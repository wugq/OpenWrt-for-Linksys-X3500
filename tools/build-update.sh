#!/usr/bin/env bash
# X3500 固件更新编译脚本
#
# 把 OpenWrt 源码更新到上游的新版本，重新打上 X3500 的补丁，编译出新固件。
# 只改电脑上的源码和编译产物，不会连接或改动路由器。
#
# 用法：
#   tools/build-update.sh --check            只检查：上游有没有更新、补丁能不能打上（什么都不改）
#   tools/build-update.sh                    更新到 openwrt-24.10 分支的最新提交，然后编译
#   tools/build-update.sh --ref v24.10.8     更新到指定的标签或分支，然后编译
#   tools/build-update.sh --rebuild          不更新源码，只按保存的配置重新编译
#   选项：-j N   并行编译的任务数（默认 CPU 核数 + 1）
#
# 依赖的文件（都在 openwrt-x3500/）：
#   0001-bmips-add-Linksys-X3500.patch   X3500 的全部源码改动
#   diffconfig                           编译配置
#   feeds.list                           要从 feeds 安装的软件包
#   files/                               打包进镜像的文件（首次开机设置）

set -euo pipefail

PROJ=$(cd "$(dirname "$0")/.." && pwd)
WRT=$PROJ/openwrt
SAVED=$PROJ/openwrt-x3500
PATCH=$SAVED/0001-bmips-add-Linksys-X3500.patch
DEVICE=linksys_x3500
TARGET_DIR=bin/targets/bmips/bcm6362
PREFIX=openwrt-bmips-bcm6362-$DEVICE

# 分区和内存的上限（见 private/写入闪存方案.md、private/操作记录.md §13）
FIRMWARE_MAX=$((0xFC0000))          # firmware 分区大小
INITRAMFS_MAX=$((0xFF0000))         # 内存启动版：0x81000000 - 0x80010000

# b43 固件源码包：OpenWrt 镜像站已经没有了，从 Internet Archive 取（private/操作记录.md §12）
B43_FILE=broadcom-wl-6.30.163.46.tar.bz2
B43_URL=https://web.archive.org/web/20240224140024id_/http://www.lwfinger.com/b43-firmware/$B43_FILE
B43_SHA256=a07c3b6b277833c7dbe61daa511f908cd66c5e2763eb7a0859abc36cd9335c2d

MODE=update
REF=openwrt-24.10
JOBS=$(( $(nproc) + 1 ))

while [ $# -gt 0 ]; do
	case "$1" in
	--check)   MODE=check ;;
	--rebuild) MODE=rebuild ;;
	--ref)     REF=$2; shift ;;
	-j)        JOBS=$2; shift ;;
	-h|--help) sed -n '2,20p' "$0"; exit 0 ;;
	*)         echo "未知参数：$1（--help 查看用法）" >&2; exit 2 ;;
	esac
	shift
done

say()  { printf '\n==> %s\n' "$*"; }
die()  { printf '\n错误：%s\n' "$*" >&2; exit 1; }

# 运行会改动 git 索引的命令。如果 .git/index.lock 被占用（通常是 Zed 等编辑器
# 或终端提示符的 git 集成正在读仓库），直接报错，不重试
LOCK_MSG="git 仓库被其它程序占用（.git/index.lock）。可能是 Zed 等编辑器打开了 openwrt/ 下的文件，请关闭后重新运行"
gitw() {
	local err
	err=$(mktemp)
	if git "$@" 2>"$err"; then
		rm -f "$err"
		return 0
	fi
	if grep -q 'index.lock' "$err"; then
		rm -f "$err"
		echo "  $LOCK_MSG" >&2
		return 1
	fi
	cat "$err" >&2
	rm -f "$err"
	return 1
}

# 把补丁里新加的文件标记成 intent-to-add，git diff 才会包含它们
mark_new_files() {
	grep -E '^\+\+\+ b/' "$PATCH" | sed 's|^+++ b/||' | while read -r f; do
		git ls-files --error-unmatch "$f" >/dev/null 2>&1 || gitw add -N "$f"
	done
}

# 撤掉补丁之后、重新打好补丁之前出错时，切回原来的版本并恢复改动
ROLLBACK_TO=
rollback() {
	[ -n "$ROLLBACK_TO" ] || return 0
	echo
	echo "  出错了，正在恢复到更新前的状态（$(git rev-parse --short "$ROLLBACK_TO")）..."
	if ! gitw reset -q --hard "$ROLLBACK_TO"; then
		echo "  自动恢复失败。请关闭占用仓库的程序后，在 openwrt/ 下手动运行："
		echo "    git reset -q --hard $(git rev-parse --short "$ROLLBACK_TO")"
		echo "    git apply --whitespace=nowarn $PATCH"
		echo "    然后对补丁里新加的文件运行 git add -N <文件>"
		ROLLBACK_TO=
		return 0
	fi
	# 补丁新加的文件不受 reset 管理，要先删掉，否则重新打补丁会提示文件已存在
	grep -E '^\+\+\+ b/' "$PATCH" | sed 's|^+++ b/||' | while read -r f; do
		git cat-file -e "$ROLLBACK_TO:$f" 2>/dev/null || rm -f "$f"
	done
	git apply --whitespace=nowarn "$PATCH"
	mark_new_files
	if git diff | cmp -s - "$PATCH"; then
		echo "  已恢复：源码和改动都回到了运行脚本之前的样子"
	else
		echo "  恢复后的改动和保存的补丁不一致，请手动检查（备份在 private/builds/ 下）"
	fi
	ROLLBACK_TO=
}
trap 'rollback' EXIT

cd "$WRT"

# ---------------------------------------------------------------------------
# 1. 安全检查：本地改动必须已经完整保存在 $PATCH 里，否则更新源码时会丢失
# ---------------------------------------------------------------------------
check_saved() {
	local cur
	cur=$(mktemp)
	git diff > "$cur"
	if ! cmp -s "$cur" "$PATCH"; then
		echo "  当前源码里的改动和 openwrt-x3500/ 里保存的补丁不一致。差别："
		diff -u "$PATCH" "$cur" | head -40 || true
		rm -f "$cur"
		die "请先把改动保存到补丁（git add -N 新文件后 git diff > $PATCH），再运行本脚本"
	fi
	rm -f "$cur"
	if ! diff -rq "$SAVED/files" files >/dev/null 2>&1; then
		die "openwrt/files 和 openwrt-x3500/files 不一致，请先确认以哪个为准"
	fi
	echo "  本地改动已经完整保存在 openwrt-x3500/"
}

# ---------------------------------------------------------------------------
# 2. 检查上游：取指定版本的最新提交，测试补丁能不能直接打上
# ---------------------------------------------------------------------------
fetch_upstream() {
	say "从上游获取 $REF"
	git fetch --depth 1 origin "$REF" 2>&1 | tail -2
	NEW=$(git rev-parse FETCH_HEAD)
	CUR=$(git rev-parse HEAD)
	echo "  当前：$(git log -1 --format='%h %cs %s' "$CUR")"
	echo "  上游：$(git log -1 --format='%h %cs %s' "$NEW")"
}

test_patch() {
	# 用临时索引在新版本上试打补丁，不动工作区
	local idx ok=0
	idx=$(mktemp)
	GIT_INDEX_FILE=$idx git read-tree "$NEW"
	if GIT_INDEX_FILE=$idx git apply --cached --check "$PATCH" 2>/dev/null; then
		echo "  补丁可以直接打到新版本上"
	elif GIT_INDEX_FILE=$idx git apply --cached --check --3way "$PATCH" 2>/dev/null; then
		echo "  补丁需要三方合并才能打上（上游改过同样的文件，但能自动合并）"
	else
		echo "  补丁打不上，冲突的地方："
		GIT_INDEX_FILE=$idx git apply --cached --check "$PATCH" 2>&1 | sed 's/^/    /' | head -20
		ok=1
	fi
	rm -f "$idx"
	return $ok
}

# ---------------------------------------------------------------------------
# 3. 更新源码并重新打补丁
# ---------------------------------------------------------------------------
update_source() {
	say "更新源码到 $(git rev-parse --short "$NEW")"
	[ ! -e .git/index.lock ] || die "$LOCK_MSG"
	local backup=$STAMP_DIR/local-before.patch
	git diff > "$backup"
	echo "  更新前的改动另外备份到 ${backup#$PROJ/}"

	# 先撤掉我们的改动（包括新加的文件），让工作区回到干净的上游状态。
	# 从这里开始到补丁重新打好之前，任何错误都会触发 rollback
	ROLLBACK_TO=$CUR
	git apply -R --whitespace=nowarn "$PATCH"
	gitw reset -q
	[ -z "$(git status --porcelain --untracked-files=no)" ] || die "撤销补丁后工作区不干净，已停止"

	gitw -c advice.detachedHead=false checkout -q --detach "$NEW"
	echo "  源码已切换到 $(git log -1 --format='%h %s')"

	if ! gitw apply --3way --whitespace=nowarn "$PATCH"; then
		# 冲突时保留冲突现场让用户手动解决，不自动回滚
		ROLLBACK_TO=
		echo
		echo "  补丁有冲突。冲突的文件里有 <<<<<<< ======= >>>>>>> 标记，手动解决后："
		echo "    cd openwrt && git add -N <新文件> && git diff > $PATCH"
		echo "  再运行：tools/build-update.sh --rebuild"
		echo "  如果冲突出在 120-pinctrl-bcm6362-fix-gpio-mode-mask.patch，"
		echo "  可能是上游已经修复了这个 bug，见 private/pinctrl-bcm6362-bug.md"
		die "补丁冲突，已停止（更新前的改动在 ${backup#$PROJ/}）"
	fi
	gitw reset -q
	mark_new_files
	ROLLBACK_TO=

	# 三方合并时补丁内容可能变了，保存新的版本（旧的备份一份）
	if ! git diff | cmp -s - "$PATCH"; then
		cp "$PATCH" "$STAMP_DIR/$(basename "$PATCH").old"
		git diff > "$PATCH"
		echo "  补丁经过合并有变化，已更新 openwrt-x3500/ 里的补丁（旧版在 ${STAMP_DIR#$PROJ/}）"
	fi
}

# ---------------------------------------------------------------------------
# 4. feeds、配置、编译
# ---------------------------------------------------------------------------
prepare_build() {
	say "复制 files/（首次开机设置）"
	rm -rf files
	cp -a "$SAVED/files" files

	say "更新 feeds"
	./scripts/feeds update -a > "$STAMP_DIR/feeds.log" 2>&1 || die "feeds update 失败，见 ${STAMP_DIR#$PROJ/}/feeds.log"
	grep -v -E '^\s*(#|$)' "$SAVED/feeds.list" | xargs ./scripts/feeds install >> "$STAMP_DIR/feeds.log" 2>&1 \
		|| die "feeds install 失败，见 ${STAMP_DIR#$PROJ/}/feeds.log"

	say "生成编译配置"
	cp "$SAVED/diffconfig" .config
	make defconfig > /dev/null 2>&1
	local missing=""
	for p in luci luci-i18n-base-zh-cn kmod-leds-gpio kmod-b43 wpad-basic-mbedtls \
		 tcpdump iperf3 bird2 ip-full ip-bridge kmod-fs-exfat; do
		grep -q "^CONFIG_PACKAGE_$p=y" .config || missing="$missing $p"
	done
	[ -z "$missing" ] || die "这些软件包没有被选上：$missing"
	echo "  配置检查通过"

	if [ ! -f "dl/$B43_FILE" ]; then
		say "下载 b43 固件源码包（Internet Archive）"
		curl -fsSL --retry 3 -o "dl/$B43_FILE.tmp" "$B43_URL"
		echo "$B43_SHA256  dl/$B43_FILE.tmp" | sha256sum -c --quiet || { rm -f "dl/$B43_FILE.tmp"; die "b43 固件校验失败"; }
		mv "dl/$B43_FILE.tmp" "dl/$B43_FILE"
	fi
}

build() {
	say "下载源码包"
	make -j8 download > "$STAMP_DIR/download.log" 2>&1 || die "下载失败，见 ${STAMP_DIR#$PROJ/}/download.log"
	say "编译（-j$JOBS），日志：${STAMP_DIR#$PROJ/}/build.log"
	local t0=$SECONDS
	if ! make -j"$JOBS" > "$STAMP_DIR/build.log" 2>&1; then
		tail -20 "$STAMP_DIR/build.log"
		die "编译失败。可以用 make -j1 V=s 查看详细错误"
	fi
	echo "  用时 $(( (SECONDS - t0) / 60 )) 分钟"
}

# ---------------------------------------------------------------------------
# 5. 检查产物大小，复制到 private/builds/
# ---------------------------------------------------------------------------
collect() {
	say "检查产物"
	local sysup=$TARGET_DIR/$PREFIX-squashfs-sysupgrade.bin
	local elf=$TARGET_DIR/$PREFIX-initramfs.elf
	[ -f "$sysup" ] && [ -f "$elf" ] || die "找不到编译产物"

	local size
	size=$(stat -c %s "$sysup")
	printf '  sysupgrade.bin：%d 字节（firmware 分区 %d 字节）\n' "$size" "$FIRMWARE_MAX"
	[ "$size" -lt "$FIRMWARE_MAX" ] || die "sysupgrade.bin 超过 firmware 分区大小，不能写入"

	local readelf vmlinux filesz
	readelf=$(ls staging_dir/toolchain-*/bin/*-readelf | head -1)
	vmlinux=$(ls -td build_dir/target-*/linux-bmips_bcm6362/linux-*/vmlinux | head -1)
	filesz=$("$readelf" -lW "$vmlinux" | awk '$1=="LOAD"{print $5}')
	printf '  内存启动版内核解压后：%d 字节（上限 %d）\n' "$((filesz))" "$INITRAMFS_MAX"
	[ "$((filesz))" -lt "$INITRAMFS_MAX" ] || echo "  警告：内存启动版放不下，不能用 CFE 的 r 命令测试（写闪存的版本不受影响）"

	local ver
	ver=$(git describe --tags --always 2>/dev/null)
	local out=$STAMP_DIR
	cp "$sysup" "$elf" "$TARGET_DIR/$PREFIX-squashfs-cfe.bin" "$TARGET_DIR/$PREFIX.manifest" "$out/"
	( cd "$out" && sha256sum ./*.bin ./*.elf > sha256sums )
	echo "  源码版本：$ver"
	echo "  产物在：${out#$PROJ/}/"
}

finish() {
	cat <<EOF

完成。升级路由器（由你自己决定什么时候做）：

  方法 1：网页
    http://192.168.2.1 → 系统 → 备份/升级 → 刷写新的固件
    选择 ${STAMP_DIR#$PROJ/}/$PREFIX-squashfs-sysupgrade.bin
    勾选"保留当前配置"

  方法 2：命令行
    scp -O ${STAMP_DIR#$PROJ/}/$PREFIX-squashfs-sysupgrade.bin root@192.168.2.1:/tmp/
    ssh root@192.168.2.1 sysupgrade -v /tmp/$PREFIX-squashfs-sysupgrade.bin

  想先在内存里试运行：把 $PREFIX-initramfs.elf 放进 private/tftp/，
  进 CFE 用 r 命令加载（电脑有线口要临时加 192.168.1.100，见 private/操作记录.md §10）

  升级出问题时的恢复办法：private/写入闪存方案.md §5
EOF
}

# ---------------------------------------------------------------------------

STAMP_DIR=$PROJ/private/builds/$(date +%Y%m%d-%H%M)

case "$MODE" in
check)
	say "检查本地改动"
	check_saved
	fetch_upstream
	if [ "$NEW" = "$CUR" ]; then
		echo "  已经是最新的，不需要更新"
		exit 0
	fi
	echo "  上游有更新。最近的提交（浅克隆只能看到最新一条）："
	git log -1 --format='    %h %cs %s' "$NEW"
	say "测试补丁"
	test_patch || exit 1
	echo
	echo "可以运行 tools/build-update.sh 更新并编译"
	;;
update)
	say "检查本地改动"
	check_saved
	fetch_upstream
	if [ "$NEW" = "$CUR" ]; then
		echo "  已经是最新的。要重新编译请用 --rebuild"
		exit 0
	fi
	test_patch || die "补丁打不上新版本，没有做任何改动"
	mkdir -p "$STAMP_DIR"
	update_source
	prepare_build
	build
	collect
	finish
	;;
rebuild)
	say "检查本地改动"
	check_saved
	mkdir -p "$STAMP_DIR"
	prepare_build
	build
	collect
	finish
	;;
esac

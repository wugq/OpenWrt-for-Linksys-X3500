#!/usr/bin/env bash
# 从零编译 Linksys X3500 的 OpenWrt 固件（GitHub Actions 和本地都可以用）
#
# 环境变量：
#   OPENWRT_REF   上游分支或标签（默认 openwrt-24.10）
#   WORKDIR       OpenWrt 源码目录（默认 ./openwrt，不存在时自动克隆）
#   OUTDIR        产物目录（默认 ./out）
#   STOP_AFTER    设为 config 时只做到生成配置为止，用于快速检查补丁和配置
#   JOBS          并行任务数（默认 CPU 核数 + 1）
#   DL_CACHE      源码包缓存目录（可选；设置后 dl/ 会链接到这里，CI 用来跨次复用下载）

set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
OPENWRT_REF=${OPENWRT_REF:-openwrt-24.10}
WORKDIR=$(realpath -m "${WORKDIR:-openwrt}")
OUTDIR=$(realpath -m "${OUTDIR:-out}")
JOBS=${JOBS:-$(( $(nproc) + 1 ))}

PATCH=$REPO/0001-bmips-add-Linksys-X3500.patch
DEVICE=linksys_x3500
PREFIX=openwrt-bmips-bcm6362-$DEVICE
TARGET_DIR=bin/targets/bmips/bcm6362

FIRMWARE_MAX=$((0xFC0000))     # firmware 分区大小
INITRAMFS_MAX=$((0xFF0000))    # 内存启动版：0x81000000 - 0x80010000

# b43 固件源码包，OpenWrt 镜像站已经没有了
B43_FILE=broadcom-wl-6.30.163.46.tar.bz2
B43_URL=https://web.archive.org/web/20240224140024id_/http://www.lwfinger.com/b43-firmware/$B43_FILE
B43_SHA256=a07c3b6b277833c7dbe61daa511f908cd66c5e2763eb7a0859abc36cd9335c2d

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\n错误：%s\n' "$*" >&2; exit 1; }

say "获取 OpenWrt 源码（$OPENWRT_REF）"
if [ ! -d "$WORKDIR/.git" ]; then
	git clone --depth 1 --branch "$OPENWRT_REF" https://github.com/openwrt/openwrt.git "$WORKDIR"
fi
cd "$WORKDIR"
OPENWRT_COMMIT=$(git rev-parse HEAD)
echo "  $(git log -1 --format='%h %cs %s')"

say "打补丁"
git apply --whitespace=nowarn "$PATCH" || die "补丁打不上 $OPENWRT_REF 的最新代码，需要手动更新补丁"
rm -rf files
cp -a "$REPO/files" files

say "更新 feeds"
./scripts/feeds update -a > /dev/null
grep -v -E '^\s*(#|$)' "$REPO/feeds.list" | xargs ./scripts/feeds install > /dev/null

say "生成配置"
cp "$REPO/diffconfig" .config
make defconfig > /dev/null
missing=""
for p in luci luci-i18n-base-zh-cn kmod-leds-gpio kmod-b43 wpad-basic-mbedtls \
	 tcpdump iperf3 bird2 ip-full ip-bridge kmod-fs-exfat; do
	grep -q "^CONFIG_PACKAGE_$p=y" .config || missing="$missing $p"
done
[ -z "$missing" ] || die "这些软件包没有被选上：$missing"
echo "  配置检查通过"

if [ "${STOP_AFTER:-}" = config ]; then
	echo "  STOP_AFTER=config，到此为止"
	exit 0
fi

if [ -n "${DL_CACHE:-}" ]; then
	mkdir -p "$DL_CACHE"
	rm -rf dl
	ln -s "$(realpath "$DL_CACHE")" dl
fi
mkdir -p dl
if [ ! -f "dl/$B43_FILE" ]; then
	say "下载 b43 固件源码包"
	curl -fsSL --retry 3 -o "dl/$B43_FILE.tmp" "$B43_URL"
	echo "$B43_SHA256  dl/$B43_FILE.tmp" | sha256sum -c --quiet || die "b43 固件校验失败"
	mv "dl/$B43_FILE.tmp" "dl/$B43_FILE"
fi

say "下载源码包"
make -j8 download > /dev/null || make -j1 download V=s

say "编译（-j$JOBS）"
if ! make -j"$JOBS"; then
	echo "并行编译失败，用 -j1 V=s 重新编译以显示错误："
	make -j1 V=s 2>&1 | tail -100
	die "编译失败"
fi

say "检查产物"
sysup=$TARGET_DIR/$PREFIX-squashfs-sysupgrade.bin
elf=$TARGET_DIR/$PREFIX-initramfs.elf
[ -f "$sysup" ] && [ -f "$elf" ] || die "找不到编译产物"
size=$(stat -c %s "$sysup")
echo "  sysupgrade.bin：$size 字节（firmware 分区 $FIRMWARE_MAX 字节）"
[ "$size" -lt "$FIRMWARE_MAX" ] || die "sysupgrade.bin 超过 firmware 分区大小"

readelf=$(ls staging_dir/toolchain-*/bin/*-readelf | head -1)
vmlinux=$(ls -td build_dir/target-*/linux-bmips_bcm6362/linux-*/vmlinux | head -1)
filesz=$(( $("$readelf" -lW "$vmlinux" | awk '$1=="LOAD"{print $5}') ))
echo "  内存启动版内核解压后：$filesz 字节（上限 $INITRAMFS_MAX）"
initramfs_note="内存启动版可以用 CFE 的 r 命令测试"
if [ "$filesz" -ge "$INITRAMFS_MAX" ]; then
	initramfs_note="警告：内存启动版太大，不能用 CFE 的 r 命令测试（写闪存的版本不受影响）"
	echo "  $initramfs_note"
fi

say "整理产物"
mkdir -p "$OUTDIR"
cp "$sysup" "$elf" "$TARGET_DIR/$PREFIX-squashfs-cfe.bin" "$TARGET_DIR/$PREFIX.manifest" "$OUTDIR/"
( cd "$OUTDIR" && sha256sum ./*.bin ./*.elf > sha256sums )
cat > "$OUTDIR/build-info.txt" <<EOF
OpenWrt 分支：$OPENWRT_REF
OpenWrt 提交：$OPENWRT_COMMIT
X3500 仓库提交：$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)
编译时间（UTC）：$(date -u '+%Y-%m-%d %H:%M')
sysupgrade.bin：$size 字节
内存启动版内核解压后：$filesz 字节（上限 $INITRAMFS_MAX）。$initramfs_note
EOF
cat "$OUTDIR/build-info.txt"
echo "openwrt_commit=$OPENWRT_COMMIT" >> "${GITHUB_OUTPUT:-/dev/null}"

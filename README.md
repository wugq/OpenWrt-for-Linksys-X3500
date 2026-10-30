# OpenWrt for Linksys X3500

为 Linksys X3500（Broadcom BCM6362，ADSL2+ 调制解调路由器）编译 OpenWrt 24.10 固件的补丁、配置和工具。GitHub Actions 每周检查一次 OpenWrt 上游，有更新就自动编译，固件发布在 [Releases](../../releases)。

*OpenWrt 24.10 support patches, build configuration and CI for the Linksys X3500 (BCM6362). Firmware is built weekly by GitHub Actions and published under Releases.*

> **这不是 OpenWrt 官方支持的设备。** 补丁只在一台 X3500 上测试过。刷机有变砖风险，请先完整备份闪存，并准备好串口线。没有任何担保。

## 硬件支持情况

| 部分 | 状态 | 说明 |
|---|---|---|
| CPU、内存、SPI 闪存（16MB） | ✅ | |
| 网口（WAN + 4 个 LAN，BCM53125 交换芯片） | ✅ | DSA，支持硬件 VLAN |
| LED、Reset 键、WiFi 键 | ✅ | WiFi 灯接在无线芯片上，无法控制 |
| USB 2.0 | ✅ | U 盘约 20 MB/s |
| 无线（Mini PCIe 的 BCM4331） | ⚠️ | `b43` 驱动只支持 2.4GHz、802.11g，速度很低；**不支持 5GHz** |
| 无线（SoC 内置的 2.4GHz） | ❌ | 没有开源驱动 |
| ADSL | ❌ | 没有开源驱动 |

## 固件的默认设置
- LAN 地址 **`192.168.2.1`**（避免和上级路由器的 `192.168.1.x` 冲突），网页管理界面 LuCI（中文）
- 用户名 `root`，**没有密码**：首次登录后请立即在"系统 → 管理权"里设置
- 时区：Pacific/Auckland
- 带有实验工具：`tcpdump`、`iperf3`、`mtr`、`ip-full`、`ip-bridge`、`ethtool`、`bird2`
- 无线默认关闭

## 闪存布局
| 偏移 | 大小 | 内容 | 固件是否改写 |
|---|---|---|---|
| `0x000000` | 64KB | CFE 引导程序 | 否（设备树里只读） |
| `0x010000` | 15.75MB | firmware：Broadcom 镜像头 + 内核 + squashfs + jffs2 可写区 | 是 |
| `0xFD0000` | 64KB | 原厂 scratch pad | 否（只读） |
| `0xFE0000` | 128KB | 原厂设置（PSI） | 否（只读） |

## 安装
**首次安装**（从原厂固件）：需要串口进入 CFE，参考步骤：
1. 用串口（115200）在开机倒计时时按回车，进入 `CFE>`
2. 先用 `r <TFTP 主机>:<文件>` 加载 `*-initramfs.elf` 在内存里试运行，确认一切正常（不写闪存）
3. 在内存里运行的 OpenWrt 中，用 `sysupgrade -n` 写入 `*-squashfs-sysupgrade.bin`

**CFE 的 `w` 命令会覆盖 CFE 本身，不要使用。** 回原厂可以在 CFE 里用 `f` 命令或 CFE 网页恢复页面（`http://192.168.1.1`）刷入原厂固件。

**升级**（已经是 OpenWrt）：LuCI → 系统 → 备份/升级 → 上传 `*-squashfs-sysupgrade.bin`，勾选"保留当前配置"。

## 仓库内容
```
openwrt-x3500/
  0001-bmips-add-Linksys-X3500.patch   对 OpenWrt 源码的全部改动（设备树、镜像定义、LED、内核补丁）
  diffconfig                           编译配置
  config.x3500                         完整的 .config（参考用）
  feeds.list                           要从 feeds 安装的软件包
  files/                               打包进镜像的文件（首次开机设置）
  scripts/ci-build.sh                  从零编译（CI 和本地都能用）
tools/
  build-update.sh                      本地：更新已有的 OpenWrt 源码树并重新编译
  serial_cmd.py                        串口收发、开机时进入 CFE
  dump_mtd.py                          通过串口备份闪存
  parse_flash.py                       解析闪存备份：镜像头、CFE NVRAM、PSI
.github/workflows/build.yml            每周自动编译
```

## 本地编译
```sh
git clone https://github.com/wugq/OpenWrt-for-Linksys-X3500.git && cd OpenWrt-for-Linksys-X3500
openwrt-x3500/scripts/ci-build.sh       # 克隆 OpenWrt、打补丁、编译，产物在 out/
```
需要 OpenWrt 的编译依赖，以及约 20GB 磁盘空间。

## 内核补丁
`target/linux/bmips/patches-6.6/120-pinctrl-bcm6362-fix-gpio-mode-mask.patch` 修复了 Linux `pinctrl-bcm6362` 驱动的一个 bug：`bcm6362_set_gpio()` 把引脚号当成了位掩码（少了 `BIT()`），导致被引导程序复用给 LED 控制器的引脚无法切回 GPIO。这个 bug 在最新的主线内核里仍然存在。

## 许可证
GPL-2.0（与 OpenWrt 和 Linux 内核相同），见 [LICENSE](LICENSE)。

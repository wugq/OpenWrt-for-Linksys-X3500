#!/usr/bin/env python3
"""通过串口把路由器（OpenWrt）上的一个 MTD 分区读回电脑。

路由器上用 hexdump 把分区按每行 16 字节输出成 16 进制文本，电脑这边收下来再还原成二进制，
最后和路由器上 md5sum 的结果比对。只读操作，不写闪存。

用法:
  dump_mtd.py --mtd 0 --size 0x10000 --out private/backup/mtd0-cfe.bin
"""
import argparse
import hashlib
import os
import re
import select
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from serial_cmd import open_port  # noqa: E402

HEX_LINE = re.compile(rb"^[0-9a-f]{32}$")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", default="/dev/ttyUSB0")
    p.add_argument("--mtd", type=int, required=True)
    p.add_argument("--size", type=lambda s: int(s, 0), required=True, help="分区大小（字节）")
    p.add_argument("--out", required=True)
    p.add_argument("--timeout", type=float, default=7200)
    a = p.parse_args()

    dev = f"/dev/mtd{a.mtd}ro"
    # 标记拆开写，避免回显的命令行本身被当成标记
    cmd = (f"dmesg -n 1; echo ==''=BEGIN; hexdump -v -e '16/1 \"%02x\" \"\\n\"' {dev}; "
           f"echo ==''=END; md5sum {dev}; echo ==''=DONE\r")

    fd = open_port(a.port)
    os.write(fd, b"\r")
    time.sleep(0.5)
    os.read(fd, 65536) if select.select([fd], [], [], 0)[0] else None
    os.write(fd, cmd.encode())

    buf = b""
    start = last_report = time.monotonic()
    expected = a.size // 16
    while b"===DONE" not in buf:
        if time.monotonic() - start > a.timeout:
            sys.exit("超时")
        r, _, _ = select.select([fd], [], [], 0.5)
        if r:
            buf += os.read(fd, 65536)
        if time.monotonic() - last_report > 10:
            got = buf.count(b"\n")
            el = time.monotonic() - start
            print(f"  {got}/{expected} 行，{el:.0f}s", flush=True)
            last_report = time.monotonic()
    os.close(fd)

    body = buf.split(b"===BEGIN", 1)[1].split(b"===END", 1)
    hex_part, tail = body[0], body[1]
    lines = [l.strip() for l in hex_part.replace(b"\r", b"").split(b"\n")]
    good = [l for l in lines if HEX_LINE.match(l)]
    bad = [l for l in lines if l and not HEX_LINE.match(l)]
    data = bytes.fromhex(b"".join(good).decode())

    m = re.search(rb"([0-9a-f]{32})\s+" + re.escape(dev.encode()), tail)
    router_md5 = m.group(1).decode() if m else None
    local_md5 = hashlib.md5(data).hexdigest()

    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    with open(a.out, "wb") as f:
        f.write(data)

    print(f"{dev}: 收到 {len(good)} 行 / 期望 {expected} 行，{len(data)} 字节 / 期望 {a.size} 字节")
    print(f"无法识别的行: {len(bad)}")
    for l in bad[:5]:
        print("   ", l[:80])
    print(f"路由器 md5: {router_md5}")
    print(f"本地   md5: {local_md5}")
    ok = router_md5 == local_md5 and len(data) == a.size
    print("✅ 校验通过" if ok else "❌ 校验失败")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()

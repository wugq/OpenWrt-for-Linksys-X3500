#!/usr/bin/env python3
"""通过串口给 X3500 发命令，把收到的内容同时打印出来并追加到日志文件。

用法:
  serial_cmd.py [--port /dev/ttyUSB0] [--log private/serial-session.log] [--quiet 2.0] [--max 30] CMD [CMD ...]
  serial_cmd.py --listen 10          # 只听 10 秒，不发送
  serial_cmd.py --break-cfe 60       # 最多等 60 秒：一直发回车，直到出现 CFE> 提示符

每条命令发送后会一直读，直到串口连续 --quiet 秒没有新数据，或者总共读满 --max 秒。
"""
import argparse
import os
import select
import sys
import termios
import time


def open_port(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    # 原始模式，115200 8N1，无流控
    attrs[0] = 0                                   # iflag
    attrs[1] = 0                                   # oflag
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL  # cflag
    attrs[3] = 0                                   # lflag
    attrs[4] = termios.B115200                     # ispeed
    attrs[5] = termios.B115200                     # ospeed
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    termios.tcflush(fd, termios.TCIFLUSH)
    return fd


def read_until_quiet(fd, log, quiet, max_s):
    start = last = time.monotonic()
    while True:
        now = time.monotonic()
        if now - last >= quiet or now - start >= max_s:
            return
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            data = os.read(fd, 4096)
            if data:
                last = time.monotonic()
                log.write(data)
                log.flush()
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()


def break_into_cfe(fd, log, max_s, prompt=b"CFE>"):
    """开机时每 0.1 秒发一个回车，抢在倒计时结束前停在 CFE 提示符。"""
    start = time.monotonic()
    seen = b""
    while time.monotonic() - start < max_s:
        os.write(fd, b"\r")
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            data = os.read(fd, 4096)
            if data:
                log.write(data)
                log.flush()
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
                seen = (seen + data)[-4096:]
                if prompt in seen:
                    return True
    return False


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", default="/dev/ttyUSB0")
    # 日志固定写到项目的 private/ 下（串口日志含序列号等私人信息，不进 git）
    default_log = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "private", "serial-session.log")
    p.add_argument("--log", default=os.path.normpath(default_log))
    p.add_argument("--quiet", type=float, default=2.0)
    p.add_argument("--max", type=float, default=30.0)
    p.add_argument("--listen", type=float, help="只监听这么多秒，不发送命令")
    p.add_argument("--break-cfe", type=float, metavar="SECONDS",
                   help="开机时连续发回车，直到出现 CFE> 或超时")
    p.add_argument("cmds", nargs="*")
    a = p.parse_args()

    fd = open_port(a.port)
    with open(a.log, "ab") as log:
        if a.listen:
            read_until_quiet(fd, log, a.listen, a.listen)
        if a.break_cfe:
            log.write(f"\n===== [{time.strftime('%H:%M:%S')}] >>> 等待 CFE 提示符 =====\n".encode())
            ok = break_into_cfe(fd, log, a.break_cfe)
            print(f"\n[break-cfe] {'已进入 CFE' if ok else '超时，没有看到 CFE>'}", file=sys.stderr)
            if not ok:
                os.close(fd)
                sys.exit(1)
            read_until_quiet(fd, log, 1.0, 3.0)
        for cmd in a.cmds:
            marker = f"\n===== [{time.strftime('%H:%M:%S')}] >>> {cmd} =====\n".encode()
            log.write(marker)
            log.flush()
            os.write(fd, cmd.encode() + b"\r")
            read_until_quiet(fd, log, a.quiet, a.max)
    os.close(fd)


if __name__ == "__main__":
    main()

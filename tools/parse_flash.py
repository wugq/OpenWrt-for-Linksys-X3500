#!/usr/bin/env python3
"""解析 X3500 整片闪存备份：CFE 里的 NVRAM、firmware 分区开头的 Broadcom 镜像头，以及闪存末尾的 PSI 区。"""
import struct, sys, zlib

data = open(sys.argv[1], 'rb').read()

def s(b):
    return b.split(b'\0')[0].decode('latin-1')

# Broadcom 镜像头 (bcm_tag)，位于 firmware 分区开头 0x10000
TAG = 0x10000
t = data[TAG:TAG + 256]
fields = [
    ('tagVersion', 0, 4), ('sig_1', 4, 20), ('sig_2', 24, 14), ('chipid', 38, 6),
    ('boardid', 44, 16), ('big_endian', 60, 2), ('totalLength', 62, 10),
    ('cfeAddress', 72, 12), ('cfeLength', 84, 10), ('flashImageStart', 94, 12),
    ('flashRootLength', 106, 10), ('kernelAddress', 116, 12), ('kernelLength', 128, 10),
    ('dualImage', 138, 2), ('inactiveFlag', 140, 2), ('information1', 162, 30),
    ('flashLayoutVer', 192, 4), ('information2', 200, 16),
]
print('== 镜像头 @0x%06x' % TAG)
for name, off, ln in fields:
    print('  %-16s %r' % (name, s(t[off:off + ln])))
for name, off in [('fskernelCRC', 196), ('imageCRC', 216), ('rootfsCRC', 220),
                  ('kernelCRC', 224), ('headerCRC', 236)]:
    print('  %-16s 0x%08x' % (name, struct.unpack('>I', t[off:off + 4])[0]))
# Broadcom 的 CRC32 初值 0xffffffff、最后不取反，等于 zlib.crc32 的结果再取反
hc = (~zlib.crc32(t[:236])) & 0xffffffff
print('  headerCRC 计算值  0x%08x' % hc)

# CFE 里的 NVRAM 结构（Broadcom: NVRAM_DATA_OFFSET 0x580）
NV = 0x580
nv = data[NV:NV + 0x400]
print('\n== CFE NVRAM @0x%x' % NV)
ver = struct.unpack('>I', nv[0:4])[0]
print('  version        ', ver)
print('  bootline       ', repr(s(nv[4:260])))
print('  boardId        ', repr(s(nv[260:276])))
mt, psi, nmac = struct.unpack('>III', nv[276:288])
print('  mainThreadNum  ', mt)
print('  psiSize (KB)   ', psi)
print('  numMacAddrs    ', nmac)
print('  baseMac        ', nv[288:294].hex(':'))
rest = nv[294:]
print('  (之后 64 字节)  ', rest[:64].hex())

# PSI：一般在闪存末尾 psiSize KB
if 0 < psi < 1024:
    start = len(data) - psi * 1024
    blk = data[start:start + 64]
    print('\n== 末尾 %d KB @0x%06x 开头：' % (psi, start), blk[:48])

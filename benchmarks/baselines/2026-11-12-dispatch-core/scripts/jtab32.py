"""Decode a jump table of signed 32-bit offsets from BASE.
usage: jtab32.py BINARY TABLE_VMADDR BASE_VMADDR COUNT OPNAMES"""
import struct, sys
path, table, base, count, names = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3], 16), int(sys.argv[4]), open(sys.argv[5]).read().split()
data = open(path, 'rb').read()
ncmds = struct.unpack_from('<I', data, 16)[0]
off = 32; segs = []
for _ in range(ncmds):
    cmd, size = struct.unpack_from('<II', data, off)
    if cmd == 0x19:
        vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', data, off+24)
        segs.append((vmaddr, fileoff, filesize))
    off += size
def read(addr, n):
    for vmaddr, fileoff, filesize in segs:
        if vmaddr <= addr < vmaddr + filesize:
            o = fileoff + addr - vmaddr
            return data[o:o+n]
raw = read(table, 4 * count)
for i in range(count):
    e = struct.unpack_from('<i', raw, 4*i)[0]
    print(f"{i}\t{names[i] if i < len(names) else '?'}\t{base + e:x}")

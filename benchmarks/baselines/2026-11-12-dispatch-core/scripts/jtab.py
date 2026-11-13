"""Decode runLoop's dispatch jump table and print each opcode's handler address.
usage: jtab.py BINARY TABLE_VMADDR BASE_VMADDR COUNT OPNAMES"""
import struct, sys
path, table, base, count, names = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3], 16), int(sys.argv[4]), open(sys.argv[5]).read().split()
data = open(path, 'rb').read()
ncmds = struct.unpack_from('<I', data, 16)[0]
off = 32
segs = []
for _ in range(ncmds):
    cmd, size = struct.unpack_from('<II', data, off)
    if cmd == 0x19:  # LC_SEGMENT_64
        name = data[off+8:off+24].rstrip(b'\0').decode()
        vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', data, off+24)
        segs.append((vmaddr, vmsize, fileoff, filesize, name))
    off += size
def read(addr, n):
    for vmaddr, vmsize, fileoff, filesize, name in segs:
        if vmaddr <= addr < vmaddr + filesize:
            o = fileoff + addr - vmaddr
            return data[o:o+n]
    raise SystemExit('address not mapped %x' % addr)
raw = read(table, 2 * count)
for i in range(count):
    e = struct.unpack_from('<H', raw, 2*i)[0]
    print(f"{i}\t{names[i] if i < len(names) else '?'}\t{base + 4*e:x}")

"""Find runLoop's opcode jump table: for each `br`, the adrp/add table address and
adr base just before it; print the most common (table, base, entry size)."""
import re, sys, collections
lines = open(sys.argv[1]).read().split('\n')
found = collections.Counter()
for i, l in enumerate(lines):
    if re.search(r'\sbr\s+x\d+', l):
        win = lines[max(0, i-14):i]
        adrp = add = adr = size = None
        for w in win:
            m = re.search(r'adrp\s+(x\d+), (0x[0-9a-f]+)', w)
            if m: adrp = (m.group(1), int(m.group(2), 16))
            m = re.search(r'add\s+(x\d+), (x\d+), #(0x[0-9a-f]+)$', w.strip())
            if m and adrp and m.group(2) == adrp[0]: add = adrp[1] + int(m.group(3), 16)
            m = re.search(r'\sadr\s+(x\d+), (0x[0-9a-f]+)', w)
            if m: adr = int(m.group(2), 16)
            if 'ldrsw' in w: size = 4
            elif 'ldrh' in w: size = 2
            elif 'ldrb' in w and 'lsl' not in w and size is None: pass
        if add and adr and size:
            found[(hex(add), hex(adr), size)] += 1
for k, n in found.most_common(6): print(n, *k)

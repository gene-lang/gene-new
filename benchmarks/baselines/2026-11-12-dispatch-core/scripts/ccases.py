"""Size of each top-level case of runLoop's dispatch switch in the generated C.
usage: ccases.py CFILE SWITCH_LINE END_LINE OPCODE_NAMES_FILE"""
import re, sys
path, sw, end = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
names = open(sys.argv[4]).read().split()
lines = open(path, encoding='latin-1').read().split('\n')
ind = None
cur = None; sizes = {}; order = []
case_re = re.compile(r'^(\s*)case \(\(tyEnum_OpCode__\w+\)(\d+)\):')
for i in range(sw, end):
    m = case_re.match(lines[i])
    if m:
        if ind is None: ind = m.group(1)
        if m.group(1) == ind:
            idx = int(m.group(2))
            if cur is not None and sizes[cur] == 0:
                # several case labels share one body
                pass
            cur = idx; sizes.setdefault(cur, 0); order.append(cur)
            continue
    if ind is not None and lines[i].startswith(ind + '}') and lines[i].strip() == '}' and len(lines[i]) - len(lines[i].lstrip()) < len(ind):
        pass
    if cur is not None:
        sizes[cur] += len(lines[i].strip())
tot = sum(sizes.values())
print('total chars', tot)
for k, v in sorted(sizes.items(), key=lambda kv: -kv[1])[:60]:
    print(f"{v:9d} {100*v/tot:5.1f}% {names[k] if k < len(names) else k}")

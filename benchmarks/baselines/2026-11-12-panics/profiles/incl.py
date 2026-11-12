"""Inclusive time per symbol from a macOS `sample` call graph (main thread)."""
import re, sys, collections
def short(sym):
    if sym.startswith("eq") or sym.startswith("kind"): return sym
    sym = re.sub(r'__gene[A-Za-z]*_u\d+', '', sym)
    sym = re.sub(r'__system_u\d+|__pureZ[A-Za-z]*_u\d+|_u\d+$', '', sym)
    return sym
def parse(path):
    lines = open(path).read().split('\n')
    start = next(i for i, l in enumerate(lines) if l.startswith('Call graph:')) + 1
    nodes = []; stack = []
    for l in lines[start:]:
        if not l.strip(): break
        m = re.search(r'\d', l)
        if not m: continue
        depth = m.start() // 2
        rest = l[m.start():].split()
        count = int(rest[0]); sym = rest[1]
        node = {'count': count, 'sym': short(sym), 'parent': None, 'depth': depth}
        while stack and stack[-1]['depth'] >= depth: stack.pop()
        if stack: node['parent'] = stack[-1]
        stack.append(node); nodes.append(node)
        if depth == 2 and len(nodes) > 1 and 'Thread' in sym: break
    return nodes
def main(path, syms):
    nodes = parse(path); total = nodes[0]['count']
    incl = collections.Counter()
    for n in nodes:
        p = n['parent']; dup = False
        while p is not None:
            if p['sym'] == n['sym']: dup = True; break
            p = p['parent']
        if not dup: incl[n['sym']] += n['count']
    print(f"== {path}: {total} samples")
    if syms:
        for s in syms: print(f"{incl[s]:6d} {100*incl[s]/total:5.1f}%  {s}")
    else:
        for s, c in incl.most_common(40):
            print(f"{c:6d} {100*c/total:5.1f}%  {s}")
path = sys.argv[1]; main(path, sys.argv[2:])

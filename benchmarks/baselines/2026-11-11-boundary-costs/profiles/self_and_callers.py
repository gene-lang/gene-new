"""Self time and callers from a macOS `sample` call graph (main thread)."""
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
        node = {'count': count, 'sym': short(sym), 'children': 0, 'parent': None, 'depth': depth}
        while stack and stack[-1]['depth'] >= depth: stack.pop()
        if stack:
            node['parent'] = stack[-1]; stack[-1]['children'] += count
        stack.append(node); nodes.append(node)
        if depth == 2 and len(nodes) > 1 and 'Thread' in sym: break
    return nodes
def main(path, top=14, chain=3):
    nodes = parse(path)
    total = nodes[0]['count']
    selft = collections.Counter(); callers = collections.defaultdict(collections.Counter)
    for n in nodes:
        s = n['count'] - n['children']
        if s <= 0: continue
        selft[n['sym']] += s
        p = n['parent']; names = []
        while p is not None and len(names) < chain:
            names.append(p['sym']); p = p['parent']
        callers[n['sym']][' < '.join(names)] += s
    print(f"== {path}: {total} samples")
    for sym, s in selft.most_common(top):
        print(f"{s:6d} {100*s/total:5.1f}%  {sym}")
        if sym.startswith('runLoop'): continue
        for c, k in callers[sym].most_common(3):
            print(f"         {k:5d}  < {c}")
for p in sys.argv[1:]: main(p)

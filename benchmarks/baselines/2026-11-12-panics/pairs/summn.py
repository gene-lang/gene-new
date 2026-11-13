"""Summarize pairn.sh output: median ms per label and kernel, and per-round
paired ratios of every label against the first (the baseline).

usage: summn.py FILE BASE_LABEL [LABEL ...]
"""
import collections, statistics, sys

path, labels = sys.argv[1], sys.argv[2:]
rows = collections.defaultdict(dict)  # (kernel, round) -> label -> ms
kernels = []
for line in open(path):
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 4:
        continue
    r, label, kernel, ms = parts[:4]
    try:
        ms = float(ms)
    except ValueError:
        continue
    if kernel not in kernels:
        kernels.append(kernel)
    rows[(kernel, int(r))][label] = ms
base = labels[0]
head = f"{'kernel':28}" + "".join(f"{l:>9}" for l in labels) + "".join(
    f"{l + '/' + base:>14}" for l in labels[1:]) + "  wins"
print(head)
for k in kernels:
    rounds = sorted(r for (kk, r) in rows if kk == k)
    meds = []
    for l in labels:
        vals = [rows[(k, r)][l] for r in rounds if l in rows[(k, r)]]
        meds.append(statistics.median(vals) if vals else float("nan"))
    line = f"{k:28}" + "".join(f"{m:9.0f}" for m in meds)
    wins = []
    for l in labels[1:]:
        ratios = [rows[(k, r)][l] / rows[(k, r)][base] for r in rounds
                  if l in rows[(k, r)] and base in rows[(k, r)] and rows[(k, r)][base] > 0]
        med = statistics.median(ratios) if ratios else float("nan")
        line += f"{med:14.3f}"
        wins.append(f"{sum(1 for x in ratios if x < 1)}/{len(ratios)}")
    print(line + "  " + " ".join(wins))

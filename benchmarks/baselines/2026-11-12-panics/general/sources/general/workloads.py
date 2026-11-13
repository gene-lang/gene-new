"""Python standard-library counterpart to workloads.gene; no benchmark runner."""

import json
import sys
import time


def make_input(size):
    numbers, records, lines, events = [], [], [], []
    words = ["READ", "WRITE", "SAVE", "LOAD", "OPEN", "CLOSE"]
    for i in range(size):
        amount = (i * 37 + 11) % 1009
        numbers.append(amount)
        records.append(dict(id=i, group=f"group-{i % 32}", amount=amount, active=i % 5 != 0))
        lines.append(f" INFO user-{i % 64} ACTION {words[i % 6]} ")
        events.append(dict(key=f"user-{i % 64}", kind=i % 3, amount=amount))
    return dict(numbers=numbers, records=records, lines=lines, events=events)


def integer_loop(data):
    state, total = 7, 0
    for number in data["numbers"]:
        state = (state * 33 + number) % 1000003
        total += state
    return [state, total]


def make_transform(factor):
    def transform(value):
        return (value * (factor + 1) + factor) % 1009
    return transform


def closure_dispatch(data):
    handlers = []
    for i in range(8):
        handlers.append(make_transform(i))
    total, index = 0, 0
    for number in data["numbers"]:
        handler_index = index % 8
        handler = handlers[handler_index]
        total += handler(number)
        index += 1
    return total


def records(data):
    selected, groups = [], {}
    for row in data["records"]:
        if row["active"]:
            selected.append(row)
            groups[row["group"]] = groups.get(row["group"], 0) + row["amount"]
    ordered = sorted(selected, key=lambda row: row["amount"])
    digest = 0
    for row in ordered:
        digest = (digest * 31 + row["id"]) % 1000000007
    totals = []
    for i in range(32):
        totals.append(groups.get(f"group-{i}", 0))
    return [len(ordered), digest, totals]


def text_index(data):
    counts, total = {}, 0
    for line in data["lines"]:
        for word in line.strip().lower().split(" "):
            counts[word] = counts.get(word, 0) + 1
            total += 1
    entries = []
    for key, count in counts.items():
        entries.append([key, count])
    return [total, sorted(entries, key=lambda entry: entry[0])]


def json_roundtrip(data):
    encoded = json.dumps(data["records"], separators=(",", ":"))
    decoded = json.loads(encoded)
    total = 0
    for row in decoded:
        total += row["amount"]
    return [len(decoded), total, len(encoded.encode("utf-8"))]


def event_replay(data):
    state = {}
    for event in data["events"]:
        account = state.get(event["key"])
        if account is None:
            account = dict(balance=0, revision=0)
            state[event["key"]] = account
        if event["kind"] == 0:
            account["balance"] += event["amount"]
        elif event["kind"] == 1:
            account["balance"] -= event["amount"]
        else:
            account["balance"] = event["amount"]
        account["revision"] += 1
    result = []
    for key, account in state.items():
        result.append([key, account["balance"], account["revision"]])
    return sorted(result, key=lambda entry: entry[0])


CASES = [integer_loop, closure_dispatch, records, text_index, json_roundtrip, event_replay]


def measure(function, data, target_ms):
    repetitions, elapsed = 1, 0
    while elapsed < target_ms:
        started = time.perf_counter_ns()
        for _ in range(repetitions):
            result = function(data)
        elapsed = (time.perf_counter_ns() - started) / 1_000_000
        if elapsed < target_ms:
            if repetitions >= 1048576:
                raise RuntimeError("benchmark calibration exceeded repetition limit")
            repetitions *= 2
    expected = result
    started = time.perf_counter_ns()
    for _ in range(repetitions):
        result = function(data)
    elapsed = (time.perf_counter_ns() - started) / 1_000_000
    if result != expected:
        raise RuntimeError(f"unstable result: {function.__name__}")
    return dict(name=function.__name__, repetitions=repetitions, elapsed_ms=elapsed, result=result)


def main():
    if not 2 <= len(sys.argv) <= 3:
        raise SystemExit("usage: workloads.py SIZE [TARGET_MS]; TARGET_MS=0 verifies without timing")
    size = int(sys.argv[1])
    target_ms = int(sys.argv[2]) if len(sys.argv) == 3 else 100
    if not 1 <= size <= 1000000 or not 0 <= target_ms <= 10000:
        raise SystemExit("size must be in 1..1000000; target_ms must be in 0..10000")
    data = make_input(size)
    rows = [dict(name=f.__name__, result=f(data)) if target_ms == 0
            else measure(f, data, target_ms) for f in CASES]
    print(json.dumps(dict(format=1, language="python", size=size, target_ms=target_ms, rows=rows)))


if __name__ == "__main__":
    main()

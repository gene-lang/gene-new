# The Python side of kernels.gene: the same kernels, names and iteration counts.
import time
def now(): return time.perf_counter()*1000
def gene(value):
    """The result as Gene prints it, so run_kernels.gene can compare it with
    Gene's exactly."""
    if isinstance(value, list): return "[" + " ".join(gene(v) for v in value) + "]"
    if isinstance(value, str): return '"' + value + '"'
    return str(value)
def report(name, start, result): print(f"{name}\t{now()-start:.0f}\t{gene(result)}")

def fib(n): return n if n < 2 else fib(n-1) + fib(n-2)
def bench_fib(): return fib(30)

def bench_while(n):
    i = 0; total = 0
    while i < n:
        total = total + (i * 7) % 13
        i = i + 1
    return total
def bench_for_range(n):
    total = 0
    for i in range(0, n): total = total + i
    return total
def bench_list(n):
    xs = []
    for i in range(n): xs.append(i * 2)
    total = 0
    for i in range(n): total = total + xs[i]
    return total
def bench_list_for(n):
    xs = []
    for i in range(n): xs.append(i * 2)
    total = 0
    for x in xs: total = total + x
    return total
def bench_map(n):
    m = {}
    for i in range(n): m[f"k{i % 1000}"] = i
    total = 0
    for i in range(n): total = total + m[f"k{i % 1000}"]
    return total
class Pt:
    __slots__ = ("x", "y")
    def __init__(self, x, y): self.x = x; self.y = y
def bench_field(n):
    p = Pt(1, 2); total = 0
    for i in range(n):
        p.x = p.x + 1
        total = total + p.x + p.y
    return total
def bench_alloc(n):
    total = 0
    for i in range(n):
        p = Pt(i, 2)
        total = total + p.x
    return total
class Counter:
    def __init__(self, n): self.n = n
    def inc(self, d): self.n = self.n + d
    def value(self): return self.n
def bench_send(n):
    c = Counter(0)
    for i in range(n): c.inc(1)
    return c.value()
def make_adder(k): return lambda x: x + k
def bench_closure(n):
    add = make_adder(3); total = 0
    for i in range(n): total = add(total)
    return total
def bench_str(n):
    last = ""; total = 0
    for i in range(n):
        last = f"item-{i}-{i*2}"
        total = total + 1
    return [total, last]
def bench_float(n):
    x = 0.0
    for i in range(n): x = x * 0.999 + 1.5
    return x
def bench_map_literal(n):
    total = 0
    for i in range(n):
        m = {"a": i, "b": 2}
        total = total + m["a"] + m["b"]
    return total

def make_records(n): return [{"id": i, "name": "item", "amount": i * 3} for i in range(n)]
def items_of(state): return state["items"]
def bench_accessor(n, state):
    total = 0
    for i in range(n): total = total + len(items_of(state))
    return total
def bench_store(n, state):
    m = {}
    for i in range(n): m["last"] = items_of(state)
    return len(m["last"])
def len_typed(xs: list[int]) -> int: return 1
def bench_list_param(n, xs):
    total = 0
    for i in range(n): total = total + len_typed(xs)
    return total
def bench_field_write(n):
    p = Pt(1, 2)
    for i in range(n): p.x = i
    return p.x
def add_t(a: int, b: int) -> int: return a + b
def bench_typed_call(n):
    total = 0
    for i in range(n): total = add_t(total, 1)
    return total

t = now(); report("fib30", t, bench_fib())
t = now(); report("while_arith_3M", t, bench_while(3000000))
t = now(); report("for_range_3M", t, bench_for_range(3000000))
t = now(); report("repeat_3M", t, bench_for_range(3000000))
t = now(); report("list_push_index_1M", t, bench_list(1000000))
t = now(); report("list_push_for_1M", t, bench_list_for(1000000))
t = now(); report("map_strkey_500k", t, bench_map(500000))
t = now(); report("field_rw_2M", t, bench_field(2000000))
t = now(); report("alloc_record_1M", t, bench_alloc(1000000))
t = now(); report("send_2M", t, bench_send(2000000))
t = now(); report("closure_2M", t, bench_closure(2000000))
t = now(); report("str_interp_500k", t, bench_str(500000))
t = now(); report("float_3M", t, bench_float(3000000))
t = now(); report("map_literal_1M", t, bench_map_literal(1000000))
state = {"items": make_records(10000), "name": "s"}
t = now(); report("accessor_10k_records_200k", t, bench_accessor(200000, state))
t = now(); report("store_10k_records_200k", t, bench_store(200000, state))
ints = list(range(1000))
t = now(); report("typed_list_param_1k_500k", t, bench_list_param(500000, ints))
t = now(); report("field_write_2M", t, bench_field_write(2000000))
t = now(); report("typed_call_3M", t, bench_typed_call(3000000))

# Benchmarks

Run the recursive Fibonacci benchmark with:

```bash
benchmarks/scripts/bench_fib       # defaults to fib(28)
benchmarks/scripts/bench_fib 28
benchmarks/scripts/bench_fib_typed 30
```

Run the call burst benchmark with:

```bash
benchmarks/scripts/bench_call_burst             # defaults to 10000 x 1000 calls
benchmarks/scripts/bench_call_burst 1000 100
```

The current implementation has a bytecode VM but not the old native compiler
mode, so `GENE_BENCH_MODE` currently supports only `vm`. The benchmark compiles
the Gene source once and times VM execution.

## Fibonacci

The benchmarked Gene program is:

```gene
(var fib (fn [n]
  (if (< n 2)
    n
    (+ (fib (- n 1)) (fib (- n 2))))))
(fib 28)
```

`fib(28)` performs 1028457 naive recursive `fib` calls and returns `317811`.

The default benchmark annotates the recursive function as `Int -> Int`, so
typed call-boundary and recursive dispatch fast paths are visible in perf runs.
Pass `24` for the shorter historical 150049-call sample.

## Call Burst

The call burst benchmark compiles three source units once, then measures tight
bursts of zero-arg, one-arg, and four-arg function calls inside a `while` loop.

# Benchmarks

Run the recursive Fibonacci benchmark with:

```bash
benchmarks/scripts/benchme       # defaults to fib(24)
benchmarks/scripts/benchme 28
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
(fib 24)
```

`fib(24)` performs 150049 naive recursive `fib` calls and returns `46368`.

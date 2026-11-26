# Fakes

Fences that are not uses of a name.

## Shell

```sh
gene run body
```

## Output

```text
body
```

## Send

```gene
(x .body 1)
```

## Bindings

```gene
(let body [1])
(fn tag [^attrs... body...] [attrs body])
(macro unless [condition body...] (quote nil))
```

## Match

```gene
(match [1 2] when [first rest...] (quote rest))
```

## Interpolation

```gene
(let n 1)
$"n=${n}"
```

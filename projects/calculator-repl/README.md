# Calculator REPL

A compact interactive calculator implemented in Verona. It uses the separate
[`libc`](../libc/) project for its POSIX `getchar`, `write`, and `memset`
bindings. Its reusable evaluator is constrained by `base:numeric` and
`base:equality`, so the `+`, `-`, `*`, `/`, and `=` operators resolve through
the base protocol layer.

Build it from this directory:

```sh
verona build calculator ./dist
./dist/calculator
```

Enter one compact, single-digit expression at each prompt:

```text
calc> 3+4
07
calc> 9*9
81
calc> 8/2
04
```

Results are printed as two decimal digits. End the session with Ctrl-D.
Division by zero and unsupported operators produce `00`.

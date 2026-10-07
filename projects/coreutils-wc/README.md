# Verona `wc`

A Verona port of the default standard-input mode of GNU/POSIX `wc`. It emits
the usual line, word, and byte counts:

```sh
verona build wc ./dist
printf 'one two\nthree\n' | ./dist/wc
# 2 3 14
```

The program treats the POSIX word separators (space, tab, newline, vertical
tab, form feed, and carriage return) as whitespace. It is intentionally
streaming: it counts one input byte at a time and holds no input buffer.

For now, the executable covers only standard input and the default three
counters. Its `main` receives the standard `argc`/`argv` pair, so options and
file operands now have a source-level representation; this initial port does
not parse them yet.

This is still a useful compiler stress test: C ABI calls, product values,
pattern matching, recursive tail calls, arithmetic and narrowing conversions,
and unbuffered terminal output all appear in one compact project.

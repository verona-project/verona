# Verona `wc`

A Verona port of GNU/POSIX `wc`. It emits the usual line, word, and byte
counts for standard input or one or more file operands:

```sh
verona build wc ./dist
printf 'one two\nthree\n' | ./dist/wc
# 2 3 14

printf 'one two\nthree\n' | ./dist/wc -l -c
# 2 14

./dist/wc README.md src/wc.vrn
# ... README.md
# ... src/wc.vrn
# ... total
```

The program treats the POSIX word separators (space, tab, newline, vertical
tab, form feed, and carriage return) as whitespace. It is intentionally
streaming: it counts one input byte at a time and holds no input buffer.

The program accepts `-l`/`--lines`, `-w`/`--words`, and `-c`/`--bytes`.
Specify more than one switch to select multiple counters; with no switches it
prints all three. Options precede file operands; `--` ends option parsing, and
`-` reads standard input as a named operand. Multiple input operands receive a
final `total` line. Combined short options such as `-lwc` are not supported.

This is still a useful compiler stress test: C ABI calls, product values,
pattern matching, recursive tail calls, arithmetic and narrowing conversions,
and unbuffered terminal output all appear in one compact project.

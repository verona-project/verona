# Verona formatter

`verona-fmt` is a source formatter written in Verona and built on Foundation.
It reads one file or standard input, preserves every lexeme, and writes formatted
source to standard output. It also supports a check mode for CI and editors.

```sh
make formatter
./build/formatter/verona-fmt projects/formatter/src/formatter.vrn
./build/formatter/verona-fmt --check projects/formatter/src/formatter.vrn
./build/formatter/verona-fmt --width 80 < input.vrn
make test-formatter
```

Build directly from this package with the existing development environment:

```sh
../../build/verona build verona-fmt ../../build/formatter
```

## Command line

```text
verona-fmt [--check] [--width 20..240] [--] [FILE|-]
```

Omitting FILE, or supplying `-`, reads stdin. `--` ends option parsing, allowing
an option-shaped filename. `--help` prints usage without reading input.

- Normal mode writes only complete, successfully formatted source to stdout.
- `--check` emits no source: exit 0 means already formatted; exit 1 means layout
  differs. Differences are reported on stderr.
- Invalid arguments, input, allocation failures, and I/O errors return 2 and
  report a diagnostic on stderr. Source positions use one-based byte columns;
  CRLF is treated as one line ending in diagnostics.

This version accepts one input and never overwrites it. `--write`, multiple-file
traversal, and configuration files are not implemented. Do not redirect output
over the input path: the shell can truncate it before the formatter reads it.

## Layout policy

The initial policy uses two-space indentation and a default soft width of 100
bytes. Widths from 20 through 240 are supported. Short lists remain inline;
long lists break at form boundaries. Function/macro/protocol implementations
and named tests place their bodies on subsequent lines. `let` and `match` retain
their header expressions. Anonymous lists use one-space continuation indentation.

Top-level forms have a blank line between them, while consecutive direct imports
stay together. Comments remain attached inline or standalone as appropriate.
Nonempty output ends with a newline; empty/layout-only input becomes empty output.
Outside literal lexemes, line endings normalize to LF.

The width is soft: indivisible tokens, preserved comments, literal line breaks,
and deeply nested prefixes can exceed it. Width is measured in bytes rather
than Unicode display cells. Comments, character spellings, numeric spellings,
string escapes, and literal contents are preserved byte for byte. The formatter
does not normalize Unicode or rewrite code.

For example:

```lisp
; Input: (base:function main () exit-code (+ 1 2))
(base:function main () exit-code
  (+ 1 2))
```

## Architecture and library API

Base remains unchanged while direct operator dispatch is deferred for review.
The formatter uses the temporary `foundation.compat.arithmetic` and
`foundation.compat.signed_arithmetic` shims provided by the Foundation project.

All formatting algorithms are Verona code. Foundation provides checked storage,
Data, Array specialization, UTF-8 validation, and a segmented arena. Existing
libc bindings provide descriptor I/O; the platform-specific errno accessor is
isolated in `formatter.io.vrn`. No compiler changes or C formatting implementation
are required.

- `formatter.lexer.vrn` preserves token spans, comments, character literals,
  quotes/backquotes/commas, and both sides of feature conditionals.
- `formatter.parser.vrn` builds a concrete syntax tape with subtree boundaries
  and cached flat widths. It never evaluates macros or selects reader features.
- `formatter.layout.vrn` applies layout rules; `formatter.writer.vrn` bounds
  output storage and retains literal text.
- `formatter.model.vrn` defines shared status/tape types and static iteration
  macros. Divided iteration budgets keep stack depth bounded without relying
  on pointer-bearing tail-call optimization.
- `formatter.vrn` stages output transactionally; `formatter.io.vrn` handles
  partial reads/writes, EINTR, and geometric input-buffer reservation.
- `formatter.cli.vrn` parses arguments and reports errors/check differences.

Reusable entry point:

```lisp
(formatter:format source-view width (& destination-data) workspace-allocator)
```

Initialize destination Data with its desired allocator. Success replaces its
contents and transfers ownership of the new buffer into that descriptor; failure
preserves it. Source may borrow the destination because all rendering happens
before commit. Workspace allocations use a local arena and are destroyed before
return. Output owns independent storage associated with the destination allocator.

The result is `formatter.model:status`: success, syntax error with offset/message,
allocation error, I/O error, or a size/depth limit. Public formatting validates
UTF-8, literal boundaries, character names, prefixes, and balanced lists; it does
not type-check, resolve names, or replace the compiler's complete validation.

Limits are 16 MiB input, 64 MiB output, 256 levels of list/prefix nesting,
and 127 command-line arguments (excluding the executable name).
The application currently inherits Foundation's 64-bit Darwin/Linux POSIX target
assumptions. Native verification was performed on Darwin; Linux reader-feature
selection is checked, but a Linux executable has not been run here.

## Verification

`make test-formatter` runs 63 independently named Verona unit tests, CLI/stress
tests, and a separate compiler-reader equivalence test for each bundled Verona
source/build file. Golden tests also compare the complete lexeme sequence and
format their output again to check idempotence. Tests use `testing:checks` for
expression-level aggregation.

Coverage includes comments and reader prefixes, character literals containing
parentheses/semicolons/quotes, escape preservation, scalar-valid UTF-8, malformed
input, allocation failures, transactional destination preservation, destination
aliasing, stdin/files, flags, exit codes, and line/column diagnostics. Stress
cases include million-byte whitespace, 100,000-byte atoms/comments/strings,
50,000 list elements, 20,000 comments after a quote, deep nesting, read boundaries,
and the input-size limit.

The corpus tests compare the actual compiler reader's data before and after
formatting with no features, Darwin features, and Linux features. Each file is
also tested for idempotence and a successful `--check` of its formatted output.
The application's own new Verona files are formatted with `verona-fmt`.

Large-input testing also prompted Foundation improvements: Data can reserve
capacity without changing its length, and byte/array copies, Data zero-fill and
equality, and UTF-8 validation use bounded-depth traversal. Their existing tests
and additional reserve/Unicode regression tests run through `make test-foundation`.

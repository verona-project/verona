# Verona

![Verona logo](assets/calico.png)

Verona is a statically typed systems programming language with an S-expression
syntax. It compiles ahead of time through LLVM and supports product and sum
types, pattern matching, generic dispatch, protocols, compile-time macros, and
native-library output.

## About

The language is designed to keep programs structurally simple without giving
up explicit types or native performance. Its source forms are readable as data,
which makes macros a natural part of the language, while the compiler carries
source locations through analysis for useful diagnostics.

Verona currently targets Darwin and Linux hosts supported by its LLVM and
native-toolchain setup. The standalone `verona` command can compile an
executable, object file, static library, or shared library.

## Example: most of the language in one program

This small program uses a product type, a sum type, construction and field
access, pattern matching, local bindings, a generic with an implementation,
and a protocol constraint:

```lisp
(type point (product (x i32) (y i32)))

(type option (sum (none) (some i32)))

(generic add (left right))

(implementation add ((left i32) (right i32)) i32
  (+ left right))

(protocol measurement (a)
  (measure ((value a)) i32))

(implementation (measurement i32)
  (function measure ((value i32)) i32
    value))

(function report
  (for (a)
    ((measurement a)))
  ((value a))
  i32
  (measure value))

(function unwrap ((value option)) i32
  (match value
    ((none) 0)
    ((some number) number)))

(function main () exit-code
  (let ((origin point (point 40 2))
        (value option (some (add (field origin x) (field origin y)))))
    (report (unwrap value))))
```

The program returns `42`. For smaller runnable examples, including arithmetic,
bindings, matching, products, sums, generics, and protocols, see
[`examples/`](examples/) and [its guide](examples/README.md).

Text literals use familiar source syntax: `"hello"` has type `(pointer u8)`
and is a NUL-terminated `char*`; `#\\a` is a one-byte `char` (with named forms
such as `#\\space` and `#\\newline`). Use C's `strlen` when a string length is
needed.

Use `;` for a source comment through the end of its line.

## Architecture

The compiler is organized as a reusable front end, an LLVM backend, and a
thin native driver:

```text
Verona source
  → source-aware reader and syntax
  → top-level macro expansion and declaration collection
  → semantic type resolution and specialization
  → LLVM IR generation and verification
  → object emission and the host linker or archiver
```

The front end keeps source forms and expanded syntax attached to declarations.
It processes top-level forms in order, so a macro can affect later forms, then
resolves the complete declaration set before lowering. The LLVM backend turns
the resolved program into target-specific IR. Finally, the compiler driver
selects a target, emits an object, and asks the host toolchain to create the
requested native artifact.

The `verona` executable is deliberately a small wrapper around the reusable
`verona.compiler:compiler-driver` API. This keeps source analysis independent
of linking policy and makes the front end suitable for embedding.

## Getting started

Enter the Nix development shell, then run the test suite:

```sh
make test
```

Build the self-contained command-line executable with SBCL's runtime bundled
into the image:

```sh
make build
```

This creates `build/verona`. The build must run from the Verona development
shell because it uses the configured LLVM bindings. You can then install it,
for example:

```sh
install -m 755 build/verona /usr/local/bin/verona
```

Compile a program or produce a library with:

```sh
verona compile src/app.vrn -o app
verona compile src/lib.vrn --emit static-library -o libverona.a
verona compile src/lib.vrn --emit shared-library -o libverona.dylib
```

Executables may use either `(function main () exit-code ...)` or
`(function main ((argc i32) (argv (pointer (pointer u8)))) exit-code ...)`.
The latter receives the platform's C-style argument count and vector; use
`(deref (pointer-offset argv index))` to read an argument pointer.
Object files, static libraries, and shared libraries do not require `main`.
`-L`, `-l`, and `--framework` pass native linker inputs through the driver;
frameworks are Darwin-only.

Verona-module visibility is separate from native visibility. Expose a function
to C with an explicit top-level declaration:

```lisp
(function add ((a i32) (b i32)) i32 (+ a b))
(native-export add) ; optional second argument: "c_symbol_name"
```

Native exports currently accept the scalar and pointer types supported by
`external-function`; products, sums, and `unit` are outside the C ABI.

## Declarative builds

`verona.build` describes native artifacts without evaluating Verona code. The
output directory belongs to the invocation, not the build file:

```lisp
(executable app
  (root app.main)
  (module-path "src")
  (optimize 2)
  (library "sqlite3"))
```

```sh
verona build app ./dist/bin
```

Top-level `static-library` and `shared-library` declarations use the same
options. Build files may also declare target triples, native library paths,
and Darwin frameworks. Relative module and library paths are resolved from the
directory containing `verona.build`.

For the complete source-language, Common Lisp, LLVM, compiler-driver, and
declarative-build reference, see [the API documentation](docs/API.md).
The planned language and tooling work is described in the
[roadmap](docs/ROADMAP.md).

## Editor support

An Emacs major mode is included at
[`editors/emacs/verona-mode.el`](editors/emacs/verona-mode.el).  Add that
directory to `load-path` and load the mode from your Emacs configuration:

```elisp
(add-to-list 'load-path "/path/to/verona/editors/emacs")
(require 'verona-mode)
```

It automatically selects itself for `.vrn`, `.verona`, and `verona.build`
files, and provides Verona-aware font locking and Lisp-style indentation.

## License

Verona is released under the [Unlicense](license): it is free and
unencumbered software dedicated to the public domain, to the extent permitted
by law. See [`license`](license) for the complete dedication and warranty
disclaimer.

## Why “Verona”?

The name is inspired by Verona, the city in Italy—and by Verona, one of the
author's cats.

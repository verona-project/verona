# Verona

![Verona logo](assets/github-banner.png)

## About

Verona is a statically typed systems programming language with S-expression
syntax. It compiles ahead of time through LLVM and supports explicit types,
product and sum types, pattern matching, generic dispatch, protocols,
compile-time macros, native interoperability, and library output.

Source forms are readable as data, making macros a natural part of the language.
The compiler preserves source locations through analysis and native code
generation so diagnostics can point back to the original program.

Verona targets AArch64 and x86-64 on Darwin and Linux.

## Minimal example

```lisp
(import base)

(base:function main () exit-code
  (+ 20 22))
```

The program returns `42` as its process status. Use `;` for a source comment
through the end of the line.

## How to compile

With `verona` on `PATH`, save the example as `hello.vrn` and run:

```sh
verona check hello.vrn \
  --module-path projects/base/src \
  --module-path projects/foundation/src \
  --module-path projects/libc/src

verona compile hello.vrn -o hello \
  --module-path projects/base/src \
  --module-path projects/foundation/src \
  --module-path projects/libc/src

./hello
echo $?
# 42
```

The repository's pinned LLVM 23 environment is available through Nix:

```sh
nix develop --offline path:.
```

## Command line options

```text
verona {read|check|eval|emit-llvm} FILE [OPTIONS]
verona {compile|compile-report} FILE [OPTIONS]
verona build TARGET OUTPUT-DIRECTORY [--feature NAME ...]
verona {--version|-V}
```

Source commands accept:

- `--module-path DIRECTORY` — add a module search root;
- `--feature NAME` — add a reader feature; and
- `--target TRIPLE` — select an LLVM target triple instead of the native target.

Compilation additionally accepts:

- `-o OUTPUT` or `--output OUTPUT` — select the output path;
- `--emit object|executable|static-library|shared-library` — select the artifact;
- `-O0`, `-O1`, `-O2`, or `-O3` — select the code-generation level;
- `--cpu CPU` — select the LLVM target CPU;
- `--features FEATURES` — select LLVM machine features;
- `--library NAME` or `-l NAME` — link a native library;
- `--library-path DIRECTORY` or `-L DIRECTORY` — add a native library path; and
- `--framework NAME` — link a framework on Darwin.

Without an explicit output path, `compile` derives a name beside the source.
Static and shared libraries with native exports also receive a C header.

`read` prints the indexed syntax tree, `check` performs analysis without
execution, `eval` evaluates the checked program, and `emit-llvm` writes LLVM IR.
`compile-report` creates an executable that prints the complete typed result.

The native tools can be selected with `VERONA_CORE_CLANG` and
`VERONA_CORE_AR`, with `VERONA_LINKER` and `VERONA_AR` as fallbacks.

## Manifest files

The `build` command reads `verona.build` in the current directory. A manifest
can declare executables, static libraries, and shared libraries:

```lisp
(executable hello
  (root hello)
  (module-path "src")
  (module-path "../base/src")
  (version "0.1.0")
  (target native)
  (optimize 2))
```

Build the target from the directory containing the manifest:

```sh
verona build hello build
```

The output directory may be relative or absolute. Module and native-library
paths are resolved relative to the manifest. Supported target options include
`root`, repeatable `module-path`, `target`, `optimize`, `version`, `features`,
`library`, `library-path`, and `framework`.

Manifests describe individual artifacts rather than a dependency graph, so
native dependencies must be built before the targets that link them.

## License

Verona is released under the [Unlicense](license): it is free and unencumbered
software dedicated to the public domain, to the extent permitted by law. See
the [license](license) for the complete dedication and warranty disclaimer.

## Why “Verona”?

The name is inspired by Verona, the city in Italy—and by Verona, one of the
author's cats.

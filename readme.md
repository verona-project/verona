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

To rebuild the self-hosted compiler, supply a compatible seed compiler. A
development checkout normally keeps that seed at `build/verona`:

```sh
autoreconf -fi
./configure --with-seed="$PWD/build/verona"
make build
make check
```

`make build` writes the compiler to `build/compiler/verona` and also builds
`verona-formatter` and `verona-project`. `make install` installs all three
tools. For a source release, pass the recorded seed artifact explicitly with
`--with-seed`; configuration rejects a missing seed or a non-LLVM-23 toolchain.

## Command line options

```text
verona {read|check|eval|emit-llvm|optimization-report} FILE [OPTIONS]
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
- `-O0`, `-O1`, `-O2`, or `-O3` — select the optimization level;
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

`optimization-report FILE` runs the checked simplifications during LLVM lowering
without producing a native artifact. It writes deterministic `before-lowering`
and `after-lowering` tape summaries to stdout, and applied-rule remarks with
source locations and checked node IDs to stderr. The tape summaries match:
these passes select existing nodes or values without rewriting the checked tape.
Summaries include kind, type, child/next IDs and source ranges; pointer-bearing
payloads are omitted. Remarks cover constant folding, known branches/matches,
and discarded local bindings actually encountered during lowering. They are
not an inventory of all possible rewrites in unreachable subtrees. Like
`emit-llvm`, this command uses enabled local simplification and accepts source
options, not native output options or `-O` flags. It does not run LLVM passes.

Native compilation at `-O1`, `-O2`, and `-O3` runs LLVM's corresponding standard
optimization pipeline with the configured target machine before object emission.
`-O0` skips LLVM middle-end passes. `emit-llvm` shows IR after Verona's local
simplifications and before LLVM passes; native optimization flags remain specific
to compilation commands. Modules are verified before and after LLVM optimization.

With local optimization enabled, direct self-recursive calls in tail position
are emitted as LLVM `musttail` calls. The supported tail contexts are the final
result of a function, `if` branch, `let` body, or `do` sequence. Calls through
values, mutual recursion, matches, and bodies that use addressable parameters
or locals remain ordinary calls. Arguments still evaluate once from left to
right before the call; `-O0` keeps ordinary recursion. `optimization-report`
emits `self-tail-recursion` only when this lowering is selected.

Optimized native output also removes unreachable internal functions, including
dead recursive groups. A source-level `export` controls Verona module visibility;
it does not keep a native function alive. `native-export` supplies a native entry
point, and callbacks escaping through live code retain callable entry points.
Taking an address only inside unreachable code does not retain it. `%noinline`
prevents inlining but does not keep an unreachable function. All bodies are
checked before elimination, so unused functions still produce checking errors.

The native tools can be selected with `VERONA_CORE_CLANG` and
`VERONA_CORE_AR`, with `VERONA_LINKER` and `VERONA_AR` as fallbacks.

## Inlining controls

Without a directive, a function uses LLVM's automatic inlining policy. Use
independent top-level declarations to request or forbid inlining:

```lisp
(%inline helper)
(%function helper ((value i64)) i64
  (+ value 1))

(%function retained ((value i64)) i64
  (+ value 2))
(%noinline retained)
```

Directives may precede or follow a local function. Identical duplicates are
idempotent; conflicting directives are errors. Targets must be unqualified,
module-local Verona functions with bodies. Parametric functions pass the policy
to their specializations. External declarations and overloaded generic or
protocol declarations are not directive targets. These are declaration policies;
there is no call-site override.

Base provides `base:inline-function` and `base:noinline-function` macros. Each
emits the ordinary `%function` declaration followed by the matching directive.
The function body still follows normal macro expansion and generic dispatch.

At `-O1` through `-O3`, `%inline` bypasses LLVM profitability thresholds using
`alwaysinline`; `%noinline` supplies `noinline`. LLVM legality and recursion
constraints still apply. Remaining direct calls from a forced request produce a
nonfatal source-location remark. `-O0` retains the unoptimized path and reports
forced requests as inactive. `emit-llvm` displays the attributes before LLVM
passes. Native export and callback adapter symbols retain their ABI/identity;
attributes apply to the underlying implementation bodies. `%noinline` prevents
inlining, while other optimizations may still fold calls or delete unused bodies.

Automatic small-function inlining uses the standard LLVM pipeline after Verona's
local simplification and ABI lowering. It adds no `alwaysinline` attribute or
Verona source-size cutoff. LLVM decides profitability at each call site, so a
small source body is not a promise of inlining. Decisions may vary with the
target, optimization level and pinned LLVM version. `optimization-report`
describes local simplification before that pipeline; it does not report LLVM's
automatic inlining decisions.

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

## Project management

The repository also builds `verona-project`, a native tool for creating a
minimal Verona project and listing locally available libraries:

```sh
build/verona-project new my-app
build/verona-project libraries
```

`libraries` reads the absolute directory named by `VERONA_SOURCE_DIR` and
groups its immediate library directories by name and available version. See
`build/verona-project --help` for command usage.

The output directory may be relative or absolute. Module and native-library
paths are resolved relative to the manifest. Supported target options include
`root`, repeatable `module-path`, `target`, `optimize`, `version`, `features`,
`library`, `library-path`, and `framework`.

Manifests describe individual artifacts rather than a dependency graph, so
native dependencies must be built before the targets that link them.

## Formatter

The repository also builds the Verona source formatter. It reads one source file
or standard input and writes formatted source to standard output; `--check`
reports whether formatting would change the input.

```sh
verona-formatter src/core.cli.vrn
verona-formatter --check src/core.cli.vrn
verona-formatter --width 80 < input.vrn
```

## License

Verona is released under the [Unlicense](license): it is free and unencumbered
software dedicated to the public domain, to the extent permitted by law. See
the [license](license) for the complete dedication and warranty disclaimer.

## Why “Verona”?

The name is inspired by Verona, the city in Italy—and by Verona, one of the
author's cats.

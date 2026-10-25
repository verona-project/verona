# Verona

![Verona logo](assets/calico.png)

Verona is a statically typed systems programming language with an S-expression
syntax. It compiles ahead of time through LLVM and supports product and sum
types, pattern matching, generic dispatch, protocols, compile-time macros, and
native-library output. The bundled `base` library supplies numeric, equality,
ordering, and result-directed conversion protocols; the bundled `testing`
library supports Verona-native assertions, fixtures, and runners.

## About

The language is designed to keep programs structurally simple without giving
up explicit types or native performance. Its source forms are readable as data,
which makes macros a natural part of the language, while the compiler carries
source locations through analysis for useful diagnostics.

Verona currently targets Darwin and Linux hosts supported by its LLVM and
native-toolchain setup. The standalone `verona` command can compile an
executable, object file, static library, or shared library.

## Example: most of the language in one program

```lisp
(function main () exit-code
  (+ 1 2))
```

The program returns `3`. For runnable applications and library packages, see
[`projects/`](projects/).

Text literals use familiar source syntax: `"hello"` has type `(pointer u8)`
and is a NUL-terminated `char*`; `#\\a` is a one-byte `char` (with named forms
such as `#\\space` and `#\\newline`).

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
resolves declaration signatures and type-checks executable bodies before
lowering. The LLVM backend turns the resolved program into target-specific IR.
Finally, the compiler driver selects a target, emits an object, and asks the
host toolchain to create the requested native artifact.

The `verona` executable is deliberately a small wrapper around the reusable
`verona.compiler:compiler-driver` API. This keeps source analysis independent
of linking policy and makes the front end suitable for embedding.

## Getting started

Install the build prerequisites using your preferred package manager or local
toolchain setup:

- SBCL with ASDF, and Bash for the server launcher.
- LLVM 23, Clang, and `llvm-ar`, with LLVM's shared libraries available to SBCL.
- The bundled CL-LLVM bindings and their Common Lisp dependencies available to
  ASDF. The bindings are pinned as the `vendor/CL-LLVM` Git submodule from
  [verona-project/CL-LLVM](https://github.com/verona-project/CL-LLVM).
- Autoconf, Automake, and Make.

Initialize the submodule from the repository root (or clone Verona with
`git clone --recurse-submodules`), then set the bindings directory:

```sh
git submodule update --init --recursive
export VERONA_CL_LLVM="$PWD/vendor/CL-LLVM"
```

Use the recorded submodule commit when updating a checkout; the fork's default
branch may target a different LLVM version.

From the repository root, bootstrap and configure the Autotools build. Generated
Autotools files are not committed, so this is required from a Git checkout:

```sh
autoreconf -fi
./configure
```

`configure` locates SBCL, `clang`, and `llvm-ar` on `PATH`. Use
`--with-linker=PATH` and `--with-archiver=PATH` to select explicit tool paths.

> **Optional Nix environment:** If you use Nix 2.27 or later with flakes enabled, run
> `nix develop` from the repository root before the commands above. The provided
> shell supplies the pinned LLVM bindings, SBCL dependencies, and native
> toolchain, and sets `VERONA_CL_LLVM`, `VERONA_LINKER`, and `VERONA_AR`.

Build the standalone command-line executable with SBCL's runtime bundled into
the image:

```sh
make build
```

This creates `build/verona`, `build/verona-server`,
`build/project/verona-project`, and `build/formatter/verona-fmt`. The compiler executable
bundles SBCL; the server launcher uses an SBCL executable from its environment.
Run the full test suite with:

```sh
make test
```

To install the command, configure the desired prefix (default: `/usr/local`)
and run `make install`. This installs `verona`, `verona-project`, `verona-fmt`, and the `verona-server`
Bash launcher side by side in `PREFIX/bin`. The launcher embeds its Lisp entry point;
no separate server Lisp file is installed:

```sh
./configure --prefix=/path
make install
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

## Create a project

Use the separate `verona-project` tool (installed alongside Verona) to create an
executable project. It is written in Verona; from a checkout, run `make project`
and use `build/project/verona-project new NAME`:

```sh
verona-project new my-app
cd my-app
verona build my-app ./build
./build/my-app
```

This creates `verona.build`, `src/main.vrn`, `README.md`, and `.gitignore`.
The starter program returns exit code zero and needs no external packages.
Names start with a letter and contain only ASCII letters, digits, `-`, or `_`.
The destination must not already exist. Run `verona-project --help` to list
project management commands.

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

## Bundled tutorials and libraries

Run the package-environment tutorial from the repository root with:

```sh
make bootstrap
```

It checks `VERONA_SOURCE_DIR` and `VERONA_LIBRARY_DIR`, explains the required
Bash `export` commands, and prints the Verona website and repository links.
For Verona programs, import [`projects/base/`](projects/base/) instead of using compiler-internal
`%` operations directly. Its `numeric`, `equality`, and `ordering` protocols
provide `+`, `-`, `*`, `/`, `=`, `<`, `<=`, `>`, and `>=`; `base:convert`
performs an explicit numeric conversion whose destination type is inferred from
context. The [`projects/testing/`](projects/testing/) package adds assertions,
named tests, runners, fixtures, and typed function-pointer test callbacks.

The [Foundation package](projects/foundation/README.md) adds explicit allocators,
arenas, UTF-8 strings, binary data, checked numeric/time utilities, and statically
specialized collections. Run `make test-foundation` for its native suite.

The [Verona formatter](projects/formatter/README.md) is a Foundation-based native
application. Build it with `make formatter`; run `make test-formatter` for its
unit, command-line, and compiler-reader equivalence suites.

For the complete source-language, Common Lisp, LLVM, compiler-driver, and
declarative-build reference, see [the API documentation](docs/API.md).
The planned language and tooling work is described in the
[roadmap](docs/ROADMAP.md).

## Editor support

The included `verona-mode` provides syntax highlighting and Lisp-style
indentation for `.vrn`, `.verona`, and `verona.build` files. The optional
`verona-ide` integration adds SLIME sessions, explicit module evaluation,
completion, Eldoc, Xref, Flymake diagnostics, inspection, and project build/run
commands. Emacs 28.1 or later and an installed SLIME package are required for
the IDE integration.

```elisp
(add-to-list 'load-path "/absolute/path/to/verona/editors/emacs")
(require 'verona-mode)
(require 'verona-ide)
(setq verona-server-directory "/absolute/path/to/verona")
```

Configure the server environment using the [Emacs setup guide](editors/emacs/README.md),
then use this workflow:

1. Run `M-x verona-help` to inspect the environment and launcher checklist.
2. Run `M-x verona-start-server` and wait for the readiness message.
3. Run `M-x verona-open-project` and select a folder with `verona.build` and a target.
4. Use `C-c C-e` to analyze a module and its dependencies, including unsaved
   buffers. Use `verona-ide-build` or `verona-ide-run` to build saved files.
5. Run `verona-close-project` to release the project session, then
   `verona-stop-server` to shut down the managed server.

Startup, project opening, edits, saves, and queries never trigger evaluation or
builds. Analysis diagnostics appear through Flymake and
`verona-ide-project-diagnostics`; build and run results appear in separate
`*Verona build*` buffers. The [Emacs guide](editors/emacs/README.md) covers
configuration, targets, reconnecting, and troubleshooting.

## License

Verona is released under the [Unlicense](license): it is free and
unencumbered software dedicated to the public domain, to the extent permitted
by law. See [`license`](license) for the complete dedication and warranty
disclaimer.

## Why “Verona”?

The name is inspired by Verona, the city in Italy—and by Verona, one of the
author's cats.

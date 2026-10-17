# Verona contributor guide

## Project overview

Verona is a statically typed systems-programming language with an S-expression
syntax.  Its compiler is written in Common Lisp, lowers resolved Verona
programs through LLVM, and can emit executables, object files, static
libraries, and shared libraries.

The compiler pipeline is:

```text
Verona source → reader and syntax → macro expansion and declaration collection
→ semantic resolution and specialization → LLVM IR → native artifact
```

Read [`readme.md`](readme.md) for the language overview and
[`docs/API.md`](docs/API.md) for the detailed language, compiler, and build
reference.

## Repository map

- `src/`: Common Lisp implementation of the reader, semantic analysis,
  compiler frontend, LLVM backend, and compiler driver.
- `src/backend/llvm/`: LLVM lowering, target setup, IR generation, and C-header
  generation.
- `src/driver/`: CLI, package environment handling, and declarative build-file
  support.
- `tests/`: FiveAM frontend, LLVM integration, compiler-driver, native ABI, and
  invalid-program tests.
- `projects/`: runnable Verona packages, including the bootstrap tutorial and
  testing-library smoke suite.
- `docs/`: API reference and roadmap.
- `scripts/build-executable.lisp`: builds the standalone `verona` executable.
- `verona.asd`: ASDF system definitions and component ordering.

## Development environment

Use the repository's Nix development shell when working on LLVM-backed builds
or tests. It provides the pinned LLVM Common Lisp bindings and sets
`VERONA_CL_LLVM` for the LLVM and compiler-driver test runners.

Bootstrap the Autotools build once per checkout with `autoreconf -fi` followed
by `./configure` before running the commands below.

The frontend test runner loads FiveAM through Quicklisp and expects
`~/quicklisp/setup.lisp` to exist. Do not change test setup to depend on a
developer's unpinned local LLVM installation.

## Common commands

Run commands from the repository root:

```sh
make test          # Run every test runner
make test-frontend # Frontend and module-semantic FiveAM suite
make test-llvm     # LLVM backend integration suite
make test-compiler # Compiler-driver, CLI, and declarative-build suite
make test-verona   # Build and run the Verona testing-library smoke project
make build         # Build build/verona
make install       # Install verona under the configured prefix
make bootstrap     # Build and run the bootstrap tutorial
```

Run `make test-frontend` for frontend changes. Run `make test-llvm` for
changes to semantic output, LLVM lowering, or native emission. Run
`make test-compiler` for compiler-driver, CLI, or declarative-build changes.
`make test` runs every suite; use it as the broad final check. Run
`make test-verona` when changing the bundled testing package or its
integration with the driver.

## Implementation guidance

- Preserve the component order in `verona.asd`: systems are serial and later
  files may depend on earlier ones.
- Keep source locations attached to syntax and declarations when extending the
  reader, macro expansion, or semantic phases; diagnostics rely on them.
- Update both [`docs/API.md`](docs/API.md) and the
  [`site/manual/`](site/manual/) reference when changing Verona syntax or
  semantic behavior. Update the site landing page too when its language
  overview would otherwise become inaccurate.
- Treat the compiler frontend and native driver as separate layers. Keep native
  linking and artifact-policy decisions in `src/driver/`, not in reusable
  frontend code.
- Add or update focused FiveAM tests under `tests/` with every behavior change.
  Keep invalid-program fixtures and their `.expected` diagnostics aligned.
- Prefer Verona's `base` protocols in `.vrn` programs rather than compiler
  internals. Extend `projects/base/` alongside compiler support when a language feature
  needs library-level behavior.
- Keep projects and their build files runnable. They serve as user-facing
  regression coverage and documentation.
- Do not commit generated artifacts from `build/`.

## Scope-based verification

| Change area | Minimum verification |
| --- | --- |
| Reader, syntax, macros, resolver, or semantic analysis | `make test-frontend` |
| LLVM backend, ABI, or native code generation | `make test-llvm` |
| Compiler driver, CLI, or declarative builds | `make test-compiler` |
| Standalone executable or package environment | `make build` |
| `projects/testing` or Verona test runner | `make test-verona` |
| `projects/base/` or another project package | Relevant command plus the affected project |

Before handing off a change, run the narrowest relevant tests first, then the
appropriate broader command above. Report any verification that cannot run due
to missing Quicklisp, Nix, LLVM, or host-toolchain prerequisites.

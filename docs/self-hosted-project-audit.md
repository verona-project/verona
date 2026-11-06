# Self-hosted project audit

Inside the pinned Nix development shell, select an existing self-hosted compiler:

```sh
make test-self-hosted-projects SELF_HOSTED_COMPILER=/absolute/path/to/verona-core
```

The command never bootstraps a compiler or falls back to the Common Lisp driver.
Choose a compiler from a successful self-hosting run or a subsequently verified
self-hosted rebuild. The report identifies the selected binary by path and
SHA-256; selection alone does not prove its origin. This audit complements the
A/B/C reproducibility gate and does not repeat its byte comparison.

Each invocation creates a new `build/self-hosted-projects/run-*` directory.
`REPORT.md` summarizes target results; `results.json` retains the inventory,
policy, compiler hash, Git and submodule state, copied source hashes, native
tool paths, commands, input, output, errors, and elapsed times. Individual
command records and native linker/archiver logs remain beside the report.
Failures and timeouts retain evidence as well as successful runs.

`SELF_HOSTED_PROJECTS_JOBS` controls concurrent builds (default 2).
`SELF_HOSTED_PROJECTS_OUTPUT` selects the parent evidence directory. For direct
invocation and the per-build timeout, see:

```sh
python3 scripts/self-hosted-projects.py --help
```

The inexpensive runner tests require Python only and also run under `make test`:

```sh
make test-self-hosted-projects-runner
```

## What the audit verifies

The runner copies project source inputs into an isolated tree, preserving their
relative paths and excluding existing build outputs and native artifacts.
It discovers targets through the selected compiler's indexed `read` output,
then invokes `build TARGET OUTPUT-DIRECTORY` from each manifest's directory.
Manifest settings are interpreted by the compiler itself.

Every normal target must produce a fresh native artifact through the selected
compiler and the pinned linker or archiver. Libraries must also produce a C
header that passes a native syntax check. Transparent native-tool wrappers
retain arguments, exit status, and diagnostics. Declared dependencies build
first; a failed dependency blocks its consumers while unrelated builds continue.
The dynamic client uses the freshly built shared library, with native dependency
inspection and the fresh library directory first in its runtime search path.

Runtime checks cover the command-line tools, test executables, a C library
client, LLVM object emission/linking, and the freshly built compiler. The latter
runs six selected manifest/target regression methods and the shared fixture
suite, without requiring the host compiler. The persistent echo server is
explicitly build-only. Intentional negative fixtures must fail in analysis or
native linking with their expected source diagnostic or missing-library error;
an arbitrary nonzero exit is insufficient.

Original source hashes and the selected compiler hash must remain unchanged.
The isolated copy and reports are retained for inspection. The audit uses current
working files, so a passing run on a dirty checkout describes that workspace,
not necessarily its recorded Git commit.

## Adding or changing a target

Update `scripts/self-hosted-projects.json` alongside the project's manifest.
Keys have the form `projects/PACKAGE/verona.build::TARGET`. Each entry declares
the artifact `kind`, isolated `output` directory, and validation `mode`:

- `run`: executable with one or more `checks`.
- `library`: generated-header validation and optional client checks.
- `build-only`: successful build with an explicit `reason` for skipping execution.
- `negative`: expected `failure` phase and identifying diagnostic details.

`depends_on` lists other policy keys that must build first. Outputs must remain
inside the isolated workspace and must not collide. Runtime checks can specify
arguments, input, expected exit status, output, environment, and temporary files;
special checks cover the compiler, formatter, project tool, LLVM object, and C
client. Existing entries show each supported check's configuration.

New targets, removed targets, changed artifact kinds, unknown checks, dependency
cycles, and unsupported artifacts fail validation before builds begin. Review
the policy whenever a target's behavior changes rather than weakening a failing
check. Add runner tests when extending policy behavior or failure handling.

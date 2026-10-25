# Verona IDE for Emacs

## Setup and installation

Emacs 28.1 or later and SLIME are required. Add the checkout's editor directory
to `load-path` and load the integration:

```elisp
(add-to-list 'load-path "/absolute/path/to/verona/editors/emacs")
(require 'verona-mode)
(require 'verona-ide)
(setq verona-server-directory "/absolute/path/to/verona"
      verona-server-environment
      '("VERONA_SOURCE_DIR=/absolute/path/to/verona/projects"
        "VERONA_LIBRARY_DIR=/absolute/path/to/verona/build"))
```

Run `make build` from the configured checkout to create `build/verona` and
`build/verona-server`. `make install` installs both executables at the same
level in `PREFIX/bin`. The default prefix is `/usr/local`, producing
`/usr/local/bin/verona` and `/usr/local/bin/verona-server`. To select it
explicitly, run `./configure --prefix=/usr/local` before installation. A prefix
saved by an earlier configure invocation remains in effect until reconfigured.
The Bash launcher embeds its Lisp entry point; no separate `ide-server.lisp`
is installed. It still needs the configured checkout and development environment.
Run `verona-server --help` for its invocation syntax.

The default `verona-server-command` is `'("verona-server")`. The editor searches
its executable paths, beside a located `verona` binary, common installation
directories, and finally `build/verona-server` under `verona-server-directory`.
Custom commands are used as configured and never replaced by a local fallback.
The launcher uses `sbcl` by default; `VERONA_IDE_SBCL` selects another SBCL
executable for both the server and build workers. SBCL startup options, such as
`--load` followed by a settings file, belong in `verona-server-startup-arguments`.

Initialize the checkout's bindings with `git submodule update --init --recursive`.
For a manually configured server, set `VERONA_CL_LLVM` to the absolute path of
`vendor/CL-LLVM`, using the recorded submodule commit for LLVM 23.

The server environment must provide the pinned `VERONA_CL_LLVM`, native toolchain,
and package paths used for command-line builds. The default command does not
start Nix. Start Emacs from the repository's `nix develop` shell to inherit its
environment, or configure an explicit Nix launcher command:

```elisp
(setq verona-server-command
      '("nix" "develop" "--command"
        "/absolute/path/to/verona/build/verona-server"))
```

Nix runs from `verona-server-directory`. The absolute launcher path also works
before installation. Outside Nix, supply the same pinned LLVM bindings and
compiler/linker environment explicitly.

## Startup checklist

Run `M-x verona-help` to see every environment requirement, effective values,
launcher discovery, setup instructions, and development commands. Values combine
Emacs's inherited environment with `verona-server-environment` overrides.

- `VERONA_SOURCE_DIR` and `VERONA_LIBRARY_DIR` must identify existing, readable
  absolute local directories.
- An explicitly supplied `VERONA_CL_LLVM` must identify an existing readable
  absolute directory containing a readable `llvm.asd`.
- The launcher must be available through discovery or the configured command.

Missing or invalid settings reject startup and open `*Verona help*` with
OK/MISSING/INVALID status. An unset LLVM path is marked CHECK ON START because
an explicit development-shell command can supply it during launch. The server
checks all three environment variables before loading compiler support or Swank.
Press `g` to refresh the checklist after changing settings. Help never starts a
server, evaluates sources, or builds.

Other startup settings are `verona-server-host`, `verona-server-port`, and
`verona-server-startup-timeout`. The default host is `127.0.0.1`; port zero
chooses a free port. Editor and server files must share absolute local paths;
TRAMP is unsupported.

## Developer workflow

1. Run `M-x verona-start-server` and wait for “Verona ready.” Startup is
   asynchronous and repeated start requests reuse the managed process. The
   launcher registers the pinned LLVM bindings and loads project/build support
   and the Swank adapter. Swank comes from the installed SLIME directory to
   keep its version matched to the editor.
2. Run `M-x verona-open-project`, select a folder containing `verona.build`, and
   choose its target. A sole target is selected automatically. The target's root
   module opens, or the editor asks for a source file if it cannot locate it.
3. Use `verona-project-find-file` or ordinary file opening for more source
   buffers. `verona-ide-mode` enables the development commands and shows analysis
   status after `V:` in the mode line. Evaluate explicitly with `C-c C-e`, then
   use the query and build commands below.
4. Run `verona-close-project` to close the current buffer's project/target
   session. It cancels work, stops programs, releases build artifacts, and clears
   editor attachments and session views. Source buffers and unsaved edits remain.
   Other sessions and the server stay available; reopening creates a fresh session.
5. Run `verona-stop-server` to release all remaining sessions and work, disconnect
   SLIME, and stop the managed server. Only the process started by this editor is
   shut down. Output remains in `*Verona server*`.

Startup and project opening never evaluate or build. Each source buffer uses one
selected session. Use `C-u M-x verona-open-project` to name another target while
keeping existing target sessions, or call `(verona-open-project root target)`.
Opening a target's entry file selects that session for the entry buffer; other
attached buffers retain their selection. Project and target sessions keep
independent analysis and build state.

Disconnecting SLIME alone preserves sessions and pending evaluation. After a
socket disconnect, `verona-start-server` reconnects to the managed process;
reopen the project to reattach the remembered session. An already stopped or
crashed managed process can be started again. External servers remain supported
through `slime-connect` and `verona-open-project`.

## Analysis, queries, and inspection

Editing and saving synchronize overlays only. `C-c C-e` explicitly analyzes the
module and its transitive dependencies, including unsaved overlays in attached
buffers and compile-time macro evaluation. It never executes application code.
`C-c C-k` cancels; the mode line reports progress, failed or invalidated analysis,
and unevaluated edits. `M-x verona-ide-refresh` refreshes cached status only.

Use ordinary completion-at-point, Eldoc, and Xref commands. Enable `flymake-mode`
to display cached errors and warnings. Completion fetches asynchronously: invoke
completion again when the first response arrives. Typing a module qualifier's
colon, such as `stdio:`, automatically fetches and offers that import's exported
members. Import aliases are supported, and private definitions are excluded.
Qualified completion uses the current token's bounds even after unevaluated
edits; the candidates still describe cached analysis. Evaluate the module first
so its imports and exports are available. Xref results appear when ready.
Queries report incomplete data and input mismatches; outdated source locations
are withheld. Flymake displays up to 1000 diagnostics for the current module;
the project diagnostic view provides pagination for larger result sets.

Inspection commands: `verona-ide-session` (effective configuration), `verona-ide-modules`, `verona-ide-module`,
`verona-ide-definition`, `verona-ide-related` (implementations and expansion
origins), `verona-ide-expansion`, `verona-ide-expansion-full`, `verona-ide-expansion-analysis`, `verona-ide-type`, and
`verona-ide-project-diagnostics`. Views retain structured metadata, availability,
coverage and truncation flags. Valid locations have source buttons; paginated
views offer a Next page button. `verona-ide-expansion` shows only the cached
first-level macro result in `*Verona Expansion*`.
`verona-ide-expansion-full` follows the outer macro chain in `*Verona Full expansion*`,
stopping at the surface form before bootstrap/compiler lowering. It leaves macros
inside that resulting form unchanged; `verona-ide-expansion-analysis` shows
the before/after forms, steps, and metadata in `*Verona Expansion analysis*`.
The expansion view prints identifiers without quotes and preserves quotes on string literals.
Both commands leave source text unchanged. Expansion output has a 4096-unit server budget.

## Builds and program execution

Managed startup already loads `verona/ide/project` to enable builds. When using
an external server, load that system explicitly. Workers need the same SBCL,
`VERONA_CL_LLVM`, linker and library environment as command-line builds.
`VERONA_IDE_SBCL` can select their SBCL executable.

- `verona-ide-build` offers to save modified project buffers, then builds the
  selected target from a private snapshot of saved sources.
- `verona-ide-run` builds first and runs only its successful host executable.
- `verona-ide-save-and-build` and `verona-ide-save-build-and-run` save project
  buffers before performing those operations.

If modified buffers remain, the editor names them and asks whether to build
saved files while omitting their unsaved changes. Saving and synchronizing these
buffers never evaluate modules. Configure `verona-ide-program-arguments`,
`verona-ide-program-directory`, and `verona-ide-program-environment` for program
execution. Arguments are literal strings; environment entries are `NAME=value`.

Each operation creates a separate `*Verona build*` compilation buffer showing
stages, output, source-linked build diagnostics, the artifact and program exit
status. Analysis diagnostics and evaluation state remain available unchanged.
In that build buffer, use `verona-ide-stop-build`, `verona-ide-stop-program`, or
`verona-ide-program-input` (prefix argument closes standard input afterward).
`verona-ide-release-build` stops processes and deletes that build's snapshot and
artifacts. Closing a view leaves the job available on the server; session close
or expiry releases all of its builds. Results can also be polled through the
server's `:build-status` operation using the build token. These commands replace
the former configurable shell build/run commands.

## Diagnostics and server output

| Operation | Where to look |
| --- | --- |
| Explicit module evaluation | Flymake in source buffers and `verona-ide-project-diagnostics` for cached project diagnostics |
| Project build or run | A separate `*Verona build*` compilation buffer, with source locations when available |
| Startup configuration | `*Verona help*` for the checklist and resolved launcher |
| Server initialization or startup failure | `*Verona server*` for process output |
| Rejected IDE request | The minibuffer; use `verona-ide-last-error` in the originating buffer for the full response |

## Editor verification

Run the editor regression tests with:

```sh
emacs -Q --batch -L editors/emacs -l tests/editor.el -f ert-run-tests-batch-and-exit
```

For real connected lifecycle acceptance, run `make test-editor-live` inside
`nix develop`, setting `EMACS` and `SLIME_DIR` to the installed editor and SLIME
paths. This remains separate from mock transport tests.

For combined compiler/server/editor verification, use `make test-workflows`
(`EMACS=/absolute/path/to/emacs` is supported). The repeatable connected-editor
acceptance walkthrough and coverage map are in
[`docs/IDE-WORKFLOWS.md`](../../docs/IDE-WORKFLOWS.md).

## Troubleshooting

If imported modules are missing, inspect `verona-ide-project-diagnostics` and
`verona-ide-session`. The module browser lists known source/evaluation records,
not every import or package name. For `projects/calculator-repl`, successful
analysis lists `calculator`, `base`, and `libc.types`, `libc.constants`,
`libc.memory`, `libc.string`, `libc.stdio`, `libc.descriptor`.
A session created before project discovery was loaded retains its old settings.
After loading discovery, close the old project with `verona-close-project`, then use
`verona-open-project` to create a **new** project session and evaluate
again. Its single target, `calculator`, is selected automatically. Reconnecting to the old
session does not update its configuration.

If session creation is rejected, the minibuffer shows the server's request error
or compiler diagnostic. Use `M-x verona-ide-last-error` in the originating source
buffer to inspect the full response. Project discovery requires both
`VERONA_SOURCE_DIR` and `VERONA_LIBRARY_DIR` to name absolute package directories
in the **server process** environment; starting Emacs with these variables does
not update an already running Lisp process.

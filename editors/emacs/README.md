# Verona IDE for Emacs

Add `editors/emacs` to `load-path`, install SLIME, and load both
`verona-mode` and `verona-ide`. Emacs 28.1 or later is required.
Configure the checkout and package directories before starting the server:

```elisp
(setq verona-server-directory "/absolute/path/to/verona"
      verona-server-environment
      '("VERONA_SOURCE_DIR=/absolute/path/to/verona/projects"
        "VERONA_LIBRARY_DIR=/absolute/path/to/verona/build"))
```

`verona-start-server` checks the inherited environment together with
`verona-server-environment` overrides before launching. `VERONA_SOURCE_DIR` and
`VERONA_LIBRARY_DIR` must name existing, readable absolute local directories.
An explicitly supplied `VERONA_CL_LLVM` must also contain a readable `llvm.asd`.
Missing or invalid settings reject startup and open `*Verona help*`, listing
all settings, their effective values, and OK/MISSING/INVALID status. An LLVM
path supplied later by Nix is marked CHECK ON START. Use `M-x verona-help` at
any time to see this checklist, setup instructions, and developer commands;
press `g` to refresh it after changing settings. Help never starts a server,
evaluates sources, or builds.
Nix can supply `VERONA_CL_LLVM` during launch; the server checks all three
variables in its actual environment before loading compiler support or Swank.

Use `M-x verona-start-server`. By default it runs the installed `verona-server` Bash launcher
from that checkout, registers the pinned LLVM bindings, and loads project/build
support and the Swank adapter from the installed SLIME package. The checkout's development prerequisites must be available in the server environment. Startup is asynchronous;
wait for “Verona ready” before opening a project. `*Verona server*` retains
initialization output and failures. Repeated start requests reuse the managed
process. Starting the server does not select a project, evaluate or build.

Customize `verona-server-command` (a list of literal executable/arguments),
`verona-server-startup-arguments` (SBCL options, including optional `--load`
settings), `verona-server-environment`, `verona-server-host`,
`verona-server-port`, and `verona-server-startup-timeout` as needed. The default
host is `127.0.0.1`; port zero chooses a free port. The environment must supply the pinned `VERONA_CL_LLVM`, compiler/linker
and package paths. To explicitly launch through Nix, set
`verona-server-command` to `'("nix" "develop" "--command" "verona-server")`.
The launcher uses `sbcl` by default; set `VERONA_IDE_SBCL` to select another
SBCL executable. Before installation, set `verona-server-command` to a list
containing the absolute path to `build/verona-server` after running `make build`.
For the default command, the editor searches its executable paths, beside a
located `verona` binary, common installation directories, and finally
`build/verona-server` under `verona-server-directory`. `verona-help` shows the
resolved launcher path. If none is available, startup opens the checklist with
build/install instructions before launching a process. Custom launcher commands
are used as configured and never replaced by a local fallback.
The server loads Swank through ASDF from the same installed SLIME directory,
avoiding a mismatched Quicklisp Swank version.

Use `M-x verona-open-project`, select a folder containing `verona.build`, and
choose its target (a sole target is automatic). Project discovery reads the
build configuration before attaching buffers. Opening and synchronizing never
evaluate or build. The target root module opens automatically. Use
`verona-project-find-file` for another file; existing source buffers and newly
visited files associate with an opened project. Local paths must be shared
between Emacs and SBCL; TRAMP is unsupported.

Reopening the same project reattaches its session. Use `C-u M-x
verona-open-project` to name another target without closing existing target
sessions, or call `(verona-open-project root target)` from Lisp. Each source
buffer uses one selected session; opening a target's entry file explicitly
selects that session for the entry buffer. Other attached buffers retain their
selection. Independent targets keep separate analysis and build state.

`verona-close-project` explicitly closes the current buffer's project/target
session, cancels its work, stops its programs, and releases its build artifacts.
It clears attached editor state and views while preserving source buffers and
unsaved edits. Other sessions and the server remain available. Reopening creates
a fresh session. Disconnecting SLIME alone preserves server sessions and pending
evaluation. After a dropped connection, `verona-start-server` reconnects the
managed process; reopen the project to reattach its remembered session. An
external server can also be used with `slime-connect` and `verona-open-project`.

`verona-stop-server` releases all remaining server sessions, builds and programs,
disconnects its SLIME connection, and shuts down only the process started by
`verona-start-server`. Unrelated Lisp processes and external servers are never
terminated by this command. Output remains available in `*Verona server*`.
An already stopped or crashed managed process can be started again.

`verona-ide-mode` is enabled in project source buffers; the mode line shows
`V:` followed by analysis status. `C-c C-e` evaluates the current module.
Use `verona-close-project` to close the current project session.
Local editor and server files must share absolute paths; TRAMP is not supported.
Opening a project requires an existing SLIME connection to the configured server.

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
origins), `verona-ide-expansion`, `verona-ide-type`, and
`verona-ide-project-diagnostics`. Views retain structured metadata, availability,
coverage and truncation flags. Valid locations have source buttons; paginated
views offer a Next page button. Expansion output has a 4096-unit server budget.

Load `verona/ide/project` in the server's Nix environment to enable project
build operations. Workers need the same `sbcl`, `VERONA_CL_LLVM`, linker and
library environment as command-line builds. `VERONA_IDE_SBCL` can select the
worker's SBCL executable.

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

`make install` installs `verona` and the executable `verona-server` launcher
at the same level in `PREFIX/bin` (for example, `/usr/local/bin/verona` and
`/usr/local/bin/verona-server`). The launcher embeds its Lisp entry point;
there is no separate `ide-server.lisp` to install. It forwards SBCL startup
options and uses `exec` to preserve process ownership and standard input for
shutdown. It requires the configured Verona checkout and development environment.
For invocation details, run `verona-server --help`.

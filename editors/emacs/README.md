# Verona IDE for Emacs

Add `editors/emacs` to `load-path`, install SLIME, and load both
`verona-mode` and `verona-ide`. Emacs 28.1 or later is required.
Start the optional server as described in the Swank section of `docs/API.md`.
For projects with a `verona.build` file, also load project discovery in the
SLIME server before selecting a session:

Start a fresh Lisp process from `nix develop` in the repository root. After
loading Quicklisp, register the pinned CL-LLVM ASDF file **before** loading the
project system:

```lisp
(require :asdf)
(let ((root (uiop:getenv "VERONA_CL_LLVM")))
  (unless root (error "Start this Lisp process inside nix develop"))
  (let ((directory (uiop:ensure-directory-pathname root)))
    (pushnew directory asdf:*central-registry* :test #'equal)
    (asdf:load-asd (merge-pathnames "llvm.asd" directory))))
(asdf:load-system :verona/ide/project)
```

`VERONA_CL_LLVM` does not register an ASDF system by itself. Register the
Nix directory in `asdf:*central-registry*` as well as loading `llvm.asd`:
ASDF can search again during dependency loading, allowing Quicklisp to replace
a definition loaded only with `load-asd`. The central registry gives the pinned
bindings priority. Check the effective source with
`(asdf:system-source-file (asdf:find-system "llvm"))`; it must point into Nix. If the old bindings have already started loading,
restart Lisp before following these steps. Errors mentioning removed identifiers
such as `LLVMBr` or `LLVMX86_MMXTypeKind` while compiling a Quicklisp
`sellout-CL-LLVM-2019…` path indicate this mismatch.

This uses the compiler development environment (including the pinned LLVM ASDF
setup and `VERONA_SOURCE_DIR`/`VERONA_LIBRARY_DIR` package directories). Project
discovery reads the build target, module paths and target reader features.
The editor requires project discovery and a valid `verona.build` in the selected
root directory. It rejects missing or malformed build files.

Run `M-x slime-connect` once and wait for SLIME to connect. Then use
`M-x verona-open-project` and select the project folder. It reads `verona.build`,
presents its settings, selects a sole target automatically (or asks you to
choose among multiple targets), starts the project session, and opens the
selected target's root module. If that module cannot be located in its module
paths, it asks you to select a file.

Use `M-x verona-project-find-file` to choose another project file, or open it
normally with Emacs. Source buffers inside an opened project automatically
reuse its session, including source buffers that were already open. There is
no session ID to enter for each file. The context outlives individual source
buffers. Reopening a project reuses its session and target. To select a different target,
close the project first; server sessions and caches remain independent.

`verona-ide-mode` is enabled in project source buffers; the mode line shows
`V:` followed by analysis status. `C-c C-e` evaluates the current module.
Use `verona-close-project` to detach all source buffers in the current project.
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

`verona-close-project` releases the project's overlays and editor hooks while
preserving server analysis. To reconnect after a dropped socket, reconnect
SLIME and run `verona-open-project` for the same folder. It reattaches the
remembered session and target, restores buffer synchronization, and resumes
retained request polling. Closing individual source buffers leaves the project
context available. If the server was restarted, close the remembered project
and open it again to create a session on the new server.

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

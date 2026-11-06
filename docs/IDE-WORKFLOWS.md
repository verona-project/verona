# Editor workflow acceptance walkthrough

Use the pinned Nix development shell and the editor setup in
[the Emacs README](../editors/emacs/README.md). The acceptance project is
[`projects/ide-workflow`](../projects/ide-workflow/).

For manual edits, make a disposable copy alongside the original project so
its manifest's `../base/src` path still resolves. If placing the copy elsewhere,
replace that path in every target with the absolute path to this checkout's
`projects/base/src`. Include both the copied `src` directory and Base in any
manually configured analysis search paths.

1. Start the server with `verona-start-server`. Open the disposable project
   with `verona-open-project`, selecting `workflow`.
2. Open `src/main.vrn` and evaluate it with `verona-ide-evaluate`. The imported
   `model` and `leaf` modules should complete analysis. Their surface declarations
   explicitly import Base and use its declaration macros.
3. Run `verona-ide-run`. The saved project should build and exit with status 7
   without output.
4. Change the leaf module to the following, preserving its Base import:

   ```lisp
   (import base)
   (base:function answer () exit-code 9)
   (export answer)
   ```

   Editing does not evaluate the module. Explicitly evaluate it to update
   analysis; saving alone does not replace the evaluated state. Save and run
   with `verona-ide-save-build-and-run`; the program should exit with status 9.
5. Replace the leaf body with `missing-workflow-value` and explicitly evaluate.
   Analysis should fail at that identifier. Restore the saved leaf source and
   evaluate again to clear the failure.
6. Select `analysis-failure`: analysis and build should fail on the unresolved
   `missing-workflow-value` in `src/broken.vrn`.
7. Select `link-failure`: analysis should succeed, while the native linker
   rejects `verona_missing_library_for_workflow_test`. No runnable artifact
   should be offered for either failed build.
8. Select `workflow-library`: the Common Lisp driver should build a static
   library and reject requests to run it. Self-hosted library artifact output
   is tracked separately in the tool-build checklist.

`src/unrelated.vrn` deliberately uses expanded `%function` input without imports.
It provides an independent module for selective-invalidation checks.

Automated coverage lives in `tests/ide-workflows.lisp` (analysis, edits,
recovery, and invalidation), `tests/ide-builds.lisp` (saved snapshots, builds,
runs, and failure phases), and `tests/editor-live.el` (connected editor/server
lifecycle). Run `make test-frontend test-compiler` for compiler and IDE service
coverage, `make test-editor` for editor regression checks, and opt into
`make test-editor-live` with the editor and SLIME paths described in the Emacs
README for connected lifecycle checks.

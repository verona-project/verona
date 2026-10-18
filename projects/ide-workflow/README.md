# Interactive workflow acceptance project

This project is shared by the automated IDE workflow tests and the
[editor acceptance walkthrough](../../docs/IDE-WORKFLOWS.md).

| Target | Expected result |
| --- | --- |
| `workflow` | Builds and exits with status 7, without output |
| `workflow-library` | Builds a static library; cannot be run |
| `analysis-failure` | Analysis and build fail on `missing-workflow-value` |
| `link-failure` | Analysis succeeds; linking fails on a deliberately missing library |

`main` imports `model` as `calc`; `model` imports `leaf` as `values`.
The project includes an imported macro, a generic implementation, a protocol
implementation, and an unrelated module for checking selective invalidation.
It needs no external Verona packages. Native builds require the repository's
pinned Nix toolchain. Editor project discovery additionally requires the package
environment described in the Emacs README.

From this directory, using a compiler built from this checkout:

```sh
../../build/verona build workflow ../../build/ide-workflow
../../build/ide-workflow/workflow
echo $? # 7 is the expected program result, not a build failure
```

Use a disposable copy for edits in the walkthrough. Automated tests change
overlays or temporary copies and leave these sources untouched.

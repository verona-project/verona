# Verona CSV diagnostic formatter

The repository build installs `libverona-csv-diagnostic-format.so` on Linux
and `libverona-csv-diagnostic-format.dylib` on macOS. Select it with
`verona --diagnostic-plugin /path/to/library COMMAND ...`.

The output is CSV on standard error. Its columns are `severity`, `code`,
`path`, `line`, `column`, `message`, and `notes`, in that order. Line and
column coordinates are one-based, and columns count source bytes. Location
fields are empty when a diagnostic has no source location. Notes are joined
with line feeds in the final cell and include their source location when one
is available. Captured native-tool detail is included in the notes cell.
CSV quoting follows the standard doubled-quote convention.

For example, Python's standard CSV reader can select diagnostics by stable
code:

```python
import csv
import sys

for diagnostic in csv.DictReader(sys.stdin):
    if diagnostic["code"] == "type-mismatch":
        print(diagnostic["path"], diagnostic["message"])
```

The plugin implements ABI version 1 from the command-line reference. Its
callback emits the header on the first diagnostic only; a clean invocation
therefore leaves standard error empty.

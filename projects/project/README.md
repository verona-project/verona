# Verona project management

`verona-project` is a standalone native executable written in Verona. It uses
Base protocols and the bundled libc bindings, independently of compiler internals.

From the repository root:

```sh
make project
build/project/verona-project --help
build/project/verona-project new my-app
```

`make install` installs the executable alongside `verona`. The `new` command
creates a minimal executable project and refuses existing destinations,
including symbolic links. Names start with an ASCII letter and contain only
ASCII letters, digits, hyphens, or underscores.

File and directory errors return a nonzero exit status. A failure after creating
the destination can leave a partial project for inspection.

`verona-project libraries` groups immediate directories in `VERONA_SOURCE_DIR`
by library and lists every available version, for example:

```text
base: 1.1.0, 1.2.0
foundation: 0.1.0
```

Directory names use `NAME-MAJOR.MINOR.PATCH`, with optional `-` release or `+`
build suffixes. Names may contain hyphens. Directories without a version suffix
fall back to the `(version "...")` clause on a matching `static-library` or
`shared-library` target in that directory's `verona.build`. Directory versions
take precedence. Missing or unusable version metadata leaves the directory
shown as `(unversioned)` without an asterisk. A version read from the manifest
of an unversioned directory is followed by an asterisk, for example `0.1.0*`. If both
versioned and unversioned directories provide the same version, it appears once
with an asterisk. Manifest reads are limited to files smaller than 1 MiB;
read errors fail the listing. Libraries and version strings are sorted
lexicographically, with repeated versions shown once; this ordering does not
select a preferred version.
Directory symlinks are followed; ordinary files and dangling links are skipped.
An empty source directory produces no output. The variable must name an absolute,
readable directory. Listing, allocation, or output failures return a nonzero exit
status. This reads version metadata without checking library integrity; `VERONA_LIBRARY_DIR` is not required.

Run the command integration tests after building:

```sh
sbcl --script projects/project/tests/run-integration.lisp
```

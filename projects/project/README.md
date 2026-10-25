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

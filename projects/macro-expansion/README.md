# Macro expansion

This project is a runnable macro-expansion example. `define-entry-point`
receives its argument as an ordinary S-expression, builds a `%function` form
with `list`, `symbol`, and `keyword`, and returns that form to the compiler.

Build and run it from this directory:

```sh
verona build macro-expansion ./dist
./dist/macro-expansion
echo $? # 42
```

The project imports the standalone [`base`](../../base/) module explicitly.

# Macro expansion

This project is a runnable macro-expansion application. `application` receives
its body as an ordinary S-expression and returns a `base:function` declaration
for the executable `main` entry point. Its generated body contains
`(exit-status 42)`, demonstrating a second macro expansion in executable
expression position.

Build and run it from this directory:

```sh
verona build macro-expansion ./dist
./dist/macro-expansion
echo $? # 42
```

The program exits with status 42. It imports the standalone
[`base`](../../base/) module explicitly.

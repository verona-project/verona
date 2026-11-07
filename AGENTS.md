# Compiler input convention

The compiler consumes expanded `%` forms. The initial core accepts `%function`
alongside `import` and `export` for module directives,
and existing concrete integer primitives such as `%+-primitive-i64` and
`%=-primitive-i64`. Surface `function` declarations belong to Base's macro layer.
Numeric operator names use the reference compiler's default generics, after
lexical declarations and protocol evidence have been resolved; do not register
them as concrete primitive aliases. Preserve the distinction between Base
expansion, semantic generic dispatch, and concrete compiler input.

Existing core `let` is unprefixed. The initial core's built-in `if` remains
unprefixed; do not invent `%let` or `%if` as aliases for this convention.

The compiler implementation itself uses the richer bootstrapping Verona
language and imports Base normally, including `base:function` declarations.
Examples and test input programs must use the compiler's expanded input forms.
In the pinned Nix development shell, run
`python3 tests/test_core.py build/verona` and
`python3 tests/shared_suite.py build/verona` after compiler changes.

Process surface `import` and `export` during module collection, before
expanding later declarations. Keep `%import` and `%export` for expanded-core
callers. Other declarations reach the checker in their expanded `%` forms.

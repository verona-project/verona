# Generate types from compiler state

This example turns compile-time data into two runtime types, uses both in a
calculation, prints the result, and exits successfully.

1. `src/models.vrn` initializes `'models:types` directly at top level. The
   state contains two property lists describing `Rectangle` (integer `width`
   and `height`) and `Scale` (integer `factor`).
2. Its exported `generate-types` macro reads those descriptions and returns
   both `base:type` declarations through `definitions`.
3. `src/macro-expansion.vrn` imports the module as `m` and invokes
   `(m:generate-types)`. Both generated types belong to the application module.
4. `main` constructs `Rectangle 3 7` and `Scale 2`, then computes the scaled
   area: `3 * 7 * 2 = 42`. It prints the computed integer and returns `0`.

The registry is compile-time data, and each build starts with fresh state.
The generated types and `scaled-area` function are checked and compiled into
ordinary native code. Decimal output uses `libc.stdio:putchar`.

Build and run from this directory in the repository development environment:

```sh
../../build/verona build macro-expansion ./dist
./dist/macro-expansion
# Prints: 42
echo $? # 0
```

The build imports the standalone [`base`](../base/) and [`libc`](../libc/)
projects through their module search paths.

# Verona dynamic library

This project builds a Verona source file into a shared library. It exports
`dynamic_library_add` through the C ABI for
[`../dynamic-library-client/`](../dynamic-library-client/), an independent
Verona project that links and calls it.

Build the library from the repository root:

```sh
mkdir -p build/dynamic-library
cd projects/dynamic-library
../../build/verona build dynamic-library ../../build/dynamic-library
```

The artifact is written to `build/dynamic-library/` as a `.dylib` on macOS or
a `.so` on Linux.

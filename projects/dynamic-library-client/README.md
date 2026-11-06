# Verona dynamic-library client

This independent Verona project links against the shared library built by
[`../dynamic-library/`](../dynamic-library/). Its executable declares the
library's C-ABI export with `external-function`, calls it with `20` and `22`,
and succeeds only when the result is `42`. Surface declarations explicitly
import Base; the manifest includes `../base/src` in its module search paths.

Build and run both projects with the self-hosted compiler from the repository
root (Darwin filenames shown):

```sh
mkdir -p build/dynamic-library
build/compiler/verona-core compile projects/dynamic-library/src/dynamic-library.vrn \
  --emit shared-library -o build/dynamic-library/libdynamic-library.dylib \
  --module-path projects/base/src
build/compiler/verona-core compile projects/dynamic-library-client/src/dynamic-library-client.vrn \
  -o build/dynamic-library/dynamic-library-client --module-path projects/base/src \
  --library-path build/dynamic-library --library dynamic-library
DYLD_LIBRARY_PATH=build/dynamic-library build/dynamic-library/dynamic-library-client
```

On Linux, use `libdynamic-library.so` and `LD_LIBRARY_PATH` instead. The library
and its generated header are written to `build/dynamic-library/`. The loader
path applies only to the final test process; no installation is required.

The Common Lisp compiler can also build each project's manifest using
`verona build TARGET OUTPUT-DIRECTORY` from that project's directory.

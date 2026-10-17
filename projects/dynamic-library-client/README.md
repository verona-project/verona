# Verona dynamic-library client

This independent Verona project links against the shared library built by
[`../dynamic-library/`](../dynamic-library/). Its executable declares the
library's C-ABI export with `external-function`, calls it with `20` and `22`,
and succeeds only when the result is `42`.

Build and run both projects from the repository root:

```sh
make test-dynamic-library
```

The command first writes the shared library to `build/dynamic-library/`, then
links this client with that directory as its native library path. It sets the
dynamic loader path only for the final test process, so no installation is
required.

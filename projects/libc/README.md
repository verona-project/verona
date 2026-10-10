# Verona libc

A test-oriented POSIX libc binding for Verona programs. It exposes the memory,
string, standard-I/O, file-descriptor, filesystem, process, time, math,
network, and pthread names used in the development inventory. The source uses
the selected target's C ABI and currently supports Darwin and Linux.

`libc.types` exports transparent aliases for the ABI types used here: `c-char`,
`c-int`, `c-long`, `size-t`, `ssize-t`, `off-t`, `pid-t`, `mode-t`, `time-t`,
`socket-length-t`, `file-descriptor`, and `c-string`, along with opaque names
for C values that must only be used through pointers (`file-stream`,
`directory-stream`, `file-status`, `time-specification`, `socket-address`,
`address-info`, and pthread objects).

`libc.types` and `libc.constants` use platform feature conditionals (`#+darwin` and `#+linux`) to select the
ABI-dependent aliases and values from the target triple. This includes
`mode-t`, `pthread-thread`, open flags, `AF-INET6`, and the platform-specific
`EAGAIN`/`EDEADLK` values. It provides standard file-descriptor and exit
values; seek, open, and permission flags; `WNOHANG`; the basic socket
families, socket kinds, and IP protocol values; and common POSIX errno values.
These are target definitions, not a portable replacement for every C header.

The declarations are divided by C API category. `src/libc.vrn` is the build
aggregator; clients import the category they use. The modules are
`libc.types`, `libc.constants`, `libc.memory`, `libc.string`, `libc.stdio`,
`libc.descriptor`, `libc.filesystem`, `libc.process`, `libc.time`,
`libc.math`, `libc.network`, and `libc.pthread`. The library deliberately
contains only C ABI declarations; applications own their convenience
functions while the Verona surface is still evolving.

Some declarations are intentionally low-level placeholders: variadic functions
and APIs that require C-layout storage still need additional ABI support before
they can be called safely. Verona supports typed function pointers and can call
them, but `qsort`, `bsearch`, and `pthread-create` still need bindings with
their exact callback signatures and C-layout argument storage. Use
`execv`/`execve`/`execvp` instead of variadic `execl*`.

## Exported test API

| Area | Functions |
| --- | --- |
| Memory | `malloc`, `calloc`, `realloc`, `free`, `memcpy`, `memmove`, `memset`, `memcmp` |
| Strings | `strlen`, `strcmp`, `strncmp`, `strcpy`, `strncpy`, `strchr`, `strstr`, `strerror` |
| Standard I/O | `fopen`, `fclose`, `fread`, `fwrite`, `fgets`, `fputs`, `getchar`, `putchar`, `puts`, `perror` |
| File descriptors | `open`, `close`, `read`, `write`, `lseek`, `pipe`, `dup`, `dup2` |
| Files/directories | `stat`, `mkdir`, `unlink`, `rename`, `opendir`, `readdir`, `closedir` |
| Process/environment | `getenv`, `setenv`, `unsetenv`, `getpid`, `fork`, `execv`, `execve`, `execvp`, `wait`, `exit` |
| Time | `time`, `clock-gettime`, `sleep`, `nanosleep` |
| Conversion/math | `abs`, `strtol`, `strtoul`, `qsort`, `bsearch`, `sin`, `cos`, `sqrt` |
| Networking | `socket`, `htons`, `inet-addr`, `setsockopt`, `bind`, `listen`, `accept`, `connect`, `send`, `recv`, `getaddrinfo`, `freeaddrinfo` |
| Pthreads | `pthread-create`, `pthread-join`, `pthread-mutex-init`, `pthread-mutex-destroy`, `pthread-mutex-lock`, `pthread-mutex-unlock`, `pthread-cond-init`, `pthread-cond-destroy`, `pthread-cond-wait`, `pthread-cond-signal`, `pthread-cond-broadcast` |

Use the source modules from another project's build file:

```lisp
(module-path "../libc/src")
```

Then import the module in Verona source:

```lisp
(import libc.types :as libc)
(import libc.descriptor :as descriptor)
```

The build target roots at `libc`, which imports every category so the full
package is compiled together:

```sh
verona build libc ./dist
```

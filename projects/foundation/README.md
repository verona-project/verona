# Verona Foundation 0.1

An initial Foundation library written in Verona. It provides explicit allocation,
a segmented arena, binary data, UTF-8 strings, checked numeric utilities, absolute
time, structured errors, and statically specialized collections. Algorithms and
storage management are Verona code; only POSIX allocation/free and wall-clock
access use C calls. No compiler changes, reference counting, Regions, garbage
collector, object headers, runtime registry, or reference tracking are introduced.

## Build and run

Use the repository development shell and configured build:

```sh
make test-foundation
make test
cd projects/foundation
../../build/verona build foundation ../../build/foundation
../../build/verona build foundation-example ../../build/foundation
../../build/foundation/foundation-example
```

`foundation-tests` runs 276 named unit tests and one separate integration test.
See [Testing](TESTING.md) for coverage, allocation checks, and selecting a module
or individual test.
`foundation-example` runs the arena-backed Array<String>, Dictionary<String,u64>,
Set<u64>, and mutable Data example in `tests/test_integration.vrn`. Both return
zero on success. `foundation` builds a static archive, with source modules as the
normal Verona consumption interface; it does not declare a C export API.

Add this package's `src` and `../base/src` to a consumer's module paths. Import
individual modules explicitly; `foundation.vrn` is the library build aggregator.
Each file defines its own namespace. Collection macro expansions refer to `base`,
`array`, `allocator`, `foundation.compat.arithmetic`, and `error`; clients must import those module
names too (aliases alone do not introduce the original qualified names).

## Memory and lifetime contract

- An allocator is a `backend` value with a context pointer and two typed callbacks.
  `allocate`, `resize`, and `deallocate` consistently use that backend. Contexts
  must outlive their users. Layouts require a nonzero power-of-two alignment.
- System zero-size allocation obtains a distinct, freeable allocation of at least
  one byte. Arena zero-size allocation consumes one byte. Deallocation must use
  the same backend and original requested size/alignment. Never free borrowed
  pointers, views, or empty descriptors' sentinel pointers.
- `resize` allocates a replacement, copies the smaller length, and releases the
  original only on success. Failure preserves the original allocation. Checked
  addition/multiplication reject overflow before allocating collection storage.
  Integer overflow guards use Base’s `minBound` and `maxBound`; collection
  doubling checks use half the unsigned maximum.
- Arena creation is lazy. Blocks have at least the configured initial capacity;
  oversized requests get larger blocks. Block alignment satisfies its request.
  Allocation scans reusable blocks and bumps an aligned offset, allocating a new
  segment when needed. `used` includes alignment padding; `capacity` counts
  payload bytes, excluding the 40-byte metadata per block. Blocks are not moved.
- `reset` sets every block's cursor to zero and retains storage; `destroy` frees
  all backing allocations. **Both invalidate every outstanding arena allocation,
  view, string, and collection.** There are no lifetime checks. A destroyed arena
  descriptor becomes empty and can be reused. Arena release callbacks do nothing.
- Keep an arena descriptor at a stable address while a backend points to it.
  Destroy/reset shared arenas only after all their clients have finished.
- Data, String, and collection descriptors own their allocated storage. Plain
  assignment copies the descriptor, not its storage; it does not create a second
  owner. Use explicit copy APIs for independent allocations. Call `destroy`
  exactly once per owner, before its allocator context expires. Empty/repeated
  destruction is allowed on the same descriptor; using a copied owner is not.
- Removal/clear changes logical contents, retaining capacity. Arena-backed
  resize/rehash retains obsolete storage until reset/destroy. Elements are shallow
  values: Foundation never runs destructors. Callers release nested owners and
  external resources explicitly, including removed/replaced values.
- A borrowed view/get pointer remains valid only while its owner remains alive
  and storage has not moved. Growth, removal, replacement, clear, or reset can
  invalidate addresses or their logical contents. Read-only views are a contract;
  the current type system cannot enforce pointer immutability.
- Copy, byte assignment, and concatenation require destination storage to be
  distinct from borrowed source storage. Visitor callbacks must not mutate the
  collection being visited. APIs are unsynchronized; callers coordinate access.

## Public APIs

| Module | Core API |
| --- | --- |
| `allocator` | `backend`, `result`, `error`, `allocate`, `resize`, `deallocate`, `valid-alignment`, `checked-add-size`, `checked-multiply-size`, `copy-bytes` |
| `system_allocator` | `create` returns the POSIX backend (`posix_memalign` paired with `free`) |
| `arena` | `arena`, `create`, `allocate`, `allocator`, `reset`, `destroy`, `used`, `capacity` |
| `data` | `data`, borrowed `view`, `empty`, `assign-bytes`, `bytes`, `length`, `borrow`, `slice`, `reserve`, `append`, `resize`, `copy`, `equal`, `destroy` |
| `string` | `string`, `empty`, `validate`, `from-utf8`, `bytes`, `byte-length`, `scalar-length`, `equal`, `substring`, `find`, `copy`, `concat`, `destroy` |
| `number` | Unboxed primitives; `parse-u64`, checked `to-i64`, `format-u64`, distinct invalid/overflow results |
| `date` | `instant`, `duration`, `now`, `before`, checked `add`/`subtract`/`between` |
| `error` | `status` sum with success/allocation/bounds/invalid/overflow cases; descriptions; optional `context` value with code, description, detail |
| `array` | `layout`, `define` specialization macro; generated operations below |
| `dictionary` | `define` specialization macro; generated hash table below |
| `set` | `define` specialization macro reuses Dictionary with a boolean payload |

`foundation.compat.arithmetic` and `foundation.compat.signed_arithmetic` are
private, temporary compatibility shims. They forward typed u64/i64 calls to the
existing Base protocols while literal inference and direct operator dispatch
remain deferred for Base/compiler review. They add no arithmetic semantics or
checked operations and are not public Foundation APIs. The bundled formatter
reuses these shims; Base itself is unchanged.

A successful mutation returns `error:status` case `(ok)`; errors are sum values.
Allocator, Number, and Date additionally have module-specific result/error sums.
Sum constructor names in matches are unqualified and resolved from the matched
type. Constructors are not exported functions; use module helper functions where
needed. Context descriptions are borrowed NUL-terminated UTF-8/ASCII pointers.

Data's `assign-bytes` constructs/replaces content in an initially empty owner;
`resize` zero-fills newly exposed bytes. `reserve` grows capacity without changing
logical length or contents; streaming clients can reserve geometrically before
copying a chunk. Slices are checked borrowed views, indexed
in bytes. Out parameters are existing descriptors initialized with the desired
allocator, making destination allocation policy explicit.

String stores validated UTF-8, including embedded NUL. Validation rejects
continuation errors, truncation, overlong encodings, surrogates, and scalars above
U+10FFFF. `substring(start,count)` indexes **Unicode scalar values**, not bytes or
grapheme clusters, and returns a borrowed byte view with complete scalar boundaries.
`find` returns `(tuple found scalar-index)`, with the first match; an empty needle
matches at zero. Equality compares exact UTF-8 bytes. `bytes` is not necessarily
NUL-terminated. Unicode normalization and locale collation are outside this version.

Number accepts nonempty ASCII decimal digits only (no sign, whitespace, separators,
or prefixes), detecting u64 overflow. Formatting replaces destination Data with
ASCII decimal digits without a terminating NUL. Other primitive arithmetic,
comparison, and conversions remain in Verona's `base`; Foundation adds no boxing.

Date uses signed Unix seconds since 1970-01-01T00:00:00Z, with one-second wall-clock
resolution. Durations are signed seconds. `between(start,end)` computes end minus
start. All arithmetic checks overflow, including minimum signed values. `now`
reports a clock error for the platform's -1 failure sentinel. These are instants,
not local calendar dates; wall-clock readings need not increase monotonically.

## Collection specialization

Verona currently needs macro specialization for owning collections; see
[the compatibility assessment](COMPATIBILITY.md). This is existing compiler syntax:

```lisp
(import base)
(import allocator)
(import foundation.compat.arithmetic)
(import error)
(import array)
(import dictionary)
(import set)
(import system_allocator :as system)

(array:define integers u64)
; integers-empty takes a typed witness pointer and array:layout.
; The witness is never dereferenced while length/capacity are zero.

(base:function hash ((key u64)) u64 key)
(base:function equal ((left u64) (right u64)) bool (foundation.compat.arithmetic:eq left right))
(dictionary:define scores u64 u64 hash equal 32 8)
(set:define identifiers u64 hash equal 32 8)
```

`(array:define PREFIX ELEMENT)` generates `PREFIX-empty`, `-length`, `-capacity`,
`-reserve`, `-get`, `-append`, `-insert`, `-remove`, `-replace`, `-clear`, `-copy-into`,
`-visit`, and `-destroy`. An array is `(tuple (pointer ELEMENT) u64 u64 array:layout)`.
`layout` takes allocation size per element, alignment, and allocator. `reserve`
provides initial capacity; append doubles capacity starting at four. `get` returns
`(tuple valid pointer)`; never dereference the pointer on failure. Insert accepts
index equal to length; access/remove/replace require index less than length.
`copy-into` preserves the destination allocator. Visitors take one element by value.

`(dictionary:define PREFIX KEY VALUE HASH EQUAL SLOT-SIZE SLOT-ALIGNMENT)` generates
`PREFIX-table`, `-empty`, `-count`, `-capacity`, `-lookup`, `-get`, `-contains`,
`-insert`, `-remove`, `-clear`, `-visit`, and `-destroy`. Helper declarations also
exist in the expanding module; treat them as private implementation details.
`lookup` returns `(tuple found slot-index)`; indices are invalid after mutation.
`get` writes a supplied value pointer on success and leaves it unchanged on absence.
`insert` updates existing keys. `remove` returns whether an entry existed.
Visitors take a key and value by value. Generated declarations can be re-exported
by their containing module using ordinary Verona exports.

Dictionary uses open addressing, linear probing, tombstones, cached hashes, and
rehashing at 50% live occupancy. Growth is transactional on allocation failure.
Iteration order is unspecified and can change after any mutation. Equality must
be an equivalence relation; equal keys **must** have equal hashes. Stored keys and
hash/equality behavior must stay unchanged while entries exist. The table owns
its slot allocation, not separately allocated resources inside keys/values.

`(set:define PREFIX ELEMENT HASH EQUAL SLOT-SIZE SLOT-ALIGNMENT)` generates the same
table and query/removal/visit operations and adds `PREFIX-add(owner,value)`. The
shared internal `-insert` operation has a boolean payload; normal Set callers use
`-add`. Dictionary-style visitors receive that boolean as their second argument.

**Layout is an explicit unsafe caller contract.** Element/slot allocation sizes
must be at least their actual ABI size, and alignment must satisfy the actual
ABI alignment. Pointer arithmetic uses the compiler's true type stride. Wrong
layouts can corrupt memory. On this compiler's 64-bit ABI, u64 arrays need 8/8;
u64/u64 and u64/bool hash slots need 32/8; String arrays need 72/8; String/u64
hash slots need 96/8. No automatic size or alignment discovery is claimed.

## Verification and remaining work

Implemented and exercised: each module, growth, collisions/rehash/tombstones,
duplicate updates, allocator failures including failed arena block acquisition and
failed rehash, arena reuse/reset/destruction, binary copying/slices, UTF-8 validity
and scalar boundaries, integer boundaries/formatting, time arithmetic, and shared
arena integration. Tests never access invalidated arena allocations.

The suite and static library compile with the available LLVM-backed compiler;
verification was performed on this Darwin host. Linux uses the same POSIX calls
and 64-bit layout assumptions but has not been executed here. Other operating
systems and 32-bit targets are unsupported. Large recursion depth may exhaust the
stack at low optimization; tail-call elimination is not a public guarantee.

Blocked by compiler capabilities: automatic layouts, ordinary parameterized named
collection types, generic bodies containing local type-parameter declarations or
casts, field-place mutation, and enforced immutable/lifetime-safe borrowed views.
Whole-descriptor writes and macro specialization provide the working alternatives.

Deferred enhancements: signed integer parsing/formatting, additional checked numeric
conversions, lexicographic string ordering, Unicode normalization/collation,
higher-resolution/monotonic clocks, amortized arena block indexing, stable iterators,
resource cleanup callbacks, and performance/large-input stress benchmarks. Next,
add compiler layout queries and generic local-type resolution, then remove manual
layouts and simplify collection specialization; verify the suite on Linux.

## Changed files and verification record

All new files are under `projects/foundation/`:

- `src/allocator.vrn`, `src/system_allocator.vrn`, `src/arena.vrn`: memory backends and arena.
- `src/data.vrn`, `src/string.vrn`, `src/number.vrn`, `src/date.vrn`, `src/error.vrn`: primitive Foundation APIs.
- `src/array.vrn`, `src/dictionary.vrn`, `src/set.vrn`: collection specialization and algorithms.
- `src/foundation.vrn`: build aggregation.
- `src/foundation.compat.arithmetic.vrn` and `src/foundation.compat.signed_arithmetic.vrn`:
  temporary private compiler compatibility shims.
- `tests/test_allocator.vrn`, `tests/test_system_allocator.vrn`, `tests/test_arena.vrn`, `tests/test_data.vrn`,
  `tests/test_string.vrn`, `tests/test_number.vrn`, `tests/test_array.vrn`,
  `tests/test_dictionary.vrn`, `tests/test_set.vrn`, `tests/test_date.vrn`,
  `tests/test_error.vrn`, `tests/test_compat_arithmetic.vrn`: module and compatibility regression tests.
- `tests/support.vrn`, `tests/test_integration.vrn`, `tests/suite.vrn`,
  `tests/example.vrn`: deterministic failing allocator, shared-arena integration,
  complete runner, and executable example.
- `verona.build`, `README.md`, `COMPATIBILITY.md`, `TESTING.md`: build targets, API/ownership
  documentation, and compiler capability assessment.

Existing root files changed: `Makefile.am` adds `test-foundation` to `make test`;
`readme.md` links the package. Generated build/configuration outputs are not source
changes. Pre-existing unrelated untracked files were left alone.

Executed successfully on the available host/compiler:

- `make test-foundation`: native module and integration suites, exit 0.
- `make test`: 1,306 frontend checks, 84 LLVM checks, 189 compiler/driver checks,
  existing Verona testing smoke suite, and Foundation suite; no failures/skips.
- `verona build foundation`: static archive produced.
- `verona build foundation-example` and its executable: exit 0.
- `git diff --check`: clean.

Implemented/tested functionality is described above. Implemented but not independently
verified here: Linux execution, exact address-modulo alignment inspection (tests
request aligned allocations but the source language cannot inspect pointer bits),
and large-input performance/stack behavior. Automatic layouts and stronger typed
ownership remain compiler-blocked; the other enhancements listed above are deferred.

The formatter application additionally exercises large Foundation buffers. Byte
copying, Array copying, Data zero-fill/equality, and UTF-8 validation now use
bounded-depth traversal, avoiding reliance on pointer-bearing tail-call
optimization. Other recursive APIs retain the stack limitations noted above.

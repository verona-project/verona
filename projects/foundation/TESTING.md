# Foundation tests

The native suite has 276 independently named unit tests and one separate
shared-arena integration test. Each behavior has its own `testing:test`
declaration, fresh resources, and explicit teardown. Expression-level groups use `testing:checks`; aggregation trees are generated
by the testing library rather than repeated in test bodies.

Stress cases remain named
and bounded so they run with the ordinary unit suite.

## Running tests

From the repository root:

```sh
make test-foundation
./build/foundation/foundation-tests array
./build/foundation/foundation-tests compat
./build/foundation/foundation-tests array/append-4096-elements-verifies-every-value
./build/foundation/foundation-tests dictionary/mixed-operations-match-independent-model
make test
```

The optional selector is either an exact test name or a whole module name.
An unknown selector returns 2 rather than silently succeeding. Every failing
case prints `FAIL module/test-name`; the runner returns 1 for any failed check,
including when the failure count is a multiple of 256. Successful runs report
the number of selected tests. The example executable runs only the integration
case; it is not a replacement for module tests.

## Unit coverage

| Component | Named tests | Focus |
| --- | ---: | --- |
| Allocator | 21 | Alignment validation, arithmetic boundaries, callback routing, zero-byte copy, grow/shrink/same-size/zero-size resize, complete-prefix preservation on failure |
| System allocator | 11 | Sizes from zero through 2,048 bytes over 512 allocation/free cycles; requested alignments from 1 through 4,096 |
| Arena | 13 | Lazy creation, default capacity, zero-size behavior, exact fit, padding, segment growth, old-storage preservation, metadata/payload failure rollback, reset/reuse, destruction/recreation |
| Data | 25 | Binary NUL/high bytes, ownership independence, 8,192 appends, zero-filled resize tails, shrink/regrow, slice boundaries, overflow-sized slice requests, failed mutations/copy |
| String | 59 | Valid UTF-8 width boundaries, surrogate edges, maximum scalar, overlong/invalid/truncated sequences, scalar-indexed slices/search, copy/concat, failure preservation, every position in a 2,048-scalar string |
| Number | 34 | Golden parsing/formatting cases at decimal boundaries and u64 extremes, malformed input, embedded NUL, checked conversion, failure preservation, 4,096 format/parse roundtrips |
| Array | 24 | 4,096-element growth with every value checked, 512 front insertions/removals, middle/end operations, invalid indexes, capacity reuse, independent copies, exact visitor order, failed growth/copy/insert, overflow |
| Dictionary | 18 | Wraparound collision chains, 512 colliding entries and repeated rehash, tombstone deletion/reuse, all-tombstone lookup termination, duplicate updates, complete visitor coverage, failed rehash/retry, direct model comparison |
| Set | 12 | 512 colliding values, duplicate uniqueness, deletion/reinsertion, clear/reuse, visitor uniqueness, failure preservation, numeric extremes, direct membership model comparison |
| Date | 26 | Epoch comparisons, signed minimum/maximum duration arithmetic, both overflow directions, subtraction of minimum duration, forward/reverse elapsed time, 8,193 arithmetic cases, wall-clock smoke check |
| Error | 7 | Exact descriptions for every status, preservation of allocation causes, contextual code/messages |
| Compatibility shims | 26 | Typed u64/i64 forwarding through existing Base protocols, comparisons, and numeric boundaries |
| Integration | 1 | Array<String>, Dictionary<String,u64>, Set<u64>, and mutable Data sharing one arena |

Dictionary stress executes 4,096 deterministic mixed operations against a
64-key direct-indexed oracle. After **every operation**, it compares all keys,
all stored values, absent-output preservation, and entry count. Set stress
executes 2,048 mixed operations and checks all 64 memberships after each step.
These models have no hashing, probing, rehashing, or tombstone implementation.

Growth tests inspect complete sequences rather than only lengths or the final
element. Visitor tests check each entry's multiplicity, and Array additionally
checks order. Failure cases verify the previous contents and observable size,
not merely that an error was returned. Some tests disable further allocations
to verify updates, clear/reuse, and tombstone reuse do not allocate.

## Isolation and allocation checks

`support.vrn` supplies a deterministic allocation budget and an allocation ledger.
The ledger records pointer, requested size, alignment, and active state for each
live allocation. Every named test starts with reset counters/budget and checks
that it inherited no live allocations; teardown checks there are no leaks or
size/alignment pairing errors. Unknown and duplicate frees are recorded as
failures without actually executing an invalid native free.

The ledger's 256-record storage lives in the runner, outside the allocator being
tested. Its limit is above the maximum live allocations in these bounded tests
(the many-segment arena case uses 192). Visitor scratch buffers belong to their
own test cases. No test dereferences an arena pointer after reset or destruction.

## Practical limits

Tests request aligned native allocations and verify arena-relative padding and
callback layout routing. The language has no pointer-to-integer operation, so
these tests do not independently inspect native address modulo alignment.
The wall-clock test does not assume monotonicity or a particular current date.
Stress uses fixed seeds and bounded sizes; it is reproducible, not a substitute
for sanitizer runs, platform CI, fuzzing, or unbounded performance benchmarks.

## Verification of failure detection

During this revision, five temporary production-code mutations were compiled and
run against the relevant selected unit. Every run returned 1 and printed the
expected failing test name:

- Replacing copied bytes with zero: `allocator/resize-grow-preserves-entire-prefix`.
- Skipping Array's insertion shift: `array/prepend-512-elements-preserves-reverse-order`.
- Leaving Dictionary's count unchanged on removal: `dictionary/single-entry-get-and-remove`.
- Accepting a UTF-8 scalar above U+10FFFF: `string/reject-above-unicode-maximum`.
- Reversing Date's positive overflow comparison: `date/addition-positive-overflow`.

The byte-copy mutation produces 256 failed byte checks, also exercising exit-code
normalization. All mutations were restored before the final ordinary suite run;
this revision changes tests, their runner, and test documentation only.

Final verification passed: `make test-foundation`, the complete `make test`
(1,306 frontend, 84 LLVM, and 189 compiler checks plus both native suites),
each module selected independently, exact single-case selection, unknown-selector
rejection, the rebuilt standalone integration example, and `git diff --check`.

# Verona testing library

`testing` is a Verona-native assertion library. A test suite returns the
aggregate failure count as its process exit status: `0` means every check
passed, and a non-zero value is the number of failed checks.

```lisp
(import base)
(import testing)

(testing:test arithmetic
  (testing:assert-equal 40 40)
  (testing:assert-less-than 40 42))

(testing:test ordering
  (testing:assert-less-than 40 42))

(testing:runner main
  (arithmetic)
  (ordering))
```

`testing:test` declares a zero-argument named test and combines all of its
checks. `testing:runner` declares the program entry point and executes the
listed test calls in order; its exit status is the total failure count. Use
`testing:check` for an existing boolean condition, and `testing:assert-equal`
/ `testing:assert-not-equal` for any type implementing `base:equality`. The
four ordering helpers (`assert-less-than`, `assert-less-or-equal`,
`assert-greater-than`, and `assert-greater-or-equal`) work for types
implementing `base:ordering`.

### Grouping checks inside expressions

Use `testing:checks` to return one result from any number of assertions inside
`let`, `match`, fixtures, or recursive helpers:

```lisp
(let ((value i64 42) (expected i64 42) (upper i64 43))
  (testing:checks
    (testing:assert-equal value expected)
    (testing:assert-less-than value upper)))
```

Every expression runs once in source order, including after a failure. An empty
group returns an empty result. `testing:test` already groups its top-level checks;
use `testing:checks` when an expression needs a single aggregate result.

### Fixtures

`testing:with-fixture` scopes a resource around one or more checks. Its
binding has the form `(name type setup-expression teardown-function)`:

```lisp
(base:function make-answer () i32 42)
(base:function release-answer ((value i32)) unit unit)

(testing:test uses-a-fixture
  (testing:with-fixture (answer i32 (make-answer) release-answer)
    (testing:assert-equal answer 42)))
```

The teardown function runs after the checks are aggregated, even when checks
fail. For a callback-style test, `testing:execute` accepts a `testing:test-function`
pointer; this also makes arrays of equally typed tests possible.

Build the static library from this directory:

```sh
verona build testing ./dist
```

The repository includes a runnable smoke suite:

```sh
verona build testing-smoke ./dist
./dist/testing-smoke
```

The library deliberately has no runtime registry. The runner therefore uses an
explicit static list of test calls, while its macro generates the aggregation
code at compile time. Named tests can also be used as typed function pointers
through `testing:test-function` and `testing:execute`.

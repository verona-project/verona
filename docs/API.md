# Verona API reference

This reference covers the public surface of Verona 0.x: the `.vrn` language,
the Common Lisp embedding API, the LLVM backend, and the native compiler
driver.  Names in the `verona` package are available as `verona:name`; driver
and backend names use `verona.compiler:name` and
`verona.backend.llvm:name` respectively.

The compiler exposes source-aware and semantic objects deliberately. The
front-end first resolves module names and declaration signatures, then runs a
bidirectional type-checking phase over executable bodies. The public
front-end functions below are suitable for tools, tests, and embeddings; the
semantic and LLVM layers are advanced APIs for analyzers and alternate
backends.

## Command-line compiler

`verona compile SOURCE [options]` compiles one root `.vrn` module and prints
the produced artifact path.  `verona build TARGET OUTPUT-DIRECTORY` reads a
`verona.build` file from the current directory, builds `TARGET`, and prints its
artifact path.

| Option | Meaning |
| --- | --- |
| `--version`, `-V` | Print the Verona release version. |
| `-o PATH`, `--output PATH` | Write the artifact to `PATH`. |
| `--emit object` | Emit an object file. |
| `--emit executable` | Emit a native executable (the default). `main` returns `exit-code` and may accept `(argc i32)` and `(argv (pointer (pointer u8)))`. |
| `--emit static-library` | Emit `libNAME.a`. |
| `--emit shared-library` | Emit `libNAME.dylib` on Darwin or `libNAME.so` on Linux. |
| `--target TRIPLE` | Compile for an LLVM target triple. |
| `--cpu CPU` | Select the target CPU; defaults to `generic`. |
| `--features FEATURES` | Pass the LLVM target-feature string. |
| `--feature NAME` | Enable a Verona reader feature for this compile or build invocation. Repeatable. |
| `-l NAME`, `--library NAME` | Link a native library as `-lNAME`. Repeatable. |
| `-L PATH`, `--library-path PATH` | Add a native library search path. Repeatable. |
| `--framework NAME` | Link a Darwin framework. Repeatable; rejected on non-Darwin targets. |

The LLVM bindings are pinned in the `vendor/CL-LLVM` Git submodule from
[verona-project/CL-LLVM](https://github.com/verona-project/CL-LLVM). Initialize
it with `git submodule update --init --recursive` and set `VERONA_CL_LLVM` to
that directory's absolute path when configuring the environment manually.
Keep the recorded submodule revision matched to LLVM 23.

The optional Nix development shell uses that same submodule and supplies
`VERONA_CL_LLVM`, `VERONA_LINKER`, and `VERONA_AR`. Its automatic submodule
inclusion requires Nix 2.27 or later. Override the latter two variables to
select a different native linker or archiver.

## Verona language

### Values and types

| Item | Meaning |
| --- | --- |
| `unit` | The sole unit value and the unit type. |
| `true`, `false` | Boolean literals of type `bool`. |
| Signed integers | `i8`, `i16`, `i32`, `i64`, and pointer-sized `isize`. |
| Unsigned integers | `u8`, `u16`, `u32`, `u64`, and pointer-sized `usize`. |
| Floating point | `f32` and `f64`. |
| `char` | An ASCII code unit, represented as `u8` by the LLVM backend. |
| Text literal | An immutable ASCII C string: a NUL-terminated `(pointer u8)`. Use `strlen` for its length. |
| `void` | C ABI-only no-value result type; it is not a Verona value type. |
| `(pointer TYPE)` | Pointer type. Pointers to `void` or an opaque type cannot be dereferenced. |
| `(function (TYPE...) RESULT)` | Function type syntax. |

`(type Name)` declares a nominal opaque type: it has no Verona layout and is
valid only as the pointee of a pointer, which is appropriate for a C handle.
Platform bindings must use a concrete product type only when that target's C
layout is known and tested; otherwise they must expose an opaque handle.
Type aliases use `(type Name Type)`, for example `(type UserId i64)`. Product
types use `(type Name (product (field Type) ...))`; sum types use
`(type Name (sum (case Type...) ...))`; a zero-payload case is written
`(case)`. A product is constructed as `(Name value...)`, a sum as
`(case value...)`, and product fields are read with `(field value field-name)`.
Aliases are transparent: they have their target's identity and representation,
and introduce no constructor of their own. An alias of a nominal type uses the
target's existing constructor. Use a product or sum type when a distinct
nominal type is required.

### Top-level forms

| Form | Purpose |
| --- | --- |
| `(type NAME TYPE)` | Define a transparent type alias. |
| `(type NAME)` | Define a nominal opaque type, usable only behind a pointer. |
| `(type NAME (product FIELD...))` | Define a nominal product type. |
| `(type NAME (sum CASE...))` | Define a nominal sum type. |
| `(function NAME ((parameter TYPE) ...) RESULT BODY)` | Define a function. |
| `(external-function NAME "c_name" (TYPE...) RESULT)` | Declare a C function. Parameters must use `bool`, numeric scalar, or pointer C ABI types; a result may also be `void`. Verona `bool` follows the target C ABI's `_Bool` convention. |
| `(macro NAME (parameter ...) BODY)` | Define a compile-time macro. Parameters and result are S-expressions. |
| `(constant NAME TYPE VALUE)` | Define an immutable global. |
| `(variable NAME TYPE INITIALIZER)` | Define a mutable global. |
| `(generic NAME (parameter ...))` | Declare a generic callable by arity. |
| `(implementation NAME ((parameter TYPE) ...) RESULT BODY)` | Add an exact-type implementation to a generic. |
| `(import module.name)` | Load a module from the module search path. |
| `(import module.name :as alias)` | Load a module and use `alias:member` to qualify exports. |
| `(export NAME...)` | Make declarations available to importing modules. |
| `(native-export NAME)` | Export a function with its Verona name to C. |
| `(native-export NAME "c_name")` | Export a function to C with an explicit external name. |

Macros may return one S-expression form in an expression position, or a
top-level sequence of definitions when invoked at the top level. Imports,
exports, and native exports are only valid at the top level.

### Base macro module

The bundled standard library is a standalone project at
[`projects/base/`](../projects/base/), whose `verona.build` declares its `base` module.  Add
`projects/base/src` to a consuming project's module path, then explicitly import the
module and invoke its exported macros with the module qualifier:

```lisp
(import base)

(base:function add ((left i32) (right i32)) i32
  (+ left right))
```

Projects can replace a surface convention locally. For example, this installs
an unqualified `function` macro by placing the primitive definition name ahead
of the original arguments:

```lisp
(import base)

(base:macro fn (&rest arguments)
  (cons '%function arguments))

(fn main () exit-code 0)
```

`base` exports `macro`, `type`, `function`, `external-function`, `constant`,
`variable`, `generic`, `protocol`, and `implementation`. It also supplies three
protocols for ordinary parametric code:

```lisp
(base:function total
  (for (a)
    ((base:numeric a)))
  ((left a) (right a))
  a
  (+ left right))

(base:function same
  (for (a)
    ((base:equality a)))
  ((left a) (right a))
  bool
  (= left right))

(base:function before
  (for (a)
    ((base:ordering a)))
  ((left a) (right a))
  bool
  (< left right))
```

`base:numeric` provides `+`, `-`, `*`, and `/` to a function constrained by
that protocol; `base:equality` provides `=` in the same way. Both are
implemented for `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`, `f32`,
and `f64`; `base:equality` is also implemented for `bool`. `base:ordering`
provides `<`, `<=`, `>`, and `>=` for those numeric types. Each numeric-family
implementation calls its corresponding concrete primitive operation.

`base:convert` is a result-directed generic. Its source type comes from the
argument and its target type comes from the surrounding context:

```lisp
(base:function byte ((value i32)) u8
  (base:convert value))

(base:function code ((value u8)) i32
  (base:convert value))
```

Every pair of numeric types is supported: `i8`, `i16`, `i32`, `i64`, `u8`,
`u16`, `u32`, `u64`, `f32`, and `f64`. Integer widening preserves the source
signedness; narrowing discards high bits; same-width signed/unsigned
conversions preserve the underlying bits. An uncontextualized conversion is
rejected because its target type is unknown.

### Testing library

The bundled `projects/testing/` package provides Verona-native test results
and generic assertions. Add `projects/testing/src` and `projects/base/src` to a test
target's module paths, declare named tests, then list their calls in a runner:

```lisp
(import base)
(import testing)

(testing:test arithmetic
  (testing:assert-equal 40 40)
  (testing:assert-less-than 40 42))

(testing:runner main
  (arithmetic))
```

`testing:test` combines all checks in a named zero-argument function.
`(testing:checks CHECK...)` aggregates results inside expressions such as `let`
and `match`. It evaluates each check once in source order, including after
a failure; an empty group returns an empty result.
`testing:runner` executes its explicit list of test calls and makes the
process exit code equal the total number of failures. `testing:check` wraps a
boolean condition; `assert-equal` and `assert-not-equal` require
`base:equality`; the four ordering assertions require `base:ordering`.

`testing:with-fixture` scopes a resource around checks using
`(name type setup-expression teardown-function)`. It invokes teardown after
the checks have been aggregated. `testing:test-function` is a typed pointer to
a zero-argument test; pass one to `testing:execute` when a test should be run
through a function pointer or stored alongside same-signature tests.

### Metaprogramming and compilation layers

Verona has two cooperating compilation layers. In the metaprogramming layer,
macro bodies evaluate at compile time and manipulate ordinary S-expressions:
they inspect, construct, combine, and generate syntax for the compiler. In the
top-level-form compiler, the expanded forms are collected as declarations,
their signatures are resolved, executable bodies are type-checked, and the
resulting program is lowered to LLVM. A macro therefore creates program forms;
it does not turn a declaration into a runtime value.

The compiler retains source-aware syntax privately, restoring invocation
provenance only after macro expansion. `base` macros are separately imported
language forms, not implicit evaluator functions. A macro can emit any `%…`
definition form itself; it needs no compiler-only definition constructor.

| Function | Signature | Result / notes |
| --- | --- | --- |
| `+` | `(+ NUMBER...)` | Compile-time addition; zero arguments return 0. |
| `definitions` | `(definitions FORM...)` | Returns zero or more top-level S-expression forms from one macro expansion. Each argument must be an S-expression. |
| `compiler:call` | `(compiler:call HEAD FORM...)` | Constructs a call S-expression headed by the identifier `HEAD`. |
| `compiler:map` | `(compiler:map HEAD LIST...)` | Constructs one call to `HEAD` per parallel set of elements. Lists must be proper and equally long. |
| `compiler:reduce` | `(compiler:reduce HEAD INITIAL FORMS)` | Builds left-associated binary calls to `HEAD`, reducing `INITIAL` over `FORMS`. |
| `compiler:reduce-right` | `(compiler:reduce-right HEAD INITIAL FORMS)` | Builds right-associated binary calls to `HEAD`, reducing `FORMS` into `INITIAL`. |
| `compiler:reverse` | `(compiler:reverse LIST)` | Returns a proper macro list in reverse order. |

### Identifier functions

An identifier value is the atom used in a returned S-expression where source
would contain a name.  `keyword` is an ordinary function: it does not create a
reserved source keyword, and it is currently equivalent to `symbol`.

| Function | Signature | Result / notes |
| --- | --- | --- |
| `symbol` | `(symbol TEXT)` | Construct an identifier with the non-empty string `TEXT`. |
| `symbol-name` | `(symbol-name SYMBOL)` | Return an identifier's spelling as a string. |
| `symbol-concat` | `(symbol-concat PART...)` | Construct an identifier by joining strings and identifiers; requires at least one non-empty resulting component. |
| `keyword` | `(keyword TEXT)` | Construct an identifier with the exact non-empty string `TEXT`; supplied for keyword-style macro conventions. |
| `keyword-concat` | `(keyword-concat PART...)` | Construct an identifier by joining strings and identifiers; supplied for keyword-style macro conventions. |

### String functions

| Function | Signature | Result / notes |
| --- | --- | --- |
| `string-concat` | `(string-concat STRING...)` | Join zero or more strings. With no arguments, returns the empty string. |
| `string-length` | `(string-length STRING)` | Return the character length of `STRING`. |
| `substring` | `(substring STRING START [END])` | Return the portion from zero-based `START` through optional exclusive `END`. Bounds must be non-negative integers. |

### List functions

All compile-time lists are finite, proper S-expression lists.

| Function | Signature | Result / notes |
| --- | --- | --- |
| `list` | `(list VALUE...)` | Construct a proper S-expression list. |
| `cons` | `(cons VALUE LIST)` | Prepend an S-expression `VALUE` to a proper list. |
| `car` | `(car LIST)` | Return the first item of a non-empty proper list. |
| `cdr` | `(cdr LIST)` | Return all but the first item of a non-empty proper list. |
| `append` | `(append LIST...)` | Join zero or more proper lists. |
| `length` | `(length VALUE)` | Return the length of a string or proper list. |

### Compile-time control and data

`nil`, `'nil`, `'()`, and `()` evaluate to the empty compile-time list.
It is distinct from `false` and `unit`, and cannot be used as a runtime value.
Empty data never means zero declarations: return `(definitions)` for that.
Conditions require `true` or `false`; predicates return Verona booleans.

| Form | Evaluation |
| --- | --- |
| `(cond (TEST BODY...) ...)` | First true test selects a nonempty body; no match returns `nil`. Use `true` for an unconditional final test. Malformed clauses are rejected. |
| `(let ((NAME INITIALIZER) ...) BODY...)` | Sequential immutable local bindings; later initializers see earlier bindings. Duplicate names and binding `nil` are errors. |
| `(and TEST...)`, `(or TEST...)` | Evaluate left to right, short-circuit, and return a boolean. With no operands return `true` and `false`, respectively. |
| `(not BOOLEAN)` | Boolean negation. |

Bodies evaluate in order and return their final value. There is no compile-time
`if` or `do`, and runtime `let` type annotations do not apply here.

| Operations | Contract |
| --- | --- |
| `+`, `*` | Zero or more numeric arguments; identities 0 and 1. |
| `-`, `/` | One or more arguments; unary negation/reciprocal, otherwise left-associated. |
| `quotient`, `remainder` | Exactly two integers. Quotient truncates toward zero; remainder has the dividend's sign. |
| `min`, `max`, `abs` | At least one number for min/max; exactly one for abs. |
| `=`, `/=`, `<`, `<=`, `>`, `>=` | At least two numbers; adjacent ordered comparisons, or all-distinct for `/=`. |
| `equal?` | Exactly two values; structural comparison, including identifier spelling, qualified identifiers, booleans, and nested lists. |
| `number?`, `integer?`, `string?`, `symbol?`, `keyword?`, `list?`, `empty?`, `boolean?` | Unary predicates. `symbol?` includes qualified names; `empty?` requires a proper list. |
| `(nth INDEX LIST)` | Zero-based index, strictly below length. |
| `(take COUNT LIST)`, `(drop COUNT LIST)` | Count from zero through length, inclusive. |
| `(reverse LIST)` | Reversed copy. |

Integers have arbitrary precision at compile time. Numeric values are integers
or floating-point numbers, never host ratios or complex numbers. Integer-only
arithmetic stays exact; `/` preserves exact integer results and converts
fractional rational results to double precision. Mixed operations use floating
point. Division by zero, floating overflow, invalid arity, and invalid operands
are compiler diagnostics. Emitted integers must fit their inferred or declared
runtime type; emitted floats must fit the selected floating type.

Property lists alternate keys and values; association lists contain proper
two-element lists. Both reject duplicate keys using structural equality.

| Operation | Signature |
| --- | --- |
| Lookup | `(plist-ref DATA KEY [DEFAULT])`, `(alist-ref DATA KEY [DEFAULT])` |
| Presence | `(plist-has? DATA KEY)`, `(alist-has? DATA KEY)` |
| Update | `(plist-set DATA KEY VALUE)`, `(alist-set DATA KEY VALUE)` |
| Remove | `(plist-remove DATA KEY)`, `(alist-remove DATA KEY)` |
| Enumerate | `(plist-keys DATA)`, `(alist-keys DATA)`, `(alist-values DATA)` |

Missing lookups return `DEFAULT`, initially `nil`; presence distinguishes a
missing key from one associated with `nil`. Updates return new values, replace
in place in the logical order, and append new entries. Inputs remain unchanged.

Strings compare case-sensitively. `(string= LEFT RIGHT)` tests equality;
`(string-prefix? PREFIX TEXT)` and `(string-suffix? SUFFIX TEXT)` test boundaries.
`(string-split TEXT SEPARATOR)` preserves empty segments, and
`(string-join STRINGS SEPARATOR)` joins a proper list of strings.
`(string-replace TEXT OLD NEW)` replaces all non-overlapping matches from left
to right. Empty split separators and empty replacement patterns are errors.
Source strings and emitted runtime strings retain the existing ASCII rules.

`(number->string NUMBER)` formats decimal integers or decimal floats without
exponents. `(string->number TEXT)` accepts the source grammar for signed decimal
integers and decimal floats, with surrounding ASCII whitespace; conversion
failure is a diagnostic. Ratios, exponent notation, and reader expressions are
rejected. `keyword` remains equivalent to `symbol`: neither inserts a colon.
`keyword?` recognizes identifier spellings beginning with a colon and containing
at least one further character. `keyword-name` removes one leading colon;
`symbol->keyword` adds one unless already present, and `keyword->symbol` removes
one. The latter two operate on unqualified identifiers; invalid inputs fail.

### Compilation context and session state

| Operation | Result |
| --- | --- |
| `(compiler:feature? NAME)` | Case-insensitive reader feature membership; NAME is a string or identifier. |
| `(compiler:features)` | Copy of the effective reader feature names as normalized strings. |
| `(compiler:target-info)` | Plist with `:triple`, `:cpu`, `:pointer-width`, `:data-layout`, and `:object-format`; unavailable fields are `nil`. |
| `(compiler:state-ref KEY [DEFAULT])` | Stored value or default (`nil`). |
| `(compiler:state-has? KEY)` | Whether an entry exists, including entries holding `nil`. |
| `(compiler:state-set! KEY VALUE)` | Store VALUE and return a copy of it. |
| `(compiler:state-remove! KEY)` | Remove the entry and return whether it existed. |

These operations require an active compilation context. The frontend reports
only available target facts; it does not use host facts for cross targets.
LLVM CPU feature strings are separate from reader features. Reader conditionals
are selected before macros run and cannot be changed by state writes.

State operations may also appear directly at module top level. Top-level
`let`, `cond`, `and`, and `or` can compose and sequence state operations using
the same evaluator semantics as macro bodies. These expressions run during
collection in source order, including when emitted by a macro. Their return
values are discarded as data; they do not implicitly emit declarations.

```lisp
(compiler:state-set! 'models:types nil)
(let ((entries (compiler:state-ref 'models:types)))
  (compiler:state-set! 'models:types (append entries '(Point))))
```

One fresh store belongs to each build, development macro-expansion request, or
IDE analysis generation. Every module in that compilation shares it.
Unqualified keys are session-global. Qualified keys such as `'models:types`
use the invoking module's import aliases or full imported module identity;
self qualification works during collection. The named state entry needs no
declaration or export. Unknown or ambiguous qualifiers are errors.
Qualification in composite keys is normalized recursively at the state boundary;
ordinary quoted qualified names remain unchanged elsewhere.

State holds only finite macro S-expressions. Reads, writes, and returned values
copy lists, names, and strings so callers cannot alter stored values indirectly.
The lexical environment still comes from the macro definition; session and
module context come from the active invocation and restore on return or error.

Top-level expansion follows source order. An import loads and collects its
module immediately, depth first in source import order; each module is loaded
once per session. Missing keys never trigger loading. After collection, body
analysis visits modules in dependency-first depth-first source-import order,
and declarations in source order. Within expressions, expansion follows the
type checker's deterministic operand traversal and demand-driven specialization.
Each source expression's outer expansion is cached for the session, including
across specializations, so revisiting it does not repeat mutations. State reads
in cached expressions also retain their first expansion result.

IDE generations replay the entire required import closure rather than reusing
expanded environments. Successful products retain their session; failed or
cancelled generations are never reused by a later analysis. Independent builds
and concurrent requests have separate stores. There is no partial state replay.

`compiler:map`, `compiler:reduce`, and `compiler:reduce-right` construct calls;
they do not invoke arbitrary compile-time functions. Callable helpers, general
map/filter/fold, and resolved-type reflection remain outside this language.
See [the runnable registry example](../projects/macro-expansion/README.md).

### Reader forms

These forms are recognized by the reader and evaluator; they are not function
bindings.

| Form | Meaning |
| --- | --- |
| `'FORM` | Quote `FORM` as an S-expression. |
| `` `FORM`` | Quasiquote an S-expression template. |
| `,FORM` | Evaluate `FORM` and insert its S-expression value into a quasiquote template. |

For example:

```lisp
(import base)

(base:macro generated-function (type)
  `(base:function ,(keyword-concat (keyword "generated-") ,type)
     () ,type 42))

(generated-function i32) ; defines generated-i32
```

At the top level, a macro may return any ordinary top-level form, including
`base:implementation`; expansion then continues normally and the resulting
form is compiled as though it had appeared in the source. In an executable
expression position, it returns exactly one expression form, which expands
before resolution and type checking. A declaration wrapper can preserve its
arguments with `(cons '%function arguments)` (or the appropriate `%…` name),
so declaration syntax remains entirely expressible as a macro.

### Primitive definition API

The compiler-facing `%type`, `%function`, `%external-function`, `%macro`,
`%constant`, `%variable`, `%generic`, `%implementation`, and `%protocol`
forms accept named, source-aware clauses.  This API is intended for generated
definitions and compiler clients; the surface forms above remain available.
Every declaration accepts optional `(:documentation "text")`, retained on the
collected declaration with its source syntax.

```lisp
(%type Point
  (:type (product (x i32) (y i32)))
  (:documentation "A two-dimensional integer point."))

(%function add
  (:type (function ((left i32) (right i32)) i32))
  (:implementation (+ left right)))
```

Clause sets are declaration-specific: `%type` requires `:type`;
`%function`, `%constant`, and `%variable` require `:type` and
`:implementation`; `%external-function` requires `:type` and
`:external-name`; `%macro` requires `:parameters` and `:implementation`;
`%generic` requires `:parameters`; and `%protocol` requires `:parameters`
and `:operations`.  A generic `%implementation` uses `:generic`, `:type`,
and `:implementation`; a protocol `%implementation` uses `:protocol` and
`:operations`.  A clause may appear at most once.

### Platform feature conditionals

Prefix one form with `#+name` to include it when `name` is available, or with
`#-name` to include it when it is unavailable.  The reader still consumes
unselected forms, but they do not reach macro expansion or semantic analysis.
Feature names are case-insensitive.  Native compilation derives `darwin` or
`linux` from the selected target triple, so this works correctly for
cross-target compilation as well as the host target.  It also provides the
selected target's architecture (`x86_64`, `aarch64`, `arm`, or `riscv64`),
pointer width (`pointer_32` or `pointer_64`), endianness (`little_endian` or
`big_endian`), and object format (`macho` or `elf`).  Add project-specific conditions with
`verona compile --feature NAME`; repeat `--feature` for more than one.

```lisp
#+darwin
(external-function mach-task-self "mach_task_self" () u32)

#-darwin
(function mach-task-self () u32 0)
```

### Expressions and callable operations

Single-line comments begin with `;` and continue through the end of the line.
They are accepted anywhere whitespace is accepted, but a semicolon inside a
string or character literal remains literal data.

String literals use double quotes and accept ASCII only; they support `\\n`, `\\t`,
`\\"`, and `\\\\`. Unicode strings will use a separate `#ustring"..."` spelling.
Character literals use Common Lisp spelling: `#\\a`, `#\\space`, `#\\newline`,
`#\\tab`, `#\\vertical_tab`, `#\\form_feed`, and `#\\return`. A character literal
denotes exactly one ASCII character; the named spellings are case-insensitive.
A `char` automatically widens to an
integer when an integer is expected, which makes character literals and values
usable with C APIs such as `putchar`; integer-to-`char` conversion remains
explicit. Unicode characters are not supported yet.

| Form or function | Signature / behavior |
| --- | --- |
| `(let ((name Type initializer) ...) body)` | Introduces sequential immutable lexical bindings. Each initializer is resolved before its own name enters scope; a binding's address may be taken with `&`, but it cannot be assigned through its name. |
| `(match value (pattern expression) ...)` | Exhaustive pattern match. Supports `true`, `false`, integer literals, `_`, bindings, and sum constructor patterns. `_` discards its value and cannot be referenced in the case expression. |
| `(return value)` | Return from the enclosing function. |
| `(do expression...)` | Evaluate expressions in order and return the last value. |
| `(& place)`, `(address-of place)` | Create a pointer to an addressable place. |
| `(deref pointer)`, `(dereference pointer)` | Turn a pointer to a complete type into a place. |
| `(pointer-offset pointer integer)` | Advance a pointer by an element count. The pointer must target a complete type; callers are responsible for bounds and lifetime. |
| `(assign place value)`, `(store place value)` | Write a writable place. |
| `(cast Type value)` | Explicit pointer cast. |
| Function pointers | Write `(pointer (function (ParameterType...) ResultType))`. A named function automatically decays to that type when it is expected, including as an element of a fixed array. A function-pointer value, including an indexed array element, can be called with ordinary call syntax. |
| Numeric and comparison operators | Import `base` for the public protocol operations: `+`, `-`, `*`, `/`, `=`, `<`, `<=`, `>`, and `>=`. `base:numeric`, `base:equality`, and `base:ordering` provide them for constrained parametric code. |

Addressable places are read implicitly wherever a value is required. For
example, `(deref pointer)` reads the pointed-to value when it appears as a
function argument, initializer, return value, or arithmetic operand; it remains
a place when used with `&`, `assign`, or `store`.

The compiler also exposes concrete bootstrap primitives. They are for compiler
tests and generated library code; ordinary `.vrn` programs must use operations
exported by a module such as `base`, rather than calling the internal `%…`
primitives directly:

| Primitive family | Available names |
| --- | --- |
| Integer arithmetic | `%+-primitive-T`, `%-primitive-T`, `%*-primitive-T`, `%/-primitive-T` for `T` in `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`. |
| Integer comparison | `%=`, `%/=`, `%<`, `%<=`, `%>`, `%>=` with the same `-primitive-T` suffix. |
| Float arithmetic and comparison | The same arithmetic and comparison spellings with `-primitive-f32` and `-primitive-f64`. |
| Boolean operations | `%not-primitive-bool`, `%and-primitive-bool`, `%or-primitive-bool`, `%=-primitive-bool`, and `%/=-primitive-bool`. |
| Integer width conversion | `%sext-primitive-S-D`, `%zext-primitive-S-D`, and `%trunc-primitive-S-D`, for valid widening, zero/sign-extending, and narrowing integer pairs. |
| Same-width signedness conversion | `%reinterpret-primitive-S-D`, for signed/unsigned integer types of the same width. It preserves the bit pattern. |
| Integer/float conversion | `%sitofp-primitive-I-F`, `%uitofp-primitive-U-F`, `%fptosi-primitive-F-I`, `%fptoui-primitive-F-U`, `%fext-primitive-f32-f64`, and `%ftrunc-primitive-f64-f32`. |

## Common Lisp front-end API

### Source and syntax

| Function | Description |
| --- | --- |
| `make-source name contents` | Create a `source` from diagnostic name and text. |
| `source-from-file pathname` | Read a file into a source object; signals `source-error` on I/O failure. |
| `make-syntax datum source start end` | Create a source-spanned syntax object. |
| `syntax-with-datum syntax datum` | Copy `syntax`'s source span while replacing its datum. |
| `read-source source &key features` | Parse selected forms in a source, returning source-aware syntax objects. `features` controls `#+`/`#-` conditionals. |
| `make-verona-name value` | Make a case-sensitive identifier. |
| `verona-name= left right` | Compare two identifiers by exact spelling. |
| `make-module-name &rest components` | Make a non-empty dotted module identity from Verona names. |
| `module-name= left right` | Compare module identities component by component. |
| `module-name-string name` | Render a module identity as `component.component`. |
| `make-qualified-name qualifier name` | Build a structured `module:name` reference. |
| `qualified-name-string name` | Render a qualified name. |
| `make-verona-list &rest elements` | Make a list datum from syntax elements. |

Reader predicates and accessors are also public: `source-name`,
`source-contents`, `source-location-offset`, `source-location-line`,
`source-location-column`, `syntax-datum`, `syntax-source`, `syntax-start`,
`syntax-end`, `verona-name-p`, `verona-name-value`, `module-name-p`,
`module-name-components`, `qualified-name-p`, `qualified-name-qualifier`,
`qualified-name-name`, `verona-list-p`, and `verona-list-elements`.
`verona-symbol-p` and `verona-symbol-name` are compatibility aliases for the
Verona-name API.  `unit-literal-p`, `verona-boolean-literal-p`, and
`verona-boolean-literal-value` inspect reader literal datums.

### Compile-time evaluator

| Function | Description |
| --- | --- |
| `make-environment &optional parent` | Create a lexical evaluator environment. |
| `environment-bind environment name value` | Bind or replace a value in one environment. |
| `environment-lookup environment name` | Resolve a name through parent environments; signals `unbound-name-error` when absent. |
| `environment-child environment` | Create a child environment. |
| `make-verona-function implementation` | Wrap a host function that receives evaluated Verona values. |
| `make-verona-macro implementation` | Wrap a host function that receives unevaluated S-expressions and returns an S-expression. |
| `evaluate syntax environment` | Evaluate a bootstrap evaluator expression. |
| `expand syntax environment` | Expand macros at a syntax form's head. |
| `make-bootstrap-environment` | Create the evaluator environment containing the standard definition-form macros. |

Predicates `verona-callable-p`, `verona-function-p`, and `verona-macro-p`
classify evaluator callables.  `environment-parent`,
`verona-function-implementation`, and `verona-macro-implementation` retrieve
their associated objects.

### Compilation and modules

| Function | Description |
| --- | --- |
| `make-compiler &key search-paths` | Create a front end. Search paths are used by `compile-file` and `compile-module`. |
| `target-feature-names target` | Return source-reader features for a target: platform, architecture, data layout, object format, and explicit reader features. |
| `compile-string compiler contents &key name target pointer-width` | Compile in-memory source into a compilation unit. |
| `compile-file compiler pathname &key target pointer-width` | Compile a root `.vrn` file and its imports. |
| `compile-module compiler name &key target pointer-width` | Find and compile a named module from the compiler search paths. |
| `find-declaration unit name` | Return a declaration and a presence flag from the unit namespace. |
| `module-lookup module name` | Compatibility alias for `find-declaration`. |
| `unit-declarations unit` | Return declarations in discovery order. |
| `register-declaration unit declaration` | Add a declaration, rejecting duplicate non-implementation names. |
| `module-find-export module name` | Return an exported declaration, or `nil`. |
| `module-loader-load loader name` | Load one module recursively through a `module-loader`. |

The compiler/unit/module accessor functions are `compiler-search-paths`,
`compilation-unit-source`, `compilation-unit-forms`,
`compilation-unit-declarations`, `compilation-unit-namespace`,
`compilation-unit-environment`, `compilation-unit-compile-time-environment`,
`compilation-unit-semantic-program`, `module-name`, `module-pathname`,
`module-identity-explicit-p`, `module-imports`, `module-exports`,
`module-native-export-specs`, `module-source`, `module-forms`,
`module-declarations`, `module-namespace`, `module-environment`,
`module-loader-search-paths`, `module-loader-loaded-modules`,
`module-graph-modules`, and `module-graph-edges`.

`import-module`, `import-alias`, `native-export-spec-name`,
`native-export-spec-external-name`, and `native-export-spec-source` inspect
module edges and C-export requests.

### Declaration, semantic, and type inspection

Compilation creates source declarations first, then semantic declarations and
expressions.  The following accessor families expose every field without
requiring slot access:

| Family | Public accessors |
| --- | --- |
| Source declarations | `declaration-name`, `declaration-source`, `declaration-expanded-syntax`, `declaration-module`, `declaration-compilation-unit`, `declaration-documentation`, `declaration-documentation-syntax`, and `declaration-type-declaration`; `type-declaration-kind`, `type-declaration-body`, `type-alias-declaration-target`; `function-declaration-parameters`, `function-declaration-return-type`, `function-declaration-body`; `external-function-declaration-external-name`, `external-function-declaration-parameter-types`, `external-function-declaration-result-type`; `macro-declaration-parameters`, `macro-declaration-body`; `constant-declaration-type`, `constant-declaration-value`; `variable-declaration-type`, `variable-declaration-initializer`; `generic-declaration-parameters`, `generic-declaration-arity`; `implementation-declaration-generic-name`, `implementation-declaration-parameters`, `implementation-declaration-return-type`, `implementation-declaration-body`. |
| Scopes and programs | `make-semantic-scope`, `semantic-scope-child`, `semantic-scope-bind`, `semantic-scope-find`, `semantic-scope-lookup`, `semantic-scope-parent`, `semantic-scope-owning-program`, `semantic-scope-owning-type-context`, `semantic-scope-owning-function`; `semantic-program-module-scope-for`, `semantic-program-declaration`, `make-bootstrap-semantic-scope`; `semantic-program-bootstrap-scope`, `semantic-program-module-scope`, `semantic-program-declarations`, `semantic-program-type-context`, `program-entry-module`, `program-modules`, `program-module-graph`, `program-target`, `semantic-program-native-exports`. |
| Bindings and generics | `semantic-binding-name`; parameter, pattern, and let-binding accessors prefixed `parameter-binding-`, `pattern-binding-`, and `let-binding-`; `generic-name`, `generic-arity`, `generic-implementations`, `generic-find-implementation`; `generic-binding-generic`; and generic-implementation accessors prefixed `generic-implementation-`. |
| Semantic declarations | `semantic-declaration-source-declaration`; accessors prefixed `semantic-type-declaration-`, `semantic-type-alias-declaration-`, `semantic-constant-declaration-`, `semantic-variable-declaration-`, `semantic-function-declaration-`, `semantic-external-function-declaration-`, and `semantic-generic-implementation-`. |
| Expressions and patterns | `semantic-expression-syntax`, `semantic-expression-type`, `expression-syntax`, `expression-source`, `expression-type`; accessors prefixed `semantic-reference-`, `semantic-call-`, `external-call-expression-`, `primitive-call-`, `conversion-expression-`, `pointer-cast-expression-`, `construct-expression-`, `sum-construct-expression-`, `field-expression-`, `sequence-expression-`, `let-expression-`, `address-expression-`, `dereference-expression-`, `load-expression-`, `assignment-expression-`, `store-expression-`, `return-expression-`, `pattern-`, `literal-pattern-`, `binding-pattern-`, `constructor-pattern-`, `match-case-`, and `match-expression-`. |

The analysis functions are `resolve-type`, `resolve-types`,
`make-type-checker`, `type-check-expression`, `type-check-program`,
`infer-expression`, `check-expression`, `build-semantic-expression`,
`resolve-compilation-unit`, `resolve-program`, `same-type-p`, `compatible-p`,
`validate-for-backend`, `backend-representable-type-p`, and `verona-type-name`.
`type-check-program` validates executable bodies after declaration signatures
are known. Generic dispatch uses argument types and, for result-directed
generics such as `base:convert`, the expected result type. These functions
operate on the advanced semantic representation and may signal the exported
semantic error conditions.

Advanced declaration-pipeline functions are `definition-form-p`,
`expand-top-level`, `process-definition`, `make-top-level-expansion-result`,
and `top-level-expansion-result-definitions`.  They are useful when embedding
the definition collector rather than calling `compile-string` or
`compile-file`.

Primitive inspection uses `builtin-type-binding-type`,
`builtin-intrinsic-binding-type`, `primitive-binding-operation`, and
`primitive-operation-identity`, `primitive-operation-name`,
`primitive-operation-parameter-types`, `primitive-operation-result-type`,
`primitive-operation-kind`, and `primitive-operation-nan-semantics`.
`native-export-binding-function` and `native-export-binding-external-name`
inspect resolved C exports.

`make-type-context` makes canonical types. Its constructors/cache accessors
are `type-context-unit-type`, `type-context-void-type`, `type-context-never-type`,
`type-context-unit-value`, `type-context-pointer-width`,
`type-context-unit-representation-type`, `type-context-boolean-type`,
`type-context-char-type`, `type-context-integer-type`,
`type-context-float-type`, `type-context-pointer-type`,
`type-context-function-type`, `type-context-defined-type`,
`type-context-opaque-type`, `type-context-product-type`, and
`type-context-sum-type`.
`unit-machine-representation` returns the target-sized unit representation.

Type accessors are `integer-type-signed`, `integer-type-width`,
`float-type-width`, `pointer-type-target`, `pointer-type-pointee`,
`function-type-parameters`, `function-type-result`,
`defined-type-declaration` (including `opaque-type`), `product-type-fields`, `product-type-find-field`,
`product-field-name`, `product-field-type`, `product-field-index`,
`product-field-source`, `sum-type-alternatives`, `sum-type-find-alternative`,
`sum-alternative-sum-type`, `sum-alternative-name`, `sum-alternative-index`,
`sum-alternative-payload-types`, and `sum-alternative-source`.

## LLVM backend API

Use this layer after `compile-string` or `compile-file`, passing the unit's
`compilation-unit-semantic-program` to `generate-llvm`.

| Function | Description |
| --- | --- |
| `native-target-triple` | Return LLVM's host target triple. |
| `make-target-configuration &key triple cpu features relocation-model code-model` | Describe an LLVM target. Relocation values are `:default`, `:static`, `:pic`, and `:dynamic-no-pic`; code-model values are `:default`, `:jit-default`, `:small`, `:kernel`, `:medium`, and `:large`. |
| `make-llvm-backend &key module-name target-configuration optimization-level` | Allocate an LLVM module, builder, target machine, and canonical type context. |
| `generate-llvm program &key module-name target-configuration optimization-level` | Lower a semantic program into a populated backend. |
| `verify-llvm-module backend` | Signal on invalid LLVM IR; return the backend when valid. |
| `print-llvm-module backend` | Return LLVM textual IR. |
| `emit-object backend output` | Verify and emit an object file. |
| `emit-output program output &key configuration` | Emit IR, an object, or an executable according to `codegen-configuration-output-kind`. |
| `build-executable program output &key configuration` | Legacy convenience path that lowers and links an executable. |
| `add-platform-entry-wrapper backend program` | Add the C `main` adapter for a Verona `main : () -> exit-code` or `main : (i32, (pointer (pointer u8))) -> exit-code`. |
| `validate-executable-entry-point program` | Validate that executable entry-point contract. |
| `lower-type backend type` | Lower a canonical Verona type to LLVM. |
| `emit-value backend expression` | Emit an LLVM value for a resolved expression. |
| `emit-place backend expression` | Emit the LLVM address for an addressable expression. |
| `hide-verona-symbols backend program` | Give non-native-exported functions internal LLVM visibility. |

Backend configuration/readback accessors are `llvm-backend-context`,
`llvm-backend-module`, `llvm-backend-builder`, `llvm-backend-target-triple`,
`llvm-backend-data-layout`, `llvm-backend-pointer-width`,
`llvm-backend-target-machine`, `llvm-backend-target-configuration`,
`target-configuration-triple`, `target-configuration-cpu`,
`target-configuration-features`, `target-configuration-relocation-model`,
`target-configuration-code-model`, `make-codegen-configuration`,
`codegen-configuration-target`, `codegen-configuration-optimization-level`,
`codegen-configuration-relocation-model`, `codegen-configuration-code-model`,
`codegen-configuration-output-kind`, `make-linker-configuration`,
`linker-configuration-executable`, `linker-configuration-arguments`,
`linker-configuration-libraries`, `linker-configuration-library-paths`, and
`linker-configuration-framework-paths`.

## Native compiler-driver and build API

`resolve-verona-environment` reads the required independent
`VERONA_SOURCE_DIR` and `VERONA_LIBRARY_DIR` variables. They identify the
canonical Verona package source and artifact roots, respectively, and must be
absolute paths. They do not affect C-library lookup; native C libraries remain
per-build `-L`, `-l`, or `pkg-config` inputs.

Verona 0.1.0 is the initial release line. `verona --version` prints the
version declared by the primary compiler system. Bundled libraries declare the
same release version in their build metadata.

| Function | Description |
| --- | --- |
| `resolve-compilation-target &key triple cpu features reader-features` | Resolve LLVM target data, pointer width, platform, object format, and optional explicit Verona reader features before front-end analysis. |
| `verona-version` | Return the primary compiler release version. |
| `resolve-verona-environment &key getenv` | Read and validate the required Verona source and library roots. `getenv` supports embedding and tests. |
| `make-link-options &key libraries library-search-paths frameworks` | Build native linker options. |
| `make-native-toolchain &key compiler archiver` | Create the default linker/archiver adapter. Defaults read `VERONA_LINKER` and `VERONA_AR`. |
| `make-compiler-driver &key search-paths target optimization-level toolchain` | Configure a reusable native compiler driver. |
| `compile-root driver root &key artifact-kind output link-options` | Compile a root module to `:object`, `:executable`, `:static-library`, or `:shared-library`. |
| `compile-file driver pathname &rest arguments` | Alias-style convenience entry to `compile-root`. |
| `default-output-path root kind target` | Compute the platform-correct default artifact pathname. |
| `toolchain-emit-object toolchain backend output` | Generic protocol operation for object production. |
| `toolchain-link-executable toolchain object output target options` | Generic protocol operation for executable linking. |
| `toolchain-archive-static-library toolchain object output target` | Generic protocol operation for static library creation. |
| `toolchain-link-shared-library toolchain object output target options` | Generic protocol operation for shared-library linking. |

Driver accessors are `compiler-driver-search-paths`, `compiler-driver-target`,
`compiler-driver-optimization-level`, `compiler-driver-toolchain`,
`verona-environment-source-directory`, `verona-environment-library-directory`,
`compilation-target-triple`, `compilation-target-cpu`,
`compilation-target-features`, `compilation-target-data-layout`,
`compilation-target-reader-features`,
`compilation-target-pointer-width`, `compilation-target-object-format`,
`compilation-target-platform`, `artifact-kind`, `artifact-path`,
`artifact-target`, `link-options-libraries`, `link-options-library-search-paths`,
and `link-options-frameworks`.

### Declarative builds

`verona.build` accepts an `(executable NAME ...)`, `(static-library NAME ...)`,
or `(shared-library NAME ...)` target. Every target needs exactly one
`(root module.name)`. Optional clauses are `(module-path "PATH")`,
`(target native)` or `(target "TRIPLE")`, `(optimize 0|1|2|3)`,
`(version "VERSION")`, `(features NAME...)`, `(library "NAME")`, `(library-path "PATH")`, and
`(framework "NAME")`.  `features` may appear once per target and supplies
reader conditions to that target and all of its imported Verona modules.
The combined feature list is append-only: compiler-provided features come
first, then `verona build … --feature NAME` flags, then this target's
`features` clause.

```lisp
(executable app
  (root app.main)
  (features sqlite telemetry))

(static-library example
  (root example)
  (version "0.1.0"))
```

| Function | Description |
| --- | --- |
| `make-build-name value`, `build-name=` | Create and compare target names. |
| `make-build-invocation target-name output-directory` | Select a target and output directory for a build invocation. |
| `parse-build-source source &key directory` | Parse build configuration without evaluating Verona code. |
| `parse-build-file pathname` | Read and parse a `verona.build` file. |
| `find-build-target file name` | Retrieve one parsed target. |
| `locate-build-file &optional directory` | Find `verona.build` in a directory. |
| `build-target-artifact-kind target` | Return the target's driver artifact kind. |
| `execute-build file invocation &key toolchain` | Validate and build the selected target. |

Build accessors are `build-name-p`, `build-name-value`, `build-file-source`,
`build-file-targets`, `build-target-name`, `build-target-root-module`,
`build-target-module-paths`, `build-target-compilation-target`,
`build-target-optimization`, `build-target-link-options`,
`build-invocation-target-name`, and `build-invocation-output-directory`.

## Errors

All APIs signal Common Lisp conditions rather than returning error sentinels.
The most useful common readers are `source-error-message`,
`verona-read-error-source`, `verona-read-error-location`,
`verona-read-error-message`, `definition-error-syntax`,
`semantic-error-syntax`, `semantic-error-message`, and
`compiler-driver-error-message`.

Use the exported condition types to handle a specific layer: source/reader
errors (`source-error`, `verona-read-error`); declaration and module errors
(`definition-error`, `duplicate-declaration-error`, `module-error`); semantic
errors (`semantic-error`, `type-mismatch-error`, `unresolved-name-error`, and
match/type/generic subtypes); LLVM errors (`llvm-backend-error`,
`target-configuration-error`, `object-emission-error`, `entry-point-error`,
`linker-error`); and driver/build errors (`compiler-driver-error`,
`toolchain-failure`, `build-error`).  Error-specific readers share the
condition's hyphenated prefix, for example `type-mismatch-error-actual`,
`type-mismatch-error-expected`, `toolchain-failure-stderr`, and
`build-error-message`.


## IDE sessions

Load `verona/ide` for the transport-independent `verona.ide` API. A session
store belongs to the server, not an editor connection. `create-session` returns
a stable store-local ID and reuses sessions with equal project configuration.
Different canonical project roots and target configurations remain independent.
`attach-session` and `detach-session` track opaque connection IDs; detaching
preserves state. `expire-sessions` explicitly expires detached sessions after
one day by default. `close-session` removes all store-owned session resources;
subsequent operations on the ID signal an error.

`make-configuration` accepts a project root, build file/target, ordered search
paths, package locations, target descriptor and reader features. The default
root is the current directory and the default search path is that root. Reader
features default to the compiler target features; explicit `:reader-features nil`
selects an empty feature set.
Load `verona/ide/project` to use `discover-project-configuration`, which reuses
the build parser, target resolver and package environment. It requires a
`verona.build` file in the selected root; missing files are rejected.
`inspect-project` reads the same file and returns target metadata without
creating a session or resolving the package environment. A sole build target
is selected automatically; multiple targets require a selection. Its
`:overrides` keyword plist replaces individual discovered fields.
`configure-session` increments the configuration revision when settings change;
a session's project root, selected build target and target descriptor cannot
change. Select or create a separate session when switching targets to retain
their caches. Reconfiguration also rejects a configuration already owned by
another session. Explicit `:search-paths nil` overrides the default root path.
The store copies configurations on entry and inspection.

`open-buffer` associates an editor buffer ID with a canonical file path or a
separate unnamed source ID and an optional module context. Each source has one
mutable `source-record`. `edit-buffer` overwrites its contents and advances its
revision; the session does not retain previous versions of the source text.
`read-source` prefers an open buffer and otherwise refreshes the stored contents
from disk. `save-buffer` acknowledges an editor save after verifying disk
contents; `rename-buffer` changes source identity after an editor rename.
Neither writes files. `close-buffer` discards the overlay; the next file read
uses disk contents. Opening, editing, saving, renaming, closing, and refreshing
a source do not evaluate it, invalidate analysis, or cancel pending evaluation.

`begin-request` is the explicit user evaluation boundary. It submits the latest
file or buffer contents, recording the session ID, source ID, module context,
source revision and configuration revision. The request holds its input text
only while pending; later edits do not alter that input or prevent publication.
Completed, failed, cancelled and stale requests release their input text.
`source-state` reports the latest source revision and the single submitted
evaluation revision, alongside the request status (`:unsubmitted` before the
first evaluation). There is no retained successful revision or fallback result.

`begin-request` replaces the module's state immediately, clearing declarations,
compile-time bindings, products, diagnostics and the previous query result.
`publish-result` stores the current evaluation's value even when `:failed t`;
`:diagnostics` adds current diagnostics. It returns `:complete`, `:failed`,
`:cancelled` or `:stale`. `query-result` returns only this evaluation's result
and `:current`, `:stale` or `:missing`. Current describes evaluation state even
if the buffer has since been edited. While a replacement is pending, cancelled,
or has failed through `record-phase`, there is no published aggregate result;
partial products remain accessible through `module-state`.

`module-state` takes a session and source ID and returns a snapshot plist:

- `:identity`: the resolved module context and canonical source ID. Equal module
  names at different paths are independent. Without an explicit module context,
  the file basename (or unnamed buffer ID) supplies the provisional name.
- `:source-id`, `:source-path`, `:source-revision`, `:configuration-revision`:
  the input identity and revisions for the current evaluation.
- `:status`: `:pending`, `:processing`, `:complete`, `:failed`,
  `:needs-evaluation`, or `:cancelled`.
- `:phase`, `:completed-phases`, `:failed-phase`: processing progress.
- `:products`, `:diagnostics`: current compiler products and source-linked
  diagnostics, including valid partial results.
- `:dependency-environments`: module identities, source/configuration revisions
  and evaluation generations in the shared semantic graph used for analysis.

`record-phase` takes the session, request and next phase, in order: `:reading`,
`:expansion`, `:declarations`, `:resolution`, `:type-checking`. Its `:products`
plist accepts the following keys:

| Phase | Products |
| --- | --- |
| `:reading` | `:syntax` (preserving source locations) |
| `:expansion` | `:expanded-forms`, `:macros`, `:bindings` |
| `:declarations` | `:declarations`, `:imports`, `:exports` |
| `:resolution` | `:resolved-definitions` |
| `:type-checking` | `:types` |

Macro and binding values are returned as `(:module identity :definitions value)`
so entries retain their originating module and caller-supplied definition data.
Compile-time products are distinct from semantic products. No operation here
executes application code. `:complete nil` records progress within a phase;
the default completes it. `:failed t` terminates the request, identifies the
failed phase and retains its partial products and `:diagnostics`. Consumers
must check completed phases before treating a product as complete. Successful
aggregate publication requires every phase to have completed when phases are
reported; it also supports callers that do not yet report phases.

`evaluate-module` connects these operations to the compiler pipeline. It takes a
store, session ID and session source record or file path, and returns a request.
It always replaces the requested module, refreshes disk inputs, and prefers
unsaved buffer overlays. It reads, expands, collects declarations, resolves and
type-checks the required transitive module graph. It does not execute application
bodies, lower LLVM, link, or emit artifacts. Inspect `request-status`,
`module-state`, and `query-result` for the outcome; successful aggregate values
are compiler module objects. Compiler products are read-only inspector objects;
plist/list metadata is copied, while compiler objects retain their identities.

Every explicit action captures buffer overlays and the required source closure
before compiler callbacks run. Later edits, saves or closes do not change those
inputs. Sources on disk are captured during closure discovery; this is not an
atomic filesystem snapshot. Imports, reader conditionals, ordered macro
expansion, declaration collection, resolution and type checking use the same
implementations as project compilation. Expansion and declaration processing
are interleaved in language order; their separate phase products describe the
completed collection boundaries. Source locations and macro expansion origins
remain attached to syntax and declarations.

Every action walks all required imports, including imports of cached modules.
Dependencies with matching source/configuration revisions, complete current
state and unchanged imported module environments reuse their declarations and
compile-time environments. Missing, edited, failed, cancelled or invalidated
dependencies are collected again. The requested graph is resolved and checked
in one shared semantic/type context, preserving compiler semantics for generics
and protocols; semantic resolution is currently graph-wide. Successful new
results publish in dependency order, with the requested module last.

Missing prerequisites and forbidden import cycles fail the action. Current
partial products and discovered edges remain visible; later phases stop.
Diagnostics use the compiler diagnostic representation, with
`:prerequisite-failures` in diagnostic `:data` when other modules failed.
Unavailable imports retain candidate canonical identities and lookup context,
so their arrival can mark users as needing evaluation. Queries never read or
analyze prerequisites, and edits alone never change evaluation state.

For queued or cancellable evaluation, call `begin-request`, then
`evaluate-request`. Its optional `:progress` callback takes the current module
request and phase; a phase may report incomplete progress more than once.
Callbacks run outside the session mutex and can inspect, edit, cancel or submit
another evaluation. `cancel-request` cancels all pending prerequisites in the
same action. Cancellation is cooperative at compiler observation and phase
boundaries. A new explicit evaluation supersedes the old action, including when
it reevaluates one of its prerequisites; generation checks prevent stale
products, diagnostics, edges and reusable environments from being published.
Terminal requests release their pending source text and never restore old
products.

Superseded, cancelled and terminal requests cannot publish products or replace
the current state. Explicit evaluation marks direct and transitive dependent module states
`:needs-evaluation` and their aggregate results stale using the current graph.
Unrelated completed results remain current. Dependents are not evaluated automatically.
Source edits alone never mark dependents or cancel pending requests.
Configuration changes mark module states as needing evaluation and invalidate
pending requests. `reset-session` clears analysis while preserving buffers and
source revisions. State operations are serialized with a store mutex on SBCL;
implementations without thread support require callers to serialize access.

`build-inputs` is an explicit operation describing a disk build with the session
ID, configuration revision and captured file contents, source IDs and revisions.
Its `:paths` argument includes inputs not yet opened or read by the IDE. Repeated
captures of unchanged files retain their revisions. Build inputs use a separate
registry and never replace analysis overlays or trigger evaluation. Unsaved
buffers are rejected unless the caller explicitly selects
`:unsaved-buffers :ignore`. Project builds capture the configured module search
paths, including transitive sources, and compile private copies of these contents. IDE evaluation never runs
application code or writes build artifacts; it may evaluate compile-time macros.

### Explicit project builds and execution

Load `verona/ide/project` in an SBCL server with the same Nix toolchain environment
used for CLI builds. Workers use `sbcl` from `PATH` (override its executable with
`VERONA_IDE_SBCL`) and inherit `VERONA_CL_LLVM`, linker and package settings.
`verona/ide` and `verona/swank` remain usable without LLVM or build support.

These functions take a session store and session ID first. When project support
is loaded, Swank advertises matching keyword operations; RPC arguments omit the
store and session ID. Connections must attach before using them.

| Operation | Remaining arguments | Behavior |
| --- | --- | --- |
| `start-build` | `&key (unsaved-buffers :reject)` | Return `:build` token and `:building` status. |
| `build-status` | token, `&key (offset 0) (error-offset 0) (limit 16384) output` | Poll stage, status, diagnostics, artifact and bounded stdout/stderr. |
| `cancel-build` | token | Terminate the compiler process group; mark an active build cancelled. |
| `start-program` | token, `&key arguments directory environment` | Run this successful host executable, with argument strings, working directory and `NAME=value` environment overrides. |
| `program-input` | token, text, `&key eof` | Write and flush standard input, optionally closing it. |
| `stop-program` | token | Stop the program and close its input. |
| `release-build` | token | Stop owned processes and delete this build's snapshot, logs and artifacts. |

Builds use the session's selected target, effective module paths, target triple
and reader features, plus the captured build file's optimization and native
library options. Each invocation parses saved build metadata and captures saved
`.vrn` files in the ordered module search directories before launching. The
compiler's existing dependency loader, native compiler and linker consume these
copies through `execute-build`; evaluated IDE products never substitute for
build inputs. The snapshot is a sequential file capture, not a filesystem-wide
atomic transaction. Native libraries and toolchain executables remain external
inputs. Unsaved overlays require explicit `:ignore`; the editor offers saves and
names any remaining modified project buffers before requesting this policy.

A fresh compiler process reports `:compiling`, `:emitting`, and `:linking` stages.
Build status becomes `:succeeded`, `:failed`, or `:cancelled`; only success exposes
`:artifact`, `:artifact-kind`, and the actual `:artifact-target` triple. Artifacts
live in a unique build-owned temporary directory, so failed builds cannot reuse
an older output. Metadata includes the selected target, effective configuration
and its revision, saved build file text, source IDs/paths/revisions and
`:input-coverage :search-path-snapshot` (all captured search-path sources, not
only imported modules). Source snapshots and results persist until release or
session close/expiry. Resetting analysis preserves build jobs.

`:diagnostics` contains compiler diagnostics with original saved-file locations;
raw tool output, including unlocated linker output, remains in stdout/stderr.
These locations describe the captured files and may differ from later edits.
Each output stream returns `:text`, `:next-offset`, and `:truncated`; pass the
returned offsets to fetch more. `:limit` is 1–65536 characters per stream.
`:output :build` and `:output :program` select retained logs explicitly; the
default selects program logs once execution has started. Build `:exit-status`
and program `:run-exit-status` are separate. Program status is `:not-started`,
`:running`, `:exited`, or `:stopped`. A program can be started again after exit.

Execution requires a succeeded executable whose emitted target triple exactly
matches the host triple. Cross-target compilation and library builds use the
ordinary driver; incompatible executables and libraries cannot be run.
Arguments are passed directly without shell interpretation. Working directory
defaults to the project root; environment overrides extend inherited settings.
Saving, building and running preserve module states and analysis diagnostics.
Build logs are presented separately in Emacs compilation buffers.

### IDE dependency graph

`record-dependencies` takes a store, session ID, current request and a list of
edge plists. `evaluate-module` records imports, macro uses and semantic or
expanded references during compiler traversal. Definition identities produced
by this integration are identifier strings. Recording `:imports` products alone
does not infer edges from arbitrary caller data.

Each edge requires `:kind` (`:import`, `:semantic`, `:macro`, `:binding`, or
`:expanded`) and `:target`, the full module identity returned by `module-state`
(a module context and canonical source identity). Targets need not have been
evaluated. Equal module names at different sources remain distinct.
`:from` and `:to` carry originating and referenced definition identities,
including functions, types, constants, generics, protocols and implementations;
`:location` carries the reference source location. Import edges may also carry
`:alias` and `:selected`. Macro and binding edges identify compile-time uses;
`:expanded` edges identify references introduced by expansion. Definitions and
locations are supplied by the analysis caller, without reinterpretation.

Missing modules or definitions use the expected `:target` identity and, for a
missing definition, `:to`, plus `:unresolved t` and required `:lookup-context`.
These references remain queryable with their locations. Evaluating the missing
target module marks its users even on the target's first evaluation. This does
not silently resolve old edges; users must be explicitly evaluated again.

Calls append discoveries, deduplicating identical edges. Each batch is validated
before mutation. Superseded, cancelled and terminal requests cannot add edges.
At `begin-request`, affected dependents are captured before previous outgoing
edges are removed. Incoming references survive, including references to removed
definitions. Discovered partial edges remain after failure or cancellation.
Source edits and buffer lifecycle operations leave edges unchanged.

`dependency-graph` takes a store, session ID and module identity. It returns
`:edges`, `:complete`, `:incomplete-modules`, and `:needs-evaluation-reasons`.
Use `:direction :dependencies` (default) or `:dependents`, `:transitive t` for
reachability, or `:imports-only t` to restrict traversal to imports. Module-level
traversal is the default. Use `:level :definition` and `:definition identity`
for definition relationships. Traversal terminates through cycles. Returned
lists and strings are snapshots that cannot mutate the graph.

Completeness describes the visited modules' outgoing discovery, not whether
references resolved or cached semantic results remain current. It requires a
successful evaluation with all phases completed through resolution; legacy
aggregate-only publication, pending, failed and cancelled evaluations remain
incomplete. Transitive queries include missing target modules in
`:incomplete-modules`. `module-state` also exposes `:dependency-complete` and
`:needs-evaluation-reasons`. Dependency reasons carry `:changed-module` and an
edge `:path`; configuration invalidation has reason kind `:configuration`.

`dependency-cycles` returns one snapshot per cyclic strongly connected component,
at `:level :module` (default) or `:definition`. Each component has `:nodes`,
`:edges` and `:status`. Nodes are `(module-identity definition-identity)` pairs;
the definition is `nil` at module level. Edges include all resolved relationships
within the component, retaining source locations and parallel references. They
are not an ordered path or an enumeration of every individual cycle. Self-loops
are included, while acyclic singleton nodes are omitted.

The analysis caller supplies language legality using edge `:cycle-policy
:allowed` (default) or `:forbidden`. Any forbidden internal edge makes its
component `:invalid`; otherwise it is `:allowed`. This classifies recorded
relationships; compiler validation still determines whether definitions satisfy
language rules. Unresolved edges do not establish cycles.

A second return value is a plist with `:complete` and `:incomplete-modules`,
covering every registered module and every referenced module in the snapshot.
Pending, failed, cancelled or missing discovery and unresolved edges make it
incomplete. An empty component list proves the evaluated graph acyclic only
when `:complete` is true. Completeness describes recorded evaluation state;
source edits alone do not refresh the graph.

Cycle queries copy the graph and completeness under the session mutex, then
perform iterative strongly connected component analysis outside the mutex.
Traversal takes O(V + E) time and space and does not use the Lisp call stack
for graph depth. Returned metadata cannot mutate session-owned graph data.

### Module browsing queries

The `verona.ide` module queries operate on one session snapshot under the session
lock. They never evaluate, refresh sources, scan directories, or build. Returned
lists and strings are isolated from session state; compiler objects are projected
into portable summaries rather than returned as mutable objects.

- `(discover-modules store id &key paths)` explicitly scans `.vrn` files beneath
  the supplied files/directories, defaulting to configured search paths. It
  registers canonical paths without reading contents or evaluating them, and
  returns sorted source identifiers. Repeated discovery is additive; missing
  files remain known. Names are provisional basenames until a source has an
  explicit module context. Symlink directory cycles are visited only once.
- `(list-modules store id &key name source-path status offset limit)` lists
  discovered sources, registered buffers/files, and evaluated modules. Name and
  path filters are case-insensitive substrings; status is an exact keyword.
  Listing never performs discovery. Ordering is by printed full module identity.
- `(inspect-module store id module)` returns identity, project root, target and
  build target, current and evaluated revisions, evaluation status, phases,
  invalidation reasons, and cached product availability. `:evaluated-p` means
  evaluation has been submitted, including pending/failed evaluation.
- `(module-contents store id module &key kind name offset limit)` queries one of
  `:declarations` (default), `:imports`, `:exports`, `:macros`, or `:bindings`.
  Each item has an `:id`, `:name`, and `:summary`. Summaries include declaration
  kinds/locations, import aliases/paths, export definitions, or local compile-time
  binding names. Callable values and compiler internals are represented by kind.
  Names sort deterministically, with original product order breaking ties.
  Declaration and macro identifiers use the definition-query identifiers below.
  Other content identifiers are `(module kind product-index)` and refer to the
  current evaluation only; retain the response's evaluation revisions with them.
- `(module-relationships store id module &key direction transitive imports-only
  offset limit)` reuses the dependency graph. Direction is `:dependencies` or
  `:dependents`. Items retain edge kinds, definition identities, source locations,
  unresolved lookups and import metadata. Responses include graph completeness,
  incomplete modules, and reasons evaluation is needed. Edges sort by their
  printed portable descriptors. Completeness describes known graph discovery;
  it does not assert that every source in the project has been discovered.
- `(module-diagnostics store id module &key severity phase definition offset limit)` returns only
  current evaluation diagnostics, with their originating processing phases,
  severity, message, code, source ranges and structured data. Ordering is emission
  order. Severity filters by exact keyword.

`module` is the full `(module-context source-id)` identity returned as `:id` by
listing/inspection. Equal names at different paths remain distinct. Unknown
identities signal an error without looking them up on disk. Unevaluated known
modules have `:status :unevaluated` and need evaluation. Current buffer revisions
may differ from evaluated revisions without invalidating cached products.

Collection responses contain `:items`, `:total` (after filtering), `:offset`,
`:limit`, and `:next-offset` (`nil` at the end). Offset defaults to zero; limit
is 100 by default and must be between 1 and 1000. Offsets beyond the end return
an empty page. Separate calls may see different session states, so clients should
restart pagination after evaluation or discovery changes.

Contents include the supplying `:phase` and `:availability`: `:unavailable`
means the product has not been supplied, `:partial` means it has been supplied
by an unfinished phase, and `:complete` means its phase completed, even if the
collection is empty. Diagnostics use `:unavailable` before submission, `:partial`
while evaluation is pending, processing, failed, cancelled or invalidated, and
`:complete` after successful evaluation. Inspection reports cached products
without returning their potentially large syntax/type payloads; detailed
inspection of definitions belongs to the subsequent definition-query API.


### Definition queries

Definition queries in `verona.ide` use the same session lock, isolated portable
responses, pagination limits, and current-state rules as module queries. They
perform no I/O, macro invocation, binding evaluation, or implicit analysis.

- `(list-definitions store id &key module name kind visibility offset limit)`
  lists current functions (including external functions), types (including
  aliases), constants, variables, macros, generics, protocols, and implementations.
  Kind and visibility (`:public` or `:private`) are exact keyword filters; name
  is a case-insensitive substring. Module is a full module identity. Results
  sort by their portable descriptors, including identity to break name ties.
- `(find-definitions store id name &key module offset limit)` accepts an exact,
  case-sensitive name or a definition identifier. Names use `qualifier:member`
  for qualification. With a module context, unqualified names search that
  module; qualified names follow its imports and aliases and expose only
  exported declarations, matching compiler lookup semantics. Without a context,
  unqualified names search all current modules and qualifiers match module
  names. The response reports `:status :found`, `:ambiguous`, or `:unresolved`
  before pagination, alongside the standard collection fields.
- `(inspect-definition store id identifier)` returns shared identity, owning
  module, kind, visibility, source range, evaluation revisions, status and phase
  metadata. `:documentation` has explicit availability and a value of `nil`
  when the declaration has no documentation. `:declared` contains structural
  source syntax for parameters, results, generic clauses, declared types, and
  type layout. `:resolved` wraps the current semantic structure with its phase
  availability; absent semantic data is `:unavailable`. Named semantic nodes
  carry their compiler kind and descriptive slots as keyword fields, including
  parameter types, return types, type parameters and constraints. Nominal type
  references include related definition identifiers. Recursive structures end
  with a kind and `:recursive-p t` marker rather than cycling.
- `(definition-type-structure store id identifier)` returns the same inspection
  snapshot, including declared layout and resolved product fields, sum variants,
  payload types, alias targets, pointers, arrays, tuples, and function types.
- `(definition-relationships store id identifier &key offset limit)` lists
  current source implementations associated with a generic, protocol, or type.
  Protocol operations appear structurally in `:requirements`. Availability is
  complete only when all known modules have completed resolution; undiscovered
  modules are outside the query scope. It never evaluates potential implementors.

Compile-time inspection reports macro parameters, the originating definition
identifier and cached binding kind in `:compile-time`. It excludes callable
implementations, environments, runtime bodies and initializer values. Generated
definitions expose `:generated-p` and `:expansion-origins` with invocation and
macro source locations. This includes expansions of the language's bootstrap
definition macros; primitive `%` definitions are source-written.

Identifiers are opaque `(module-identity evaluation-generation declaration-index)`
values, consistent across definition queries and declaration/macro content lists.
They remain valid across source edits, but replacement evaluation (even at the
same source revision), reset, or removal makes them unresolved. Clients must not
reuse them across sessions. No query falls back to old declarations or semantics.
Declaration information remains available after body analysis fails. Collection
responses include module summaries with revision and phase information and
explicit availability, so an empty page does not imply that analysis is complete.

### Completion and navigation

The `verona.ide` API also exports these read-only queries:

```lisp
(position-context store session-id module-identity offset)
(complete-names store session-id module-identity offset
                :prefix nil :expected-type nil :limit 100)
(signature-help store session-id module-identity offset)
(go-to-definition store session-id module-identity offset)
(find-references store session-id definition-id
                 :include-declaration t :offset 0 :limit 100)
(related-definitions store session-id definition-id :limit 100)
```

Position arguments are zero-based character offsets in the evaluated input,
not byte offsets or offsets in a subsequently edited buffer. Results identify
the module, evaluated and current source revisions, processing status, and
analysis availability. Resolution and type availability are reported separately.
They never read files, evaluate code, expand macros, or initiate analysis.

`position-context` reports the symbol, enclosing definition, and visible scope.
Lexical bindings are captured from the compiler's actual scopes during explicit
analysis; inner bindings shadow outer bindings and module definitions. Failed
analysis retains scopes visited before failure and current declarations. Scopes
that the compiler has not reached are unavailable; queries do not reconstruct
them from a previous evaluation.

`complete-names` returns a bounded, deterministic page of case-sensitive prefix
matches, including locals, module declarations, macros, import qualifiers,
public qualified members, constrained protocol operations, and language forms
appropriate to declaration or expression heads. Each candidate supplies
`:insertion-text`, a half-open character `:replacement-range`, kind, identity
where available, and structural type or signature data. `:prefix` overrides the
prefix inferred from the token up to the cursor. Optional `:expected-type`
compares structural type data for exact equality; candidates with unknown types
remain visible with `:type-match :unknown`. This initial filter does not perform
type inference or generic specialization during a query.

`signature-help` returns a zero-based `:active-argument` and `:signatures`,
including declared parameters, results, generic clauses, and available resolved
data. Generic implementations are returned as separate possible signatures;
queries do not select an overload by evaluating arguments. Missing signature
information is explicit. `go-to-definition` returns `:found`, `:ambiguous`, or
`:unresolved` and structured locations. Local identities are opaque values
scoped to the current evaluation and can be passed to `find-references`.

`find-references` distinguishes `:declaration` from `:use` sites, using current
semantic/macro dependency edges and captured local scopes. Its `:coverage`
describes every known module; `:complete-p` is false if any known module is
unevaluated, partial, invalidated, or differs from its evaluated input. Coverage
is limited to registered session modules, not undiscovered project files.
`related-definitions` navigates both ways between a generic or protocol and
its implementations and includes generated definitions' expansion origins.

All locations describe evaluated input. `:exact-p` requires matching source
and configuration revisions. When they differ, `:location` and completion
replacement ranges are nil; historical coordinates remain available only as
`:evaluated-location`. Each target checks its own module, so editing an imported
module also suppresses its exact target locations. Edits leave semantic caches
and identities intact; explicit reevaluation replaces them and invalidates old
definition and local identifiers. Responses contain isolated portable data.


### Diagnostics, cached expansion, and types

The `verona/ide` system exports these read-only queries:

```lisp
(module-diagnostics store session-id module-id
                    :definition definition-id :severity :error :phase :type-checking
                    :offset 0 :limit 100)
(project-diagnostics store session-id :module module-id :definition definition-id
                     :severity :error :phase :type-checking :offset 0 :limit 100)
(inspect-expansion store session-id module-id :offset character-offset :limit 4096)
(inspect-expansion store session-id module-id :definition definition-id :limit 4096)
(type-at-position store session-id module-id character-offset)
```

Diagnostic filters are optional and combined. Project diagnostics use the same
current module diagnostics and include per-module `:coverage`; they never discover
additional files. Both views return deterministic pages with `:items`, `:total`,
`:next-offset`, and the existing pagination limits. Each item identifies its
`:module`, `:phase`, and `:diagnostic`. Diagnostic fields include `:severity`,
`:code`, `:message`, `:location`, `:evaluated-location`, `:related-locations`,
`:secondary-locations`, `:notes`, and compiler `:data`. Prerequisite failures remain
visible on affected modules; `:data :prerequisite-failures`, when available,
identifies failed source inputs. Generated-code failures retain expansion
invocation and macro-definition locations when recorded.

`inspect-expansion` selects the innermost source list containing the evaluated
zero-based offset, or a current definition's source form. It returns portable
`:before` and `:after` syntax data, chronological `:steps`, and `:expanded-p`.
Names become case-sensitive strings, lists become lists, and other atoms use the
definition-query representation. Core declaration macros are included, so a
source `function` can expand to `%function`. Expansion steps are captured during
evaluation, including expression macros; inspection never invokes a macro.
`limit` is a shared syntax-node/string-character budget for before, after, and
step data (1–100000). `:truncated-p` explicitly reports omitted output. A complete
expansion with `:expanded-p nil` required no expansion; `:unknown` denotes missing
expansion information. Replaced definition identifiers return `:status :unavailable`.

`type-at-position` returns `:declared-type`, `:inferred-type`, a readable
`:description`, and the enclosing current `:definition`. Types reuse the structured
definition-query representation. The smallest captured expression containing the
position supplies its inferred type, including contextually typed literals;
otherwise available enclosing definition type information is used. Valid partial
expression types remain queryable when a later body fails. Missing information is
explicit through `:status :unavailable` and phase availability metadata.

These queries include evaluated source/configuration revisions, current source
revision, processing status, completed/failed/incomplete phases, and availability.
Exact locations require matching current revisions; after edits, historical ranges
remain only in `:evaluated-location`, with `:location nil` and `:exact-p nil`.
Related diagnostic locations check their owning source independently. Queries do
not refresh files, run macros, infer new types, evaluate bindings, or start builds.
New evaluation clears previous diagnostics, expansion steps, and expression types;
publication obeys the same cancellation and supersession gates as other products.
Fix suggestions are deferred until the compiler provides reliable edits.
# Optional Swank IDE adapter

`verona/swank` depends on `verona/ide` and Swank. The compiler, project
builder, and ordinary test suite do not depend on Swank. Load and start it
in a Lisp process with ASDF and Quicklisp configured:

```lisp
(require :asdf)
(asdf:load-asd #P"/path/to/verona/verona.asd")
(ql:quickload :verona/swank)
(swank:create-server :port 4005 :style :spawn :dont-close t)
```

Use a Swank backend with thread support (tested with SBCL). In Emacs, run
`M-x slime-connect`, select localhost and port 4005, then send Verona requests
with `slime-eval` or `slime-eval-async`. Standard Common Lisp Swank operations
remain available for developing the compiler itself. Verona analysis uses only
`verona.swank:rpc`; it does not execute application code or invoke a build.
The optional Emacs client is documented in `editors/emacs/README.md`.
For editor sessions based on `verona.build`, also load `verona/ide/project`
in this server process before session selection. It requires the compiler's
pinned LLVM setup and `VERONA_SOURCE_DIR`/`VERONA_LIBRARY_DIR` environment.
Register the pinned LLVM bindings before loading project discovery (after
Quicklisp setup), as the LLVM test runners do:

```lisp
(let ((root (uiop:getenv "VERONA_CL_LLVM")))
  (unless root (error "Start Lisp inside nix develop"))
  (let ((directory (uiop:ensure-directory-pathname root)))
    (pushnew directory asdf:*central-registry* :test #'equal)
    (asdf:load-asd (merge-pathnames "llvm.asd" directory))))
(asdf:load-system :verona/ide/project)
```

Setting `VERONA_CL_LLVM` alone does not register the system with ASDF.
Both the central-registry entry and explicit load are intentional: dependency
loading can cause ASDF to search again, and Quicklisp can replace a definition
registered only with `load-asd`. Verify that
`(asdf:system-source-file (asdf:find-system "llvm"))` points into Nix.
Quicklisp's outdated CL-LLVM release cannot compile against the shell's LLVM 23
headers. Restart Lisp if those old bindings were already
loaded or partially loaded before registering the pinned system.
The lightweight adapter alone cannot discover build targets or module paths.
Loading discovery later does not reconfigure an existing generic session;
create a new project session to obtain the build configuration.

The entry point is `(verona.swank:rpc operation &optional session arguments)`.
`operation` is a keyword; `arguments` is a list of data arguments. Successful
responses are `(:ok value)`. Rejected requests return
`(:error (:code :invalid-request :message "..."))`. IDE request validation
signals `verona.ide:request-error`, a subtype of `simple-error`; the adapter
translates that condition and filesystem input errors. Unexpected implementation
errors propagate to Swank's debugger rather than becoming compiler diagnostics.
User compilation/configuration conditions raised before evaluation return
`(:error (:code :compiler-diagnostic :diagnostic diagnostic-plist))`.
Compiler failures during evaluation use the IDE's structured diagnostic and
partial-result responses and leave the request in `:failed` status.

```elisp
(slime-eval '(verona.swank:rpc :capabilities))
(setq verona-session
      (cadr (slime-eval
             '(verona.swank:rpc :create-session nil
                                '(:root "/path/to/project/")))))
(slime-eval `(verona.swank:rpc :open-buffer ,verona-session
                             '("scratch" "(function answer () i64 42)")))
(setq verona-request
      (cadr (slime-eval
             `(verona.swank:rpc :evaluate ,verona-session
                                '((:buffer "scratch"))))))
(slime-eval `(verona.swank:rpc :request-status ,verona-session
                             '(,(plist-get verona-request :request))))
```

`:capabilities` works before attachment and reports `:protocol-version` (1),
`:adapter-version`, supported operations, and features. Editors should check it
before use. The operation set is:

| Operations | Arguments after the session |
| --- | --- |
| `:create-session` | `make-configuration` keywords, with session `nil`; creates or reuses and attaches |
| `:inspect-project` | Project root; reads required `verona.build` and returns root, build-file path and target descriptions without a session |
| `:create-project-session` | Project root, then `discover-project-configuration` keywords; optional, see below |
| `:attach-session`, `:detach-session` | Empty argument list |
| `:configure-session` | Complete `make-configuration` keywords |
| `:inspect-session`, `:reset-session`, `:close-session` | Empty argument list |
| `:open-buffer`, `:edit-buffer`, `:save-buffer`, `:rename-buffer`, `:close-buffer`, `:read-source` | Corresponding IDE API arguments after store/session |
| `:evaluate` | One canonical file path or unnamed source ID, e.g. `(:buffer "scratch")` |
| `:request-status`, `:cancel-request` | One request token returned by `:evaluate` |
| `:source-state`, `:module-state` | Source ID |
| `:discover-modules`, `:list-modules`, `:inspect-module`, `:module-contents`, `:module-relationships`, `:dependency-graph`, `:dependency-cycles` | Corresponding IDE API arguments after store/session |
| `:list-definitions`, `:find-definitions`, `:inspect-definition`, `:definition-type-structure`, `:definition-relationships` | Corresponding IDE API arguments after store/session |
| `:position-context`, `:complete-names`, `:signature-help`, `:go-to-definition`, `:find-references`, `:related-definitions` | Corresponding IDE API arguments after store/session |
| `:module-diagnostics`, `:project-diagnostics`, `:inspect-expansion`, `:type-at-position` | Corresponding IDE API arguments after store/session |

Every operation except capabilities, project inspection and session creation requires attachment to
the supplied session. A connection may attach to several sessions. Sessions are
identified by project configuration; selecting another target creates or attaches
to its independent session. Configuring an existing session preserves its target
identity, following the direct API. To use the build system's discovery defaults,
load `verona/ide/project` in the Nix development environment. Capabilities then
advertises `:inspect-project` and `:create-project-session`.
`:inspect-project` requires `verona.build` in the selected directory and returns
`:root`, `:build-file`, and `:targets` containing `:name`, `:kind`, `:root-module`,
`:search-paths`, `:target`, `:reader-features`, and `:optimization`. Inspection
only parses configuration; it does not resolve LLVM targets, require package
environment variables, create sessions, or evaluate source. Missing or malformed
files are rejected. Project session creation also requires this build file and
uses the selected target; the low-level `:create-session` API remains available
for explicit configurations. Project session creation arguments are, for example,
`("/path/to/project/" :build-target "app" :overrides (:reader-features ("linux")))`.
Without that optional LLVM-backed system, `:create-session` accepts explicit
configuration and the same defaults as `make-configuration`.

Transport values are lists/plists, keywords, booleans, numbers, and strings.
Paths become namestrings, characters become one-character strings, and other
symbols become names. Configuration and source records become plists; source
records omit source text. Compiler objects remain server-side: the adapter uses
the IDE's structured query representations, including source locations, types,
and diagnostics, rather than printing or serializing compiler instances. Module,
source, and definition IDs are opaque data: pass returned IDs back unchanged.
Query revision metadata, completeness, pagination, expansion bounds, and stale
location handling are preserved. Semantic query operations take full module
identities from `:list-modules`, not just a filename or module name.
`:dependency-cycles` packages its two IDE return values as
`(:items cycles :completeness metadata)` so partial graph coverage is retained.

Buffer updates, source discovery, and queries never evaluate or invalidate
analysis. `:evaluate` captures the selected source through `begin-request`,
immediately replaces its current state, starts a connection-independent worker,
and returns `(:request "request-N" :session "session-N")`. The worker invokes
`evaluate-request`, including required transitive dependencies. Poll
`:request-status` for `:pending`, `:complete`, `:failed`, `:cancelled`, or `:stale`.
It includes the request's source/configuration revisions and `:current-module`,
the current module snapshot with active/completed/failed phases and diagnostics.
That snapshot may belong to a newer request; its own revision metadata is
authoritative. Historical request tokens retain status, never older products.
Cancellation is cooperative; cancelled or superseded workers cannot publish.
Queries remain available while workers process analysis.

The Swank disconnect hook detaches that connection without cancelling workers
or closing sessions. After reconnecting, use `:attach-session` with the original
session ID and poll the original request token. This persistence is within the
server process. Explicit reset/close releases request handles. Detached sessions
follow the IDE's lifecycle policy: explicit `expire-sessions` maintenance on
`verona.swank:*store*` may expire them; otherwise they remain until closed.
Expired-session handles are pruned on subsequent RPCs. Loading `verona/ide/project`
adds the explicit build and program operations described below; analysis operations
never compile or execute application code.

Run `make test-swank` for the optional adapter suite. Swank and FiveAM must be
available through ASDF or Quicklisp; `VERONA_SWANK_ASD` may point to a particular
Swank ASDF file. `make test` continues to test the compiler without loading Swank.

# Optional Emacs IDE client

`editors/emacs/verona-ide.el` extends `verona-mode` through SLIME with explicit
module evaluation, cached completion/signatures, Xref navigation, Flymake
diagnostics, and structured inspection buffers. See
[the editor workflow](../editors/emacs/README.md) for setup, session selection,
reconnection, cancellation, response limits, and separate build/run commands.
Edits, saves and queries never evaluate modules or build projects.

The Emacs entry point `verona-open-project` selects a project folder, creates
its project session from `verona.build`, and opens its target root module (or
prompts for a file if unavailable). `verona-project-find-file` and ordinary file
opening reuse the opened project context automatically for source buffers under
that root. This does not evaluate modules or invoke builds.

`verona-close-project` explicitly closes the current project/target server
session through `:close-session`, cancelling evaluation and builds, stopping
owned programs, and releasing session resources. Editor attachments and
session-specific views are cleared; source buffers and unsaved edits remain.
Other project/target sessions stay available. Reopening a closed project creates
a fresh session. Disconnecting SLIME alone preserves sessions and pending work;
reopening after reconnecting reattaches the remembered session and target.
Session identifiers and attachment are internal to this workflow.

### Managed Emacs server lifecycle

The editor workflow is `verona-help`, `verona-start-server`,
`verona-open-project`, explicit evaluation/build commands,
`verona-close-project`, and `verona-stop-server`.

`make build` produces `build/verona` and `build/verona-server`. Installation
places both executables in `PREFIX/bin`; the default prefix is `/usr/local`.
The `verona-server` Bash launcher embeds its Lisp entry point and invokes SBCL
with a separate descriptor for that entry point, preserving standard input and
process ownership for shutdown. No standalone server Lisp file is installed.
The launcher still requires the configured Verona checkout and development
environment. Run `verona-server --help` for its command-line contract.

`verona-server-command` defaults to `'("verona-server")`. Discovery checks the
editor's executable paths, beside a located `verona`, common installation
locations, and the configured checkout's `build/verona-server`. Custom commands
are used as configured. The launcher uses `sbcl` unless `VERONA_IDE_SBCL` selects
another executable. SBCL startup options belong in
`verona-server-startup-arguments`. Nix is an explicit environment option; the
default launcher does not invoke it. The [Emacs setup guide](../editors/emacs/README.md)
describes checkout, environment, host, port, and timeout configuration.

Startup loads `verona/ide/project` and `verona/swank`, then connects SLIME after
listener readiness and checks adapter capabilities. Swank is loaded from the
installed SLIME package. Startup, project discovery, buffer synchronization,
edits, saves, and ordinary queries never evaluate or build. Explicit evaluation
analyzes the module and required dependencies, including unsaved overlays;
project builds use saved-file snapshots. Project/target sessions remain
independent of editor connections.

`verona-help` displays the startup checklist, effective environment values,
resolved launcher, and workflow commands without starting work. Managed startup
rejects missing or invalid `VERONA_SOURCE_DIR` and `VERONA_LIBRARY_DIR`; values
must identify existing readable absolute local directories. An editor-supplied
`VERONA_CL_LLVM` must also contain a readable `llvm.asd`. An unset LLVM path is
marked CHECK ON START because an explicitly configured development shell can
supply it. The server rechecks all three variables before loading systems.
Unavailable launchers and invalid editor settings open `*Verona help*`; `g`
refreshes the checklist. Server initialization output is kept separately in
`*Verona server*`.

Managed shutdown uses `verona.swank:close-all-sessions` to release all remaining
sessions and their owned work before exiting the editor-owned process. This is
a server lifecycle function, not a remotely advertised RPC operation. External
Lisp processes are not stopped by `verona-stop-server`.

### Editor diagnostics

Evaluation diagnostics are cached session products exposed through Flymake and
`verona-ide-project-diagnostics`. Build/run output and build diagnostics appear
in separate `*Verona build*` compilation buffers and do not replace analysis
state. Request rejection is reported in the minibuffer;
`verona-ide-last-error` in the originating buffer shows its full response.
Startup settings appear in `*Verona help*`, while server process output and
initialization failures appear in `*Verona server*`.


### Bounded values

Base exports `bounded`, the Haskell-style protocol for types with a smallest and
largest value. Its zero-argument operations are `minBound` and `maxBound`:

```lisp
(import base)
(base:function smallest () i64 (base:minBound))
(base:function largest () u64 (base:maxBound))
```

The expected result type selects the instance. A call with no type context is
ambiguous when multiple instances apply. Constrained functions can use the
operations directly:

```lisp
(base:function bounds (for (a) ((base:bounded a))) ((witness a)) (tuple a a)
  (tuple (minBound) (maxBound)))
```

Instances cover signed and unsigned fixed-width integers, `bool` (`false` through
`true`), ASCII `char` (0 through 127), `unit`, and `base:order` (`less` through
`greater`). Integer aliases, including `isize`, `usize`, `int`, and `exit-code`,
use the underlying integer instance. Floating-point numbers and pointers have no
instances. There is no ordering superclass and no overflow checking.

Custom types use ordinary protocol implementations:

```lisp
(base:type color (sum (red) (green) (blue)))
(base:implementation (base:bounded color)
  (function minBound () color (red))
  (function maxBound () color (blue)))
```

Concrete product and tuple types can implement the protocol explicitly; instances
are not automatically derived. An exported zero-argument generic can select a
same-named protocol method declared in its owning module by expected result type.
Explicit generic implementations retain precedence, and ambiguous matches are
rejected. Calls resolve statically.

## Project management tools

`verona-project` is a standalone executable for project management, installed
alongside the compiler. Run `verona-project --help` to list its commands.
The tool is written in Verona in `projects/project/`; `make project` builds
`build/project/verona-project`. The resulting native executable does not load
the compiler or LLVM.

`verona-project new NAME` creates a new executable project in `NAME/` under the
current directory. It writes `verona.build`, `src/main.vrn`, `README.md`, and
`.gitignore` (ignoring `/build/`). The program returns exit code zero and
requires no additional packages. Run `cd NAME`, `verona build NAME ./build`,
then `./build/NAME` to build and run it.

NAME must start with an ASCII letter and contain only ASCII letters, digits,
hyphens, or underscores. Existing files and directories are rejected.

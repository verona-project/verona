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

The development shell supplies `VERONA_CL_LLVM`, `VERONA_LINKER`, and
`VERONA_AR`.  Override the latter two only to deliberately use another native
linker or archiver.

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
[`base/`](../base/), whose `verona.build` declares its `base` module.  Add
`base/src` to a consuming project's module path, then explicitly import the
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
and generic assertions. Add `projects/testing/src` and `base/src` to a test
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
| `+` | `(+ NUMBER...)` | Bootstrap arithmetic binding. It exists for evaluator tests and simple bootstrap macros; it is not a stable general-purpose macro library. |
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
| `(match value (pattern expression) ...)` | Exhaustive pattern match. Supports `true`, `false`, integer literals, `_`, bindings, and sum constructor patterns. |
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

# Compiler optimization implementation handover

Date: 2026-11-14

## Objective

Implement optimizations that remove runtime abstraction overhead while preserving
Verona's observable behavior. Start with a conservative checked-expression
simplifier and an explicit LLVM optimization pipeline. Add inlining and
specialization incrementally, with bounded compile time and code growth.

This document is an implementation plan, not a claim that these passes exist.
Effort estimates are focused engineering days including implementation, meaningful
tests, and basic diagnostics. They overlap, depend on shared infrastructure, and
must not be summed as an overall schedule.

## Repository context and constraints

- Read the root `AGENTS.md`, `readme.md`, and `docs/compiler-roadmap.org` first.
- The maintained compiler is implemented in Verona under `src/`. Do not base this
  work on the archived Common Lisp compiler.
- `src/core.check.vrn` resolves calls and already implements generic
  specialization. `src/core.model.vrn` defines the shared node representation.
- `src/core.emit.vrn` lowers checked expressions into LLVM and associates LLVM
  values with checked syntax/binder identities.
- `src/core.cli.vrn` configures compilation; `src/core.target.vrn` and
  `projects/llvm/src/llvm.target.vrn` configure LLVM target machines.
- Inspection found optimization levels passed into target-machine creation, but
  no explicit pass-running API in the searched LLVM bindings. Audit all compile,
  object, library, and project-build paths before deciding what is missing.
  Target-machine optimization settings alone do not establish a middle-end
  optimization pipeline.
- LLVM/Clang 23 is pinned by the current Nix shell. Verify available C APIs
  against that version and extend the existing LLVM project bindings as needed.
- Preserve the distinction between Base macro expansion, semantic generic
  dispatch, and concrete compiler input. Never treat numeric generic names as
  aliases for concrete primitives before resolution.
- Collect surface `import` and `export` before expanding later declarations;
  retain `%import` and `%export` for expanded-core callers.
- Compiler implementation code imports Base normally. Test input programs use
  expanded declarations such as `%function`; existing core `let` and `if` remain
  unprefixed. Do not introduce `%let` or `%if` aliases.
- Use `.vrn` for Verona sources. Preserve arena ownership and established node
  lifetime rules. Do not add a separate general-purpose IR as a prerequisite.
- Preserve unrelated working-tree changes. In particular, `src/core.cli.vrn`
  was already modified when this handover was created; inspect its current diff
  before editing it.

## Effort ranking: least to greatest

Ranges overlap; ordering is approximate and is not dependency order.

| Optimization / infrastructure | Effort |
|---|---:|
| Known-condition branch elimination | 1–2 days |
| Copy propagation | 1–3 days |
| Constant folding | 2–4 days |
| Known-constructor / `match` simplification | 2–4 days |
| Dead local binding elimination | 2–4 days |
| Forced / forbidden inlining controls | 2–4 days |
| Beta reduction through explicit bindings | 2–4 days |
| Conservative eta reduction | 2–4 days |
| Selective eta expansion | 2–5 days |
| Optimization pass framework, traversal, dumps, budgets | 3–5 days |
| Constant propagation | 3–5 days |
| Small-function heuristic inlining | 3–6 days |
| Dead internal function elimination | 3–6 days |
| Local common subexpression elimination | 3–6 days |
| Self-tail-recursion elimination | 3–6 days |
| Explicit LLVM optimization pipeline integration | 3–6 days |
| Conservative effect analysis | 4–8 days |
| Inlining transformation itself | 5–9 days |
| Constant-argument specialization | 5–10 days |
| Temporary product scalar replacement | 5–10 days |
| Known-function argument specialization | 6–12 days |
| Speculative inlining with simplification | 7–12 days |
| General tail-call support | 7–15 days |
| Cross-block common subexpression elimination | 8–15 days |
| Dead store elimination | 8–15 days |
| General escape analysis | 10–20 days |
| Compile-and-benchmark inlining experiments | 10–20 days |
| Profile guided inlining | 15–30 days |

Beta reduction shares machinery with inlining. Inlining controls and heuristics
assume the transformation exists. Eta and known-function estimates assume the
necessary callable representation is available: audit support first, and defer
unsupported cases rather than adding language features incidentally.

## Implementation sequence

### 1. Establish the optimization boundary and observability

1. Trace module collection, expansion, checking, specialization, emission, and
   native output paths. Record where checked graphs are complete and whether
   emission or checking mutates them afterward.
2. Add a dedicated optimizer module, preferably `src/core.optimize.vrn`, following
   existing module conventions. Start after successful checking and resolved
   specialization, before LLVM lowering. Never remove source before checking in
   order to conceal existing diagnostics.
3. Define traversal and rewrite contracts for node identities, binder references,
   types, source spans, and cached semantic information. Audit shared subtrees:
   mutation must not silently change a different specialization or caller.
4. Add deterministic before/after dumps and opt-in remarks. Preserve source
   locations so a rewrite or inlining decision can be traced to its origin.
5. Bound simplifier iterations, node growth, inline depth, and specialization
   versions. A budget exhaustion must stop optimization safely.
6. Keep an unoptimized path for differential validation. Define and document the
   relationship with existing optimization levels without silently changing CLI
   contracts or inventing annotation syntax.

### 2. Implement a conservative simplifier

Implement constant folding, known-condition simplification, propagation, and
dead binding elimination first, then known-constructor simplification.

Use separate safety questions rather than a single `pure` flag:

- Can evaluation be discarded?
- Can its result be duplicated or substituted?
- Can evaluation move across another expression?
- Does it read or write memory, call unknown code, trap, or potentially diverge?

Treat unknown calls and unsupported nodes conservatively. Start with local
facts and immutable bindings; extend interprocedural summaries later. A read
without writes can still depend on mutable memory or fail. An effect-free call
can still diverge. Never infer discardability solely from an unused result.

Fold only resolved primitives with documented semantics. Match target widths,
signedness, overflow, shifts, division failures, floating-point behavior, and
casts. Reuse existing numeric/constant helpers where their contracts match;
do not substitute host arithmetic accidentally. A failed fold should leave the
runtime expression intact unless the language already requires a diagnostic.

### 3. Integrate LLVM passes

Audit existing behavior first. If absent, expose the pinned LLVM pass-running
API through the existing LLVM project. Run an appropriate standard pipeline
after lowering, with target-machine information available and before native
emission. Preserve verification and diagnostic ownership on all error paths.

Check which CLI modes should produce optimized LLVM output and document that
choice. Ensure each native build path uses the intended pipeline exactly once.
Leave broad CSE, dead stores, scalar replacement, and target-specific work to
LLVM initially; add Verona passes only where language-level facts justify them.

### 4. Add safe inlining and beta reduction

- Clone bodies with fresh identities for binders and other identity-bearing
  nodes. Remap references and preserve provenance.
- Bind arguments once, in the existing evaluation order, before substituting
  parameters. Preserve evaluation of unused arguments when required.
- Do not duplicate, omit, or reorder argument effects or failures.
- Preserve addressable parameter/local storage behavior and pointer escape
  semantics. Reject unsupported cases conservatively.
- Handle direct and mutual recursion using call-graph recursion groups and
  explicit expansion limits; forced inlining must not cause infinite expansion.
- Add forced/forbidden controls through the established declaration metadata
  mechanism after auditing it. Specify declaration versus call-site precedence,
  conflicts, and unavailable-body behavior before selecting public syntax.
- Forced requests bypass profitability thresholds, not legality. Emit a clear
  remark for an eligible request that cannot be honored; document the policy.
- Start heuristics with small bodies, known constants, and single-use internal
  functions. Count size after simplification where practical.
- Run the simplifier after inlining. Retain an out-of-line body when exports,
  function pointers, recursion, or remaining calls require it.

Beta reduction should use the same binding/substitution machinery. For example,
`(lambda x. x + x)(read())` must evaluate `read()` once. This notation is
explanatory, not a proposal for Verona source syntax.

### 5. Add reachability and specialization

Root dead-function analysis at entry points, externally visible symbols,
initializers, callbacks, and address-taken functions. Preserve unknown indirect
targets conservatively and account for library output, not only executables.

Extend existing specialization infrastructure where feasible for constant and
known-function arguments. Cache versions, bound growth, and account for recursive
specialization. Do not merge function identities or change ABI exposure.

### 6. Add selective higher-level transformations

- Eta reduction: only remove a forwarding wrapper when the target is stable,
  obtaining it does not move effects, and arity, ABI, identity, and captures allow
  replacement. The free-variable condition alone is insufficient.
- Eta expansion: introduce wrappers only for an identified optimization benefit;
  do not alternate expansion and reduction without a termination policy.
- Scalar replacement: start with nonescaping temporary products whose addresses
  and identity are unobservable.
- Local CSE: restrict initial support to safe computations and invalidate facts
  around writes and unknown calls.
- Self-tail-recursion: preserve argument evaluation order and addressable local
  lifetimes. General tail calls require separate ABI and backend work.

### 7. Measure before adding advanced policies

Speculative inlining clones a candidate, simplifies it, and compares estimated
runtime savings against code growth and compile cost. Report why candidates are
accepted or rejected. Keep speculation budgeted.

Profile guided inlining needs instrumentation, stable profile identities,
representative training runs, profile ingestion, and stale-profile handling.
Runtime profiles inform a cost model; they do not directly prove a rewrite faster.

Compile-and-benchmark selection is a separate offline workflow: compile bounded
alternatives, validate equivalent results, benchmark repeated runs, and record
workloads, target details, noise, and chosen configuration. Never execute user
programs automatically as an ordinary compilation step.

## Correctness and acceptance tests

Add behavioral tests alongside focused checks that a transformation occurred.
Avoid requiring exact generated LLVM text when a stable structural assertion
suffices. Cover both successful rewrites and deliberately rejected rewrites.

Required cases, as relevant to each pass:

- Shadowing, fresh binders, nested bindings, and multiple specializations.
- Arguments evaluated exactly once and in order; unused effectful arguments.
- Unknown external calls, mutable loads, writes, aliasing, address-taken locals,
  callbacks, and pointer escapes.
- Untaken failing branches, evaluated failures, integer boundary cases, floating
  NaNs/infinities/signed zero where supported, and target-dependent widths.
- Unused potentially diverging computations: do not remove without a valid proof.
  Use structural assertions or bounded timeout harnesses for regression tests.
- Known sum constructors, payload evaluation, and nested matches.
- Direct/mutual recursion and termination of optimizer budgets.
- Exported library functions and address-taken functions surviving reachability.
- Preservation of existing source diagnostics in otherwise unreachable code.
- Equivalent results, exit status, stdout/stderr, and observable state between
  optimized and unoptimized native builds; compare evaluator behavior where its
  contract overlaps. Passing examples alone do not prove a rewrite sound.

In the pinned development shell:

```sh
nix develop --offline path:.
```

Check compiler sources using the current seed:

```sh
build/verona check src/core.cli.vrn \
  --module-path src \
  --module-path projects/base/src \
  --module-path projects/foundation/src \
  --module-path projects/libc/src \
  --module-path projects/llvm/src
```

Build the changed compiler using the current documented Make/seed workflow;
ensure `build/verona` contains the changes before running the required suites:

```sh
python3 tests/test_core.py build/verona
python3 tests/shared_suite.py build/verona
```

Also exercise compiler self-rebuild, native ABI/callback/library coverage, and
relevant output modes when their paths change. Verify LLVM modules around the
new pipeline. Record target and LLVM version for performance measurements.

## First delivery

Deliver the pass boundary and dumps, a conservative local simplifier, explicit
LLVM pipeline integration if missing, and regression coverage. Report which
rewrites are supported, which remain conservative, and measured compilation time,
runtime, and code-size changes on a small fixed workload set. Keep later inlining,
eta, profiling, and memory-analysis work as separate reviewable changes.

## Research references

- LLVM pass overview: https://llvm.org/docs/Passes.html
- LLVM function attributes and semantics: https://llvm.org/docs/LangRef.html
- Peyton Jones and Marlow, *Secrets of the Glasgow Haskell Compiler inliner*:
  https://www.microsoft.com/en-us/research/publication/secrets-of-the-glasgow-haskell-compiler-inliner/
- Historical Flambda design, including speculative inlining and reports:
  https://ocaml.org/manual/4.10/flambda.html

Use these for design background. Validate API choices against the repository's
pinned LLVM version and Verona's own semantics.

## Implementation status

### 1. Known-condition branch elimination

The first incremental rewrite lives in `src/core.optimize.vrn`. LLVM lowering
consults it only after whole-program checking and specialization succeed. A
checked, typed boolean literal condition selects its existing branch directly;
unknown conditions keep normal control flow. Nested selected branches simplify
as lowering visits them. Both source branches still receive diagnostics.

The optimizer borrows the checked graph without mutation or allocation. It
preserves source spans, sibling links, binder IDs, specialization sharing, and
emitter value slots. This rule needs no fixed point or growth budget. It does
not propagate constants, evaluate calls, simplify matches, or discard effects.

Native `-O0` disables this rewrite; `-O1` through `-O3` enable it. `emit-llvm`
uses the rewrite by default and provides a structural inspection path through
its existing IR output; it does not accept native compilation flags. `eval`
continues to consume the original checked graph. Dedicated checked-graph dumps,
remarks, traversal infrastructure, and LLVM pass integration remain pending.

Regression coverage checks literal true/false and nested selections, untaken
division failures, effectful unknown conditions, and unreachable diagnostics.
Behavior is compared between evaluator, `-O0`, and `-O2` native builds.

### 2. Copy propagation

Audit confirmed that `src/core.emit.vrn` already propagates copies during SSA
lowering. `bindings` evaluates each initializer once, in source order;
`bind-binder` maps nonstored binders to the same LLVM value. Local references
retrieve that handle by resolved binder identity. Chains of immutable copies
therefore emit no copy instructions, including copies of function parameters.
This existing behavior applies at all optimization levels, including `-O0`.

Addressable or writable locals retain distinct storage. Copying from one loads
its value at the binding site, so later writes through an aliasing
pointer do not change the copy. A destination that needs storage is
materialized separately. No source initializer is duplicated, moved, or removed.

This item adds explanatory emitter comments and focused regression coverage,
without a new transformation or checked-graph mutation. Tests assert a parameter
copy chain lowers to a single return and compare evaluator, `-O0`, and `-O2`
behavior for shadowing, effect order, unused copies, and source/destination
mutation through pointers obtained before and after copying. Constant propagation and folding remain
separate future items.

### 3. Constant folding

`src/core.optimize.vrn` now evaluates checked integer/boolean literals and
resolved primitive-only trees without modifying the checked graph. Supported
operations are wrapping add/subtract/multiply, checked division, comparisons,
bitwise operations, modulo-width shifts, boolean negation, and integer
conversions. Numeric names are never interpreted before generic dispatch.
Unsigned intermediates and existing `core.numeric` normalization helpers enforce
operand widths, signedness, and canonical payloads; signed division truncates
toward zero, while signed right shift rounds down.

Division by zero and signed minimum divided by minus one return unknown, leaving
the original runtime failure and source location intact. Calls, local/global
references, memory accesses, pointers, floating-point operations, and conversions
involving floating point remain conservative. Initializers and arguments are not
moved, duplicated, or discarded. This item does not add constant propagation.

Lowering queries the folder only at `-O1` through `-O3` and for `emit-llvm`;
`-O0` and the evaluator retain their original behavior. LLVM may independently
fold simple constants even at `-O0`. Successful folds emit a constant under the
original expression's LLVM slot and type. Proven boolean computations also feed
known-condition branch elimination. Each query has a 32-level recursion budget;
unknown or exhausted queries fall back to normal lowering. No graph growth,
fixed-point loop, or shared-subtree mutation is introduced.

Focused tests cover signed/unsigned boundaries, wrapping, high-bit u64 division,
shifts, conversions, boolean expressions, and removal of guarded-division calls
and computed branches. Rejection coverage includes runtime failure status and
locations, effectful calls, custom numeric-name declarations, floating point,
and folding-depth exhaustion. Native behavior is compared at `-O0` and `-O2`.

The boundary tests also exposed an existing LLVM constant-construction issue:
passing sign-extended narrow literal payloads directly to `LLVMConstInt` could
make a negative literal compare unequal to the same wrapped arithmetic result.
`core.emit:word` now masks the payload to the declared width first. This applies
at every optimization level and keeps the unoptimized baseline consistent with
Verona's integer semantics.

Validation: the configured LLVM 23 toolchain rebuilt the compiler successfully;
17 focused/related regression methods passed, and all five new folding methods
also passed with the compiler's successful self-rebuild. A fail-fast core-suite
run and the shared suite still hit the previously reproduced evaluator pointer
access failures (`test_addressable_storage_and_aliases` and
`pointer-equality-offset-handles`). The complete suites are not passing.

### 4. Known-constructor / match simplification

`core.optimize:known-match` selects an existing checked arm for a direct sum or
tuple construction, or a scalar expression proven constant by the folder.
Sum tags are resolved descriptor identities; scalar/payload literals use checked
canonical values. The selector respects source arm order: it skips only proven
mismatches and stops on an undecidable earlier pattern. It does not assume that
a known constructor implies known payload values. Each query scans at most 128
arms/components and uses the existing 32-level constant-folding budget.

At `-O1` through `-O3` and in `emit-llvm`, lowering evaluates the complete
scrutinee once and then either binds the selected arm directly or emits the
original runtime match. `-O0` retains runtime dispatch. Shared `bind-arm` logic
binds scalar/whole-value and payload variables from the already evaluated LLVM
value. Unused payloads still evaluate in source order, including calls, writes,
and failures. No source subtrees or binder identities are mutated.

Known selections omit tag/literal tests, unselected arm bodies, and the match
merge phi. Unknown scrutinees, undecidable payload patterns, and exhausted
budgets retain the runtime path. Matches through local bindings or function
results remain conservative; no constant propagation, nested-pattern language
feature, or scalar replacement is introduced. All arms still receive semantic
checking, including exhaustiveness and diagnostics in unselected bodies.

Focused regressions cover scalar/boolean boundaries and catch-alls, empty tuples,
known sum constructors, literal payloads, nested matches, whole-value bindings,
effectful unused payloads, failure order/source locations, unknown earlier
patterns/scrutinees, preserved diagnostics, and arm-budget exhaustion. Native
behavior is compared with the evaluator at `-O0` and `-O2`, with structural IR
assertions that dispatch is removed or deliberately retained.

### 5. Dead local binding elimination

Optimized lowering now skips an unreferenced local binding only when its
initializer has a bounded discardability proof. `core.optimize:references`
allocates one arena-owned byte per checked tape identity, zeros it, and scans
all checked local-reference nodes once. The table uses resolved binder IDs, so
shadowing, indirect-call callees, places, and specialized copies remain distinct.
The scan splits ranges to keep its own stack depth logarithmic.

`dead-binding` rejects referenced or materialized-storage binders. Its initial
32-level proof supports literals, immutable SSA local reads, integer/boolean
primitives that cannot fail, constant-proven successful division, value
construction/extraction, sequences, and conditionals whose condition and both
branches are discardable. Unknown nodes or exhausted budgets preserve evaluation.
Calls (including potential divergence), mutable/global/constant memory loads,
addresses, stores, indexing, floating arithmetic/conversions, and unproven
failures remain conservative. This is a discardability proof, not a general
purity, duplication, movement, or interprocedural effect summary.

The emitter builds the reference table after checking and specialization, then
consults it before lowering each let initializer. Remaining initializers retain
their original evaluation order. Source nodes, links, types, spans, and binder
identities are not changed. `-O0` performs no analysis allocation/scan and keeps
all initializers; `-O1` through `-O3` and `emit-llvm` enable the elimination.

The initial reference table deliberately includes references in other unused
initializers and unreachable branches. It does not subtract references or remove
whole dependency chains to a fixed point: shared checked subtrees make such
subtraction require additional analysis. Nested lets and matches also remain
conservative as whole initializers, although their own inner bindings are still
processed normally. No general dead-code or dead-function pass is added.

Regression coverage checks that unused dynamic arithmetic/aggregate/conditional
work disappears from IR, and compares evaluator, `-O0`, and `-O2` behavior for
shadowing, later-initializer dependencies, specializations, indirect callees,
effect order, stored snapshots, global reads, runtime failure order/locations,
and diagnostics. Structural tests retain potentially diverging calls and
computations beyond the proof budget without executing an infinite program.

Validation: compiler source checking and the configured LLVM 23 rebuild passed.
All 14 focused/related regression methods passed. Compiler self-rebuild succeeded,
and all six new methods passed against that self-built compiler. The fail-fast
core suite and shared suite still encounter the previously reproduced evaluator
pointer-access failures; the complete suites are not passing.

### 6. Explicit LLVM optimization pipeline (inlining prerequisite)

The next effort-ranking row, forced/forbidden inlining controls, depends on an
inliner and an established declaration-metadata mechanism. The audit found
neither in the maintained compiler. LLVM function-attribute bindings exist, but
setting inline attributes alone does not run an inliner. No new annotation syntax
or inert inline control is introduced. This delivery follows implementation
sequence step 3: LLVM pass integration before inlining policies.

`projects/llvm/src/llvm.passes.vrn` binds the pinned LLVM 23 PassBuilder and error
APIs. Its wrapper borrows the module/target/pipeline, verifies each pass, releases
pass options on success/failure, consumes errors once, and copies error text into
the existing LLVM message ownership convention. The original error string is
released with `LLVMDisposeErrorMessage`, not `LLVMDisposeMessage`.

All native artifact paths converge on `core.cli:compile`. After target machine
creation installs target layout, `optimize-native` clears the lowering builder's
insertion position, runs `default<O1>`, `default<O2>`, or `default<O3>` exactly
once, and verifies the resulting module before object emission or linking.
The existing pre-pipeline verification remains. Pipeline errors stop output and
return through the existing diagnostic/session/target cleanup paths. Manifest
builds use this same path. `-O0` bypasses LLVM middle-end passes entirely.
`emit-llvm` retains pre-pipeline output after Verona simplification; it keeps its
existing CLI contract and does not acquire compilation-only optimization flags.

Tests inspect object symbols across all four levels to verify internal dead-code
removal and native-export preservation, exercise repeated invalid-pipeline error
recovery followed by successful optimization/verification, check callbacks both
directions through an optimized static library, and retain potentially diverging
calls with a bounded execution check. Inlining controls remain pending their
metadata and policy design; the standard LLVM pipelines can use LLVM's own
inlining heuristics without adding a Verona annotation contract.

Validation: LLVM 23 source checking and configured compiler rebuild succeeded.
All 15 selected regression methods passed, including native artifacts, manifest
builds, aggregate C ABI at both `-O0` and `-O2`, floating-point semantics,
callbacks, errors, and failure ordering. The compiler rebuilt itself with the
new pipeline, and all four new methods passed against that self-built compiler.
The fail-fast core suite and shared suite still hit the previously reproduced
evaluator pointer-access failures; the complete suites are not passing.

### 7. Forced/forbidden inlining controls

The accepted interface uses independent `%inline name` and `%noinline name`
declarations; no directive means automatic inlining. Base's `inline-function`
and `noinline-function` macros emit a `%function` and matching directive as
separate top-level forms. Numeric operators in bodies still resolve normally.
No compiler-state metadata convention or function declaration option is added.

The checker classifies directives as kinds 72/73 and resolves their targets
following signature collection, before body checking. Targets are unqualified
module-local ordinary or parametric `%function` declarations with bodies.
Directive order relative to the function does not matter. Identical duplicates
are idempotent and collapse to the first resolved record; opposing policies
produce a source diagnostic. Unknown targets, wrong arity, external functions,
non-function declarations, imported/qualified targets, and overloaded generic or
protocol declarations are rejected. All existing body diagnostics remain active.

`core.inline` attaches LLVM `alwaysinline`/`noinline` function attributes after
LLVM function declaration and before lowering bodies. A template's directive
applies to every checked specialization of that template. Auto creates neither
attribute. Only implementation bodies receive the policy, leaving export and
callback adapters' ABI and pointer identity unchanged. There are no call-site
policies; an explicit declaration policy overrides LLVM's normal profitability
heuristics, not legality. Rejected forced requests do not silently become auto.

The existing LLVM pipelines own transformation, recursion limits, and legality.
After native optimization, forced requests with remaining direct calls receive
nonfatal source-location remarks. The queries look up current LLVM functions by
numeric source identity and traverse borrowed use lists; they never dereference
cached handles that passes may have deleted. Address-only uses do not produce a
missed-direct-inline remark. `-O0` retains no-pass behavior and explicitly marks
forced requests inactive; `emit-llvm` shows policy attributes without running a
pipeline. Semantic check/eval validate directives but do not transform calls.

Tests cover the auto default, explicit attributes and native body retention or
removal at all four optimization levels, both Base convenience macros, module
isolation and aliased imports, multiple specializations, duplicates/conflicts,
invalid targets, effects and unused failing arguments, addressable storage,
callback identity, direct recursion remarks, and bounded mutual recursion.

Validation: source checking, LLVM 23 compiler rebuild, and compiler self-rebuild
succeeded. All 11 selected regression methods, including all five new control
methods, passed against the self-built compiler. The fail-fast core suite and
shared suite still hit the previously reproduced evaluator pointer-access
failures. Base's macros and documentation are changes inside the separate
`projects/base` submodule; its manifest version is unchanged.

### 8. Beta reduction through explicit bindings: supported-case audit

Verona currently has top-level functions and typed function pointers, not lambdas
or capturing closures. The supported noncapturing application shape is:

```lisp
(%type Callback (pointer (function (i64) i64)))
(%function twice ((value i64)) i64 (%+-primitive-i64 value value))
(%function main () i64 (let ((bound Callback twice)) (bound 21)))
```

Audit confirmed that immutable binding lowering preserves the concrete LLVM
callee. The indirect-call path evaluates its callee value first, then evaluates
arguments once from left to right. The LLVM pipeline already supplies body
substitution with fresh SSA identities when its inlining policy permits it.
This delivery adds comments and regressions for that existing supported case;
it does not add a checked-expression beta reducer or a new callable syntax.
General lambda/closure beta reduction remains deferred until that language
representation exists. Auto remains subject to LLVM profitability and legality;
`%noinline` prevents body substitution, and `%inline` retains its established
forced-request behavior. `-O0` remains the comparison path.

Six focused regression methods verify that live known-function applications
lose their private function/adapter symbols at `-O1` through `-O3`, while an
exported API continues accepting runtime inputs from a separately compiled C
client. The client also calls an exported unknown-callee application to ensure
function parameters remain dynamically callable. `%noinline` retains the
private target. Behavioral comparisons cover unused effectful arguments,
duplicated parameter uses, repeated applications, shadowing, stored function
pointer snapshots/mutations, callee evaluation before arguments, addressable
parameter storage, and preservation of unused-argument failure ordering and
source locations. All six methods passed against the current compiler; no
compiler behavior changed, so another self-rebuild was not required.

### 9. Conservative eta reduction: forwarding-wrapper audit

General eta replacement remains deferred: Verona exposes function-pointer
identity, so a named forwarding declaration cannot simply become its target.
There is currently no anonymous lambda/closure representation on which to apply
a separate checked eta rule. This delivery adds no new rewrite or language form.

The existing LLVM pipeline removes the private forwarding call chain when legal
at optimized levels, while keeping exported native entry points. This is
inlining and dead-function elimination, not function-value eta replacement.
An emitter comment records why callback adapters remain cached by source
declaration rather than by a forwarded target.

Three focused regressions cover distinct wrapper/target pointer identities,
repeatable wrapper identity, runtime-selected targets and wrapper effects, and
removal of private forwarding symbols at -O1 through -O3. A separately compiled
C client calls the preserved exported wrapper with runtime input, preventing
constant-result elimination from masquerading as wrapper optimization. -O0
retains the private functions as a comparison. These tests and the six beta
regressions pass against the current compiler. Changes are comments and tests;
no compiler rebuild is necessary.

### Constant propagation through immutable local bindings

The pass coordinator now builds an arena-owned initializer index after checking
and specialization. It maps resolved immutable `let` binder IDs to checked
initializer IDs; zero means no fact. Parameters, pattern binders and globals
receive no entry, and checking's final storage flags exclude every addressable
or writable local. Disabled optimization allocates no initializer index.

The constant query follows integer/boolean local references through this index,
then reuses the existing checked primitive folding rules. Each alias hop consumes
the same 32-level budget as primitive nesting. Calls, stored-local/global reads,
floating-point operations, pointers, aggregates, control-flow joins and other
unsupported initializers remain unknown. There is no interprocedural inference
or propagation from caller arguments. The tape, identities and source locations
remain unchanged, and original initializers retain their evaluation order.

Known branches, scalar matches and constructor component comparisons can use
the new local facts. Discardability queries can also prove division through
constant aliases safe, while division by zero and signed overflow remain runtime
failures. No facts are inferred from memory reads or unknown calls. Storage is
one eight-byte initializer ID per tape identity, in addition to the existing
reference map; queries remain bounded and do not grow or mutate the graph.

`optimization-report` emits `constant-propagation` for local reads replaced by a
proven scalar. The same facts can appear as `constant-fold`, `known-branch`,
`known-match` or `dead-binding` decisions when consumed by those existing rules.
`-O0` and the evaluator keep their comparison behavior.

Six focused regression methods cover alias-driven branch/match elimination,
safe dead division, shadowing and multiple generic specializations, unknown
parameters, signed/unsigned widths and wrapping, addressable local/global
snapshots across writes, effectful initializers evaluated once, source-located
division failures, and conservative fallback for long alias chains.

Validation: source checking, the pinned LLVM23 compiler rebuild and a second
self-host build succeeded. All 29 selected regression methods passed against
the rebuilt compiler, and all six new methods passed against the self-built
compiler. The fail-fast core suite still stops at
`test_addressable_storage_and_aliases`; the shared suite still stops at
`pointer-equality-offset-handles/eval`. Both are the previously observed
evaluator invalid-pointer-access failures, outside this change.

### Small-function heuristic inlining: existing LLVM policy verified

Automatic inlining is already supplied by the `default<O1>`, `default<O2>` and
`default<O3>` pipelines after local simplification and ABI lowering. The pinned
LLVM23 `llvm/Analysis/InlineCost.h` describes its call-site cost/threshold model.
No new source-node counting heuristic, threshold option, inline hint or forced
attribute is introduced. Ordinary functions remain automatic, explicit
`%noinline` forbids substitution, and `%inline` retains its forced-request
policy. LLVM owns legality and recursive expansion. There is no new checked
body-cloning pass, growth policy, or general lambda support in this delivery.

The new live-helper regression verifies that an automatic function has neither
`alwaysinline` nor `noinline` in the pre-pipeline IR. Its body calls an unknown
external function and adjusts the result; an exported caller invokes it twice
with different runtime arguments. The helper symbol disappears at -O1 through
-O3 but remains at -O0, and the same source with `%noinline` retains the helper
at every level. A separately compiled C client supplies two different runtime
inputs and verifies the returned value, exact external call count and effect
order. This prevents dead-code elimination, constant-result folding or a simple
forwarding alias from masquerading as successful inlining.

A second regression checks automatic recursion and source-located failure of an
unused argument at all four optimization levels. Existing tests cover forced
policies, specialization, addressable storage and callbacks. Automatic choices
are implementation-dependent, not a language guarantee about every small body
or an asserted performance improvement. `optimization-report` remains a local
lowering report and does not run/report LLVM automatic inlining. Compiler
changes are explanatory comments only; this item adds regression coverage and
documentation for an existing optimization, with no behavior change.

Validation: both new methods and eight related inlining, specialization,
callback and propagation regression methods passed against the current rebuilt
compiler (10 methods total). Object inspection and separately linked clients
cover automatic and forbidden policies at -O0 through -O3. No compiler behavior
changed, so another self-rebuild was not required.

### Dead internal function elimination: existing LLVM reachability verified

All Verona implementation functions have internal LLVM linkage. The optimized
native pipelines already perform global dead-code elimination; the pinned
LLVM23 `llvm/Transforms/IPO/GlobalDCE.h` explicitly describes elimination of
unreachable recursive groups. This delivery adds no second source-level call
graph or pre-check pruning pass. `emit-llvm` remains pre-pipeline, and -O0
remains the comparison path with internal bodies retained.

Native exports create externally visible C entry points, and LLVM use edges
retain reachable implementations and callable values escaping through live
code. Source-level `export` only grants Verona module visibility; it is not a
native retention root. `%noinline` likewise does not retain an unreachable
body. Taking an address inside code that is itself unreachable is insufficient
to keep a function alive. LLVM preserves dynamic incoming callback arguments;
the optimizer must not restrict those calls to locally known functions.
Current global initializers are restricted to supported static values; this
audit does not add runtime initializer or new callable-global syntax.

The first new regression checks an unreachable, effectful mutually recursive
group and its caller, including a callback address taken only in the dead
caller. All three bodies have `%noinline`, and one is source-exported. Their
symbols and unused external dependencies remain at -O0 and disappear at
-O1 through -O3. A live exported API still accepts runtime input from a separate
C client, and dead effects are never executed.

The second regression builds object, static-library and shared-library output
without a Verona main. C clients retrieve two callbacks with equal results but
distinct identities, call them with runtime input, check repeated pointer
identity, and supply an independently compiled C callback to an exported
unknown-callee invocation. This verifies reachability and ABI retention from
library roots rather than relying only on an executable entry point. A third
regression ensures unused erroneous bodies still fail checking in all command
paths before any elimination. Changes are comments, tests and documentation;
the existing LLVM transformation already supplies the implementation.

Validation: all three new regression methods and seven related pipeline,
artifact, export, inlining and identity methods passed (10 total). There is no
compiler behavior change, so another compiler rebuild was not required.

### Local common subexpression elimination

The initial implementation is intentionally narrower than general local value
numbering. At binary primitive lowering, after the left operand has been
materialized, it compares the left and right checked trees. If they are equal
safe scalar trees, lowering reuses the left LLVM value for the right operand.
This establishes dominance without a CFG, mutation, a value-numbering table, or
a second lowering sweep.

The safe tree domain contains integer/boolean literals, nonstored local reads,
and integer/boolean primitive operations other than division. Matching includes
the resolved primitive opcode, concrete types, literal bits, and resolved binder
IDs, so shadowing and integer widths remain distinct. Calls, external calls,
loads, pointers, floating-point values, aggregates, stores, division, lets,
sequences, branches and matches are excluded. In particular, no fact crosses a
control-flow boundary, and no unknown operation is reordered or omitted.

`optimization-report` emits `local-cse` at the replaced right operand and names
the left canonical node in `selected`. `-O0` performs no analysis allocation or
rewrite. Two regressions verify reuse of repeated multiplication trees, preserve
the repeated calls that are outside the domain, and reject structurally similar
computations separated by conditionals.

# Verona LLVM bindings

A Verona library binding the LLVM 23 C API directly. It supplies distinct opaque
handle types, module/context/builder ownership helpers, instruction builders,
verification, native target initialization, and object-file emission. The library
uses ordinary Verona `external-function` declarations; it needs no C shim and
has no dependency on the compiler core or the Common Lisp LLVM bindings.

The current surface covers the compiler's initial integer core. It is a focused
subset of LLVM, with raw bindings exposed so other Verona tools can use and
extend it. The signatures and enum values follow the repository's pinned LLVM
23 `llvm-c` headers.

## Build and test

Use the repository's pinned Nix development shell:

```sh
make llvm-bindings
make test-llvm-bindings
make test-compiler-core
```

Or from this directory:

```sh
../../build/verona build verona-llvm ../../build/llvm
../../build/verona build llvm-tests ../../build/llvm
```

The archive is `build/llvm/libverona-llvm.a`. As with other Verona libraries,
source modules are the normal consumption interface: add `projects/llvm/src`
and `projects/base/src` to the consumer's module paths and `(library "LLVM")`
to its build target. LLVM's shared library must be on the linker's search path
and available at runtime. The pinned Nix shell provides both. This library
currently supports the repository's 64-bit AArch64/x86-64 Darwin/Linux targets;
`llvm.target` selects the real architecture-specific C initializers at build time.
Cross-compilation and additional architectures are future additions.

## Modules

| Module | Contents |
| --- | --- |
| `llvm.types` | Distinct opaque `context-ref`, `module-ref`, `type-ref`, `value-ref`, `block-ref`, `builder-ref`, `target-ref`, `machine-ref`, `layout-ref`; 32-bit `boolean` for LLVMBool |
| `llvm.core` | Raw context/module/message management; integer, pointer and function types; functions and parameters; constants; blocks/builders; arithmetic, comparisons, calls, branches, phi nodes, casts and global strings; verification and LLVM's text printer |
| `llvm.enums` | Named LLVM 23 C enum constants for predicates, linkage, verification and object generation |
| `llvm.target` | Raw target/target-machine/layout operations plus `native-machine`, `null-pointer`, and `is-null` helpers |
| `llvm` | Owning `session`, `create`, `destroy`, `verify`, fixed-arity direct `call-0` through `call-3`, and single-edge phi `incoming` helper |

Raw binding names use Verona spelling, for example `llvm.core:build-add` binds
`LLVMBuildAdd`, and `llvm.core:build-call` binds `LLVMBuildCall2`. Opaque LLVM
pointers require explicit function types for calls; the direct-call helpers
obtain them with `LLVMGlobalGetValueType`. Function-pointer calls can use the
raw binding with their known function type. `llvm.core:function-type` accepts
a return type, a contiguous array of parameter handles, a `u32` count, and an
`i32` variadic flag. Integer flags/enums are C `int`, not Verona `bool`.

## Example

This creates and verifies a module whose native `main` returns 42. The source
is Verona; LLVM constructs and prints the IR itself.

```lisp
(import base)
(import llvm)
(import llvm.types :as t)
(import llvm.core :as ir)
(import llvm.target :as target)

(base:function main () exit-code
  (let ((owner llvm:session (llvm:create "example"))
        (context t:context-ref (field owner context))
        (builder t:builder-ref (field owner builder))
        (i32 t:type-ref (ir:int-type context 32))
        (fn t:value-ref (ir:function-add (field owner module) "main"
                         (ir:function-type i32 (& i32) 0 0)))
        (message (pointer u8) (cast (pointer u8) (target:null-pointer))))
    (do
      (ir:builder-position builder (ir:block-append context fn "entry"))
      (ir:build-ret builder (ir:const-int i32 42 0))
      (let ((status i32 (llvm:verify owner (& message))))
        (do
          (match (target:is-null (cast (pointer void) message))
            (true unit)
            (false (do (ir:message-dispose message) unit)))
          (llvm:destroy owner)
          status)))))
```

To generate an object, obtain a machine with
`llvm.target:native-machine(module, out-message)`, then call
`llvm.target:emit-file(machine, module, path, llvm.enums:object-file, out-message)`.
It attaches the host triple and data layout, uses generic CPU/default codegen
optimization and PIC relocation, and returns a caller-owned machine. Link the
object using the host linker. The compiler core demonstrates the full flow.

## Ownership and errors

- A `session` owns one context, module, and builder. Call `destroy` exactly once
  after all generated code and object operations have finished. Assignment
  copies handles, not ownership. Disposing a session invalidates all borrowed
  types, values, functions, and blocks it contains. Do not mix handles from
  different contexts. Raw handles remain unsafe foreign resources.
- The raw APIs preserve LLVM's ownership rules: contexts, modules, builders,
  target machines, and target layouts each have matching disposal calls.
  Functions, values, and blocks belong to their module; types to their context;
  target handles are borrowed from LLVM's registry. `native-machine` disposes
  its temporary triple/layout and transfers the machine to its caller.
- Array arguments borrow a contiguous buffer of the stated handle type for the
  call. Counts must match the allocated capacity and use `u32`. LLVM copies
  function signatures, call arguments, and phi edges. Stack buffers passed by
  the fixed-arity helpers therefore need no heap allocation.
- Returned text from `module-string`, `default-triple`, and `message-create`,
  and diagnostic out-pointers from verification/target/object operations, is
  LLVM-owned memory transferred to the caller. Release each nonnull message
  with `message-dispose`, including verifier messages on success. Initialize
  diagnostic out-pointers to null before calls. Ordinary input strings are
  borrowed NUL-terminated UTF-8/ASCII C strings; LLVM copies stored names.
- Verification uses `verify-return-status`, returning zero on success and a
  diagnostic on invalid IR without aborting the process. Native target creation
  returns a null machine on failure and transfers an allocated diagnostic to
  its out-pointer. Object emission returns nonzero and an allocated diagnostic
  on failure. Dispose a successful machine with `machine-dispose` after use.
- Most builders require structurally valid operands and can assert on incorrect
  use; distinct handles prevent type-category mixups, not all LLVM misuse.
  `null-pointer`/`is-null` use the supported hosts' pointer-sized representation.
  No garbage collector, reference counting, or automatic resource cleanup is
  introduced.

The native test builds calls and control flow with a phi, verifies it, emits an
object, links it, and checks process status 42. It also checks that unterminated
IR and an invalid target triple return diagnostics and that an invalid object
path fails without aborting. The compiler tests exercise wrapping arithmetic,
recursion and runtime guards through the binding. A linker spy verifies that
Clang receives a binary object and only performs native linking; `emit-llvm`
works even when no Clang executable is available.

Verification on the current AArch64 Darwin host: library archive built;
`make test-llvm-bindings` passed all eight FiveAM checks; the compiler passed
21 FiveAM checks and twelve differential/driver test groups. LLVM backend (85),
compiler driver (189), Verona/Base/Foundation, and formatter suites also pass.
`make -k test` still reports the same two existing
`IDE-INSPECTION-SELECTS-EXPANSION-SUBTREES` failures in the frontend suite.
Linux and x86-64 execution have not been independently verified here.

# Hitherto: Stage0 Interface and Compiler Extraction

## Objective

Review the current Stage0 (`bootstrap.s`) and Stage1 (`.ht`) implementations. Determine the **minimum remaining functionality Stage0 must expose** so compiler logic can move into Stage1, while preserving the efficient register-based execution model and preparing for AArch64, RISC-V and eventually WASM.

Do not implement changes yet. Produce a concrete interface proposal grounded in the current code.

## Architecture

Hitherto currently uses a threaded interpreter with compilation performed partly in x86-64 assembly and increasingly in `.ht`.

Stage0 assigns dedicated registers:

- `rbp`: current definition
- `rbx`: scope-stack cursor
- `r12`: instruction pointer / active compilation cursor
- `r13`: cached top of data stack
- `r14`: dictionary tail
- `r15`: data-stack cursor

**These registers are authoritative.** Do not introduce mirrored memory state. Native backends should preserve dedicated register allocation. Expose register-backed getters/setters where necessary; WASM may implement equivalent logical state differently.

## Investigation

### 1. Inventory existing Stage1 functionality

Inspect the actual source, especially `bootstrap.ht`, rather than assuming functionality is missing.

Stage1 already implements substantial portions of:

- Node representation, creation, finalization and name matching.
- Dictionary operations and tail management.
- Scope tags and invocation-frame decoding.
- Memory access, arithmetic and Linux wrappers.

Identify exactly which compiler operations are already implemented versus still delegated to Stage0.

### 2. Trace compiler dependencies

Follow the execution paths from `read_token` and `eval_token` through:

- `find_scope`, `find_node`, `find_member`, `find_member_chain`
- `resolve_declaration_type`, `resolve_signature_type`
- `compile_signature`, `compile_local`
- `compile_definition_open`, `compile_child_declaration`, `compile_child_publish`
- Control-region creation, closing and patching
- Immediate-word execution and recursive `source`

For each operation, identify its inputs, outputs, state dependencies and use of dedicated registers.

Pay particular attention to compilation inside immediate words, where `rbp` and `r12` describe the executing helper rather than necessarily the compilation target.

### 3. Audit the Stage0 interface

Review the existing `$n` core table, including dictionary addresses, tail accessors, runtime instruction entry points and stack bases.

Determine whether Stage1 still needs access to:

- The **live scope cursor**, currently `rbx`.
- The active compilation target, potentially derived from tagged scope entries.
- Compiler execution state (`STATE_EXE` / `STATE_DEF`).
- The local-node code identity used for signature validation.
- Any execution or scope operations that cannot safely be implemented in `.ht`.

Distinguish **information requiring a new primitive** from information derivable using existing node structures and scope tags.

Prefer the latter when it does not compromise execution efficiency.

### 4. Identify runtime/compiler coupling

Some apparently compiler-related functionality still participates in execution.

In particular, `word_member_dispatch` performs runtime member lookup for inherited virtual overrides.

Identify such dependencies before proposing that their Stage0 implementations be removed. Preserve existing dispatch semantics unless an explicit replacement is proposed.

### 5. Assess backend portability

Separate the common language interface from architecture-specific implementations.

Native targets should retain dedicated registers and direct execution where practical. WASM may require globals, function tables or another representation.

Review dependencies on machine-code pointers, inline `asm`, native-code buffers and Linux syscalls. Do not require physical register numbering to be identical across targets.

## Deliverables

Produce:

1. **Existing interface inventory** — what Stage0 already exposes and how Stage1 uses it.
2. **Missing interface table** — proposed primitive, reason required, and whether a Stage1 implementation is possible instead.
3. **Extraction order** — smallest practical sequence for moving remaining compiler functionality into `.ht`.
4. **Portability constraints** — which interfaces can remain common and which require target-specific implementations.

For each proposed addition, identify the relevant functions or source locations.

## Design constraints

- Stage0 should become smaller, not acquire new compiler abstractions.
- Keep one authoritative copy of execution state.
- Preserve the current node and signature formats unless a change is demonstrably necessary.
- Prefer portable semantic operations over exposing x86-specific register names.
- Do not introduce IR, optimization, garbage collection or unrelated runtime features during this extraction.
- Preserve current language behavior and regression tests.

**Success criterion:** A justified, minimal Stage0 interface sufficient to move member/type resolution, signature compilation and subsequent compiler logic into Stage1 without sacrificing native register efficiency.

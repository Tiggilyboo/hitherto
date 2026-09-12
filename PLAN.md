# Hitherto Typed Bootstrap Plan

## Goal

Keep runtime typing at zero cost.

- Runtime values remain untagged qwords.
- The assembly core remains a small Forth-like qword machine.
- Numeric width/signedness semantics live in Hitherto type members, using `asm` where machine behavior differs.
- The compiler tracks only type-node pointers while compiling; no runtime type metadata or dispatch is emitted.
- The compiler knows nothing about signedness, widths, `DIV`/`IDIV`, `SHR`/`SAR`, etc. It only resolves members and validates signatures.
- Field/layout sugar is deferred to the future Hitherto-hosted compiler.

## 1. Existing foundations

Already implemented:

1. `parse_hex` defect fix.
2. Lexical `self` resolution.
3. Lexical locals vs public/inherited member lookup.

Keep these invariants:

- `self` is only a lexical type alias.
- Signatures are the only invocation contract.
- Runtime values have no hidden receiver or type tag.
- Public member lookup skips locals and follows `NODE_TYPE` ancestry.

## 2. Bootstrap type hierarchy

Use representation types for width and derived types for interpretation:

```text
cell
├── b8
│   ├── u8
│   └── i8
├── b16
│   ├── u16
│   └── i16
├── b32
│   ├── u32
│   └── i32
└── b64
    ├── u64
    └── i64

addr
memory
└── str
```

Meaning:

- `cell`: packed scalar qword semantics.
- `bN`: physical width/bit-pattern behavior.
- `uN` / `iN`: unsigned/signed interpretation.
- `addr`: numerical address value; separate from packed scalar semantics.
- `memory`: pointer + length abstraction.
- `str`: printable length-delimited memory span; not NUL-terminated.

## 3. Numeric behavior belongs to the types

Typed numeric operations must resolve through the type hierarchy. Do not teach the compiler numeric semantics.

Define common behavior once on `cell`/`bN`; override only where signedness changes behavior.

Common bit-level behavior includes:

```text
+  -  *  <<  =  bitwise ops  store
```

Signedness-sensitive behavior includes:

```text
/     DIV vs IDIV
<     unsigned vs signed comparison
>>    SHR vs SAR
.     unsigned vs signed formatting
@     zero-extension vs sign-extension for narrow loads
&     narrow canonicalization/sign-extension
```

Narrow signed canonical forms are sign-extended qwords:

```text
u8  0xff       -> 255
i8  0xff       -> -1
u16 0xffff     -> 65535
i16 0xffff     -> -1
u32 0xffffffff -> 4294967295
i32 0xffffffff -> -1
```

Thus initially:

```text
i8   overrides & and @
i16  overrides & and @
i32  overrides & and @
i64  needs no representation override
```

The typed numeric hierarchy should expose a complete operator surface for operations intended to work on typed values. Implement shared members once and signed/unsigned variants with `asm` where needed.

## 4. Root builtins

Keep root arithmetic builtins as raw/untyped qword operations for bootstrap and explicitly untyped code.

They are not fallback semantics for a known typed value.

Rule:

```text
known lhs type:
    resolve operator through lhs type/member chain
    missing member -> compile error

unknown lhs type:
    root builtin may be used
```

This avoids silent errors such as `u64 /` falling through to signed root division.

## 5. Zero-runtime-cost compiler type mirror

The compiler maintains a parallel compile-time stack containing only:

```text
0             unknown/untyped
NODE_TYPE*    concrete type node
```

Nothing is emitted at runtime for this stack.

Runtime code remains exactly the same shape as untyped code; the compiler only chooses which word node to emit.

Examples of compiler-only updates:

```text
typed local get   push local.NODE_TYPE
untyped literal   push unknown
^                 duplicate type
_                 drop type
><                swap types
<^                duplicate NOS type
```

The mirror is necessary because computed values no longer have a source node to inspect:

```forth
a b + c /
```

After `+`, the compiler must remember the result type so later operators can resolve correctly.

## 6. Operator dispatch

Binary operators dispatch from the lhs/NOS type, not the rhs/TOS type.

```text
lhs rhs op
^^^
operator owner
```

This is required for operations such as shifts:

```forth
i64:value u8:count
value count >>
```

`>>` must resolve through `i64`, because the lhs determines `SAR` vs `SHR` and the result type.

Compilation rule:

1. read lhs type from compile-time type stack;
2. if known, resolve the operator with `find_member(lhs_type, operator)`;
3. validate operands against the resolved word signature;
4. emit that resolved word;
5. update the compile-time type stack from its outputs.

No runtime dispatch occurs.

## 7. Signature type propagation

Use ordinary signatures for operator and word type checking.

For a call:

1. compare known actual input types with declared input types through `NODE_TYPE` ancestry;
2. bind actual input types to the called word's input locals;
3. consume input type entries;
4. push output types.

Output rule:

- new output local -> declared type;
- reused input/output local -> actual type bound to that input at the call site.

Example:

```forth
( b64:a b64:b -- a )
```

Called with `u64 u64`, the output remains `u64`.
Called with `i64 i64`, the output remains `i64`.

This allows shared base operations to preserve concrete subtype identity without compiler knowledge of numeric types.

## 8. Mixed numeric types

Do not add implicit promotion rules to the bootstrap compiler.

Initially require operands to satisfy the resolved operator signature through normal ancestry rules.

Examples:

```text
u64 + u64    valid
i64 / i64    valid
u32 + u16    error unless explicitly converted
i32 < u32    error unless explicitly converted
```

Promotion/coercion policy can be added later in the hosted compiler.

## 9. Control flow

Type tracking must remain compile-time only.

At control-flow joins, require compatible abstract stacks:

- same depth;
- each known type compatible with the corresponding joined type;
- otherwise reject compilation.

Do not emit runtime type reconciliation.

## 10. Typed local members

Implement:

```forth
v~member
```

for typed locals as a compile-time rewrite:

1. emit normal local-get for `v`;
2. read `NODE_TYPE(v)`;
3. resolve `member` through that type's public member chain;
4. compile the ordinary member call.

Do not treat locals as runtime receiver/scope objects.

## 11. Fields and layout

Keep generic field extraction in Hitherto:

```forth
[ :cell
    [ :field ( :v :offset :mask -- :o )
        v
        offset >>
        mask
        &
        to o
    ]
]
```

Concrete accessors can already be written using ordinary Hitherto:

```forth
[ i8:x
    ( self:v -- i8:o )
    v 8 mask field & to o
]
```

The final type `&` canonicalizes signed or unsigned field values.

Defer all compiler sugar for:

- `u8:x` layout declarations;
- automatic offsets/layout measurement;
- generated field accessors;
- field flags/metadata;
- pointer-backed layout generation.

Those belong in the future Hitherto-hosted compiler.

## 12. Linux boundary

Keep syscall ABI lowering separate from Hitherto value abstractions.

- `addr` is the raw address value type.
- `memory` exposes pointer + length.
- `str` is length-delimited and not NUL-terminated.
- pathname syscalls must materialize a NUL-terminated representation at the Linux boundary.
- raw syscall results remain signed/raw until success is checked; only then refine to types such as `fd` or `addr`.

## 13. Implementation order

1. Establish `cell`, `b8/b16/b32/b64`, `u8/u16/u32/u64`, `i8/i16/i32/i64`, and `addr`.
2. Implement width masks, canonicalizers, narrow loads/stores, and signed narrow extension.
3. Implement complete typed arithmetic/comparison/shift behavior in Hitherto, using `asm` for machine variants.
4. Add the compiler-only type stack of type-node pointers.
5. Mirror normal Forth stack operations on the type stack.
6. Add lhs-directed typed operator resolution with no root fallback for known types.
7. Add signature input validation and output type propagation, including concrete type preservation for reused outputs.
8. Validate type stacks across control-flow joins.
9. Implement typed-local `v~member`.
10. Build `memory`, `str`, and typed Linux wrappers on top.
11. Defer field/layout sugar to the hosted compiler.
12. Optimize only after semantics are stable.

## 14. Required tests

Verify at minimum:

```text
signed/unsigned narrow canonicalization
signed/unsigned narrow loads
u64 vs i64 division
u64 vs i64 comparison
u64 SHR vs i64 SAR
no root fallback for known typed operators
root builtins still work for unknown/untyped values
reused outputs preserve actual subtype
stack operators preserve mirrored types
computed expressions preserve result types
mixed incompatible numeric types are rejected
control-flow joins reject incompatible type stacks
lexical locals still shadow public members
explicit member lookup still skips locals
```

## Non-goals

Do not add:

- runtime type tags;
- tagged data-stack cells;
- runtime type lookup or dispatch;
- compiler signedness/width flags;
- arithmetic-specific compiler tables;
- implicit numeric promotion;
- hidden receivers;
- new signature modes;
- typed root fallback;
- bootstrap field/layout syntax;
- field-specific runtime machinery.

The compiler should only need to know:

```text
what type node describes each compile-time stack value?
what signature does this word declare?
does the lhs type provide this operator/member?
```

Everything else belongs to ordinary Hitherto definitions.

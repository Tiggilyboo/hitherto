# Hitherto Typed Layout and Invocation Plan

## 1. Design goals

Keep the feature inside Hitherto's existing mechanisms:

- definitions are callable words and namespaces;
- `type:name` remains the declaration form;
- signatures define all stack consumption/output;
- no hidden receiver, receiver register, receiver flag, or signature prefix;
- `immediate` remains compile-time execution only;
- packed layout metadata is represented by ordinary child nodes;
- leaf packed width comes from an immediate `mask` member;
- composite width is derived from declared fields;
- runtime values remain untagged qwords; type checking is a compiler concern.

Working example:

```forth
[ :u8
    [ :mask ( -- :v )
        0xff
        to v
        immediate
    ]

    [ :& 0xff & ]

    ( :i -- self:v )
        i 0xff &
        to v
]

[ :something
    u8:x
    u8:y
    u16:z

    ( u8:x u8:y u16:z -- self:v )
        x
        y 8 << |
        z 16 << |
        to v

    [ :double ( self:v -- v )
        v~x 2 *
        v~y 2 *
        v~z 2 *
        something
        to v
    ]
]
```

## 2. Signature semantics

Signatures remain the only invocation contract.

```forth
( self:v -- v )
```

means:

- consume one qword into local `v`;
- `v` is typed as the lexical owning type;
- reuse local `v` as the output;
- effective stack effect is `self -> self`.

There is no special preservation mechanism. If an input survives a call, it must appear in the outputs.

Output ordering remains meaningful. For example:

```forth
( self:v -- v u8:x )
```

means `self -> self u8`.

The existing signed invocation machinery already supports input locals, reused output locals, staging outputs, reclaiming consumed inputs, and emitting outputs. Do not extend the signature header with receiver metadata.

## 3. `self`

`self` is only a lexical type alias used in `type:name` declarations.

It is not:

- a value;
- a hidden receiver;
- an unnamed signature item;
- a runtime context pointer.

Initial resolution rule:

- in a type's own top-level constructor, `self` resolves to that definition;
- in a nested member, `self` resolves to the owning/enclosing type definition.

Keep self-resolution isolated in `resolve_declaration_type`; do not expose unfinished definitions through ordinary word lookup merely to support `self`.

Nested type definitions are an edge case until type-vs-member ownership is formalized; do not broaden `self` semantics implicitly.

## 4. Definition preamble and fields

Leading typed declarations before the signature are persistent layout fields:

```forth
[ :header
    u32:a
    u8:b
    u8:c

    ( -- )
    ... executable body ...
]
```

Meaning:

- `a`, `b`, `c` are child field nodes of `header`;
- they are not invocation locals;
- they are not executed when `header` is invoked;
- the signature begins the callable portion of the definition.

Declarations inside `( ... )` remain invocation locals.

Once executable code begins, existing body declaration behavior remains unchanged.

Because a leading `type:name` is now a field, a definition whose executable body intentionally begins with a typed child declaration must use an explicit `( -- )` boundary.

Refactor `compile_definition_open` into a preamble loop:

1. read the next token;
2. `type:name` -> compile a field and continue the preamble;
3. `(` -> compile signature, set code start, open executable control region;
4. anything else -> set code start, open executable control region, evaluate that token;
5. `]` after fields -> establish an empty executable body and close normally.

Do not move `NODE_BODY` or add `NODE_SIZE`.

## 5. Field node representation

Fields are ordinary child nodes with a distinct code kind, e.g. `word_field`.

Minimum field state:

```text
NODE_CODE = word_field
NODE_TYPE = declared field type
payload:
    packed bit offset
    packed bit width or extraction mask
```

The exact payload packing can be chosen for the smallest representation; it does not require a fixed node-header field.

`compile_field` should mirror the publication pattern of `compile_local`, but fields are persistent public members rather than invocation-frame locals.

Fields are densely packed in declaration order. There is no implicit alignment or padding.

## 6. Packed width and `mask`

Do not add `size`, `mask` metadata fields, or magic inspection of `&` implementation code.

A leaf scalar type exposes its maximum packed value through an immediate member named `mask`:

```forth
[ :u8
    [ :mask ( -- :v )
        0xff
        to v
        immediate
    ]
]
```

Rules for a layout-capable leaf `mask`:

- member name is `mask`;
- it must be immediate;
- signature must consume zero inputs and produce exactly one output;
- it must return a non-zero contiguous low-bit mask (`2^n - 1`);
- it must not emit runtime code while being queried by the layout compiler.

Examples:

```text
u8~mask  -> 0xff    -> width 8
u16~mask -> 0xffff  -> width 16
```

Derived scalar types inherit `mask` through the existing `NODE_TYPE` member lookup chain.

Composite width is not queried through a synthetic `mask`. It is derived by summing its direct field widths. This recursively solves nested composites without a `NODE_SIZE` field.

## 7. Isolated compile-time property evaluation

Normal `immediate` semantics execute against the compiler-time data stack and may emit into the active compile target. Layout queries must be stricter.

Add one internal helper for compile-time property evaluation, conceptually:

```text
query_immediate_value(type, "mask") -> qword
```

It must:

1. resolve the member through normal type inheritance;
2. require `NODE_IMMEDIATE_MASK`;
3. inspect/validate the zero-input, one-output signature;
4. execute the word with no usable runtime-code emission target;
5. obtain exactly one resulting value;
6. restore compiler stack/state completely;
7. reject missing members, malformed signatures, stack imbalance, or attempted code emission.

Prefer executing the property in an isolated `STATE_EXE`-style context while preserving the surrounding `STATE_DEF`, `rbp`, `r12`, `rbx`, and data-stack state. This naturally makes `lit`/compile-target emission invalid during a property query.

Do not put `lit` inside `mask`. A source-level immediate may still explicitly use `mask` plus `lit` when the programmer intentionally wants to emit the constant.

## 8. Member lookup: locals are not public members

Current direct member lookup shares the same child/local dictionary and can expose `word_local` nodes through `find_member`.

Split lookup semantics without splitting physical storage:

- lexical lookup may find signature locals;
- public/member lookup must skip `NODE_CODE == word_local`;
- fields and nested words remain public members;
- inherited member lookup continues through `NODE_TYPE`.

Recommended helpers:

```text
find_local(node, name)          # direct word_local only
find_direct_member(node, name)  # direct non-local children
find_member(node, name)         # direct member + NODE_TYPE chain
```

Update `find_scope` so current/parent locals keep their existing lexical precedence, while `scope~member` cannot expose invocation locals.

## 9. Typed-local member access

Implement the intended meaning of:

```forth
v~x
```

when `v` resolves to `word_local`:

1. emit `internal_local_get` for `v`;
2. obtain `NODE_TYPE(v)`;
3. resolve `x` through that type's member chain;
4. emit the resolved field/member call normally.

Do not use the local node as `SCOPE_CONTEXT_TAG`; that context is dictionary dispatch state, not a runtime receiver.

There is no runtime value-based dynamic dispatch because values carry no runtime type tag. Dispatch from a typed local is statically determined by its declared type.

For an untyped value, explicit qualification remains valid:

```forth
value something~x
```

The member operation consumes/uses the actual data-stack value according to its implementation/signature.

## 10. Field execution

A field is a real stack operation; it has no hidden receiver.

For a packed scalar owner:

```text
owner-value -> field-value
```

Implementation:

```text
(field = value >> bit_offset) & field_mask
```

The original value is consumed unless the caller explicitly preserved or stored it elsewhere.

This matches typed locals naturally:

```forth
v~x
```

loads `v`, then extracts `x`; the original `v` still exists in its local slot.

## 11. Pointer-backed types

Representation kind is determined by the type system, not field syntax.

Introduce one minimal builtin/internal pointer base type (working name `ptr`). A type deriving from it is address-backed; other types are value-backed.

Use the existing `NODE_TYPE` ancestry chain to test this property.

```forth
[ ptr:header
    u32:a
    u8:b
]
```

means a `header` qword is an address to packed storage.

For an address-backed owner:

- field bit offsets are still derived from the same dense layout;
- scalar fields are read from memory at the corresponding offset and masked to their width;
- a field whose representation is itself address-backed may return the address of that embedded subregion rather than loading it.

Initial implementation should reject address-backed field offsets/extents that are not byte-aligned unless bit-addressed memory loads are deliberately implemented.

Do not introduce separate `@(`/`$(` signature forms or receiver modes.

## 12. Constructors and namespaces

A definition is callable only according to its ordinary signature/body.

Example constructor:

```forth
[ :something
    ... fields ...

    ( u8:x u8:y u16:z -- self:v )
        ...
        to v
]
```

Calling `something` consumes its declared inputs and emits a qword typed as `something` in compiler analysis.

A nested word with no owning-type input is simply a namespaced/static function:

```forth
[ :something
    [ :whatever ( -- :v )
        123 to v
    ]
]
```

No separate static flag is needed.

`immediate` stays orthogonal: it only chooses compile-time execution instead of call emission.

## 13. Compiler type validation

Runtime qwords remain untagged. Add validation to the compiler's abstract stack rather than runtime primitives.

Track, at minimum:

```text
unknown
concrete NODE_TYPE
```

Rules:

- unknown input may call anything compatible with stack arity;
- known typed input must satisfy the callee's declared type, following `NODE_TYPE` ancestry;
- local get pushes the local's declared type;
- constructor outputs push their declared output type (`self:v` included);
- field access consumes the owner value and pushes the field's `NODE_TYPE`;
- reused output locals retain their declared type;
- a namespaced member does not require an owner value unless its signature declares one.

This is where `something~double` validates that TOS is `something`; there is no separate receiver validation pass.

## 14. Implementation order

1. Fix existing parser/runtime defects independently (including the known `parse_hex` empty-input test).
2. Add lexical `self` resolution in type declarations.
3. Split lexical-local lookup from public member lookup.
4. Add `word_field` and `compile_field`.
5. Refactor `compile_definition_open` to parse leading field declarations before the optional signature.
6. Add isolated immediate-property query and `mask` validation.
7. Compute field offsets/widths recursively during definition.
8. Implement packed scalar `word_field` extraction.
9. Implement typed-local `v~member` as local-get + static member resolution.
10. Add the internal pointer base type and address-backed field path.
11. Add compiler abstract-stack type validation.
12. Only then optimize identity constructors/pass-through locals or constant-fold immediate properties.

## 15. Required tests

### Leaf mask

```forth
u8~mask  -> 0xff at compile time
u16~mask -> 0xffff at compile time
```

Reject:

- missing `mask` for a leaf field type;
- non-immediate `mask`;
- inputs on `mask`;
- zero/multiple outputs;
- zero or non-contiguous mask;
- `mask` attempting `lit`/runtime emission during layout query.

### Layout

```forth
[ :something
    u8:x
    u8:y
    u16:z
]
```

Must produce:

```text
x offset 0,  width 8
y offset 8,  width 8
z offset 16, width 16
total width 32
```

### Constructor

```forth
1 2 3 something
```

must consume three qwords and produce one qword whose compiler type is `something`.

### Typed local fields

```forth
[ :f ( something:v -- )
    v~x
]
```

must emit local-get for `v`, then field extraction, and infer result type `u8`.

### Pass-through

```forth
[ :identity ( something:v -- v ) ]
```

must consume and re-emit the same declared local through existing signature semantics; no receiver machinery is involved.

### Namespace/static member

```forth
something~whatever
```

must require only `whatever`'s declared inputs, not an implicit `something` value.

### Pointer-backed layout

A `ptr`-derived owner must interpret fields relative to its TOS address; a value-backed owner must extract fields from the qword itself.

## 16. Explicit non-goals

Do not add in this pass:

- hidden/preserved receivers;
- receiver registers or scope-stack receiver values;
- receiver node flags;
- special signature prefixes;
- `NODE_SIZE`;
- static-value node/storage classes;
- `size`/`mask` declaration keywords;
- magic execution/introspection of `&`;
- automatic `lit` behavior for `mask`;
- implicit alignment/padding;
- runtime tagged values;
- runtime value-based dynamic dispatch.

The implementation should first make the existing dictionary, signature, immediate, and type mechanisms compose cleanly; optimization and richer ABI layout rules can follow later.

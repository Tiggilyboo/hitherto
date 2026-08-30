
# Hitherto Signatures and Signed Scope Implementation Plan

## Definitions

Use these terms consistently throughout the implementation:

| Term                       | Meaning                                                                                                                                                                                                                                             |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Definition**             | A dictionary node whose `NODE_CODE` executes Hitherto threaded code through `word_exec`.                                                                                                                                                            |
| **Signature**              | The ordered input and output declarations in `( inputs -- outputs )`.                                                                                                                                                                               |
| **Signature local**        | An ordinary child node created from one signature declaration. It participates in the existing local dictionary and lookup rules.                                                                                                                   |
| **Lexical parent**         | The enclosing definition of a nested definition. Existing compilation records this relationship with `SCOPE_PARENT_TAG`; `find_scope` walks these entries when resolving names from enclosing definitions.                                          |
| **Receiver context**       | The dynamic receiver established by a qualified `x~member` call. Existing runtime code records it with `SCOPE_CONTEXT_TAG` and uses it for override/member dispatch. Do not call this the lexical parent or lexical context.                        |
| **Type chain**             | The chain followed through `NODE_TYPE` after searching a node's own child dictionary. It is distinct from lexical-parent lookup and receiver-context dispatch.                                                                                      |
| **Compile target**         | The definition currently receiving emitted code while Hitherto code executes during `STATE_DEF`. Existing code records this with `SCOPE_COMPILE_TAG` and temporarily parks its compile cursor in `NODE_END`.                                        |
| **Active invocation**      | One runtime execution of a signed definition. This is new. It is represented by one untagged node-bearing entry on the existing scope stack.                                                                                                        |
| **Control entry**          | Existing non-node scope-stack data used by `[ ... ]`, `~[`, `~]`, and compilation bookkeeping. At runtime the packed control value contains start/end offsets. During compilation the same stack also contains descriptor and skip-patch addresses. |
| **Stack mark**             | The value of `r15` when an active invocation begins. It separates that invocation's inputs from temporary values produced by its body.                                                                                                              |
| **Temporary**              | A logical data-stack value produced after invocation entry and above that invocation's stack mark. Inputs are not temporaries.                                                                                                                      |
| **Source output order**    | The order of names following the body epilogue `--`. It describes the order of the selected temporary values from deeper stack position to TOS.                                                                                                     |
| **Signature output order** | The order of outputs declared after `--` inside the signature. This is the order returned to the caller.                                                                                                                                            |
| **Return map**             | For each output in signature output order, the source-output position containing its value. Source position `0` means the deepest of the selected output temporaries; source position `M-1` means TOS when there are `M` outputs.                   |

The dedicated register meanings remain those already defined by the source: `rbp` current dictionary word/execution frame, `rbx` scope-stack cursor, `r12` threaded instruction pointer, `r13` cached TOS, `r14` dictionary tail, and `r15` data-stack cursor.

---

## 1. Language contract

A definition declares its stack contract as:

```forth
[ :test ( :a :b -- :c :d )
    ...
]
```

A declaration means:

```text
:name       one untyped 64-bit cell
type:name   one 64-bit cell carrying that declared type in metadata
```

Inputs and outputs combined may contain at most eight entries.

For:

```forth
( :a :b -- :c :d )
```

the caller supplies `a` below `b`, with `b` as TOS immediately before the call.

After return, the caller receives `c` below `d`, with `d` as TOS.

The bootstrap records declared types but does not attempt general static type-flow, branch, range, or definite-assignment proof.

---

## 2. Body output epilogue

A definition declaring one or more outputs must contain a terminal body epilogue:

```forth
--
output-name ...
```

Every declared output must occur exactly once. The order may differ from signature output order.

Example:

```forth
[ :test ( :a :b -- :c :d )
    a b +
    ^
    2 *
    --
    d c
]
```

Immediately before this epilogue there are two selected output temporaries. The deeper selected temporary is the result of `a b +`; the TOS value is twice that result.

The source output order is therefore:

```text
source position 0 = value named d
source position 1 = value named c
```

The signature output order is:

```text
signature output 0 = c
signature output 1 = d
```

The return map is consequently:

```text
return_map[0] = 1
return_map[1] = 0
```

Runtime return places source position `1` into caller-visible output `c` and source position `0` into caller-visible output `d`.

The caller therefore receives the doubled value as `c` and the original sum as `d`; `d` is TOS after the call.

With at most eight outputs, each source position requires three bits. The complete return map occupies at most 24 bits:

```text
bits 3*j through 3*j+2 = source position for signature output j
```

The output count stored in the signature determines how many entries are meaningful.

Names following the body `--` are compile-time metadata. They do not execute local words or perform individual runtime stores.

---

## 3. Definitions with no outputs

If `output_count` is zero, closing the definition is sufficient to establish its return point:

```forth
[ :consume ( :x -- )
    1
    2
    3
]
```

At runtime the three temporaries are discarded and `x` is consumed.

Zero-output return still validates that the active invocation being exited is the invocation of the current definition. It is not an unchecked fall-through from `word_exec`.

No output storage or initialized-output state exists.

---

## 4. Signature-local representation

Signature declarations create ordinary child nodes in the definition's existing local dictionary.

The existing node machinery already gives each node an exact name, a `NODE_TYPE`, a child-dictionary tail, payload storage, `NODE_END`, and dictionary linkage.

A signature local uses:

```text
NODE_CODE   = word_signature_local
NODE_TYPE   = declared type node or zero
payload     = owner definition offset + signature slot index
```

The owner is stored as a dictionary-relative byte offset.

The slot index is `0..7`.

Whether that slot is an input or output is derived from the owning definition's `input_count`; do not duplicate a role flag in the local.

Signature locals must be linked through the parent's existing local-tail cell. Use `node_add`, `node_finalize`, and `node_locals_ref` rather than creating another local structure.

They are allocated before the definition's executable root control region begins, so they do not require runtime `internal_skip` instructions merely to avoid executing their node bytes.

---

## 5. Definition payload metadata

`node_payload` continues to identify the beginning of definition-specific payload data.

For a Hitherto definition, reserve this fixed metadata block before its signature-local child nodes:

```text
payload + 0
    SIG_META, one qword

payload + 8
    SIG_CODE, one qword

payload + 16
    signature-local references, eight u32 dictionary-relative offsets

payload + 48
    first signature-local node, if any
```

### SIG_META

```text
bits 0..3      input_count
bits 4..7      output_count
bits 8..31     return_map
bit 32         output epilogue was supplied
bits 33..63    reserved
```

The epilogue flag is needed only to distinguish a parsed epilogue from the default zero contents of a valid return map.

### SIG_CODE

```text
low 32 bits     executable code-start byte offset from NODE_BODY
high 32 bits    executable code-end byte offset from NODE_BODY
```

The separate execution-end offset is necessary because the end of the root control region and the end of the definition's executable thread are no longer the same position.

The current `word_exec` assumes the root control descriptor at payload offset `+8` supplies the execution end. That assumption must be removed when this metadata layout is introduced.

The fixed eight-entry reference table costs 32 bytes and avoids another variable metadata parser. Only the first `input_count + output_count` entries are meaningful.

Each reference points to the corresponding signature-local node in declaration order.

---

## 6. Signature parsing and local creation

After `[ :name`, compilation must parse the signature before opening the definition's root control region.

The existing `parse_declaration` already separates `type:name` into a type span and a name span, and `resolve_declaration_type` already resolves an optional type through current scope lookup. Reuse those routines.

Compilation performs these operations in sequence:

1. Reserve and clear the 48-byte definition metadata block.
2. Require `(`.
3. Parse input declarations until the signature separator `--`.
4. Parse output declarations until `)`.
5. Reject a total count greater than eight.
6. For each declaration, create and immediately finalize a signature-local child node and write its dictionary-relative offset into the corresponding reference-table position.
7. Record the input and output counts.
8. Record the current physical position as `SIG_CODE.code_start`.
9. Call the existing `compile_ctrl_open` so threaded execution begins with the definition's root control region.

For nested definitions, this occurs after `compile_child_declaration` has allocated the child but before its root `compile_ctrl_open`. The parent's existing inline-child skip continues to skip the entire child definition, including signature metadata and locals.

---

## 7. Compiling the body epilogue

The body spelling `--` is an immediate compiler word, distinct from the signature parser's handling of the same token.

For a definition with `M > 0`, it must be encountered while compiling that definition's root control region, not while an anonymous nested control region remains open.

The compiler reads exactly `M` output-name tokens.

For source position `s` from `0` through `M-1`:

1. Compare the token against the declared output nodes stored in the definition's signature reference table.
2. Determine that declaration's output index `j`.
3. Reject a name that is not an output or whose output bit has already been seen.
4. Set the transient seen bit for `j`.
5. Store `s` in the three-bit field `return_map[j]`.

After all `M` names have been parsed, every output bit must have been seen.

Set `SIG_META.epilogue_seen`.

From that point until the root `]`, no additional body token is legal.

Do not emit the runtime return instruction from the `--` compiler word; the root control frame must be closed first.

---

## 8. Closing a signed definition

The existing `word_ctrl_close` currently emits `internal_ctrl_pop`, patches the control descriptor's end offset, then either finalizes a global definition, publishes a child definition, or returns from an anonymous control close.

Retain that ordering for anonymous controls.

When the control being closed is the definition's root control region:

1. Emit its existing `internal_ctrl_pop`.
2. Patch the root control descriptor end to the current position.
3. If `output_count > 0`, require `epilogue_seen`.
4. Emit `internal_signed_return`.
5. Record the position immediately after that instruction as `SIG_CODE.code_end`.
6. Finalize or publish the definition using the existing node lifecycle.

For `output_count == 0`, step 3 imposes no epilogue requirement and the same signed-return instruction is emitted automatically.

The patched root-control end therefore identifies the address of `internal_signed_return`, while `SIG_CODE.code_end` identifies the address after it.

---

## 9. `word_exec` integration

`word_exec` currently saves `rbp`, `r12`, and `rbx`, preserves compile-target behavior when executing Hitherto during `STATE_DEF`, derives a threaded execution end, and restores the saved machine state afterwards. Preserve the compile-target logic unchanged in meaning.

After compile-target setup:

1. Set `rbp` to the word being invoked.
2. Read the signature metadata.
3. Validate and push the active invocation described in section 11.
4. Set `r12` from `SIG_CODE.code_start`.
5. Use `SIG_CODE.code_end` as the threaded execution-end address.
6. Run the existing threaded dispatch loop.
7. On reaching `code_end`, perform the existing native-state restoration.

`internal_signed_return` must already have removed the active invocation before the dispatch loop reaches `code_end`.

---

## 10. Logical stack convention

The implementation must reason from the current cached-TOS representation rather than pretending every logical value has a permanent memory address.

`r15` is the logical depth cursor. A push stores the previous `r13` value at `[r15]`, advances `r15` by one cell, then makes the new value `r13`. Current `word_lit` demonstrates this directly.

When logical depth is nonzero, `r13` contains the logical TOS.

When logical depth is zero, `r13` does not represent a language stack value.

For an active invocation:

```text
F = stack_mark recorded at entry
K = (r15 - F) / 8
```

`K` is the number of current temporaries belonging to that invocation.

At entry, `K` is zero.

---

## 11. Scope-stack encoding

The current scope stack is 64 qwords, and the current data stack is 65,536 bytes. The dictionary is 131,072 bytes.

Use bit 63 to distinguish node-bearing entries from existing opaque entries:

```text
bit 63 = 1    encoded node-bearing scope entry
bit 63 = 0    existing non-node entry
```

A bit-63-clear entry may currently represent a packed runtime control frame, a compile-time control descriptor pointer, or a nested-child skip-patch pointer. Its interpretation remains with the code that created it.

For bit-63-set entries:

```text
bits 0..2      existing SCOPE_* tag
bits 3..31     dictionary-relative node byte offset
bits 32..47    data-stack cell index of stack_mark
bits 48..62    reserved
bit 63         node-bearing marker
```

The current dictionary size fits the low 32-bit relative-node field, and the current data-stack cursor range fits the 16-bit stack-mark field.

Tagged lexical-parent, receiver-context, and compile-target entries store zero in the stack-mark field.

An active invocation has all three tag bits clear and stores its stack mark.

Add shared encode/decode helpers and migrate every node-bearing scope-stack producer and consumer to them before introducing active invocations.

In particular, `scope_context`, `scope_compile_target`, lexical-parent scanning, member dispatch, qualified execution, child-close detection, and compile-target parking must first verify the node-bearing marker before interpreting tag bits. Current helpers assume a tagged absolute node pointer and mask the low bits directly; that representation cannot coexist with the new encoding.
Runtime control operations should reject a bit-63-set entry where a packed control entry is required rather than accidentally interpreting invocation metadata as control offsets.

---

## 12. Invocation entry

For a callee requiring `N` inputs, determine how many values its caller is permitted to supply.

If the caller has an active signed invocation with stack mark `C`:

```text
caller temporary count = (r15 - C) / 8
```

Require that count to be at least `N`.

At top-level execution, calculate available values from the existing global data-stack depth.

After validation:

```text
F = current r15
```

Push one untagged active-invocation entry containing the callee node and `F`.

Do not copy the inputs and do not allocate output cells.

The root `internal_ctrl_push` then executes normally, so the runtime scope-stack order within an ordinary signed word is the active invocation followed by its root control entry and any subsequently nested control entries.

---

## 13. Reading a signature local

`word_signature_local` receives the local node being executed.

Decode its owner and slot, then scan the existing scope stack from newest entry to oldest until finding an untagged active invocation whose node is that owner.

This nearest-owner rule makes recursive invocations resolve their own inputs.

Let the owner have `N` inputs, the local have slot `i`, and the located invocation have stack mark `F`.

If `i >= N`, the local is a declared output and has no body-time value. Reading it fails as uninitialized.

For an input:

```text
backing_address(i) = F - 8 * (N - 1 - i)
```

For slots below the highest input, that backing address already contains the value.

For the highest input, where `i == N-1`:

* if the owner's current temporary count is zero, its value is the current `r13`;
* if the temporary count is nonzero, its value has been materialized at address `F`.

Push the retrieved value using the ordinary cached-TOS push convention.

No signature value is copied into a separate local store.

---

## 14. Temporary-floor enforcement

The stack mark is the invocation's lower bound for anonymous stack consumption.

For an operation requiring `K_required` input temporaries, calculate the current temporary count and require:

```text
current temporary count >= K_required
```

Perform the check before changing `r15`.

Audit every primitive that reads or consumes anonymous data-stack values. This includes stack rearrangement, arithmetic, comparison, memory access, output/printing, branch-condition consumption, and compile-time primitives that consume the language stack.

A primitive that only pushes a value needs no floor check.

Raw `!` retains its current memory-store meaning; only its operand-count protection changes.

Native machine code emitted by `asm` remains a trusted low-level boundary because arbitrary native instructions can manipulate dedicated registers directly.

---

## 15. Signed return

At `internal_signed_return`, the root control entry has already been removed.

First require the newest scope-stack node entry to be an untagged active invocation for the current `rbp`. This is the signed scope-exit validation and applies even when there are no outputs.

Let:

```text
N = input_count
M = output_count
F = invocation stack_mark
K = (r15 - F) / 8
C = F - 8*N
```

`C` is the caller's data-stack cursor before the call's input values were supplied.

Reject `r15 < F`.

If `M > 0`, require `K >= M`.

The selected output temporaries are the last `M` of the `K` temporaries. Any earlier temporary is discarded.

For source position `s`:

```text
temporary_index = K - M + s
```

If `temporary_index == K-1`, the selected value is `r13`.

Otherwise its materialized address is:

```text
F + 8 * (temporary_index + 1)
```

Stage all selected values before modifying their original stack region. An eight-qword scratch area on the native machine stack is sufficient and does not create another Hitherto stack.

For each signature output index `j`, read source position:

```text
s = return_map[j]
```

and obtain that staged value.

Reconstruct the caller-visible stack in signature order.

For `M > 0`:

```text
final r15 = C + 8*M
```

For each signature output `j` from `0` through `M-2`, store its value at:

```text
C + 8*(j+1)
```

Set `r13` to signature output `M-1`.

For `M == 0`, set `r15 = C`.

If this removal exposes a pre-existing caller value, restore that caller value to `r13` from the backing stack when it had been materialized by argument or temporary activity. If the call had no inputs, produced no temporaries, and returns no outputs, the stack has not changed and `r13` is left unchanged. If the resulting logical stack is empty, `r13` has no language-level value and need not be initialized to a sentinel.

Finally pop the active invocation entry.

---

## 16. Control-flow interaction

Existing `~]` semantics do not change.

`word_break` pops the innermost runtime control frame and jumps to that frame's patched end offset.

For a nested anonymous control region, this continues execution after that region.

For the definition's root control region, section 8 places its patched end at `internal_signed_return`. A root-level `~]` therefore performs a normal signed return using that definition's single compiled return map.

Consequently, every runtime path reaching the definition's signed-return instruction must leave its final `M` temporary values in the source output order declared by the definition's terminal epilogue.

---

## 17. Implementation sequence

1. Introduce node-bearing scope-entry encode/decode helpers and migrate the existing `SCOPE_PARENT_TAG`, `SCOPE_CONTEXT_TAG`, and `SCOPE_COMPILE_TAG` users.
2. Make runtime control operations distinguish bit-63-clear control data from node-bearing entries.
3. Add the 48-byte definition signature metadata layout and change `word_exec` to use explicit `code_start` and `code_end`.
4. Add signature parsing and signature-local child creation for global and nested definitions.
5. Add active invocation entries and call-input validation.
6. Implement `word_signature_local`.
7. Add temporary-floor checks to every consuming primitive.
8. Implement zero-output signed return and verify stack restoration across empty and non-empty callers.
9. Add body `--` parsing, output permutation validation, and return-map generation.
10. Add multi-output staging, permutation, and caller-stack reconstruction.
11. Integrate root-control closing so normal fall-through and root-level `~]` both reach `internal_signed_return`.
12. Run the complete existing regression set after each representation-level change rather than waiting for the full signature implementation.

---

## 18. Acceptance cases

The implementation must establish the following behavior.

### Identity

```forth
[ :identity ( :x -- :y )
    x
    -- y
]
```

One input is consumed and one output returned.

### Permuted outputs

```forth
[ :test ( :a :b -- :c :d )
    a b +
    ^
    2 *
    --
    d c
]
```

The deeper of the final two temporaries is bound to `d`; the TOS temporary is bound to `c`. The caller receives `c` followed by `d`.

### Disposable temporaries

```forth
[ :select ( -- :x )
    10
    20
    30
    -- x
]
```

`30` is returned as `x`; `10` and `20` are reclaimed with the invocation.

### No outputs

```forth
[ :discard ( :x -- )
    10
    20
]
```

The input and both temporaries are removed when the definition closes.

### Required failures

Compilation must reject malformed signatures, more than eight signature entries, unresolved declared types, missing required output epilogues, duplicate/missing/non-output names in an epilogue, and an epilogue attempted inside an unclosed nested control region.

Runtime must reject insufficient call inputs, temporary consumption below the active stack mark, reading a declared output from the body, insufficient temporary values at a nonzero-output return, and a signed return whose active invocation does not match the current definition.

Recursion must resolve the nearest invocation's input locals.

Lexically nested definitions must continue resolving enclosing locals through the existing parent rules.

Receiver-context dispatch, type-chain lookup, compile-target execution, anonymous controls, native execution, `lit`, `@`, and `!` must retain their existing meanings.

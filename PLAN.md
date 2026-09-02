
# Hitherto Signed Locals and Signatures — Consolidated Implementation Plan

## 1. Goal and phase boundary

This phase adds compact runtime contracts for signed `word_exec` definitions while keeping runtime values as raw qwords.

The kernel validates only:

- enough input values exist when a signed word is invoked;
- signature locals are initialized before read;
- every declared output is initialized before return;
- invocation-frame bounds are sane at entry and exit;
- outputs are returned in declared signature order.

The kernel does **not** coerce, tag, infer, widen, or narrow runtime values according to declared types. Declared types remain metadata for a future Hitherto-written compiler using a separate compile-time type stack.

`~[` repeats the current control scope inside the **same invocation frame**. It is not recursive invocation. Same-name self-reference while defining a word remains unsupported. Calling an older shadowed definition is an ordinary invocation of that older node and receives its own frame.

Current register roles remain unchanged:

```text
rbp = current definition
rbx = scope-stack cursor
r12 = threaded instruction pointer / compile cursor
r13 = cached TOS
r14 = dictionary tail
r15 = data-stack cursor
```

---

## 2. Language and signature semantics

Example:

```forth
[ :word ( u8:i u16:j -- u32:x i )
    ...
]
```

A declaration creates a local:

```text
:name
type:name
```

A bare output name reuses an input local:

```forth
( u32:i -- i )
```

Each unique signature local owns one dense runtime slot `0..7`. The same local may appear at most once on each side of the signature. Inputs plus outputs are limited to eight signature positions, and at most eight unique locals may exist.

Assignment:

```forth
value to local
```

`to` consumes TOS, writes the target slot, and marks it valid. Reading an invalid local fails.

Inputs begin valid. Output-only locals begin invalid. Passthrough locals begin valid because they are inputs.

At word exit:

1. every output position must reference a valid local;
2. anonymous body temporaries are discarded;
3. the local frame is reclaimed;
4. outputs are pushed to the caller in signature order.

---

## 3. `word_exec` payload ABI

There is no legacy execution format. **Every node with `NODE_CODE == word_exec` begins its payload with one execution/signature qword.**

```text
bits  0..3    input_count
bits  4..7    output_count
bits  8..11   local_count
bits 12..35   eight 3-bit signature references
bits 36..49   executable-start offset in qwords from NODE_BODY
bits 50..63   reserved
```

For signature position `p`:

```text
slot = (header >> (12 + 3*p)) & 7
```

References remain in complete signature order:

```text
refs[0 .. input_count-1]                         inputs
refs[input_count .. input_count+output_count-1] outputs
```

Input locals are allocated first and densely, so initial invocation validity is derived:

```text
valid_mask = (1 << input_count) - 1
```

No persistent input/output masks are needed. `local_count` remains explicit so frame size is cheap to recover.

Example:

```forth
( :a :b -- b :x a )
```

```text
slot 0 = a
slot 1 = b
slot 2 = x

input_count  = 2
output_count = 3
local_count  = 3

refs:
    0 -> 0   input a
    1 -> 1   input b
    2 -> 1   output b
    3 -> 2   output x
    4 -> 0   output a
```

Executable layouts:

```text
bracket definition payload:
    execution/signature qword
    signature-local child nodes
    threaded code

constructor-created executable payload:
    execution/signature qword
    constructor-emitted threaded code
```

All creation paths assigning `NODE_CODE = word_exec` must reserve and initialize the header before executable code is emitted. Constructor-created executable declarations initially use zero input/output/local counts unless their syntax later gains signatures.

---

## 4. Signature-local nodes, parsing, and lookup

### Local node representation

Every unique signature local is an ordinary child node of its definition:

```text
NODE_CODE = word_signature_local
NODE_TYPE = declared type node or 0
payload   = owner pointer | slot
```

Dictionary nodes are 8-byte aligned, so the low three owner-pointer bits hold slot `0..7`.

Use a dedicated signature-local creation helper:

1. allocate with `node_add` against the parent's local-tail;
2. assign `NODE_TYPE`;
3. write packed owner/slot payload;
4. finalize immediately;
5. publish to the parent's local-tail;
6. advance the parent's physical compile cursor.

Do not use `compile_child_declaration`; signature locals are metadata nodes before executable threaded code and require no `internal_skip`.

### Signature parser

For top-level and nested bracket definitions:

```text
create definition node
r12 = node_payload
reserve execution/signature qword
parse signature and create locals
encode executable-start offset
compile_ctrl_open
```

Reuse existing declaration parsing and type resolution.

Input rules:

- every input is a declaration;
- reject duplicate input names;
- allocate slots densely in input order;
- append each slot to the next signature-reference position.

Output rules:

- a declaration creates a new local and next dense slot;
- a bare output name may reuse only one of this definition's own signature locals;
- reject a repeated output occurrence of the same slot;
- append each output slot to the next signature-reference position.

Temporary parser masks may be used for duplicate detection but are not stored in the header.

Reject when:

```text
input_count + output_count > 8
local_count > 8
```

Encode:

```text
code_start_qword = (r12 - (rbp + NODE_BODY)) >> 3
```

### Lookup precedence

Signature locals are lexical storage and must win before receiver/virtual behavior.

`find_scope` rules:

1. search the current definition's local dictionary;
2. if a signature local matches, return it immediately as lexical/static;
3. otherwise preserve current static/member behavior;
4. while searching lexical parents, a signature-local match is also lexical/static;
5. never turn a signature local into receiver-context dispatch.

A receiver member with the same name cannot override a signature local.

---

## 5. Active invocation scope frame

Do **not** migrate existing `scope_stack` formats.

Existing entries remain unchanged:

- runtime control frames;
- compiler descriptor/patch addresses;
- `SCOPE_PARENT_TAG` node pointers;
- `SCOPE_CONTEXT_TAG` node pointers;
- `SCOPE_COMPILE_TAG` node pointers.

Add one packed active-invocation entry:

```text
bit 63        active-invocation marker
bits 0..2     000
bits 3..16    owner dictionary qword index
bits 17..30   local_base data-stack qword index
bits 31..38   valid_mask
bits 39..62   reserved
```

Encode:

```text
owner_index = (owner - dict) >> 3
base_index  = (local_base - data_stack) >> 3
```

Decode:

```text
owner      = dict + owner_index*8
local_base = data_stack + base_index*8
```

An invocation is itself an active scope, so it lives on `scope_stack`; no separate BSS active-frame pointer is used. Existing low-bit tag consumers ignore it because its low three bits are zero. New invocation helpers explicitly test bit 63.

Add:

```text
scope_active_invocation
    nearest bit63-marked active invocation

scope_invocation_for_owner
    nearest active invocation matching an owner node
```

The owner lookup supports dynamic-extent lexical access to an enclosing definition's locals. It is not closure capture; locals cease to exist when the owner invocation returns.

`~[` creates no new invocation and therefore keeps the same local frame and valid mask.

---

## 6. Invocation entry

The data stack uses cached TOS: pushes store old `r13` at `[r15]`, advance `r15`, then replace `r13`.

Let:

```text
N = input_count
L = local_count
F = r15 before frame construction
```

Determine the caller's anonymous-body floor:

- inside a signed word: caller invocation's `temporary_floor`;
- at top level: `data_stack`.

Require at least `N` caller body values.

Compute:

```text
caller_cursor   = F - 8*N
local_base      = caller_cursor + 8
temporary_floor = local_base + 8*L
```

Before writing frame storage:

```text
require enough caller body values for N
require temporary_floor <= data_stack_end
```

Then materialize cached TOS and establish the frame:

```text
[F] = r13
r15 = temporary_floor
valid_mask = (1 << N) - 1
```

Push the packed active-invocation scope entry.

Only `local_base` is stored. Recover when needed:

```text
caller_cursor   = local_base - 8
temporary_floor = local_base + 8*local_count
```

Ordinary arithmetic, stack, memory, and branch primitives gain no per-instruction local-floor checks in this phase.

---

## 7. Local runtime operations

### Read: `word_signature_local`

Decode owner and slot from the local node, then find the active invocation for that owner.

Require:

```text
valid_mask & (1 << slot)
```

Then push:

```text
[local_base + slot*8]
```

using the normal cached-TOS convention.

The same operation covers input locals, assigned outputs, mutated inputs, and active enclosing lexical locals. Values remain raw qwords.

### Write: `to`

Add:

```text
token_to = "to"
internal_local_set
word_to
```

Register `to` as immediate.

Compile-time `word_to`:

1. require definition state;
2. read the following token;
3. resolve through lexical/local-aware scope lookup;
4. require a signature-local target;
5. emit `internal_local_set` plus the exact resolved local node.

There is no contextual/virtual local-set form.

Runtime local-set:

1. decode target owner and slot;
2. find the owner's active invocation;
3. write TOS to the slot;
4. set the slot bit in that packed invocation's `valid_mask`;
5. consume TOS using existing stack mechanics.

A cheap TOS/floor consumption check may be added here, but full stack safety remains deferred.

---

## 8. `word_exec` execution and return

### Execution boundary

Preserve the current compile-target handling around `SCOPE_COMPILE_TAG`, `NODE_END`, and compile-time restoration.

Refactor the dispatch loop so its authoritative execution end is directly:

```text
[rbp + NODE_END]
```

rather than the root control descriptor.

After compile-target setup:

1. set `rbp` to the invoked definition;
2. load `node_payload` and execution/signature header;
3. establish the active invocation frame;
4. decode `code_start_qword`;
5. set:

```text
r12 = rbp + NODE_BODY + code_start_qword*8
```

6. dispatch until `r12 == [rbp + NODE_END]`.

### Common return epilogue

Do **not** add `internal_signed_return` or `word_signed_return`.

Existing root close continues to emit `internal_ctrl_pop` only.

Normal root fall-through:

```text
internal_ctrl_pop
r12 reaches NODE_END
word_exec epilogue
```

Root `~]`:

```text
word_break pops root control
r12 = root control end = NODE_END
word_exec epilogue
```

Nested `~]` still exits only its nested control region and continues the same invocation.

At the common epilogue:

1. require the newest active invocation to belong to `rbp`;
2. recover `local_base`, `valid_mask`, and `local_count`;
3. compute:

```text
temporary_floor = local_base + 8*local_count
```

4. require:

```text
r15 >= temporary_floor
```

   This is an exit-state sanity check only; it does not prove execution never temporarily underflowed into the frame.
5. iterate output signature positions in declared order;
6. for each output slot, require its valid bit and stage its raw qword on the native stack;
7. compute:

```text
caller_cursor = local_base - 8
```

8. reclaim temporaries and locals:

```text
r15 = caller_cursor
```

9. restore the cached caller TOS from the saved cursor cell;
10. push staged outputs left-to-right using ordinary data-stack push mechanics;
11. pop the active-invocation scope entry;
12. continue the existing compile-target/register restoration path.

`node_finalize` remains responsible for writing the physical end to `NODE_END`.

---

## 9. Type boundary and future phase

Runtime qwords carry no dynamic language type.

For example:

```forth
u32-local 2 *
```

executes only on raw qwords. The runtime does not coerce or label the result `u32`.

A later Hitherto-written compiler will maintain a separate compile-time type stack and will be responsible for:

- propagating types through expressions and stack operations;
- checking call-site input/output compatibility;
- recursively resolving word signatures/types;
- evaluating and merging branch paths;
- proving stack-depth and local-frame effects across control flow;
- moving signature/compiler policy out of the assembly bootstrap where practical.

The intended permanent kernel ABI remains small:

- compact execution/signature metadata;
- invocation-frame construction and reclamation;
- lexical local get/set;
- validity tracking;
- threaded execution primitives.

---

## 10. Implementation sequence

### Step 1 — Baseline execution refactor - DONE

X fix unrelated assembler/test-harness blockers;
X make `word_exec` use `NODE_END` directly as its execution boundary;
X preserve current `~[` / `~]` behavior;
X regression-test controls, constructors, immediate execution, member dispatch, `lit`, and `asm`;
X document or name the native-stack layout used by `word_exec` rather than adding more ad-hoc offsets.

### Step 2 — New `word_exec` payload ABI

X reserve the header qword for every `word_exec` node;
X transition bracket definitions and constructor-created executable nodes directly;
X add counts, ordered 3-bit refs, and executable-start qword offset.

### Step 3 — Signature locals and parser

X create signature-local child nodes;
X allocate dense slots;
X enforce duplicate/position limits;
X make local resolution lexical before receiver/member behavior.

### Step 4 — Active invocation scope entry

X add bit63-marked packed invocation entries without changing existing scope encodings;
X add encode/decode and owner-lookup helpers;
X construct invocation frames using `caller_cursor`, `local_base`, and `temporary_floor`.

### Step 5 — Local reads

- implement `word_signature_local`;
- enforce initialized-before-read;
- support active enclosing lexical locals;
- verify `~[` retains frame and validity state.

### Step 6 — `to`

- add immediate lexical target resolution;
- emit exact local target;
- implement runtime write and valid-mask update.

### Step 7 — Common `word_exec` epilogue

- validate active invocation owner;
- check exit floor;
- validate/stage outputs;
- reclaim frame and temporaries;
- restore caller stack state;
- push outputs in signature order;
- pop invocation scope entry;
- retain existing compile-target/register restoration.

### Step 8 — Optional cleanup after feature stability

- consolidate duplicated scope/context backward scans;
- consolidate repeated context push/pop sequences;
- keep these cleanups off the feature's critical path.

---

## 11. Regression and contract tests

Required semantic cases:

```forth
[ :identity ( u32:i -- i ) ]

[ :reverse ( :a :b -- b a ) ]

[ :new-output ( :a :b -- :x a )
    a b + to x
]

[ :mutate ( :i -- i )
    i 2 * to i
]

[ :input-mutation ( :i -- )
    10 to i
    i .
]
```

Also verify:

- zero-input and zero-output definitions;
- multi-input frames;
- output-only read before assignment fails;
- output-only local left invalid at return fails;
- assigned output can be read again;
- extra temporaries are reclaimed;
- exit with `r15 < temporary_floor` fails;
- root `~]` reaches the common `word_exec` epilogue;
- nested `~]` does not return the word;
- `~[` repeats in the same invocation/local frame;
- enclosing lexical locals resolve to their active owner frame;
- receiver/member dispatch cannot override signature locals;
- eight signature positions work;
- eight unique locals work where representable;
- constructor-created `word_exec` nodes use the new header;
- existing `lit`, `asm`, constructors, member dispatch, branches, `@`, and `!` retain behavior;
- calling an older shadowed word creates a distinct ordinary invocation;
- same-name self-reference during definition remains unsupported.

Full stack/control-flow/type proof is intentionally deferred to future compile-time tracing.

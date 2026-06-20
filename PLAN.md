# GPU-Centric Vulkan/SPIR-V Compiler Runtime — Actionable Implementation List

## Goal

Build a tiny Vulkan/SPIR-V runtime where:

```text
host sets up Vulkan
GPU runs bootstrap kernels
GPU compiles uploaded program into simple IR
GPU executes that IR
```

Do **not** try to generate new Vulkan pipelines on GPU.

---

## Phase 0 — Hard constraints

Accept these rules up front:

1. GPU cannot call Vulkan (directly).
4. GPU can only read/write buffers the host already bound.
5. GPU “compiled code” must be data consumed by an existing executor kernel.
6. Real SPIR-V pipeline generation must be host-assisted later.

---

## Phase 1 — Minimal host shell

Implement only this:

1. Pick Vulkan device.
2. Create compute queue.
3. Create storage buffers.
4. Load fixed SPIR-V kernels.
5. Bind buffers.
6. Dispatch kernels.
7. Read back result buffer.
8. Read back error buffer.

No compiler logic on host.

Required buffers:

```text
program_input
runtime_state
arena
work_queue
ir_buffer
result_buffer
error_buffer
```

First test:

```text
GPU writes "hello/status code" into result_buffer.
Host reads it.
```

Done when:

```text
one compute shader can read/write all buffers
host can dispatch it repeatedly
errors are visible
```

---

## Phase 2 — GPU memory arena

Build a stupid allocator first.

Required fields:

```text
arena_base
arena_size
arena_bump_offset
arena_error
```

Operations:

```text
alloc(size, align) -> offset
reset_arena()
```

Rules:

1. Bump-only.
2. No free.
3. Atomic bump pointer.
4. Return invalid offset on overflow.
5. Write overflow to error buffer.

First test:

```text
many GPU invocations allocate fixed-size blocks
host verifies no overlaps
```

Done when:

```text
GPU can allocate temporary memory safely
```

---

## Phase 3 — Runtime error system

Do this early.

Error record:

```text
error_code
kernel_id
workgroup_id
invocation_id
arg0
arg1
arg2
```

Minimum error codes:

```text
0 = OK
1 = arena overflow
2 = queue overflow
3 = invalid opcode
4 = invalid buffer range
5 = compiler failed
6 = executor failed
```

Rules:

1. First error wins.
2. Store enough data to debug.
3. Never silently fail.

Done when:

```text
bad input produces readable error records
```

---

## Phase 4 — Work queue

Implement a fixed-size GPU queue.

Record:

```text
task_type
task_state
input_offset
output_offset
arg0
arg1
arg2
arg3
```

Task states:

```text
empty
ready
running
done
failed
```

Operations:

```text
push_task()
claim_task()
finish_task()
fail_task()
```

First task types:

```text
COMPILE_PROGRAM
EXECUTE_IR
```

Done when:

```text
one kernel can push tasks
another kernel can consume them
```

---

## Phase 5 — Define tiny IR v0

Do not start with a “language.”

Start with a tiny binary IR.

Header:

```text
magic
version
instruction_count
constant_count
buffer_count
entry_offset
```

Instruction format:

```text
opcode
dst
src0
src1
imm0
imm1
```

Initial opcodes:

```text
NOP
CONST_U32
ADD_U32
MUL_U32
LOAD_U32
STORE_U32
RANGE_FOR
END
```

Rules:

1. Fixed-size instructions.
2. No strings.
3. No recursion.
4. No dynamic types.
5. No pointers except buffer offsets.
6. All memory access must be bounds checked.

First program:

```text
for i in 0..N:
    C[i] = A[i] + B[i]
```

Done when:

```text
GPU executor can run the IR and produce correct C
```

---

## Phase 6 — IR executor kernel

Implement one executor kernel that reads `ir_buffer`.

Inputs:

```text
runtime_state
ir_buffer
arena
program buffers
result_buffer
error_buffer
```

Execution model v0:

```text
one invocation = one element
```

For `C[i] = A[i] + B[i]`:

```text
global_id = invocation id
execute IR for that element
```

Do not build a general VM yet.

Start with:

```text
fixed register file per invocation
linear instruction scan
bounds checks
opcode switch
```

Done when:

```text
host uploads IR directly
GPU executes it
host verifies output
```

---

## Phase 7 — GPU compiler v0

Now add compiler.

Input format should be simpler than source code.

Use a binary “source” format first:

```text
program_kind = MAP_ADD_U32
input_a
input_b
output_c
count
```

Compiler output:

```text
tiny IR v0
```

First compiler only needs to emit:

```text
C[i] = A[i] + B[i]
```

Done when:

```text
host uploads source-like binary program
GPU compiler emits IR
GPU executor runs IR
host verifies output
```

---

## Phase 8 — Add slightly useful ops

Add only after v0 works.

Useful next opcodes:

```text
SUB_U32
DIV_U32
AND_U32
OR_U32
XOR_U32
SHL_U32
SHR_U32
LT_U32
EQ_U32
SELECT
```

Then float:

```text
CONST_F32
ADD_F32
MUL_F32
FMA_F32
LOAD_F32
STORE_F32
```

Then reductions:

```text
LOCAL_REDUCE_ADD
GLOBAL_ATOMIC_ADD
```

Do not add function calls yet.

---

## Phase 9 — Coarse ops, not scalar VM forever

Scalar bytecode will be slow. Add coarse instructions early.

Examples:

```text
MAP_U32
MAP_F32
FUSED_MAP_F32
REDUCE_ADD_F32
SCAN_U32
FILL
COPY
```

These should represent whole parallel operations, not one scalar instruction.

Goal:

```text
one IR instruction = lots of GPU work
```

Done when:

```text
executor can run coarse tasks faster than scalar VM path
```

---

## Phase 10 — Self-hosting path

Once compiler v0 works, move more logic into the GPU language.

Stages:

1. Handwritten SPIR-V compiler kernel emits IR.
2. IR executor runs small programs.
3. Write compiler pieces in your own IR/program format.
4. Bootstrap compiler compiles those pieces.
5. New compiler compiles future programs.

Minimal self-hosting target:

```text
compiler can compile a newer version of its own MAP_ADD emitter
```

Do not aim for full language self-hosting first.

---

## Phase 11 — Optional host-assisted SPIR-V path

Only after the IR system works.

Flow:

```text
GPU compiler emits SPIR-V bytes into buffer
host reads/uses bytes
host calls vkCreateShaderModule
host creates pipeline
host dispatches optimized kernel
```

This is an optimization tier, not the core runtime.

Done when:

```text
same program can run through:
1. IR executor
2. host-assisted generated SPIR-V
```

---

## Build order

Implement in this exact order:

```text
1. Vulkan host shell
2. fixed buffers
3. hello compute kernel
4. error buffer
5. arena allocator
6. queue
7. hand-authored IR
8. IR executor
9. binary program input
10. GPU compiler to IR
11. coarse IR ops
12. self-hosting compiler subset
13. optional SPIR-V generation
```

---

## First milestone

The first serious milestone is:

```text
host uploads:
    A buffer
    B buffer
    binary program saying "add A and B into C"

GPU:
    compiles program into IR
    executes IR
    writes C

host:
    verifies C
```

That proves the whole idea without excess machinery.

# PLAN.md — Tiny x86 Assembly Vulkan Host + Device-Generated SPIR-V Runtime

## Project intent

Current state:

- Host is handwritten x86-64 assembly, assembled with `llvm-mc` and linked with `lld`.
- Host links against `libvulkan`.
- Host can print to stdout/stderr and use `mmap`.
- Host creates a Vulkan instance, enumerates physical devices, reads physical-device properties, and selects a preferred compute device.
- The host binary should stay tiny. Treat the current ~18K size as a design constraint, not an accident.

Target architecture:

```text
x86 assembly host = tiny privileged Vulkan microkernel
GPU/device       = compiler, planner, SPIR-V emitter, runtime brain
hostcalls        = explicit missing-Vulkan capability requests
```

The host should only do things the device cannot do:

- Create/destroy Vulkan objects.
- Allocate/bind/map Vulkan memory.
- Submit command buffers.
- Materialize generated SPIR-V into shader modules and compute pipelines.
- Print/debug/exit.

The host should **not** understand the compiler source language, model graph, lowering rules, optimization plan, or LLM graph semantics.

---

## Design rules

1. **No host compiler logic.**
   The host accepts byte ranges, object descriptors, and hostcall records. It does not parse the future compiler IR.

2. **No raw Vulkan handles visible to device code.**
   Use small virtual object IDs. The host maps object IDs to real `Vk*` handles.

3. **No general allocator in the host yet.**
   Use static tables and one or two large buffers.

4. **Prefer one fixed descriptor ABI first.**
   Start with a single storage buffer bound to the seed compiler shader. Use internal offsets for `runtime_state`, hostcall ring, heaps, and errors.

5. **Debug validation can be external.**
   Do not embed SPIRV-Tools or validation code into the tiny host. In debug builds, optionally dump generated SPIR-V for external `spirv-val` / `spirv-dis`.

6. **Signal path exits directly.**
   Normal errors run cleanup. Signal handler should not re-enter Vulkan cleanup. Use raw `exit` / `exit_group`, or set a flag checked at safe points.

---

## Immediate build order

### Phase 1 — Finish logical device and queue bootstrap

Already done:

- `vkCreateInstance`
- `vkEnumeratePhysicalDevices`
- `vkGetPhysicalDeviceProperties`
- preferred physical-device selection

Next:

1. Query queue-family count.
2. Allocate queue-family-property array with `mmap`.
3. Query queue-family properties.
4. Select compute-capable queue family.
5. Create logical device with one queue.
6. Fetch `VkQueue`.
7. Add `vkDestroyDevice` to cleanup.

Minimal queue policy:

```text
prefer VK_QUEUE_COMPUTE_BIT
prefer VK_QUEUE_TRANSFER_BIT as secondary bonus
no graphics requirement
queueCount = 1
queuePriority = 1.0f
no device extensions at v0
no enabled features at v0
```

State to add:

```asm
.align 8
logical_device:      .zero 8      # VkDevice
queue:               .zero 8      # VkQueue
queue_family_count:  .zero 4
queue_family_index:  .zero 4
queue_family_props:  .zero 8      # mmap pointer
queue_family_bytes:  .zero 8
queue_priority:      .float 1.0
```

Cleanup bit additions:

```asm
.equ STATE_VKDEVICE,      4
.equ STATE_QUEUE_PROPS,   8
```

### Phase 2 — Create one runtime storage buffer

Create exactly one host-visible, host-coherent storage buffer at first.

Suggested buffer size:

```text
1 MiB minimum for v0
```

Suggested logical layout inside the buffer:

```text
0x00000 runtime_state
0x01000 hostcall_ring
0x03000 object_table
0x05000 input_heap
0x25000 output_heap
0x65000 scratch_heap
0xE5000 error_buffer
```

At v0, all offsets are constants in both host assembly and seed shader.

Vulkan calls:

1. `vkCreateBuffer`
2. `vkGetBufferMemoryRequirements`
3. `vkGetPhysicalDeviceMemoryProperties`
4. choose memory type with `HOST_VISIBLE | HOST_COHERENT`
5. `vkAllocateMemory`
6. `vkBindBufferMemory`
7. `vkMapMemory`

State to add:

```asm
runtime_buffer:       .zero 8      # VkBuffer
runtime_memory:       .zero 8      # VkDeviceMemory
runtime_mapped:       .zero 8      # void*
runtime_size:         .quad 1048576
memory_type_index:    .zero 4
```

Cleanup order:

```text
vkUnmapMemory, if mapped
vkDestroyBuffer
vkFreeMemory
```

Destroy buffer before freeing its memory.

### Phase 3 — Fixed descriptor ABI

Start with one descriptor binding:

```text
set 0 binding 0: runtime storage buffer
```

This keeps the host small. Shaders use fixed offsets into that buffer.

Vulkan calls:

1. `vkCreateDescriptorSetLayout`
2. `vkCreatePipelineLayout`
3. `vkCreateDescriptorPool`
4. `vkAllocateDescriptorSets`
5. `vkUpdateDescriptorSets`

State to add:

```asm
desc_set_layout:      .zero 8
pipeline_layout:      .zero 8
desc_pool:            .zero 8
desc_set:             .zero 8
```

Descriptor layout binding v0:

```text
binding         = 0
descriptorType  = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
descriptorCount = 1
stageFlags      = VK_SHADER_STAGE_COMPUTE_BIT
pImmutableSamplers = NULL
```

### Phase 4 — Command pool and command buffer

Create one command pool and one primary command buffer.

Vulkan calls:

1. `vkCreateCommandPool`
2. `vkAllocateCommandBuffers`
3. `vkBeginCommandBuffer`
4. `vkCmdBindPipeline`
5. `vkCmdBindDescriptorSets`
6. `vkCmdDispatch`
7. `vkEndCommandBuffer`
8. `vkQueueSubmit`
9. `vkQueueWaitIdle`

At v0, use `vkQueueWaitIdle` instead of fences/semaphores. This is slower but smaller and simpler.

State to add:

```asm
command_pool:         .zero 8
command_buffer:       .zero 8
```

### Phase 5 — Static seed shader

Embed one known-good SPIR-V blob or link it as a binary object.

Seed shader v0 behavior:

```text
runtime_state.status = 0x12345678
hostcall_ring[0] = HC_STDOUT_WRITE or HC_EXIT
```

Host validates execution by:

1. Dispatch seed shader.
2. Wait idle.
3. Read `runtime_state.status` from mapped runtime buffer.
4. Process one hostcall.

### Phase 6 — Hostcall ring v0

Use in-place result fields initially. Avoid a second response ring until needed.

Hostcall record:

```c
struct HostCall {
    uint32_t op;
    uint32_t seq;
    uint32_t status;
    uint32_t flags;
    uint32_t arg0;
    uint32_t arg1;
    uint32_t arg2;
    uint32_t arg3;
    uint32_t arg4;
    uint32_t arg5;
    uint32_t result0;
    uint32_t result1;
};
```

Hostcall ring header:

```c
struct HostCallRing {
    uint32_t write_index;
    uint32_t read_index;
    uint32_t capacity;
    uint32_t _pad;
    HostCall calls[capacity];
};
```

v0 opcodes:

```text
HC_NOP                         = 0
HC_EXIT                        = 1
HC_STDOUT_WRITE                = 2
HC_VK_CREATE_SHADER_MODULE     = 100
HC_VK_CREATE_COMPUTE_PIPELINE  = 101
HC_VK_DISPATCH                 = 102
```

The hostcall dispatcher should be a simple compare chain first. A jump table can come later.

### Phase 7 — First generated SPIR-V materialization

The seed shader writes valid SPIR-V words into `output_heap`, then emits hostcalls:

```text
HC_VK_CREATE_SHADER_MODULE
HC_VK_CREATE_COMPUTE_PIPELINE
HC_VK_DISPATCH
HC_EXIT
```

For v0, hardcode:

```text
pipeline_layout_id = bootstrap pipeline layout
descriptor_set_id  = bootstrap descriptor set
entry point        = "main"
```

Generated shader v0 behavior:

```text
runtime_state.generated_result = 0xCAFEBABE
```

This is the first architectural milestone:

```text
device emits SPIR-V -> host materializes Vulkan pipeline -> generated shader runs
```

### Phase 8 — Map-add generated shader

After generated `0xCAFEBABE` works, emit a generated shader for:

```text
C[i] = A[i] + B[i]
```

Only then add multiple data buffers or a second descriptor ABI.

---

## Vulkan signatures needed next

All signatures below are from the Vulkan 1.0 reference pages. The host is x86-64 System V ABI, so the first six integer/pointer arguments are passed in:

```text
rdi, rsi, rdx, rcx, r8, r9
```

Return `VkResult` is in `eax`. Non-dispatchable handles are 64-bit values on the host ABI.

### Queue-family enumeration

```c
void vkGetPhysicalDeviceQueueFamilyProperties(
    VkPhysicalDevice             physicalDevice,
    uint32_t*                    pQueueFamilyPropertyCount,
    VkQueueFamilyProperties*     pQueueFamilyProperties);
```

Assembly call shape:

```asm
mov rdi, [rip + selected_device]
lea rsi, [rip + queue_family_count]
xor edx, edx                    # NULL first query
call vkGetPhysicalDeviceQueueFamilyProperties
```

Second call:

```asm
mov rdi, [rip + selected_device]
lea rsi, [rip + queue_family_count]
mov rdx, [rip + queue_family_props]
call vkGetPhysicalDeviceQueueFamilyProperties
```

`VkQueueFamilyProperties` v0 fields needed:

```c
typedef struct VkQueueFamilyProperties {
    VkQueueFlags    queueFlags;
    uint32_t        queueCount;
    uint32_t        timestampValidBits;
    VkExtent3D      minImageTransferGranularity;
} VkQueueFamilyProperties;
```

On LP64, this is 24 bytes in the usual Vulkan headers:

```text
offset 0: queueFlags
offset 4: queueCount
```

Select the first family where:

```text
(queueFlags & VK_QUEUE_COMPUTE_BIT) != 0
queueCount > 0
```

### Logical device creation

```c
VkResult vkCreateDevice(
    VkPhysicalDevice             physicalDevice,
    const VkDeviceCreateInfo*    pCreateInfo,
    const VkAllocationCallbacks* pAllocator,
    VkDevice*                    pDevice);
```

Minimal structs:

```c
typedef struct VkDeviceQueueCreateInfo {
    VkStructureType             sType;
    const void*                 pNext;
    VkDeviceQueueCreateFlags    flags;
    uint32_t                    queueFamilyIndex;
    uint32_t                    queueCount;
    const float*                pQueuePriorities;
} VkDeviceQueueCreateInfo;

typedef struct VkDeviceCreateInfo {
    VkStructureType                    sType;
    const void*                        pNext;
    VkDeviceCreateFlags                flags;
    uint32_t                           queueCreateInfoCount;
    const VkDeviceQueueCreateInfo*     pQueueCreateInfos;
    uint32_t                           enabledLayerCount;
    const char* const*                 ppEnabledLayerNames;
    uint32_t                           enabledExtensionCount;
    const char* const*                 ppEnabledExtensionNames;
    const VkPhysicalDeviceFeatures*    pEnabledFeatures;
} VkDeviceCreateInfo;
```

Recommended v0:

```text
queueCreateInfoCount = 1
queueCount = 1
pQueuePriorities -> .float 1.0
enabledExtensionCount = 0
pEnabledFeatures = NULL
```

Assembly call shape:

```asm
mov rdi, [rip + selected_device]
lea rsi, [rip + device_create_info]
xor edx, edx
lea rcx, [rip + logical_device]
call vkCreateDevice
```

### Get queue

```c
void vkGetDeviceQueue(
    VkDevice    device,
    uint32_t    queueFamilyIndex,
    uint32_t    queueIndex,
    VkQueue*    pQueue);
```

Assembly call shape:

```asm
mov rdi, [rip + logical_device]
mov esi, [rip + queue_family_index]
xor edx, edx                    # queueIndex = 0
lea rcx, [rip + queue]
call vkGetDeviceQueue
```

Use this only for queues created with `VkDeviceQueueCreateInfo::flags = 0`.

### Buffer creation

```c
VkResult vkCreateBuffer(
    VkDevice                        device,
    const VkBufferCreateInfo*       pCreateInfo,
    const VkAllocationCallbacks*    pAllocator,
    VkBuffer*                       pBuffer);
```

Minimal `VkBufferCreateInfo` fields:

```c
typedef struct VkBufferCreateInfo {
    VkStructureType        sType;
    const void*            pNext;
    VkBufferCreateFlags    flags;
    VkDeviceSize           size;
    VkBufferUsageFlags     usage;
    VkSharingMode          sharingMode;
    uint32_t               queueFamilyIndexCount;
    const uint32_t*        pQueueFamilyIndices;
} VkBufferCreateInfo;
```

Recommended v0:

```text
size = runtime_size
usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT
sharingMode = VK_SHARING_MODE_EXCLUSIVE
queueFamilyIndexCount = 0
pQueueFamilyIndices = NULL
```

### Buffer memory requirements

```c
void vkGetBufferMemoryRequirements(
    VkDevice                device,
    VkBuffer                buffer,
    VkMemoryRequirements*   pMemoryRequirements);
```

Minimal `VkMemoryRequirements` fields:

```c
typedef struct VkMemoryRequirements {
    VkDeviceSize    size;
    VkDeviceSize    alignment;
    uint32_t        memoryTypeBits;
} VkMemoryRequirements;
```

### Physical-device memory properties

Needed to choose memory type:

```c
void vkGetPhysicalDeviceMemoryProperties(
    VkPhysicalDevice                    physicalDevice,
    VkPhysicalDeviceMemoryProperties*   pMemoryProperties);
```

v0 selection rule:

```text
candidate = memoryTypeBits & (1 << i)
required  = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT
accept if (propertyFlags & required) == required
```

### Allocate/bind/map memory

```c
VkResult vkAllocateMemory(
    VkDevice                         device,
    const VkMemoryAllocateInfo*      pAllocateInfo,
    const VkAllocationCallbacks*     pAllocator,
    VkDeviceMemory*                  pMemory);

VkResult vkBindBufferMemory(
    VkDevice         device,
    VkBuffer         buffer,
    VkDeviceMemory   memory,
    VkDeviceSize     memoryOffset);

VkResult vkMapMemory(
    VkDevice         device,
    VkDeviceMemory   memory,
    VkDeviceSize     offset,
    VkDeviceSize     size,
    VkMemoryMapFlags flags,
    void**           ppData);
```

`vkMapMemory` has six arguments, so on System V AMD64:

```text
rdi = device
rsi = memory
rdx = offset
rcx = size
r8  = flags
r9  = ppData
```

### Descriptor set layout

```c
VkResult vkCreateDescriptorSetLayout(
    VkDevice                              device,
    const VkDescriptorSetLayoutCreateInfo* pCreateInfo,
    const VkAllocationCallbacks*          pAllocator,
    VkDescriptorSetLayout*                pSetLayout);
```

v0 uses one `VkDescriptorSetLayoutBinding`:

```c
typedef struct VkDescriptorSetLayoutBinding {
    uint32_t              binding;
    VkDescriptorType      descriptorType;
    uint32_t              descriptorCount;
    VkShaderStageFlags    stageFlags;
    const VkSampler*      pImmutableSamplers;
} VkDescriptorSetLayoutBinding;
```

### Command pool

```c
VkResult vkCreateCommandPool(
    VkDevice                         device,
    const VkCommandPoolCreateInfo*   pCreateInfo,
    const VkAllocationCallbacks*     pAllocator,
    VkCommandPool*                   pCommandPool);
```

v0:

```text
queueFamilyIndex = selected compute family
flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT optional; 0 is smaller
```

### Shader module

```c
VkResult vkCreateShaderModule(
    VkDevice                          device,
    const VkShaderModuleCreateInfo*   pCreateInfo,
    const VkAllocationCallbacks*      pAllocator,
    VkShaderModule*                   pShaderModule);
```

`VkShaderModuleCreateInfo` v0:

```c
typedef struct VkShaderModuleCreateInfo {
    VkStructureType              sType;
    const void*                  pNext;
    VkShaderModuleCreateFlags    flags;
    size_t                       codeSize;
    const uint32_t*              pCode;
} VkShaderModuleCreateInfo;
```

For generated SPIR-V from `output_heap`:

```text
codeSize = spirv_word_count * 4
pCode    = runtime_mapped + output_heap_offset + spirv_word_offset * 4
```

### Compute pipeline

```c
VkResult vkCreateComputePipelines(
    VkDevice                            device,
    VkPipelineCache                     pipelineCache,
    uint32_t                            createInfoCount,
    const VkComputePipelineCreateInfo*  pCreateInfos,
    const VkAllocationCallbacks*        pAllocator,
    VkPipeline*                         pPipelines);
```

This has six arguments:

```text
rdi = device
rsi = pipelineCache, NULL at v0
rdx = createInfoCount, 1
rcx = pCreateInfos
r8  = pAllocator, NULL
r9  = pPipelines
```

v0 uses a single `VkComputePipelineCreateInfo` with:

```text
stage.sType  = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
stage.stage  = VK_SHADER_STAGE_COMPUTE_BIT
stage.module = generated shader module
stage.pName  = "main"
layout       = bootstrap pipeline layout
basePipelineHandle = NULL
basePipelineIndex = -1
```

---

## Clean assembly implementation notes

### 1. Use static Vulkan structs in `.data` where possible

Prefer static structs with mutable fields patched before calls:

```asm
.data
.align 8
queue_create_info:
    .long VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
    .long 0                  # padding / low pNext alignment helper if hand-laid
    .quad 0                  # pNext
    .long 0                  # flags
    .long 0                  # queueFamilyIndex, patched
    .long 1                  # queueCount
    .long 0                  # padding before pointer
    .quad queue_priority
```

This avoids building structs on the stack and keeps stack alignment simple.

### 2. Keep all `sType` constants in one include-style assembly file

Create `vulkan_constants.inc`:

```asm
.equ VK_SUCCESS, 0
.equ VK_QUEUE_COMPUTE_BIT, 0x00000002
.equ VK_QUEUE_TRANSFER_BIT, 0x00000004
.equ VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, 2
.equ VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, 3
...
```

Generate this file from `vulkan_core.h` later if desired. For now, manually keep the few constants used.

### 3. Use one error convention

For every Vulkan call returning `VkResult`:

```asm
call vkWhatever
test eax, eax
je .ok
lea rdi, [rip + err_vk_whatever]
call fail
.ok:
```

Later, add `print_i32_hex_eax` before `fail` for debugging.

### 4. Use state bits for cleanup

Cleanup should destroy in strict reverse creation order:

```text
command/pipeline objects
shader modules
pipeline layout
descriptor pool
set layout
buffer
memory
logical device
instance
mmap regions
```

Suggested state bits:

```asm
.equ STATE_VKINSTANCE,        0x00000001
.equ STATE_QUEUE_PROPS,       0x00000002
.equ STATE_VKDEVICE,          0x00000004
.equ STATE_RUNTIME_BUFFER,    0x00000008
.equ STATE_RUNTIME_MEMORY,    0x00000010
.equ STATE_RUNTIME_MAPPED,    0x00000020
.equ STATE_DESC_SET_LAYOUT,   0x00000040
.equ STATE_PIPELINE_LAYOUT,   0x00000080
.equ STATE_DESC_POOL,         0x00000100
.equ STATE_COMMAND_POOL,      0x00000200
.equ STATE_SEED_MODULE,       0x00000400
.equ STATE_SEED_PIPELINE,     0x00000800
```

### 5. Avoid preserving loop counters in caller-saved registers across calls

Use either:

- memory variables for indices, or
- callee-saved registers with disciplined push/pop paths.

For tiny assembly, memory indices are often safer and not meaningfully slower during setup code.

### 6. Do not use Vulkan cleanup from a signal handler

Use:

```asm
signal_trap:
    mov edi, 130
    mov eax, 60          # SYS_exit
    syscall
```

or, for future threaded host:

```asm
signal_trap:
    mov edi, 130
    mov eax, 231         # SYS_exit_group
    syscall
```

Normal error paths should still run cleanup.

### 7. Keep generated-object hostcalls separate from bootstrap objects

Reserve object IDs:

```text
0  = null
1  = runtime buffer
2  = bootstrap descriptor set layout
3  = bootstrap pipeline layout
4  = bootstrap descriptor set
5  = seed shader module
6  = seed compiler pipeline
32+ = generated objects
```

Host object table in `.bss`:

```asm
.align 8
object_kind:        .zero 256 * 4
object_generation:  .zero 256 * 4
object_handle0:     .zero 256 * 8
object_handle1:     .zero 256 * 8
```

### 8. Use in-place hostcall results first

A separate response ring is cleaner long-term but more code. For v0, host writes back into each hostcall record:

```text
status  = VK_SUCCESS or host error
result0 = virtual object ID or numeric result
result1 = extra detail
```

### 9. Record and submit command buffers simply

At v0, record one command buffer per dispatch and wait idle:

```text
vkBeginCommandBuffer
vkCmdBindPipeline
vkCmdBindDescriptorSets
vkCmdDispatch
vkEndCommandBuffer
vkQueueSubmit
vkQueueWaitIdle
```

This is simple and deterministic. Optimize later.

---

## First generated pipeline hostcall protocol

### `HC_VK_CREATE_SHADER_MODULE`

Arguments:

```text
arg0 = byte offset in runtime buffer to SPIR-V words
arg1 = SPIR-V word count
arg2 = requested object ID or 0 for auto-allocate
```

Host:

```text
pCode = runtime_mapped + arg0
codeSize = arg1 * 4
vkCreateShaderModule(device, &create_info, NULL, &module)
store module in object table
result0 = module_id
```

### `HC_VK_CREATE_COMPUTE_PIPELINE`

Arguments:

```text
arg0 = shader_module_id
arg1 = pipeline_layout_id, 0 means bootstrap layout
arg2 = requested pipeline object ID or 0 for auto-allocate
```

Host:

```text
stage.module = object[arg0].VkShaderModule
stage.pName  = "main"
layout       = bootstrap or object[arg1].VkPipelineLayout
vkCreateComputePipelines(...)
result0 = pipeline_id
```

### `HC_VK_DISPATCH`

Arguments:

```text
arg0 = pipeline_id
arg1 = descriptor_set_id, 0 means bootstrap descriptor set
arg2 = groupCountX
arg3 = groupCountY
arg4 = groupCountZ
```

Host:

```text
record command buffer
bind compute pipeline
bind descriptor set
vkCmdDispatch(arg2, arg3, arg4)
submit
wait idle
```

---

## External documentation references

Official Vulkan reference pages used for signature and parameter details:

- `vkGetPhysicalDeviceQueueFamilyProperties`: https://docs.vulkan.org/refpages/latest/refpages/source/vkGetPhysicalDeviceQueueFamilyProperties.html
- `vkCreateDevice`: https://docs.vulkan.org/refpages/latest/refpages/source/vkCreateDevice.html
- `vkGetDeviceQueue`: https://docs.vulkan.org/refpages/latest/refpages/source/vkGetDeviceQueue.html
- `vkCreateBuffer`: https://docs.vulkan.org/refpages/latest/refpages/source/vkCreateBuffer.html
- `vkGetBufferMemoryRequirements`: https://docs.vulkan.org/refpages/latest/refpages/source/vkGetBufferMemoryRequirements.html
- `vkCreateDescriptorSetLayout`: https://docs.vulkan.org/refpages/latest/refpages/source/vkCreateDescriptorSetLayout.html
- `vkCreateCommandPool`: https://docs.vulkan.org/refpages/latest/refpages/source/vkCreateCommandPool.html
- `vkCreateShaderModule`: https://docs.vulkan.org/refpages/latest/refpages/source/vkCreateShaderModule.html

Use `vulkan_core.h` from the Vulkan SDK as the final authority for constants and exact struct layout on the target platform.

---

## Milestone checklist

### Milestone A — Device and queue

- [ ] Query queue-family count.
- [ ] Allocate queue-family properties.
- [ ] Select compute-capable queue family.
- [ ] Create logical device.
- [ ] Fetch queue.
- [ ] Destroy logical device in cleanup.

### Milestone B — Runtime buffer

- [ ] Create one storage buffer.
- [ ] Query memory requirements.
- [ ] Select host-visible coherent memory type.
- [ ] Allocate/bind/map memory.
- [ ] Write/read status words from mapped memory.

### Milestone C — Static seed shader

- [ ] Create descriptor set layout.
- [ ] Create pipeline layout.
- [ ] Create descriptor pool/set.
- [ ] Update descriptor set with runtime buffer.
- [ ] Create command pool/buffer.
- [ ] Create shader module from static SPIR-V.
- [ ] Create compute pipeline.
- [ ] Dispatch seed shader.
- [ ] Read `runtime_state.status`.

### Milestone D — Hostcall ring

- [ ] Seed shader emits `HC_STDOUT_WRITE`.
- [ ] Host processes hostcall ring.
- [ ] Seed shader emits `HC_EXIT`.
- [ ] Host exits with requested status.

### Milestone E — Device-generated SPIR-V

- [ ] Seed shader writes valid SPIR-V module into `output_heap`.
- [ ] Seed shader emits `HC_VK_CREATE_SHADER_MODULE`.
- [ ] Host creates generated shader module.
- [ ] Seed shader emits `HC_VK_CREATE_COMPUTE_PIPELINE`.
- [ ] Host creates generated compute pipeline.
- [ ] Seed shader emits `HC_VK_DISPATCH`.
- [ ] Host dispatches generated pipeline.
- [ ] Generated pipeline writes `0xCAFEBABE`.

### Milestone F — First useful generated kernel

- [ ] Device emits map-add SPIR-V.
- [ ] Host materializes generated pipeline.
- [ ] Generated kernel computes `C[i] = A[i] + B[i]`.
- [ ] Host verifies output.



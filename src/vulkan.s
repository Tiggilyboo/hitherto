.include "./src/macros.inc"
.intel_syntax noprefix

.equ STATE_DEVICE_MAP,     1
.equ STATE_VKINSTANCE,     2
.equ STATE_QUEUE_PROPS,    4
.equ STATE_VKDEVICE,       8
.equ STATE_RUNTIME_BUFFER, 16
.equ STATE_RUNTIME_MEMORY, 32
.equ STATE_RUNTIME_MAPPED, 64



.section .rodata

app_name:
  .asciz "hitherto"
newline:
  .asciz "\n"
space:
  .asciz " "
msg_devices:
  .asciz "Selected device(s): "
msg_bootstrapped:
  .asciz "Strapped some boots\n"
msg_queue_family:
  .asciz "Selected Queue Family: "
msg_compute:
  .asciz "Compute "
msg_transfer:
  .asciz "Transfer "
msg_graphics:
  .asciz "Graphics "
msg_queue_family_index:
  .asciz "Index "

err_vk_instance:
  .asciz "vkCreateInstance failed\n"
err_vk_enum:
  .asciz "vkEnumeratePhysicalDevices failed\n"
err_mmap:
  .asciz "mmap failed\n"
err_no_devices:
  .asciz "vkEnumeratePhysicalDevices returned 0 devices\n"
err_no_queue:
  .asciz "vkGetDeviceQueue returned null queue pointer\n"
err_sig:
  .asciz "rt_sigaction failed"
err_no_queue_family:
  .asciz "No Vulkan physical device queue family with compute capabilities found.\n"
err_create_buffer:
  .asciz "vkCreateBuffer failed\n"
err_buffer_memory_requirements:
  .asciz "vkGetBufferMemoryRequirements returned 0 size or no supported memory types\n"
err_no_memory_type_found:
  .asciz "No valid buffer memory type found with HOST_VISIBLE | HOST_CORHERENT flags\n"

.section .bss

.align 4
alloc_state:
  .zero 4

# VkInstance handle, pointer sized
.align 8
instance:
  .zero 8
device_count:
  .zero 4

# VkPhysicalDevice* allocated with mmap
.align 8
physical_device:
  .zero 8
.align 8
devices_bytes:
  .zero 8
.align 8

# VkPhysicalDeviceProperties*
device_properties:
  .zero 552 # max 8
.align 8
selected_device:
  .zero 8
.align 4
selected_device_type:
  .zero 4

.align 4
queue_family_count:
  .zero 4

.align 8
# VkQueueFamilyProperties* allocated with mmap
queue_family_properties:
  .zero 384 # max 16

.align 8
queue_family_bytes:
  .zero 8

.align 4
queue_family_index:
  .zero 4

.align 8
logical_device:
  .zero 8
queue:
  .zero 8

runtime_buffer:
  .zero 8
runtime_memory:
  .zero 8
runtime_mapped:
  .zero 8 
runtime_memory_type_index:
  .zero 4
runtime_memory_requirements:
  .zero 8 # size
  .zero 8 # alignment
  .zero 4 # memoryTypeBits
runtime_memory_properties:
  .zero 4   # memoryTypeCount
  .zero 256 # memoryTypes[32] : propertyFlags + heapIndex = 8 bytes
  .zero 4   # heapCount
  .zero 4   # pad
  .zero 256 # memoryHeaps[16] : flags + size(8) + size(8) = 24 bytes

.section .data
app_info:
  .long 0          # sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
  .long 0          # padding
  .quad 0          # pNext = NULL
  .quad app_name   # pApplicationName
  .long 1          # applicationVersion
  .long 0          # padding
  .quad app_name   # pEngineName
  .long 1          # engineVersion
  .long 0x00400000 # api version = VK_API_VERSION_1_0

instance_create_info:
  .long 1                      # sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
  .long 0                      # padding before pNext
  .quad 0                      # pNext = NULL
  .long 0                      # flags = 0
  .long 0                      # padding before pApplicationInfo
  .quad app_info               # pApplicationInfo = &app_info
  .long 0                      # enabledLayerCount = 0
  .long 0                      # padding before ppEnabledLayerNames
  .quad 0                      # ppEnabledLayerNames = NULL
  .long 0                      # enabledExtensionCount = 0
  .long 0                      # padding before ppEnabledExtensionNames
  .quad 0                      # ppEnabledExtensionNames = NULL

# VkDeviceQueueCreateInfo (40 bytes)
queue_priority:
  .float 1.0
device_queue_create_info:
  .long 2  # sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
  .long 0  # padding before pNext
  .quad 0  # pNext = NULL
  .long 0  # flags = 0
  .long 0  # queueFamilyIndex
  .long 1  # queueCount = 1
  .quad queue_priority  # queuePriority

# VkDeviceCreateInfo (72 bytes)
device_create_info:
  .long 3  # sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
  .long 0  # padding before pNext
  .quad 0  # pNext = 0
  .long 0  # flags = 0
  .long 1  # queueCreateInfoCount
  .quad device_queue_create_info
  .long 0  # enabledLayerCount
  .long 0  # pad
  .quad 0  # ppEnabledLayerNames
  .long 0  # enabledExtensionCount
  .long 0  # pad
  .quad 0  # ppEnabledExtensionNames
  .quad 0  # pEnabledFeatures

# VkBufferCreateInfo (48 bytes)
.align 8
buffer_create_info:
  .long 12  # sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
  .long 0   # pad
  .quad 0   # pNext*
  .quad 0   # flags
  .quad 1048576   # size = 1MB
  .long 0x23 # usage = STORAGE(0x20) | TRANSFER_SRC(0x01) | TRANSFER_DST (0x02)
  .long 0 # sharingMode = VK_SHARING_EXCLUSIVE
  .long 0 # queueFamilyIndexCount = 0
  .quad 0 # qQueueFamilyINdices = NULL

# VkMemoryAllocateInfo (32 bytes)
.align 8
memory_allocate_info:
  .long 5 # sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
  .long 0 # pad
  .quad 0 # pNext
  .quad 0 # allocationSize
  .long 0 # memoryTypeIndex

.section .text

fn destroy_instance
  # void vkDestroyInstance(VkInstance instance, const VkAllocationCallbacks* pAllocator)
  # ABI: rdi=instance, rsi=pAllocator | returns void
  .extern vkDestroyInstance
  load qword, rdi, instance
  xor esi, esi
  calla vkDestroyInstance
  ret

fn destroy_device
  # void vkDestroyDevice(VkDevice device, const VkAllocationCallbacks* pAllocator)
  # ABI: rdi=device, rsi=pAllocator | returns void
  .extern vkDestroyDevice
  load qword, rdi, logical_device
  xor esi, esi
  calla vkDestroyDevice
  ret

fn destroy_buffer
  # void vkDestroyBuffer(VkDevice device, VkBuffer buffer, const VkAllocationCallbacks* pAllocator)
  # ABI: rdi=device, rsi=buffer, rdx=pAllocator | returns void
  .extern vkDestroyBuffer
  load qword, rdi, logical_device
  load qword, rsi, runtime_buffer
  xor edx, edx # NULL
  calla vkDestroyBuffer
  ret

fn create_buffer
  # VkResult vkCreateBuffer(VkDevice device, const VkBufferCreateInfo* pCreateInfo, const VkAllocationCallbacks* pAllocator, VkBuffer* pBuffer)
  # ABI: rdi=device, rsi=pCreateInfo, rdx=pAllocator, rcx=pBuffer | returns VkResult in eax
  .extern vkCreateBuffer
  load qword, rdi, logical_device
  addr rsi, buffer_create_info
  xor rdx, rdx # NULL
  addr rcx, runtime_buffer
  calla vkCreateBuffer
  ret

# rax = munmap(void* addr rdi, size_t length rsi)
fn unmap_pysical_device
  load qword, rdi, physical_device
  load qword, rsi, devices_bytes
  calla munmap
  ret

fn unmap_queue_props
  load qword, rdi, queue_family_properties
  load qword, rsi, queue_family_bytes
  calla munmap
  ret

gfn _start
  and rsp, -16
  sub rsp, 8
  jmp main

fn cleanup
  mov r12, rdi

  test dword ptr [rip + alloc_state], STATE_RUNTIME_BUFFER
  jz .skip_cleanup_buffer
  calla destroy_buffer
.skip_cleanup_buffer:

  test dword ptr [rip + alloc_state], STATE_VKDEVICE
  jz .skip_cleanup_device
  calla destroy_device
.skip_cleanup_device:

  test dword ptr [rip + alloc_state], STATE_QUEUE_PROPS
  jz .skip_queue_props
  calla unmap_queue_props
.skip_queue_props:

  test dword ptr [rip + alloc_state], STATE_DEVICE_MAP
  jz .skip_devices
  calla unmap_pysical_device
.skip_devices:

  test dword ptr [rip + alloc_state], STATE_VKINSTANCE
  jz .skip_instance
  calla destroy_instance
.skip_instance:

  mov rdi, r12
  jmp exit_group

fn main
  # bind signals
  mov rdi, 2 # SIGINT
  calla bind_signal
  test eax, eax
  je .begin
  addr rdi, err_sig

# fail(rdi = error string)
fn fail
  calla print_err
  mov edi, 1 # exit code = 1
  jmp cleanup

.begin:
  # VkResult vkCreateInstance(const VkInstanceCreateInfo* pCreateInfo, const VkAllocationCallbacks* pAllocator, VkInstance* pInstance)
  # ABI: rdi=pCreateInfo, rsi=pAllocator, rdx=pInstance | returns VkResult in eax
  .extern vkCreateInstance
.create_instance:
  addr rdi, instance_create_info
  xor esi, esi
  addr rdx, instance
  calla vkCreateInstance
  test eax, eax
  je .instance_created
  addr rdi, err_vk_instance
  jmp fail

.instance_created:
  or dword ptr [rip + alloc_state], STATE_VKINSTANCE

  # VkResult vkEnumeratePhysicalDevices(VkInstance instance, uint32_t* pPhysicalDeviceCount, VkPhysicalDevice* pPhysicalDevices)
  # ABI: rdi=instance, rsi=pPhysicalDeviceCount, rdx=pPhysicalDevices | returns VkResult in eax
  .extern vkEnumeratePhysicalDevices
  load qword, rdi, instance
  addr rsi, device_count
  xor rdx, rdx # pDevices = NULL (query count only)
  calla vkEnumeratePhysicalDevices
  test eax, eax
  je .check_device_count
  addr rdi, err_vk_enum
  jmp fail

.check_device_count:
  # If device_count == 0, there is nothing to allocate.
  load dword, eax, device_count
  test eax, eax
  jne .compute_device_allocation_size
.no_devices:
  addr rdi, err_no_devices
  jmp fail

.compute_device_allocation_size:
  # devices_bytes = device_count * sizeof(VkPhysicalDevice)
  load dword, eax, device_count
  shl rax, 3 # rax = count * 8
  store qword, devices_bytes, rax

.mmap_physical_device:
  # rax = mmap(void* addr rdi, size_t length rsi, int prot rdx, int flags r10, int fd r8, off_t offset r9)
  xor edi, edi # addr = NULL
  load qword, rsi, devices_bytes
  mov edx, 3 # PROT_READ | PROT_WRITE
  mov r10d, 0x22 # MAP_PRIVATE | MAP_ANONYMOUS
  mov r8, -1 # fd = -1
  xor r9d, r9d
  calla mmap
  cmp rax, -4095
  jae cleanup
  store qword, physical_device, rax
  or dword ptr [rip + alloc_state], STATE_DEVICE_MAP

.populate_devices:
  # VkResult = vkEnumeratePhysicalDevices(VkInstance rdi, uint32_t* pCount rsi, VkPhysicalDevice* pDevices rdx)
  load qword, rdi, instance
  addr rsi, device_count
  load qword, rdx, physical_device
  calla vkEnumeratePhysicalDevices
  test eax, eax
  je .devices_ok
  addr rdi, err_vk_enum
  jmp fail
.devices_ok:

.print_devices:
  # reset selected_device_type as .bss is only 0 init
  mov dword ptr [rip + selected_device_type], -1

  xor rcx, rcx
  load dword, eax, device_count

.device_loop:
  # we have to reload this every iteration as call below clobbers eax
  load dword, eax, device_count
  cmp rcx, rax
  jge .devices_printed

  # void vkGetPhysicalDeviceProperties(VkPhysicalDevice physicalDevice, VkPhysicalDeviceProperties* pProperties)
  # ABI: rdi=physicalDevice, rsi=pProperties | returns void
  .extern vkGetPhysicalDeviceProperties
  load qword, r8, physical_device
  mov rdx, rcx
  shl rdx, 3  # offset = i * 8
  add r8, rdx # r8 += offset

  mov r13, qword ptr [r8]
  mov rdi, r13
  addr rsi, device_properties
  calla vkGetPhysicalDeviceProperties

  # validate / check that device is better than last
  # device type is at offset = 16 of VkPhysicalDeviceProperties
  load dword, eax, device_properties + 16

  cmp eax, 0 # OTHER
  je .skip_device
  cmp eax, 2 # DISCRETE_GPU
  je .set_priority_3
  cmp eax, 1 # INTEGRATED_GPU
  je .set_priority_2
  cmp eax, 4 # CPU
  je .set_priority_1
  # else
  jmp .skip_device
.set_priority_3:
  mov ebx, 3
  jmp .compare_priority
.set_priority_2:
  mov ebx, 2
  jmp .compare_priority
.set_priority_1:
  mov ebx, 1
.compare_priority:
  cmp ebx, dword ptr [rip + selected_device_type]
  jle .skip_device # priority <= best? skip

.select_device:
  store qword, selected_device, r13
  store dword, selected_device_type, eax
  addr rdi, msg_devices
  calla print
  # device name is at offset = 20 of VkPhysicalDeviceProperties
  addr rdi, device_properties + 20
  calla print

  # newline separated
  push rax
  addr rdi, newline
  calla print
  pop rax
  jmp .devices_printed

.skip_device:
  inc rcx
  jmp .device_loop

.devices_printed:
  cmp dword ptr [rip + selected_device_type], -1
  push rbp
  mov rbp, rsp
  je .no_devices
  pop rbp

.get_queue_family_count:
  # void vkGetPhysicalDeviceQueueFamilyProperties(VkPhysicalDevice physicalDevice, uint32_t* pQueueFamilyPropertyCount, VkQueueFamilyProperties* pQueueFamilyProperties)
  # ABI: rdi=physicalDevice, rsi=pQueueFamilyPropertyCount, rdx=pQueueFamilyProperties | returns void
  .extern vkGetPhysicalDeviceQueueFamilyProperties
  xor edi, edi # addr = NULL
  load qword, rdi, selected_device
  addr rsi, queue_family_count
  xor edx, edx
  calla vkGetPhysicalDeviceQueueFamilyProperties
  load dword, eax, queue_family_count

.compute_family_allocation_size:
  imul rax, 24 # rax = count * 24
  store qword, queue_family_bytes, rax

.mmap_queue_family:
  # mmap(void* addr rdi, size_t length rsi, int prot rdx, int flags r10, int fd r8, off_t offset r9)
  load qword, rsi, queue_family_bytes
  mov edx, 3 # PROT_READ | PROT_WRITE
  mov r10d, 0x22 # MAP_PRIVATE | MAP_ANONYMOUS
  mov r8, -1 # fd = -1
  xor r9d, r9d
  calla mmap
  cmp rax, -4095
  jae cleanup
  store qword, queue_family_properties, rax
  or dword ptr [rip + alloc_state], STATE_QUEUE_PROPS

.get_queue_family_properties:
  # vkGetPhysicalDeviceQueueFamilyProperties(VkPhysicalDevice rdi, uint32_t* pCount rsi, VkQueueFamilyProperties* pProperties rdx)
  load qword, rdi, selected_device
  addr rsi, queue_family_count
  load qword, rdx, queue_family_properties
  calla vkGetPhysicalDeviceQueueFamilyProperties

.select_queue_family:
  addr rdi, msg_queue_family
  calla print
  xor rcx, rcx

.check_qfp_loop:
  load dword, eax, queue_family_count
  cmp rcx, rax
  jge .no_compute_family

  mov rdx, rcx
  imul rdx, 24
  load qword, r8, queue_family_properties
  add r8, rdx

  mov eax, [r8]
  test eax, 2 # COMPUTE
  jz .check_qfp_next

  # compute family is compatible, store and print index
  store dword, queue_family_index, ecx
.print_qfp:
  addr rdi, msg_queue_family_index
  calla print

  load dword, edi, queue_family_index
  calla print_u32
  # clobbered after print_u32
  mov eax, [r8]

  addr rdi, space
  calla print

  # print capabilities
  addr rdi, msg_compute
  calla print

  test eax, 4 # TRANSFER
  jz .qfp_no_transfer
  addr rdi, msg_transfer
  calla print
.qfp_no_transfer:

  test eax, 1 # GRAPHICS
  jz .qfp_no_graphics
  addr rdi, msg_graphics
  calla print
.qfp_no_graphics:

  jmp .check_qfp_done

.check_qfp_next:
  inc rcx
  jmp .check_qfp_loop
.check_qfp_done:
  addr rdi, newline
  calla print
  jmp .create_device

.no_compute_family:
  addr rdi, err_no_queue_family
  jmp fail

.create_device:
  # VkResult vkCreateDevice(VkPhysicalDevice physicalDevice, const VkDeviceCreateInfo* pCreateInfo, const VkAllocationCallbacks* pAllocator, VkDevice* pDevice)
  # ABI: rdi=physicalDevice, rsi=pCreateInfo, rdx=pAllocator, rcx=pDevice | returns VkResult in eax
  .extern vkCreateDevice

  load dword, eax, queue_family_index
  store dword, device_queue_create_info + 20, eax
  load qword, rdi, selected_device
  addr rsi, device_create_info
  xor edx, edx
  addr rcx, logical_device
  calla vkCreateDevice
  test eax, eax
  jne fail
  or dword ptr [rip + alloc_state], STATE_VKDEVICE

  # void vkGetDeviceQueue(VkDevice device, uint32_t queueFamilyIndex, uint32_t queueIndex, VkQueue* pQueue)
  # ABI: rdi=device, esi=queueFamilyIndex, edx=queueIndex, rcx=pQueue | returns void
  .extern vkGetDeviceQueue
  load qword, rdi, logical_device
  load dword, esi, queue_family_index
  xor edx, edx
  addr rcx, queue
  calla vkGetDeviceQueue

  # vkGetDeviceQueue is void; verify the handle was written
.validate_device_queue:
  load qword, rax, queue
  test rax, rax
  jz .has_device_queue
  addr rdi, err_no_queue
  jz fail
.has_device_queue:

.create_runtime_buffer:
  calla create_buffer
  test eax, eax
  addr rdi, err_create_buffer
  jne fail
  or dword ptr [rip + alloc_state], STATE_RUNTIME_BUFFER
  
.get_runtime_requirements:
  # void vkGetBufferMemoryRequirements(VkDevice device, VkBuffer buffer, VkMemoryRequirements* pMemoryRequirements)
  # ABI: rdi=device, rsi=buffer, rdx=pMemoryRequirements | returns void
  .extern vkGetBufferMemoryRequirements
  load qword, rdi, logical_device
  load qword, rsi, runtime_buffer
  addr rdx, runtime_memory_requirements
  calla vkGetBufferMemoryRequirements
  load qword, rax, runtime_memory_requirements
  test rax, rax 
  addr rdi, err_buffer_memory_requirements
  # size == 0
  je fail
  load dword, eax, runtime_memory_requirements + 16
  # memoryTypeBits invalid
  test eax, eax
  addr rdi, err_buffer_memory_requirements
  jz fail

.get_device_memory_properties:  
  # void vkGetPhysicalDeviceMemoryProperties(VkPhysicalDevice physicalDevice, VkPhysicalDeviceMemoryProperties* pMemoryProperties)
  # ABI: rdi=physicalDevice, rsi=pMemoryProperties | returns void
  .extern vkGetPhysicalDeviceMemoryProperties  
  load qword, rdi, selected_device
  addr rsi, runtime_memory_properties
  calla vkGetPhysicalDeviceMemoryProperties

.find_memory_type:
  # required = HOST_VISIBLE 0x2 | HOST_COHERENT 0x4 = 0x6
  mov r9d, 6
  load dword, r8d, runtime_memory_properties # memoryTypeCount
  load dword, r10d, runtime_memory_requirements + 16 # memoryTypeBits

  xor ecx, ecx
.find_memtype_loop:
  cmp ecx, r8d
  jge .no_valid_memory_type

  mov eax, r10d
  shr eax, cl
  test eax, 1
  jz .find_memtype_next

  # propertyFlags @ 4 + i * 8
  mov edx, ecx
  imul edx, 8
  add edx, 4 # memoryTypes offset
  load dword, eax, runtime_memory_properties + edx

  and eax, r9d
  cmp eax, r9d
  je .found_memory_type

.find_memtype_next:
  inc ecx
  jmp .find_memtype_loop

.found_memory_type:
  store dword, runtime_memory_type_index, ecx
  jmp .allocate_runtime_memory

.no_valid_memory_type:
  addr rdi, err_no_memory_type_found
  jmp fail

.allocate_runtime_memory:
  # TODO
  
.started:
  addr rdi, msg_bootstrapped
  calla print

.finished:
  # exit code 0
  xor edi, edi
  jmp cleanup

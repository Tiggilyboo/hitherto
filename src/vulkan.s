.include "./src/macros.inc"
.intel_syntax noprefix

.equ STATE_DEVICE_MAP,    1
.equ STATE_VKINSTANCE,    2
.equ STATE_QUEUE_PROPS,   4
.equ STATE_VKDEVICE,      8

.extern vkCreateInstance
.extern vkDestroyInstance

.extern vkCreateDevice
.extern vkGetDeviceQueue
.extern vkDestroyDevice

.extern vkCreateBuffer
.extern vkDestroyBuffer

.extern vkEnumeratePhysicalDevices
.extern vkGetPhysicalDeviceProperties
.extern vkGetPhysicalDeviceQueueFamilyProperties

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
err_sig:
  .asciz "rt_sigaction failed"
err_no_queue_family:
  .asciz "No Vulkan physical device queue family with compute capabilities found.\n"

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
devices:
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
  .long 0  # padding before queueCount
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

.section .text

# void = vkDestroyInstance(VkInstance rdi, VkAllocationCallbacks* rsi)
fn destroy_instance 
  load qword, rdi, instance
  xor esi, esi
  calla vkDestroyInstance
  ret

fn destroy_device
  load qword, rdi, logical_device
  xor esi, esi
  calla vkDestroyDevice
  ret

# rax = munmap(void* addr rdi, size_t length rsi)
fn unmap_devices
  load qword, rdi, devices
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
  calla unmap_devices
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
  lea rdi, [rip + err_sig]

# fail(rdi = error string)
fn fail
  calla print_err
  mov edi, 1 # exit code = 1
  jmp cleanup
  
.begin:
  # rax = vkCreateInstance(vkInstanceCreateInfo* rdi, VkAllocationCallbacks* rsi, VkInstance* rdx)
  lea rdi, [rip + instance_create_info]
  xor esi, esi
  lea rdx, [rip + instance]
  calla vkCreateInstance
  test eax, eax
  je .instance_created
  lea rdi, [rip + err_vk_instance]
  jmp fail
  
.instance_created:
  or dword ptr [rip + alloc_state], STATE_VKINSTANCE

  # VkResult = vkEnumeratePhysicalDevices(VkInstance rdi, uint32_t* pCount rsi, VkPhysicalDevice* pDevices rdx)
  mov rdi, qword ptr [rip + instance]
  lea rsi, [rip + device_count]
  xor rdx, rdx # pDevices = NULL (query count only)
  calla vkEnumeratePhysicalDevices
  test eax, eax
  je .check_device_count
  lea rdi, [rip + err_vk_enum]
  jmp fail

.check_device_count:
  # If device_count == 0, there is nothing to allocate.
  mov eax, dword ptr [rip + device_count]
  test eax, eax
  jne .compute_device_allocation_size
.no_devices:
  lea rdi, [rip + err_no_devices]
  jmp fail

.compute_device_allocation_size:
  # devices_bytes = device_count * sizeof(VkPhysicalDevice)
  mov eax, dword ptr [rip + device_count]
  shl rax, 3 # rax = count * 8
  mov qword ptr [rip + devices_bytes], rax

.mmap_devices:
  # rax = mmap(void* addr rdi, size_t length rsi, int prot rdx, int flags r10, int fd r8, off_t offset r9)
  xor edi, edi # addr = NULL
  mov rsi, qword ptr [rip + devices_bytes]
  mov edx, 3 # PROT_READ | PROT_WRITE
  mov r10d, 0x22 # MAP_PRIVATE | MAP_ANONYMOUS
  mov r8, -1 # fd = -1
  xor r9d, r9d
  calla mmap
  cmp rax, -4095
  jae cleanup
  mov qword ptr [rip + devices], rax
  or dword ptr [rip + alloc_state], STATE_DEVICE_MAP

.populate_devices:
  # VkResult = vkEnumeratePhysicalDevices(VkInstance rdi, uint32_t* pCount rsi, VkPhysicalDevice* pDevices rdx)
  load qword, rdi, instance
  addr rsi, device_count
  load qword, rdx, devices
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
  mov eax, dword ptr [rip + device_count]

.device_loop:
  # we have to reload this every iteration as call below clobbers eax
  mov eax, dword ptr [rip + device_count]
  cmp rcx, rax
  jge .devices_printed

  # VkResult = vkGetPhysicalDeviceProperties(vkPhysicalDevice rdi, VkPhysicalDeviceProperties* rsi)
  mov r8, qword ptr [rip + devices]
  mov rdx, rcx
  shl rdx, 3  # offset = i * 8
  add r8, rdx # r8 += offset

  mov r13, qword ptr [r8]
  mov rdi, r13  
  addr rsi, device_properties
  calla vkGetPhysicalDeviceProperties

  # validate / check that device is better than last
  # device type is at offset = 16 of VkPhysicalDeviceProperties
  mov eax, dword ptr [rip + device_properties + 16]

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
  mov qword ptr [rip + selected_device], r13
  mov dword ptr [rip + selected_device_type], eax
  lea rdi, [rip + msg_devices]
  calla print
  # device name is at offset = 20 of VkPhysicalDeviceProperties
  lea rdi, [rip + device_properties + 20]
  calla print

  # newline separated
  push rax
  lea rdi, [rip + newline]
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
  # vkGetPhysicalDeviceQueueFamilyProperties(VkPhysicalDevice rdi, uint32_t* pCount rsi, VkQueueFamilyProperties* pProperties rdx)
  xor edi, edi # addr = NULL
  mov rdi, qword ptr [rip + selected_device]
  lea rsi, [rip + queue_family_count]
  xor edx, edx
  calla vkGetPhysicalDeviceQueueFamilyProperties
  mov eax, dword ptr [rip + queue_family_count]

.compute_family_allocation_size:
  imul rax, 24 # rax = count * 24
  mov qword ptr [rip + queue_family_bytes], rax

.mmap_queue_family:
  # mmap(void* addr rdi, size_t length rsi, int prot rdx, int flags r10, int fd r8, off_t offset r9)
  mov rsi, qword ptr [rip + queue_family_bytes]
  mov edx, 3 # PROT_READ | PROT_WRITE
  mov r10d, 0x22 # MAP_PRIVATE | MAP_ANONYMOUS
  mov r8, -1 # fd = -1
  xor r9d, r9d
  calla mmap
  cmp rax, -4095
  jae cleanup
  mov qword ptr [rip + queue_family_properties], rax
  or dword ptr [rip + alloc_state], STATE_QUEUE_PROPS

.get_queue_family_properties:
  # vkGetPhysicalDeviceQueueFamilyProperties(VkPhysicalDevice rdi, uint32_t* pCount rsi, VkQueueFamilyProperties* pProperties rdx)
  mov rdi, qword ptr [rip + selected_device]
  lea rsi, [rip + queue_family_count]
  mov rdx, qword ptr [rip + queue_family_properties]
  calla vkGetPhysicalDeviceQueueFamilyProperties

.select_queue_family:
  lea rdi, [rip + msg_queue_family]
  calla print
  xor rcx, rcx

.check_qfp_loop:
  mov eax, dword ptr [rip + queue_family_count]
  cmp rcx, rax
  jge .no_compute_family

  mov rdx, rcx
  imul rdx, 24
  mov r8, qword ptr [rip + queue_family_properties]
  add r8, rdx

  mov eax, [r8]
  test eax, 2 # COMPUTE
  jz .check_qfp_next

  # compute family is compatible, store and print index
  mov dword ptr [rip + queue_family_index], ecx
.print_qfp:
  lea rdi, [rip + msg_queue_family_index]
  calla print
  
  mov edi, dword ptr [rip + queue_family_index]
  calla print_u32
  # clobbered after print_u32
  mov eax, [r8]

  lea rdi, [rip + space]
  calla print

  # print capabilities
  lea rdi, [rip + msg_compute]
  calla print

  test eax, 4 # TRANSFER
  jz .qfp_no_transfer
  lea rdi, [rip + msg_transfer]
  calla print
.qfp_no_transfer:

  test eax, 1 # GRAPHICS
  jz .qfp_no_graphics
  lea rdi, [rip + msg_graphics]
  calla print
.qfp_no_graphics:

  jmp .check_qfp_done

.check_qfp_next:
  inc rcx
  jmp .check_qfp_loop
.check_qfp_done:
  lea rdi, [rip + newline]
  calla print
  jmp .create_device
  
.no_compute_family:
  lea rdi, [rip + err_no_queue_family]
  jmp fail
  
.create_device:
  mov eax, [rip + queue_family_index]
  mov dword ptr [rip + device_queue_create_info + 20], eax

  # vkResult = vkCreateDevice(physicalDevice, device_create_info, NULL, logical_devices)
  mov rdi, [rip + selected_device]
  lea rsi, [rip + device_create_info]
  xor edx, edx
  lea rcx, [rip + logical_device]
  calla vkCreateDevice
  test eax, eax
  jne fail
  or dword ptr [rip + alloc_state], STATE_VKDEVICE

  # vkResult = vkGetDeviceQueue(device, queueFamilyIndex, 0, queue)
  mov rdi, [rip + logical_device]
  mov esi, [rip + queue_family_index]
  xor edx, edx
  lea rcx, [rip + queue]
  calla vkGetDeviceQueue

.started:
  lea rdi, [rip + msg_bootstrapped]
  calla print

.finished:
  # exit code 0
  xor edi, edi
  jmp cleanup
  

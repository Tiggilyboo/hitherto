.intel_syntax noprefix

.extern vkCreateInstance
.extern vkDestroyInstance
.extern vkEnumeratePhysicalDevices
.extern vkGetPhysicalDeviceProperties
.extern vkGetPhysicalDeviceQueueFamilyProperties

.section .rodata

app_name:
  .asciz "hitherto"
newline:
  .asciz "\n"
msg_devices:
  .asciz "Selected device(s): \n"
msg_bootstrapped:
  .asciz "Strapped some boots\n"

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

.section .bss

# Define cleanup bits, cleanup should be in high -> low order
.equ STATE_EXIT,       1
.equ STATE_VKINSTANCE, 2
.equ STATE_DEVICES,    4
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
device_properties:
  .zero 552
.align 8
selected_device:
  .zero 8
.align 4
selected_device_type:
  .zero 4
    
.section .text

# void = vkDestroyInstance(VkInstance rdi, VkAllocationCallbacks* rsi)
destroy_instance:  
  mov rdi, qword ptr [rip + instance]
  xor esi, esi
  call vkDestroyInstance
  ret

# rax = munmap(void* addr rdi, size_t length rsi)
unmap_devices:
  mov rdi, qword ptr [rip + devices]
  mov rsi, qword ptr [rip + devices_bytes]
  call munmap
  ret

cleanup:
  push rdi
  test dword ptr [rip + alloc_state], STATE_DEVICES
  jz skip_devices
  call unmap_devices
skip_devices:
  test dword ptr [rip + alloc_state], STATE_VKINSTANCE
  jz skip_instance
  call destroy_instance
  and dword ptr [rip + alloc_state], ~STATE_VKINSTANCE
skip_instance:
  pop rdi
  call exit

# fail(rdi = error string)
.type fail, @function
fail:
  call print_err
  mov edi, 1 # exit code = 1
  jmp cleanup

.global _start
.type _start, @function
_start:
 
  # bind signals
  mov rdi, 2 # SIGINT
  call sig_handler
  test eax, eax
  je begin
  lea rdi, [rip + err_sig]
  
begin:
  # rax = vkCreateInstance(vkInstanceCreateInfo* rdi, VkAllocationCallbacks* rsi, VkInstance* rdx)
  lea rdi, [rip + instance_create_info]
  xor esi, esi
  lea rdx, [rip + instance]
  call vkCreateInstance
  test eax, eax
  je instance_created
  lea rdi, [rip + err_vk_instance]
  call fail
  
instance_created:
  or dword ptr [rip + alloc_state], STATE_VKINSTANCE

  # VkResult = vkEnumeratePhysicalDevices(VkInstance rdi, uint32_t* pCount rsi, VkPhysicalDevice* pDevices rdx)
  mov rdi, qword ptr [rip + instance]
  lea rsi, [rip + device_count]
  xor rdx, rdx # pDevices = NULL (query count only)
  call vkEnumeratePhysicalDevices
  test eax, eax
  je check_device_count
  lea rdi, [rip + err_vk_enum]
  call fail

check_device_count:
  # If device_count == 0, there is nothing to allocate.
  mov eax, dword ptr [rip + device_count]
  test eax, eax
  jne compute_allocation_size
no_devices:
  lea rdi, [rip + err_no_devices]
  call fail

compute_allocation_size:
  # devices_bytes = device_count * sizeof(VkPhysicalDevice)
  mov eax, dword ptr [rip + device_count]
  shl rax, 3 # rax = count * 8
  mov qword ptr [rip + devices_bytes], rax

mmap_devices:
  # rax = mmap(void* addr rdi, size_t length rsi, int prot rdx, int flags r10, int fd r8, off_t offset r9)
  xor edi, edi # addr = NULL
  mov rsi, qword ptr [rip + devices_bytes]
  mov edx, 3 # PROT_READ | PROT_WRITE
  mov r10d, 0x22 # MAP_PRIVATE | MAP_ANONYMOUS
  mov r8, -1 # fd = -1
  xor r9d, r9d
  call mmap
  cmp rax, -4095
  jae cleanup
  mov qword ptr [rip + devices], rax
  or dword ptr [rip + alloc_state], STATE_DEVICES

populate_devices:
  # VkResult = vkEnumeratePhysicalDevices(VkInstance rdi, uint32_t* pCount rsi, VkPhysicalDevice* pDevices rdx)
  mov rdi, qword ptr [rip + instance]
  lea rsi, [rip + device_count]
  mov rdx, qword ptr [rip + devices]
  call vkEnumeratePhysicalDevices
  test eax, eax
  je devices_ok
  lea rdi, [rip + err_vk_enum]
  call fail
devices_ok:

print_devices:
  # reset selected_device_type as .bss is only 0 init
  mov dword ptr [rip + selected_device_type], -1


  xor rcx, rcx
  mov eax, dword ptr [rip + device_count]
device_loop:
  # we have to reload this every iteration as call below clobbers eax
  mov eax, dword ptr [rip + device_count]
  cmp rcx, rax
  jge devices_printed

  # VkResult = vkGetPhysicalDeviceProperties(vkPhysicalDevice rdi, VkPhysicalDeviceProperties* rsi)
  mov r8, qword ptr [rip + devices]
  mov rdx, rcx
  shl rdx, 3  # offset = i * 8
  add r8, rdx # r8 += offset
  mov rdi, qword ptr [r8] # devices[r8]
  lea rsi, [rip + device_properties]
  call vkGetPhysicalDeviceProperties

  # validate / check that device is better than last
  # device type is at offset = 16 of VkPhysicalDeviceProperties
  mov eax, dword ptr [rip + device_properties + 16]

  # test no devices found?
  #jmp skip_device

  cmp eax, 2 # DISCRETE_GPU
  je select_device
  cmp eax, 4 # CPU 
  je skip_device
  cmp eax, 0 # OTHER
  je skip_device
  cmp eax, dword ptr [rip + selected_device_type]
  jge skip_device
  
select_device:
  mov qword ptr [rip + selected_device], rdi
  mov dword ptr [rip + selected_device_type], eax
  lea rdi, [rip + msg_devices]
  call print
  # device name is at offset = 20 of VkPhysicalDeviceProperties
  lea rdi, [rip + device_properties + 20]
  call print

  # newline separated
  push rax
  lea rdi, [rip + newline]
  call print
  pop rax
  jmp devices_printed

skip_device:
  inc rcx
  jmp device_loop

devices_printed:
  cmp dword ptr [rip + selected_device_type], -1
  push rbp
  mov rbp, rsp  
  je no_devices
  pop rbp

started:
  lea rdi, [rip + msg_bootstrapped]
  call print

finished:
  # exit code 0
  xor edi, edi
  jmp cleanup

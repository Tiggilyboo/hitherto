.intel_syntax noprefix
.include "./src/macros.inc"

.section .rodata

.section .bss

.section .data

.align 8
sigact:
    .quad signal_trap # handler
    .quad 0           # flags
    .quad 0           # restorer
    .quad 0           # mask, 8 bytes for sigaction syscall ABI

.section .text

gfn exit
    mov rax, 60
    syscall
    ret

gfn exit_group
    mov rax, 231
    syscall
    ret

# len(rdi = current position, rsi = string)
gfn len
    xor rax, rax
.len_find:
    cmp [rdi], al
    je .len_ret
    inc rdi
    jmp .len_find
.len_ret:
    sub rdi, rsi
    mov rdx, rdi
    ret

# print(rdi = string)
gfn print
    mov rsi, rdi
    calla len # rsi = length
    mov rdi, 1 # stdout
    mov rax, 1 # sys_write
    syscall
    ret

# print_err(rdi = string)
gfn print_err
    mov rsi, rdi
    calla len # rsi = length
    mov rdi, 2 #st0   
    mov rax, 1 #sys_write
    syscall
    ret

# print_u32(rdi = u32)
gfn print_u32
    sub rsp, 16                 # keeps rsp % 16 == 8
    lea rsi, [rsp + 16]

    mov eax, edi
    mov ecx, 10

    test eax, eax
    jne .loop

    dec rsi
    mov byte ptr [rsi], '0'
    mov edx, 1
    jmp .write

.loop:
    xor edx, edx
    div ecx
    add dl, '0'
    dec rsi
    mov byte ptr [rsi], dl
    test eax, eax
    jne .loop

    lea rdx, [rsp + 16]
    sub rdx, rsi

.write:
    mov edi, 1
    mov eax, 1
    syscall

    add rsp, 16
    ret

# rax = mmap(addr = rdi, length = rsi, prot = rdx, flags = r10, fd = r8, offset = r9)
gfn mmap
    mov eax, 9   # syscall: mmap
    syscall
    ret

# rax = munmap(addr = rdi, length = rsi)
gfn munmap
    mov eax, 11 # syscall: munmap
    syscall
    ret

# rax = bind_signal(signum = rdi)
gfn bind_signal
    lea rsi, [rip + sigact] # new action
    xor edx, edx # old = NULL
    mov r10d, 8  # sizeof(sigset_t)
    mov eax, 13  # rt_sigaction
    syscall
    ret

gfn signal_trap
    # don't bother cleaning up, kernel can reclaim when the process dies
    # otherwise we might try to jmp cleanup mid execution in any external vulkan / syscalls (re-entry)
    mov edi, 130
    call exit
    ret


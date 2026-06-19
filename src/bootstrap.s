.intel_syntax noprefix
.section .rodata

.section .data

.align 8
sigact:
    .quad sig_handler # handler
    .quad 0           # mask = empty set
    .long 0           # flags
    .quad 0           # restorer = NULL

.section .text

.global exit
.type exit, @function
exit:
    mov rax, 60
    syscall
    ret

# len(rdi = current position, rsi = string)
.global len
.type len, @function
len:
    xor rax, rax
len_find:
    cmp [rdi], al
    je len_ret
    inc rdi
    jmp len_find
len_ret:
    sub rdi, rsi
    mov rdx, rdi
    ret

.global print
.type print, @function
# print(rdi = string)
print:
    mov rsi, rdi
    call len # rsi = length
    mov rdi, 1 # stdout
    mov rax, 1 # sys_write
    syscall
    ret

.global print_err
.type print_err, @function
# print_err(rdi = string)
print_err:
    mov rsi, rdi
    call len # rsi = length
    mov rdi, 2 #st0   
    mov rax, 1 #sys_write
    syscall
    ret

.global mmap
.type mmap, @function
# rax = mmap(addr = rdi, length = rsi, prot = rdx, flags = r10, fd = r8, offset = r9)
mmap:
    mov eax, 9   # syscall: mmap
    syscall
    ret

.global munmap
.type munmap, @function
# rax = munmap(addr = rdi, length = rsi)
munmap:
    mov eax, 11 # syscall: munmap
    syscall
    ret

.global sig_handler
.type sig_handler @function
# rax = sig_handler(signum = rdi, sigaction = rsi, sigaction (old) rdx)
sig_handler:
    lea rsi, [rip + sigact] # new action
    xor edx, edx # old = NULL
    mov eax, 13  # rt_sigaction
    syscall
    ret
    

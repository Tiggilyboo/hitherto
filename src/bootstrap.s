.intel_syntax noprefix

.equ TOKEN_MAX_LEN, 31

.equ E_EOF, -1
.equ E_LEN, -2
.equ E_DIC, -3
.equ E_SYN, -4
.equ E_DIV, -5
.equ E_STA, -6

.section .rodata

token_dup:
    .asciz "^"
    .skip 29
token_drop:
    .asciz "_"
    .skip 29
token_swap:
    .asciz "><"
    .skip 28
token_over:
    .asciz "<^"
    .skip 28
token_def:
    .asciz ":"
    .skip 29
token_end:
    .asciz ";"
    .skip 29
token_add:
    .asciz "+"
    .skip 29
token_sub:
    .asciz "-"
    .skip 29
token_mul:
    .asciz "*"
    .skip 29
token_div:
    .asciz "/"
    .skip 29
token_write:
    .asciz "."
    .skip 29
token_tick:
    .asciz "'"
    .skip 29

err_unknown:
    .asciz "Unknown error occurred\n"
err_token:
    .asciz "Error reading token\n"
err_token_len:
    .asciz "Token length must be less than 31\n"
err_dict_notfound:
    .asciz "Dictionary did not contain token\n"
err_token_invalid:
    .asciz "Token invalid\n"
err_div_zero:
    .asciz "Divide by zero\n"
err_stack_underflow:
    .asciz "Data stack underflow\n"
err_stack_overflow:
    .asciz "Data stack overflow\n"
err_dict_overflow:
    .asciz "Dictionary full\n"
ok_test:
    .asciz "OK\n"

.section .bss

.align 8
data_stack:
    .skip 65536
data_stack_end:
token_buf:
    .skip 32
io_char:
    .skip 1
write_buf:
    .skip 32

.align 16
dict:
    .skip 131072
dict_end:

.section .text

read_char:
    push rcx
    mov eax, 0 # sys_read
    xor edi, edi
    lea rsi, [rip + io_char]
    mov edx, 1
    syscall
    cmp rax, 1
    jne .read_char_eof
    movzx eax, byte ptr [rip + io_char]
    pop rcx
    ret
.read_char_eof:
    mov rax, E_EOF
    pop rcx
    ret

write:
    mov eax, 1 # sys_write
    mov edi, 1 # stdout
    syscall
    ret

write_err:
    mov eax, 1 # sys_write
    mov edi, 2 # stderr
    syscall
    ret

# assumes rsi populated for length
# output in rax
len:
    xor rax, rax
    mov rdi, rsi
.len_next:
    movzx eax, byte ptr[rdi]
    test al, al
    jz .len_done
    inc rdi
    jmp .len_next
.len_done:
    # end - start = len
    mov rax, rdi
    sub rax, rsi
    ret

exit:
    mov eax, 60
    xor edi, edi
    mov rdi, rax
    syscall
    ret

fail:
    # assumes rsi populated with string pointer
    cmp rsi, 0
    je .fail_done
    xor edx, edx
.fail_count:
    call len
    mov rdx, rax
.fail_done:
    call write_err
    jmp exit

# RSI -> null terminated token
# returns:
#   RAX = signed integer
#   CF=0 success
#   CF=1 not a valid integer
parse_int:
    xor eax, eax
    xor edi, edi
    cmp byte ptr [rsi], '-'
    jne .require_digit
    mov edi, 1 # negative
    inc rsi

.require_digit:
    cmp byte ptr [rsi], 0
    je .int_bad

.int_loop:
    movzx edx, byte ptr [rsi]

    # End of string = successful parse
    test dl, dl
    jz .int_done

    # ASCII -> digit
    sub edx, '0'
    cmp edx, 9
    ja .int_bad

    # number *= 10
    imul rax, rax, 10
    jo .int_bad

    # Add/subtract digit according to sign
    test edi, edi
    jnz .int_negative

    add rax, rdx
    jo .int_bad
    jmp .int_next
.int_negative:
    sub rax, rdx
    jo .int_bad
.int_next:
    inc rsi
    jmp .int_loop
.int_done:
    clc
    ret
.int_bad:
    stc
    ret

read_token:
    xor rcx, rcx
.skip_ws:
    call read_char
    cmp eax, E_EOF
    je .fail_token_eof

    cmp al, ' ' 
    je .skip_ws
    cmp al, '\t'
    je .skip_ws
    cmp al, '\n'
    je .skip_ws
.next:
    cmp rcx, TOKEN_MAX_LEN
    jge .fail_token_overflow

    mov byte ptr [rip + token_buf + rcx], al
    inc rcx

    call read_char
    cmp eax, E_EOF
    je .done

    cmp al, ' ' 
    je .done
    cmp al, '\t'
    je .done
    cmp al, '\n'
    je .done

    jmp .next
.done:
    # null-terminate
    mov byte ptr [rip + token_buf + rcx], 0
    xor eax, eax
    ret
    
# WORDS

word_dup:
    mov [r15], r13
    add r15, 8
    ret

word_drop:
    lea rax, [rip + data_stack]
    cmp r15, rax
    je .fail_stack_underflow
    sub r15, 8
    mov r13, [r15]
    ret

word_swap:
    xchg r13, [r15 - 8]
    ret

word_over:
    mov rax, [r15 - 8]
    mov [r15], r13
    add r15, 8
    mov r13, rax
    ret

# rsi = pointer to 32-byte name
# rdi = code function pointer
#
# returns:
#   rax = new dictionary node address
dict_add_builtin:
    xor edx, edx
    xor ecx, ecx
    call dict_add
    ret

# r14 = dictionary tail, null if empty
# rsi = pointer to 32-byte name
# rdi = code function pointer
# rdx = pointer to body cells (ignored if rcx == 0)
# rcx = body_len
#
# returns:
#   rax = new dictionary node address
dict_add:
    test r14, r14
    jz .dict_first
    # next node begins immediately after previous node
    mov rax, [r14 + 40]              # previous body_len
    lea rax, [r14 + 56 + rax * 8]
    jmp .dict_alloc
.dict_first:
    lea rax, [rip + dict]
.dict_alloc:
    # exclusive end of new node
    lea r8, [rax + 56 + rcx * 8]
    lea r9, [rip + dict_end]
    cmp r8, r9
    ja .fail_dict_overflow
.dict_add_copy_name:
    movdqu xmm0, [rsi]
    movdqu [rax], xmm0
    movdqu xmm0, [rsi + 16]
    movdqu [rax + 16], xmm0
.dict_add_code:
    mov [rax + 32], rdi
.dict_add_copy_len:
    mov [rax + 40], rcx
    lea r8, [rax + 48]
    mov r9, rcx
.dict_add_copy_body:
    test r9, r9
    jz .dict_add_prev
    mov r10, [rdx]
    mov [r8], r10
    add rdx, 8
    add r8, 8
    dec r9
    jmp .dict_add_copy_body
.dict_add_prev:
    mov [r8], r14
    mov r14, rax
    ret

# r14 = current completed dict tail
word_def:
    # rsi = name
    call read_token
    lea rsi, [rip + token_buf]
    lea rdi, [rip + word_exec]
    # alloc empty node and populate it until ';'
    push r14
    xor ecx, ecx
    xor ebx, ebx # body_len
    call dict_add
    mov rbp, rax # rbp = def being compiled
    # pop back old tail
    pop r14
    lea r12, [rbp + 48]
    xor ebx, ebx # body_len

.def_next:
    call read_token
    cmp byte ptr [rip + token_buf], ';'
    je .def_done

    lea rsi, [rip + token_buf]
    call find_word
    jc .fail_notfound

    lea rdx, [r12 + 16]
    lea rcx, [rip + dict_end]
    cmp rdx, rcx
    ja .fail_dict_overflow

    mov [r12], rax
    add r12, 8
    inc rbx
    jmp .def_next

.def_done:
    mov [rbp + 40], rbx # body_len
    mov [r12], r14 # prev ptr
    mov r14, rbp
    ret
    
word_end:
    jmp .fail_notfound

# rax = dictionary node being executed
word_exec:
    push r12
    push rbx
    mov rbx, [rax + 40] # body_len
    lea r12, [rax + 48] # body
.exec_next:
    test rbx, rbx
    jz .exec_done
    mov rax, [r12] # next node
    add r12, 8
    dec rbx
    mov rdx, [rax + 32] # code
    call rdx
    jmp .exec_next
.exec_done:
    pop rbx
    pop r12
    ret
    
word_add:
    sub r15, 8
    add r13, [r15]
    ret

word_sub:
    sub r15, 8
    mov rax, [r15]
    sub rax, r13
    mov r13, rax
    ret

word_mul:
    sub r15, 8
    imul r13, [r15]
    ret

word_write:
    mov rax, r13
    lea rsi, [rip + write_buf + 32]
    dec rsi
    mov byte ptr [rsi], '\n'

    xor r8d, r8d # negative flag
    test rax, rax
    jns .convert_numeric
    mov r8b, 1
    neg rax
.convert_numeric:
    mov rcx, 10 # base
    test rax, rax
    jnz .convert_digit_loop
    dec rsi
    mov byte ptr [rsi], '0'
    jmp .convert_add_sign
.convert_digit_loop:
    xor edx, edx
    div rcx # rdx:rax / 10, rax = quotient, rdx = remainder
    add dl, '0'
    dec rsi
    mov byte ptr [rsi], dl
    test rax, rax
    jnz .convert_digit_loop
.convert_add_sign:
    test r8b, r8b
    jz .convert_output
    dec rsi
    mov byte ptr [rsi], '-'
.convert_output:
    lea rdx, [rip + write_buf + 32]
    sub rdx, rsi
    call write
    sub r15, 8
    mov r13, [r15]
    ret
    
word_div:
    mov rcx, r13 # divisor = rhs TOS
    test rcx, rcx
    jz .fail_div_zero
    sub r15, 8
    mov rax, [r15] # dividend = lhs
    cqo
    idiv rcx # rax = div, rdx = remainder
    mov r13, rax
    ret

word_tick:
    call read_token
    lea rsi, [rip + token_buf]
    call find_word
    jc .fail_notfound

    mov [r15], r13 # old TOS = NOS
    add r15, 8
    mov r13, rax # XT becomes new TOS
    ret

# rsi = pointer to null-terminated token
# r14 = dict tail (most recent node starte, null when empty)
# returns:
#   rax = node start ptr
#   CF=0 found
#   CF=1 not found
# Walks backward from r14 following last_ptr.
# Returns the node start in rax so the caller can read code_len and iterate the code array
find_word:
    mov rdx, r14
.find_next:
    test rdx, rdx
    jz .find_missing
    xor ecx, ecx
.find_compare:
    mov al, byte ptr [rsi + rcx]
    cmp al, byte ptr [rdx + rcx]
    jne .find_prev
    test al, al
    jz .find_found
    inc rcx
    jmp .find_compare
.find_prev:
    mov rcx, [rdx + 40] # body_len
    mov rdx, [rdx + 48 + rcx * 8] # prev
    jmp .find_next
.find_found:
    mov rax, rdx
    clc
    ret
.find_missing:
    stc
    ret

.global _start
_start:
    xor r14d, r14d # dict must be null (0) for first dict_add call
    lea r15, [rip + data_stack]

    # load builtins into dict
.load_builtins:
    lea rsi, [rip + token_dup]
    lea rdi, [rip + word_dup]
    call dict_add_builtin
    lea rsi, [rip + token_drop]
    lea rdi, [rip + word_drop]
    call dict_add_builtin
    lea rsi, [rip + token_swap]
    lea rdi, [rip + word_swap]
    call dict_add_builtin
    lea rsi, [rip + token_over]
    lea rdi, [rip + word_over]
    call dict_add_builtin
    lea rsi, [rip + token_def]
    lea rdi, [rip + word_def]
    call dict_add_builtin
    lea rsi, [rip + token_end]
    lea rdi, [rip + word_end]
    call dict_add_builtin
    lea rsi, [rip + token_add]
    lea rdi, [rip + word_add]
    call dict_add_builtin
    lea rsi, [rip + token_sub]
    lea rdi, [rip + word_sub]
    call dict_add_builtin
    lea rsi, [rip + token_mul]
    lea rdi, [rip + word_mul]
    call dict_add_builtin
    lea rsi, [rip + token_div]
    lea rdi, [rip + word_div]
    call dict_add_builtin
    lea rsi, [rip + token_write]
    lea rdi, [rip + word_write]
    call dict_add_builtin
    lea rsi, [rip + token_tick]
    lea rdi, [rip + word_tick]
    call dict_add_builtin

# VM reserved registers:
# r12 = instruction pointer
# r13 = cached TOS
# r14 = dictionary tail
# r15 = data stack pointer
.repl_loop:
    call read_token

    lea rsi, [rip + token_buf]
    call find_word
    jc .try_number

    mov rdx, [rax + 32]
    call rdx

    jmp .repl_loop
.try_number:
    lea rsi, [rip + token_buf]
    call parse_int
    jc .fail_notfound

.push_numeric:
    mov [r15], r13
    add r15, 8
    mov r13, rax
    jmp .repl_loop
    
.repl_done:
    call exit

.fail_notfound:
    mov rax, E_DIC
    lea rsi, [rip + err_dict_notfound]
    jmp fail
.fail_dict_overflow:
    mov rax, E_DIC
    lea rsi, [rip + err_dict_overflow]
    jmp fail
.fail_div_zero:
    mov rax, E_DIV
    lea rsi, [rip + err_div_zero]
    jmp fail
.fail_stack_underflow:
    mov ax, E_STA
    lea rsi, [rip + err_stack_underflow]
    jmp fail
.fail_stack_overflow:
    mov ax, E_STA
    lea rsi, [rip + err_stack_overflow]
    jmp fail
.fail_token_eof:
    mov rax, E_EOF
    lea rsi, [rip + err_token]
    jmp fail
.fail_token_invalid:
    mov rax, E_SYN
    lea rsi, [rip + err_token_invalid]
    jmp fail
.fail_token_overflow:
    mov rax, E_LEN
    lea rsi, [rip + err_token_len]
    jmp fail


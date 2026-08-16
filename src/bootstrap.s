.intel_syntax noprefix

.equ TOKEN_MAX_LEN, 31

.equ E_EOF, -1
.equ E_LEN, -2
.equ E_DIC, -3
.equ E_SYN, -4
.equ E_DIV, -5

.section .rodata

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
ok_test:
    .asciz "OK\n"

.section .bss

.align 8
data_stack:
    .skip 65536
token_buf:
    .skip 32
io_char:
    .skip 1
write_buf:
    .skip 32
user_dict:
    .skip 65536

.section .data
dictionary:
    .string "^"
    .quad word_dup
    .string "_"
    .quad word_drop
    .string "><"
    .quad word_swap
    .string "<^"
    .quad word_over
    .string ":"
    .quad word_def
    .string ";"
    .quad word_end
    .string "+"
    .quad word_add
    .string "-"
    .quad word_sub
    .string "*"
    .quad word_mul
    .string "/"
    .quad word_div
    .string "."
    .quad word_write
    .string "'"
    .quad word_tick
    .string "~"
    .byte 0 # End of dictionary marker


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
    cmp al, ' ' 
    je .skip_ws
    cmp al, '\t'
    je .skip_ws
    cmp al, '\n'
    je .skip_ws
.next:
    call read_char
    cmp eax, E_EOF
    je .done

    cmp al, ' ' 
    je .done
    cmp al, '\t'
    je .done
    cmp al, '\n'
    je .done

    cmp rcx, TOKEN_MAX_LEN
    jge .fail_token_overflow

    mov byte ptr [rip + token_buf + rcx], al
    inc rcx
    jmp .next

.done:
    # null-terminate
    mov byte ptr [rip + token_buf + rcx], 0
    xor eax, eax
    ret

.fail_token_eof:
    mov rax, E_EOF
    lea rsi, [rip + err_token]
    jmp fail
.fail_token_overflow:
    mov rax, E_LEN
    lea rsi, [rip + err_token_len]
    jmp fail

word_dup:
    sub r15, 8
    mov rax, [r15]
    add r15, 8
    mov [r15], rax
    add r15, 8
    ret

word_drop:
    sub r15, 8
    ret

word_swap:
    mov rax, [r15 - 8]
    mov rdx, [r15 - 16]
    mov [r15 - 16], rax
    mov [r15 - 8], rdx
    ret

word_over:
    mov rax, [r15 - 16]
    mov [r15], rax
    add r15, 8
    ret

word_def:
word_end:
    jmp .fail_notfound

word_add:
    sub r15, 8
    mov rax, [r15]
    sub r15, 8
    add rax, [r15]
    mov [r15], rax
    add r15, 8
    ret

word_sub:
    sub r15, 8
    mov rax, [r15]
    sub r15, 8
    mov rdx, [r15]
    sub rax, rdx
    mov [r15], rax
    add r15, 8
    ret

word_mul:
    sub r15, 8
    mov rax, [r15]
    sub r15, 8
    imul rax, [r15]
    mov [r15], rax
    add r15, 8
    ret

word_write:
    sub r15, 8
    mov rax, [r15]
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
    ret
    
word_div:
    sub r15, 8
    mov rcx, [r15]
    sub r15, 8
    mov rax, [r15]
    cqo
    test rcx, rcx
    jz .fail_div_zero
    idiv rcx # rax = div, rdx = remainder
    mov [r15], rax
    add r15, 8
    ret

word_tick:
    call read_token
    lea rsi, [rip + token_buf]
    call find_word
    jc .fail_notfound

    mov [r15], rax
    add r15, 8
    ret

find_word:
    lea rdi, [rip + dictionary]
    xor ecx, ecx
.find_compare:
    mov al, byte ptr [rsi + rcx]
    cmp al, byte ptr [rdi + rcx]
    jne .find_next

    test al, al
    jz .find_found

    inc rcx
    jmp .find_compare
.find_next:
.find_skip_name:
    cmp byte ptr [rdi + rcx], 0
    je .find_skip_xt
    inc rcx
    jmp .find_skip_name
.find_skip_xt:
    lea rdi, [rdi + rcx + 1]
    add rdi, 8
    # 0 dictionary end marker
    cmp byte ptr [rdi], 0
    je .find_missing
    xor ecx, ecx
    jmp .find_compare
.find_found:
    lea rax, [rdi + rcx + 1]
    mov rax, [rax]
    clc
    ret
.find_missing:
    stc
    ret
    

.global _start
_start:
    lea r14, [rip + user_dict]
    lea r15, [rip + data_stack]

.repl_loop:
    call read_token

    lea rsi, [rip + token_buf]
    call find_word
    jc .try_number

    call rax
    jmp .repl_loop
.try_number:
    lea rsi, [rip + token_buf]
    call parse_int
    jc .fail_notfound

.push_numeric:
    mov [r15], rax
    add r15, 8
    jmp .repl_loop
    
.repl_done:
    call exit

.fail_notfound:
    mov rax, E_DIC
    lea rsi, [rip + err_dict_notfound]
    jmp fail

.fail_token_invalid:
    mov rax, E_SYN
    lea rsi, [rip + err_token_invalid]
    jmp fail

.fail_div_zero:
    mov rax, E_DIV
    lea rsi, [rip + err_div_zero]
    jmp fail

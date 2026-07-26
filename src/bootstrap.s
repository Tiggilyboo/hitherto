.intel_syntax noprefix

.equ TOKEN_MAX_LEN, 31

.equ E_EOF, -1
.equ E_LEN, -2

.section .rodata

err_unknown:
    .asciz "Unknown error occurred\n"
err_token:
    .asciz "Error reading token\n"
err_token_len:
    .asciz "Token length must be less than 31\n"
err_dict_notfound:
    .asciz "Dictionary did not contain token\n"
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

.section .data
dictionary:
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
    
dict_ptr:
    .quad dictionary
    .skip 1

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

read_token:
    xor rcx, rcx
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
    mov byte ptr [rip + token_buf + rcx], al
    inc rcx
    cmp rcx, TOKEN_MAX_LEN
    jge .fail_token_overflow
    jmp .next
.fail_token_eof:
    mov rax, E_EOF
    lea rsi, [rip + err_token]
    jmp fail
.fail_token_overflow:
    mov rax, E_LEN
    lea rsi, [rip + err_token_len]
    jmp fail
.done:
    # null-terminate
    mov byte ptr [rip + token_buf + rcx], 0
    xor eax, eax
    ret

word_def:
word_end:
word_add:
word_sub:
word_mul:
word_write:
word_div:
    lea rsi, [rip + ok_test]
    call len
    mov rdx, rax
    call write
    ret

.global _start
_start:
.repl_loop:
    call read_token
    lea rsi, [rip + token_buf]
    lea rdi, [rip + dictionary]
    xor rcx, rcx
.compare:
    mov al, byte ptr [rsi + rcx] # token char
    cmp al, [rdi + rcx] # dict entry name char
    jne .next_key

    test al, al # both equal, is it null?
    jz .found
    inc rcx
    jmp .compare
.next_key:
    # skip past dict name (until it's null)
.skip_name:
    cmp byte ptr [rdi + rcx], 0
    je .skip_ptr
    inc rcx
    jmp .skip_name
.skip_ptr:
    add rdi, 8
    # check if next entry is empty (end of dictionary)
    cmp byte ptr [rdi], 0
    je .fail_dict_notfound
    xor rcx, rcx # reset token index for next compare
    jmp .repl_loop
.found:
    # rdi = matched entry name
    # code pointer = rdi + rcx + 1
    lea rax, [rdi + rcx + 1]
    mov rax, [rax] # load pointer value
    cmp rax, 0
    call rax
    jmp .repl_loop
    
.repl_done:
    call exit

.fail_dict_notfound:
    mov rax, E_LEN
    lea rsi, [rip + err_dict_notfound]
    jmp fail

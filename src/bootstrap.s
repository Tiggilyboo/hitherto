# Dedicated register association
# rbp = current dict word / execution frame
# rbx = control stack pointer
# r12 = threaded instruction pointer
# r13 = TOS
# r14 = dictionary tail
# r15 = data stack pointer
.intel_syntax noprefix

.equ STATE_EXE, 0
.equ STATE_DEF, 1

.equ TOKEN_MAX_LEN, 31

.equ NODE_CODE, 0
.equ NODE_END,  8
.equ NODE_BODY, 16

.equ CONTROL_MAX,   64

.equ E_EOF, -1
.equ E_LEN, -2
.equ E_DIC, -3
.equ E_SYN, -4
.equ E_DIV, -5
.equ E_STA, -6

.section .rodata

token_dup:
    .asciz "^"
token_drop:
    .asciz "_"
token_swap:
    .asciz "><"
token_over:
    .asciz "<^"
token_ctrl_open:
    .asciz "["
token_ctrl_close:
    .asciz "]"
token_add:
    .asciz "+"
token_sub:
    .asciz "-"
token_mul:
    .asciz "*"
token_div:
    .asciz "/"
token_write:
    .asciz "."
token_tick:
    .asciz "'"
token_sys:
    .asciz "sys"
token_store:
    .asciz "!"
token_load:
    .asciz "@"
token_ign:
    .asciz "#"
token_branch:
    .asciz "?"
token_mask_and:
    .asciz "&"
token_mask_or:
    .asciz "|"
token_eq:
    .asciz "="
token_lt:
    .asciz "<"
token_shl:
    .asciz "<<"
token_shr:
    .asciz ">>"
token_loop:
    .asciz "~["
token_break:
    .asciz "~]"
token_pack:
    .asciz "pack"
token_span:
    .asciz "span"

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
err_token_noclose:
    .asciz "Missing close token\n"
err_token_noopen:
    .asciz "Missing open token\n"
err_div_zero:
    .asciz "Divide by zero\n"
err_stack_underflow:
    .asciz "Stack underflow\n"
err_stack_overflow:
    .asciz "Stack overflow\n"
err_dict_overflow:
    .asciz "Dictionary full\n"
err_state:
    .asciz "Already in define state\n"

.align 8
internal_lit:
    .quad word_lit
internal_branch:
    .quad word_branch_runtime
internal_ctrl_push:
    .quad word_ctrl_push
internal_ctrl_pop:
    .quad word_ctrl_pop
internal_packed_bind:
    .quad word_packed_bind

bootstrap:
    .incbin "src/bootstrap.ht"
bootstrap_end:

.section .bss

.align 8
state:
    .quad 0
reg_data:
    .skip 64
io_char:
    .skip 1
write_buf:
    .skip TOKEN_MAX_LEN
token_buf:
    .skip TOKEN_MAX_LEN + 1

.align 8
ctrl_stack:
    .skip CONTROL_MAX * 8
ctrl_stack_end:
data_stack:
    .skip 65536
data_stack_end:

input_ptr:
    .quad 0
input_end:
    .quad 0

.align 16
dict:
    .skip 131072
dict_end:

.section .text

read_char:
    push rcx

    # Embedded bootstrap input first.
    mov rcx, qword ptr [rip + input_ptr]
    cmp rcx, qword ptr [rip + input_end]
    jae .read_char_stdin

    movzx eax, byte ptr [rcx]
    inc rcx
    mov qword ptr [rip + input_ptr], rcx

    pop rcx
    ret

.read_char_stdin:
    mov eax, 0                    # SYS_read
    xor edi, edi                  # stdin
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

# RSI -> null-terminated token
# returns:
#   RAX = literal value
#   CF=0 success
#   CF=1 not a literal
# literals:
#   123     -> 123
#   -123    -> -123
#   $N      -> $reg_data[N]
parse_literal:
    cmp byte ptr [rsi], '$'
    jne .literal_number

    # Register literal: $N
    inc rsi
    call parse_int
    jc .literal_bad

    # reg_data is currently 8 cells / 64 bytes
    cmp rax, 7
    ja .literal_bad

    lea rcx, [rip + reg_data]
    lea rax, [rcx + rax * 8]

    clc
    ret

.literal_number:
    call parse_int
    ret

.literal_bad:
    stc
    ret

read_token:
    xor rcx, rcx
.skip_ws:
    call read_char
    cmp eax, E_EOF
    je fail_token_eof

    cmp al, ' ' 
    je .skip_ws
    cmp al, '\t'
    je .skip_ws
    cmp al, '\n'
    je .skip_ws
    cmp al, byte ptr [rip + token_ign]
    je .skip_comment
    jmp .next

.skip_comment:
    call read_char
    cmp eax, E_EOF
    je fail_token_eof
    cmp al, '\n'
    jne .skip_comment
    jmp .skip_ws

.next:
    cmp rcx, TOKEN_MAX_LEN
    jge fail_token_overflow

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
    
# rsi = null-terminated name
# rdi = code function pointer
# returns:
#   rax = new global dictionary node
dict_add:
    # Global dictionary's current tail.
    mov rdx, r14

    # Dictionary link?
    test r14, r14
    jz .dict_add_first

    mov r8, [r14 + NODE_END]
    add r8, 8
    jmp .dict_add_node

.dict_add_first:
    lea r8, [rip + dict]
    
.dict_add_node:
    call node_add
    mov r14, rax
    ret

# rsi = null-terminated name
# rdi = code function pointer
# rdx = previous node in this dictionary, 0 if first
# r8  = allocation address if rdx == 0
# returns:
#   rax = new node
#   r8  = physical allocation address
node_add:
    mov rax, r8

    # Measure source name.
    xor ecx, ecx
.node_name_len:
    cmp byte ptr [rsi + rcx], 0
    je .node_name_len_done
    inc rcx
    jmp .node_name_len

.node_name_len_done:
    # Aligned offset immediately after:
    #
    #   packed descriptor (8 bytes)
    #   name bytes
    #
    # align8(8 + len) = (len + 15) & -8
    lea r10, [rcx + 15]
    and r10, -8

    # Payload begins after local-tail qword.
    lea r8, [rax + NODE_BODY + r10 + 8]

    # NODE_END currently equals payload start.
    # Need one more qword for previous-node pointer.
    lea r9, [r8 + 8]
    lea r11, [rip + dict_end]
    cmp r9, r11
    ja fail_dict_overflow

    # Runtime behavior.
    mov [rax + NODE_CODE], rdi

    # Name descriptor:
    #   low32  = 8
    #   high32 = 8 + name length
    mov r11d, ecx
    add r11d, 8
    shl r11, 32
    or r11, 8
    mov [rax + NODE_BODY], r11

    # Copy exact name bytes.
    # No terminating NUL is stored.
    xor r9d, r9d

.node_name_copy:
    cmp r9, rcx
    je .node_name_done

    mov r11b, byte ptr [rsi + r9]
    mov byte ptr [rax + NODE_BODY + 8 + r9], r11b
    inc r9
    jmp .node_name_copy

.node_name_done:
    # Recompute aligned name end.
    lea r10, [rcx + 15]
    and r10, -8

    # New node begins with an empty local dictionary.
    mov qword ptr [rax + NODE_BODY + r10], 0

    # Payload / physical end of this currently-empty node.
    lea r8, [rax + NODE_BODY + r10 + 8]

    mov [rax + NODE_END], r8

    # Link to previous node in whichever dictionary owns this node.
    mov [r8], rdx

    # Return next free byte after the prev-pointer cell.
    add r8, 8
    ret

compile_ctrl_open:
    lea rcx, [rip + ctrl_stack_end]
    cmp rbx, rcx
    jae fail_stack_overflow

    lea rax, [rip + internal_ctrl_push]
    mov [r12], rax

    # runtime region 
    lea rax, [r12 + 16]
    lea rcx, [rbp + NODE_BODY]
    sub rax, rcx

    # start | end
    mov [r12 + 8], eax
    mov dword ptr [r12 + 12], 0

    # comp state = ctrl_stack has descriptor address, not packed value!
    lea rax, [r12 + 8]
    mov [rbx], rax
    add rbx, 8

    add r12, 16
    ret

words:

word_ctrl_open:
    cmp qword ptr [rip + state], STATE_DEF
    je .ctrl_open_nested

    # for now only top level [ must have a named definition
    # no anonymous top level regions yet...
    lea rcx, [rip + ctrl_stack]
    cmp rbx, rcx
    jne fail_state

    call read_token
    lea rsi, [rip + token_buf]

    # require :name
    cmp byte ptr [rsi], ':'
    jne fail_token_invalid
    cmp byte ptr [rsi + 1], 0
    je fail_token_invalid

    # strip ':'
    xor ecx, ecx

.ctrl_name_shift:
    mov al, byte ptr [rsi + rcx + 1]
    mov byte ptr [rsi + rcx], al
    inc rcx
    test al, al
    jne .ctrl_name_shift

    lea rdi, [rip + word_exec]

    # alloc empty dictionary def
    # keep dictionary tail unset until ctrl_close
    push r14
    call dict_add
    mov rbp, rax
    pop r14

    mov rax, rbp
    call node_payload
    mov r12, rax

    mov qword ptr [rip + state], STATE_DEF

    # fall through here, both modes compile ctrl open
.ctrl_open_nested:
    call compile_ctrl_open
    ret

word_ctrl_close:
    cmp qword ptr [rip + state], STATE_DEF
    jne fail_state

    lea r8, [rip + ctrl_stack]
    cmp rbx, r8
    je fail_token_noopen

    # runtime fall-through leaves region
    lea rax, [rip + internal_ctrl_pop]
    mov [r12], rax
    add r12, 8

    # pop compile-time descriptor pointer
    sub rbx, 8
    mov rax, [rbx]

    # r12 = region end
    lea rcx, [rbp + NODE_BODY]
    mov rdx, r12
    sub rdx, rcx

    # end = high 32 bits
    mov [rax + 4], edx

    # if another frame remains, close nested region
    cmp rbx, r8
    jne .ctrl_close_done

    # else: if root, set dictionary word to dedicated registers
    call node_finalize

    mov qword ptr [rip + state], STATE_EXE

.ctrl_close_done:
    ret

word_dup:
    mov [r15], r13
    add r15, 8
    ret

word_drop:
    lea rax, [rip + data_stack]
    cmp r15, rax
    je fail_stack_underflow
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

# rax = dictionary node being executed
word_exec:
    push rbp
    push r12
    push rbx

    mov rbp, rax

    # r12 = start of node payload
    call node_payload
    mov r12, rax

    # Root payload currently begins:
    #   +8  packed root start|end
    mov rax, [r12 + 8]
    shr rax, 32

    lea rcx, [rbp + NODE_BODY]
    lea rax, [rcx + rax]
    push rax

.exec_next:
    cmp r12, [rsp]
    je .exec_done

    mov rax, [r12]
    add r12, 8
    mov rdx, [rax + NODE_CODE]
    call rdx
    jmp .exec_next

.exec_done:
    add rsp, 8
    pop rbx
    pop r12
    pop rbp
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
    lea rsi, [rip + write_buf + TOKEN_MAX_LEN]
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
    lea rdx, [rip + write_buf + TOKEN_MAX_LEN]
    sub rdx, rsi
    call write
    sub r15, 8
    mov r13, [r15]
    ret
    
word_div:
    mov rcx, r13 # divisor = rhs TOS
    test rcx, rcx
    jz fail_div_zero
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
    jc fail_notfound

    mov [r15], r13 # old TOS = NOS
    add r15, 8
    mov r13, rax # XT becomes new TOS
    ret

word_lit:
    # next cell is data not ptr
    mov rax, [r12]
    add r12, 8

    # push lit to dat stack
    mov [r15], r13
    add r15, 8
    mov r13, rax
    ret

# Compile-time only
word_packed:
    cmp qword ptr [rip + state], STATE_DEF
    jne fail_state

    lea rcx, [rip + ctrl_stack]
    cmp rbx, rcx
    je fail_token_noopen

    # control region start
    mov rax, [rbx - 8]
    mov eax, dword ptr [rax]

    lea rcx, [rbp + NODE_BODY]
    lea rdx, [rcx + rax]

    # must being with packed record
    lea rax, [rip + internal_packed_bind]
    cmp qword ptr [rdx], rax
    jne fail_token_invalid

    # only once
    cmp qword ptr [rdx + 24], 0
    jne fail_token_invalid

    # skip to current compiled position (past locals)
    mov rax, r12
    sub rax, rcx
    mov [rdx + 24], rax
    ret

# Runtime:
#  r12 = mutable source qword
#  r12 + 8 = packed mask
#  r12 + 16 = byte offset after inline local nodes
# Pops TOS into source cell, skips compile time local node data embedded in instruction stream
word_packed_bind:
    lea rax, [rip + data_stack]
    cmp r15, rax
    je fail_stack_underflow

    mov [r12], r13
    sub r15, 8
    mov r13, [r15]

    # skip source/mask/local-node data
    mov rax, [r12 + 16]
    lea rcx, [rbp + NODE_BODY]
    lea r12, [rcx + rax]
    ret

# rax = packed-local node
# Push selected value 0 extends to bit 0
word_packed_local:
    call node_payload
    mov rcx, [rax] # source address
    mov rdx, [rax + 8] # mask

    mov rax, [rcx]
    and rax, rdx

    test rdx, rdx
    jz .packed_local_push

    # shift and normalize mask offset
    bsf rcx, rdx
    shr rax, cl

.packed_local_push:
    mov [r15], r13
    add r15, 8
    mov r13, rax
    ret

# [r12] = packed control frame
# CF=0 success
# CF=1 stack full
word_ctrl_push:
    lea rcx, [rip + ctrl_stack_end]
    cmp rbx, rcx
    jae .ctrl_push_full

    mov rax, [r12]
    add r12, 8
    mov [rbx], rax
    add rbx, 8
    clc
    ret
.ctrl_push_full:
    stc
    ret

# RAX = popped packed control frame
# CF=0 success
# CF=1 stack empty
word_ctrl_pop:
    lea rcx, [rip + ctrl_stack]
    cmp rbx, rcx
    je .ctrl_pop_empty

    sub rbx, 8
    mov rax, [rbx]
    clc
    ret
.ctrl_pop_empty:
    stc
    ret

word_loop:
    lea rcx, [rip + ctrl_stack]
    cmp rbx, rcx
    je fail_token_noopen

    # peek start offset
    mov eax, dword ptr [rbx - 8]

    # jump there
    lea rcx, [rbp + NODE_BODY]
    lea r12, [rcx + rax]
    ret

word_break:
    call word_ctrl_pop
    jc fail_token_noopen

    # popped frame: end offset
    shr rax, 32

    # jump there
    lea rcx, [rbp + NODE_BODY]
    lea r12, [rcx + rax]
    ret

word_sys:
    mov rax, [rip + reg_data + 0*8]
    mov rdi, [rip + reg_data + 1*8]
    mov rsi, [rip + reg_data + 2*8]
    mov rdx, [rip + reg_data + 3*8]
    mov r10, [rip + reg_data + 4*8]
    mov r8,  [rip + reg_data + 5*8]
    mov r9,  [rip + reg_data + 6*8]
    syscall
    mov [rip + reg_data + 0*8], rax
    ret

word_load:
    mov r13, [r13]
    ret

word_store:
    sub r15, 8
    mov rax, [r15]
    mov [r13], rax
    sub r15, 8
    mov r13, [r15]
    ret

word_branch:
    cmp qword ptr [rip + state], STATE_DEF
    jne fail_state

    # ? consumes one named word for arm
    call read_token
    lea rsi, [rip + token_buf]
    call find_scope
    jc fail_notfound

    mov rdx, rax # arm cell

    lea rax, [rip + internal_branch]
    mov [r12], rax
    mov [r12 + 8], rdx
    add r12, 16
    ret

word_branch_runtime:
    mov rcx, r13       # flag
    mov r8, [r12]      # arm cell
    add r12, 8         # consume arm cell

    # consume flag
    sub r15, 8
    mov r13, [r15]

    # false: leave branch frame active, continue
    test rcx, rcx
    jz .branch_runtime_done

    # true: leave current [ ... ] region
    # TODO: This might be redesigned when we have better locals / anonymous control regions
    call word_break

    # execute selected arm after branch continuation has been checked
    mov rax, r8
    mov rdx, [rax + NODE_CODE]
    call rdx

.branch_runtime_done:
    ret
    
word_mask_and:
    sub r15, 8
    and r13, [r15]
    ret

word_mask_or:
    sub r15, 8
    or r13, [r15]
    ret

word_eq:
    sub r15, 8
    cmp [r15], r13
    sete r13b
    movzx r13, r13b
    ret

word_lt:
    sub r15, 8
    cmp [r15], r13
    setl r13b
    movzx r13, r13b
    ret

word_shl:
    mov rcx, r13
    sub r15, 8
    mov r13, [r15]
    shl r13, cl
    ret

word_shr:
    mov rcx, r13
    sub r15, 8
    mov r13, [r15]
    shr r13, cl
    ret
    

words_end:

# rdx = node
# returns:
#   rax = name byte address
#   rcx = exact name length
node_name:
    mov r8, [rdx + NODE_BODY]
    # start
    mov eax, r8d
    # end
    shr r8, 32
    # rcx = end - start
    sub r8d, eax
    mov ecx, r8d
    lea rax, [rdx + NODE_BODY + rax]
    ret

node_payload:
    mov rcx, [rax + NODE_BODY]
    shr rcx, 32
    add rcx, 7
    and rcx, -8

    # Skip local-tail qword.
    lea rax, [rax + NODE_BODY + rcx + 8]
    ret

# rax = node
# returns:
#   rax = address of node-local dictionary tail cell
node_locals_ref:
    mov rcx, [rax + NODE_BODY]
    shr rcx, 32
    add rcx, 7
    and rcx, -8

    # Local-tail qword is immediately after aligned name.
    lea rax, [rax + NODE_BODY + rcx]
    ret

# rax = node
# returns:
#   rax = root packed record address
#   CF=0 if node's root region begins with packed
#   CF=0 doesn't
node_packed_record:
    mov rdx, rax
    call node_payload

    # compiled words start with ctrl push function
    lea rcx, [rip + internal_ctrl_push]
    cmp qword ptr [rax], rcx
    jne .node_packed_missing

    # region start byte offset
    mov eax, dword ptr [rax + 8]
    lea rcx, [rdx + NODE_BODY]
    lea rax, [rcx + rax]

    # packed def has it's record at start of root region
    lea rcx, [rip + internal_packed_bind]
    cmp qword ptr [rax], rcx
    jne .node_packed_missing

    clc
    ret
.node_packed_missing:
    stc
    ret

# rax = source node
# returns:
#   rax = mask
node_mask:
    mov rdx, [rax + NODE_CODE]
    lea rcx, [rip + word_packed_local]
    cmp rdx, rcx
    je .node_mask_local

    # should expose full mask without using it (lazy)
    push rax
    call node_packed_record
    jc .node_mask_execute

    mov rax, [rax + 16] # packed record full mask
    add rsp, 8
    ret
.node_mask_execute:
    pop rax
    # ordinary source: execute pop TOS as mask
    mov rdx, [rax + NODE_CODE]
    call rdx

    mov r8, r13
    call word_drop
    mov rax, r8
    ret

.node_mask_local:
    call node_payload
    mov rax, [rax + 8] # applied mask

    # convert mask back to bit-0 form (shifted)
    test rax, rax
    jz .node_mask_done

    bsf rcx, rax
    shr rax, cl

.node_mask_done:
    ret

# rbp = node
# r12 = current physical end
# r14 = previous published dictionary tail
node_finalize:
    mov [rbp + NODE_END], r12
    mov [r12], r14
    mov r14, rbp
    ret

# rsi = null terminated token
# STATE_COMP: Search current node locals first, locals eventally point back to r14
#   From r14 we can continue following through all globals backwards
# STATE_DEF: Search global dict
# returns:
#   rax = matching node
#   CF = 0 found
#   CF = 1 not found
find_scope:
    cmp qword ptr [rip + state], STATE_DEF
    jne .find_scope_global

    mov rax, rbp
    call node_locals_ref
    mov rdx, [rax]

    test rdx, rdx
    jz .find_scope_global

    jmp find_from

.find_scope_global:
    mov rdx, r14
    jmp find_from

# rsi = null-terminated token
# returns:
#   rax = matching node
#   CF=0 found
#   CF=1 not found
find_word:
    mov rdx, r14
    jmp find_from

# rsi = null-terminated token
# rdx = dictionary tail
# returns:
#   rax = matching node
#   CF=0 found
#   CF=1 not found
find_from:
    # token length
    xor r9d, r9d

.find_token_len:
    cmp byte ptr [rsi + r9], 0
    je .find_token_len_done
    inc r9
    jmp .find_token_len

.find_token_len_done:

.find_next:
    test rdx, rdx
    jz .find_missing

    # rax = candidate name address
    # rcx = candidate name length
    call node_name

    cmp rcx, r9
    jne .find_prev

    xor r10d, r10d

.find_compare:
    cmp r10, r9
    je .find_found

    mov cl, byte ptr [rsi + r10]
    cmp cl, byte ptr [rax + r10]
    jne .find_prev

    inc r10
    jmp .find_compare

.find_prev:
    mov rcx, [rdx + NODE_END]
    mov rdx, [rcx]
    jmp .find_next

.find_found:
    mov rax, rdx
    clc
    ret

.find_missing:
    stc
    ret

# rsi = token string in "type:name" pattern
# rcx = index of ':' character
# emits packed local node at r12
# stack format:
#[rsp + 0]   applied mask
#[rsp + 8]   packed record
#[rsp + 16]  provider node
#[rsp + 24]  local-name pointer
compile_packed_local:
    test rcx, rcx
    jz fail_token_invalid

    cmp byte ptr [rsi + rcx + 1], 0
    je fail_token_invalid

    # split token
    mov byte ptr [rsi + rcx], 0
    lea rax, [rsi + rcx + 1]
    push rax # local name

    # resolve source in current scope
    call find_scope
    jc fail_notfound

    push rax # source

    call node_mask
    mov r10, rax # mask

    # control region must exist
    lea rcx, [rip + ctrl_stack]
    cmp rbx, rcx
    je fail_token_noopen

    # region start
    mov rax, [rbx - 8]
    mov eax, dword ptr [rax]

    lea rcx, [rbp + NODE_BODY]
    lea r11, [rcx + rax]

    # reserve packed record
    lea rax, [rip + internal_packed_bind]
    cmp qword ptr [r11], rax
    je .packed_record_exists

    # TODO: Can this restriction be lifted?
    # No code may be before packed declarations
    cmp r12, r11
    jne fail_token_invalid

    mov [r12], rax # internal_packed_bind
    mov qword ptr [r12 + 8], 0 # source
    mov qword ptr [r12 + 16], 0 # full mask
    mov qword ptr [r12 + 24], 0 # end offset
    add r12, 32

.packed_record_exists:
    # finalized packed record has no more declarations
    cmp qword ptr [r11 + 24], 0
    jne fail_token_invalid

    push r11 # packed record

    # dense placement after highest occupied bit of full mask
    mov rax, [r11 + 16]
    xor ecx, ecx

    test rax, rax
    jz .packed_shift_ready

    bsr rcx, rax
    inc rcx

.packed_shift_ready:
    # zero = no bits
    test r10, r10
    jz .packed_mask_zero

    # mask can't do more than qword (yet)
    cmp rcx, 64
    jae fail_token_invalid

    mov r9, r10
    shl r9, cl

    # reject everything after 64 bit word
    mov rax, r9
    shr rax, cl
    cmp rax, r10
    jne fail_token_invalid

    jmp .packed_mask_ready

.packed_mask_zero:
    xor r9d, r9d
.packed_mask_ready:
    or [r11 + 16], r9

    push r9 # applied mask

    # add tail
    mov rax, rbp
    call node_locals_ref

    mov rdx, [rax]
    test rdx, rdx
    jnz .packed_have_prev

    # first local falls through to global ref (so we can continue iterating globals to resolve the name)
    mov rdx, r14

.packed_have_prev:
    # emit local node into compiled body
    mov r8, r12
    mov rsi, [rsp + 24] # local name
    lea rdi, [rip + word_packed_local]
    call node_add

    mov r10, rax # new node
    mov rcx, [r10 + NODE_END]
    mov rdx, [rcx] # prev node

    # node_add prev pointer is at NODE_END, offset to quads to local payload
    lea rax, [rcx + 24]
    lea r11, [rip + dict_end]
    cmp rax, r11
    ja fail_dict_overflow

    # local payload
    mov r11, [rsp + 8] # packed record
    lea r11, [r11 + 8] # source qword
    mov [rcx], r11

    mov r11, [rsp] # applied mask
    mov [rcx + 8], r11

    # new physical end = prev-pointer
    lea r11, [rcx + 16]
    mov [r10 + NODE_END], r11
    mov [r11], rdx

    lea r12, [r11 + 8]

    # inherit nested locals (join refs TODO?)
    mov rax, r10
    call node_locals_ref
    mov r11, rax

    # source node
    mov rax, [rsp + 16]
    call node_locals_ref
    mov rax, [rax]
    mov [r11], rax

    # publish latest local of owning word
    mov rax, rbp
    call node_locals_ref
    mov [rax], r10
    add rsp, 32
    ret

# exe + word => execute
# exe + literal => push
# def + word => compile cell
# def + lit => compile lit + value
eval_token:
    cmp qword ptr [rip + state], STATE_DEF
    jne .eval_lookup

    lea rsi, [rip + token_buf]
    xor ecx, ecx

.eval_colon_scan:
    mov al, byte ptr [rsi + rcx]
    test al, al
    jz .eval_lookup

    cmp al, ':'
    je .eval_packed_local
    inc rcx
    jmp .eval_colon_scan

.eval_packed_local:
    call compile_packed_local
    ret

.eval_lookup:
    lea rsi, [rip + token_buf]
    call find_scope
    jc .eval_literal

    mov rdx, [rax + NODE_CODE]

    cmp qword ptr [rip + state], STATE_EXE
    je .eval_exec

    # state = def
    lea rcx, [rip + word_branch]
    cmp rdx, rcx
    je .eval_exec

    lea rcx, [rip + word_ctrl_open]
    cmp rdx, rcx
    je .eval_exec

    lea rcx, [rip + word_ctrl_close]
    cmp rdx, rcx
    je .eval_exec

    lea rcx, [rip + word_packed]
    cmp rdx, rcx
    je .eval_exec

    # any other word: compile
    mov [r12], rax
    add r12, 8
    ret

.eval_exec:
    call rdx
    ret

.eval_literal:
    cmp qword ptr [rip + state], STATE_DEF
    je .def_literal

    # exe: parse and push literal
    lea rsi, [rip + token_buf]
    call parse_literal
    jc fail_notfound

    mov [r15], r13
    add r15, 8
    mov r13, rax
    ret

.def_literal:
    lea rsi, [rip + token_buf]
    call parse_literal
    jc fail_notfound

    mov rdx, rax
    lea rax, [rip + internal_lit]

    mov [r12], rax
    mov [r12 + 8], rdx
    add r12, 16
    ret
    
.global _start
_start:
    xor r14d, r14d # dict must be null (0) for first node_add call
    lea r15, [rip + data_stack]
    lea rbx, [rip + ctrl_stack]

    # load builtins into dict
.load_builtins:
    # internals
    lea rax, [rip + internal_branch]

    # global
    
    lea rsi, [rip + token_dup]
    lea rdi, [rip + word_dup]
    call dict_add
    lea rsi, [rip + token_drop]
    lea rdi, [rip + word_drop]
    call dict_add
    lea rsi, [rip + token_swap]
    lea rdi, [rip + word_swap]
    call dict_add
    lea rsi, [rip + token_over]
    lea rdi, [rip + word_over]
    call dict_add
    lea rsi, [rip + token_ctrl_open]
    lea rdi, [rip + word_ctrl_open]
    call dict_add
    lea rsi, [rip + token_ctrl_close]
    lea rdi, [rip + word_ctrl_close]
    call dict_add
    lea rsi, [rip + token_add]
    lea rdi, [rip + word_add]
    call dict_add
    lea rsi, [rip + token_sub]
    lea rdi, [rip + word_sub]
    call dict_add
    lea rsi, [rip + token_mul]
    lea rdi, [rip + word_mul]
    call dict_add
    lea rsi, [rip + token_div]
    lea rdi, [rip + word_div]
    call dict_add
    lea rsi, [rip + token_write]
    lea rdi, [rip + word_write]
    call dict_add
    lea rsi, [rip + token_tick]
    lea rdi, [rip + word_tick]
    call dict_add
    lea rsi, [rip + token_sys]
    lea rdi, [rip + word_sys]
    call dict_add
    lea rsi, [rip + token_store]
    lea rdi, [rip + word_store]
    call dict_add
    lea rsi, [rip + token_load]
    lea rdi, [rip + word_load]
    call dict_add
    lea rsi, [rip + token_branch]
    lea rdi, [rip + word_branch]
    call dict_add
    lea rsi, [rip + token_mask_and]
    lea rdi, [rip + word_mask_and]
    call dict_add
    lea rsi, [rip + token_mask_or]
    lea rdi, [rip + word_mask_or]
    call dict_add
    lea rsi, [rip + token_eq]
    lea rdi, [rip + word_eq]
    call dict_add
    lea rsi, [rip + token_lt]
    lea rdi, [rip + word_lt]
    call dict_add
    lea rsi, [rip + token_shl]
    lea rdi, [rip + word_shl]
    call dict_add
    lea rsi, [rip + token_shr]
    lea rdi, [rip + word_shr]
    call dict_add
    lea rsi, [rip + token_loop]
    lea rdi, [rip + word_loop]
    call dict_add
    lea rsi, [rip + token_break]
    lea rdi, [rip + word_break]
    call dict_add
    lea rsi, [rip + token_pack]
    lea rdi, [rip + word_packed]
    call dict_add

    # load embedded bootstrap code
    lea rax, [rip + bootstrap]
    mov [rip + input_ptr], rax

    lea rax, [rip + bootstrap_end]
    mov [rip + input_end], rax

.repl_loop:
    call read_token
    call eval_token
    jmp .repl_loop

fail_notfound:
    mov rax, E_DIC
    lea rsi, [rip + err_dict_notfound]
    jmp fail
fail_dict_overflow:
    mov rax, E_DIC
    lea rsi, [rip + err_dict_overflow]
    jmp fail
fail_div_zero:
    mov rax, E_DIV
    lea rsi, [rip + err_div_zero]
    jmp fail
fail_stack_underflow:
    mov ax, E_STA
    lea rsi, [rip + err_stack_underflow]
    jmp fail
fail_stack_overflow:
    mov ax, E_STA
    lea rsi, [rip + err_stack_overflow]
    jmp fail
fail_token_eof:
    mov rax, E_EOF
    lea rsi, [rip + err_token]
    jmp fail
fail_token_invalid:
    mov rax, E_SYN
    lea rsi, [rip + err_token_invalid]
    jmp fail
fail_token_overflow:
    mov rax, E_LEN
    lea rsi, [rip + err_token_len]
    jmp fail
fail_token_noclose:
    mov rax, E_SYN
    lea rsi, [rip + err_token_noclose]
    jmp fail
fail_token_noopen:
    mov rax, E_SYN
    lea rsi, [rip + err_token_noopen]
    jmp fail
fail_state:
    mov rax, E_SYN
    lea rsi, [rip + err_state]
    jmp fail
        

# Dedicated register association
# rbp = current definition
# rbx = scope stack pointer
# r12 = threaded instruction pointer / compile cursor
# r13 = cached TOS
# r14 = dictionary tail
# r15 = data stack pointer
.intel_syntax noprefix

.equ DICT_SIZE, 131072
.equ DICT_QWORDS, DICT_SIZE / 8

.equ STATE_EXE, 0
.equ STATE_DEF, 1

.equ TOKEN_MAX_LEN, 31

.equ NODE_CODE, 0
.equ NODE_TYPE, 8
.equ NODE_END,  16
.equ NODE_BODY, 24
.equ NODE_IMMEDIATE_MASK, 1
.equ NODE_FLAGS_MASK, 7
.equ NODE_TYPE_MASK, -8

# Max depth of scope stack depth
.equ SCOPE_MAX, 64

.equ SCOPE_TAG_MASK, 7
# Enclosing definition (outside of [)
.equ SCOPE_PARENT_TAG, 1
# Active ~ receiver / accessor context
.equ SCOPE_CONTEXT_TAG, 2
# Active definition receiving emitted code
.equ SCOPE_COMPILE_TAG, 4

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
token_immediate:
    .asciz "immediate"
token_asm:
    .asciz "asm"
token_type:
    .asciz "type"
token_lit:
    .asciz "lit"

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
internal_skip:
    .quad word_skip
internal_native:
    .quad word_native
internal_member_dispatch:
    .quad word_member_dispatch

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
    .skip TOKEN_MAX_LEN

.align 8
scope_stack:
    .skip SCOPE_MAX * 8
scope_stack_end:
data_stack:
    .skip 65536
data_stack_end:

.align 16
dict:
    .skip DICT_SIZE
dict_end:

.section .native,"awx",@progbits
.align 16
native_buf:
    .skip 4096
native_buf_end:
.section .data
native_here:
    .quad native_buf

.section .text

read_char:
    push rcx
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

# rsi = integer bytes
# r9  = byte length
# returns:
#   rax = signed integer
#   CF = 0 success
#   CF = 1 invalid
parse_int:
    xor eax, eax
    xor edi, edi

    test r9, r9
    jz .int_bad

    xor ecx, ecx
    cmp byte ptr [rsi], '-'
    jne .int_loop

    mov edi, 1
    inc rcx

    # '-' alone is invalid
    cmp rcx, r9
    je .int_bad

.int_loop:
    cmp rcx, r9
    je .int_done

    movzx edx, byte ptr [rsi + rcx]

    sub edx, '0'
    cmp edx, 9
    ja .int_bad

    imul rax, rax, 10
    jo .int_bad

    test edi, edi
    jnz .int_negative

    add rax, rdx
    jo .int_bad
    jmp .int_next

.int_negative:
    sub rax, rdx
    jo .int_bad
.int_next:
    inc rcx
    jmp .int_loop
.int_done:
    clc
    ret
.int_bad:
    stc
    ret

# rsi = hex bytes
# r9 = byte length
# returns:
#   rax = byte value
#   CF = 0 success
#   CF = 1 invalid
parse_hex_byte:
    cmp r9, 2
    jne .hex_invalid

    xor eax, eax
    xor ecx, ecx

.hex_next:
    cmp rcx, r9
    je .hex_done

    movzx edx, byte ptr [rsi + rcx]

    cmp dl, '0'
    jb .hex_alpha
    cmp dl, '9'
    jbe .hex_digit

.hex_alpha:
    or dl, 0x20
    cmp dl, 'a'
    jb .hex_invalid
    cmp dl, 'f'
    ja .hex_invalid

    sub dl, 'a' - 10
    jmp .hex_append

.hex_digit:
    sub dl, '0'

.hex_append:
    shl eax, 4
    movzx edx, dl
    or eax, edx

    inc rcx
    jmp .hex_next

.hex_done:
    clc
    ret
.hex_invalid:
    stc
    ret


# rsi = token address
# r9 = token length
# returns:
#  rax = scope address
#  r8 = scope length
#  rsi = member address
#  r9 = member length
#  CF = 0 valid
#  CF = 1 invalid
parse_member:
    xor ecx, ecx

.member_scan:
    cmp rcx, r9
    je .member_invalid

    cmp byte ptr [rsi + rcx], '~'
    je .member_split

    inc rcx
    jmp .member_scan

.member_split:
    # scope non-empty
    test rcx, rcx
    je .member_invalid
    # member must not be empty
    lea rdx, [rcx + 1]
    cmp rdx, r9
    je .member_invalid

    # preserve scope length
    mov r8, rcx
    mov rcx, rdx

.member_tail:
    cmp rcx, r9
    jz .member_done

    # TODO: only one scope member jump for now
    cmp byte ptr [rsi + rcx], '~'
    je .member_invalid

    inc rcx
    jmp .member_tail
    
.member_done:
    mov rax, rsi
    lea rsi, [rsi + r8 + 1]
    sub r9, r8
    dec r9
    clc
    ret
.member_invalid:
    stc
    ret

# rsi = null-terminated token
# returns:
#   rax = literal value
#   CF=0 success
#   CF=1 not a literal
parse_literal:
    test r9, r9
    jz .literal_bad

    cmp byte ptr [rsi], '$'
    jne .literal_number

    # '$' must have a value after it
    cmp r9, 1
    je .literal_bad

    push rsi
    push r9
    inc rsi
    dec r9
    call parse_int
    pop r9
    pop rsi
    jc .literal_bad

    cmp rax, 7
    ja .literal_bad

    lea rcx, [rip + reg_data]
    lea rax, [rcx + rax * 8]

    clc
    ret

.literal_number:
    # needs at least 0x..
    cmp r9, 2
    jb .literal_decimal

    cmp byte ptr [rsi], '0'
    jne .literal_decimal
    cmp byte ptr [rsi + 1], 'x'
    jne .literal_decimal

    push rsi
    push r9
    add rsi, 2
    sub r9, 2
    call parse_hex_byte
    pop r9
    pop rsi
    ret

.literal_decimal:
    call parse_int
    ret
.literal_bad:
    stc
    ret

# rsi = token address
# r9 = token length
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

    # quote belongs to the next word, do not consume next
    cmp al, '"'
    je .single
    jmp .next

.skip_comment:
    call read_char
    cmp eax, E_EOF
    je fail_token_eof
    cmp al, '\n'
    jne .skip_comment
    jmp .skip_ws

.single:
    mov byte ptr [rip + token_buf], al
    lea rsi, [rip + token_buf]
    mov r9d, 1
    xor eax, eax
    ret

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
    lea rsi, [rip + token_buf]
    mov r9, rcx
    xor eax, eax
    ret

# rsi = declaration bytes
# r9 = declaration length
# returns:
#   rax = type address, 0 if none
#   r8 = type length, 0 if none
#   rsi = name address
#   r9 = name length
#   CF = 0 valid
#   CF = 1 invalid
parse_declaration:
    xor ecx, ecx
.decl_scan:
    cmp rcx, r9
    jz .decl_invalid

    cmp byte ptr [rsi + rcx], ':'
    je .decl_colon

    inc rcx
    jmp .decl_scan

.decl_colon:
    # name must contain at least one byte
    lea rdx, [rcx + 1]
    cmp rdx, r9
    jae .decl_invalid

    # type span
    mov rax, rsi
    mov r8, rcx

    # name span
    lea rsi, [rsi + rcx + 1]
    sub r9, rcx
    dec r9

    # no type
    test r8, r8
    jnz .decl_done

    xor eax, eax
.decl_done:
    clc
    ret
    
.decl_invalid:
    stc
    ret

# rax = type address, 0 if none
# r8 = type length
# rsi = declaration name address
# r9 = declaration name length
# returns:
#  rdx = resolved type node, 0 if none
resolve_declaration_type:
    xor edx, edx

    test rax, rax
    jz .resolve_decl_done

    push rsi
    push r9
    mov rsi, rax
    mov r9, r8
    call find_scope
    pop r9
    pop rsi
    jc fail_notfound

    mov rdx, rax
.resolve_decl_done:
    ret

    
# rsi = name address
# r9 = name length
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

# rsi = name address null terminated
# rdi = code function pointer
# returns:
#   rsi = name address
#   r9 = name length
# overload for dict_add for length resolution from asciz
dict_add_z:
    push rdi
    call len
    pop rdi
    mov r9, rax
    jmp dict_add

# rsi = name address
# r9 = name length
# rdi = code function pointer
# rdx = previous node in this dictionary, 0 if first
# r8  = allocation address if rdx == 0
# returns:
#   rax = new node
#   r8  = physical allocation address
node_add:
    mov rax, r8
    mov rcx, r9

    # align end of name + descriptor
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

    mov qword ptr [rax + NODE_TYPE], 0

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
    lea rcx, [rip + scope_stack_end]
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

    # comp state = scope_stack has descriptor address, not packed value!
    lea rax, [r12 + 8]
    mov [rbx], rax
    add rbx, 8

    add r12, 16
    ret

# rbp = parent scope node
# r12 = parent physical compile end
# rsi = name address
# r9 = name length
# rdi = child code pointer
# returns:
#  rax = unpublished child node
#  r10 = parent's internal_skip patch cell
# clobbers:
#  rcx, rdx, r8, r9, r11
compile_child_declaration:
    # skip inline child node
    lea rax, [rip + internal_skip]
    mov [r12], rax

    lea rax, [r12 + 8]
    mov qword ptr [rax], 0

    # preserve skip patch for node_add
    push rax

    add r12, 16
    # inline child 
    mov r8, r12

    # link current tail of parent scope dict
    mov rax, rbp
    call node_locals_ref
    mov rdx, [rax]

    call node_add

    pop r10
    ret

# rbp = child node
# r12 = child physical end
# r9 = parent scope node
# r10 = parent internal_skip patch cell
# returns:
#  rbp = parent
# r12 = parent compile resumes
compile_child_publish:
    # prev tail of parent's scope dict
    mov rax, r9
    call node_locals_ref
    mov r11, rax
    mov rdx, [rax]

    call node_finalize
    mov [r11], rbp

    # resume after child's prev-pointer
    add r12, 8

    # patch internal skip
    mov rax, r12
    lea rcx, [r9 + NODE_BODY]
    sub rax, rcx
    mov [r10], rax

    mov rbp, r9
    ret

.macro SIGNATURE_POSITION_COUNT dst, tmp, header
    mov \dst, [\header]
    mov \tmp, \dst
    and \dst, 0xf # input count
    shr \tmp, 4
    and \tmp, 0xf # output count
    add \dst, \tmp
.endm
.macro SIGNATURE_LOCAL_COUNT dst, header
    mov \dst, [\header]
    shr \dst, 8
    and \dst, 0xf
.endm
.macro NODE_NAME_ALIGNED_SIZE dst, node
    mov \dst, [\node + NODE_BODY]
    shr \dst, 32
    add \dst, 7
    and \dst, -8
.endm

# rax = signature header address
# rdx = local slot 0..7
signature_append_ref:
    SIGNATURE_POSITION_COUNT rcx, r8, rax
    cmp rcx, 8
    jae fail_token_invalid

    # refs start at 12, each 3 bits
    lea ecx, [rcx + rcx * 2 + 12]
    shl rdx, cl
    or [rax], rdx
    ret

# rax = signature header
# fails if all slots used
signature_require_position:
    SIGNATURE_POSITION_COUNT rcx, r8, rax
    cmp rcx, 8
    jae fail_token_invalid
    ret

# rsi/r9 = local name
# rdx = type node or 0
# rdi = header count delta: 0x101 = input & local count, 0x110 output + local count
# returns:
#   r10 = allocated slot
signature_declare_local:
    push rdi
    push rdx
    # check duplicate
    call find_current_local
    pop rdx
    jnc fail_token_invalid

    NODE_NAME_ALIGNED_SIZE rcx, rbp
    lea rax, [rbp + NODE_BODY + rcx + 8]

    call signature_require_position
    SIGNATURE_LOCAL_COUNT r10, rax

    push r10
    call compile_local
    pop r10

    NODE_NAME_ALIGNED_SIZE rcx, rbp
    lea rax, [rbp + NODE_BODY + rcx + 8]

    mov rdx, r10
    call signature_append_ref

    pop rdi
    add qword ptr [rax], rdi
    ret

# r10 = existing local slot
# rdi = address of parser output slot mask
signature_reuse_output:
    NODE_NAME_ALIGNED_SIZE rcx, rbp
    lea rax, [rbp + NODE_BODY + rcx + 8]

    call signature_require_position

    bt qword ptr [rdi], r10
    jc fail_token_invalid
    bts qword ptr [rdi], r10

    mov rdx, r10
    call signature_append_ref
    add qword ptr [rax], 0x10 # output only (already defined)
    ret

# rbp = def
# r12 = first free qword after signature header
# '(' already consumed
# returns:
#   r12 = first free qword after local definitions in signature header
compile_signature:
    push 0 # parser output slot mask

.signature_inputs:
    call read_token
    # '--' switch to outputs
    cmp r9, 2
    jne .signature_input
    cmp word ptr [rsi], 0x2d2d
    je .signature_outputs

.signature_input:
    # must declare new local
    call parse_declaration
    jc fail_token_invalid

    call resolve_declaration_type

    mov edi, 0x101
    call signature_declare_local
    jmp .signature_inputs

.signature_outputs:
    call read_token
    # ')' ends signature
    cmp r9, 1
    jne .signature_output
    cmp byte ptr [rsi], ')'
    je .signature_done

.signature_output:
    # new declaration: create output local
    # else: reuse existing
    call parse_declaration
    jc .signature_output_reuse

    call resolve_declaration_type

    mov edi, 0x110
    call signature_declare_local

    # a new output local cannot already exist
    # later refs to this must be rejected
    bts qword ptr [rsp], r10
    jmp .signature_outputs

.signature_output_reuse:
    call find_current_local
    jc fail_notfound

    call node_local_binding
    mov r10, rax
    and r10d, 7
    
    lea rdi, [rsp]
    call signature_reuse_output
    jmp .signature_outputs

.signature_done:
    add rsp, 8
    ret

# rbp = newly-created word_exec definition
# r12 = first free qword after zeroed signature header
# STATE_DEF is active
compile_definition_open:
    call read_token

    # Optional signature starts with '('.
    cmp r9, 1
    jne .definition_body
    cmp byte ptr [rsi], '('
    jne .definition_body

    call compile_signature

    # Signature parser consumed ')'.
    # Code begins after all local definitions.
    mov rax, rbp
    call node_exec_set_code_start
    call compile_ctrl_open
    ret

.definition_body:
    # No signature. We consumed the first body token,
    # so establish executable start/control then evaluate it.
    mov rax, rbp
    call node_exec_set_code_start
    call compile_ctrl_open
    call eval_token
    ret

# rbp = owning node
# r12 = next free physical qword
# rsi = local name
# r9 = local name len
# rdx = declared type node, or 0 for anonymous
# r10 = local slot 0..7
# returns:
#   rax = published signature local node
#   r12 = next free qword after local node
compile_local:
    # node_add needs rdx for the previous local node.
    push rdx
    push r10

    # push parent local dictionary tail
    mov rax, rbp
    call node_locals_ref
    push rax

    mov rdx, [rax]
    mov r8, r12
    lea rdi, [rip + word_local]
    call node_add

    # +16 = type
    mov rcx, [rsp + 16]
    mov [rax + NODE_TYPE], rcx

    # node_add leaves NODE_END at payload start
    # overwrite previous node cell with: parent pointer | slot
    mov rcx, [rax + NODE_END]
    mov r11, rbp
    or r11, [rsp + 8] # slot
    mov [rcx], r11

    # node_add's prev-node cell is overwritten => local binding
    # node_finalize will add one back later
    mov rcx, [rax + NODE_END]
    mov r11, rbp
    or r11, [rsp + 8]
    mov [rcx], r11

    # local payload
    mov r9, rbp
    mov rbp, rax
    lea r12, [rcx + 8]

    mov rcx, [rsp] # parent local tail cell
    mov rdx, [rcx]
    call node_finalize

    mov rbp, r9

    # publish to local node dictionary
    mov rcx, [rsp]
    mov [rcx], rax
    add r12, 8 # prev-node from finalize is [r12]
    add rsp, 24

    # note that we don't use internal_skip here:
    # signature locals are before code_start
    # no skip needed.
    ret

words:

word_ctrl_open:
    cmp qword ptr [rip + state], STATE_DEF
    je .ctrl_open_nested

    # for now only top level [ must have a named definition
    # no anonymous top level regions yet...
    lea rcx, [rip + scope_stack]
    cmp rbx, rcx
    jne fail_state

    call read_token
    call parse_declaration
    jc fail_token_invalid

    call resolve_declaration_type
    # rsi = name, rdx = type node or 0

    lea rdi, [rip + word_exec]
    # dict_add clobbers rdx
    push rdx
    push r14
    call dict_add
    pop r14
    pop rdx

    mov [rax + NODE_TYPE], rdx
    mov rbp, rax
    
    call node_exec_header_init

    mov qword ptr [rip + state], STATE_DEF

    call compile_definition_open

    call compile_ctrl_open
    ret

    # fall through here, both modes compile ctrl open
.ctrl_open_nested:
    # next token figures out : anonymous control region or scoped def
    call read_token
    call parse_declaration
    jc .ctrl_open_anonymous

    call resolve_declaration_type
    # rsi = name, rdx = type node or 0

    # reserve skip patch ref and tagged parent
    lea rcx, [rip + scope_stack_end]
    lea rax, [rbx + 16]
    cmp rax, rcx
    ja fail_stack_overflow

    lea rdi, [rip + word_exec]
    push rdx
    call compile_child_declaration
    pop rdx

    # rax = child node
    # r10 = parent's skip patch
    mov [rax + NODE_TYPE], rdx

    mov [rbx], r10
    add rbx, 8

    mov rdx, rbp
    or rdx, SCOPE_PARENT_TAG
    mov [rbx], rdx
    add rbx, 8

    # compile into child
    mov rbp, rax

    call node_exec_header_init
    call compile_definition_open
    ret
.ctrl_open_anonymous:
    call compile_ctrl_open
    # we already consumed in parse_declaration for lookahead, process it here
    call eval_token
    ret

word_ctrl_close:
    cmp qword ptr [rip + state], STATE_DEF
    jne fail_state

    lea r8, [rip + scope_stack]
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

    # nothing underneath: root of global def
    cmp rbx, r8
    je .ctrl_close_global

    # tagged entry underneath: root of child def
    test qword ptr [rbx - 8], SCOPE_PARENT_TAG
    jnz .ctrl_close_child

    # anonymouse control region, nothing to do
    ret
.ctrl_close_global:
    mov rdx, r14
    call node_finalize
    mov r14, rbp
    mov qword ptr [rip + state], STATE_EXE
    ret
.ctrl_close_child:
    mov r9, [rbx - 8]
    and r9, -2
    mov r10, [rbx - 16]
    # consume skip-ref + tagged parent
    sub rbx, 16
    call compile_child_publish
    ret

# [r12] = byte offset relative to rbp + NODE_BODY
# Skip arbitrary inline compile-time data
# ie. These bytes are compiler data, not threaded instructions
word_skip:
    mov rax, [r12]
    lea rcx, [rbp + NODE_BODY]
    lea r12, [rcx + rax]
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
    # did this invocation establish the compile target?
    push 0

    # if compile-time code in definition, preserve the definition being defined
    cmp qword ptr [rip + state], STATE_DEF
    jne .exec_target_ready

    # nested calls from an immediate reuses the existing target
    mov r10, rax
    call scope_compile_target
    mov rax, r10
    jnc .exec_target_ready

    # rbp = definition being compiled
    # no target, save current r12 compile cursor
    mov [rbp + NODE_END], r12

    lea rcx, [rip + scope_stack_end]
    cmp rbx, rcx
    jae fail_stack_overflow

    mov rdx, rbp
    or rdx, SCOPE_COMPILE_TAG
    mov [rbx], rdx
    add rbx, 8

    mov qword ptr [rsp], 1
.exec_target_ready:
    mov rbp, rax
    call node_exec_start

.exec_next:
    cmp r12, [rbp + NODE_END]
    je .exec_done

    mov rax, [r12]
    add r12, 8
    mov rdx, [rax + NODE_CODE]
    call rdx
    jmp .exec_next

.exec_done:
    # if compile target modified NODE_END for compile time emission
    cmp qword ptr [rsp], 0
    je .exec_restore

    # stack: rsp + 24 = saved rbp compile target
    mov rax, [rsp + 24]
    mov rax, [rax + NODE_END]
    mov [rsp + 16], rax

.exec_restore:
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

# Waaaait, why lit and compile_lit?
# Emits TOS as a runtime literal into the active compile target (word)
word_compile_lit:
    call scope_compile_target
    jc fail_state

    # rax = definition being compiled
    mov rcx, [rax + NODE_END]
    lea rdx, [rip + internal_lit]
    mov [rcx], rdx
    mov [rcx + 8], r13
    add rcx, 16

    # advance stored compile cursor
    mov [rax + NODE_END], rcx

    sub r15, 8
    mov r13, [r15]
    ret

# [r12] = native entry address
word_native:
    mov rax, [r12]
    add r12, 8
    # we entered from invoked call, must jump
    jmp rax 

# [r12] = packed control frame
word_ctrl_push:
    lea rcx, [rip + scope_stack_end]
    cmp rbx, rcx
    jae fail_stack_overflow

    mov rax, [r12]
    add r12, 8
    mov [rbx], rax
    add rbx, 8
    ret

# RAX = popped packed control frame
# CF=0 success
# CF=1 stack empty
word_ctrl_pop:
    lea rcx, [rip + scope_stack]
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
    lea rcx, [rip + scope_stack]
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

word_immediate:
    cmp qword ptr [rip + state], STATE_DEF
    jne fail_state
    or qword ptr [rbp + NODE_TYPE], NODE_IMMEDIATE_MASK
    ret

# [ 0x12 0x23 0x34 asm ]
# Immediate: Consumes all words in the scope
word_asm:
    cmp qword ptr [rip + state], STATE_DEF
    jne fail_state

    lea rcx, [rip + scope_stack]
    cmp rbx, rcx
    je fail_token_noopen

    # top scope entry is current scope
    mov rax, [rbx - 8]
    mov eax, dword ptr [rax]
    lea rcx, [rbp + NODE_BODY]

    # compiled litral iterator
    lea r8, [rcx + rax]
    mov r9, r12 # current end

    # native entry
    mov r10, [rip + native_here]
    # native write cursor
    mov r11, r10 

    lea rdx, [rip + internal_lit]
.asm_next:
    cmp r8, r9
    je .asm_ret
    ja fail_token_invalid

    # validate: either lit or qword value
    cmp qword ptr [r8], rdx
    jne fail_token_invalid

    # must be a byte
    mov rax, [r8 + 8]
    cmp rax, 255
    ja fail_token_invalid

    lea rcx, [rip + native_buf_end]
    cmp r11, rcx
    # TODO: Better error
    jae fail_dict_overflow

    mov [r11], al
    inc r11

    add r8, 16
    jmp .asm_next

.asm_ret:
    # ret to threaded caller
    lea rcx, [rip + native_buf_end]
    cmp r11, rcx
    jae fail_dict_overflow

    mov byte ptr [r11], 0xc3
    inc r11
    mov [rip + native_here], r11

.asm_consume:
    # reset region body start
    mov rax, [rbx - 8]
    mov eax, dword ptr [rax]
    lea rcx, [rbp + NODE_BODY]
    lea r12, [rcx + rax]

    # replace literals with: internal_native entry addresses
    lea rax, [rip + internal_native]
    mov [r12], rax
    mov [r12 + 8], r10
    add r12, 16
    ret

word_type:
    call scope_target
    jc fail_state
    call node_type

    mov [r15], r13
    add r15, 8
    mov r13, rax
    ret

# [r12]   = scope node (context for a qualified ~ call) or 0 (use the current context)
# [r12+8] = S, the statically-resolved member node (source of the member name and the
#           no-context fallback)
#
# Qualified (scope != 0): establish the scope as the active context, run S, restore.
# Plain (scope == 0): dispatch S by name from the innermost active context so that an
#        inherited implementation resolves overridden members from the original context.
#        With no active context it runs S directly (static behavior).
word_member_dispatch:
    mov rax, [r12]          # scope or 0
    mov r11, [r12 + 8]      # S
    add r12, 16

    test rax, rax
    jz .md_plain

    # qualified member call: push context, run scope node, pop
    lea rcx, [rip + scope_stack_end]
    cmp rbx, rcx
    jae fail_stack_overflow

    or rax, SCOPE_CONTEXT_TAG
    mov [rbx], rax
    add rbx, 8

    mov rax, r11             # word_exec takes the node to run in rax
    mov rdx, [r11 + NODE_CODE]
    call rdx

    sub rbx, 8
    ret

.md_plain:
    call scope_context
    test rax, rax
    jz .md_run_s

    # name from the statically-resolved node
    mov r10, rax            # context
    mov rdx, r11            # scope
    call node_name          # rax = name addr, rcx = name len
    mov rsi, rax
    mov r9, rcx
    mov r8, r10
    call find_scope_local
    jnc .md_run             # override found in context's chain

    # not found: fall back to the statically-resolved node
.md_run_s:
    mov rax, r11
.md_run:
    mov rdx, [rax + NODE_CODE]
    call rdx
    ret

word_local:
    jmp fail_state

words_end:

# rdx = node
# returns:
#   rax = name byte address
#   rcx = exact name length
node_name:
    mov rcx, [rdx + NODE_BODY]
    # start
    mov eax, ecx
    # end - start
    shr rcx, 32
    sub ecx, eax

    lea rax, [rdx + NODE_BODY + rax]
    ret

# rax = created word_exec node
# returns:
#  r12 = first free qword after signature header
node_exec_header_init:
    NODE_NAME_ALIGNED_SIZE rcx, rax

    # node_add places a temporary previous node pointer here
    # node_finalize will re-write it at the finalize step
    lea r12, [rax + NODE_BODY + rcx + 8]
    mov qword ptr [r12], 0
    add r12, 8
    ret

# rax = word_exec node
# r12 = first executable threaded qword
node_exec_set_code_start:
    NODE_NAME_ALIGNED_SIZE rcx, rax

    # rcx = signature header
    lea rcx, [rax + NODE_BODY + rcx + 8]

    # 36..49 = start offset in qwords from NODE_BODY
    mov rdx, r12
    lea r11, [rax + NODE_BODY]
    sub rdx, r11
    shr rdx, 3

    cmp rdx, DICT_QWORDS - 1
    ja fail_dict_overflow

    shl rdx, 36
    or [rcx], rdx
    ret

# rax = word_exec node
# returns:
#  r12 = first threaded instruction in code payload
node_exec_start:
    NODE_NAME_ALIGNED_SIZE rcx, rax

    # word_exec payload begins with signature header
    mov rdx, [rax + NODE_BODY + rcx + 8]

    shr rdx, 36
    and edx, DICT_QWORDS - 1
    lea rcx, [rax + NODE_BODY]
    lea r12, [rcx + rdx * 8]
    ret

# rax = node
# returns:
#   rax = address of node-local dictionary tail cell
node_locals_ref:
    NODE_NAME_ALIGNED_SIZE rcx, rax
    lea rax, [rax + NODE_BODY + rcx]
    ret

# rax = signature local node
# returns:
#  rax = packed owner | slot (0..7)
node_local_binding:
    NODE_NAME_ALIGNED_SIZE rcx, rax
    mov rax, [rax + NODE_BODY + rcx + 8]
    ret

# rax = node
# returns:
#   rax = node type, 0 for none
node_type:
    mov rax, [rax + NODE_TYPE]
    and rax, NODE_TYPE_MASK
    ret

# rbp = node
# r12 = current physical end
# rdx = previous node in owning dictionary
node_finalize:
    mov [rbp + NODE_END], r12
    mov [r12], rdx
    ret

# returns:
#  rax = target node
#  CF = 0 found
#  CF = 1 not
scope_target:
    mov rcx, rbx
    lea rdx, [rip + scope_stack] 

.scope_target_next:
    cmp rcx, rdx
    je .scope_target_missing
    sub rcx, 8
    mov rax, [rcx]

    test rax, SCOPE_CONTEXT_TAG
    jz .scope_target_next

    and rax, -8
    clc
    ret
.scope_target_missing:
    stc
    ret

# r8 = scope node
# rsi = name address
# r9 = name address
# Search order: scope children, scope's type children, type chain
# returns:
#   rax = matching node
#   CF = 0 found
#   CF = 1 not found
# clobbers:
#   rax, rcx, rdx, r8, r10
find_scope_local:
.scope_local_next:
    mov rax, r8
    call node_locals_ref
    mov rdx, [rax]

    test rdx, rdx
    jz .scope_local_type

    call find_dict
    jnc .scope_local_done

.scope_local_type:
    mov rax, r8
    call node_type

    test rax, rax
    jz .scope_local_missing

    mov r8, rax
    jmp .scope_local_next

.scope_local_done:
    ret
.scope_local_missing:
    stc
    ret

# rbp = parent to local definition
# rsi = name
# r9 = name len
# returns:
#   rax = matching direct local def
#   CF = 0 found
#   CF = 1 not found
# NOTE: Purposely does not look outside defining parent
find_current_local:
    mov rax, rbp
    call node_locals_ref
    mov rdx, [rax]
    jmp find_dict

# returns:
#   rax = context node of the innermost active qualified member call, 0 if none
scope_context:
    mov rcx, rbx
    lea rdx, [rip + scope_stack]

.context_next:
    cmp rcx, rdx
    je .recv_missing
    sub rcx, 8
    mov rax, [rcx]

    test rax, SCOPE_CONTEXT_TAG
    jz .context_next

    and rax, -8
    ret
.recv_missing:
    xor rax, rax
    ret

# returns:
#   rax = node currently receiving compile time output
#   CF = 0 found
#   CF = 1 not found
scope_compile_target:
    mov rcx, rbx
    lea rdx, [rip + scope_stack]
.compile_target_next:
    cmp rcx, rdx
    je .compile_target_missing
    sub rcx, 8
    mov rax, [rcx]

    test rax, SCOPE_COMPILE_TAG
    jz .compile_target_next

    and rax, -8
    clc
    ret
.compile_target_missing:
    stc
    ret

    ret

# rsi = name address
# r9 = name length
# returns:
#   rax = matching node
#   r10 = 1 if context member, 0 if static
#   CF = 0 found
#   CF = 1 not found
find_scope:
    cmp qword ptr [rip + state], STATE_DEF
    jne .find_scope_root

    mov r11, rbx

    # current word is static
    mov r8, rbp
    call find_scope_local
    jnc .find_scope_static

# find immediate defining scope
.find_scope_parent:
    lea rcx, [rip + scope_stack]
    cmp r11, rcx
    je .find_scope_root

    sub r11, 8
    mov rax, [r11]

    test rax, SCOPE_PARENT_TAG
    jz .find_scope_parent

    and rax, -8
    mov r8, rax

    # parent's scope is overrideable
    call find_scope_local
    jnc .find_scope_virtual

    # anything further out is normal lookup
.find_scope_outer:
    lea rcx, [rip + scope_stack]
    cmp r11, rcx
    je .find_scope_root

    sub r11, 8
    mov rax, [r11]

    test rax, SCOPE_PARENT_TAG
    jz .find_scope_outer

    and rax, -8
    mov r8, rax

    call find_scope_local
    jc .find_scope_outer

.find_scope_static:
    mov r10d, 0
    ret
.find_scope_virtual:
    mov r10d, 1
    ret
.find_scope_root:
    mov rdx, r14
    call find_dict
    # preserve CF from find_dict
    mov r10d, 0
    ret

# rsi = name address
# r9 = name length
# returns:
#   rax = matching node
#   CF=0 found
#   CF=1 not found
find_word:
    mov rdx, r14
    jmp find_dict

# rsi = name address
# r9 = name length
# rdx = dictionary tail
# Searches one dictionary chain
# returns:
#   rax = matching node
#   CF=0 found
#   CF=1 not found
find_dict:
.find_dict_next:
    test rdx, rdx
    jz .find_missing

    call node_name
    # rax = name
    # rcx = name length

    cmp rcx, r9
    jne .find_dict_prev

    xor r10d, r10d

.find_dict_compare:
    cmp r10, r9
    je .find_found

    mov cl, byte ptr [rsi + r10]
    cmp cl, byte ptr [rax + r10]
    jne .find_dict_prev

    inc r10
    jmp .find_dict_compare

.find_dict_prev:
    mov rcx, [rdx + NODE_END]
    mov rdx, [rcx]
    jmp .find_dict_next

.find_found:
    mov rax, rdx
    clc
    ret
.find_missing:
    stc
    ret

# exe + word => execute
# exe + literal => push
# def + word => compile cell
# def + lit => compile lit + value
eval_token:
    call find_scope
    jnc .eval_word

    # then try scope~member
    call parse_member
    jc .eval_literal

    # rax = context name
    # r8 = context name len
    # rsi = member name
    # r9 = member name len

    push rsi
    push r9
    mov rsi, rax
    mov r9, r8
    call find_scope
    pop r9
    pop rsi
    jc fail_notfound

    # resolve member through context chain
    mov r8, rax
    push r8
    call find_scope_local
    pop r8
    jc fail_notfound

    # rax = resolved member
    # r8 = original context node
    jmp .eval_qualified

.eval_word:
    mov rdx, [rax + NODE_CODE]
    cmp qword ptr [rip + state], STATE_EXE
    je .eval_exec

    # def: execute immediates
    test qword ptr [rax + NODE_TYPE], NODE_IMMEDIATE_MASK
    jnz .eval_exec

    # r10 = 1 means it was resolved with override
    test r10, r10
    jz .eval_compile_static

    # Resolve member from context if one exists
    lea rdx, [rip + internal_member_dispatch]
    mov [r12], rdx
    mov qword ptr [r12 + 8], 0
    mov [r12 + 16], rax
    add r12, 24
    ret

.eval_compile_static:
    mov [r12], rax
    add r12, 8
    ret

.eval_qualified:
    # rax = member node
    # r8 = scope node
    cmp qword ptr [rip + state], STATE_EXE
    je .eval_qualified_exec

    test qword ptr [rax + NODE_TYPE], NODE_IMMEDIATE_MASK
    jnz .eval_qualified_exec

    # def: compile a qualified member call
    lea rdx, [rip + internal_member_dispatch]
    mov [r12], rdx
    mov [r12 + 8], r8
    mov [r12 + 16], rax
    add r12, 24
    ret

.eval_qualified_exec:
    # EXE: establish x as the active context, run scope node, restore
    lea rcx, [rip + scope_stack_end]
    cmp rbx, rcx
    jae fail_stack_overflow

    or r8, SCOPE_CONTEXT_TAG
    mov [rbx], r8
    add rbx, 8

    mov rdx, [rax + NODE_CODE]
    call rdx

    sub rbx, 8
    ret

.eval_exec:
    call rdx
    ret

.eval_literal:
    cmp qword ptr [rip + state], STATE_DEF
    je .def_literal

    # exe: parse and push literal
    call parse_literal
    jc fail_notfound

    mov [r15], r13
    add r15, 8
    mov r13, rax
    ret

.eval_declaration:
    call parse_declaration
    jc fail_notfound

    # declaration must be typed
    test rax, rax
    jz fail_token_invalid

    call resolve_declaration_type
    # rdx = type node
    # rsi/r9 = declaration name

    push rdx
    push rbp

    lea rdi, [rip + word_exec]
    call compile_child_declaration

    # stack: parent, +8 type
    mov rcx, [rsp + 8]
    mov [rax + NODE_TYPE], rcx

    # r10 = parent skip patch
    push r10

    # child is now physical compilation context
    mov rbp, rax

    call node_exec_header_init
    call compile_definition_open

    # push constructor target
    lea rcx, [rip + scope_stack_end]
    cmp rbx, rcx
    jae fail_stack_overflow

    mov rax, rbp
    or rax, SCOPE_CONTEXT_TAG
    mov [rbx], rax
    add rbx, 8

    # exec the type as a constructor
    # stack:
    #  [rsp] = skip patch
    #  [rsp + 8] = parent
    #  [rsp + 16] = type
    mov rax, [rsp + 16]
    mov rdx, [rax + NODE_CODE]
    call rdx

    # constructor should leave scope balanced
    sub rbx, 8

    # restore child publication context (no longer target scope)
    pop r10
    pop r9
    # discard saved type
    add rsp, 8 

    call compile_child_publish
    ret

.def_literal:
    call parse_literal
    jc .eval_declaration

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
    lea rbx, [rip + scope_stack]

    # load builtins into dict
.load_builtins:
    # internals
    lea rax, [rip + internal_branch]

    # global
    lea rsi, [rip + token_dup]
    lea rdi, [rip + word_dup]
    call dict_add_z
    lea rsi, [rip + token_drop]
    lea rdi, [rip + word_drop]
    call dict_add_z
    lea rsi, [rip + token_swap]
    lea rdi, [rip + word_swap]
    call dict_add_z
    lea rsi, [rip + token_over]
    lea rdi, [rip + word_over]
    call dict_add_z
    lea rsi, [rip + token_add]
    lea rdi, [rip + word_add]
    call dict_add_z
    lea rsi, [rip + token_sub]
    lea rdi, [rip + word_sub]
    call dict_add_z
    lea rsi, [rip + token_mul]
    lea rdi, [rip + word_mul]
    call dict_add_z
    lea rsi, [rip + token_div]
    lea rdi, [rip + word_div]
    call dict_add_z
    lea rsi, [rip + token_write]
    lea rdi, [rip + word_write]
    call dict_add_z
    lea rsi, [rip + token_tick]
    lea rdi, [rip + word_tick]
    call dict_add_z
    lea rsi, [rip + token_sys]
    lea rdi, [rip + word_sys]
    call dict_add_z
    lea rsi, [rip + token_store]
    lea rdi, [rip + word_store]
    call dict_add_z
    lea rsi, [rip + token_load]
    lea rdi, [rip + word_load]
    call dict_add_z
    lea rsi, [rip + token_mask_and]
    lea rdi, [rip + word_mask_and]
    call dict_add_z
    lea rsi, [rip + token_mask_or]
    lea rdi, [rip + word_mask_or]
    call dict_add_z
    lea rsi, [rip + token_eq]
    lea rdi, [rip + word_eq]
    call dict_add_z
    lea rsi, [rip + token_lt]
    lea rdi, [rip + word_lt]
    call dict_add_z
    lea rsi, [rip + token_shl]
    lea rdi, [rip + word_shl]
    call dict_add_z
    lea rsi, [rip + token_shr]
    lea rdi, [rip + word_shr]
    call dict_add_z
    lea rsi, [rip + token_loop]
    lea rdi, [rip + word_loop]
    call dict_add_z
    lea rsi, [rip + token_break]
    lea rdi, [rip + word_break]
    call dict_add_z
    lea rsi, [rip + token_type]
    lea rdi, [rip + word_type]
    call dict_add_z
    lea rsi, [rip + token_lit]
    lea rdi, [rip + word_compile_lit]
    call dict_add_z

    # immediates
    lea rsi, [rip + token_ctrl_open]
    lea rdi, [rip + word_ctrl_open]
    call dict_add_z
    or qword ptr [rax + NODE_TYPE], NODE_IMMEDIATE_MASK

    lea rsi, [rip + token_ctrl_close]
    lea rdi, [rip + word_ctrl_close]
    call dict_add_z
    or qword ptr [rax + NODE_TYPE], NODE_IMMEDIATE_MASK

    lea rsi, [rip + token_branch]
    lea rdi, [rip + word_branch]
    call dict_add_z
    or qword ptr [rax + NODE_TYPE], NODE_IMMEDIATE_MASK

    lea rsi, [rip + token_immediate]
    lea rdi, [rip + word_immediate]
    call dict_add_z
    or qword ptr [rax + NODE_TYPE], NODE_IMMEDIATE_MASK

    lea rsi, [rip + token_asm]
    lea rdi, [rip + word_asm]
    call dict_add_z
    or qword ptr [rax + NODE_TYPE], NODE_IMMEDIATE_MASK

.repl_loop:
    call read_token
    # rax = return, can be EOF, but handy for bootstrapping and continuing repl
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
        

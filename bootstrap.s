# Dedicated register association
# rbp = current definition
# rbx = scope stack pointer
# r12 = threaded instruction pointer / compile cursor
# r13 = cached TOS
# r14 = dictionary tail
# r15 = data stack pointer
.intel_syntax noprefix

.equ DATA_STACK_SIZE, 65536
.equ DICT_SIZE, 131072
.equ DICT_QWORDS, DICT_SIZE / 8

.equ CORE_QWORDS, (core_end - core) / 8

.equ STATE_EXE, 0
.equ STATE_DEF, 1

.equ TOKEN_MAX_LEN, 31

.equ NODE_CODE, 0
.equ NODE_TYPE, 8
.equ NODE_END,  16
.equ NODE_BODY, 24
.equ NODE_IMMEDIATE_MASK, 1
.equ NODE_TYPE_MASK, -8
.equ NODE_SIG_INPUT_MASK,   0xf
.equ NODE_SIG_OUTPUT_MASK,  0xf0
.equ NODE_SIG_LOCAL_MASK,   0xf00
.equ NODE_SIG_PRESENT_BIT,  50

# Max depth of scope stack depth
.equ SCOPE_MAX, 64
# Enclosing definition (outside of [)
.equ SCOPE_PARENT_TAG, 1
# Active ~ receiver / accessor context
.equ SCOPE_CONTEXT_TAG, 2
# Active definition receiving emitted code
.equ SCOPE_COMPILE_TAG, 4

.section .rodata
bootstrap_file_path:
    .asciz "bootstrap.ht"

token_ctrl_open:
    .asciz "["
token_ctrl_close:
    .asciz "]"
token_tick:
    .asciz "'"
token_ign:
    .asciz "#"
token_branch:
    .asciz "?"
token_loop:
    .asciz "~["
token_break:
    .asciz "~]"
token_immediate:
    .asciz "immediate"
token_asm:
    .asciz "asm"
token_lit:
    .asciz "lit"
token_to:
    .asciz "to"
token_panic:
    .asciz "panic"
token_source:
    .asciz "source"


.section .data

.align 8

# assembly host state exposed to language via TOS $[0-9]+
# number is qword index (cell)
core:
panic_handler:
    .quad 0
argc:
    .quad 0
argv:
    .quad 0
source_fd:
    .quad 0
source_dirfd:
    .quad 0
source_data:
    .quad 0
source_len:
    .quad 0

dict_base:
    .quad 0
dict_end_ptr:
    .quad 0
dict_tail_get:
    .quad word_dict_tail_get
dict_tail_set:
    .quad word_dict_tail_set

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
internal_local_get:
    .quad word_local_get
internal_local_set:
    .quad word_local_set
internal_exec:
    .quad word_exec

core_end:

.section .bss

# private state not exposed to core
.align 8
state:
    .quad 0
panic_active:
    .quad 0
token_buf:
    .skip TOKEN_MAX_LEN

.align 8
scope_stack:
    .skip SCOPE_MAX * 8
scope_stack_end:
data_stack:
    .skip DATA_STACK_SIZE
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

.equ P_STATE, 1
.equ P_DICT_NOTFOUND, 2
.equ P_DICT_OVERFLOW, 3
.equ P_STACK_UNDERFLOW, 4
.equ P_STACK_OVERFLOW, 5
.equ P_TOKEN_INVALID, 6
.equ P_TOKEN_OVERFLOW, 7
.equ P_TOKEN_NOCLOSE, 8
.equ P_TOKEN_NOOPEN, 9
.equ P_COMPILE_NODE, 10
.equ P_DIV_ZERO, 11
.equ P_LOCAL, 12
.equ P_EOF, 13

.equ PANIC_CODE, 0
.equ PANIC_STATE, 8
.equ PANIC_RBP, 16
.equ PANIC_RBX, 24
.equ PANIC_R12, 32
.equ PANIC_R13, 40
.equ PANIC_R14, 48
.equ PANIC_R15, 56
.equ PANIC_RSP, 64
.equ PANIC_SIZE, 72

# eax = P_*
panic:
    sub rsp, PANIC_SIZE

    mov [rsp + PANIC_CODE], rax
    
    mov rcx, [rip + state]
    mov [rsp + PANIC_STATE], rcx

    mov [rsp + PANIC_RBP], rbp
    mov [rsp + PANIC_RBX], rbx
    mov [rsp + PANIC_R12], r12
    mov [rsp + PANIC_R13], r13
    mov [rsp + PANIC_R14], r14
    mov [rsp + PANIC_R15], r15

    lea rcx, [rsp + PANIC_SIZE]
    mov [rsp + PANIC_RSP], rcx

panic_dispatch:
    # prevent resursive panic attacks
    cmp qword ptr [rip + panic_active], 0
    jne .panic_exit
    mov qword ptr [rip + panic_active], 1

    mov rax, [rip + panic_handler]
    test rax, rax
    jz .panic_exit

    # debugger must execute even if panic occurred while compiling
    mov qword ptr [rip + state], STATE_EXE

    # panic frame address as TOS
    mov [r15], r13
    add r15, 8
    mov r13, rsp

    # rax = registered handler node
    mov rdx, [rax + NODE_CODE]
    call rdx

    # if no panic_handler
.panic_exit:
    mov edi, dword ptr [rsp + PANIC_CODE]
    mov rax, 60
    syscall

# returns:
#   al = character
#   CF = 0 success
#   CF = 1 EOF
read_char:
    cmp qword ptr [rip + source_len], 0
    jne .read_char_cached

    xor eax, eax # SYS_read
    mov edi, dword ptr [rip + source_fd]
    lea rsi, [rip + source_data]
    mov edx, 8
    syscall

    test rax, rax
    js .read_char_error
    jz .read_char_eof

    mov [rip + source_len], rax

.read_char_cached:
    movzx eax, byte ptr [rip + source_data]
    shr qword ptr [rip + source_data], 8
    dec qword ptr [rip + source_len]
    clc
    ret

.read_char_error:
    mov rax, P_STATE
    jmp panic

.read_char_eof:
    stc
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
#   rax = unsigned qword
#   CF = 0 success
#   CF = 1 invalid
parse_hex:
    test r9, r9
    je .hex_invalid

    cmp r9, 16
    ja .hex_invalid

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
    shl rax, 4
    movzx edx, dl
    or rax, rdx

    inc rcx
    jmp .hex_next

.hex_done:
    clc
    ret
.hex_invalid:
    stc
    ret

# rsi = name address
# r9 = name length
# Splits once at the first '~'
# returns:
#  rax = head address
#  r8 = head length
#  rsi = tail address
#  r9 = tail length
#  CF = 0 split found
#  CF = 1 no split found
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
    # head non-empty
    test rcx, rcx
    je .member_invalid

    # tail must not be empty
    lea rdx, [rcx + 1]
    cmp rdx, r9
    je .member_invalid

    mov rax, rsi
    mov r8, rcx
    add rsi, rdx
    sub r9, rdx
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

    # '$' prefix for core address?
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

    cmp rax, OFFSET CORE_QWORDS
    jae .literal_bad

    lea rcx, [rip + core]
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
    call parse_hex
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
    xor r10d, r10d

.skip_ws:
    call read_char
    jc .token_eof

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
    jc .token_eof
    cmp al, '\n'
    jne .skip_comment
    jmp .skip_ws

.next:
    cmp r10, TOKEN_MAX_LEN
    jge panic_token_overflow

    lea rdx, [rip + token_buf]
    mov byte ptr [rdx + r10], al
    inc r10

    cmp al, '"'
    je .done

    call read_char
    jc .done

    cmp al, ' '
    je .done
    cmp al, '\t'
    je .done
    cmp al, '\n'
    je .done

    jmp .next

.done:
    lea rsi, [rip + token_buf]
    mov r9, r10
    xor eax, eax
    clc
    ret
.token_eof:
    stc
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
    jc panic_dict_notfound

    mov rdx, rax
.resolve_decl_done:
    ret

# rax = type address, 0 if none
# r8  = type length
# rsi = declaration name
# r9  = declaration name length
# returns:
#   rdx = resolved type node, 0 if untyped
resolve_signature_type:
    xor edx, edx

    test rax, rax
    jz .resolve_signature_done

    push rsi
    push r9
    mov rsi, rax
    mov r9, r8
    call find_signature_type
    pop r9
    pop rsi
    jc panic_dict_notfound

    mov rdx, rax

.resolve_signature_done:
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
    ja panic_dict_overflow

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

# rdx = node
# rsi = name
# r9  = name length
# returns:
#   CF = 0 match
#   CF = 1 no match
node_name_eq:
    push rdx

    call node_name
    cmp rcx, r9
    jne .node_name_eq_no

    xor edx, edx
.node_name_eq_next:
    cmp rdx, r9
    je .node_name_eq_yes

    mov cl, byte ptr [rsi + rdx]
    cmp cl, byte ptr [rax + rdx]
    jne .node_name_eq_no

    inc rdx
    jmp .node_name_eq_next

.node_name_eq_yes:
    pop rdx
    clc
    ret

.node_name_eq_no:
    pop rdx
    stc
    ret

# rdx = node
# rsi = name
# r9  = name length
# returns:
#   CF = 0 match
#   CF = 1 no match
node_match:
    call node_name

    cmp rcx, r9
    jne .node_match_no

    xor r10d, r10d
.node_match_next:
    cmp r10, r9
    je .node_match_yes

    mov cl, byte ptr [rsi + r10]
    cmp cl, byte ptr [rax + r10]
    jne .node_match_no

    inc r10
    jmp .node_match_next

.node_match_yes:
    clc
    ret
.node_match_no:
    stc
    ret

compile_ctrl_open:
    lea rcx, [rip + scope_stack_end]
    cmp rbx, rcx
    jae panic_stack_overflow

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
    # child words may override words, but never a local
    call find_scope
    jc .child_name_available

    lea rcx, [rip + word_local]
    cmp [rax + NODE_CODE], rcx
    je panic_token_invalid

.child_name_available:
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

    # output count determines next ref slot
    mov rcx, [rax]
    shr rcx, 4
    and ecx, 0xf
    cmp ecx, 8
    jae panic_token_invalid

    # refs start at 12, each 3 bits
    lea ecx, [rcx + rcx * 2 + 12]
    shl rdx, cl
    or [rax], rdx
    ret

# rsi/r9 = local name
# rdx = type node or 0
# rdi = header count delta: 0x101 = input & local count, 0x110 output + local count
# returns:
#   r10 = allocated slot
signature_declare_local:
    push rdi
    push rdx

    # validate: may override words but not other locals
    call find_scope
    jc .signature_local_free

    lea rcx, [rip + word_local]
    cmp [rax + NODE_CODE], rcx
    je panic_token_invalid

.signature_local_free:
    pop rdx

    NODE_NAME_ALIGNED_SIZE rcx, rbp
    lea rax, [rbp + NODE_BODY + rcx + 8]

    SIGNATURE_LOCAL_COUNT r10, rax

    push r10
    call compile_local
    pop r10

    NODE_NAME_ALIGNED_SIZE rcx, rbp
    lea rax, [rbp + NODE_BODY + rcx + 8]

    pop rdi

    # new output local:
    test edi, 0x10
    jz .signature_declare_count

    push rdi
    mov rdx, r10
    call signature_append_ref
    pop rdi

.signature_declare_count:
    add qword ptr [rax], rdi
    ret

# r10 = existing local slot
# rdi = address of parser output slot mask
signature_reuse_output:
    NODE_NAME_ALIGNED_SIZE rcx, rbp
    lea rax, [rbp + NODE_BODY + rcx + 8]

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
.signature_inputs:
    call read_token
    jc panic_token_noclose

    # '--' switch to outputs
    cmp r9, 2
    jne .signature_input
    cmp word ptr [rsi], 0x2d2d
    je .signature_outputs

.signature_input:
    # must declare new local
    call parse_declaration
    jc panic_token_invalid

    call resolve_signature_type

    mov edi, 0x101
    call signature_declare_local
    jmp .signature_inputs

.signature_outputs:
    call read_token
    jc panic_token_noclose

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

    call resolve_signature_type

    mov edi, 0x110
    call signature_declare_local
    jmp .signature_outputs

.signature_output_reuse:
    call find_scope
    jc panic_dict_notfound

    # output must resolve to a local
    lea rcx, [rip + word_local]
    cmp [rax + NODE_CODE], rcx
    jne panic_token_invalid

    # local must belong to this definition (not parent's or type's)
    call node_local_binding
    mov r10, rax
    and rax, -8
    cmp rax, rbp
    jne panic_token_invalid

    and r10d, 7    
    call signature_reuse_output
    jmp .signature_outputs

.signature_done:
    ret

# rbp = newly-created word_exec definition
# r12 = first free qword after zeroed signature header
# STATE_DEF is active
compile_definition_open:
    call read_token
    jc panic_token_noclose

    cmp r9, 1
    jne .definition_body
    cmp byte ptr [rsi], '('
    jne .definition_body

    call compile_signature

    mov rax, rbp
    call node_exec_set_code_start
    call compile_ctrl_open
    ret

.definition_body:
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

# TOS = P_* panic code
word_panic:
    mov rax, r13
    sub r15, 8
    mov r13, [r15]
    jmp panic

word_ctrl_open:
    cmp qword ptr [rip + state], STATE_DEF
    je .ctrl_open_nested

    # for now only top level [ must have a named definition
    # no anonymous top level regions yet...
    lea rcx, [rip + scope_stack]
    cmp rbx, rcx
    jne panic_state

    call read_token
    jc panic_token_noclose

    call parse_declaration
    jc panic_token_invalid

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
    ret

.ctrl_open_nested:
    # next token figures out : anonymous control region or scoped def
    call read_token
    jc panic_token_noclose

    call parse_declaration
    jc .ctrl_open_anonymous

    call resolve_declaration_type
    # rsi = name, rdx = type node or 0

    # reserve skip patch ref and tagged parent
    lea rcx, [rip + scope_stack_end]
    lea rax, [rbx + 24]
    cmp rax, rcx
    ja panic_stack_overflow

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
    jne panic_state

    lea r8, [rip + scope_stack]
    cmp rbx, r8
    je panic_token_noopen

    # recursive source cannot close it's caller's definition
    cmp qword ptr [rbx - 8], SCOPE_COMPILE_TAG
    je panic_token_noopen

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
    and r9, -8

    # parent's skip patch
    # consume skip-ref + tagged parent
    mov r10, [rbx - 16]
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

# rax = dictionary node being executed
word_exec:
    push rbp
    push r12
    push rbx

    # cached signature header
    # bit 63 = this invocation established the compile target
    push 0

    # if compile-time code in definition, preserve the definition being defined
    cmp qword ptr [rip + state], STATE_DEF
    jne .exec_target_ready

    # nested calls from an immediate reuse the existing target
    mov r10, rax
    call scope_compile_target
    mov rax, r10
    jnc .exec_target_ready

    # no target: preserve current compile cursor
    mov [rbp + NODE_END], r12

    lea rcx, [rip + scope_stack_end]
    cmp rbx, rcx
    jae panic_stack_overflow

    mov rdx, rbp
    or rdx, SCOPE_COMPILE_TAG
    mov [rbx], rdx
    add rbx, 8

    # use reserved header bit as our saved flag
    bts qword ptr [rsp], 63

.exec_target_ready:
    mov rbp, rax

    # establishes r12 and, for signed words, invocation frame
    # returns signature header in r11
    call node_exec_enter

    # cache header alongside compile-target flag
    or [rsp], r11

.exec_next:
    cmp r12, [rbp + NODE_END]
    je .exec_done

    mov rax, [r12]
    add r12, 8
    mov rdx, [rax + NODE_CODE]
    call rdx
    jmp .exec_next

.exec_done:
    # preserve compile cursor if this call established the target
    bt qword ptr [rsp], 63
    jnc .exec_leave

    mov rax, [rsp + 24]
    mov rax, [rax + NODE_END]
    mov [rsp + 16], rax

.exec_leave:
    mov r11, [rsp]

    # unsigned word: no invocation frame
    test r11d, 0xfff
    jz .exec_restore

    call node_exec_leave

.exec_restore:
    add rsp, 8
    pop rbx
    pop r12
    pop rbp
    ret

word_tick:
    call read_token
    jc panic_token_noclose

    call find_scope
    jc panic_dict_notfound

    mov [r15], r13 # old TOS = NOS
    add r15, 8
    mov r13, rax # XT becomes new TOS
    ret

word_dict_tail_get:
    mov [r15], r13
    add r15, 8
    mov r13, r14
    ret

word_dict_tail_set:
    mov r14, r13
    sub r15, 8
    mov r13, [r15]
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

# Emits TOS as a runtime literal into the active compile target (word)
# Ignored during runtime
word_compile_lit:
    # exe = value already resolved
    cmp qword ptr [rip + state], STATE_EXE
    je .compile_lit_done

    # def = embed value in active target
    call scope_compile_target
    jc panic_state

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
.compile_lit_done:
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
    jae panic_stack_overflow

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

    # stop at recursive source boundary
    cmp qword ptr [rbx - 8], SCOPE_COMPILE_TAG
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
    je panic_token_noopen

    # do not loop into caller's compile scope
    cmp qword ptr [rbx - 8], SCOPE_COMPILE_TAG
    je panic_token_noopen

    # peek start offset
    mov eax, dword ptr [rbx - 8]

    # jump there
    lea rcx, [rbp + NODE_BODY]
    lea r12, [rcx + rax]
    ret

word_break:
    call word_ctrl_pop
    jc panic_token_noopen

    # popped frame: end offset
    shr rax, 32

    # jump there
    lea rcx, [rbp + NODE_BODY]
    lea r12, [rcx + rax]
    ret

word_branch:
    cmp qword ptr [rip + state], STATE_DEF
    jne panic_state

    # ? consumes one named word for arm
    call read_token
    jc panic_token_noclose

    call find_scope
    jc panic_dict_notfound

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
    
word_immediate:
    cmp qword ptr [rip + state], STATE_DEF
    jne panic_state
    or qword ptr [rbp + NODE_TYPE], NODE_IMMEDIATE_MASK
    ret

# [ 0x12 0x23 0x34 asm ]
# Immediate: Consumes all words in the scope
word_asm:
    cmp qword ptr [rip + state], STATE_DEF
    jne panic_state

    lea rcx, [rip + scope_stack]
    cmp rbx, rcx
    je panic_token_noopen

    # asm can't run in a compile scope (must be it's own anonymous one)
    cmp qword ptr [rbx - 8], SCOPE_COMPILE_TAG
    je panic_token_noopen

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
    ja panic_token_invalid

    # validate: either lit or qword value
    cmp qword ptr [r8], rdx
    jne panic_token_invalid

    # must be a byte
    mov rax, [r8 + 8]
    cmp rax, 255
    ja panic_token_invalid

    lea rcx, [rip + native_buf_end]
    cmp r11, rcx
    # TODO: Better error
    jae panic_dict_overflow

    mov [r11], al
    inc r11

    add r8, 16
    jmp .asm_next

.asm_ret:
    # ret to threaded caller
    lea rcx, [rip + native_buf_end]
    cmp r11, rcx
    jae panic_dict_overflow

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
    jae panic_stack_overflow

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
    call find_member
    jnc .md_run             # override found in context's chain

    # not found: fall back to the statically-resolved node
.md_run_s:
    mov rax, r11
.md_run:
    mov rdx, [rax + NODE_CODE]
    call rdx
    ret

word_local_get:
    mov rax, [r12]
    add r12, 8

    # slot = low 3 bits
    mov r10, rax
    and r10d, 7

    # find owning def
    and rax, -8
    call scope_invocation_frame
    jc panic_local

    mov rax, [rax]

    # local must contain a valid value
    mov ecx, r10d
    add rcx, 31
    bt rax, rcx
    jnc panic_local

    # decode local base (where data stack should end up at end of execution)
    shr rax, 17
    and eax, 0x3fff
    lea rdx, [rip + data_stack]
    lea rax, [rdx + rax * 8]

    # push local value to data stack
    mov [r15], r13
    add r15, 8
    mov r13, [rax + r10 * 8]
    ret

# [r12] = packed owner | slot
word_local_set:
    mov rax, [r12]
    add r12, 8

    # slot
    mov r10, rax
    and r10d, 7

    # find invocation frame for owner
    and rax, -8
    call scope_invocation_frame
    jc panic_local

    # preserve address of packed frame
    mov r11, rax
    mov rax, [rax]

    # local base
    shr rax, 17
    and eax, 0x3fff

    lea rdx, [rip + data_stack]
    lea rax, [rdx + rax * 8]

    # set TOS = local
    mov [rax + r10 * 8], r13

    # set local valid
    mov ecx, r10d
    add ecx, 31
    bts qword ptr [r11], rcx

    # consume value from TOS
    sub r15, 8
    mov r13, [r15]
    ret

# Should not be executed at runtime, only compile time
word_local:
    jmp panic_compile_node

word_to:
    cmp qword ptr [rip + state], STATE_DEF
    jne panic_state

    # consume local (name)
    call read_token
    jc panic_token_noclose

    call find_scope
    jc panic_dict_notfound

    # validate it's a local
    lea rcx, [rip + word_local]
    cmp [rax + NODE_CODE], rcx
    jne panic_token_invalid

    # emit internal_local_set + owner|slot
    call node_local_binding
    mov [r12 + 8], rax

    lea rax, [rip + internal_local_set]
    mov [r12], rax
    add r12, 16
    ret

word_source:
    cmp qword ptr [rip + state], STATE_DEF
    jne .eval_source

    # comp time - find def of parent
    call scope_compile_target
    jc panic_state

    # rax = compile target
    # rdx = adress of target|SCOPE_COMPILE_TAG entry
    push rbp
    push r12
    push rbx

    # re-enter evaluator as target def
    mov rbp, rax
    mov r12, [rax + NODE_END]

    # put recursive compile target bounary above every active caller frame
    lea rcx, [rip + scope_stack_end]
    cmp rbx, rcx
    jae panic_stack_overflow

    mov qword ptr [rbx], SCOPE_COMPILE_TAG
    add rbx, 8

    call .eval_source

    # publish where recursive compilation finished
    mov [rbp + NODE_END], r12

    pop rbx
    pop r12
    pop rbp
    ret
    
.eval_source:
.eval_source_next:
    call read_token
    jc .eval_source_done
    call eval_token
    jmp .eval_source_next
.eval_source_done:
    ret

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
    ja panic_dict_overflow

    shl rdx, 36
    or [rcx], rdx
    ret

scope_body_floor:
    mov rcx, rbx
    lea rdx, [rip + scope_stack]
.scope_body_floor_next:
    cmp rcx, rdx
    je .scope_body_floor_root

    sub rcx, 8
    mov rax, [rcx]

    test rax, rax
    jns .scope_body_floor_next

    shr rax, 39
    and eax, 0x3fff

    lea rdx, [rip + data_stack]
    lea rax, [rdx + rax * 8]
    ret

.scope_body_floor_root:
    lea rax, [rip + data_stack]
    ret

# rbp = word_exec node
# returns:
#   r11 = signature header
#   r12 = first threaded instruction
node_exec_enter:
    NODE_NAME_ALIGNED_SIZE rcx, rbp
    mov r11, [rbp + NODE_BODY + rcx + 8]

    # code-start qword offset
    mov r12, r11
    shr r12, 36
    and r12d, DICT_QWORDS - 1
    lea r12, [rbp + NODE_BODY + r12 * 8]

    # no inputs, outputs or locals
    test r11d, 0xfff
    jz .exec_enter_done

    # r8 = input count
    mov r8d, r11d
    and r8d, 0xf

    # r9 = local count
    mov r9, r11
    shr r9, 8
    and r9d, 0xf

    # r10 = caller cursor
    mov rcx, r8
    shl rcx, 3
    mov r10, r15
    sub r10, rcx

    call scope_body_floor
    cmp r10, rax
    jb panic_stack_underflow

    # rdx = local base
    lea rdx, [r10 + 8]

    # r9 = temporary floor
    lea r9, [rdx + r9 * 8]

    lea rcx, [rip + data_stack_end]
    cmp r9, rcx
    ja panic_stack_overflow

    lea rcx, [rip + scope_stack_end]
    cmp rbx, rcx
    jae panic_stack_overflow

    # owner occupies bits 3..16 as dictionary byte offset
    mov rax, rbp
    lea rcx, [rip + dict]
    sub rax, rcx

    # local-base byte offset << 14 gives qword index in bits 17..
    lea rsi, [rip + data_stack]
    sub rdx, rsi
    shl rdx, 14
    or rax, rdx

    # body-floor qword index in bits 39..52
    mov rcx, r9
    sub rcx, rsi
    shr rcx, 3
    shl rcx, 39
    or rax, rcx

    # initial validity mask = (1 << input_count) - 1
    mov ecx, r8d
    mov edx, 1
    shl rdx, cl
    dec rdx
    shl rdx, 31
    or rax, rdx

    # invocation-frame marker
    bts rax, 63

    mov [rbx], rax
    add rbx, 8

    # spill cached input TOS only after all bounds checks succeeded
    mov [r15], r13

    # body stack starts above local storage
    mov r13, [r10]
    mov r15, r9
.exec_enter_done:
    ret

# rbp = word_exec node
# r11 = cached signature header
node_exec_leave:
    # invocation frame must be on top
    lea rcx, [rip + scope_stack]
    cmp rbx, rcx
    je panic_local

    sub rbx, 8
    mov rax, [rbx]

    test rax, rax
    jns panic_local

    # verify frame belongs to this definition
    mov rdx, rbp
    lea rcx, [rip + dict]
    sub rdx, rcx

    mov ecx, eax
    and ecx, DICT_SIZE - 8
    cmp rcx, rdx
    jne panic_local

    # r8 = local base
    mov r8, rax
    shr r8, 17
    and r8d, 0x3fff

    lea rcx, [rip + data_stack]
    lea r8, [rcx + r8 * 8]

    # body must not have dropped below its local frame
    mov rcx, r11
    shr rcx, 8
    and ecx, 0xf
    lea rcx, [r8 + rcx * 8]

    cmp r15, rcx
    jb panic_local

    # r9 = validity mask
    mov r9, rax
    shr r9, 31
    and r9d, 0xff

    # r10 = output count
    mov r10, r11
    shr r10, 4
    and r10d, 0xf

    test r10, r10
    jz .exec_reclaim

    # refs only contain outputs
    shr r11, 12

    # stage outputs before local storage is reclaimed
    mov rsi, r10

.exec_stage_output:
    mov edx, r11d
    and edx, 7

    bt r9, rdx
    jnc panic_local

    push qword ptr [r8 + rdx * 8]

    shr r11, 3
    dec rsi
    jnz .exec_stage_output

.exec_reclaim:
    # restore caller stack after consuming all inputs
    lea r15, [r8 - 8]
    mov r13, [r15]

    test r10, r10
    jz .exec_leave_done

    # staged values are reversed on the machine stack;
    # begin with the first declared output
    lea rdx, [rsp + r10 * 8 - 8]
    mov rsi, r10

.exec_emit_output:
    mov [r15], r13
    add r15, 8
    mov r13, [rdx]

    sub rdx, 8
    dec rsi
    jnz .exec_emit_output

    lea rsp, [rsp + r10 * 8]

.exec_leave_done:
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

# rax = owning definition
# r10 = local slot 0..7
# returns:
#   rax = local node
#   CF = 0 found
#   CF = 1 not found
node_local_slot:
    call node_locals_ref
    mov rdx, [rax]
.node_local_slot_next:
    test rdx, rdx
    jz .node_local_slot_missing

    # only signature locals have owner|slot payloads.
    lea rcx, [rip + word_local]
    cmp [rdx + NODE_CODE], rcx
    jne .node_local_slot_prev

    mov rax, rdx
    call node_local_binding

    and eax, 7
    cmp eax, r10d
    je .node_local_slot_found

.node_local_slot_prev:
    mov rcx, [rdx + NODE_END]
    mov rdx, [rcx]
    jmp .node_local_slot_next

.node_local_slot_found:
    mov rax, rdx
    clc
    ret
.node_local_slot_missing:
    stc
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

# r8 = node
# rsi = name
# r9 = name len
# returns: find_dict
# Search only this node's direct child dictionary
find_node:
    mov rax, r8
    call node_locals_ref
    mov rdx, [rax]
    jmp find_dict

# r8 = node
# rsi = member name
# r9 = member name len
# Searches public children, then NODE_TYPE chain.
# word_local matches are skipped (searches from external node)
# returns:
#   rax = matching public member
#   CF = 0 found
#   CF = 1 not found
find_member:
.find_member_next:
    call find_node
    jc .find_member_type

.find_member_check:
    lea rcx, [rip + word_local]
    cmp [rax + NODE_CODE], rcx
    jne .find_member_found

    # Matching local is not a public member.
    # Resume this same dictionary before the local.
    mov rcx, [rax + NODE_END]
    mov rdx, [rcx]
    call find_dict
    jnc .find_member_check

.find_member_type:
    mov rax, r8
    call node_type
    test rax, rax
    jz .find_member_missing

    mov r8, rax
    jmp .find_member_next

.find_member_found:
    clc
    ret

.find_member_missing:
    stc
    ret

# r8 = resolved current scope node
# rsi = remaining qualified chain
# r9 = remaining chain length
# Walks zero or more intermediate member scopes
# returns:
#   rax = final member node
#   r8 = immediate parent of final member
#   CF = 0 found
#   CF = 1 not
find_member_chain:
    # rsp = scope
    # rsp + 8 = tail address
    # rsp + 16 = remaining tail len
    sub rsp, 24
    mov [rsp], r8

.member_chain_next:
    # failure means rsi/r9 is the final segment.
    call parse_member
    jc .member_chain_final

    # Save the tail while resolving this segment.
    mov [rsp + 8], rsi
    mov [rsp + 16], r9

    # Resolve this segment inside current scope.
    mov rsi, rax
    mov r9, r8
    mov r8, [rsp]

    call find_member
    jc .member_chain_missing

    # Resolved member becomes the scope for the next segment.
    mov [rsp], rax

    mov rsi, [rsp + 8]
    mov r9, [rsp + 16]
    jmp .member_chain_next
    
.member_chain_final:
    # rsi/r9 = final member name
    mov r8, [rsp]
    # '~' missing and is final member name
    call find_member
    jc .member_chain_missing

    # r8 can be clobbered
    mov r8, [rsp]
    add rsp, 24
    clc
    ret

.member_chain_missing:
    add rsp, 24
    stc
    ret

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

# rax = owning definition
# returns:
#   rax = address of packed active invocation
#   CF = 0 found
#   CF = 1 not
scope_invocation_frame:
    lea rdx, [rip + dict]
    sub rax, rdx
    mov r8, rax

    mov rcx, rbx
    lea rdx, [rip + scope_stack]

.scope_invocation_next:
    cmp rcx, rdx
    je .scope_invocation_missing

    sub rcx, 8
    mov r9, [rcx]

    # invocation frame have bit 64 set
    test r9, r9
    jns .scope_invocation_next

    # bits 3..16 are aligned dict offset
    mov eax, r9d
    and eax, DICT_SIZE - 8
    cmp rax, r8
    jne .scope_invocation_next

    mov rax, rcx
    clc
    ret
.scope_invocation_missing:
    stc
    ret

# returns:
#   rax = node currently receiving compile time output
#   rdx = address of it's SCOPE_COMPILE_TAG stack entry
#   CF = 0 found
#   CF = 1 not found
# Recursive source boundary: compile target should not cross it
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

    # recursive source boundary = bare tag
    cmp rax, SCOPE_COMPILE_TAG
    je .compile_target_missing

    # strip tag
    and rax, -8
    clc
    ret

.compile_target_missing:
    stc
    ret

# rsi = type name
# r9  = type name length
# returns:
#   rax = matching node
#   CF = 0 found
#   CF = 1 not found
# Signature-only additions to normal scope lookup:
# current definition itself, then enclosing definitions themselves.
find_signature_type:
    push rdi

    # current definition
    mov rdx, rbp
    call node_match
    jnc .find_signature_type_current

    # enclosing definitions
    mov rdi, rbx

.find_signature_type_parent:
    lea rcx, [rip + scope_stack]
    cmp rdi, rcx
    je .find_signature_type_scope

    sub rdi, 8
    mov rdx, [rdi]

    test rdx, SCOPE_PARENT_TAG
    jz .find_signature_type_parent

    and rdx, -8
    call node_match
    jc .find_signature_type_parent

    # rdx is the matched parent
    mov rax, rdx
    pop rdi
    clc
    ret

.find_signature_type_current:
    mov rax, rbp
    pop rdi
    clc
    ret

.find_signature_type_scope:
    pop rdi
    jmp find_scope

# rsi = name address
# r9 = name length
# returns:
#   rax = matching node
#   r10 = 1 if context member, 0 if static
#   CF = 0 found
#   CF = 1 not found
find_scope:
    push rdi

    cmp qword ptr [rip + state], STATE_DEF
    jne .find_scope_root

    # direct current children first: locals participate and shadow
    mov r8, rbp
    call find_node
    jnc .find_scope_static

    # then public members of current definition / type chain
    # find_member skips locals
    mov r8, rbp
    call find_member
    jnc .find_scope_static

    # parents
    mov rdi, rbx

.find_scope_parent:
    lea rcx, [rip + scope_stack]
    cmp rdi, rcx
    je .find_scope_root

    sub rdi, 8
    mov rax, [rdi]
    test rax, SCOPE_PARENT_TAG
    jz .find_scope_parent

    and rax, -8
    mov r8, rax

    # first: direct children first + locals
    call find_node
    jnc .find_scope_found

    # next: public / inherited members no locals!
    call find_member
    jc .find_scope_parent

.find_scope_found:
    # parent locals remain static
    lea rdx, [rip + word_local]
    cmp [rax + NODE_CODE], rdx
    je .find_scope_static

    # parent words and inherited members are virtual
    mov r10d, 1
    clc
    jmp .find_scope_done

.find_scope_static:
    xor r10d, r10d
    # clears CF
    jmp .find_scope_done

.find_scope_root:
    mov rdx, r14
    call find_dict
    mov r10d, 0 # find_dict clobbers r10
    # CF set

.find_scope_done:
    pop rdi
    ret

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

    call node_match
    jnc .find_found

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

    # then try scope~member chain
    call parse_member
    jc .eval_literal

    # rax/r8 = root scope nam / len
    # rsi/r9 = remaining member chain name / len
    push rsi
    push r9
    mov rsi, rax
    mov r9, r8
    call find_scope
    pop r9
    pop rsi
    jc panic_dict_notfound

    # resolve member segments
    mov r8, rax
    call find_member_chain
    jc panic_dict_notfound

    # rax = resolved member
    # r8 = original context node
    jmp .eval_qualified

.eval_word:
    mov rdx, [rax + NODE_CODE]
    cmp qword ptr [rip + state], STATE_EXE
    je .eval_exec

    # locals: emit compiled local
    lea rcx, [rip + word_local]
    cmp rdx, rcx
    je .eval_compile_local

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

.eval_compile_local:
    call node_local_binding

    # emit runtime read + packed owner|slot
    mov [r12 + 8], rax
    lea rax, [rip + internal_local_get]
    mov [r12], rax
    add r12, 16
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

    mov rdx, [rax + NODE_CODE]
    lea rcx, [rip + word_exec]
    cmp rdx, rcx
    jne .eval_qualified_no_signature

.eval_qualified_no_signature:
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
    jae panic_stack_overflow

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
    jc panic_dict_notfound

    mov [r15], r13
    add r15, 8
    mov r13, rax
    ret

.eval_declaration:
    call parse_declaration
    jc panic_dict_notfound

    # declaration must be typed
    test rax, rax
    jz panic_token_invalid

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
    mov rax, rbp
    call node_exec_set_code_start

    # push constructor target
    lea rcx, [rip + scope_stack_end]
    cmp rbx, rcx
    jae panic_stack_overflow

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
    # rsp = argc
    # rsp + 8... = argv...
    mov rax, [rsp]
    mov [rip + argc], rax
    lea rax, [rsp + 8]
    mov [rip + argv], rax


    # bind runtime stacks
    lea r15, [rip + data_stack]
    lea rbx, [rip + scope_stack]

    lea rax, [rip + dict]
    mov [rip + dict_base], rax

    lea rax, [rip + dict_end]
    mov [rip + dict_end_ptr], rax

    # dict must be null (0) for first node_add call
    xor r14d, r14d 

    # load builtins into dict
.load_builtins:
    # internals
    lea rax, [rip + internal_branch]

    # global
    lea rsi, [rip + token_tick]
    lea rdi, [rip + word_tick]
    call dict_add_z
    lea rsi, [rip + token_loop]
    lea rdi, [rip + word_loop]
    call dict_add_z
    lea rsi, [rip + token_break]
    lea rdi, [rip + word_break]
    call dict_add_z
    lea rsi, [rip + token_lit]
    lea rdi, [rip + word_compile_lit]
    call dict_add_z
    lea rsi, [rip + token_panic]
    lea rdi, [rip + word_panic]
    call dict_add_z
    lea rsi, [rip + token_source]
    lea rdi, [rip + word_source]
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

    lea rsi, [rip + token_to]
    lea rdi, [rip + word_to]
    call dict_add_z
    or qword ptr [rax + NODE_TYPE], NODE_IMMEDIATE_MASK

    mov eax, 257  # SYS_OPENAT
    mov edi, -100 # AT_FDCWD
    lea rsi, [rip + bootstrap_file_path]
    mov edx, 0x80000    # O_RDONLY | O_CLOEXEC
    xor r10d, r10d
    syscall

    test rax, rax
    js panic_state

    mov [rip + source_fd], rax
    mov qword ptr [rip + source_dirfd], -100 # AT_FDCWD
    mov qword ptr [rip + source_len], 0

    # evaluate current source (we just loaded bootstrap.ht)
    call word_source

    # exit
    xor edi, edi
    mov eax, 60
    syscall

panic_dict_notfound:
    mov rax, P_DICT_NOTFOUND
    jmp panic
panic_dict_overflow:
    mov rax, P_DICT_OVERFLOW
    jmp panic
 panic_stack_overflow:
    mov rax, P_STACK_OVERFLOW
    jmp panic
panic_stack_underflow:
    mov rax, P_STACK_UNDERFLOW
    jmp panic
panic_token_invalid:
    mov rax, P_TOKEN_INVALID
    jmp panic
panic_token_overflow:
    mov rax, P_TOKEN_OVERFLOW
    jmp panic
panic_token_noclose:
    mov rax, P_TOKEN_NOCLOSE
    jmp panic
panic_token_noopen:
    mov rax, P_TOKEN_NOOPEN
    jmp panic
panic_compile_node:
    mov rax, P_COMPILE_NODE
    jmp panic
panic_state:
    mov rax, P_STATE
    jmp panic
panic_local:
    mov rax, P_LOCAL
    jmp panic
panic_eof:
    mov rax, P_EOF
    jmp panic

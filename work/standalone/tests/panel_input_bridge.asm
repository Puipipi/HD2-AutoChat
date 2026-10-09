bits 64
default rel
org 0x100200

%macro QUEUE_EVENT 0
    mov r10, [rsp+0x40]
    cmp dword [r10+132], 0
    jne %%done
    mov eax, [r10+136]
    lea ecx, [rax+1]
    and ecx, 63
    cmp ecx, [r10+140]
    je %%full
    lea r11, [rax+rax*2]
    shl r11, 3
    lea r11, [r10+r11+256]
    mov edx, [rsp+0x28]
    mov [r11], edx
    mov rdx, [rsp+0x30]
    mov [r11+8], rdx
    mov rdx, [rsp+0x38]
    mov [r11+16], rdx
    mov [r10+136], ecx
    jmp %%done
%%full:
    mov dword [r10+132], 1
%%done:
%endmacro

; Entered by the RX trampoline with R10 = RW state page. It keeps the
; original four WNDPROC arguments on the stack while native IMM calls run.
bridge:
    sub rsp, 0x78
    mov [rsp+0x20], rcx
    mov [rsp+0x28], rdx
    mov [rsp+0x30], r8
    mov [rsp+0x38], r9
    mov [rsp+0x40], r10
    mov qword [rsp+0x48], 0

    cmp edx, 0x84a2
    jne .not_control
    cmp qword [rsp+0x38], r10     ; reject an unrelated game WM_APP message
    jne forward
    jmp control_message
.not_control:
    cmp edx, 0x0082                 ; retry context restore before window teardown
    je destroyed
    cmp dword [r10+128], 0
    je forward

    cmp edx, 0x0102                 ; WM_CHAR
    je queue_char
    cmp edx, 0x0109                 ; WM_UNICHAR
    je queue_char
    cmp edx, 0x0100                 ; WM_KEYDOWN
    je queue_key
    cmp edx, 0x0101                 ; WM_KEYUP
    je queue_key
    cmp edx, 0x0104                 ; WM_SYSKEYDOWN
    je queue_key
    cmp edx, 0x0105                 ; WM_SYSKEYUP
    je queue_key
    cmp edx, 0x010d                 ; WM_IME_STARTCOMPOSITION
    je queue_ime
    cmp edx, 0x010e                 ; WM_IME_ENDCOMPOSITION
    je queue_ime
    cmp edx, 0x010d
    jb forward
    cmp edx, 0x010f                 ; include WM_IME_COMPOSITION
    jbe default_proc
    cmp edx, 0x0281                 ; WM_IME_SETCONTEXT
    jb forward
    cmp edx, 0x0291                 ; WM_IME_KEYUP
    jbe default_proc
    jmp forward

queue_char:
    cmp dword [rsp+0x28], 0x0109
    jne .queue_character
    cmp qword [rsp+0x30], 0xffff
    je .unicode_probe
.queue_character:
    QUEUE_EVENT
    xor eax, eax                    ; the game must not consume editor text
    jmp return
.unicode_probe:
    mov eax, 1                      ; WM_UNICHAR support probe
    jmp return

queue_key:
    QUEUE_EVENT
    mov edx, [rsp+0x28]
    cmp edx, 0x0100
    je key_control
    cmp edx, 0x0104
    jne forward
key_control:
    mov rax, [rsp+0x30]
    cmp eax, 0x0d                   ; let DefWindowProc handle IME candidate keys
    je default_proc
    cmp eax, 0x1b
    je default_proc
    jmp forward

queue_ime:
    QUEUE_EVENT
    jmp default_proc

default_proc:
    mov rcx, [rsp+0x20]
    mov rdx, [rsp+0x28]
    mov r8,  [rsp+0x30]
    mov r9,  [rsp+0x38]
    mov r10, [rsp+0x40]
    call qword [r10+168]
    jmp return

destroyed:
    mov qword [rsp+0x48], 1
    jmp disable_ime

control_message:
    cmp qword [rsp+0x30], 0
    je disable_ime
    jmp enable_ime

disable_ime:
    mov r10, [rsp+0x40]
    mov dword [r10+128], 0
    jmp restore_context

enable_ime:
    mov r10, [rsp+0x40]
    cmp dword [r10+128], 0
    jne .already_active
    cmp dword [r10+148], 0
    jne .already_active
    mov dword [r10+128], 0
    mov dword [r10+144], 0
    mov dword [r10+148], 0
    mov qword [r10+152], 0
    mov qword [r10+160], 0
    mov rcx, [rsp+0x20]
    call qword [r10+176]            ; ImmGetContext
    mov r10, [rsp+0x40]
    mov [r10+152], rax
    test rax, rax
    jz .saved
    mov rcx, [rsp+0x20]
    mov rdx, rax
    call qword [r10+184]            ; ImmReleaseContext
.saved:
    mov r10, [rsp+0x40]
    mov rcx, [rsp+0x20]
    xor edx, edx
    mov r8d, 0x10                   ; IACE_DEFAULT
    call qword [r10+192]            ; ImmAssociateContextEx
    test eax, eax
    jz .make_context
    mov r10, [rsp+0x40]
    mov dword [r10+148], 1
    mov rcx, [rsp+0x20]
    call qword [r10+176]            ; verify usable default context
    test rax, rax
    jz .restore_before_create
    mov r10, [rsp+0x40]
    mov rcx, [rsp+0x20]
    mov rdx, rax
    call qword [r10+184]
    mov r10, [rsp+0x40]
    mov dword [r10+144], 1
    mov dword [r10+128], 1
    xor eax, eax
    jmp return
.already_active:
    xor eax, eax
    jmp return
.restore_before_create:
    mov r10, [rsp+0x40]
    mov rcx, [rsp+0x20]
    mov rdx, [r10+152]
    call qword [r10+200]
    mov [rsp+0x58], rax
    mov r10, [rsp+0x40]
    mov rcx, [rsp+0x20]
    call qword [r10+176]
    mov r10, [rsp+0x40]
    cmp rax, [r10+152]
    jne .restore_before_create_failed
    test rax, rax
    jz .clear_before_create
    mov rcx, [rsp+0x20]
    mov rdx, rax
    call qword [r10+184]
.clear_before_create:
    mov r10, [rsp+0x40]
    mov dword [r10+148], 0
    jmp .make_context
.restore_before_create_failed:
    test rax, rax
    jz .restore_before_create_failed_no_release
    mov rcx, [rsp+0x20]
    mov rdx, rax
    call qword [r10+184]
.restore_before_create_failed_no_release:
    mov r10, [rsp+0x40]
    mov dword [r10+128], 0
    mov dword [r10+144], 0
    xor eax, eax
    jmp return
.make_context:
    mov r10, [rsp+0x40]
    mov rcx, [rsp+0x20]
    call qword [r10+208]            ; ImmCreateContext
    test rax, rax
    jz .active_without_ime
    mov r10, [rsp+0x40]
    mov [r10+160], rax
    mov dword [r10+148], 2           ; track the context before associating it
    mov rcx, [rsp+0x20]
    mov rdx, rax
    call qword [r10+200]            ; ImmAssociateContext
    mov r10, [rsp+0x40]
    mov rcx, [rsp+0x20]
    call qword [r10+176]            ; verify the association
    mov r10, [rsp+0x40]
    cmp rax, [r10+160]
    jne .bad_own_context
    mov rcx, [rsp+0x20]
    mov rdx, rax
    call qword [r10+184]
    mov r10, [rsp+0x40]
    mov dword [r10+144], 1
    mov dword [r10+128], 1
    xor eax, eax
    jmp return
.bad_own_context:
    test rax, rax
    jz .restore_bad_own
    mov rcx, [rsp+0x20]
    mov rdx, rax
    call qword [r10+184]            ; release every successful ImmGetContext
.restore_bad_own:
    mov r10, [rsp+0x40]
    mov rcx, [rsp+0x20]
    mov rdx, [r10+152]
    call qword [r10+200]
    mov [rsp+0x58], rax
    mov r10, [rsp+0x40]
    mov rcx, [rsp+0x20]
    call qword [r10+176]
    mov r10, [rsp+0x40]
    cmp rax, [r10+152]
    je .bad_own_context_matches
    test rax, rax
    jz .bad_own_restore_failed
    mov rcx, [rsp+0x20]
    mov rdx, rax
    call qword [r10+184]
    jmp .bad_own_restore_failed
.bad_own_context_matches:
    test rax, rax
    jz .bad_own_restore_null
    mov rcx, [rsp+0x20]
    mov rdx, rax
    call qword [r10+184]
    jmp .destroy_bad_own
.bad_own_restore_null:
    mov r10, [rsp+0x40]
    mov rax, [rsp+0x58]
    cmp rax, [r10+160]
    je .destroy_bad_own
.bad_own_restore_failed:
    mov r10, [rsp+0x40]
    mov dword [r10+128], 0
    mov dword [r10+144], 0
    xor eax, eax
    jmp return
.destroy_bad_own:
    mov r10, [rsp+0x40]
    mov rcx, [r10+160]
    test rcx, rcx
    jz .active_without_ime
    call qword [r10+216]
    mov r10, [rsp+0x40]
    mov qword [r10+160], 0
    mov qword [r10+152], 0
    mov dword [r10+148], 0
.active_without_ime:
    mov r10, [rsp+0x40]
    mov dword [r10+144], 0
    mov dword [r10+128], 1
    xor eax, eax
    jmp return

restore_context:
    mov r10, [rsp+0x40]
    mov eax, [r10+148]
    test eax, eax
    jz .clear
    mov rcx, [rsp+0x20]
    mov rdx, [r10+152]
    call qword [r10+200]            ; restore the exact prior HIMC, including NULL
    mov r10, [rsp+0x40]
    mov [rsp+0x58], rax             ; ImmAssociateContext returns the displaced HIMC
    cmp dword [r10+148], 2
    jne .check_default_restore
    cmp qword [r10+152], 0
    jne .verify_restored_context
    mov rax, [rsp+0x58]
    cmp rax, [r10+160]
    jne .restore_failed             ; prove the own HIMC was disassociated before destroy
    jmp .verify_restored_context
.check_default_restore:
    cmp qword [r10+152], 0
    jne .verify_restored_context
    cmp qword [rsp+0x58], 0
    je .restore_failed             ; ready default context must have been displaced
.verify_restored_context:
    mov rcx, [rsp+0x20]
    call qword [r10+176]            ; verify exact prior context, including NULL
    mov r10, [rsp+0x40]
    cmp rax, [r10+152]
    jne .release_restore_mismatch
    test rax, rax
    jz .restore_verified
    mov rcx, [rsp+0x20]
    mov rdx, rax
    call qword [r10+184]
    jmp .restore_verified
.release_restore_mismatch:
    test rax, rax
    jz .restore_failed
    mov rcx, [rsp+0x20]
    mov rdx, rax
    call qword [r10+184]
    jmp .restore_failed
.restore_verified:
    mov r10, [rsp+0x40]
    cmp dword [r10+148], 2
    jne .clear
    mov rcx, [r10+160]
    test rcx, rcx
    jz .clear
    call qword [r10+216]            ; only destroy a context we created
    jmp .clear
.restore_failed:
    mov r10, [rsp+0x40]
    mov dword [r10+128], 0
    mov dword [r10+144], 0
    cmp qword [rsp+0x48], 0
    jne .destroyed_restore_failed
    xor eax, eax
    jmp return
.destroyed_restore_failed:
    mov qword [rsp+0x48], 0
    jmp forward
.clear:
    mov r10, [rsp+0x40]
    mov dword [r10+148], 0
    mov dword [r10+144], 0
    mov qword [r10+152], 0
    mov qword [r10+160], 0
    cmp qword [rsp+0x48], 0
    jne .destroyed_return
    xor eax, eax
    jmp return
.destroyed_return:
    mov qword [rsp+0x48], 0
    jmp forward

forward:
    mov r10, [rsp+0x40]
    add rsp, 0x78
    jmp 0x100100                   ; preserved original input filter

return:
    add rsp, 0x78
    ret

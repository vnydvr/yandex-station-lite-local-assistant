.global _start
.type _start,@function
_start:
    xor %rbp, %rbp
    mov (%rsp), %rdi
    lea 8(%rsp), %rsi
    lea 8(%rsi,%rdi,8), %rdx
    call app_main
    mov %rax, %rdi
    mov $60, %rax
    syscall

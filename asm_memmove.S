#if defined(__APPLE__)
.text
.global _libc_memmove
.p2align  4, 0x90
_libc_memmove:
        jmp _memmove

#else
.text
.global libc_memmove
.p2align  4, 0x90
libc_memmove:
        jmp memmove
#endif

#if defined(__APPLE__)
.text
.global _asm_memmove
.p2align  5, 0x90
_asm_memmove:
#else
.text
.global asm_memmove
.p2align  5, 0x90
asm_memmove:
#endif

  mov  %rdi, %rax
  cmp  %rsi, %rdi
  je   .Lexit_memmove
  ja   .Lbackward

  jmp  asm_memcpy

.Lbackward:
  lea  -1(%rsi, %rdx), %rsi
  lea  -1(%rdi, %rdx), %rdi
  std
  mov  %rdx, %rcx
  rep  movsb
  cld
.Lexit_memmove:
  retq

.macro fn name, saves:vararg
.type \name, @function
\name:
.endm

.macro gfn name, saves:vararg
.global \name
.type \name, @function
\name:
.endm

.macro addr reg, sym
  lea \reg, [rip + \sym]
.endm

.macro load type, reg, sym
  mov \reg, \type ptr [rip + \sym]
.endm

.macro store type, sym, reg
  mov \type ptr [rip + \sym], \reg
.endm

.macro calla target
  sub rsp, 8
  call \target
  add rsp, 8
.endm



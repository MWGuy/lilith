.section .multiboot
.set MBOOT_HEADER_MAGIC, 0x1BADB002
.set MBOOT_PAGE_ALIGN,   1 << 0
.set MBOOT_MEM_INFO,     1 << 1
.set MBOOT_VID_INFO,     1 << 2
.set MBOOT_HEADER_FLAGS, MBOOT_PAGE_ALIGN | MBOOT_MEM_INFO | MBOOT_VID_INFO
.set MBOOT_CHECKSUM,     -(MBOOT_HEADER_MAGIC + MBOOT_HEADER_FLAGS)

# multiboot spec
.align 4
.long MBOOT_HEADER_MAGIC        # magic
.long MBOOT_HEADER_FLAGS        # flags
.long MBOOT_CHECKSUM            # checksum. m+f+c should be zero
.long 0, 0, 0, 0, 0
.long 0 # 0 = set graphics mode
.long 1024, 768, 32 # Width, height, depth

.section .text
.global _bootstrap_start
_bootstrap_start:
    # store multiboot
    mov %eax, (multiboot_magic)
    mov %ebx, (multiboot_header)
    # global descriptor table
    lgdt (gdt_table)
    # setup fxsr, xmmexcpt, pge, pae
    mov %cr4, %eax
    or $0x6A0, %ax
    mov %eax, %cr4
    # enable long mode by setting EFER flag
    mov $0xC0000080, %ecx
    rdmsr
    or $0x100, %eax
    wrmsr
    # enable paging
    mov $pml4, %eax
    mov %eax, %cr3
    mov %cr0, %eax
    or $0x80000000, %eax
    mov %eax, %cr0
    # restore multiboot
    mov (multiboot_magic), %eax
    mov (multiboot_header), %ebx
    ljmp $0x08, $kernel64

multiboot_magic: .long 0
multiboot_header: .long 0

.section .data
# global descriptor table
gdt_table:
    .word 3 * 8 - 1 # size
    .long gdt_null # offset
    .long 0

gdt_null:
    .quad 0

gdt_code:
    .word 0xFFFF # limit 0..15
    .word 0 # base 0..15
    .byte 0 # base 16.24
    .byte 0x9A # access
    .byte 0xAF # flags/attrs
    .byte 0 # base 24..31

gdt_data:
    .word 0xFFFF # limit 0..15
    .word 0 # base 0..15
    .byte 0 # base 16.24
    .byte 0x92 # access
    .byte 0xAF # flags/attrs
    .byte 0 # base 24..31

# identity page the first 1GiB of physical memory
# pml4
.align 0x1000
pml4:
    .long pdpt + 0x7
    .long 0
    .skip 0x1000 - 8
# pdpt
.align 0x1000
pdpt:
    .quad 0x87
    .skip 0x1000 - 8

.section .kernel64
.incbin "build/kernel64.bin"

#pragma once

#define IDT_SIZE 256
#define IDT_BASE 0x00000000
#define INTERRUPT_GATE 0x8e
#define TRAP_GATE 0x8f
#define KERNEL_CODE_SEGMENT_OFFSET 0x08

#include "stdint.h"

struct idtr {
    uint16_t limit;
    uint32_t base;
} __attribute__((packed));

struct idt_entry {
    uint16_t offset_1;  // offset bits 0..15
    uint16_t selector;  // a code segment selector in GDT or LDT
    uint8_t zero;       // unused, set to 0
    uint8_t type_attr;  // type and attributes
    uint16_t offset_2;  // offset bits 16..31
} __attribute__((packed));

struct idt_entry kidt[IDT_SIZE];
struct idtr kidtr;

void kinit_idtr();
void kinit_idt(int num, uint16_t select, uint32_t offset, uint16_t type);
void kirq_install(uint16_t num, uint32_t offset);
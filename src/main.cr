require "./drivers/serial.cr"
require "./drivers/vga.cr"
require "./core/panic.cr"

MULTIBOOT_BOOTLOADER_MAGIC = 0x2BADB002

lib Kernel
    fun kinit_gdtr()
end

fun kmain(mboot_magic : UInt32, mboot_header : Pointer(UInt8))
    if mboot_magic != MULTIBOOT_BOOTLOADER_MAGIC
        panic "Kernel should be booted from a multiboot bootloader!"
    end

    Serial.puts "initializing gdtr...\n"
    Kernel.kinit_gdtr()

    Serial.puts "done...\n"
    while true
    end
end
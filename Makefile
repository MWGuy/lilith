ARCH=i686-elf
AS=$(ARCH)-as
LD=ld
CC=gcc
LDFLAGS=-m elf_i386 -T link.ld
CCFLAGS=-c -m32 -g -nostdlib -nostdinc -fno-stack-protector -ffreestanding -Wall -Wno-unused-function
CRFLAGS=--cross-compile --target "i686-elf" --prelude empty -d -p
KERNEL_OBJ=build/main.cr.o \
	$(patsubst src/mem/%.c,build/mem.%.o,$(wildcard src/mem/*.c)) \
	build/boot.o


QEMUFLAGS ?=

QEMUFLAGS += \
	-rtc base=localtime \
	-monitor telnet:127.0.0.1:7777,server,nowait \
	-m 256 \
	-serial stdio \
	-no-shutdown -no-reboot

.PHONY: kernel
all: build/kernel

build/%.cr.o: src/%.cr
	@crystal build $(CRFLAGS) $< -o $(patsubst src/%.cr,build/%.cr,$<)
	@echo "CR $<"

build/mem.%.o: src/mem/%.c
	@$(CC) $(CCFLAGS) -Isrc -o $@ $<
	@echo "CC $<"

build/boot.o: boot.s
	@$(AS) $^ -o $@
	@echo "AS $<"

build/kernel: $(KERNEL_OBJ)
	@$(LD) $(LDFLAGS) -o $@ $^
	@echo "LD $^ => $@"

#
run: build/kernel
	-qemu-system-i386 -kernel $^ $(QEMUFLAGS)

rungdb: build/kernel
	qemu-system-i386 -S -kernel $^ $(QEMUFLAGS) -gdb tcp::9000 &
	gdb -quiet -ex 'target remote localhost:9000' -ex 'b kmain' -ex 'continue' build/kernel
	-@pkill qemu

runiso: os.iso
os.iso: build/kernel
	rm -rf /tmp/iso && mkdir -p /tmp/iso/boot/grub
	cp $^ /tmp/iso
	cp grub.cfg /tmp/iso/boot/grub
	grub-mkrescue -o os.iso /tmp/iso
	qemu-system-i386 -S -cdrom os.iso $(QEMUFLAGS) -gdb tcp::9000 &
	gdb -quiet -ex 'target remote localhost:9000' -ex 'b kmain' -ex 'continue' build/kernel
	-@pkill qemu

clean:
	rm -f */*.o
	rm -f *.o
	rm -f kernel

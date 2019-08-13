ARCH=x86_64-elf
LLVM_ARCH=x86-64
AS=$(ARCH)-as
LD=$(ARCH)-ld

ARCH32=i686-elf
AS32=$(ARCH32)-as
LD32=$(ARCH32)-ld
CR=toolchain/crystal/.build/crystal
LLC=llc

CRFLAGS=--cross-compile --emit llvm-ir --target $(ARCH) --prelude ./prelude.cr --error-trace
LLCFLAGS=-march=x86-64 -code-model=large -filetype=obj
ASFLAGS=-Isrc/asm/x64
LDFLAGS=-T link64.ld
KERNEL_OBJ=build/main.o build/boot.o
KERNEL_SRC=$(wildcard src/*.cr src/*/*.cr)

ifeq ($(RELEASE),1)
	LLCFLAGS += -O3
else
	LLCFLAGS += -O1
endif

QEMU = qemu-system-x86_64
# QEMU = /tmp/qemu/build/x86_64-softmmu/qemu-system-x86_64

QEMUFLAGS += \
	-rtc base=localtime \
	-monitor telnet:127.0.0.1:7777,server,nowait \
	-m 1G \
	-serial stdio \
	-no-shutdown -no-reboot \
	-vga std

GDB = /usr/bin/gdb

.PHONY: kernel src/asm/bootstrap.s
all: build/kernel

build/main.o: $(KERNEL_SRC)
	@echo "CR src/main.cr => build/main.ll"
	@cd build && FREESTANDING=1 ../$(CR) build $(CRFLAGS) ../src/main.cr -o main
	@echo "LLC build/main.ll => $@"
	@$(LLC) $(LLCFLAGS) -o $@ build/main.ll

build/%.o: src/asm/x64/%.s
	@echo "AS $<"
	@$(AS) $(ASFLAGS) $^ -o $@

build/kernel64: $(KERNEL_OBJ)
	@echo "LD64 $^ => $@"
	@$(LD) $(LDFLAGS) -o $@ $^

# bootstrapping code
build/kernel: build/bootstrap.o
	@echo "LD $^ => $@"
	@$(LD32) -T link.ld -o $@ build/bootstrap.o

build/kernel64.bin: build/kernel64
	objcopy --output-target=binary $< $@

build/bootstrap.o: src/asm/bootstrap.s build/kernel64.bin
	@echo "AS32 $<"
	$(AS32) $< -o $@

#
run: build/kernel
	-$(QEMU) -kernel $^ $(QEMUFLAGS)

run_img: build/kernel drive.img
	$(QEMU) -kernel build/kernel $(QEMUFLAGS) -hda drive.img

rungdb: build/kernel
	$(QEMU) -S -kernel $^ $(QEMUFLAGS) -gdb tcp::9000 &
	$(GDB) -quiet -ex 'target remote localhost:9000' -ex 'b kmain' -ex 'continue' build/kernel
	-@pkill qemu

rungdb_img: build/kernel drive.img
	$(QEMU) -kernel build/kernel $(QEMUFLAGS) -hda drive.img -S -gdb tcp::9000 &
	sleep 0.1s && $(GDB) -quiet \
		-ex 'set arch i386:x86-64:intel' \
		-ex 'target remote localhost:9000' \
		-ex 'hb kmain' \
		-ex 'continue' \
		-ex 'disconnect' \
		-ex 'set arch i386:x86-64:intel' \
		-ex 'target remote localhost:9000' \
		build/kernel64
	-@pkill qemu

rungdb_img_custom: build/kernel drive.img
	$(QEMU) -kernel build/kernel $(QEMUFLAGS) -hda drive.img -S -gdb tcp::9000 &
	$(GDB) -quiet -ex 'target remote localhost:9000' $(GDB_ARGS)
	-@pkill qemu

runiso: os.iso
	$(QEMU) -S -boot d -cdrom os.iso -hda drive.img $(QEMUFLAGS) -gdb tcp::9000 &
	sleep 0.1s && $(GDB) -quiet \
		-ex 'set arch i386:x86-64:intel' \
		-ex 'target remote localhost:9000' \
		-ex 'hb kmain' \
		-ex 'continue' \
		-ex 'disconnect' \
		-ex 'set arch i386:x86-64:intel' \
		-ex 'target remote localhost:9000' \
		build/kernel64
	-@pkill qemu

os.iso: build/kernel
	rm -rf /tmp/iso && mkdir -p /tmp/iso/boot/grub
	cp $^ /tmp/iso
	cp grub.cfg /tmp/iso/boot/grub
	cp build/kernel /tmp/iso/boot/
	grub-mkrescue -o os.iso /tmp/iso

clean:
	rm -f build/*
	rm -f kernel

# debug
toolchain/crystal:
	cd toolchain && git clone https://github.com/crystal-lang/crystal && \
	cd crystal && git checkout 0.30.0 && \
	patch -p1 < ../crystal.patch

$(CR): toolchain/crystal
	cd toolchain/crystal && make release=1

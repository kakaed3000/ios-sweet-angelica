#!/bin/bash
# Build the shim and wrap it in a boot.img v2 matching angelica's stock header
# (page 2048, base 0x40000000, kernel 0x40080000, dtb/tags 0x47880000).
set -euo pipefail
cd "$(dirname "$0")"
CC="clang --target=aarch64-linux-gnu"
CFLAGS="-O2 -ffreestanding -nostdlib -fno-pic -mgeneral-regs-only -mstrict-align -fno-stack-protector -fno-jump-tables -Wall -Wextra"
DTB="${DTB:-../../ref/unpacked/dtb}"
[ -f "$DTB" ] || { echo "missing DTB: $DTB (set DTB=...)" >&2; exit 1; }
mkdir -p out
for f in start.S shim.c console.c fdt.c loader.c; do
	$CC $CFLAGS -c "$f" -o out/${f%.*}.o
done
# The image runs wherever LK puts it with no relocation pass: only the
# header's image_size (start.o, linked at 0) may be an absolute address.
abs=$(readelf -r out/shim.o out/console.o out/fdt.o out/loader.o | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }
$CC $CFLAGS -static -T shim.ld -fuse-ld=lld -Wl,--build-id=none -Wl,-N \
	out/start.o out/shim.o out/console.o out/fdt.o out/loader.o -o out/shim.elf
# ELF -> raw Image (no objcopy for aarch64 on this host).
python3 - "$DTB" <<'EOF'
import struct, sys
d = open('out/shim.elf', 'rb').read()
assert d[:4] == b'\x7fELF', 'not an ELF'
phoff, = struct.unpack_from('<Q', d, 0x20)
phentsize, phnum = struct.unpack_from('<HH', d, 0x36)
img = bytearray()
base = None
for i in range(phnum):
    o = phoff + i * phentsize
    ptype, = struct.unpack_from('<I', d, o)
    if ptype != 1:
        continue
    poff, = struct.unpack_from('<Q', d, o + 8)
    vaddr, = struct.unpack_from('<Q', d, o + 16)
    filesz, = struct.unpack_from('<Q', d, o + 32)
    memsz, = struct.unpack_from('<Q', d, o + 40)
    if base is None or vaddr < base:
        base = vaddr
    end = vaddr + memsz - base
    if end > len(img):
        img.extend(b'\0' * (end - len(img)))
    rel = vaddr - base
    img[rel:rel + filesz] = d[poff:poff + filesz]
open('out/Image', 'wb').write(bytes(img))
print('Image: %d bytes (linked at 0x%x)' % (len(img), base))
EOF
# Pad to image_size so .bss/stacks exist as zeroed bytes.
size=$(readelf -Ws out/shim.elf | awk '$8=="_end"{print "0x"$2}')
truncate -s "$((size))" out/Image
# Ramdisk: an xnu payload (tools/mkpayload.py) if given as $1, else an empty
# newc cpio (LK dislikes a zero-size ramdisk) -> diagnostics.
if [ -n "${1:-}" ]; then
	cp "$1" out/ramdisk.bin
else
	(cd out && rm -rf rd && mkdir rd && cd rd && find . | cpio -o -H newc --quiet | gzip -9 > ../ramdisk.bin)
fi
mkbootimg --header_version 2 --kernel out/Image --ramdisk out/ramdisk.bin \
	--dtb "$DTB" --base 0x40000000 --kernel_offset 0x80000 --ramdisk_offset 0x11b00000 \
	--tags_offset 0x7880000 --dtb_offset 0x7880000 --pagesize 2048 \
	--os_version 10.0.0 --os_patch_level 2023-01 \
	--cmdline "bootopt=64S3,32N2,64N2" -o out/shim-boot.img
# Round-trip check against the unpacker.
python3 ../tools/unpack_bootv2.py out/shim-boot.img out/check
cmp out/check/ramdisk out/ramdisk.bin
# Host render of the console layout.
gcc -O1 -Wall -o out/host_test console.c host_test.c && ./out/host_test
ls -l out/Image out/shim-boot.img

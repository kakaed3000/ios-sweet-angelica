ENTRY(_head)
SECTIONS
{
	. = 0;
	.text.head : { *(.text.head) }
	/* LK jumps to kernel_addr = base + text_offset (0x80000): the
	 * arm64 convention - real code lives there, the 64-byte header sits
	 * at the image start. Stock kernels' _text is at file offset
	 * 0x80000 too (verified on the MIUI angelica kernel). */
	. = 0x80000;
	.text : { *(.text*) }
	.rodata : { *(.rodata*) }
	.data : { *(.data*) }
	. = ALIGN(16);
	_bss_start = .;
	.bss : { *(.bss*) *(COMMON) }
	. = ALIGN(16);
	_bss_end = .;
	. += 0x8000;
	. = ALIGN(16);
	_stack_top = .;
	. = ALIGN(4096);
	_sec_stacks = .;
	. += 8 * 0x1000;
	_end = .;
	/DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}

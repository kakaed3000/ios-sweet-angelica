/*
 * angelica boot shim entry: arm64 Linux Image header so the MediaTek LK
 * treats us like a kernel.  LK enters at EL3 (bootopt=64S3) or EL2,
 * MMU/D-cache off, x0 = DTB pointer.  Drop to EL1h first.
 */
	.section .text.head, "ax"
	.globl _head
_head:
	b	_start			/* code0 */
	.long	0			/* code1 */
	.quad	0x80000			/* text_offset: base + 0x80000 = load addr */
	.quad	_end			/* image_size (linked at 0) */
	.quad	0xa			/* flags: LE, 4K pages, place anywhere */
	.quad	0			/* res2 */
	.quad	0			/* res3 */
	.quad	0			/* res4 */
	.ascii	"ARM\x64"		/* magic */
	.long	0			/* res5 (PE offset) */

	.text
	.globl _start
_start:
#if CANARY
	/* Bisect build: paint the framebuffer white and park. No EL drop,
	 * no stack, no C code - if this shows, entry + LK load are fine. */
	mov	x1, #0x5000
	movk	x1, #0x05e6, lsl #16	/* fb 0x5e605000 */
	mov	w2, #-1			/* white, 32bpp */
	movz	w3, #0x9400
	movk	w3, #0x11, lsl #16	/* 720 * 1600 */
1:	str	w2, [x1], #4
	subs	w3, w3, #1
	b.ne	1b
2:	wfi
	b	2b
#else
	msr	daifset, #0xf
	adr	x10, el1_start		/* continuation once at EL1 */
	b	el_check
#endif

/* PSCI CPU_ON target. x0 = context id = cpu index (1..7). */
	.globl secondary_entry
secondary_entry:
	msr	daifset, #0xf
	adr	x10, sec_el1_start

/* Drop EL3/EL2 -> EL1h. x0 (DTB / context id) preserved; uses x9, x10. */
el_check:
	mrs	x9, CurrentEL
	lsr	x9, x9, #2
	cmp	x9, #3
	b.eq	el3_drop
	cmp	x9, #2
	b.eq	el2_drop
el_drop_ret:
	br	x10

el3_drop:
	mov	x9, #0x5c1		/* SCR_EL3: RES1|RW|HCE|SMD|NS */
	msr	scr_el3, x9
	mov	x9, #0x3c5		/* SPSR: EL1h, DAIF masked */
	msr	spsr_el3, x9
	adr	x9, el2_drop
	msr	elr_el3, x9
	eret

el2_drop:
	mrs	x9, cnthctl_el2		/* EL1 may use the physical timers */
	orr	x9, x9, #3		/* EL1PCTEN | EL1PCEN */
	msr	cnthctl_el2, x9
	msr	cnthp_ctl_el2, xzr
	msr	cntvoff_el2, xzr
	mov	x9, #(1 << 31)		/* HCR_EL2.RW: EL1 is AArch64 */
	msr	hcr_el2, x9
	mov	x9, #0x3c5
	msr	spsr_el2, x9
	adr	x9, el_drop_ret
	msr	elr_el2, x9
	eret

el1_start:
	mov	x19, x0			/* DTB pointer from the bootloader */
	msr	spsel, #1
	adr	x1, _stack_top
	mov	sp, x1
	adr	x1, vectors
	msr	vbar_el1, x1
	isb
	/* zero .bss */
	adr	x1, _bss_start
	adr	x2, _bss_end
1:	cmp	x1, x2
	b.hs	2f
	str	xzr, [x1], #8
	b	1b
2:	mov	x0, x19
	bl	shim_main
3:	wfe
	b	3b

sec_el1_start:
	msr	spsel, #1
	adr	x1, _sec_stacks
	add	x1, x1, x0, lsl #12
	add	x1, x1, #0x1000
	mov	sp, x1
	adr	x1, vectors
	msr	vbar_el1, x1
	isb
	bl	secondary_main
4:	wfe
	b	4b

/*
 * Exception vectors. Each slot stashes x29/x30, loads its slot number
 * and jumps to the common path, which saves x0-x28 and calls
 * exc_handler(slot, regs). IRQs return; everything else ends in the
 * on-screen panic.
 */
.macro vent slot
	.balign	0x80
	stp	x29, x30, [sp, #-16]!
	mov	x29, #\slot
	b	exc_common
.endm

	.balign	0x800
	.globl vectors
vectors:
	vent 0
	vent 1
	vent 2
	vent 3
	vent 4
	vent 5
	vent 6
	vent 7
	vent 8
	vent 9
	vent 10
	vent 11
	vent 12
	vent 13
	vent 14
	vent 15

exc_common:
	sub	sp, sp, #(30 * 8)
	stp	x0, x1, [sp, #0]
	stp	x2, x3, [sp, #16]
	stp	x4, x5, [sp, #32]
	stp	x6, x7, [sp, #48]
	stp	x8, x9, [sp, #64]
	stp	x10, x11, [sp, #80]
	stp	x12, x13, [sp, #96]
	stp	x14, x15, [sp, #112]
	stp	x16, x17, [sp, #128]
	stp	x18, x19, [sp, #144]
	stp	x20, x21, [sp, #160]
	stp	x22, x23, [sp, #176]
	stp	x24, x25, [sp, #192]
	stp	x26, x27, [sp, #208]
	str	x28, [sp, #224]
	mov	x0, x29
	mov	x1, sp
	bl	exc_handler
	ldp	x0, x1, [sp, #0]
	ldp	x2, x3, [sp, #16]
	ldp	x4, x5, [sp, #32]
	ldp	x6, x7, [sp, #48]
	ldp	x8, x9, [sp, #64]
	ldp	x10, x11, [sp, #80]
	ldp	x12, x13, [sp, #96]
	ldp	x14, x15, [sp, #112]
	ldp	x16, x17, [sp, #128]
	ldp	x18, x19, [sp, #144]
	ldp	x20, x21, [sp, #160]
	ldp	x22, x23, [sp, #176]
	ldp	x24, x25, [sp, #192]
	ldp	x26, x27, [sp, #208]
	ldr	x28, [sp, #224]
	add	sp, sp, #(30 * 8)
	ldp	x29, x30, [sp], #16
	eret

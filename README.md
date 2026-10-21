# NexRedmi Project | xnuL (xnu Loader)

**Apple's iOS 16 kernel and userland on Xiaomi phones.**

xnuL is the NexRedmi bare-metal loader (formerly called `shim`). It takes over
from the stock bootloader, sets up its own MMU and display, loads the XNU
kernel together with a generated Apple Device Tree, and jumps into XNU.
On top of the kernel runs the **unmodified iOS 16.7.16 (20H392) userland of the
iPhone X**: launchd, the system daemons, backboardd, SpringBoard and the stock
apps.

Two devices are involved in this tree:

| Device | Codename | SoC | Role |
| --- | --- | --- | --- |
| Redmi 9C | `angelica` | MediaTek MT6765 (Helio G35, 8× Cortex-A53) | **active target** (branch `angelica`) |
| Redmi Note 10 Pro | `sweet` | Qualcomm SM7150 (Snapdragon 732G, 2× A76 + 6× A55) | separate upstream project ([dipa-studio/ios-sweet](https://github.com/dipa-studio/ios-sweet)) whose kernel patch base this tree started from |

The Redmi Note 10 Pro work is **not an earlier goal of this project**: it is
another project (`dipa-studio/ios-sweet`) that already runs iOS 16 on that
phone. NexRedmi takes its kernel patch base and tooling and targets `angelica`.
The word "sweet" in this tree always names that phone's codename, never this
project.

> Status as of **2026-10-21**. This is an experimental bring-up, not a usable
> phone OS. Apple's security model is mostly switched off.

## Where the Redmi 9C port stands

The loader side works and the kernel now survives the MMU handoff. XNU boots
into `arm_init` and runs early C code (the framebuffer shows the `SWEET EARLY`
markers 1–4), then stops at the next missing CPU feature. The iOS userland has
**not** been run on `angelica` yet.

| Area | State on `angelica` |
| --- | --- |
| Bootloader / flashing | Works: stock unlocked MediaTek LK → `fastboot flash boot` of the xnuL image. `fastboot boot` is unreliable on this LK variant; always flash. |
| xnuL | Works: EL3→EL1 drop, own page tables, display takeover (OVL/RDMA), live-FDT parsing, payload loading (Mach-O segments + ADT + boot_args), framebuffer console, watchdog disabled |
| Console | Visible on the phone panel (720×1600, fb `0x5e605000`); there is no usable serial UART |
| XNU kernel build | Works: 4K hardware page tables, 16K software pages (iOS ABI), ARMv8.0 code generation, classic non-large-memory virtual layout |
| XNU early boot | Reaches `arm_init` and markers 1–4 (`arm_init`, platform expert, topology, CPU bootstrap) |
| Barriers already fixed | 16K-page kernel on an A53 (the core has no 16K granule); TTBR1 walk from L0 with `T1SZ=23` under the 4K bootstrap tables; ARMv8.1 LSE atomics emitted by the Apple toolchain |
| Current blocker | The LSE fix (`0088`, `-mcpu=cortex-a53+crypto`) is committed and being verified in CI; the resulting image has not been flashed yet |
| iOS userland | Not started on `angelica` (no root filesystem flashed, no launchd/SpringBoard) |
| Storage root | MSDC/eMMC root driver exists (`0083`, polled single-block reads, untested on hardware) |
| Display/UI/touch/keys | Not implemented for `angelica` yet; the iOS graphics stack is the upstream project's |

Everything below about the working GUI refers to the **separate
`dipa-studio/ios-sweet` project for the Redmi Note 10 Pro**, not to this port.

## What the upstream ios-sweet project does

In that project the Redmi Note 10 Pro boots to the **iOS home screen** (as of 2026-10-18): you
can unlock it, open Settings, pull down Control Center and the notification
center, and use the touchscreen and hardware buttons. Rendering runs entirely on
the CPU; there is no GPU driver.

- Boot: stock ABL (Qualcomm) → their loader → XNU → UFS driver → HFS+ root in `userdata` →
  dyld + shared cache → launchd → daemons → backboardd + SpringBoard
- CPU: 6 of 8 cores (Cortex-A55s) via PSCI, GICv3, timers
- Display: kernel IOSurface + IOMobileFramebuffer (`AppleCLCD`), CPU rendering,
  frames copied into the bootloader framebuffer, presented as an iPhone X panel
  (1125×2436)
- Touch: Goodix GT9896 over I²C; buttons through SPMI; battery/device identity
  and the native activation path

Known limits there: navigation gestures are incomplete, no Wi-Fi/Bluetooth/
cellular/audio/camera/sensors/GPS/SEP, no GPU, few apps, ~4 minute boot, and
code signing/sandbox/data protection are stubbed. **Do not put personal data
on it.**

## How xnuL boots the kernel

```
MediaTek preloader + LK (stock Xiaomi bootloader, unlocked)
  -> fastboot flash boot xnul-boot.img        (roll back with the stock boot.img)
     -> xnuL: EL drop, own MMU, display takeover, live FDT
        -> payload (kernel Mach-O segments + ADT + boot-args)
           -> XNU
```

The boot image is an Android `boot.img` v2: the gzip xnuL `Image` is the
"kernel" and the xnuL payload is the "ramdisk". On `angelica` the image uses
page size 2048, kernel address `0x40080000`, DTB/tags `0x47880000` and the
stock cmdline (`bootopt=64S3,32N2,64N2 buildvariant=user`). The kernel payload
uses `phys_base=0x60000000`, `mem_size=0x60000000` (1.5 GiB) and boots with
`rd=msdcroot0 keepsyms=1 -enable_kprintf_spam debug=0x14c`.

## Building

### Kernel (GitHub Actions)

The kernel builds on GitHub's macOS runners with
[blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build):
xnu-8796.141.3 is fetched, `xnu/patches/` is applied in order, and the pinned
open-source libpthread/HFS/BearSSL sources are staged. A push that touches
`xnu/patches/**` on the `angelica` branch builds `DEVELOPMENT`/`ANGELICA`
automatically; a manual run needs `machine_config=ANGELICA`.

```sh
gh workflow run xnu.yml -R YOU/nexredmi-xnul -f machine_config=ANGELICA
gh run download RUN_ID -R YOU/nexredmi-xnul -n xnu-kernel -D xnu/out
```

Artifacts: `xnu-kernel` (`kernel.development.angelica`, the dSYM/link info and
`SHA256SUMS`) and `xnu-buildtree`.

### Boot image

Needs Python 3, `mkbootimg`, and for xnuL itself `clang` + `ld.lld` (the host
build script targets `aarch64-linux-gnu` and packs the image with `mkbootimg`).

```sh
python3 tools/mkadt.py xnul/out/angelica.adt --angelica
python3 tools/mkpayload.py xnu/out/kernel.development.angelica \
    xnul/out/angelica.adt xnul/out/payload.bin \
    --cmdline 'rd=msdcroot0 keepsyms=1 -enable_kprintf_spam debug=0x14c'
cd xnul && OUT=out/xnul-boot-angelica.img ./build.sh ../xnul/out/payload.bin
```

The builder checks that the ELF has no absolute relocations, converts it to a
raw arm64 `Image`, gzips it, appends the DTB (stock `dtb` by default, override
with `DTB=...`), and verifies the unpacked image round-trips.

### Flash

```sh
fastboot flash boot xnul/out/xnul-boot-angelica.img
fastboot reboot
```

Never use `fastboot boot` on this device. Keep the stock `boot.img` around for
rollback. Flashing `boot` does not touch `userdata`; **no iOS root image has
been flashed on `angelica` yet**.

### Diagnostics

There is no serial console. xnuL draws on the panel from the first instruction,
and the kernel console uses the same framebuffer (`0084`); panics are printed
there. The display shows the early markers, so a photo of the screen is the
primary log.

## Repository layout

| Path | What |
| --- | --- |
| `xnul/` | xnuL, the bare-metal loader (C + asm) packed as an Android `boot.img` v2 |
| `xnu/patches/` | XNU patch series, applied in order by CI |
| `.github/workflows/xnu.yml` | Kernel CI build |
| `tools/mkadt.py` | Generates the Apple Device Tree (MMIO, CPU, display, identity); `--angelica` for the Redmi 9C |
| `tools/mkpayload.py` | Packs kernel + ADT + boot-args into the xnuL payload |
| `tools/unpack_bootv2.py` | Android `boot.img` v2 unpacker (headers, DTB, round-trip checks) |
| `tools/mkiosroot.sh` | Builds the HFS+ iOS root from IPSW images (upstream ios-sweet project) |
| `tools/sweet-root-tweaks.py` | Bring-up changes to that root (Setup skip, activation, daemons) |
| `tools/sweet-log-pull.sh`, `sweet-log.py` | Read the persistent kernel log from recovery (upstream ios-sweet project) |
| `tools/sweet-crash.py` | Symbolicate console crash reports |
| `tools/xnu-cc.py` | Local single-file compile check from a CI log |
| `tools/qemu-sweet.py` | QEMU test boots (upstream sweet configuration) |
| `tools/adt.py`, `remotezip.py`, `sparsediff.py` | Helpers |
| `NOTES.md` | Detailed engineering log: every boot, crash, decision and hardware fact |

Not in git: partition backups, live device trees, recovery images, Apple
firmware/root images, and generated build trees. They contain device serials and
calibration data, or Apple's copyrighted files.

## Patch series (high level)

| # | What |
| --- | --- |
| 0001–0009 | Toolchain compatibility, SWEET machine config, non-PAC arm64, stubs for Apple-internal pieces |
| 0010–0018 | Early framebuffer console, physmap fix, PRNG, device-tree platform expert, timer PPI, boot CPU |
| 0019–0027 | libpthread provider, BearSSL AES, RAM-disk root, mockfs, SHA-256, minimal AMFI, HFS+ |
| 0028–0034 | UFS host driver and root device, read/write root, DMA above 4 GiB (upstream sweet project) |
| 0035–0045 | Entitlements, bindfs, AppleKeyStore stub, IOWatchdog, crash reports |
| 0046 | IOSurface + IOMobileFramebuffer (`AppleCLCD`) services |
| 0047–0057 | Diagnostics, sandbox permissiveness, HFS fixes, throttled panel copy |
| 0058–0069 | HID family, iPhone X identity, SPMI keys, GENI touch, RPMh, SMP, persistent log |
| 0082 | ANGELICA machine config (dual board config, A53 feature set) |
| 0083 | ANGELICA MSDC/eMMC read-only root device (untested) |
| 0084 | ANGELICA early framebuffer markers/panic console |
| 0085 | 4K hardware page tables (A53 has no 16K granule) |
| 0086 | Commpage assert exception for the first 4K build (superseded by 0087) |
| 0087 | Classic non-large-memory layout for 4K (TTBR1 roots at L1, `T1SZ=25`) |
| 0088 | Build ANGELICA with `-mcpu=cortex-a53+crypto` (no ARMv8.1 LSE atomics) |

## Warnings

- Experimental. Expect hangs, panics and data loss; the upstream ios-sweet build
  already erases `userdata`, and this port will do the same once an iOS root is flashed.
- Security is deliberately off: permissive AMFI, stub AppleKeyStore, no data
  protection, no sandbox profiles. Never store personal data.
- Only flash `boot` on `angelica` until the port reaches userland. Keep stock
  `boot`, `dtbo`, `vbmeta` and partition backups (persist, modemst1/2, fsg,
  fsc); never touch bootloader/recovery/modem/persist.
- Apple's iOS images and the iPhone X device tree are not distributed here.

## Credits

Built on Apple's open-source releases (xnu, IOHIDFamily, libpthread, hfs), the
[dipa-studio/ios-sweet](https://github.com/dipa-studio/ios-sweet) project (the
Redmi Note 10 Pro port this tree started from),
[BearSSL](https://bearssl.org),
[blacktop/darwin-xnu-build](https://github.com/blacktop/darwin-xnu-build),
[ipsw](https://github.com/blacktop/ipsw), Qualcomm/Xiaomi's published Linux
kernel sources, and [OrangeFox Recovery](https://orangefox.download). iOS itself
is Apple's and is not distributed here.

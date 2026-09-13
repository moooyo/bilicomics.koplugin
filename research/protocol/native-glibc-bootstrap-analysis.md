# glibc 2.20 ARM loader bootstrap: confirmed Thumb load-bias error

Date: 2026-09-12. This analysis concerns the original `do-rel.h:116`
bootstrap assertion only. The analysis agent performed static source/ELF
inspection; the root task independently collected instruction-state traces
and ran the causal control. No production plugin artifact, original official
loader, or original official runtime library was modified.

## Finding

The official koxtoolchain loader combines an old glibc Thumb load-address
calculation with newer GNU assembler behavior. The PC-relative address retains
its Thumb bit while the GOT-derived address has that bit cleared. Their
subtraction produces `load_base + 1`, so the loader scans its own dynamic table
one byte late and never records `DT_VERSYM`.

This is the precise issue addressed by glibc commit
[`5ba6405338c280a3d84dcab1a11dcd1df9b5bee8`](https://github.com/bminor/glibc/commit/5ba6405338c280a3d84dcab1a11dcd1df9b5bee8),
dated 2017-07-13 and titled **[ARM] Fix ld.so crash when built using Binutils
2.29**. The commit identifies glibc bug 21725 and GAS PR 21458. It adds a
second mask under `__thumb__`:

```c
pcrel_addr &= ~(Elf32_Addr) 1;
```

The unmodified loader's root-task trace confirms every intermediate address,
and a root-task private-copy causal control restores `luajit -v` startup by
correcting only the corresponding ADR immediate. This resolves the original
self-bootstrap failure; it is not a claim that later application or library
tests passed.

## Exact artifact and upstream implementation

- Official loader SHA-256:
  `6f4bbe8b68bf2bf290c6125d4ccee6a44df4451e30866e75beecbcb7f1c4011c`.
- Official koxtoolchain release: `2026.08`, `kindlehf.tar.zst`.
- Archived configuration: GNU glibc 2.20, Thumb code generation, binutils 2.43.1.
- The nineteen glibc 2.20 patches in the selected
  [crosstool-NG commit](https://github.com/benoit-pierre/crosstool-ng/tree/34844bc8e985ad1ba26b072a5b58264967072e19/packages/glibc/2.20)
  do not touch `dl-machine.h` or the dynamic-table/version-parsing headers.
  The actual loader instructions also show that the second mask is absent.

In [glibc 2.20 `sysdeps/arm/dl-machine.h:54-64`](https://github.com/bminor/glibc/blob/glibc-2.20/sysdeps/arm/dl-machine.h#L54),
`elf_machine_load_address()` obtains `_dl_start` through the GOT, clears that
address's low bit in Thumb mode, obtains a PC-relative address with `adr`, and
subtracts the former from the latter. It does not clear the PC-relative low bit.

The GNU assembler behavior is directly visible in binutils 2.43.1:
[`gas/config/tc-arm.c:11640-11644`](https://github.com/RTEMS/sourceware-mirror-binutils-gdb/blob/binutils-2_43_1/gas/config/tc-arm.c#L11640).
`do_t_adr()` recognizes a defined Thumb function symbol and adjusts the addend:

```c
inst.relocs[0].exp.X_add_number += 1;
```

The change originated in GAS commit
[`52a86f843b6dee1de9977293da9786649b146b05`](https://github.com/RTEMS/sourceware-mirror-binutils-gdb/commit/52a86f843b6dee1de9977293da9786649b146b05)
on 2017-05-15, explicitly for PR gas/21458. These binutils links are the RTEMS
mirror of the Sourceware Git repository. A later ARM interworking change does
not remove the Thumb `do_t_adr()` adjustment. The glibc fix therefore handles
both the earlier and later assembler conventions by masking both addresses.

## Source order and the dynamic-table slot

The relevant glibc source order is:

1. [`rtld.c:379-398`](https://github.com/bminor/glibc/blob/glibc-2.20/elf/rtld.c#L379)
   computes the loader bias, obtains `_DYNAMIC` from GOT[0], populates
   `bootstrap_map.l_info`, and relocates the loader itself.
2. [`get-dynamic-info.h:44-63`](https://github.com/bminor/glibc/blob/glibc-2.20/elf/get-dynamic-info.h#L44)
   scans `Elf32_Dyn` entries until `DT_NULL`. A correctly encountered
   `DT_VERSYM` tag, `0x6ffffff0`, populates index
   `34 + (0x6fffffff - 0x6ffffff0) = 49`. Bootstrap mode does not exclude it.
3. [`do-rel.h:111-116`](https://github.com/bminor/glibc/blob/glibc-2.20/elf/do-rel.h#L111)
   asserts that this slot holds a dynamic-entry pointer. The test is not a
   comparison of the version table's `d_ptr` value against zero.
4. Only after self-relocation does `_dl_start` call `_dl_start_final`.
   [`_dl_start_final:304-308`](https://github.com/bminor/glibc/blob/glibc-2.20/elf/rtld.c#L304)
   then calls `_dl_sysdep_start` to process operating-system startup data.

Consequently, the observed failure precedes normal auxiliary-vector handling
of the executable's `AT_PHDR`/`AT_BASE`. Those values are not the source of this
confirmed arithmetic error. Likewise, no plugin or dependent-library code has
run when the original assertion fires.

## Static ELF arithmetic and independent execution trace

Let `B` be the loader's page-aligned mapping base. In this artifact:

| Item | Value |
| --- | --- |
| `_dl_start` Thumb symbol | `0x38b9` |
| Actual first instruction | `0x38b8` |
| GOT virtual address | `0x19000` |
| GOT slot for `_dl_start` | `0x19024`, containing `0x38b9` before relocation |
| GOT[0] | `0x18f44`, the link-time `_DYNAMIC` address |
| ADR instruction | offset `0x38e4`, `subw r2, pc, #0x2f` |
| Architectural PC for that ADR | `B + 0x38e8` |
| ADR result | `B + 0x38b9` |
| GOT result after `bic ..., #1` | `0x38b8` |
| Incorrect subtraction | `(B + 0x38b9) - 0x38b8 = B + 1` |

The static literal words also agree: `0x3d18 = 0x1571e`,
`0x3d1c = 0x24`, and `0x3d20 = 0x15712` calculate the two GOT references and
function slot above. The dynamic table's real `DT_VERSYM` entry is at virtual
address `0x18fc4`, with value `0x604`.

The root task's unmodified-loader trace observes `B = 0x400000`:

| Instruction boundary | Observed state |
| --- | --- |
| `B + 0x38e8`, after ADR | `r2 = 0x4038b9` |
| `B + 0x38f2`, after GOT low-bit clear | `r3 = 0x38b8` |
| `B + 0x38f6`, after subtraction | `r11 = 0x400001` |
| `B + 0x3904`, dynamic scan begins | `r1 = 0x418f45`, first tag `r3 = 0x77000000` |
| `B + 0x3c68`, version-slot assertion | `r3 = 0`, read from `r9 + 0xe4` |

Reading the original ELF bytes at `_DYNAMIC + 1` independently explains the
scan: it starts with tag `0x77000000` and encounters a false zero tag at
`0x18f7d`, before reaching the real version entry. The loader has a valid
`DT_VERSYM` on disk; the runtime cursor is wrong. The slot at `r9 + 0xe4`
corresponds to `l_info[49]` in this ELF32 layout.

The compact trace record is
[`native-glibc-bootstrap-trace-result.json`](native-glibc-bootstrap-trace-result.json).
The root task recorded one instruction per translation block; it did not change
the official loader or load plugin code for that trace.

## Causal control and the one-byte correction boundary

The root task copied the sysroot into a new private diagnostic directory and
changed only file offset `0x38e6` in that copy:

```text
Original instruction bytes: aff22f02  (ADR subtracts 0x2f)
Control instruction bytes:  aff23002  (ADR subtracts 0x30)
```

For this exact artifact, the corrected result is
`(B + 0x38e8) - 0x30 = B + 0x38b8`. Since the original result is always odd
for a page-aligned `B`, subtracting this extra one is equivalent at this site
to the upstream mask `pcrel_addr & ~1`. It does not change the Thumb function's
entry symbol, disable assertions, edit dynamic tags, or suppress relocation.

This equivalence is specific to the verified instruction encoding and layout.
It is not a generic byte patch for other loaders, compiler outputs, or firmware.
A source-level backport of the upstream fix is the general repair; this control
is only a narrowly described diagnostic intervention.

The diagnostic loader has SHA-256
`23f586c4b79afe238c1f7274838bcf2de80f7bd2cd954b094a5066902992ac6a`.
The original loader retains SHA-256 `6f4bbe8b...f1c4011c`; the original official
LuaJIT and all other core runtime libraries retain their recorded hashes.
Under the same QEMU, the unchanged official LuaJIT's `-v` invocation changes
from assertion/exit 127 to successful exit 0. See
[`native-glibc-bootstrap-control-result.json`](native-glibc-bootstrap-control-result.json).

This control proves the cause of the original self-bootstrap assertion. It
does not turn the corrected copy into an unmodified official-runtime pass,
prove full crypto execution, or describe the user's actual Scribe firmware
loader. Later failures after dependency loading belong to separate evidence.

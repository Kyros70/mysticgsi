"""Make libutils work on kernels without epoll_pwait2 (added in Linux 5.11).

Android 17's libutils (Looper) calls epoll_pwait2(). On older kernels the syscall returns
ENOSYS, every Looper poll fails and the device never finishes booting. Instead of touching
libc (inside the runtime APEX) or the kernel, the PLT entry that libutils uses for
epoll_pwait2 is redirected to a small stub that converts the timespec to milliseconds
(rounding up) and tail-calls epoll_wait, which libutils already imports. The Looper call
passes no signal mask, which epoll_wait does not need.

The stub lives in the zero padding that follows the last byte of the executable PT_LOAD
segment, inside the page that is mapped anyway. Only the first instruction of the
epoll_pwait2 PLT entry and that padding are modified. Works on 64-bit (AArch64) and
32-bit (ARM) libraries.
"""

import os
import struct

from .context import PatchContext

EM_ARM = 40
EM_AARCH64 = 183
R_ARM_JUMP_SLOT = 22
R_AARCH64_JUMP_SLOT = 1026

# AArch64: epoll_pwait2(epfd, events, maxevents, const timespec *ts, sigmask) -> epoll_wait(..., ms)
# x3 = timespec*, NULL means wait forever. Words at index 15 and 17 are the branches to the
# epoll_wait PLT entry and are filled in at patch time.
_STUB64 = [
    0xB4000203,  # cbz  x3, inf
    0xA9402468,  # ldp  x8, x9, [x3]
    0xD2807D0A,  # mov  x10, #1000
    0x9B0A7D08,  # mul  x8, x8, x10
    0xD288480A,  # movz x10, #0x4240
    0xF2A001EA,  # movk x10, #0xf, lsl #16      (x10 = 1000000)
    0x8B0A0129,  # add  x9, x9, x10
    0xD1000529,  # sub  x9, x9, #1
    0x9ACA0929,  # udiv x9, x9, x10             (ceil(nsec / 1e6))
    0x8B090108,  # add  x8, x8, x9
    0x529FFFEA,  # movz w10, #0xffff
    0x72AFFFEA,  # movk w10, #0x7fff, lsl #16   (INT_MAX)
    0xEB0A011F,  # cmp  x8, x10
    0x9A8A3108,  # csel x8, x8, x10, lo
    0x2A0803E3,  # mov  w3, w8
    None,        # b    epoll_wait@plt
    0x12800003,  # inf: mov w3, #-1
    None,        # b    epoll_wait@plt
]
_SLOTS64 = (15, 17)

# ARM (ARM state, r3 = timespec*), r4-r6 are saved and restored.
_STUB32 = [
    0xE3530000,  # cmp   r3, #0
    0x0A000011,  # beq   inf
    0xE92D0070,  # push  {r4, r5, r6}
    0xE5934000,  # ldr   r4, [r3]
    0xE5935004,  # ldr   r5, [r3, #4]
    0xE304C240,  # movw  ip, #0x4240
    0xE340C00F,  # movt  ip, #0xf               (ip = 1000000)
    0xE085500C,  # add   r5, r5, ip
    0xE2455001,  # sub   r5, r5, #1
    0xE735FC15,  # udiv  r5, r5, ip             (ceil(nsec / 1e6))
    0xE3A0CFFA,  # mov   ip, #1000
    0xE0863C94,  # umull r3, r6, r4, ip
    0xE0933005,  # adds  r3, r3, r5
    0xE2A66000,  # adc   r6, r6, #0
    0xE3560000,  # cmp   r6, #0
    0x13E03102,  # mvnne r3, #0x80000000        (clamp to INT_MAX)
    0xE3530000,  # cmp   r3, #0
    0xB3E03102,  # mvnlt r3, #0x80000000
    0xE8BD0070,  # pop   {r4, r5, r6}
    None,        # b     epoll_wait@plt
    0xE3E03000,  # inf: mvn r3, #0
    None,        # b     epoll_wait@plt
]
_SLOTS32 = (19, 21)


def _b64(src, dst):
    delta = (dst - src) >> 2
    if not -(1 << 25) <= delta < (1 << 25):
        raise ValueError("branch out of range")
    return 0x14000000 | (delta & 0x03FFFFFF)


def _b32(src, dst):
    delta = (dst - (src + 8)) >> 2
    if not -(1 << 23) <= delta < (1 << 23):
        raise ValueError("branch out of range")
    return 0xEA000000 | (delta & 0x00FFFFFF)


def _parse_elf(data):
    if data[:4] != b"\x7fELF" or data[5] != 1 or data[4] not in (1, 2):
        return None
    is64 = data[4] == 2
    (machine,) = struct.unpack_from("<H", data, 18)
    if is64:
        phoff, shoff = struct.unpack_from("<QQ", data, 32)
        phentsize, phnum, shentsize, shnum, shstrndx = struct.unpack_from("<HHHHH", data, 54)
        sfmt, pfmt = "<IIQQQQIIQQ", "<IIQQQQQQ"
    else:
        phoff, shoff = struct.unpack_from("<II", data, 28)
        phentsize, phnum, shentsize, shnum, shstrndx = struct.unpack_from("<HHHHH", data, 42)
        sfmt, pfmt = "<IIIIIIIIII", "<IIIIIIII"
    sections = []
    for i in range(shnum):
        v = struct.unpack_from(sfmt, data, shoff + i * shentsize)
        sections.append(dict(name=v[0], type=v[1], addr=v[3], off=v[4], size=v[5], link=v[6]))
    strtab = sections[shstrndx]
    for s in sections:
        s["sname"] = _cstr(data, strtab["off"] + s["name"])
    segments = []
    for i in range(phnum):
        v = struct.unpack_from(pfmt, data, phoff + i * phentsize)
        if is64:
            segments.append(dict(type=v[0], flags=v[1], off=v[2], vaddr=v[3], filesz=v[5], memsz=v[6]))
        else:
            segments.append(dict(type=v[0], flags=v[6], off=v[1], vaddr=v[2], filesz=v[4], memsz=v[5]))
    return dict(is64=is64, machine=machine, sections=sections, segments=segments)


def _cstr(data, off):
    return data[off:data.index(b"\0", off)].decode()


def _jump_slots(data, elf, by_name):
    """GOT address -> imported symbol name, from .rela.plt (64-bit) or .rel.plt (32-bit)."""
    dynsym = by_name.get(".dynsym")
    rel = by_name.get(".rela.plt") if elf["is64"] else by_name.get(".rel.plt")
    if not (dynsym and rel):
        return {}
    dynstr = elf["sections"][dynsym["link"]]
    out = {}
    if elf["is64"]:
        for i in range(rel["size"] // 24):
            off, info, _ = struct.unpack_from("<QQq", data, rel["off"] + i * 24)
            if (info & 0xFFFFFFFF) == R_AARCH64_JUMP_SLOT:
                name = struct.unpack_from("<I", data, dynsym["off"] + (info >> 32) * 24)[0]
                out[off] = _cstr(data, dynstr["off"] + name)
    else:
        for i in range(rel["size"] // 8):
            off, info = struct.unpack_from("<II", data, rel["off"] + i * 8)
            if (info & 0xFF) == R_ARM_JUMP_SLOT:
                name = struct.unpack_from("<I", data, dynsym["off"] + (info >> 8) * 16)[0]
                out[off] = _cstr(data, dynstr["off"] + name)
    return out


def _arm_imm(v):
    rot = ((v >> 8) & 0xF) * 2
    imm = v & 0xFF
    return ((imm >> rot) | (imm << (32 - rot))) & 0xFFFFFFFF if rot else imm


def _plt_entries(data, elf, by_name):
    """imported function name -> address of its PLT entry."""
    plt = by_name.get(".plt")
    got_names = _jump_slots(data, elf, by_name)
    if not (plt and got_names):
        return {}
    entries = {}
    for off in range(plt["off"], plt["off"] + plt["size"] - 8, 4):
        pc = plt["addr"] + (off - plt["off"])
        if elf["is64"]:
            i1, i2 = struct.unpack_from("<II", data, off)
            if (i1 & 0x9F00001F) != 0x90000010 or (i2 & 0xFFC003FF) != 0xF9400211:  # adrp x16 / ldr x17,[x16,#n]
                continue
            imm = (((i1 >> 5) & 0x7FFFF) << 2) | ((i1 >> 29) & 3)
            if imm & (1 << 20):
                imm -= 1 << 21
            got = ((pc & ~0xFFF) + (imm << 12)) + (((i2 >> 10) & 0xFFF) << 3)
        else:
            i1, i2, i3 = struct.unpack_from("<III", data, off)
            if (i1 & 0xFFFFF000) != 0xE28FC000 or (i2 & 0xFFFFF000) != 0xE28CC000 or (i3 & 0xFFFFF000) != 0xE5BCF000:
                continue  # add ip,pc,#n / add ip,ip,#n / ldr pc,[ip,#n]!
            got = pc + 8 + _arm_imm(i1 & 0xFFF) + _arm_imm(i2 & 0xFFF) + (i3 & 0xFFF)
        if got in got_names:
            entries[got_names[got]] = pc
    return entries


def patch_library(ctx: PatchContext, path: str) -> bool:
    with open(path, "rb") as f:
        data = bytearray(f.read())
    elf = _parse_elf(bytes(data))
    if elf is None or elf["machine"] not in (EM_ARM, EM_AARCH64):
        ctx.log(f"epoll_pwait2: {path} is not an ARM/AArch64 ELF, skipping")
        return False
    by_name = {s["sname"]: s for s in elf["sections"]}
    plt = _plt_entries(bytes(data), elf, by_name)
    if "epoll_pwait2" not in plt:
        ctx.log(f"epoll_pwait2: {path} has no PLT entry for it (not imported, or already patched)")
        return False
    if "epoll_wait" not in plt:
        ctx.log(f"epoll_pwait2: {path} has no epoll_wait import, cannot patch")
        return False

    stub_tpl, slots, mk_b = (_STUB64, _SLOTS64, _b64) if elf["is64"] else (_STUB32, _SLOTS32, _b32)
    seg = next((s for s in elf["segments"] if s["type"] == 1 and s["flags"] & 1), None)
    if seg is None:
        ctx.log("epoll_pwait2: no executable PT_LOAD")
        return False
    cave_off = (seg["off"] + seg["filesz"] + 3) & ~3
    cave_va = seg["vaddr"] + (cave_off - seg["off"])
    size = len(stub_tpl) * 4
    page_end = (seg["vaddr"] + seg["filesz"] + 0xFFF) & ~0xFFF
    if cave_va + size > page_end or cave_off + size > len(data):
        ctx.log("epoll_pwait2: no room after the executable segment")
        return False
    if any(s["type"] == 1 and s is not seg and s["vaddr"] < cave_va + size and s["vaddr"] + s["memsz"] > cave_va
           for s in elf["segments"]):
        ctx.log("epoll_pwait2: cave overlaps another segment")
        return False
    if any(data[cave_off:cave_off + size]):
        ctx.log("epoll_pwait2: padding after the executable segment is not empty, refusing")
        return False

    words = list(stub_tpl)
    for slot in slots:
        words[slot] = mk_b(cave_va + slot * 4, plt["epoll_wait"])
    plt_sec = by_name[".plt"]
    entry_off = plt_sec["off"] + (plt["epoll_pwait2"] - plt_sec["addr"])
    data[cave_off:cave_off + size] = struct.pack("<%dI" % len(words), *words)
    struct.pack_into("<I", data, entry_off, mk_b(plt["epoll_pwait2"], cave_va))
    with open(path, "wb") as f:
        f.write(data)
    ctx.log(f"epoll_pwait2: {path} patched (plt {plt['epoll_pwait2']:#x} -> stub {cave_va:#x} -> epoll_wait {plt['epoll_wait']:#x})")
    return True


def patch_epoll_pwait2(ctx: PatchContext) -> None:
    system = ctx.system_root()
    for rel in ("lib64/libutils.so", "lib/libutils.so"):
        path = os.path.join(system, rel)
        if os.path.isfile(path):
            try:
                patch_library(ctx, path)
            except Exception as exc:  # never break the build for this
                ctx.log(f"epoll_pwait2: failed on {path}: {exc}")

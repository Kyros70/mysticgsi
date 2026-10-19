"""Make libutils work on kernels without epoll_pwait2 (added in Linux 5.11).

Android 17's libutils (Looper) calls epoll_pwait2(). On older kernels the syscall returns
ENOSYS, every Looper poll fails and the device never finishes booting. Instead of touching
libc (inside the runtime APEX) or the kernel, the PLT entry that libutils uses for
epoll_pwait2 is redirected to a small stub that converts the timespec to milliseconds
(rounding up) and tail-calls epoll_wait, which libutils already imports. The Looper call
passes no signal mask, which epoll_wait does not need.

The stub lives in the zero padding that follows the last byte of the executable PT_LOAD
segment, inside the page that is mapped anyway. Nothing else in the file is touched.
"""

import os
import struct

from .context import PatchContext

EM_AARCH64 = 183
R_AARCH64_JUMP_SLOT = 1026

# epoll_pwait2(epfd, events, maxevents, const timespec *ts, sigmask) -> epoll_wait(.., timeout_ms)
# x3 = timespec*, NULL means wait forever. Two words (index 15 and 17) are the final branches to
# the epoll_wait PLT entry and are filled in at patch time.
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
_BRANCH_SLOTS = (15, 17)


def _b(src: int, dst: int) -> int:
    delta = (dst - src) >> 2
    if not -(1 << 25) <= delta < (1 << 25):
        raise ValueError("branch out of range")
    return 0x14000000 | (delta & 0x03FFFFFF)


def _parse_elf64(data: bytes):
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        return None
    (e_machine,) = struct.unpack_from("<H", data, 18)
    e_phoff, e_shoff = struct.unpack_from("<QQ", data, 32)
    e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHHHH", data, 54)
    sections = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        name, typ, flags, addr, offset, size, link, info, align, entsize = struct.unpack_from(
            "<IIQQQQIIQQ", data, off
        )
        sections.append(dict(name=name, type=typ, addr=addr, off=offset, size=size, link=link, entsize=entsize))
    strtab = sections[e_shstrndx]
    for s in sections:
        end = data.index(b"\0", strtab["off"] + s["name"])
        s["sname"] = data[strtab["off"] + s["name"]:end].decode()
    segments = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, p_flags, p_offset, p_vaddr, _paddr, p_filesz, p_memsz, _align = struct.unpack_from(
            "<IIQQQQQQ", data, off
        )
        segments.append(dict(type=p_type, flags=p_flags, off=p_offset, vaddr=p_vaddr, filesz=p_filesz, memsz=p_memsz))
    return dict(machine=e_machine, sections=sections, segments=segments)


def _cstr(data: bytes, off: int) -> str:
    return data[off:data.index(b"\0", off)].decode()


def _plt_entries(data: bytes, elf: dict) -> dict:
    """Map imported function name -> address of the PLT entry that jumps through its GOT slot."""
    by_name = {s["sname"]: s for s in elf["sections"]}
    dynsym, rela, plt = by_name.get(".dynsym"), by_name.get(".rela.plt"), by_name.get(".plt")
    if not (dynsym and rela and plt):
        return {}
    dynstr = elf["sections"][dynsym["link"]]
    got_to_name = {}
    for i in range(rela["size"] // 24):
        r_offset, r_info, _addend = struct.unpack_from("<QQq", data, rela["off"] + i * 24)
        if (r_info & 0xFFFFFFFF) != R_AARCH64_JUMP_SLOT:
            continue
        st_name = struct.unpack_from("<I", data, dynsym["off"] + (r_info >> 32) * 24)[0]
        got_to_name[r_offset] = _cstr(data, dynstr["off"] + st_name)
    entries = {}
    for off in range(plt["off"], plt["off"] + plt["size"] - 4, 4):
        i1, i2 = struct.unpack_from("<II", data, off)
        if (i1 & 0x9F00001F) != 0x90000010 or (i2 & 0xFFC003FF) != 0xF9400211:  # adrp x16 / ldr x17,[x16,#n]
            continue
        pc = plt["addr"] + (off - plt["off"])
        imm = (((i1 >> 5) & 0x7FFFF) << 2) | ((i1 >> 29) & 3)
        if imm & (1 << 20):
            imm -= 1 << 21
        got = ((pc & ~0xFFF) + (imm << 12)) + (((i2 >> 10) & 0xFFF) << 3)
        if got in got_to_name:
            entries[got_to_name[got]] = pc
    return entries


def patch_library(ctx: PatchContext, path: str) -> bool:
    with open(path, "rb") as f:
        data = bytearray(f.read())
    elf = _parse_elf64(bytes(data))
    if elf is None:
        ctx.log(f"epoll_pwait2: {path} is not a 64-bit ELF, skipping")
        return False
    if elf["machine"] != EM_AARCH64:
        ctx.log(f"epoll_pwait2: {path} is not AArch64, skipping")
        return False
    plt = _plt_entries(bytes(data), elf)
    if "epoll_pwait2" not in plt:
        ctx.log(f"epoll_pwait2: {path} has no PLT entry for it (not imported, or already patched)")
        return False
    if "epoll_wait" not in plt:
        ctx.log(f"epoll_pwait2: {path} has no epoll_wait import, cannot patch")
        return False

    # the PLT entry sits in the executable segment, find where that segment ends in the file
    seg = next((s for s in elf["segments"] if s["type"] == 1 and s["flags"] & 1), None)
    if seg is None:
        ctx.log("epoll_pwait2: no executable PT_LOAD")
        return False
    cave_off = (seg["off"] + seg["filesz"] + 3) & ~3
    cave_va = seg["vaddr"] + (cave_off - seg["off"])
    size = len(_STUB64) * 4
    page_end = (seg["vaddr"] + seg["filesz"] + 0xFFF) & ~0xFFF
    if cave_va + size > page_end or cave_off + size > len(data):
        ctx.log("epoll_pwait2: no room after the executable segment")
        return False
    nxt = [s for s in elf["segments"] if s["type"] == 1 and s["vaddr"] < page_end and s is not seg]
    if any(s["vaddr"] + s["memsz"] > cave_va and s["vaddr"] < cave_va + size for s in nxt):
        ctx.log("epoll_pwait2: cave overlaps another segment")
        return False
    cave = bytes(data[cave_off:cave_off + size])

    # idempotent: if our stub is already there, stop
    words = list(_STUB64)
    for slot in _BRANCH_SLOTS:
        words[slot] = _b(cave_va + slot * 4, plt["epoll_wait"])
    stub = struct.pack("<%dI" % len(words), *words)
    if cave == stub:
        ctx.log(f"epoll_pwait2: {path} already patched")
        return True
    if any(cave):
        ctx.log("epoll_pwait2: padding after the executable segment is not empty, refusing")
        return False

    # file offset of the epoll_pwait2 PLT entry
    plt_sec = next(s for s in elf["sections"] if s["sname"] == ".plt")
    entry_off = plt_sec["off"] + (plt["epoll_pwait2"] - plt_sec["addr"])
    data[cave_off:cave_off + size] = stub
    struct.pack_into("<I", data, entry_off, _b(plt["epoll_pwait2"], cave_va))
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

"""Minimal, dependency-free Mach-O reader for WeChat hook porting.

Only the pieces needed by the porting toolkit are implemented:

* fat/arm64 slice selection and extraction
* segments / sections / UUID / LC_ID_DYLIB version
* LC_FUNCTION_STARTS (ULEB128 delta stream)
* classic LC_DYLD_INFO_ONLY binds and chained-fixup binds
* __stubs -> imported symbol names (e.g. __Znwm)

Addresses in hook/versions/*.json are arm64 RVA / vmaddr (image base 0).
"""

from __future__ import annotations

import mmap
import os
import struct
from dataclasses import dataclass, field
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_DYSYMTAB = 0xB
LC_LOAD_DYLIB = 0xC
LC_ID_DYLIB = 0xD
LC_UUID = 0x1B
LC_FUNCTION_STARTS = 0x26
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022
LC_DYLD_CHAINED_FIXUPS = 0x80000034

CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_MASK = 0x00FFFFFF

MAGIC_FAT32 = 0xCAFEBABE
MAGIC_FAT64 = 0xCAFEBABF
MAGIC_THIN_64 = 0xFEEDFACF

TEXT_SECTION = "__text"
STUBS_SECTION = "__stubs"


def _u32(data: bytes, off: int) -> int:
    return struct.unpack_from("<I", data, off)[0]


def _u64(data: bytes, off: int) -> int:
    return struct.unpack_from("<Q", data, off)[0]


def _uleb(data: bytes, off: int) -> Tuple[int, int]:
    value = 0
    shift = 0
    while True:
        if off >= len(data):
            raise ValueError("truncated ULEB128 stream")
        byte = data[off]
        off += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, off
        shift += 7
        if shift > 63:
            raise ValueError("ULEB128 value too large")


def _sleb(data: bytes, off: int) -> Tuple[int, int]:
    value = 0
    shift = 0
    while True:
        if off >= len(data):
            raise ValueError("truncated SLEB128 stream")
        byte = data[off]
        off += 1
        value |= (byte & 0x7F) << shift
        shift += 7
        if not byte & 0x80:
            if byte & 0x40:
                value -= 1 << shift
            return value, off


@dataclass(frozen=True)
class Segment:
    name: str
    vmaddr: int
    vmsize: int
    fileoff: int
    filesize: int
    initprot: int
    flags: int


@dataclass(frozen=True)
class Section:
    segment: str
    name: str
    addr: int
    size: int
    offset: int
    align: int
    flags: int

    @property
    def end(self) -> int:
        return self.addr + self.size


@dataclass
class FatArch:
    cputype: int
    cpusubtype: int
    offset: int
    size: int
    align: int


class MachOError(RuntimeError):
    pass


class MachOImage:
    """Read-only view over one Mach-O slice."""

    def __init__(self, path: str, arch: str = "arm64"):
        self.path = os.path.abspath(path)
        self._fh = open(self.path, "rb")
        self._raw = mmap.mmap(self._fh.fileno(), 0, access=mmap.ACCESS_READ)
        self.arch = arch
        self._fat_arches: List[FatArch] = []
        self._slice_offset = 0
        self._slice_size = len(self._raw)
        self._parse()

    # -- lifecycle -----------------------------------------------------

    def close(self) -> None:
        try:
            self._raw.close()
        except BufferError:
            # A memoryview/numpy view still references the mapping; the OS
            # reclaims it when the last reference goes away.
            pass
        finally:
            self._fh.close()

    def __enter__(self) -> "MachOImage":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    @property
    def raw(self) -> mmap.mmap:
        return self._raw

    @property
    def data(self) -> memoryview:
        """Bytes of the selected thin slice (zero-copy memoryview)."""
        return memoryview(self._raw)[self._slice_offset : self._slice_offset + self._slice_size]

    # -- public metadata ----------------------------------------------

    @property
    def fat_arches(self) -> Sequence[FatArch]:
        return tuple(self._fat_arches)

    @property
    def segments(self) -> Sequence[Segment]:
        return tuple(self._segments)

    @property
    def sections(self) -> Sequence[Section]:
        return tuple(self._sections)

    @property
    def starts(self) -> Sequence[int]:
        return tuple(self._starts)

    @property
    def text_start(self) -> int:
        return self._text_start

    @property
    def text_end(self) -> int:
        return self._text_end

    def section(self, name: str, segment: Optional[str] = None) -> Optional[Section]:
        for section in self._sections:
            if section.name == name and (segment is None or section.segment == segment):
                return section
        return None

    def section_at(self, addr: int) -> Optional[Section]:
        for section in self._sections:
            if section.addr <= addr < section.end:
                return section
        return None

    def segment_at(self, addr: int) -> Optional[Segment]:
        for segment in self._segments:
            if segment.vmaddr <= addr < segment.vmaddr + segment.vmsize:
                return segment
        return None

    def is_code(self, addr: int) -> bool:
        return self._text_start <= addr < self._text_end and addr % 4 == 0

    def is_pointer_target(self, addr: int) -> bool:
        """True when addr falls in a mapped section (code or data)."""
        return self.section_at(addr) is not None

    # -- raw reads -----------------------------------------------------

    def _file_offset(self, addr: int, size: int = 1) -> Optional[int]:
        segment = self.segment_at(addr)
        if segment is None:
            return None
        delta = addr - segment.vmaddr
        if delta < 0 or delta + size > segment.filesize:
            return None  # zero-fill (__bss) or beyond file
        return segment.fileoff + delta

    def read(self, addr: int, size: int) -> Optional[bytes]:
        off = self._file_offset(addr, size)
        if off is None:
            return None
        start = self._slice_offset + off
        return bytes(self._raw[start : start + size])

    def read_u64(self, addr: int) -> Optional[int]:
        data = self.read(addr, 8)
        return None if data is None else struct.unpack("<Q", data)[0]

    def read_u32(self, addr: int) -> Optional[int]:
        data = self.read(addr, 4)
        return None if data is None else struct.unpack("<I", data)[0]

    def cstring(self, addr: int, limit: int = 512) -> Optional[str]:
        data = self.read(addr, limit)
        if data is None:
            return None
        return data.split(b"\0", 1)[0].decode("utf-8", "replace")

    def pointer_at(self, addr: int) -> Optional[int]:
        """Decode a local pointer stored at addr (classic rebase or chained).

        Returns None for null/unmapped/bind pointers. Image base is 0 for the
        arm64 WeChat slice, so both classic rebases and chained rebase targets
        are directly usable as hook RVAs.
        """
        raw = self.read_u64(addr)
        if raw is None or raw == 0:
            return None
        if self.is_pointer_target(raw) and raw % 8 == 0:
            return raw
        # Chained fixups store the target in the low 36 bits.
        low = raw & 0xFFFFFFFFF
        if self.is_pointer_target(low) and low % 8 == 0:
            return low
        # Some formats leave an unaligned target; accept if in a section.
        if self.is_pointer_target(low):
            return low
        return None

    def import_at_got(self, addr: int) -> Optional[str]:
        return self._bind_slots.get(addr)

    def stub_import(self, addr: int) -> Optional[str]:
        return self._stub_imports.get(addr)

    def find_stub(self, symbol: str) -> Optional[int]:
        for addr, name in self._stub_imports.items():
            if name == symbol:
                return addr
        return None

    def find_stub_all(self, symbol: str) -> List[int]:
        return sorted(addr for addr, name in self._stub_imports.items() if name == symbol)

    # -- parsing -------------------------------------------------------

    def _parse(self) -> None:
        magic_be = struct.unpack_from(">I", self._raw, 0)[0]
        if magic_be in (MAGIC_FAT32, MAGIC_FAT64):
            self._parse_fat(magic_be)
            thin = memoryview(self._raw)[self._slice_offset : self._slice_offset + self._slice_size]
        elif struct.unpack_from("<I", self._raw, 0)[0] == MAGIC_THIN_64:
            thin = memoryview(self._raw)
        else:
            raise MachOError(f"not a 64-bit Mach-O / fat file: {self.path}")

        self._parse_thin(thin)

    def _parse_fat(self, magic: int) -> None:
        nfat = struct.unpack_from(">I", self._raw, 4)[0]
        offset = 8
        for _ in range(nfat):
            if magic == MAGIC_FAT32:
                cputype, cpusubtype, off, size, align = struct.unpack_from(">iiIII", self._raw, offset)
                offset += 20
            else:
                cputype, cpusubtype, off, size, align, _reserved = struct.unpack_from(">iiQQII", self._raw, offset)
                offset += 32
            self._fat_arches.append(FatArch(cputype & 0xFFFFFFFF, cpusubtype & CPU_SUBTYPE_MASK, off, size, align))

        wanted = CPU_TYPE_ARM64 if self.arch == "arm64" else None
        chosen = None
        for arch in self._fat_arches:
            if wanted is None or (arch.cputype & 0xFFFFFFFF) == wanted:
                chosen = arch
                break
        if chosen is None:
            raise MachOError(f"no {self.arch} slice in {self.path}")
        self._slice_offset = chosen.offset
        self._slice_size = chosen.size

    def _parse_thin(self, data: memoryview) -> None:
        # memoryview of raw; all offsets are relative to the selected slice.
        if struct.unpack_from("<I", data, 0)[0] != MAGIC_THIN_64:
            raise MachOError("expected a little-endian 64-bit Mach-O slice")

        cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from(
            "<IiiIIII", data, 4
        )
        self.cputype = cputype
        self.cpusubtype = cpusubtype
        self.filetype = filetype
        self.flags = flags
        self.ncmds = ncmds

        self._segments: List[Segment] = []
        self._sections: List[Section] = []
        self._imports: List[str] = []
        self._bind_slots: Dict[int, str] = {}
        self._stub_imports: Dict[int, str] = {}
        self._function_starts_range: Optional[Tuple[int, int]] = None
        self._classic_bind_range: Optional[Tuple[int, int]] = None
        self._chained_fixups_range: Optional[Tuple[int, int]] = None
        self.uuid: Optional[str] = None
        self.dylib_version: Optional[int] = None

        offset = 32
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<II", data, offset)
            if cmdsize < 8:
                raise MachOError(f"bad load command size {cmdsize}")
            if cmd == LC_SEGMENT_64:
                self._parse_segment(data, offset)
            elif cmd == LC_FUNCTION_STARTS:
                dataoff, datasize = struct.unpack_from("<II", data, offset + 8)
                self._function_starts_range = (dataoff, datasize)
            elif cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
                values = struct.unpack_from("<10I", data, offset + 8)
                self._classic_bind_range = (values[2], values[3])
                # weak/lazy binds are not needed for current hook anchors
            elif cmd == LC_DYLD_CHAINED_FIXUPS:
                dataoff, datasize = struct.unpack_from("<II", data, offset + 8)
                self._chained_fixups_range = (dataoff, datasize)
            elif cmd == LC_UUID:
                self.uuid = bytes(data[offset + 8 : offset + 24]).hex()
            elif cmd == LC_ID_DYLIB:
                # dylib_command: name.offset, timestamp, current_version, compatibility_version
                self.dylib_version = struct.unpack_from("<I", data, offset + 16)[0]
            offset += cmdsize

        text = self.section(TEXT_SECTION)
        if text is None:
            raise MachOError("missing __TEXT,__text")
        self._text_start = text.addr
        self._text_end = text.end

        self._starts = self._parse_function_starts(data)
        self._parse_binds(data)
        self._parse_stubs()

    def _parse_segment(self, data: memoryview, offset: int) -> None:
        segname = bytes(data[offset + 8 : offset + 24]).split(b"\0", 1)[0].decode("ascii", "replace")
        vmaddr, vmsize, fileoff, filesize, maxprot, initprot, nsects, flags = struct.unpack_from(
            "<QQQQIIII", data, offset + 24
        )
        self._segments.append(
            Segment(
                name=segname,
                vmaddr=vmaddr,
                vmsize=vmsize,
                fileoff=fileoff,
                filesize=filesize,
                initprot=initprot,
                flags=flags,
            )
        )
        section_offset = offset + 72
        for _ in range(nsects):
            sectname, segn, addr, size, file_offset, align, reloff, nreloc, sflags, _r1, _r2, _r3 = (
                struct.unpack_from("<16s16sQQIIIIIIII", data, section_offset)
            )
            self._sections.append(
                Section(
                    segment=segn.split(b"\0", 1)[0].decode("ascii", "replace"),
                    name=sectname.split(b"\0", 1)[0].decode("ascii", "replace"),
                    addr=addr,
                    size=size,
                    offset=file_offset,
                    align=align,
                    flags=sflags,
                )
            )
            section_offset += 80

    def _parse_function_starts(self, data: memoryview) -> List[int]:
        if self._function_starts_range is None:
            return []
        dataoff, datasize = self._function_starts_range
        blob = bytes(data[dataoff : dataoff + datasize])
        text_segment = next((s for s in self._segments if s.name == "__TEXT"), None)
        if text_segment is None:
            return []
        addr = text_segment.vmaddr
        starts: List[int] = []
        pos = 0
        while pos < len(blob):
            delta, pos = _uleb(blob, pos)
            if delta == 0:
                break
            addr += delta
            starts.append(addr)
        return starts

    # -- bind / import parsing ----------------------------------------

    def _parse_binds(self, data: memoryview) -> None:
        if self._classic_bind_range is not None:
            self._parse_classic_binds(data)
        if self._chained_fixups_range is not None:
            self._parse_chained_binds(data)

    def _parse_classic_binds(self, data: memoryview) -> None:
        bind_off, bind_size = self._classic_bind_range  # type: ignore[misc]
        if not bind_size:
            return
        blob = bytes(data[bind_off : bind_off + bind_size])
        pos = 0
        segment_index = 0
        segment_offset = 0
        name: Optional[str] = None
        pointer_size = 8
        while pos < len(blob):
            byte = blob[pos]
            pos += 1
            opcode = byte & 0xF0
            imm = byte & 0x0F
            if opcode == 0x00:  # DONE
                break
            elif opcode == 0x10:  # SET_DYLIB_ORDINAL_IMM
                pass
            elif opcode == 0x20:  # SET_DYLIB_ORDINAL_ULEB
                _, pos = _uleb(blob, pos)
            elif opcode == 0x30:  # SET_DYLIB_SPECIAL_IMM
                pass
            elif opcode == 0x40:  # SET_SYMBOL_TRAILING_FLAGS_IMM
                end = blob.index(b"\0", pos)
                name = blob[pos:end].decode("utf-8", "replace")
                pos = end + 1
            elif opcode == 0x50:  # SET_TYPE_IMM
                pass
            elif opcode == 0x60:  # SET_ADDEND_SLEB
                _, pos = _sleb(blob, pos)
            elif opcode == 0x70:  # SET_SEGMENT_AND_OFFSET_ULEB
                segment_index = imm
                segment_offset, pos = _uleb(blob, pos)
            elif opcode == 0x80:  # ADD_ADDR_ULEB
                delta, pos = _uleb(blob, pos)
                segment_offset += delta
            elif opcode == 0x90:  # DO_BIND
                self._record_bind(segment_index, segment_offset, name)
                segment_offset += pointer_size
            elif opcode == 0xA0:  # DO_BIND_ADD_ADDR_ULEB
                self._record_bind(segment_index, segment_offset, name)
                delta, pos = _uleb(blob, pos)
                segment_offset += delta + pointer_size
            elif opcode == 0xB0:  # DO_BIND_ADD_ADDR_IMM_SCALED
                self._record_bind(segment_index, segment_offset, name)
                segment_offset += imm * pointer_size + pointer_size
            elif opcode == 0xC0:  # DO_BIND_ULEB_TIMES_SKIPPING_ULEB
                count, pos = _uleb(blob, pos)
                skip, pos = _uleb(blob, pos)
                for _ in range(count):
                    self._record_bind(segment_index, segment_offset, name)
                    segment_offset += skip + pointer_size
            else:
                # Unknown opcode: stop rather than silently mis-map.
                break

    def _record_bind(self, segment_index: int, offset: int, name: Optional[str]) -> None:
        if name is None or segment_index >= len(self._segments):
            return
        addr = self._segments[segment_index].vmaddr + offset
        self._bind_slots.setdefault(addr, name)

    def _parse_chained_binds(self, data: memoryview) -> None:
        dataoff, datasize = self._chained_fixups_range  # type: ignore[misc]
        if not datasize:
            return
        blob = bytes(data[dataoff : dataoff + datasize])
        (
            fixups_version,
            starts_offset,
            imports_offset,
            symbols_offset,
            imports_count,
            imports_format,
            symbols_format,
        ) = struct.unpack_from("<IIIIIII", blob, 0)
        if symbols_format != 0:
            return  # compressed symbol pool: binding names unavailable
        imports: List[str] = []
        for i in range(imports_count):
            base = imports_offset + i * (4 if imports_format == 1 else 12 if imports_format == 2 else 16)
            if imports_format == 1:
                value = struct.unpack_from("<I", blob, base)[0]
                name_offset = value >> 9
            elif imports_format == 2:
                value = struct.unpack_from("<I", blob, base)[0]
                name_offset = value >> 9
            elif imports_format == 3:
                value = struct.unpack_from("<Q", blob, base)[0]
                name_offset = value >> 32
            else:
                return
            end = blob.find(b"\0", symbols_offset + name_offset)
            if end < 0:
                imports.append("")
            else:
                imports.append(blob[symbols_offset + name_offset : end].decode("utf-8", "replace"))
        self._imports = imports

        seg_count = struct.unpack_from("<I", blob, starts_offset)[0]
        seg_info_offsets = struct.unpack_from(f"<{seg_count}I", blob, starts_offset + 4)
        for seg_index, info_offset in enumerate(seg_info_offsets):
            if info_offset == 0 or seg_index >= len(self._segments):
                continue
            base = starts_offset + info_offset
            _size, page_size, pointer_format, segment_offset, _max_valid, page_count = struct.unpack_from(
                "<IHHQIH", blob, base
            )
            page_starts = struct.unpack_from(f"<{page_count}H", blob, base + 22)
            for page_index, page_start in enumerate(page_starts):
                if page_start == 0xFFFF:
                    continue
                # Chained entries live in the mapped __DATA* segment, not in the
                # LC_DYLD_CHAINED_FIXUPS payload. segment_offset is a vmaddr.
                addr = segment_offset + page_index * page_size + page_start * 4
                for _ in range(1 << 16):
                    raw = self.read_u64(addr)
                    if raw is None or raw == 0:
                        break
                    if raw >> 63:  # bind
                        if pointer_format in (2, 6):
                            ordinal = raw & 0xFFFFFF
                        elif pointer_format in (1, 7, 9, 10, 12):
                            ordinal = raw & 0xFFFFFF
                        else:
                            ordinal = raw & 0xFFFF
                        if ordinal < len(imports):
                            self._bind_slots.setdefault(addr, imports[ordinal])
                    next_stride = (raw >> 51) & 0xFFF
                    if next_stride == 0:
                        break
                    addr += next_stride * 4

    # -- stubs ---------------------------------------------------------

    def _parse_stubs(self) -> None:
        stubs = self.section(STUBS_SECTION)
        if stubs is None:
            return
        for addr in range(stubs.addr, stubs.end - 11, 12):
            got = self._decode_stub_got(addr)
            if got is None:
                continue
            name = self._bind_slots.get(got)
            if name:
                self._stub_imports[addr] = name

    def _decode_stub_got(self, addr: int) -> Optional[int]:
        adrp = self.read_u32(addr)
        ldr = self.read_u32(addr + 4)
        br = self.read_u32(addr + 8)
        if adrp is None or ldr is None or br is None:
            return None
        if (adrp & 0x9F000000) != 0x90000000:
            return None
        if (ldr & 0xFFC00000) != 0xF9400000:
            return None
        if br != 0xD61F0200:  # br x16
            return None
        immlo = (adrp >> 29) & 0x3
        immhi = (adrp >> 5) & 0x7FFFF
        imm = (immhi << 2) | immlo
        if imm & (1 << 20):
            imm -= 1 << 21
        page = (addr & ~0xFFF) + imm * 4096
        imm12 = (ldr >> 10) & 0xFFF
        return page + imm12 * 8

    # -- extraction ----------------------------------------------------

    @staticmethod
    def extract_arch(src: str, dst: str, arch: str = "arm64") -> dict:
        """Write the requested slice to dst and return provenance metadata."""
        import hashlib
        import json

        image = MachOImage(src, arch=arch)
        try:
            length = image._slice_size
            with open(dst, "wb") as out:
                view = memoryview(image._raw)[image._slice_offset : image._slice_offset + length]
                out.write(view)
            digest = hashlib.sha256(view).hexdigest()
            del view
            meta = {
                "source": os.path.abspath(src),
                "slice": arch,
                "offset": image._slice_offset,
                "size": length,
                "sha256": digest,
                "uuid": image.uuid,
                "dylib_version": image.dylib_version,
                "fat_arches": [
                    {
                        "cputype": hex(a.cputype),
                        "cpusubtype": hex(a.cpusubtype),
                        "offset": a.offset,
                        "size": a.size,
                    }
                    for a in image.fat_arches
                ],
            }
        finally:
            image.close()
        with open(dst + ".json", "w", encoding="utf-8") as fh:
            json.dump(meta, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        return meta

"""Loaded arm64 image with function boundaries and fast window search."""

from __future__ import annotations

import bisect
import hashlib
from dataclasses import dataclass
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

from .arm64 import (
    data_refs,
    decode_insn,
    normalize_words,
    shape_word,
    shape_words,
    words_to_bytes,
)
from .macho import MachOImage, Section

try:
    import numpy as np
except Exception:  # pragma: no cover
    np = None


class Image:
    """A WeChat arm64 slice plus cached instruction/function indexes."""

    def __init__(self, path: str, arch: str = "arm64", load_starts: bool = True):
        self.macho = MachOImage(path, arch=arch)
        self.path = self.macho.path
        self.text_start = self.macho.text_start
        self.text_end = self.macho.text_end
        self.starts = list(self.macho.starts) if load_starts else []
        self.starts_set = set(self.starts)
        self._normalized = None
        self._normalized_bytes = None
        self._prefix_index = {}
        self._signature_index = {}
        self._function_hash_cache = {}

    # -- lifecycle -----------------------------------------------------

    def close(self) -> None:
        # numpy arrays are views over the mmap; drop them before closing.
        for name in ("_words", "_normalized", "_normalized_bytes", "_data_pointer_index",
                     "_xref_cache", "_anchor_cache"):
            if hasattr(self, name):
                try:
                    delattr(self, name)
                except AttributeError:
                    pass
        import gc

        gc.collect()
        try:
            self.macho.close()
        except BufferError:
            # A caller still holds an exported buffer; the OS will reclaim it.
            pass

    def __enter__(self) -> "Image":
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    @property
    def arch(self) -> str:
        return self.macho.arch

    @property
    def uuid(self) -> Optional[str]:
        return self.macho.uuid

    @property
    def dylib_version(self) -> Optional[int]:
        return self.macho.dylib_version

    # -- instruction access -------------------------------------------

    @property
    def words(self):
        if not hasattr(self, "_words"):
            raw = self.macho.data
            usable = len(raw) // 4 * 4
            if np is not None:
                self._words = np.frombuffer(raw[:usable], dtype="<u4")
            else:
                import array

                self._words = array.array("I", bytes(raw[:usable]))
                if __import__("sys").byteorder != "little":  # pragma: no cover
                    self._words.byteswap()
        return self._words

    @property
    def normalized(self):
        if self._normalized is None:
            self._normalized = normalize_words(self.words)
        return self._normalized

    @property
    def normalized_bytes(self) -> bytes:
        if self._normalized_bytes is None:
            self._normalized_bytes = words_to_bytes(self.normalized)
        return self._normalized_bytes

    def word_at(self, addr: int) -> Optional[int]:
        if not (self.text_start <= addr < self.text_end and addr % 4 == 0):
            return None
        return int(self.words[addr // 4])

    def words_at(self, addr: int, count: int):
        if addr % 4 != 0:
            raise ValueError("unaligned word address")
        start = addr // 4
        return self.words[start : start + count]

    def normalized_at(self, addr: int, count: int):
        if addr % 4 != 0:
            raise ValueError("unaligned word address")
        start = addr // 4
        return self.normalized[start : start + count]

    def shape_at(self, addr: int, count: int) -> List[int]:
        return [shape_word(int(w)) for w in self.words_at(addr, count)]

    # -- function boundaries -----------------------------------------

    def enclosing(self, addr: int) -> Tuple[Optional[int], Optional[int]]:
        """Return (function_start, offset) or (None, None)."""
        index = bisect.bisect_right(self.starts, addr) - 1
        if index < 0:
            return None, None
        return self.starts[index], addr - self.starts[index]

    def function_index(self, addr: int) -> Optional[int]:
        index = bisect.bisect_right(self.starts, addr) - 1
        return index if index >= 0 else None

    def function_end(self, start: int) -> int:
        index = bisect.bisect_left(self.starts, start)
        if index < 0 or index >= len(self.starts) or self.starts[index] != start:
            return min(start + 0x4000, self.text_end)
        if index + 1 < len(self.starts):
            return self.starts[index + 1]
        return self.text_end

    def function_words(self, start: int, limit_words: int = 0x4000):
        end = min(self.function_end(start), start + limit_words * 4)
        return self.words_at(start, max(0, (end - start) // 4))

    def function_hash(self, start: int) -> bytes:
        cached = self._function_hash_cache.get(start)
        if cached is not None:
            return cached
        body = self.normalized_at(start, (self.function_end(start) - start) // 4)
        digest = hashlib.blake2b(words_to_bytes(body), digest_size=16).digest()
        self._function_hash_cache[start] = digest
        return digest

    # -- signatures / indexes ----------------------------------------

    def signature(self, start: int, width: int = 24, shape: bool = True) -> bytes:
        if shape:
            values = self.shape_at(start, width)
        else:
            values = [int(v) for v in self.normalized_at(start, width)]
        return words_to_bytes(values)

    def signature_index(self, width: int = 24, shape: bool = True) -> Dict[bytes, List[int]]:
        key = (width, shape)
        if key in self._signature_index:
            return self._signature_index[key]
        index: Dict[bytes, List[int]] = {}
        for start in self.starts:
            if start + width * 4 > self.text_end:
                continue
            index.setdefault(self.signature(start, width, shape), []).append(start)
        self._signature_index[key] = index
        return index

    def prefix_index(self, width: int = 16) -> Dict[bytes, List[int]]:
        if width in self._prefix_index:
            return self._prefix_index[width]
        index: Dict[bytes, List[int]] = {}
        for start in self.starts:
            if start + width * 4 > self.text_end:
                continue
            index.setdefault(self.signature(start, width, shape=False), []).append(start)
        self._prefix_index[width] = index
        return index

    # -- search -------------------------------------------------------

    def find_bytes(self, needle: bytes, start: int = 0, end: Optional[int] = None,
                   limit: int = 100) -> List[int]:
        """Find aligned occurrences of a byte pattern in the normalised stream."""
        if len(needle) < 4:
            raise ValueError("needle too short")
        buffer = self.normalized_bytes
        begin = max(0, start) * 4
        stop = len(buffer) if end is None else min(len(buffer), end * 4)
        results: List[int] = []
        position = begin
        while len(results) < limit:
            found = buffer.find(needle, position, stop)
            if found < 0:
                break
            if found % 4 == 0:
                results.append(found // 4)
            position = found + 1
        return results

    def find_window(self, addr: int, count: int, start: int = 0, end: Optional[int] = None,
                    limit: int = 100) -> List[int]:
        pattern = words_to_bytes(self.normalized_at(addr, count))
        return self.find_bytes(pattern, start=start, end=end, limit=limit)

    def find_shape_window(self, addr: int, count: int, start: int = 0, end: Optional[int] = None,
                          limit: int = 100) -> List[int]:
        if start % 4:
            start -= start % 4
        if end is None:
            end = self.text_end
        matches: List[int] = []
        pattern = words_to_bytes([shape_word(int(w)) for w in self.words_at(addr, count)])
        # Local scans are cheaper than building a full shape stream.
        position = start
        while position + count * 4 <= end and len(matches) < limit:
            if bytes(self.words_at(position, count)) == pattern:
                matches.append(position)
                position += 4
                continue
            # Compare shape words without materialising the whole stream.
            ok = True
            for i in range(count):
                if shape_word(int(self.words[position // 4 + i])) != shape_word(int(self.words[addr // 4 + i])):
                    ok = False
                    break
            if ok:
                matches.append(position)
            position += 4
        return matches

    # -- semantic helpers --------------------------------------------

    def data_refs(self, start: int, limit_words: int = 0x4000):
        words = self.function_words(start, limit_words)
        return data_refs(words, start)

    def branch_targets(self, start: int, limit_words: int = 0x4000):
        from .arm64 import branch_targets

        return branch_targets(self.function_words(start, limit_words), start)

    def section_at(self, addr: int) -> Optional[Section]:
        return self.macho.section_at(addr)

    def pointer_at(self, addr: int) -> Optional[int]:
        return self.macho.pointer_at(addr)

    def read_u32(self, addr: int) -> Optional[int]:
        return self.macho.read_u32(addr)

    def read_u64(self, addr: int) -> Optional[int]:
        return self.macho.read_u64(addr)

    def cstring(self, addr: int, limit: int = 512) -> Optional[str]:
        return self.macho.cstring(addr, limit)

    def find_stub(self, symbol: str) -> Optional[int]:
        return self.macho.find_stub(symbol)

    def stub_import(self, addr: int) -> Optional[str]:
        return self.macho.stub_import(addr)

    # -- data / xref helpers -----------------------------------------

    def addr_for_file_offset(self, offset: int) -> Optional[int]:
        for segment in self.macho.segments:
            if segment.fileoff <= offset < segment.fileoff + segment.filesize:
                return segment.vmaddr + (offset - segment.fileoff)
        return None

    def find_string_addresses(self, text: str) -> List[int]:
        """Return vmaddrs whose NUL-terminated C string equals text."""
        needle = text.encode("utf-8")
        raw = self.macho.raw
        results: List[int] = []
        position = 0
        while True:
            found = raw.find(needle, position)
            if found < 0:
                break
            address = self.addr_for_file_offset(found)
            if address is not None:
                section = self.section_at(address)
                if section is not None:
                    current = self.cstring(address, len(needle) + 1)
                    if current == text:
                        results.append(address)
            position = found + 1
        return sorted(set(results))

    def data_pointer_index(self) -> Dict[int, List[int]]:
        """Map decoded pointer value -> data slot addresses (built once)."""
        index = getattr(self, "_data_pointer_index", None)
        if index is not None:
            return index
        index = {}
        for section in self.macho.sections:
            if section.segment not in ("__DATA_CONST", "__DATA", "__AUTH_CONST"):
                continue
            if section.name not in ("__const", "__data", "__bss", "__common", "__auth_ptr"):
                continue
            address = section.addr
            while address + 8 <= section.end:
                pointer = self.pointer_at(address)
                if pointer is not None:
                    index.setdefault(pointer, []).append(address)
                address += 8
        self._data_pointer_index = index
        return index

    def data_slots_pointing_to(self, target: int) -> List[int]:
        """Return 8-byte-aligned data slots whose decoded pointer equals target."""
        return list(self.data_pointer_index().get(target, []))

    def xrefs_to(self, target: int, limit: int = 4096) -> List[dict]:
        """Find ADRP+ADD/LDR/STR references to a data address.

        Returns dicts with pc, function_start, offset, kind. This is a linear
        scan over ADRP instructions; results are cached per target.
        """
        cache = getattr(self, "_xref_cache", None)
        if cache is None:
            cache = {}
            self._xref_cache = cache
        if target in cache:
            return cache[target]
        words = self.words
        count = len(words)
        refs: List[dict] = []
        # Candidate ADRP positions. With numpy this is a cheap vector mask.
        if np is not None:
            arr = np.frombuffer(words, dtype="<u4") if isinstance(words, memoryview) else words
            indices = np.nonzero((arr & 0x9F000000) == 0x90000000)[0]
        else:
            indices = (i for i in range(count) if (int(words[i]) & 0x9F000000) == 0x90000000)
        for index in indices:
            index = int(index)
            pc = index * 4
            adrp = decode_insn(int(words[index]), pc)
            if adrp.kind != "adrp" or adrp.page is None:
                continue
            for step in (1, 2):
                j = index + step
                if j >= count:
                    break
                insn = decode_insn(int(words[j]), j * 4)
                if insn.kind == "addsub_imm" and insn.rn == adrp.rd:
                    ref_target = adrp.page + (insn.imm or 0)
                    kind = "add"
                elif insn.kind == "ldrstr_imm" and insn.rn == adrp.rd:
                    ref_target = adrp.page + (insn.imm or 0)
                    kind = "ldr" if (insn.word & 0x00400000) else "str"
                else:
                    continue
                if ref_target == target:
                    function_start, offset = self.enclosing(pc)
                    if function_start is not None:
                        refs.append({"pc": pc, "function_start": function_start,
                                     "offset": offset, "kind": kind})
                    if len(refs) >= limit:
                        break
            if len(refs) >= limit:
                break
        cache[target] = refs
        return refs


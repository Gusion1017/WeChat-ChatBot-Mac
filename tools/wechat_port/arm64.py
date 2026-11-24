"""ARM64 instruction helpers used by the WeChat hook porting toolkit.

We intentionally do not ship a full disassembler. The matcher needs three
things:

* a *normalised* instruction stream where PC-relative fields are masked, so
  recompiled functions can be compared byte-for-byte;
* a *shape* stream where common immediates are masked too, so small constant
  changes (line numbers, stack offsets, literals) do not hide a match;
* lightweight decoders for branches, ADRP+ADD/LDR references, vtable stores and
  operator-new factories.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterator, List, Optional, Sequence, Tuple

try:  # optional acceleration; the tool is fully functional without numpy
    import numpy as np
except Exception:  # pragma: no cover - exercised on systems without numpy
    np = None

B_MASK = 0x03FFFFFF
IMM19_MASK = 0x00FFFFE0
ADR_MASK = 0x60FFFFE0
IMM12_MASK = 0x003FFC00
IMM9_MASK = 0x001FF000
MOVE_WIDE_MASK = 0x007FFFE0


def sign_extend(value: int, bits: int) -> int:
    mask = 1 << (bits - 1)
    return (value ^ mask) - mask


def normalize_word(word: int) -> int:
    """Mask PC-relative fields (and ADRP-relative loads) for byte matching."""
    word &= 0xFFFFFFFF
    mask = 0
    if (word & 0x7C000000) == 0x14000000 or (word & 0xFC000000) == 0x94000000:
        mask |= B_MASK
    if (word & 0xFF000010) == 0x54000000:
        mask |= IMM19_MASK
    if (word & 0x7E000000) == 0x34000000:
        mask |= IMM19_MASK
    if (word & 0x7E000000) == 0x36000000:
        mask |= IMM19_MASK
    if (word & 0x1F000000) == 0x10000000:
        mask |= ADR_MASK
    if (word & 0x3B000000) == 0x18000000:
        mask |= IMM19_MASK
    return word & ~mask & 0xFFFFFFFF


def _normalize_array(words):
    """Vectorised normalisation (numpy) or a compact array fallback."""
    if np is None:
        import array

        result = array.array("I", bytes(4 * len(words)))
        for index, word in enumerate(words):
            result[index] = normalize_word(int(word))
        return result
    masks = np.zeros(len(words), dtype=np.uint32)
    masks[(words & 0x7C000000) == 0x14000000] |= B_MASK
    masks[(words & 0xFC000000) == 0x94000000] |= B_MASK
    masks[(words & 0xFF000010) == 0x54000000] |= IMM19_MASK
    masks[(words & 0x7E000000) == 0x34000000] |= IMM19_MASK
    masks[(words & 0x7E000000) == 0x36000000] |= IMM19_MASK
    masks[(words & 0x1F000000) == 0x10000000] |= ADR_MASK
    masks[(words & 0x3B000000) == 0x18000000] |= IMM19_MASK
    adrp = (words & 0x9F000000) == 0x90000000
    previous_adrp = np.zeros(len(words), dtype=bool)
    previous_adrp[1:] = adrp[:-1]
    addsub = ((words & 0x1F000000) == 0x11000000) | ((words & 0x1F000000) == 0x51000000)
    ldrstr = (words & 0x3B000000) == 0x39000000
    masks[previous_adrp & (addsub | ldrstr)] |= IMM12_MASK
    return words & ~masks


def normalize_words(words):
    """Return the exact-match normalised stream (numpy array or list)."""
    if np is None:
        return _normalize_array(words)
    out = np.empty_like(words)
    chunk = 4_000_000
    for start in range(0, len(words), chunk):
        end = min(start + chunk, len(words))
        out[start:end] = _normalize_array(words[start:end])
    return out


def shape_word(word: int) -> int:
    """Mask common immediates while preserving opcode/register shape."""
    word = normalize_word(word)
    word &= 0xFFFFFFFF
    mask = 0
    # Move wide immediate (MOVN/MOVZ/MOVK, 32/64-bit)
    if (word & 0x7F800000) in (0x12800000, 0x52800000, 0x72800000,
                               0x92800000, 0xD2800000, 0xF2800000):
        mask |= MOVE_WIDE_MASK
    # ADD/SUB (immediate), including CMP/CMN
    if (word & 0x1F000000) in (0x11000000, 0x51000000):
        mask |= IMM12_MASK
    # Logical immediate
    if (word & 0x1F800000) == 0x12000000:
        mask |= IMM12_MASK
    # Bitfield (SBFM/UBFM) and EXTR
    if (word & 0x1F800000) == 0x13000000:
        mask |= IMM12_MASK
    if (word & 0x1F800000) == 0x13800000:
        mask |= 0x001FFC00
    # LDR/STR unsigned immediate
    if (word & 0x3B000000) == 0x39000000:
        mask |= IMM12_MASK
    # LDR/STR pre/post-index immediate
    if (word & 0x3B200C00) == 0x38000C00:
        mask |= IMM9_MASK
    # Advanced SIMD MOVI/MVNI
    if (word & 0x1FBF8000) == 0x0F000000:
        mask |= MOVE_WIDE_MASK
    return word & ~mask & 0xFFFFFFFF


def _shape_array(words):
    if np is None:
        import array

        result = array.array("I", bytes(4 * len(words)))
        for index, word in enumerate(words):
            result[index] = shape_word(int(word))
        return result
    out = np.empty_like(words)
    chunk = 4_000_000
    for start in range(0, len(words), chunk):
        end = min(start + chunk, len(words))
        chunk_words = words[start:end]
        masks = np.zeros(len(chunk_words), dtype=np.uint32)
        move = (
            ((chunk_words & 0x7F800000) == 0x12800000)
            | ((chunk_words & 0x7F800000) == 0x52800000)
            | ((chunk_words & 0x7F800000) == 0x72800000)
            | ((chunk_words & 0x7F800000) == 0x92800000)
            | ((chunk_words & 0x7F800000) == 0xD2800000)
            | ((chunk_words & 0x7F800000) == 0xF2800000)
        )
        masks[move] |= MOVE_WIDE_MASK
        masks[((chunk_words & 0x1F000000) == 0x11000000)
              | ((chunk_words & 0x1F000000) == 0x51000000)] |= IMM12_MASK
        masks[(chunk_words & 0x1F800000) == 0x12000000] |= IMM12_MASK
        masks[(chunk_words & 0x1F800000) == 0x13000000] |= IMM12_MASK
        masks[(chunk_words & 0x1F800000) == 0x13800000] |= 0x001FFC00
        masks[(chunk_words & 0x3B000000) == 0x39000000] |= IMM12_MASK
        masks[(chunk_words & 0x3B200C00) == 0x38000C00] |= IMM9_MASK
        masks[(chunk_words & 0x1FBF8000) == 0x0F000000] |= MOVE_WIDE_MASK
        out[start:end] = (_normalize_array(chunk_words) & ~masks)
    return out


def shape_words(words):
    if np is None:
        return _shape_array(words)
    return _shape_array(words)


def words_to_bytes(words) -> bytes:
    """Little-endian byte view of an instruction stream (for bytes.find)."""
    if np is not None and isinstance(words, np.ndarray):
        return words.tobytes()
    import array

    if isinstance(words, (bytes, bytearray, memoryview)):
        return bytes(words)
    return array.array("I", [int(w) & 0xFFFFFFFF for w in words]).tobytes()


# ---------------------------------------------------------------------------
# Instruction decoding


@dataclass(frozen=True)
class Insn:
    pc: int
    word: int
    kind: str
    target: Optional[int] = None
    page: Optional[int] = None
    rd: int = 0
    rn: int = 0
    rt: int = 0
    rt2: int = 31
    imm: Optional[int] = None
    size: int = 0


def decode_insn(word: int, pc: int) -> Insn:
    word &= 0xFFFFFFFF
    rd = word & 0x1F
    rn = (word >> 5) & 0x1F
    rt = word & 0x1F
    if (word & 0x7C000000) == 0x14000000:
        target = pc + sign_extend(word & 0x3FFFFFF, 26) * 4
        kind = "bl" if (word & 0xFC000000) == 0x94000000 else "b"
        return Insn(pc, word, kind, target=target)
    if (word & 0xFF000010) == 0x54000000:
        target = pc + sign_extend((word >> 5) & 0x7FFFF, 19) * 4
        return Insn(pc, word, "bcond", target=target)
    if (word & 0x7E000000) == 0x34000000:
        target = pc + sign_extend((word >> 5) & 0x7FFFF, 19) * 4
        return Insn(pc, word, "cbz", target=target, rt=rt)
    if (word & 0x7E000000) == 0x36000000:
        target = pc + sign_extend((word >> 5) & 0x3FFF, 14) * 4
        return Insn(pc, word, "tbz", target=target, rt=rt)
    if (word & 0x1F000000) == 0x10000000:
        immlo = (word >> 29) & 0x3
        immhi = (word >> 5) & 0x7FFFF
        imm = (immhi << 2) | immlo
        if word & 0x80000000:
            page = (pc & ~0xFFF) + sign_extend(imm, 21) * 4096
            return Insn(pc, word, "adrp", page=page, rd=rd)
        target = pc + sign_extend(imm, 21)
        return Insn(pc, word, "adr", target=target, rd=rd)
    if (word & 0x3B000000) == 0x18000000:
        target = pc + sign_extend((word >> 5) & 0x7FFFF, 19) * 4
        return Insn(pc, word, "ldrlit", target=target, rt=rt)
    if (word & 0x1F000000) in (0x11000000, 0x51000000):
        imm12 = (word >> 10) & 0xFFF
        shift = (word >> 22) & 0x3
        return Insn(pc, word, "addsub_imm", rd=rd, rn=rn, imm=imm12 << (12 if shift == 3 else 0))
    if (word & 0x3B000000) == 0x39000000:
        imm12 = (word >> 10) & 0xFFF
        size = 1 << ((word >> 30) & 0x3)
        return Insn(pc, word, "ldrstr_imm", rt=rt, rn=rn, imm=imm12 * size, size=size)
    if (word & 0xFE000000) in (0xA8000000, 0x28000000):
        # Load/store pair (signed offset, pre-index or post-index).
        rt2 = (word >> 10) & 0x1F
        is_load = bool(word & 0x00400000)
        return Insn(pc, word, "ldp" if is_load else "stp", rt=rt, rt2=rt2, rn=rn)
    if (word & 0x7F800000) in (0x12800000, 0x52800000, 0x72800000,
                               0x92800000, 0xD2800000, 0xF2800000):
        imm16 = (word >> 5) & 0xFFFF
        hw = (word >> 21) & 0x3
        opc = (word >> 29) & 0x3
        value = imm16 << (hw * 16)
        return Insn(pc, word, "mov_wide", rd=rd, imm=value, size=opc)
    return Insn(pc, word, "other", rd=rd, rn=rn, rt=rt)


def iter_insns(words, start_addr: int):
    """Yield decoded instructions for a word stream."""
    for index in range(len(words)):
        yield decode_insn(int(words[index]), start_addr + index * 4)


# ---------------------------------------------------------------------------
# ADRP materialisation helpers


@dataclass(frozen=True)
class DataRef:
    pc: int
    target: int
    kind: str
    reg: int
    index: int


def data_refs(words: Sequence[int], start_addr: int) -> List[DataRef]:
    """Return ADRP+ADD/LDR/STR data references in a function body."""
    refs: List[DataRef] = []
    pages = {}
    insns = [decode_insn(int(word), start_addr + i * 4) for i, word in enumerate(words)]
    for i, insn in enumerate(insns):
        if insn.kind == "adrp" and insn.page is not None:
            pages[insn.rd] = insn.page
            continue
        if insn.kind == "addsub_imm" and insn.rn in pages:
            target = pages[insn.rn] + (insn.imm or 0)
            refs.append(DataRef(insn.pc, target, "add", insn.rd, i))
            continue
        if insn.kind == "ldrstr_imm" and insn.rn in pages:
            target = pages[insn.rn] + (insn.imm or 0)
            is_load = bool(insn.word & 0x00400000)
            refs.append(DataRef(insn.pc, target, "ldr" if is_load else "str", insn.rt, i))
    return refs


def stores_pointer_to(refs: Sequence[DataRef], insns: Sequence[Insn], target: int,
                     base_reg: int = 0, window: int = 4) -> Optional[DataRef]:
    """Check whether a function materialises target and stores it to [base]."""
    for ref in refs:
        if ref.target != target:
            continue
        for j in range(ref.index, min(ref.index + window, len(insns))):
            candidate = insns[j]
            if candidate.kind == "ldrstr_imm" and not (candidate.word & 0x00400000):
                if candidate.rt == ref.reg and candidate.rn == base_reg:
                    return ref
            if candidate.kind == "stp":
                if candidate.rn == base_reg and ref.reg in (candidate.rt, candidate.rt2):
                    return ref
    return None


def branch_targets(words: Sequence[int], start_addr: int) -> List[Tuple[int, int]]:
    """Return (pc, target) for B/BL instructions."""
    result: List[Tuple[int, int]] = []
    for i, word in enumerate(words):
        insn = decode_insn(int(word), start_addr + i * 4)
        if insn.kind in ("b", "bl") and insn.target is not None:
            result.append((insn.pc, insn.target))
    return result


def find_factory_size(words: Sequence[int], start_addr: int, ctor_addr: int,
                      operator_new_addr: int, radius: int = 0x400) -> Optional[int]:
    """Find mov w0,#size; bl operatorNew; bl ctor near a constructor."""
    insns = [decode_insn(int(word), start_addr + i * 4) for i, word in enumerate(words)]
    for i, insn in enumerate(insns):
        if insn.kind != "bl":
            continue
        if insn.target == operator_new_addr and i + 1 < len(insns):
            nxt = insns[i + 1]
            if nxt.kind != "bl" or nxt.target != ctor_addr:
                continue
            for j in range(max(0, i - 6), i):
                prev = insns[j]
                if prev.kind == "mov_wide" and prev.rd == 0 and prev.imm is not None:
                    return prev.imm
    return None

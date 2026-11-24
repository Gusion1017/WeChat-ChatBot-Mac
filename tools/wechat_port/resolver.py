"""Address remapping and structural verification for WeChat hook tables."""

from __future__ import annotations

import bisect
import difflib
import hashlib
from dataclasses import dataclass, field
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

try:
    import numpy as np
except Exception:  # pragma: no cover
    np = None

from .arm64 import (
    branch_targets,
    data_refs,
    decode_insn,
    find_factory_size,
    shape_word,
    stores_pointer_to,
    words_to_bytes,
)
from .image import Image
from .table import VersionTable, format_value, key_kind

VERIFIED = "verified"
HIGH = "high"
MEDIUM = "medium"
REVIEW = "review"
UNRESOLVED = "unresolved"
MANUAL = "manual"
CARRIED = "carried"

STATUS_ORDER = {VERIFIED: 0, HIGH: 1, MEDIUM: 2, REVIEW: 3, MANUAL: 4, UNRESOLVED: 5, CARRIED: 6}
ACCEPTABLE = {VERIFIED, HIGH}


@dataclass
class KeyResult:
    key: str
    kind: str
    old: Optional[int]
    new: Optional[int]
    status: str
    method: str
    checks: List[str] = field(default_factory=list)
    evidence: Dict[str, object] = field(default_factory=dict)
    alternatives: List[Dict[str, object]] = field(default_factory=list)
    note: str = ""

    def to_dict(self) -> dict:
        return {
            "key": self.key,
            "kind": self.kind,
            "old": format_value(self.old) if self.old is not None else None,
            "new": format_value(self.new) if self.new is not None else None,
            "status": self.status,
            "method": self.method,
            "checks": self.checks,
            "evidence": self.evidence,
            "alternatives": self.alternatives,
            "note": self.note,
        }


@dataclass
class VTable:
    address: int
    entries: List[int]
    typeinfo: Optional[int]
    name: Optional[str]


class Resolver:
    def __init__(self, old: Image, new: Image, old_table: VersionTable):
        self.old = old
        self.new = new
        self.old_table = old_table
        self.results: Dict[str, KeyResult] = {}
        self._anchor_map: Optional[Dict[int, Tuple[int, str]]] = None
        self._anchor_list: Optional[List[Tuple[int, int, int]]] = None
        self._function_cache: Dict[int, Tuple[int, str]] = {}
        self._alignment_cache: Dict[Tuple[int, int], object] = {}
        self._vtable_cache: Dict[int, VTable] = {}
        self._new_vtable_candidates: Optional[List[VTable]] = None
        self._xref_cache: Dict[int, List[dict]] = {}
        self._closure_relations: Dict[str, str] = {}
        for key in old_table.data:
            if not key.endswith("ClosureVtable"):
                continue
            task_key = key[: -len("ClosureVtable")] + "Vtable"
            closure_value = old_table.hex_value(key)
            task_value = old_table.hex_value(task_key) if task_key in old_table.data else None
            if closure_value is not None and task_value is not None and closure_value == task_value + 0x58:
                self._closure_relations[key] = task_key

    # -- anchors / delta prediction -----------------------------------

    def _build_anchors(self) -> None:
        if self._anchor_map is not None:
            return
        old_index = self.old.signature_index(24, shape=True)
        new_index = self.new.signature_index(24, shape=True)
        anchors: List[Tuple[int, int, int]] = []
        mapping: Dict[int, Tuple[int, str]] = {}
        for signature, old_starts in old_index.items():
            new_starts = new_index.get(signature)
            if not new_starts or len(old_starts) != 1 or len(new_starts) != 1:
                continue
            old_start = old_starts[0]
            new_start = new_starts[0]
            anchors.append((old_start, new_start, old_start - new_start))
            mapping[old_start] = (new_start, "shape24")
        anchors.sort()
        self._anchor_list = anchors
        self._anchor_map = mapping

    def nearest_delta(self, address: int) -> int:
        self._build_anchors()
        anchors = self._anchor_list or []
        if not anchors:
            return 0
        old_values = [a[0] for a in anchors]
        position = bisect.bisect_left(old_values, address)
        best = []
        for index in (position - 1, position):
            if 0 <= index < len(anchors):
                best.append((abs(anchors[index][0] - address), anchors[index][2]))
        return min(best)[1]

    # -- function mapping ---------------------------------------------

    def map_function_start(self, old_start: int) -> Tuple[int, str]:
        cached = self._function_cache.get(old_start)
        if cached is not None:
            return cached
        self._build_anchors()
        anchor = (self._anchor_map or {}).get(old_start)
        if anchor is not None:
            self._function_cache[old_start] = anchor
            return anchor

        predicted = old_start - self.nearest_delta(old_start)
        old_shape = self.old.shape_at(old_start, 16)
        old_prefix = words_to_bytes([int(v) for v in self.old.normalized_at(old_start, 16)])

        lo = bisect.bisect_left(self.new.starts, predicted - 0x20000)
        hi = bisect.bisect_right(self.new.starts, predicted + 0x20000)
        scored: List[Tuple[int, int, int, int]] = []
        for start in self.new.starts[lo:hi]:
            if start + 64 > self.new.text_end:
                continue
            new_shape = self.new.shape_at(start, 16)
            shape_score = sum(1 for a, b in zip(old_shape, new_shape) if a == b)
            first_mismatch = 0
            for a, b in zip(old_shape, new_shape):
                if a != b:
                    break
                first_mismatch += 1
            prefix_equal = 1 if words_to_bytes([int(v) for v in self.new.normalized_at(start, 16)]) == old_prefix else 0
            scored.append((prefix_equal, shape_score, first_mismatch, -abs(start - predicted), start))
        if scored:
            scored.sort(key=lambda item: (item[0], item[1]), reverse=True)
            best = scored[0]
            # A unique exact 16-instruction prefix near the predicted delta is safe.
            if best[0] == 1 and (len(scored) == 1 or scored[1][0] == 0):
                result = (best[4], "prefix16")
                self._function_cache[old_start] = result
                return result
            # Otherwise require a strong shape prefix.
            runner_up = scored[1] if len(scored) > 1 else None
            if best[1] >= 12 and (runner_up is None or best[1] - runner_up[1] >= 2):
                result = (best[4], "shape16")
                self._function_cache[old_start] = result
                return result
        result = (predicted, "delta")
        self._function_cache[old_start] = result
        return result

    # -- alignment -----------------------------------------------------

    def _align(self, old_start: int, new_start: int):
        key = (old_start, new_start)
        cached = self._alignment_cache.get(key)
        if cached is not None:
            return cached
        old_words = self.old.function_words(old_start, 0x8000)
        new_words = self.new.function_words(new_start, 0x8000)
        old_values = [int(v) for v in self.old.normalized_at(old_start, len(old_words))]
        new_values = [int(v) for v in self.new.normalized_at(new_start, len(new_words))]
        matcher = difflib.SequenceMatcher(None, old_values, new_values, autojunk=False)
        blocks = matcher.get_matching_blocks()
        self._alignment_cache[key] = blocks
        return blocks

    def _map_offset(self, old_start: int, new_start: int, old_offset: int) -> Tuple[int, str]:
        if old_offset == 0:
            return new_start, "entry"
        blocks = self._align(old_start, new_start)
        index = old_offset // 4
        for a, b, size in blocks:
            if a <= index < a + size:
                return new_start + (b + (index - a)) * 4, "align"
        # Nearest matching block fallback.
        best = None
        for a, b, size in blocks:
            distance = abs(a - index)
            candidate = new_start + (b + min(max(index - a, 0), size)) * 4
            if best is None or distance < best[0]:
                best = (distance, candidate)
        if best is not None:
            return best[1], "align_nearest"
        return new_start + old_offset, "offset"

    # -- code addresses ------------------------------------------------

    def map_code(self, old_addr: int) -> KeyResult:
        old_start, old_offset = self.old.enclosing(old_addr)
        if old_start is None:
            return KeyResult("", "function", old_addr, None, UNRESOLVED, "enclosing")
        new_start, function_method = self.map_function_start(old_start)
        candidate, offset_method = self._map_offset(old_start, new_start, old_offset)
        checks: List[str] = []
        method = f"{function_method}/{offset_method}"

        # If alignment and prediction disagree, try both and score windows.
        candidate = self._refine_candidate(old_addr, candidate, checks)
        exact = self._window_equal(old_addr, candidate, 12)
        if exact:
            checks.append("normalized_window_12")
        shape = self._shape_window_equal(old_addr, candidate, 12)
        if shape:
            checks.append("shape_window_12")
        predecessor_ok = self._predecessor_bl_match(old_addr, candidate)
        if predecessor_ok:
            checks.append("predecessor_bl")

        if exact or predecessor_ok:
            status = HIGH
        elif shape:
            status = MEDIUM
        elif function_method in ("shape24", "prefix16") and offset_method == "entry":
            status = MEDIUM
        else:
            status = REVIEW
        alternatives = self._nearby_alternatives(old_addr, candidate)
        return KeyResult("", "function", old_addr, candidate, status, method, checks,
                         {"old_func": format_value(old_start), "new_func": format_value(new_start),
                          "old_offset": format_value(old_offset)}, alternatives)

    def _window_equal(self, old_addr: int, new_addr: int, count: int) -> bool:
        if old_addr % 4 or new_addr % 4:
            return False
        if old_addr + count * 4 > self.old.text_end or new_addr + count * 4 > self.new.text_end:
            return False
        return words_to_bytes(self.old.normalized_at(old_addr, count)) == words_to_bytes(
            self.new.normalized_at(new_addr, count)
        )

    def _shape_window_equal(self, old_addr: int, new_addr: int, count: int) -> bool:
        return self.old.shape_at(old_addr, count) == self.new.shape_at(new_addr, count)

    def _predecessor_bl_match(self, old_addr: int, new_addr: int) -> bool:
        if old_addr < 4 or new_addr < 4:
            return False
        old_prev = decode_insn(int(self.old.word_at(old_addr - 4) or 0), old_addr - 4)
        new_prev = decode_insn(int(self.new.word_at(new_addr - 4) or 0), new_addr - 4)
        return old_prev.kind == "bl" and new_prev.kind == "bl"

    def _refine_candidate(self, old_addr: int, candidate: int, checks: List[str]) -> int:
        # Snap to an exact 4-instruction window within +/-0x40 when the
        # predicted address is off by a few instructions.
        if self._window_equal(old_addr, candidate, 4):
            return candidate
        old_window = words_to_bytes(self.old.normalized_at(old_addr, 4))
        best = None
        for delta in range(-0x40, 0x41, 4):
            probe = candidate + delta
            if probe < self.new.text_start or probe + 16 > self.new.text_end:
                continue
            if words_to_bytes(self.new.normalized_at(probe, 4)) == old_window:
                score = abs(delta)
                if best is None or score < best[0]:
                    best = (score, probe)
        if best is not None:
            checks.append("snapped_4insn")
            return best[1]
        return candidate

    def _nearby_alternatives(self, old_addr: int, candidate: int, radius: int = 0x100) -> List[Dict[str, object]]:
        alternatives: List[Dict[str, object]] = []
        for count in (8, 4):
            window = words_to_bytes(self.old.normalized_at(old_addr, count))
            start = max(self.new.text_start, candidate - radius)
            end = min(self.new.text_end, candidate + radius)
            pos = start
            while pos + count * 4 <= end:
                if words_to_bytes(self.new.normalized_at(pos, count)) == window:
                    alternatives.append({"address": format_value(pos), "window": count,
                                         "distance": abs(pos - candidate)})
                    if len(alternatives) >= 5:
                        return alternatives
                pos += 4
        return alternatives

    # -- vtables -------------------------------------------------------

    def read_vtable(self, address: int, image: Optional[Image] = None,
                    limit: int = 64) -> VTable:
        image = image or self.new
        cache_key = (id(image), address)
        cached = self._vtable_cache.get(cache_key)
        if cached is not None:
            return cached
        entries: List[int] = []
        for index in range(limit):
            pointer = image.pointer_at(address + index * 8)
            if pointer is None or not image.macho.is_code(pointer):
                break
            entries.append(pointer)
        typeinfo = image.pointer_at(address - 8)
        name = None
        if typeinfo:
            name_pointer = image.pointer_at(typeinfo + 8)
            if name_pointer:
                name = image.cstring(name_pointer)
        vtable = VTable(address=address, entries=entries, typeinfo=typeinfo, name=name)
        self._vtable_cache[cache_key] = vtable
        return vtable

    def data_delta(self) -> int:
        old_section = self.old.macho.section("__const", "__DATA_CONST") or self.old.macho.section("__data", "__DATA")
        new_section = self.new.macho.section("__const", "__DATA_CONST") or self.new.macho.section("__data", "__DATA")
        if old_section is None or new_section is None:
            return 0
        return new_section.addr - old_section.addr

    def find_vtable_by_name(self, name: str, expected_count: int) -> List[VTable]:
        candidates: List[VTable] = []
        seen = set()
        for string_address in self.new.find_string_addresses(name):
            # The data slot holding the string address is typeinfo+8 (the name
            # field). The slot holding typeinfo is vtable-8.
            for name_slot in self.new.data_slots_pointing_to(string_address):
                typeinfo = name_slot - 8
                for vtable_slot in self.new.data_slots_pointing_to(typeinfo):
                    address = vtable_slot + 8
                    if address in seen:
                        continue
                    seen.add(address)
                    vtable = self.read_vtable(address)
                    if not vtable.entries or len(vtable.entries) != expected_count:
                        continue
                    if vtable.typeinfo != typeinfo:
                        continue
                    candidates.append(vtable)
        return candidates

    def _score_vtable_candidate(self, old_vtable: VTable, candidate: VTable,
                                predicted_entries: Optional[List[int]] = None) -> float:
        if len(candidate.entries) != len(old_vtable.entries):
            return -1e18
        if predicted_entries is None:
            predicted_entries = [entry - self.nearest_delta(entry) for entry in old_vtable.entries]
        score = 0.0
        for predicted, new_entry in zip(predicted_entries, candidate.entries):
            score -= min(abs(new_entry - predicted), 0x40000)
        # Prefer a tight delta cluster.
        deltas = [new_entry - old_entry for old_entry, new_entry in zip(old_vtable.entries, candidate.entries)]
        score -= (max(deltas) - min(deltas)) * 0.5
        return score

    def _all_new_vtables(self) -> List[VTable]:
        if self._new_vtable_candidates is not None:
            return self._new_vtable_candidates
        candidates: List[VTable] = []
        for section in self.new.macho.sections:
            if section.segment not in ("__DATA_CONST", "__DATA", "__AUTH_CONST"):
                continue
            if section.name not in ("__const", "__data", "__bss", "__common", "__auth_ptr"):
                continue
            address = section.addr
            while address + 24 <= section.end:
                pointer = self.new.pointer_at(address)
                if pointer is not None and self.new.macho.is_code(pointer):
                    previous = self.new.pointer_at(address - 8) if address - 8 >= section.addr else None
                    if previous is None or not self.new.macho.is_code(previous):
                        typeinfo = previous
                        name = None
                        if typeinfo and self.new.section_at(typeinfo):
                            name_pointer = self.new.pointer_at(typeinfo + 8)
                            if name_pointer:
                                name = self.new.cstring(name_pointer)
                        if name and 4 <= len(name) <= 128 and all(32 <= ord(ch) < 127 for ch in name):
                            vtable = self.read_vtable(address)
                            if len(vtable.entries) >= 3:
                                candidates.append(vtable)
                address += 8
        self._new_vtable_candidates = candidates
        return candidates

    def resolve_vtable(self, key: str, old_addr: int) -> KeyResult:
        old_vtable = self.read_vtable(old_addr, self.old)
        checks = [f"old_entries={len(old_vtable.entries)}"]
        alternatives: List[Dict[str, object]] = []

        structural = self.structural_for(key)
        if structural is not None:
            candidate_address, method, evidence, structural_status = structural
            candidate = self.read_vtable(candidate_address)
            if len(candidate.entries) == len(old_vtable.entries):
                if old_vtable.name and candidate.name == old_vtable.name:
                    checks.append("structural+rtti")
                    return KeyResult(key, "vtable", old_addr, candidate_address, VERIFIED, method,
                                     checks, evidence)
                checks.append("structural")
                return KeyResult(key, "vtable", old_addr, candidate_address, structural_status, method,
                                 checks, evidence)

        if old_vtable.name:
            name_candidates = self.find_vtable_by_name(old_vtable.name, len(old_vtable.entries))
            if len(name_candidates) == 1:
                candidate = name_candidates[0]
                checks.append("rtti_name")
                checks.append("entries_count")
                return KeyResult(key, "vtable", old_addr, candidate.address, VERIFIED, "rtti_name",
                                 checks, {"rtti": old_vtable.name,
                                          "entries": [format_value(x) for x in candidate.entries]})
            if len(name_candidates) > 1:
                alternatives = [{"address": format_value(v.address), "distance": 0} for v in name_candidates[:5]]

        # Fallback: score data-section candidates by entry deltas. Data
        # sections move independently from __TEXT, so use the __DATA_CONST
        # section delta rather than a code anchor delta.
        predicted = old_addr + self.data_delta()
        predicted_entries = None
        if old_vtable.entries:
            predicted_entries = [entry - self.nearest_delta(entry) for entry in old_vtable.entries]
            first_prediction = predicted_entries[0]
        else:
            first_prediction = predicted
        scored = []
        for candidate in self._all_new_vtables():
            if len(candidate.entries) != len(old_vtable.entries):
                continue
            if abs(candidate.entries[0] - first_prediction) > 0x40000:
                continue
            distance = abs(candidate.address - predicted)
            if distance > 0x100000:
                continue
            score = self._score_vtable_candidate(old_vtable, candidate, predicted_entries)
            scored.append((score, -distance, candidate))
        scored.sort(key=lambda item: (item[0], item[1]), reverse=True)
        if scored:
            best = scored[0][2]
            alternatives = [{"address": format_value(v.address), "score": round(s, 2)}
                            for s, _, v in scored[:5]]
            status = REVIEW
            method = "vtable_delta"
            if len(scored) == 1:
                status = MEDIUM
            elif scored[0][0] - scored[1][0] > 0x8000:
                status = MEDIUM
            return KeyResult(key, "vtable", old_addr, best.address, status, method, checks,
                             {"rtti": old_vtable.name, "entries": [format_value(x) for x in best.entries]},
                             alternatives)
        return KeyResult(key, "vtable", old_addr, None, UNRESOLVED, "vtable", checks,
                         {"rtti": old_vtable.name}, alternatives)

    # -- ctors / decoders / sizes -------------------------------------

    # -- structural class discovery (factory -> ctor -> vtable) --------

    STRUCTURAL_CLASSES = [
        ("newSendMsgTaskCtorAddr", "newSendMsgTaskSize", "newSendMsgTaskVtable"),
        ("voiceTaskCtorAddr", "voiceTaskSize", "voiceTaskVtable"),
        ("snsTimelineCtor", "snsTimelineSize", "snsTimelineVtable"),
        ("snsSyncCtor", "snsSyncSize", "snsSyncVtable"),
        ("snsPostCtor", "snsPostSize", "snsPostVtable"),
        ("snsUserpageCtor", "snsUserpageSize", "snsUserpageVtable"),
        ("snsCommentCtor", "snsCommentSize", "snsCommentVtable"),
    ]

    def _stored_vtables(self, ctor: int) -> List[int]:
        cache = getattr(self, "_stored_vtable_cache", None)
        if cache is None:
            cache = {}
            self._stored_vtable_cache = cache
        if ctor in cache:
            return cache[ctor]
        result: List[int] = []
        if ctor in self.new.starts_set:
            words = self.new.function_words(ctor, 0x1000)
            insns = [decode_insn(int(word), ctor + i * 4) for i, word in enumerate(words)]
            refs = data_refs(words, ctor)
            for ref in refs:
                if stores_pointer_to(refs, insns, ref.target, base_reg=0) is not None:
                    if ref.target not in result:
                        result.append(ref.target)
        cache[ctor] = result
        return result

    def _scan_factories(self) -> List[dict]:
        cache = getattr(self, "_factory_cache", None)
        if cache is not None:
            return cache
        operator_new = self.new.find_stub("__Znwm")
        sizes = set()
        for key in self.old_table.data:
            if key.endswith("Size"):
                value = self.old_table.hex_value(key)
                if value is not None:
                    sizes.add(value)
        factories: List[dict] = []
        if operator_new is None:
            self._factory_cache = factories
            return factories
        words = self.new.words
        total = len(words)
        if np is not None:
            mask = ((words & 0x7F800000) == 0x52800000) & ((words & 0x1F) == 0)
            indices = np.nonzero(mask)[0]
        else:  # pragma: no cover - slow fallback
            indices = (i for i in range(total)
                       if (int(words[i]) & 0x7F800000) == 0x52800000 and (int(words[i]) & 0x1F) == 0)
        seen = set()
        for index in indices:
            index = int(index)
            insn = decode_insn(int(words[index]), index * 4)
            if insn.kind != "mov_wide" or insn.rd != 0 or insn.imm is None:
                continue
            if insn.imm not in sizes:
                continue
            operator_new_pc = None
            for step in (1, 2, 3):
                position = index + step
                if position >= total:
                    break
                candidate = decode_insn(int(words[position]), position * 4)
                if candidate.kind == "bl" and candidate.target == operator_new:
                    operator_new_pc = position
                    break
            if operator_new_pc is None:
                continue
            for step in range(1, 7):
                position = operator_new_pc + step
                if position >= total:
                    break
                candidate = decode_insn(int(words[position]), position * 4)
                if candidate.kind == "bl" and candidate.target != operator_new:
                    ctor = candidate.target
                    if ctor in self.new.starts_set:
                        key = (insn.imm, ctor)
                        if key not in seen:
                            seen.add(key)
                            factories.append({"size": insn.imm, "factory": index * 4, "ctor": ctor,
                                              "call_pc": position * 4})
                    break
        self._factory_cache = factories
        return factories

    def _scan_structural_classes(self) -> None:
        if getattr(self, "_structural_done", False):
            return
        self._structural_done = True
        self.structural_ctors: Dict[str, Tuple[int, str, dict, str]] = {}
        self.structural_sizes: Dict[str, Tuple[int, str, dict, str]] = {}
        self.structural_vtables: Dict[str, Tuple[int, str, dict, str]] = {}
        factories = self._scan_factories()
        if not factories:
            return
        for ctor_key, size_key, vtable_key in self.STRUCTURAL_CLASSES:
            old_size = self.old_table.hex_value(size_key)
            old_vtable_addr = self.old_table.hex_value(vtable_key)
            if old_size is None or old_vtable_addr is None:
                continue
            old_vtable = self.read_vtable(old_vtable_addr, self.old)
            predicted_ctor = None
            try:
                predicted_ctor = self.map_function_start(self.old_table.hex_value(ctor_key))[0]
            except Exception:
                predicted_ctor = None
            scored = []
            for factory in factories:
                if factory["size"] != old_size:
                    continue
                ctor = factory["ctor"]
                for vtable_address in self._stored_vtables(ctor):
                    vtable = self.read_vtable(vtable_address)
                    if len(vtable.entries) != len(old_vtable.entries):
                        continue
                    name_match = bool(old_vtable.name and vtable.name == old_vtable.name)
                    entry_error = 0
                    exact_matches = 0
                    for old_entry, new_entry in zip(old_vtable.entries, vtable.entries):
                        predicted_entry = old_entry - self.nearest_delta(old_entry)
                        entry_error += abs(new_entry - predicted_entry)
                        if self.old.function_hash(old_entry) == self.new.function_hash(new_entry):
                            exact_matches += 1
                    distance = abs(ctor - predicted_ctor) if predicted_ctor is not None else 0
                    # Constructor code and its vtable methods are laid out by
                    # the same recompilation delta. This is the strongest
                    # discriminator between sibling classes of equal size.
                    deltas = [new_entry - old_entry
                              for old_entry, new_entry in zip(old_vtable.entries, vtable.entries)]
                    deltas.sort()
                    median_delta = deltas[len(deltas) // 2]
                    ctor_delta = ctor - self.old_table.hex_value(ctor_key)
                    delta_gap = abs(median_delta - ctor_delta)
                    score = ((1000000 if name_match else 0)
                             - delta_gap * 1000
                             + exact_matches * 10000 - entry_error * 0.01 - distance * 0.1)
                    scored.append((score, ctor, vtable, name_match, entry_error, distance,
                                   delta_gap, exact_matches))
            if not scored:
                continue
            scored.sort(key=lambda item: (item[0], -item[5]), reverse=True)
            best = scored[0]
            runner_up = scored[1] if len(scored) > 1 else None
            if runner_up is not None and best[0] - runner_up[0] < 1:
                continue
            score, ctor, vtable, name_match, entry_error, distance, delta_gap, exact_matches = best
            method = "factory+ctor"
            evidence = {
                "size": format_value(old_size),
                "entry_error": entry_error,
                "exact_matches": exact_matches,
                "delta_gap": delta_gap,
                "rtti_match": name_match,
                "candidates": len(scored),
            }
            margin = (best[0] - runner_up[0]) if runner_up is not None else float("inf")
            if name_match:
                confidence = VERIFIED
            elif margin >= 100000:
                confidence = HIGH
            else:
                confidence = REVIEW
            evidence["margin"] = margin if margin != float("inf") else None
            self.structural_ctors[ctor_key] = (ctor, method, evidence, confidence)
            self.structural_sizes[size_key] = (old_size, method, evidence, confidence)
            self.structural_vtables[vtable_key] = (vtable.address, method, evidence, confidence)

    def structural_for(self, key: str):
        if not getattr(self, "_structural_done", False):
            self._scan_structural_classes()
        return (self.structural_ctors.get(key) or self.structural_sizes.get(key)
                or self.structural_vtables.get(key))


    VTABLE_RELATIONS = {
        "newSendMsgTaskCtorAddr": "newSendMsgTaskVtable",
        "voiceTaskCtorAddr": "voiceTaskVtable",
        "snsTimelineCtor": "snsTimelineVtable",
        "snsSyncCtor": "snsSyncVtable",
        "snsPostCtor": "snsPostVtable",
        "snsUserpageCtor": "snsUserpageVtable",
        "snsCommentCtor": "snsCommentVtable",
    }

    def _writes_vtable(self, function_start: int, vtable_address: int) -> bool:
        words = self.new.function_words(function_start, 0x4000)
        insns = [decode_insn(int(word), function_start + i * 4) for i, word in enumerate(words)]
        refs = data_refs(words, function_start)
        return stores_pointer_to(refs, insns, vtable_address, base_reg=0) is not None

    def resolve_ctor(self, key: str, old_addr: int, vtable_key: str) -> KeyResult:
        structural = self.structural_for(key)
        vtable_result = self.results.get(vtable_key)
        if structural is not None:
            candidate, method, evidence, structural_status = structural
            if vtable_result and vtable_result.new and self._writes_vtable(candidate, vtable_result.new):
                return KeyResult(key, "ctor", old_addr, candidate, structural_status, method,
                                 ["factory", "writes_vtable"], evidence)
            if not vtable_result:
                stored = self._stored_vtables(candidate)
                if len(stored) == 1:
                    return KeyResult(key, "ctor", old_addr, candidate, structural_status, method,
                                     ["factory", "stored_vtable"], evidence)
        mapped = self.map_code(old_addr)
        checks: List[str] = []
        if vtable_result and vtable_result.new:
            if self._writes_vtable(mapped.new, vtable_result.new):
                checks.append("writes_vtable")
                return KeyResult(key, "ctor", old_addr, mapped.new, VERIFIED, "ctor_writes_vtable",
                                 checks, {"vtable": format_value(vtable_result.new)},
                                 mapped.alternatives)
            # Search nearby constructors that write the expected vtable.
            predicted = mapped.new
            lo = bisect.bisect_left(self.new.starts, predicted - 0x20000)
            hi = bisect.bisect_right(self.new.starts, predicted + 0x20000)
            matches = [start for start in self.new.starts[lo:hi]
                       if self._writes_vtable(start, vtable_result.new)]
            if len(matches) == 1:
                checks.append("writes_vtable_search")
                return KeyResult(key, "ctor", old_addr, matches[0], HIGH, "ctor_write_search",
                                 checks, {"vtable": format_value(vtable_result.new)},
                                 [{"address": format_value(x), "distance": abs(x - predicted)} for x in matches[:5]])
        return KeyResult(key, "ctor", old_addr, mapped.new, mapped.status, mapped.method,
                         mapped.checks + checks, mapped.evidence, mapped.alternatives,
                         "could not prove constructor/vtable relation")

    def resolve_decoder(self, key: str, old_addr: int, vtable_key: str) -> KeyResult:
        old_vtable = self.read_vtable(self.old_table.hex_value(vtable_key) or 0, self.old)
        if old_addr not in old_vtable.entries:
            return KeyResult(key, "decoder", old_addr, None, UNRESOLVED, "decoder_slot")
        slot = old_vtable.entries.index(old_addr)
        vtable_result = self.results.get(vtable_key)
        if vtable_result and vtable_result.new:
            new_vtable = self.read_vtable(vtable_result.new)
            if slot < len(new_vtable.entries):
                status = VERIFIED if vtable_result.status in ACCEPTABLE else REVIEW
                return KeyResult(key, "decoder", old_addr, new_vtable.entries[slot], status,
                                 "vtable_slot", [f"slot={slot}"],
                                 {"vtable": format_value(new_vtable.address),
                                  "vtable_status": vtable_result.status})
        return KeyResult(key, "decoder", old_addr, None, UNRESOLVED, "decoder_slot")

    def resolve_size(self, key: str, old_addr: int, ctor_key: str) -> KeyResult:
        structural = self.structural_for(key)
        if structural is not None:
            value, method, evidence, structural_status = structural
            if value == old_addr:
                return KeyResult(key, "size", old_addr, value, structural_status, method,
                                 ["factory_size"], evidence)
        ctor_result = self.results.get(ctor_key)
        operator_new = self.new.find_stub("__Znwm")
        if ctor_result and ctor_result.new and operator_new:
            start = max(self.new.text_start, ctor_result.new - 0x800)
            end = min(self.new.text_end, ctor_result.new + 0x80)
            for candidate in self.new.starts:
                if candidate < start or candidate > end:
                    continue
                words = self.new.function_words(candidate, 0x800)
                size = find_factory_size(words, candidate, ctor_result.new, operator_new)
                if size is not None and size == old_addr:
                    return KeyResult(key, "size", old_addr, size, VERIFIED, "factory",
                                     ["operator_new", "ctor_call"], {"factory": format_value(candidate)})
        return KeyResult(key, "size", old_addr, old_addr, REVIEW, "carry", ["unverified_size"],
                         note="size constant was not proven from an operator-new factory")

    def resolve_body_return(self, key: str, old_addr: int) -> KeyResult:
        mapped = self.map_code(old_addr)
        if mapped.new is None:
            return mapped
        candidate = mapped.new
        checks = list(mapped.checks)
        if candidate >= 4:
            previous = decode_insn(int(self.new.word_at(candidate - 4) or 0), candidate - 4)
            if previous.kind == "bl" and (self._window_equal(old_addr, candidate, 4)
                                          or self._shape_window_equal(old_addr, candidate, 4)):
                checks.append("preceded_by_bl")
                status = HIGH if mapped.status in ACCEPTABLE else REVIEW
                return KeyResult(key, "body_return", old_addr, candidate, status, mapped.method, checks,
                                 mapped.evidence, mapped.alternatives)
        # Search a small window for a matching return site after a BL. SP-relative
        # offsets change between builds, so use the immediate-insensitive shape.
        best = None
        for delta in range(-0x80, 0x81, 4):
            probe = candidate + delta
            if probe < self.new.text_start + 4 or probe >= self.new.text_end:
                continue
            previous = decode_insn(int(self.new.word_at(probe - 4) or 0), probe - 4)
            if previous.kind != "bl":
                continue
            if self._window_equal(old_addr, probe, 4) or self._shape_window_equal(old_addr, probe, 4):
                distance = abs(delta)
                if best is None or distance < best[0]:
                    best = (distance, probe)
        if best is not None:
            checks.append("return_site_snapped")
            status = HIGH if mapped.status in ACCEPTABLE else REVIEW
            return KeyResult(key, "body_return", old_addr, best[1], status, "return_site", checks,
                             mapped.evidence, mapped.alternatives)
        return KeyResult(key, "body_return", old_addr, candidate, REVIEW, mapped.method, checks,
                         mapped.evidence, mapped.alternatives)

    # -- stub / data / string -----------------------------------------

    def resolve_stub(self, key: str, old_addr: int) -> KeyResult:
        stub = self.new.find_stub("__Znwm")
        if stub:
            return KeyResult(key, "stub", old_addr, stub, VERIFIED, "import", ["__Znwm"])
        return KeyResult(key, "stub", old_addr, None, UNRESOLVED, "import")

    def _xref_vote(self, old_addr: int, limit: int = 256) -> Tuple[Dict[int, int], List[dict]]:
        from collections import Counter

        refs = self.old.xrefs_to(old_addr, limit=limit)
        votes: Counter = Counter()
        details: List[dict] = []
        seen_functions = set()
        for ref in refs:
            function_start = ref["function_start"]
            if function_start in seen_functions:
                continue
            seen_functions.add(function_start)
            new_function, method = self.map_function_start(function_start)
            pc = new_function + ref["offset"]
            word = self.new.word_at(pc)
            if word is None:
                continue
            adrp = decode_insn(word, pc)
            if adrp.kind != "adrp" or adrp.page is None:
                continue
            target = None
            for step in (1, 2):
                next_word = self.new.word_at(pc + step * 4)
                if next_word is None:
                    break
                insn = decode_insn(next_word, pc + step * 4)
                if insn.kind == "addsub_imm" and insn.rn == adrp.rd:
                    target = adrp.page + (insn.imm or 0)
                    break
                if insn.kind == "ldrstr_imm" and insn.rn == adrp.rd:
                    target = adrp.page + (insn.imm or 0)
                    break
            if target is None:
                continue
            votes[target] += 1
            if len(details) < 8:
                details.append({"old_function": format_value(function_start),
                                "new_function": format_value(new_function),
                                "method": method,
                                "candidate": format_value(target)})
        return dict(votes), details

    def resolve_data(self, key: str, old_addr: int) -> KeyResult:
        votes, details = self._xref_vote(old_addr)
        ranked = sorted(votes.items(), key=lambda item: item[1], reverse=True)
        alternatives = [{"address": format_value(address), "votes": count}
                        for address, count in ranked[:8]]
        predicted = old_addr + self.nearest_delta(old_addr)
        section = self.new.section_at(predicted)
        if ranked and ranked[0][1] >= 3:
            candidate, count = ranked[0]
            runner_up = ranked[1][1] if len(ranked) > 1 else 0
            if count >= 2 * runner_up and self.new.section_at(candidate) is not None:
                return KeyResult(key, "data", old_addr, candidate, VERIFIED, "xref_vote",
                                 [f"votes={count}"], {"votes": count, "details": details}, alternatives)
            return KeyResult(key, "data", old_addr, candidate, HIGH, "xref_vote",
                             [f"votes={count}"], {"votes": count, "details": details}, alternatives)
        if section is not None:
            return KeyResult(key, "data", old_addr, predicted, MEDIUM, "data_delta",
                             [f"section={section.segment},{section.name}"], {}, alternatives)
        return KeyResult(key, "data", old_addr, predicted, REVIEW, "data_delta", [], {}, alternatives)

    def resolve_string(self, key: str, old_addr: int) -> KeyResult:
        content = self.old.cstring(old_addr)
        if not content:
            return KeyResult(key, "string", old_addr, None, UNRESOLVED, "content")
        votes, details = self._xref_vote(old_addr)
        matching = {address: count for address, count in votes.items()
                    if self.new.cstring(address, len(content) + 1) == content}
        ranked = sorted(matching.items(), key=lambda item: item[1], reverse=True)
        alternatives = [{"address": format_value(address), "votes": count}
                        for address, count in ranked[:8]]
        if ranked and ranked[0][1] >= 3:
            candidate, count = ranked[0]
            runner_up = ranked[1][1] if len(ranked) > 1 else 0
            status = VERIFIED if count >= 2 * runner_up else HIGH
            return KeyResult(key, "string", old_addr, candidate, status, "string_xref",
                             [f"content={content!r}", f"votes={count}"],
                             {"votes": count, "details": details}, alternatives)
        addresses = self.new.find_string_addresses(content)
        if len(addresses) == 1:
            return KeyResult(key, "string", old_addr, addresses[0], MEDIUM, "content",
                             [f"content={content!r}"], {}, alternatives)
        alternatives += [{"address": format_value(a)} for a in addresses[:8]]
        return KeyResult(key, "string", old_addr, addresses[0] if addresses else None, REVIEW, "content",
                         [f"content={content!r}", f"candidates={len(addresses)}"], {}, alternatives)

    # -- dispatch ------------------------------------------------------

    def resolve_all(self) -> Dict[str, KeyResult]:
        # Discover factory -> ctor -> vtable triples first; this is independent
        # of code-address interpolation and works across large recompiles.
        self._scan_structural_classes()
        # Resolve structural keys first so ctors/decoders/sizes can use them.
        order = sorted(self.old_table.address_keys(),
                       key=lambda key: 0 if key.endswith("Vtable") else 1)
        for key in order:
            old_value = self.old_table.hex_value(key)
            if old_value is None:
                continue
            kind = key_kind(key, self.old_table.get(key))
            if kind == "vtable":
                result = self.resolve_vtable(key, old_value)
            elif kind == "ctor":
                relation = self.VTABLE_RELATIONS.get(key)
                result = self.resolve_ctor(key, old_value, relation) if relation else self.map_code(old_value)
            elif kind == "decoder":
                relation = key[:-len("Decoder")] + "Vtable"
                result = self.resolve_decoder(key, old_value, relation)
            elif kind == "size":
                ctor_key = key[:-len("Size")] + "CtorAddr"
                if ctor_key not in self.old_table.data:
                    ctor_key = key[:-len("Size")] + "Ctor"
                result = self.resolve_size(key, old_value, ctor_key)
            elif kind == "body_return":
                result = self.resolve_body_return(key, old_value)
            elif kind == "stub":
                result = self.resolve_stub(key, old_value)
            elif kind == "data":
                result = self.resolve_data(key, old_value)
            elif kind == "string":
                result = self.resolve_string(key, old_value)
            elif kind == "function":
                result = self.map_code(old_value)
            else:
                result = KeyResult(key, kind, old_value, old_value, CARRIED, "carry")
            result.key = key
            self.results[key] = result
        self._apply_relations()
        return self.results

    def _apply_relations(self) -> None:
        # Equality groups (keys with the same baseline value must stay equal).
        groups: Dict[int, List[str]] = {}
        for key, result in self.results.items():
            if result.old is not None:
                groups.setdefault(result.old, []).append(key)
        for old_value, keys in groups.items():
            if len(keys) < 2:
                continue
            best = min((self.results[key] for key in keys if self.results[key].new),
                       key=lambda result: STATUS_ORDER[result.status], default=None)
            if best is None:
                continue
            for key in keys:
                result = self.results[key]
                if result.new is not None and result.new != best.new:
                    result.checks.append("equality_conflict")
                    result.status = max(result.status, REVIEW, key=STATUS_ORDER.get)
                elif result.new is None:
                    result.new = best.new
                    result.status = best.status
                    result.method = f"equality/{best.method}"

        # Closure vtable = task vtable + 0x58, only when that relation held in
        # the baseline. Newer builds may share a single closure vtable instead.
        for key, task_key in self._closure_relations.items():
            result = self.results.get(key)
            task = self.results.get(task_key)
            if result and task and result.new is not None and task.new is not None:
                if result.new != task.new + 0x58:
                    result.checks.append("closure_relation_failed")
                    result.status = max(result.status, REVIEW, key=STATUS_ORDER.get)

    # -- table generation ---------------------------------------------

    def candidate_table(self) -> VersionTable:
        values: Dict[str, object] = {}
        missing: List[str] = []
        for key in self.old_table.address_keys():
            result = self.results.get(key)
            if result is None:
                continue
            if result.new is None:
                if key in self._required_keys():
                    missing.append(key)
                continue
            values[key] = format_value(result.new)
        table = self.old_table.with_values(values, mark_unverified=True)
        if missing:
            table = table.without_values(missing)
        return table

    def _required_keys(self) -> set:
        from .table import SEND_PAT_KEYS, SNS_BODY_RETURN_KEYS, SNS_PREFIXES, SNS_SUFFIXES

        required = set()
        for key in self.old_table.data:
            if key.endswith(("Vtable", "Ctor", "Decoder", "BodyReturn", "Addr", "Size")):
                required.add(key)
        required.update(SNS_BODY_RETURN_KEYS)
        for prefix in SNS_PREFIXES:
            required.update(prefix + suffix for suffix in SNS_SUFFIXES)
        required.update(SEND_PAT_KEYS)
        return required

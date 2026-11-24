"""Version-table schema, classification, rendering and validation."""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
from dataclasses import dataclass, field
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

HEX_RE = re.compile(r"^0x[0-9a-fA-F]+$")
TEMPLATE_KEY_RE = re.compile(r"\{\{\s*\.([A-Za-z0-9_]+)\s*\}\}")
TEMPLATE_IF_RE = re.compile(r"\{\{\s*if\s+\.([A-Za-z0-9_]+)\s*\}\}(.*?)\{\{\s*end\s*\}\}", re.S)
TEMPLATE_ACTION_RE = re.compile(r"\{\{(.*?)\}\}", re.S)

SAFETY_SWITCHES = {
    "enableSend": "false",
    "req2bufSendMode": "off",
    "snsEnable": "false",
    "snsProbe": "false",
    "r3PatSend": "false",
    "r3VoiceSend": "false",
    "r3AppMsgSend": "false",
}

URL_KEYS = {"newsendmsgUrl", "appmsgUrl", "voiceUrl"}
STRING_KEYS = {"defaultScopeString"}
DATA_KEYS = {"globalServiceHolder"}
STUB_KEYS = {"operatorNewAddr"}
SIZE_KEYS_SUFFIX = "Size"
OFFSET_KEYS = {"messageContentOffset", "messageCreatedOffset"}
OPCODE_KEYS = {"voiceOpcode"}
VTABLE_KEYS_SUFFIX = "Vtable"
CTOR_KEYS_SUFFIX = "Ctor"
DECODER_KEYS_SUFFIX = "Decoder"
BODY_RETURN_KEYS_SUFFIX = "BodyReturn"
SPECIAL_FUNC_KEYS = {
    "startDownloadMedia",
    "sendFuncAddr",
    "messageFinalizerAddr",
    "slot13Addr",
    "serviceScopeAddr",
    "uploadImageAddr",
    "cdnGetServiceManagerAddr",
}

# Keys that are bridge-only or App-only but still live in the JSON.
BRIDGE_ONLY_KEYS = {"snsPostDailyLimit", "snsPostMinIntervalMs", "snsReadMode", "snsWrite"}
BOOLEAN_KEYS = {
    "enableSend",
    "snsEnable",
    "snsProbe",
    "snsWrite",
    "snsDbRead",
    "r3AppMsgSend",
    "r3PatSend",
    "r3VoiceSend",
    "r3ClosureCapture",
    "r3Slot13Capture",
    "r3QueueUntilSeed",
    "contactDirectory",
    "hookVerified",
}
SNS_PREFIXES = ["snsTimeline", "snsSync", "snsPost", "snsUserpage", "snsComment"]
SNS_SUFFIXES = ["Ctor", "Vtable", "Size", "ClosureVtable", "Decoder"]
SNS_BODY_RETURN_KEYS = ["snsTimelineBodyReturn", "snsSyncBodyReturn",
                       "snsPostBodyReturn", "snsCommentBodyReturn"]
SNS_SWITCH_KEYS = ["snsEnable", "snsProbe"]
SEND_PAT_KEYS = [
    "sendPatTaskCtorAddr",
    "sendPatTaskVtable",
    "sendPatClosureVtable",
    "sendPatUrl",
    "sendPatOpcode",
    "sendPatTaskSize",
    "sendPatCopyAddr",
    "sendPatRequestCtorAddr",
    "sendPatRequestType",
]


class TableError(ValueError):
    pass


@dataclass
class VersionTable:
    path: str
    data: Dict[str, object]
    order: List[str] = field(default_factory=list)

    @classmethod
    def load(cls, path: str) -> "VersionTable":
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh, object_pairs_hook=_ordered_pairs)
        if not isinstance(data, dict):
            raise TableError(f"{path}: version table must be a JSON object")
        return cls(path=os.path.abspath(path), data=data, order=list(data.keys()))

    def get(self, key: str, default=None):
        return self.data.get(key, default)

    def hex_value(self, key: str) -> Optional[int]:
        value = self.data.get(key)
        if isinstance(value, str) and HEX_RE.match(value):
            return int(value, 16)
        return None

    def with_values(self, values: Dict[str, object], *, mark_unverified: bool = True) -> "VersionTable":
        data = dict(self.data)
        data.update(values)
        if mark_unverified:
            data["hookVerified"] = "false"
        for key, value in SAFETY_SWITCHES.items():
            if key in data:
                data[key] = value
        ordered = {key: data[key] for key in self.order if key in data}
        for key, value in data.items():
            if key not in ordered:
                ordered[key] = value
        return VersionTable(path=self.path, data=ordered, order=list(ordered.keys()))

    def without_values(self, keys: Iterable[str]) -> "VersionTable":
        drop = set(keys)
        data = {k: v for k, v in self.data.items() if k not in drop}
        return VersionTable(path=self.path, data=data, order=[k for k in self.order if k in data])

    def write(self, path: str) -> None:
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(self.data, fh, ensure_ascii=False, indent=2)
            fh.write("\n")

    def address_keys(self) -> List[str]:
        return [key for key in self.data if is_address_key(key, self.data[key])]

    def value_keys(self) -> List[str]:
        return [key for key in self.data if not is_address_key(key, self.data[key])]


def _ordered_pairs(pairs):
    # object_pairs_hook only preserves order in dicts in CPython 3.7+.
    return dict(pairs)


def format_value(value: int) -> str:
    return f"0x{value:x}"


def is_address_key(key: str, value: object) -> bool:
    if key in URL_KEYS or key in OFFSET_KEYS or key in OPCODE_KEYS:
        return False
    if key.endswith(SIZE_KEYS_SUFFIX):
        return False
    if key in BRIDGE_ONLY_KEYS or key in BOOLEAN_KEYS:
        return False
    if key in ("structVer", "req2bufLayout", "messageLayout", "r3MaxClones",
               "voiceOpcode", "defaultScopeString", "globalServiceHolder"):
        # defaultScopeString/globalServiceHolder are addresses despite not ending Addr.
        return key in ("defaultScopeString", "globalServiceHolder")
    if not isinstance(value, str) or not HEX_RE.match(value):
        return False
    parsed = int(value, 16)
    return parsed > 0x1000


def key_kind(key: str, value: object) -> str:
    """Return one of: switch, size, offset, opcode, url, string, data, stub,
    vtable, ctor, decoder, body_return, function, mid_function, unknown."""
    if key in URL_KEYS:
        return "url"
    if key in OFFSET_KEYS:
        return "offset"
    if key in OPCODE_KEYS:
        return "opcode"
    if key in STRING_KEYS:
        return "string"
    if key in DATA_KEYS:
        return "data"
    if key in STUB_KEYS:
        return "stub"
    if key.endswith(SIZE_KEYS_SUFFIX):
        return "size"
    if key.endswith(VTABLE_KEYS_SUFFIX):
        return "vtable"
    if key.endswith(CTOR_KEYS_SUFFIX):
        return "ctor"
    if key.endswith(DECODER_KEYS_SUFFIX):
        return "decoder"
    if key.endswith(BODY_RETURN_KEYS_SUFFIX):
        return "body_return"
    if key in ("structVer", "req2bufLayout", "messageLayout", "r3MaxClones",
               "hookVerified", "enableSend", "req2bufSendMode"):
        return "switch"
    if isinstance(value, str) and HEX_RE.match(value):
        if int(value, 16) <= 0x1000:
            return "small_constant"
        return "function"
    return "switch"


def value_groups(table: VersionTable) -> Dict[int, List[str]]:
    """Group address keys that share the same baseline value."""
    groups: Dict[int, List[str]] = {}
    for key in table.address_keys():
        value = table.hex_value(key)
        if value is not None:
            groups.setdefault(value, []).append(key)
    return groups


def diff_tables(old: VersionTable, new: VersionTable) -> List[dict]:
    rows = []
    for key in old.order:
        if key not in new.data:
            rows.append({"key": key, "old": old.data[key], "new": None, "change": "removed"})
            continue
        if old.data[key] != new.data[key]:
            rows.append({"key": key, "old": old.data[key], "new": new.data[key], "change": "changed"})
    for key in new.order:
        if key not in old.data:
            rows.append({"key": key, "old": None, "new": new.data[key], "change": "added"})
    return rows


def render_template(source: str, table: VersionTable) -> str:
    """Mimic the subset of Go text/template used by hook/script.js."""
    data = table.data

    def replace_if(match):
        key, body = match.group(1), match.group(2)
        value = data.get(key)
        if value is None or value is False or value == "" or value == 0:
            return ""
        return body

    rendered = TEMPLATE_IF_RE.sub(replace_if, source)
    return TEMPLATE_KEY_RE.sub(lambda m: str(data.get(m.group(1), "<no value>")), rendered)


def check_template_syntax(rendered: str) -> Tuple[bool, str]:
    """Run node --check when node is available."""
    node = None
    for candidate in ("node", "/usr/local/bin/node", "/opt/homebrew/bin/node"):
        if os.path.sep in candidate:
            if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                node = candidate
                break
        else:
            import shutil

            node = shutil.which(candidate)
            if node:
                break
    if not node:
        return True, "node not found; skipped JavaScript syntax check"
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False, encoding="utf-8") as fh:
        fh.write(rendered)
        temp_path = fh.name
    try:
        result = subprocess.run([node, "--check", temp_path], capture_output=True, text=True)
        if result.returncode == 0:
            return True, "node --check passed"
        detail = (result.stderr or result.stdout).strip().splitlines()
        return False, detail[-1] if detail else "node --check failed"
    finally:
        try:
            os.unlink(temp_path)
        except OSError:
            pass


def validate_table(table: VersionTable) -> List[str]:
    """Schema checks shared with scripts/check_hook_template.py (subset)."""
    errors: List[str] = []
    data = table.data
    if "hookVerified" not in data:
        errors.append("missing hookVerified")
    elif not isinstance(data["hookVerified"], str) or data["hookVerified"].lower() not in ("true", "false"):
        errors.append("hookVerified must be the string \"true\"/\"false\"")
    for key in BOOLEAN_KEYS:
        if key in data:
            value = data[key]
            if isinstance(value, bool):
                continue
            if not isinstance(value, str) or value.lower() not in ("true", "false"):
                errors.append(f"{key} must be the string \"true\"/\"false\": {value!r}")
    for key, value in data.items():
        if isinstance(value, str) and value.startswith("0x"):
            if not HEX_RE.match(value):
                errors.append(f"{key} is not valid hexadecimal: {value!r}")
    offsets = [key for key in OFFSET_KEYS if key in data]
    if offsets and len(offsets) != len(OFFSET_KEYS):
        errors.append("messageContentOffset/messageCreatedOffset must be present as a pair")
    for key in SNS_BODY_RETURN_KEYS:
        if key in data:
            value = table.hex_value(key)
            if value is None or value % 4 != 0:
                errors.append(f"{key} must be a 4-byte-aligned return address")
    for prefix in SNS_PREFIXES:
        present = [prefix + suffix for suffix in SNS_SUFFIXES if prefix + suffix in data]
        if present and len(present) != len(SNS_SUFFIXES):
            missing = [prefix + suffix for suffix in SNS_SUFFIXES if prefix + suffix not in data]
            errors.append(f"{prefix} anchor group incomplete: missing {', '.join(missing)}")
    pat_present = [key for key in SEND_PAT_KEYS if key in data]
    if pat_present and len(pat_present) != len(SEND_PAT_KEYS):
        missing = [key for key in SEND_PAT_KEYS if key not in data]
        errors.append(f"sendPat address group incomplete: missing {', '.join(missing)}")
    if str(data.get("r3PatSend", "")).lower() == "true" and len(pat_present) != len(SEND_PAT_KEYS):
        errors.append("r3PatSend=true but sendPat address group is incomplete")
    return errors


def template_key_sets(source: str):
    """Return (all, required, optional) template keys, mirroring check_hook_template.py."""
    all_keys = set(TEMPLATE_KEY_RE.findall(source))
    all_keys.update(match[0] for match in TEMPLATE_IF_RE.findall(source))
    optional = set(SEND_PAT_KEYS)
    optional.update({"snsDbRead"})
    optional.update(OFFSET_KEYS)
    optional.update(SNS_BODY_RETURN_KEYS)
    optional.update(SNS_SWITCH_KEYS)
    optional.update(BRIDGE_ONLY_KEYS)
    optional.update({"snsSlot13BranchSNS", "snsSlot13BranchDefault"})
    for prefix in SNS_PREFIXES:
        for suffix in SNS_SUFFIXES:
            optional.add(prefix + suffix)
    return all_keys, all_keys - optional, all_keys & optional

"""Check every place a supported WeChat version must be registered."""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

SNS_PREFIXES = ["snsTimeline", "snsSync", "snsPost", "snsUserpage", "snsComment"]
SNS_SUFFIXES = ["Ctor", "Vtable", "Size", "ClosureVtable", "Decoder"]
SNS_BODY_RETURN_KEYS = ["snsTimelineBodyReturn", "snsSyncBodyReturn",
                       "snsPostBodyReturn", "snsCommentBodyReturn"]

PRIMARY_FILES = [
    "tools/manage_wechat.sh",
    "tools/install_gadget.sh",
    "scripts/run_bridge.sh",
    "scripts/build_app.sh",
    "scripts/package_release.sh",
    "app/Sources/WeChatBot/Services/WeChatAppDetection.swift",
]

UI_FILES = [
    "app/Packaging/zh-Hans.lproj/Localizable.strings",
    "app/Packaging/en.lproj/Localizable.strings",
]

DOC_FILES = [
    "README.md",
    "docs/architecture.md",
    "docs/install.md",
    "docs/releases/4.2.1.md",
]


@dataclass
class Check:
    file: str
    category: str
    ok: bool
    detail: str
    line: int = 0
    required: bool = True

    def to_dict(self) -> dict:
        return {
            "file": self.file,
            "category": self.category,
            "ok": self.ok,
            "detail": self.detail,
            "line": self.line,
            "required": self.required,
        }


def _read(root: str, relative: str) -> Optional[str]:
    path = os.path.join(root, relative)
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return None


def _first_line(text: str, needle: str) -> int:
    for index, line in enumerate(text.splitlines(), 1):
        if needle in line:
            return index
    return 0


def _parse_known_pairs(text: str) -> List[Tuple[str, str]]:
    match = re.search(r'KNOWN_VERSION_PAIRS="([^"]+)"', text)
    if not match:
        return []
    pairs = []
    for item in match.group(1).split():
        if ":" in item:
            version, build = item.split(":", 1)
            pairs.append((version.strip(), build.strip()))
    return pairs


def _parse_swift_pairs(text: str) -> List[Tuple[str, str]]:
    return re.findall(r'Pair\(version: "([0-9.]+)", build: "([0-9]+)"\)', text)


def scan(root: str, version: str, build: str, default_version: Optional[str] = None) -> dict:
    checks: List[Check] = []

    manage = _read(root, "tools/manage_wechat.sh") or ""
    install = _read(root, "tools/install_gadget.sh") or ""
    manage_pairs = _parse_known_pairs(manage)
    install_pairs = _parse_known_pairs(install)
    swift = _read(root, "app/Sources/WeChatBot/Services/WeChatAppDetection.swift") or ""
    swift_pairs = _parse_swift_pairs(swift)

    target = (version, build)
    checks.append(Check(
        "tools/manage_wechat.sh", "known_pairs", target in manage_pairs,
        f"KNOWN_VERSION_PAIRS {'contains' if target in manage_pairs else 'missing'} {version}:{build}",
        _first_line(manage, version) if version in manage else 0,
    ))
    checks.append(Check(
        "tools/install_gadget.sh", "known_pairs", target in install_pairs,
        f"KNOWN_VERSION_PAIRS {'contains' if target in install_pairs else 'missing'} {version}:{build}",
        _first_line(install, version) if version in install else 0,
    ))
    checks.append(Check(
        "app/Sources/WeChatBot/Services/WeChatAppDetection.swift", "known_pairs", target in swift_pairs,
        f"knownPairs {'contains' if target in swift_pairs else 'missing'} {version}:{build}",
        _first_line(swift, version) if version in swift else 0,
    ))
    checks.append(Check(
        "tools/manage_wechat.sh", "known_pairs_sync", manage_pairs == install_pairs == swift_pairs,
        "shell KNOWN_VERSION_PAIRS and Swift knownPairs must match exactly",
    ))
    checks.append(Check(
        "hook/versions/%s_mac.json" % version.replace(".", "_"), "version_table",
        os.path.isfile(os.path.join(root, "hook", "versions", "%s_mac.json" % version.replace(".", "_"))),
        "version JSON must exist before the version can be registered",
    ))

    # Defaults intentionally stay on the last *verified* version until the new
    # table is proven on a real device.
    defaults = {
        "tools/manage_wechat.sh": re.search(r'WECHAT_SUPPORTED_VERSION:-([0-9.]+)', manage),
        "tools/install_gadget.sh": re.search(r'WECHAT_SUPPORTED_VERSION:-([0-9.]+)', install),
        "scripts/build_app.sh": re.search(r'DEFAULT_HOOK_VERSION="([0-9.]+)"', _read(root, "scripts/build_app.sh") or ""),
        "scripts/run_bridge.sh": re.search(r'hook/versions/([0-9_]+)_mac\.json', _read(root, "scripts/run_bridge.sh") or ""),
        "scripts/package_release.sh": re.search(r'hook/versions/([0-9_]+)_mac\.json', _read(root, "scripts/package_release.sh") or ""),
    }
    expected_default = default_version or defaults["tools/manage_wechat.sh"].group(1) if defaults["tools/manage_wechat.sh"] else None
    for relative, match in defaults.items():
        value = match.group(1) if match else None
        if value:
            value = value.replace("_", ".")
        checks.append(Check(
            relative, "default",
            value == expected_default if expected_default else False,
            f"default hook version is {value or '?'} (expected {expected_default or '?'})",
            _first_line(_read(root, relative) or "", expected_default or "") if expected_default else 0,
            required=False,
        ))

    # UI strings and docs must mention the new version somewhere.
    for relative in UI_FILES:
        text = _read(root, relative) or ""
        count = text.count(version)
        checks.append(Check(relative, "ui", count > 0,
                            f"version string appears {count} time(s)", _first_line(text, version)))
    for relative in DOC_FILES:
        if not os.path.isfile(os.path.join(root, relative)):
            checks.append(Check(relative, "docs", False, "file missing", 0, required=False))
            continue
        text = _read(root, relative) or ""
        checks.append(Check(relative, "docs", version in text,
                            f"version string {'present' if version in text else 'missing'}",
                            _first_line(text, version), required=False))

    release_note = "docs/releases/%s.md" % version
    checks.append(Check(release_note, "release_notes",
                        os.path.isfile(os.path.join(root, release_note)),
                        "release note for the new version", 0, required=False))

    # 朋友圈完整读写是版本注册的硬性要求：新版本不能只适配聊天链路。
    # 完全没有 SNS 锚点的历史版本（4.2.0.5 / 4.2.0.9）只做提示，不阻断注册。
    version_json = "hook/versions/%s_mac.json" % version.replace(".", "_")
    table_path = os.path.join(root, version_json)
    table_available = os.path.isfile(table_path)
    try:
        with open(table_path, encoding="utf-8") as fh:
            table = json.load(fh)
    except (OSError, ValueError):
        table = {}
    has_sns = any(prefix + suffix in table for prefix in SNS_PREFIXES for suffix in SNS_SUFFIXES)
    missing_sns: List[str] = []
    if table_available:
        if has_sns:
            for prefix in SNS_PREFIXES:
                for suffix in SNS_SUFFIXES:
                    key = prefix + suffix
                    if key not in table:
                        missing_sns.append(key)
            for key in SNS_BODY_RETURN_KEYS:
                if key not in table:
                    missing_sns.append(key)
    else:
        missing_sns = ["<missing version table>"]
    if not table_available:
        sns_detail = "缺少版本 JSON：%s" % ", ".join(missing_sns)
        sns_ok = False
    elif not has_sns:
        sns_detail = "该版本没有 SNS 锚点（历史版本可接受）；新版本必须完成朋友圈完整读写适配"
        sns_ok = True
    elif missing_sns:
        sns_detail = ("朋友圈读写锚点缺失：%s（新版本必须完成完整读写适配，"
                      "见 docs/hook-porting.md §2.7/§5.1）" % ", ".join(missing_sns))
        sns_ok = False
    else:
        sns_detail = "朋友圈完整读写锚点齐全"
        sns_ok = True
    checks.append(Check(version_json, "sns_read_write", sns_ok, sns_detail,
                        required=table_available))
    suppressed_match = re.search(
        r"snsWriteSuppressedVersions\s*:\s*Set<String>\s*=\s*\[(.*?)\]", swift, re.S)
    suppressed = set(re.findall(r'"([0-9]+(?:\.[0-9]+)+)"', suppressed_match.group(1))) \
        if suppressed_match else set()
    if not suppressed_match:
        sns_gate_ok = False
        sns_gate_detail = ("无法解析 App 的 snsWriteSuppressedVersions（检查器需要同步更新）")
    elif version in suppressed:
        sns_gate_ok = False
        sns_gate_detail = "版本仍在 snsWriteSuppressedVersions 中；完成 §5.1 真机读写验证后再移出"
    else:
        sns_gate_ok = True
        sns_gate_detail = "版本未在 snsWriteSuppressedVersions（App 强制只读名单）中"
    checks.append(Check(
        "app/Sources/WeChatBot/Services/WeChatAppDetection.swift", "sns_read_write",
        sns_gate_ok, sns_gate_detail, required=has_sns,
    ))

    return {
        "version": version,
        "build": build,
        "expected_default": expected_default,
        "checks": [check.to_dict() for check in checks],
        "ok": all(check.ok for check in checks if check.required),
    }


def render_text(result: dict) -> str:
    lines = [f"微信 {result['version']} ({result['build']}) 注册检查："
             f"{'✅ 通过' if result['ok'] else '❌ 有缺失'}"]
    lines.append(f"当前默认版本：{result.get('expected_default') or '?'}")
    for item in result["checks"]:
        mark = "✅" if item["ok"] else ("❌" if item["required"] else "…")
        location = f":{item['line']}" if item.get("line") else ""
        lines.append(f"  {mark} [{item['category']}] {item['file']}{location} — {item['detail']}")
    return "\n".join(lines)

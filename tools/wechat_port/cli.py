"""Command line interface for the WeChat hook porting toolkit."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# Allow both "python -m wechat_port" and "python tools/wechat_port/cli.py".
if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from wechat_port.image import Image
    from wechat_port.macho import MachOImage
    from wechat_port.registry import render_text as render_registration
    from wechat_port.registry import scan as scan_registration
    from wechat_port.report import build_result, build_markdown, write_report
    from wechat_port.resolver import ACCEPTABLE, HIGH, MANUAL, REVIEW, UNRESOLVED, Resolver
    from wechat_port.table import (
        VersionTable,
        check_template_syntax,
        diff_tables,
        render_template,
        SAFETY_SWITCHES,
        template_key_sets,
        validate_table,
    )
else:
    from .image import Image
    from .macho import MachOImage
    from .registry import render_text as render_registration
    from .registry import scan as scan_registration
    from .report import build_result, build_markdown, write_report
    from .resolver import ACCEPTABLE, HIGH, MANUAL, REVIEW, UNRESOLVED, Resolver
    from .table import (
        VersionTable,
        SAFETY_SWITCHES,
        check_template_syntax,
        diff_tables,
        render_template,
        template_key_sets,
        validate_table,
    )

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SCRIPT = REPO_ROOT / "hook" / "script.js"
TEMPLATE_KEY_RE = re.compile(r"\{\{\s*\.([A-Za-z0-9_]+)\s*\}\}")
TEMPLATE_IF_RE = re.compile(r"\{\{\s*if\s+\.([A-Za-z0-9_]+)\s*\}\}")


def eprint(*args) -> None:
    print(*args, file=sys.stderr)


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_slice(image: MachOImage) -> str:
    view = memoryview(image.raw)[image._slice_offset : image._slice_offset + image._slice_size]
    return hashlib.sha256(view).hexdigest()


def known_version_pairs() -> Dict[str, str]:
    """Map CFBundleVersion -> full marketing version from the repo's source of truth."""
    manage = REPO_ROOT / "tools" / "manage_wechat.sh"
    try:
        text = manage.read_text(encoding="utf-8")
    except OSError:
        return {}
    match = re.search(r'KNOWN_VERSION_PAIRS="([^"]+)"', text)
    if not match:
        return {}
    result = {}
    for item in match.group(1).split():
        if ":" in item:
            version, build = item.split(":", 1)
            result[build.strip()] = version.strip()
    return result


def app_metadata(app_path: str) -> dict:
    path = Path(app_path)
    if path.is_dir() and path.suffix == ".app":
        info_path = path / "Contents" / "Info.plist"
        dylib_path = path / "Contents" / "Resources" / "wechat.dylib"
        version = build = None
        if info_path.is_file():
            with open(info_path, "rb") as fh:
                info = plistlib.load(fh)
            version = str(info.get("CFBundleShortVersionString") or "")
            build = str(info.get("CFBundleVersion") or "")
        mapped = known_version_pairs().get(build or "")
        version_source = "Info.plist"
        if mapped:
            version = mapped
            version_source = "KNOWN_VERSION_PAIRS(build)"
        return {"app": str(path), "dylib": str(dylib_path), "version": version,
                "build": build, "version_source": version_source}
    return {"dylib": str(path), "version": None, "build": None, "version_source": None}


def inventory(path: str) -> dict:
    meta = app_metadata(path)
    dylib = meta["dylib"]
    if not os.path.isfile(dylib):
        raise SystemExit(f"找不到微信主库：{dylib}")
    image = MachOImage(dylib)
    try:
        result = {
            "input": os.path.abspath(path),
            "app": meta.get("app"),
            "dylib": os.path.abspath(dylib),
            "version": meta.get("version"),
            "build": meta.get("build"),
            "arch": image.arch,
            "uuid": image.uuid,
            "dylib_version": image.dylib_version,
            "sha256": sha256_slice(image),
            "size": image._slice_size,
            "text_start": f"0x{image.text_start:x}",
            "text_end": f"0x{image.text_end:x}",
            "function_starts": len(image.starts),
            "stub_imports": len(image._stub_imports),
            "bind_slots": len(image._bind_slots),
            "fat_arches": [
                {"cputype": hex(arch.cputype), "offset": arch.offset, "size": arch.size}
                for arch in image.fat_arches
            ],
        }
    finally:
        image.close()
    return result


def prepare(workdir: str, path: str, force: bool = False) -> dict:
    os.makedirs(workdir, exist_ok=True)
    meta = app_metadata(path)
    dylib = meta["dylib"]
    if not os.path.isfile(dylib):
        raise SystemExit(f"找不到微信主库：{dylib}")
    target = os.path.join(workdir, "wechat-arm64.dylib")
    if os.path.abspath(dylib) == os.path.abspath(target):
        with open(target + ".json", encoding="utf-8") as fh:
            slice_meta = json.load(fh)
    elif force or not os.path.isfile(target):
        slice_meta = MachOImage.extract_arch(dylib, target, "arm64")
    else:
        with open(target + ".json", encoding="utf-8") as fh:
            slice_meta = json.load(fh)
    info = inventory(target)
    info.update({
        "source_app": meta.get("app"),
        "source_version": meta.get("version"),
        "source_build": meta.get("build"),
        "slice": slice_meta,
    })
    with open(os.path.join(workdir, "inventory.json"), "w", encoding="utf-8") as fh:
        json.dump(info, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    return info


def template_keys(script_path: Path) -> Tuple[set, set]:
    source = script_path.read_text(encoding="utf-8")
    _, required, _optional = template_key_sets(source)
    return required, _optional


def manual_keys(baseline: VersionTable) -> Dict[str, str]:
    notes = {}
    for key in ("messageContentOffset", "messageCreatedOffset"):
        if key in baseline.data:
            notes[key] = "消息对象字段偏移；地址映射无法证明。需要对 4.2.1.3/新版本消息对象做布局探针或真机验证。"
    if "voiceOpcode" in baseline.data:
        notes["voiceOpcode"] = "语音 CGI opcode；需从新版本语音任务快照或反汇编确认。"
    for key in ("structVer", "req2bufLayout", "messageLayout"):
        if key in baseline.data:
            notes[key] = "结构布局开关；只有新版本结构发生布局变化时才改。"
    return notes


def resolve_and_report(args) -> int:
    workdir = os.path.abspath(args.workdir)
    baseline = VersionTable.load(args.baseline)
    info = prepare(workdir, args.app, force=args.force)
    version = args.version or info.get("source_version") or ""
    build = args.build or info.get("source_build") or ""
    if not version:
        raise SystemExit("无法从输入推断微信版本；请用 --version 指定完整版本（例如 4.2.1.5）。")
    if not args.version:
        known = known_version_pairs()
        if build not in known and str(version).count(".") < 3:
            raise SystemExit(
                f"build {build or '?'} 不在 KNOWN_VERSION_PAIRS 中，Info.plist 只给出营销版本 {version}；"
                "请用 --version 指定完整补丁版本（例如 --version 4.2.1.5）。"
            )
    target = {
        "path": os.path.join(workdir, "wechat-arm64.dylib"),
        "version": version,
        "build": build,
        "sha256": info.get("sha256"),
        "uuid": info.get("uuid"),
        "baseline_binary": os.path.abspath(args.old_binary) if getattr(args, "old_binary", None) else None,
    }

    eprint(f"[wxport] 基线 {baseline.path}")
    eprint(f"[wxport] 目标 {version or '?'} ({build or '?'}) {target['path']}")
    old_binary = getattr(args, "old_binary", None)
    if old_binary:
        eprint(f"[wxport] 旧二进制 {old_binary}")

    if old_binary:
        old_image = Image(old_binary)
    else:
        old_image = None
        eprint("[wxport] 未提供 --old-binary；仅能做目标表自身的结构检查，无法计算映射。")
        return 3

    new_image = Image(target["path"])
    try:
        started = time.time()
        resolver = Resolver(old_image, new_image, baseline)
        results = resolver.resolve_all()
        elapsed = time.time() - started
        eprint(f"[wxport] 映射完成，用时 {elapsed:.1f}s")
        candidate = resolver.candidate_table()
        candidate_path = os.path.join(workdir, "candidate.json")
        candidate.write(candidate_path)

        script_path = Path(args.script)
        render_ok = True
        render_detail = "模板不存在，已跳过"
        if script_path.is_file():
            rendered = render_template(script_path.read_text(encoding="utf-8"), candidate)
            render_ok, render_detail = check_template_syntax(rendered)
            rendered_path = os.path.join(workdir, "rendered.js")
            with open(rendered_path, "w", encoding="utf-8") as fh:
                fh.write(rendered)
        required_keys, _optional = template_keys(script_path) if script_path.is_file() else (set(), set())
        missing_keys = sorted(key for key in required_keys if key not in candidate.data)
        schema_errors = validate_table(candidate)
        if missing_keys:
            schema_errors.append(f"候选表缺少模板键：{', '.join(missing_keys)}")

        registration = None
        if getattr(args, "registration", False) and version:
            registration = scan_registration(str(REPO_ROOT), version, build)
            print(render_registration(registration))

        result = build_result(
            baseline=baseline,
            candidate=candidate,
            target=target,
            results=results,
            render_ok=render_ok and not missing_keys,
            render_detail=(render_detail if not missing_keys else "缺少模板键：" + ", ".join(missing_keys)),
            schema_errors=schema_errors,
            registration=registration,
            manual_keys=manual_keys(baseline),
            workdir=workdir,
        )
        write_report(result, os.path.join(workdir, "REPORT.md"), os.path.join(workdir, "verification.json"))
        print(build_markdown(result).split("## 6.")[0].rstrip())
        print()
        print(f"候选表：{candidate_path}")
        print(f"报告：{os.path.join(workdir, 'REPORT.md')}")
        print(f"验证 JSON：{os.path.join(workdir, 'verification.json')}")

        blocking = result["summary"]["total"] - result["summary"]["acceptable"]
        if not render_ok or missing_keys or schema_errors:
            return 4
        return 0 if blocking == 0 else 2
    finally:
        new_image.close()
        old_image.close()


def locate_dylib_in_zip(zip_path: str) -> Tuple[zipfile.ZipFile, str]:
    archive = zipfile.ZipFile(zip_path)
    matches = [name for name in archive.namelist()
               if name.endswith("Contents/Resources/wechat.dylib")]
    if not matches:
        archive.close()
        raise SystemExit(f"{zip_path} 里找不到 WeChat.app/Contents/Resources/wechat.dylib")
    return archive, matches[0]


def command_slice(args) -> int:
    source = args.source
    out = args.out
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    if zipfile.is_zipfile(source):
        archive, member = locate_dylib_in_zip(source)
        with tempfile.TemporaryDirectory(prefix="wxport-slice-") as temp:
            archive.extract(member, temp)
            archive.close()
            dylib = os.path.join(temp, member)
            meta = MachOImage.extract_arch(dylib, out, args.arch)
    else:
        dylib = source
        if os.path.isdir(source) and source.endswith(".app"):
            dylib = os.path.join(source, "Contents", "Resources", "wechat.dylib")
        if not os.path.isfile(dylib):
            raise SystemExit(f"找不到主库：{dylib}")
        meta = MachOImage.extract_arch(dylib, out, args.arch)
    print(json.dumps(meta, ensure_ascii=False, indent=2))
    print(f"已写入 {out}（{args.arch} 切片）")
    return 0

def command_inventory(args) -> int:
    data = inventory(args.path)
    print(json.dumps(data, ensure_ascii=False, indent=2))
    return 0


def command_prepare(args) -> int:
    data = prepare(args.workdir, args.app, force=args.force)
    print(json.dumps(data, ensure_ascii=False, indent=2))
    return 0


def command_adapt(args) -> int:
    return resolve_and_report(args)


def command_diff(args) -> int:
    old = VersionTable.load(args.old)
    new = VersionTable.load(args.new)
    rows = diff_tables(old, new)
    if args.json:
        print(json.dumps(rows, ensure_ascii=False, indent=2))
        return 0
    print(f"{'键':38s} {'旧值':>14s} {'新值':>14s}  变化")
    for row in rows:
        print(f"{row['key']:38s} {str(row['old']):>14s} {str(row['new']):>14s}  {row['change']}")
    return 0


def command_render(args) -> int:
    table = VersionTable.load(args.table)
    source = Path(args.script).read_text(encoding="utf-8")
    rendered = render_template(source, table)
    if args.out:
        Path(args.out).write_text(rendered, encoding="utf-8")
    ok, detail = check_template_syntax(rendered)
    print(("OK: " if ok else "FAIL: ") + detail)
    return 0 if ok else 1


def command_verify(args) -> int:
    baseline = VersionTable.load(args.baseline)
    candidate = VersionTable.load(args.candidate)
    schema_errors = validate_table(candidate)
    required_keys, _optional = template_keys(Path(args.script))
    missing = sorted(key for key in required_keys if key not in candidate.data)
    if missing:
        schema_errors.append(f"候选表缺少模板键：{', '.join(missing)}")
    render_ok = True
    render_detail = "模板不存在，已跳过"
    if Path(args.script).is_file():
        rendered = render_template(Path(args.script).read_text(encoding="utf-8"), candidate)
        render_ok, render_detail = check_template_syntax(rendered)
    # Basic address sanity: every candidate address must land in a section.
    image = Image(args.binary)
    problems: List[str] = []
    try:
        for key in baseline.address_keys():
            value = candidate.hex_value(key)
            if value is None:
                continue
            if image.macho.section_at(value) is None:
                problems.append(f"{key}={value:#x} 不在任何 section 中")
            if key.endswith("BodyReturn") and value % 4 != 0:
                problems.append(f"{key}={value:#x} 不是 4 字节对齐")
    finally:
        image.close()
    if problems:
        schema_errors.extend(problems)
    ok = render_ok and not schema_errors
    print(("✅ 通过" if ok else "❌ 失败"))
    print(render_detail)
    for error in schema_errors:
        print("  - " + error)
    return 0 if ok else 1


def command_backtest(args) -> int:
    baseline = VersionTable.load(args.from_table)
    truth = VersionTable.load(args.to_table)
    old = Image(args.from_binary)
    new = Image(args.to_binary)
    try:
        started = time.time()
        resolver = Resolver(old, new, baseline)
        results = resolver.resolve_all()
        elapsed = time.time() - started
    finally:
        old.close()
        new.close()
    matched = 0
    wrong = []
    missing = []
    for key, result in results.items():
        expected = truth.hex_value(key)
        if expected is None:
            continue
        if result.new is None:
            missing.append(key)
        elif result.new == expected:
            matched += 1
        else:
            wrong.append((key, result.new, expected, result.status, result.method))
    total = matched + len(wrong) + len(missing)
    accuracy = matched / total if total else 0.0
    print(f"目标表 {args.to_table}")
    print(f"共 {total} 个地址键：匹配 {matched}，错误 {len(wrong)}，缺失 {len(missing)}，用时 {elapsed:.1f}s")
    print(f"准确率：{accuracy:.1%}")
    if wrong:
        print("错误：")
        for key, got, expected, status, method in wrong:
            print(f"  {key:32s} got={got:#x} expected={expected:#x} [{status}/{method}]")
    if args.json:
        print(json.dumps({
            "from": args.from_table, "to": args.to_table,
            "matched": matched, "wrong": len(wrong), "missing": len(missing),
            "accuracy": accuracy, "elapsed": elapsed,
            "details": [{"key": k, "got": f"0x{g:x}", "expected": f"0x{e:x}",
                         "status": s, "method": m} for k, g, e, s, m in wrong],
        }, ensure_ascii=False, indent=2))
    threshold = args.min_accuracy
    return 0 if accuracy >= threshold and not wrong else 1


def command_registration(args) -> int:
    result = scan_registration(str(REPO_ROOT), args.version, args.build,
                               default_version=args.default_version)
    print(render_registration(result))
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result["ok"] else 1


def command_explain(args) -> int:
    verification_path = os.path.join(args.workdir, "verification.json")
    if not os.path.isfile(verification_path):
        raise SystemExit(f"缺少 {verification_path}，请先运行 adapt")
    with open(verification_path, encoding="utf-8") as fh:
        report = json.load(fh)
    item = report.get("results", {}).get(args.key)
    if item is None:
        raise SystemExit(f"验证报告里没有 {args.key}")
    print(json.dumps(item, ensure_ascii=False, indent=2))
    if args.disasm:
        target = report.get("target", {})
        old_binary = target.get("baseline_binary")
        new_binary = target.get("path")
        old_value = item.get("old")
        new_value = item.get("new")
        if old_binary and old_value:
            print("\n--- old ---")
            print(disassemble(old_binary, int(old_value, 16), args.instructions))
        if new_binary and new_value:
            print("\n--- new ---")
            print(disassemble(new_binary, int(new_value, 16), args.instructions))
    return 0


def find_llvm_objdump() -> Optional[str]:
    candidates = [
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/llvm-objdump",
    ]
    for candidate in candidates:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    found = shutil.which("llvm-objdump")
    if found:
        return found
    try:
        result = subprocess.run(["xcrun", "--find", "llvm-objdump"], capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout.strip()
    except OSError:
        pass
    return None


def disassemble(binary: str, address: int, instructions: int = 16) -> str:
    tool = find_llvm_objdump()
    if not tool:
        return "(未找到 llvm-objdump；安装 Xcode Command Line Tools 后可查看反汇编)"
    start = max(0, address - 0x20)
    stop = address + instructions * 4
    result = subprocess.run([tool, "--arch=arm64", "--disassemble",
                             f"--start-address={start:#x}", f"--stop-address={stop:#x}", binary],
                            capture_output=True, text=True)
    return (result.stdout or result.stderr).strip()


def command_promote(args) -> int:
    verification_path = os.path.join(args.workdir, "verification.json")
    if not os.path.isfile(verification_path):
        raise SystemExit(f"缺少 {verification_path}，请先运行 adapt")
    with open(verification_path, encoding="utf-8") as fh:
        report = json.load(fh)
    summary = report.get("summary", {})
    blocking = (summary.get("review", 0) + summary.get("unresolved", 0)
                + summary.get("medium", 0))
    if blocking:
        eprint(f"❌ 仍有 {blocking} 个 medium/review/unresolved 键，拒绝 promotion；先处理 REPORT.md 第 2 节。")
        return 2
    if not report.get("render", {}).get("ok"):
        eprint("❌ 模板渲染未通过，拒绝 promotion。")
        return 2
    candidate_path = os.path.join(args.workdir, "candidate.json")
    if not os.path.isfile(candidate_path):
        raise SystemExit(f"缺少 {candidate_path}")
    candidate = VersionTable.load(candidate_path)
    data = dict(candidate.data)
    data["hookVerified"] = "false"
    for key, value in SAFETY_SWITCHES.items():
        if key in data:
            data[key] = value
    table = VersionTable(path=candidate_path, data=data, order=list(data.keys()))
    if os.path.exists(args.out) and not args.force:
        eprint(f"❌ {args.out} 已存在；确认要覆盖时加 --force")
        return 2
    table.write(args.out)
    print(f"✅ 已写入 {args.out}（hookVerified=false，发送/朋友圈写开关关闭）")
    print("下一步：")
    print("  1. wxport registration --version <version> --build <build>")
    print("  2. bash scripts/check.sh --docs")
    print("  3. 真机验证矩阵（docs/hook-porting.md 第 5 节）")
    print('  4. 通过后才把 hookVerified 改为 "true"')
    return 0

def command_doctor(args) -> int:
    checks = []
    checks.append(("python", sys.version.split()[0], True))
    try:
        import numpy
        checks.append(("numpy", numpy.__version__, True))
    except Exception:
        checks.append(("numpy", "未安装（速度较慢，但可运行）", False))
    checks.append(("node", shutil.which("node") or "未找到", bool(shutil.which("node"))))
    checks.append(("llvm-objdump", find_llvm_objdump() or "未找到", bool(find_llvm_objdump())))
    checks.append(("hook/script.js", str(DEFAULT_SCRIPT), DEFAULT_SCRIPT.is_file()))
    checks.append(("hook/versions", str(REPO_ROOT / "hook" / "versions"), (REPO_ROOT / "hook" / "versions").is_dir()))
    for name, detail, ok in checks:
        print(f"{'✅' if ok else '…'} {name}: {detail}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="wxport",
        description="微信 Hook 版本移植工具：清点、重映射、结构验证与报告。",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    inventory_parser = subparsers.add_parser("inventory", help="读取微信/主库元数据")
    inventory_parser.add_argument("path", help="WeChat.app 或 wechat.dylib")
    inventory_parser.set_defaults(func=command_inventory)

    slice_parser = subparsers.add_parser("slice", help="从 App / dylib / 官方备份 zip 提取 arm64 切片")
    slice_parser.add_argument("--source", required=True, help="WeChat.app、wechat.dylib 或官方备份 zip")
    slice_parser.add_argument("--out", required=True)
    slice_parser.add_argument("--arch", default="arm64")
    slice_parser.set_defaults(func=command_slice)

    prepare_parser = subparsers.add_parser("prepare", help="提取 arm64 切片并写 inventory")
    prepare_parser.add_argument("--app", required=True)
    prepare_parser.add_argument("--workdir", required=True)
    prepare_parser.add_argument("--force", action="store_true")
    prepare_parser.set_defaults(func=command_prepare)

    adapt_parser = subparsers.add_parser("adapt", help="完整适配：映射、验证、生成报告")
    adapt_parser.add_argument("--app", required=True, help="新版 WeChat.app 或主库")
    adapt_parser.add_argument("--baseline", required=True, help="上一版 hook/versions/*.json")
    adapt_parser.add_argument("--old-binary", required=True, help="上一版 arm64 主库切片")
    adapt_parser.add_argument("--workdir", required=True)
    adapt_parser.add_argument("--version")
    adapt_parser.add_argument("--build")
    adapt_parser.add_argument("--script", default=str(DEFAULT_SCRIPT))
    adapt_parser.add_argument("--force", action="store_true")
    adapt_parser.add_argument("--registration", action="store_true", help="同时检查版本注册点")
    adapt_parser.set_defaults(func=command_adapt)

    diff_parser = subparsers.add_parser("diff", help="比较两个版本表")
    diff_parser.add_argument("old")
    diff_parser.add_argument("new")
    diff_parser.add_argument("--json", action="store_true")
    diff_parser.set_defaults(func=command_diff)

    render_parser = subparsers.add_parser("render", help="渲染 hook 模板并做 node 语法检查")
    render_parser.add_argument("table")
    render_parser.add_argument("--script", default=str(DEFAULT_SCRIPT))
    render_parser.add_argument("--out")
    render_parser.set_defaults(func=command_render)

    verify_parser = subparsers.add_parser("verify", help="校验已有候选表")
    verify_parser.add_argument("--baseline", required=True)
    verify_parser.add_argument("--candidate", required=True)
    verify_parser.add_argument("--binary", required=True)
    verify_parser.add_argument("--script", default=str(DEFAULT_SCRIPT))
    verify_parser.set_defaults(func=command_verify)

    backtest_parser = subparsers.add_parser("backtest", help="用已知版本回测映射准确率")
    backtest_parser.add_argument("--from-table", required=True)
    backtest_parser.add_argument("--to-table", required=True)
    backtest_parser.add_argument("--from-binary", required=True)
    backtest_parser.add_argument("--to-binary", required=True)
    backtest_parser.add_argument("--min-accuracy", type=float, default=0.9)
    backtest_parser.add_argument("--json", action="store_true")
    backtest_parser.set_defaults(func=command_backtest)

    registration_parser = subparsers.add_parser("registration", help="检查新版本需要更新的所有位置")
    registration_parser.add_argument("--version", required=True)
    registration_parser.add_argument("--build", required=True)
    registration_parser.add_argument("--default-version")
    registration_parser.add_argument("--json", action="store_true")
    registration_parser.set_defaults(func=command_registration)

    explain_parser = subparsers.add_parser("explain", help="查看某个键的证据与反汇编")
    explain_parser.add_argument("--workdir", required=True)
    explain_parser.add_argument("--key", required=True)
    explain_parser.add_argument("--instructions", type=int, default=16)
    explain_parser.add_argument("--disasm", action="store_true")
    explain_parser.set_defaults(func=command_explain)

    promote_parser = subparsers.add_parser("promote", help="把已全部可接受的候选表写入 hook/versions")
    promote_parser.add_argument("--workdir", required=True)
    promote_parser.add_argument("--out", required=True)
    promote_parser.add_argument("--force", action="store_true")
    promote_parser.set_defaults(func=command_promote)

    doctor_parser = subparsers.add_parser("doctor", help="检查本机工具链")
    doctor_parser.set_defaults(func=command_doctor)

    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())

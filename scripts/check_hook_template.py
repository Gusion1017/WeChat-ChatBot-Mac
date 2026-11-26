#!/usr/bin/env python3
"""校验 hook/script.js 模板键与 hook/versions/*.json、各脚本默认微信版本一致。

背景：script.js 由 bridge 用 Go text/template 渲染，缺键会变成字符串 "<no value>"。
地址键缺失会让 baseAddr.add(<no value>) 直接语法错误；布尔/字符串开关缺失则会静默
走默认分支。历史上 4.2.1.3 的 SNS BodyReturn 就被写成了 vtable 槽位而不是调用点返回
地址，直到人工审计才发现。本检查把这类"版本表漂移"前移到 CI/本地门禁。

用法：
    python3 scripts/check_hook_template.py

退出码：0 = 通过；1 = 发现不一致。
"""

from __future__ import annotations

import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

KEY_RE = re.compile(r"\{\{\s*\.([A-Za-z0-9_]+)\s*\}\}")
IF_RE = re.compile(r"\{\{\s*if\s+\.([A-Za-z0-9_]+)\s*\}\}(.*?)\{\{\s*end\s*\}\}", re.S)
ACTION_RE = re.compile(r"\{\{(.*?)\}\}", re.S)

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
DEAD_OPTIONAL_KEYS = {"snsDbRead"}
# 只被 bridge 读取、不参与 JS 模板的 SNS 键（App 运行期覆盖也会写它们）。
BRIDGE_ONLY_KEYS = {"snsPostDailyLimit", "snsPostMinIntervalMs", "snsReadMode", "snsWrite"}
OPTIONAL_PAIR = ["snsSlot13BranchSNS", "snsSlot13BranchDefault"]
MESSAGE_OFFSET_KEYS = ["messageContentOffset", "messageCreatedOffset"]
SNS_PREFIXES = ["snsTimeline", "snsSync", "snsPost", "snsUserpage", "snsComment"]
SNS_SUFFIXES = ["Ctor", "Vtable", "Size", "ClosureVtable", "Decoder"]
SNS_BODY_RETURN_KEYS = ["snsTimelineBodyReturn", "snsSyncBodyReturn", "snsPostBodyReturn",
                       "snsCommentBodyReturn"]
# 读取主动刷新/发布模板必需的三件套；snsCommentBodyReturn 是 4.2.1.3 起才有的可选键。
SNS_CORE_BODY_RETURN_KEYS = ["snsTimelineBodyReturn", "snsSyncBodyReturn", "snsPostBodyReturn"]
SNS_SWITCH_KEYS = ["snsEnable", "snsProbe"]

ERRORS = []


def fail(message):
    ERRORS.append(message)


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def load_json(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def parse_hex(value):
    if not isinstance(value, str) or not value.startswith("0x"):
        return None
    try:
        return int(value, 16)
    except ValueError:
        return None


def is_boolish(value):
    return isinstance(value, bool) or (isinstance(value, str) and value.lower() in ("true", "false"))


def default_version_from(text, pattern):
    match = re.search(pattern, text)
    return match.group(1) if match else ""


def git_versions(pairs_text):
    result = []
    for pair in pairs_text.split():
        if ":" in pair:
            version, build = pair.split(":", 1)
            result.append((version.strip(), build.strip()))
    return result


def check_template_keys():
    script_path = os.path.join(ROOT, "hook", "script.js")
    source = read(script_path)
    refs = set(KEY_RE.findall(source))
    conditions = set()
    supported_actions = 0
    for raw in ACTION_RE.findall(source):
        action = raw.strip()
        if re.fullmatch(r"\.[A-Za-z0-9_]+", action):
            supported_actions += 1
            continue
        if re.fullmatch(r"if\s+\.[A-Za-z0-9_]+", action):
            conditions.add(action.split(".", 1)[1].strip())
            supported_actions += 1
            continue
        if action == "end":
            supported_actions += 1
            continue
        fail("hook/script.js 含未识别的模板动作 {{%s}}；请同步更新 check_hook_template.py" % action)
    if len(ACTION_RE.findall(source)) != supported_actions:
        fail("hook/script.js 模板动作统计不一致（正则未覆盖全部动作）")
    if len(re.findall(r"\{\{\s*if\s+\.", source)) != len(re.findall(r"\{\{\s*end\s*\}\}", source)):
        fail("hook/script.js 的 {{if}} 与 {{end}} 数量不匹配")
    return source, sorted(refs | conditions)


def classify_keys(keys):
    # 只出现在部分版本 JSON 的可选键：SNS 任务锚点、消息偏移、SNS bodyReturn、探针开关。
    optional = set(SEND_PAT_KEYS) | set(DEAD_OPTIONAL_KEYS) | set(OPTIONAL_PAIR)
    optional |= set(MESSAGE_OFFSET_KEYS) | set(SNS_BODY_RETURN_KEYS) | set(SNS_SWITCH_KEYS)
    optional |= BRIDGE_ONLY_KEYS
    for prefix in SNS_PREFIXES:
        for suffix in SNS_SUFFIXES:
            optional.add(prefix + suffix)
    required = [key for key in keys if key not in optional]
    return required, optional


def check_version_json(path, data, required, optional, known):
    name = os.path.basename(path)
    missing = [key for key in required if key not in data]
    if missing:
        fail("%s 缺少必需模板键：%s（会渲染成 <no value>）" % (name, ", ".join(missing)))

    # 未知键不直接报错（可能给 bridge 用），但模板键之外的键要确认不是拼错。
    for key in data:
        if key.startswith("sns") and key not in optional:
            fail("%s 含未使用的 SNS 键 %s（模板未引用，可能是拼写错误）" % (name, key))

    # SNS 任务锚点按任务成组出现，避免只补一半地址导致发送时崩。
    for prefix in SNS_PREFIXES:
        present = [prefix + suffix for suffix in SNS_SUFFIXES if prefix + suffix in data]
        if present and len(present) != len(SNS_SUFFIXES):
            absent = [prefix + suffix for suffix in SNS_SUFFIXES if prefix + suffix not in data]
            fail("%s 的 SNS 锚点不完整（%s 缺 %s）" % (name, prefix, ", ".join(absent)))

    # sendpat 实验路径：要么整组不配（脚本返回 fail，安全），要么整组齐全。
    pat_present = [key for key in SEND_PAT_KEYS if key in data]
    if pat_present and len(pat_present) != len(SEND_PAT_KEYS):
        absent = [key for key in SEND_PAT_KEYS if key not in data]
        fail("%s 的 sendPat 地址组不完整（缺 %s）；缺地址时脚本会回退 4.1.15 硬编码值"
             % (name, ", ".join(absent)))
    if str(data.get("r3PatSend", "")).lower() == "true" and len(pat_present) != len(SEND_PAT_KEYS):
        fail("%s 开启 r3PatSend=true 但 sendPat 地址组不完整（会静默不可用）" % name)

    # 消息偏移必须成对；只写一个会让正文/时间有一半用错版本。
    offsets = [key for key in MESSAGE_OFFSET_KEYS if key in data]
    if offsets and len(offsets) != len(MESSAGE_OFFSET_KEYS):
        fail("%s 的消息偏移必须成对出现（%s）" % (name, ", ".join(MESSAGE_OFFSET_KEYS)))
    for key in MESSAGE_OFFSET_KEYS:
        if key in data and parse_hex(data[key]) is None:
            fail("%s 的 %s 不是合法十六进制：%r" % (name, key, data[key]))

    # bodyReturn 必须是 4 字节对齐的返回地址（4.2.1.3 曾误填成 vtable 槽位函数入口）。
    for key in SNS_BODY_RETURN_KEYS:
        if key in data:
            value = parse_hex(data[key])
            if value is None or value % 4 != 0:
                fail("%s 的 %s 不是 4 字节对齐的返回地址：%r" % (name, key, data[key]))
    # 请求体返回点按「读取 + 发布」三件套成组出现：只补一半会让主动刷新/发布模板
    # 在某条链路上静默失效。snsCommentBodyReturn 可选（缺省时评论退回自拼报文）。
    body_return_present = [key for key in SNS_BODY_RETURN_KEYS if key in data]
    if body_return_present:
        absent = [key for key in SNS_CORE_BODY_RETURN_KEYS if key not in data]
        if absent:
            fail("%s 的 SNS 请求体返回点不完整（缺 %s）" % (name, ", ".join(absent)))

    if "hookVerified" not in data:
        fail("%s 缺少 hookVerified（仓库版本表必须显式标注真机验证状态）" % name)

    # 开关值必须能被脚本的 === "true"/"false" 判断消费。
    for key in ("enableSend", "snsEnable", "snsProbe", "snsWrite", "snsDbRead",
                "r3AppMsgSend", "r3PatSend", "r3VoiceSend", "r3ClosureCapture",
                "r3Slot13Capture", "r3QueueUntilSeed", "contactDirectory", "hookVerified"):
        if key in data and not is_boolish(data[key]):
            fail("%s 的 %s 必须是 \"true\"/\"false\"：%r" % (name, key, data[key]))

    # 任一数值/地址值必须可解析。
    for key, value in data.items():
        if key.endswith("Size"):
            size = parse_hex(value)
            if size is None or size < 0x20:
                fail("%s 的 %s 尺寸非法：%r" % (name, key, value))
        if isinstance(value, str) and value.startswith("0x"):
            if parse_hex(value) is None:
                fail("%s 的 %s 不是合法十六进制：%r" % (name, key, value))

    # 开启 SNS 的版本必须五组任务锚点齐全，否则 timeline/sync 捕获会静默失败。
    if str(data.get("snsEnable", "")).lower() == "true":
        for prefix in SNS_PREFIXES:
            if not all(prefix + suffix in data for suffix in SNS_SUFFIXES):
                fail("%s 开启 snsEnable=true 但 %s 任务锚点不完整" % (name, prefix))

    known.add(os.path.splitext(os.path.basename(path))[0])


def check_version_defaults(json_files):
    manage = read(os.path.join(ROOT, "tools", "manage_wechat.sh"))
    install = read(os.path.join(ROOT, "tools", "install_gadget.sh"))
    run_bridge = read(os.path.join(ROOT, "scripts", "run_bridge.sh"))
    build_app = read(os.path.join(ROOT, "scripts", "build_app.sh"))
    package_release = read(os.path.join(ROOT, "scripts", "package_release.sh"))
    app_detection = read(os.path.join(ROOT, "app", "Sources", "WeChatBot", "Services", "WeChatAppDetection.swift"))

    manage_version = default_version_from(manage, r"WECHAT_SUPPORTED_VERSION:-([0-9.]+)")
    manage_build = default_version_from(manage, r"WECHAT_SUPPORTED_BUILD:-([0-9]+)")
    install_version = default_version_from(install, r"WECHAT_SUPPORTED_VERSION:-([0-9.]+)")
    install_build = default_version_from(install, r"WECHAT_SUPPORTED_BUILD:-([0-9]+)")
    if not manage_version or not manage_build:
        fail("无法从 tools/manage_wechat.sh 解析默认微信版本/build")
        return
    if (manage_version, manage_build) != (install_version, install_build):
        fail("默认版本不一致：manage_wechat.sh=%s(%s) install_gadget.sh=%s(%s)"
             % (manage_version, manage_build, install_version or "?", install_build or "?"))

    manage_pairs_text = default_version_from(manage, r'KNOWN_VERSION_PAIRS="([^"]+)"')
    install_pairs_text = default_version_from(install, r'KNOWN_VERSION_PAIRS="([^"]+)"')
    if manage_pairs_text != install_pairs_text:
        fail("KNOWN_VERSION_PAIRS 在 manage_wechat.sh 与 install_gadget.sh 中不一致")
    pairs = git_versions(manage_pairs_text)
    if not pairs:
        fail("无法从 KNOWN_VERSION_PAIRS 解析已知版本")
    elif pairs[0] != (manage_version, manage_build):
        fail("KNOWN_VERSION_PAIRS 首项 %s(%s) 与默认版本 %s(%s) 不一致"
             % (pairs[0][0], pairs[0][1], manage_version, manage_build))

    run_default = default_version_from(run_bridge, r"hook/versions/([0-9_]+)_mac\.json")
    if run_default.replace("_", ".") != manage_version:
        fail("scripts/run_bridge.sh 默认 --wechat-conf 版本 %s 与默认微信版本 %s 不一致"
             % (run_default or "?", manage_version))

    build_default = default_version_from(build_app, r'DEFAULT_HOOK_VERSION="([0-9.]+)"')
    if build_default != manage_version:
        fail("scripts/build_app.sh 的 DEFAULT_HOOK_VERSION=%s 与默认微信版本 %s 不一致"
             % (build_default or "?", manage_version))

    pkg_versions = sorted(set(re.findall(r"hook/versions/([0-9_]+)_mac\.json", package_release)))
    expected_norm = manage_version.replace(".", "_")
    if pkg_versions != [expected_norm]:
        fail("scripts/package_release.sh 写死的版本 JSON %s 与默认 %s_mac.json 不一致"
             % (", ".join(pkg_versions) or "（无）", expected_norm))

    app_pairs = re.findall(r'Pair\(version: "([0-9.]+)", build: "([0-9]+)"\)', app_detection)
    if app_pairs != pairs:
        fail("App WeChatVersionSupport.knownPairs 与安装脚本 KNOWN_VERSION_PAIRS 不一致：%s vs %s"
             % (app_pairs, pairs))

    # 双向：已知版本都要有 JSON；仓库里也不要留已移除版本的孤立 JSON。
    json_versions = set()
    for path in json_files:
        match = re.fullmatch(r"([0-9_]+)_mac\.json", os.path.basename(path))
        if not match:
            fail("hook/versions 下出现无法识别的文件名：%s" % os.path.basename(path))
            continue
        json_versions.add(match.group(1))
    known_versions = {version.replace(".", "_") for version, _ in pairs}
    if json_versions != known_versions:
        for version in sorted(known_versions - json_versions):
            fail("已知版本 %s 缺少 hook/versions/%s_mac.json" % (version.replace("_", "."), version))
        for version in sorted(json_versions - known_versions):
            fail("hook/versions/%s_mac.json 对应的微信版本不在 KNOWN_VERSION_PAIRS 中" % version)

    # 默认版本必须存在且通过 hookVerified 门禁（App 启动 bridge 前会硬拦）。
    default_path = os.path.join(ROOT, "hook", "versions", "%s_mac.json" % expected_norm)
    if not os.path.isfile(default_path):
        fail("缺少默认版本 JSON：hook/versions/%s_mac.json" % expected_norm)
        return
    data = load_json(default_path)
    if "hookVerified" not in data:
        fail("默认版本 JSON 缺少 hookVerified（App 视为已验证；应显式写 true/false）")
    elif str(data["hookVerified"]).lower() != "true":
        fail("默认版本 JSON 的 hookVerified=%r；App 启动门禁会拒绝启动 bridge" % data["hookVerified"])

    # 默认版本必须完成朋友圈完整读写适配：新版本不允许「聊天能用、朋友圈只读」就切默认。
    # 如果默认版本 JSON 声明了 SNS 段，必须五组锚点 + 四个请求体返回点齐全；完全没有
    # SNS 段的旧版本（4.2.0.5 / 4.2.0.9）不在本条约束内。
    sns_declared = any(key in data for prefix in SNS_PREFIXES
                       for key in (prefix + suffix for suffix in SNS_SUFFIXES))
    if sns_declared:
        missing_groups = []
        for prefix in SNS_PREFIXES:
            for suffix in SNS_SUFFIXES:
                if prefix + suffix not in data:
                    missing_groups.append(prefix + suffix)
        missing_bodies = [key for key in SNS_BODY_RETURN_KEYS if key not in data]
        if missing_groups or missing_bodies:
            fail("默认版本 %s 的朋友圈读写适配不完整（缺 %s）；新版本必须在同一轮适配完成"
                 " SNS 读写并按 docs/hook-porting.md §5.1 真机验证，不能只留聊天链路"
                 % (manage_version, ", ".join(missing_groups + missing_bodies)))

    # 已支持版本不得被 App 的写门禁强制只读：只读名单只能用于「新版本尚未完成 SNS 读写
    # 验证」的临时状态，不能把 shared KNOWN_VERSION_PAIRS 里的版本长期留在里面。
    suppressed_match = re.search(
        r"snsWriteSuppressedVersions\s*:\s*Set<String>\s*=\s*\[(.*?)\]",
        app_detection, re.S)
    if not suppressed_match:
        fail("无法从 WeChatAppDetection.swift 解析 snsWriteSuppressedVersions；"
             "请保持 `static let snsWriteSuppressedVersions: Set<String> = [...]` 形式（检查器需要同步更新）")
    suppressed = set(re.findall(r'"([0-9]+(?:\.[0-9]+)+)"', suppressed_match.group(1))) \
        if suppressed_match else set()
    known_versions = {version for version, _ in pairs}
    leaked = sorted(suppressed & known_versions)
    if leaked:
        fail("WeChatVersionSupport.snsWriteSuppressedVersions 仍包含已支持版本 %s："
             "已适配版本必须完成朋友圈发布/评论/回复真机验证后再移出只读名单"
             % ", ".join(leaked))
    if manage_version in suppressed:
        fail("默认微信版本 %s 在 snsWriteSuppressedVersions 中（App 会强制只读朋友圈写）"
             % manage_version)


def find_node():
    node = shutil.which("node")
    if node:
        return node
    for candidate in ("/usr/local/bin/node", "/opt/homebrew/bin/node"):
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return ""


def render_template(source, data):
    def replace_if(match):
        key, body = match.group(1), match.group(2)
        value = data.get(key)
        if value is None or value is False or value == "" or value == 0:
            return ""
        return body

    rendered = IF_RE.sub(replace_if, source)
    return KEY_RE.sub(lambda match: str(data.get(match.group(1), "<no value>")), rendered)


def check_rendered_syntax(source, json_files):
    node = find_node()
    if not node:
        print("  … 未找到 node，跳过模板渲染后的 JS 语法检查")
        return
    with tempfile.TemporaryDirectory(prefix="wechatai-render-") as tmp:
        for path in json_files:
            data = load_json(path)
            rendered = render_template(source, data)
            out = os.path.join(tmp, os.path.basename(path) + ".js")
            with open(out, "w", encoding="utf-8") as fh:
                fh.write(rendered)
            result = subprocess.run([node, "--check", out], capture_output=True, text=True)
            if result.returncode != 0:
                first = (result.stderr or result.stdout).strip().splitlines()
                fail("%s 渲染后 JS 语法错误：%s" % (os.path.basename(path),
                                                   first[-1] if first else "node --check 失败"))


def main():
    script_path = os.path.join(ROOT, "hook", "script.js")
    if not os.path.isfile(script_path):
        print("❌ 缺少 hook/script.js", file=sys.stderr)
        return 1
    source, keys = check_template_keys()
    required, optional = classify_keys(keys)
    json_files = sorted(glob.glob(os.path.join(ROOT, "hook", "versions", "*.json")))
    if not json_files:
        fail("hook/versions 下没有任何版本 JSON")
    known = set()
    for path in json_files:
        try:
            data = load_json(path)
        except json.JSONDecodeError as exc:
            fail("%s JSON 解析失败：%s" % (os.path.basename(path), exc))
            continue
        check_version_json(path, data, required, optional, known)
    check_version_defaults(json_files)
    check_rendered_syntax(source, json_files)

    if ERRORS:
        print("❌ Hook 模板/版本表检查失败：", file=sys.stderr)
        for message in ERRORS:
            print("  ✘ " + message, file=sys.stderr)
        return 1
    print("  ✔ hook/script.js %d 个占位符与 %d 个版本 JSON 一致，默认版本/已知版本列表一致"
          % (len(keys), len(json_files)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

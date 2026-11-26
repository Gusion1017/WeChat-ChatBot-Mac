"""Verification summary and human-readable porting report."""

from __future__ import annotations

import json
import os
from collections import Counter
from datetime import datetime, timezone
from typing import Dict, List, Optional

from .resolver import (
    ACCEPTABLE,
    HIGH,
    MANUAL,
    MEDIUM,
    REVIEW,
    STATUS_ORDER,
    UNRESOLVED,
    VERIFIED,
    KeyResult,
)
from .table import VersionTable, format_value

SCHEMA = "wechatai.hook-port/v1"


def summarize(results: Dict[str, KeyResult]) -> Dict[str, int]:
    counts = Counter(result.status for result in results.values())
    summary = {status: counts.get(status, 0) for status in
               (VERIFIED, HIGH, MEDIUM, REVIEW, MANUAL, UNRESOLVED, "carried")}
    summary["total"] = len(results)
    summary["acceptable"] = sum(counts.get(status, 0) for status in ACCEPTABLE)
    return summary


def build_result(
    *,
    baseline: VersionTable,
    candidate: VersionTable,
    target: dict,
    results: Dict[str, KeyResult],
    render_ok: bool,
    render_detail: str,
    schema_errors: List[str],
    registration: Optional[dict] = None,
    manual_keys: Optional[Dict[str, str]] = None,
    workdir: Optional[str] = None,
    sns: Optional[dict] = None,
) -> dict:
    summary = summarize(results)
    if manual_keys:
        summary["manual"] = len(manual_keys)
    blocking = [result.to_dict() for result in results.values()
                if result.status not in ACCEPTABLE]
    blocking.sort(key=lambda item: (STATUS_ORDER.get(item["status"], 99), item["key"]))
    return {
        "schema": SCHEMA,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "workdir": os.path.abspath(workdir) if workdir else None,
        "baseline": {
            "path": baseline.path,
            "keys": len(baseline.data),
        },
        "target": target,
        "candidate": {
            "path": candidate.path,
            "keys": len(candidate.data),
            "hookVerified": candidate.data.get("hookVerified"),
        },
        "summary": summary,
        "render": {"ok": render_ok, "detail": render_detail},
        "schema_errors": schema_errors,
        "blocking": blocking,
        "results": {key: result.to_dict() for key, result in results.items()},
        "manual_keys": manual_keys or {},
        "manual_values": {key: candidate.data.get(key) for key in (manual_keys or {})},
        "registration": registration or {},
        "sns": sns or {},
    }


def _status_icon(status: str) -> str:
    return {
        VERIFIED: "✅",
        HIGH: "✅",
        MEDIUM: "🟡",
        REVIEW: "🔴",
        MANUAL: "🟡",
        UNRESOLVED: "⛔",
        "carried": "⚪",
    }.get(status, "•")


def build_markdown(result: dict) -> str:
    summary = result["summary"]
    target = result["target"]
    lines: List[str] = []
    lines.append("# WeChat Hook 适配报告")
    lines.append("")
    lines.append(f"> 生成时间：{result['generated_at']}")
    lines.append("")
    lines.append("## 1. 摘要")
    lines.append("")
    lines.append(f"- 基线版本表：`{result['baseline']['path']}`")
    lines.append(f"- 目标微信：**{target.get('version') or '?'} ({target.get('build') or '?'})**")
    lines.append(f"- 目标二进制：`{target.get('path')}`")
    lines.append(f"- SHA256：`{target.get('sha256') or '?'}`")
    lines.append(f"- UUID：`{target.get('uuid') or '?'}`")
    lines.append("")
    lines.append("| 状态 | 数量 | 含义 |")
    lines.append("| --- | ---: | --- |")
    meanings = {
        VERIFIED: "结构关系/导入符号已证明",
        HIGH: "函数/地址匹配 + 指令窗口一致",
        MEDIUM: "有候选，但证据较弱",
        REVIEW: "需要人工确认",
        MANUAL: "结构偏移/常量需真机或逆向确认",
        UNRESOLVED: "没有候选",
        "carried": "原样保留的开关/字符串",
    }
    for status in (VERIFIED, HIGH, MEDIUM, REVIEW, MANUAL, UNRESOLVED, "carried"):
        lines.append(f"| {_status_icon(status)} {status} | {summary.get(status, 0)} | {meanings[status]} |")
    lines.append(f"| **地址键合计** | **{summary.get('total', 0)}** | 可接受（verified/high）：{summary.get('acceptable', 0)}；manual 见第 3 节 |")
    lines.append("")

    blocking = result.get("blocking") or []
    lines.append("## 2. 需要处理")
    lines.append("")
    if not blocking:
        lines.append("没有 `medium/review/unresolved` 地址；仍必须完成真机验证后才能把 `hookVerified` 改为 `true`。")
    else:
        lines.append("| 键 | 旧值 | 候选值 | 状态 | 方法 | 备注 |")
        lines.append("| --- | --- | --- | --- | --- | --- |")
        for item in blocking:
            note = item.get("note") or ""
            if item.get("alternatives"):
                note += " 候选：" + ", ".join(str(alt.get("address")) for alt in item["alternatives"][:3])
            lines.append(
                f"| `{item['key']}` | `{item.get('old') or '?'}` | `{item.get('new') or '—'}` | "
                f"{_status_icon(item['status'])} {item['status']} | `{item['method']}` | {note} |"
            )
    lines.append("")

    if result.get("manual_keys"):
        lines.append("## 3. 结构偏移/常量（无法由地址映射自动证明）")
        lines.append("")
        lines.append("| 键 | 值 | 说明 |")
        lines.append("| --- | --- | --- |")
        for key, note in result["manual_keys"].items():
            value = (result.get("manual_values") or {}).get(key, "?")
            lines.append(f"| `{key}` | `{value}` | {note} |")
        lines.append("")
        lines.append("> 这些键不会阻止模板渲染，但可能在运行时导致静默错误；")
        lines.append("> 必须在真机上确认消息正文/时间、语音 opcode 等行为后再标记已验证。")
        lines.append("")

    lines.append("## 4. 模板与安全检查")
    lines.append("")
    render_ok = result["render"]["ok"]
    lines.append(f"- 模板渲染：{'✅ 通过' if render_ok else '❌ 失败'} — {result['render']['detail']}")
    schema_ok = not result["schema_errors"]
    lines.append(f"- 版本表 schema：{'✅ 通过' if schema_ok else '❌ ' + '; '.join(result['schema_errors'])}")
    lines.append("- 候选表已强制关闭 `enableSend` / `req2bufSendMode=off` / `snsEnable=false` / `snsProbe=false`，")
    lines.append("  并写入 `hookVerified=\"false\"`；未证明的地址会从候选表中删除，避免静默注入错误地址。")
    lines.append("")

    sns = result.get("sns") or {}
    lines.append("## 5. 朋友圈（SNS）读写适配")
    lines.append("")
    if not sns.get("capable"):
        lines.append("基线与候选表都没有声明朋友圈通道（无 SNS 锚点）；仅当目标版本确实不支持朋友圈时才是预期状态。")
    else:
        complete = sns.get("candidate_complete", False)
        retained = not sns.get("missing_vs_baseline")
        lines.append(f"- 朋友圈完整读写：{'✅ 齐全' if complete and retained else '❌ 不完整（候选表会退化为 503 / 只读）'}")
        lines.append(f"- 与基线相比缺少的 SNS 键：{'无' if retained else '`' + '`、`'.join(sns.get('missing_vs_baseline') or []) + '`'}")
        lines.append("")
        lines.append("| 任务 | 锚点组 | 说明 |")
        lines.append("| --- | --- | --- |")
        meanings = {
            "snsTimeline": "读取时间线（主动刷新/分页）",
            "snsSync": "mmsnssync 增量同步",
            "snsPost": "发布动态",
            "snsUserpage": "查看他人主页动态",
            "snsComment": "评论 / 回复 / 点赞（0xD5 通道）",
        }
        for prefix, meaning in meanings.items():
            item = (sns.get("candidate_tasks") or {}).get(prefix) or {}
            mark = "✅" if item.get("complete") else "❌"
            missing = item.get("missing") or []
            lines.append(f"| `{prefix}` | {mark} | {meaning}{'；缺 ' + '、'.join(missing) if missing else ''} |")
        lines.append("")
        bodies = sns.get("candidate_body_returns") or {}
        body_ok = all(bodies.values())
        lines.append(f"- 请求体返回点（BodyReturn）：{'✅ 齐全' if body_ok else '❌ 缺 ' + '、'.join(k for k, v in bodies.items() if not v)}")
        lines.append("")
        lines.append("**真机验证（必须完成，见 `docs/hook-porting.md` §5.1）**：")
        lines.append("1. 微信里手动打开一次朋友圈 → `POST /sns/timeline` 返回 `source=native`，`POST /sns/sync` 返回命令与游标；")
        lines.append("2. 手动发一条文字朋友圈（私密或部分可见）→ `POST /sns/post` 返回 `post_id` 且时间线可见；")
        lines.append("3. 手动评论一次捕获 0xD5 → `POST /sns/comment` 返回 `comment_id`，再带 `reply_comment_id` 回复他人评论；")
        lines.append("4. 四项全部通过、微信未崩溃后，才可切换默认版本并把该版本移出 `snsWriteSuppressedVersions`。")
        lines.append("")
        lines.append("> 新版本不允许「聊天能用、朋友圈只读」就发布：`adapt/verify/promote` 会拒绝缺少 SNS 键的候选表，")
        lines.append("> 默认版本的 SNS 完整性与只读名单由 `scripts/check_hook_template.py` 检查。")
    lines.append("")

    lines.append("## 6. 下一步")
    lines.append("")
    lines.append("1. 对第 2 节的每个 `review/unresolved` 键，用 `wxport explain --key <key>` 看新旧反汇编和候选；")
    lines.append("   确认后写入 `hook/versions/<version>_mac.json`。")
    lines.append("2. 跑 `./tools/wxport verify ...` 重新生成报告，直到没有 `review/unresolved`。")
    lines.append("3. 注册版本：`./tools/wxport registration --version <version> --build <build>`，按输出逐项更新")
    lines.append("   shell/Swift/README/docs/localization。")
    lines.append("4. `bash scripts/check.sh --docs`，再跑 Swift/Go 测试。")
    lines.append("5. 真机验证（先只读）：安装 Hook → 私聊文本入站 → 群聊 @ → 拍一拍 → R3 文本发送 →")
    lines.append("   重启恢复；任何 SIGILL / task_layout_mismatch 立即回滚。")
    lines.append("6. 朋友圈读写真机验证（硬性项）：按第 5 节与 `docs/hook-porting.md` §5.1 完成")
    lines.append("   timeline 主动刷新 / sync / 发布 / 评论 / 回复；未通过前不得切默认，也不得把版本")
    lines.append("   长期留在 `snsWriteSuppressedVersions`。")
    lines.append("7. 只有真机验证（含朋友圈读写）通过后，才把版本表 `hookVerified` 改为 `\"true\"`，并从")
    lines.append("   `WeChatVersionSupport.unverifiedHookVersions` 移除。")
    lines.append("")

    lines.append("## 7. 关键键明细")
    lines.append("")
    lines.append("| 键 | 旧值 | 新值 | Δ | 状态 | 方法 | 检查 |")
    lines.append("| --- | --- | --- | --- | --- | --- | --- |")
    for key in sorted(result["results"], key=lambda k: result["results"][k]["kind"]):
        item = result["results"][key]
        old = item.get("old")
        new = item.get("new")
        delta = "—"
        if old and new:
            try:
                delta = f"{int(new, 16) - int(old, 16):+#x}"
            except ValueError:
                delta = "—"
        checks = ", ".join(item.get("checks") or [])
        lines.append(
            f"| `{key}` | `{old or '?'}` | `{new or '—'}` | `{delta}` | "
            f"{_status_icon(item['status'])} {item['status']} | `{item['method']}` | {checks} |"
        )
    lines.append("")

    if result.get("registration"):
        lines.append("## 8. 注册检查")
        lines.append("")
        for item in result["registration"].get("checks", []):
            mark = "✅" if item["ok"] else "❌"
            lines.append(f"- {mark} `{item['file']}` — {item['detail']}")
        lines.append("")

    lines.append("## 9. 复现命令")
    lines.append("")
    lines.append("```bash")
    lines.append("# 重新生成候选与报告")
    lines.append("./tools/wxport adapt \\")
    lines.append("  --app /Applications/WeChat.app \\")
    lines.append(f"  --baseline {result['baseline']['path']} \\")
    lines.append(f"  --workdir {result.get('workdir') or '<workdir>'}")
    lines.append("")
    lines.append("# 只看某个键的证据")
    lines.append("./tools/wxport explain \\")
    lines.append(f"  --workdir {result.get('workdir') or '<workdir>'} --key <key>")
    lines.append("```")
    lines.append("")
    return "\n".join(lines)


def write_report(result: dict, markdown_path: str, json_path: str) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(markdown_path)), exist_ok=True)
    with open(markdown_path, "w", encoding="utf-8") as fh:
        fh.write(build_markdown(result))
    with open(json_path, "w", encoding="utf-8") as fh:
        json.dump(result, fh, ensure_ascii=False, indent=2)
        fh.write("\n")

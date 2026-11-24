# AGENTS.md — 本仓库的 Agent 工作约定

本文件面向在本仓库工作的自动化 Agent。人类维护者请看 `CONTRIBUTING.md` 与 `docs/`。

## 本机研究区（不在仓库内）

切片、工作目录、真机证据一律放**仓库外**，下文用 `$PORT_HOME` 指代（路径自选，例：
`export PORT_HOME="$HOME/wechat-research"`）。`.gitignore` 仍保留 `_local/`、`_research/`
规则，只是误建同名目录时的兜底。

## 微信更新时（最高优先级）

当用户说「微信更新了 / 新版微信适配 / Hook 失效」，按以下顺序：

1. 读 `docs/hook-porting.md`（完整流程）与 `tools/wechat_port/README.md`（工具）。
2. 先备份，不要直接改 `/Applications/WeChat.app`：
   `bash tools/manage_wechat.sh backup`
3. 用工具生成候选，不要手抄地址：
   `python3 tools/wechat_port/cli.py adapt --app /Applications/WeChat.app --old-binary "$PORT_HOME/fixtures/wechat-<上一版>-arm64.dylib" --baseline hook/versions/<上一版>_mac.json --workdir "$PORT_HOME/work/<新版本>-<build>" --version <新版本> --force`
4. 只处理 `REPORT.md` 第 2 节的 `medium/review/unresolved`；`verified/high` 不要手改。
5. 未真机验证前，版本表必须保持 `hookVerified="false"`，发送/朋友圈写开关保持关闭。
6. 真机验证矩阵见 `docs/hook-porting.md` 第 5 节；通过后才能改 `hookVerified=true` 并移出
   `WeChatVersionSupport.unverifiedHookVersions`。
7. 改完跑 `bash scripts/check.sh --docs`、`PYTHONPATH=tools python3 -m unittest discover -s tools/wechat_port/tests -v`；
   改了 `hook/script.js` 跑 `bash scripts/sync_hook_script.sh`。

禁止：

- 凭经验猜地址、把未验证地址标成 verified、跳过备份。
- 在公开文档/issue/PR 粘贴地址、偏移、wxid、聊天内容、日志原文。
- 把微信二进制、真机证据（日志/截图/DB 备份）、真实数据库提交到仓库。
- 为了「让它先跑起来」而关闭 `hookVerified` 门禁或强装未适配版本。

## 常用命令

```bash
bash scripts/check.sh --docs          # 脚本/文档/Hook 模板/版本表
bash scripts/check.sh                 # 上面 + Swift 测试
bash scripts/check.sh --with-go       # 上面 + Go bridge
bash scripts/build_bridge.sh          # bridge 构建/测试
bash scripts/build_app.sh             # App 构建
PYTHONPATH=tools python3 -m unittest discover -s tools/wechat_port/tests -v
```

## 代码边界

- `hook/script.js` 是唯一事实来源；`bridge/script.js` 由 `scripts/sync_hook_script.sh` 生成。
- 版本地址/开关只写 `hook/versions/*.json`；文档不重复地址。
- 接口/行为变更先改 `docs/architecture.md` 等契约文档，再改代码。
- 新增版本时同步 `tools/manage_wechat.sh` / `tools/install_gadget.sh` 的 `KNOWN_VERSION_PAIRS`
  与 `WeChatAppDetection.swift` 的 `knownPairs`；用 `wxport registration` 检查遗漏。

## 测试与证据

- 测试数据用 `devtools/` mock 或脱敏 fixture；不要用真实聊天记录。
- 真机日志、截图、DB 备份放**仓库外**的本机研究区（`$PORT_HOME`）；提交前用 `git status` 确认未混入。
- PR 需注明微信版本/build、验证日期、已验证/未复测范围。

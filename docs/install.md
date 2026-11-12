# 安装与启动（从 GitHub 获取）

> 本项目是 **macOS 原生 App + 微信 Hook**，不是双击即用的普通应用：GitHub 的「Download ZIP」默认只给
> **源码**，不含已编译的 App、bridge 二进制和 Frida Gadget；非开发者请用 Releases 里的 App 压缩包，
> 只有源码时按「源码构建」操作。当前发布版本：**4.1.0（build 37，2026-11-12）**，压缩包约 70 MB（66 MiB）。

## 1. 先确认环境

| 项目 | 要求 |
| --- | --- |
| 硬件 | Apple Silicon（arm64） |
| 系统 | macOS 26 或更高 |
| 微信 | 4.2.0.17 (270353)、4.2.0.12 (270348)、4.2.0.9 (270345)、4.2.0.5 (270341)、4.1.15.55 (270135) 或 4.1.12.53 (269365) 之一；已安装并登录；默认位于 `/Applications/WeChat.app`，当前用户需对该 App 有写权限 |
| 命令行工具 | **安装 Hook 必需**：Xcode Command Line Tools（或完整 Xcode），提供 `/usr/bin/python3` 与 `/usr/bin/otool`。安装命令 `xcode-select --install`；不需要 Apple 开发者账号 |
| 权限 | 安装到 `/Applications`、修改微信或移除 quarantine 时可能需要管理员密码 / Touch ID |
| 磁盘 | 安装 Hook 会完整备份微信（约 670MB，随微信版本略有差异），建议预留 ≥2.5GB |
| 源码构建 | 仅方式 B 需要 Xcode 27（已验证 27.1，含命令行工具）；方式 A 只需上面的 CLT |
| 本地 TTS（语音引擎） | **Qwen3-TTS-1.7B**（唯一模型，Apple MLX）：额外需要 `uv`、`python3.10` 或 conda 之一（安装脚本按此顺序探测）；首次安装约 4.7GB 磁盘（MLX 模型 ~4.2GB + 依赖 ~0.5GB，运行时内存约 10GB）；默认 GPU，可选 CPU（极慢，实验性）；App 不内置音色，需自行导入参考音；模型未安装/服务未启动/合成失败或超时时语音回复自动改发文字 |

> 微信版本必须**精确匹配列表**；不在列表时向导会提示不匹配，不要强行安装 Hook。
> 安装脚本默认以 4.2.0.17 (270353) 为目标，其余五个历史版本仍可直接安装。
> **4.2.0.17 真机验证（2026-11-07，4.1.0）**：`manage_wechat.sh install` 完整备份（约 670MB）后注入 Gadget + ad-hoc 重签
> （保留 sandbox entitlements）；模块基址与版本地址表解析通过；Message finalizer 入站（群聊文本、type=49 appmsg、
> 自身消息）字段正常；R3 classA/service vptr、slot13 捕获、newsendmsg closure seed 均通过；R3 文本发送到
> 文件传输助手（slot13 返回 0、worker result=1）；通讯录读取正常（联系人 / 群聊）；R3 模式下连续运行数分钟稳定。
> 4.2.0.12 / 4.2.0.9 / 4.2.0.5 已完成真机验证（注入、入站消息、通讯录与 R3 文本发送）。
> 语音发送、图片获取与群聊 @ 未在 4.2.0.17 逐一复测，历史记录见 `CHANGELOG.md`。
>
> 如果微信来自 **App Store**，或 App 由 root 安装导致当前用户不可写，Hook 可能装不上；
> 请改用微信官网下载的 arm64 版，并确认 `/Applications/WeChat.app` 属主是当前用户。
> 修改微信仍有风险，安装前请保留官方备份。

## 2. 方式 A：Releases 里的 App 压缩包（推荐给普通用户）

发布者在本地构建后把 `WeChat AI.app` 压缩上传到 GitHub Releases，当前版本 **4.1.0（约 70 MB / 66 MiB）**。

1. 下载 `WeChat-AI-4.1.0.zip`（建议同时下载 `.sha256`），解压 zip，得到 `WeChat AI.app`。可选校验（在下载目录执行）：

   ```bash
   shasum -a 256 -c WeChat-AI-4.1.0.zip.sha256
   ```

2. 把 `WeChat AI.app` 拖到 `~/Applications`（当前用户，无需管理员）或 `/Applications`（所有用户）；下文分别示例。

3. **首次打开会被 Gatekeeper 拦截**（App 是 ad-hoc 签名、未做 Apple 公证）。**macOS 15 起（含 macOS 26）
   已取消「右键 → 打开」这个绕过入口**，正确流程：

   - 双击 App，看到“无法验证开发者 / 无法打开”的拦截提示；
   - 打开「系统设置 → 隐私与安全性」，滚动到底部，找到刚被拦截的 App，点「仍要打开」；
   - 按提示输入管理员密码或使用 Touch ID 确认。

   如果「隐私与安全性」里没有条目或仍被拦截，可在终端移除 quarantine（**路径必须与实际安装位置一致**）：

   ```bash
   # 安装在当前用户目录
   xattr -dr com.apple.quarantine "$HOME/Applications/WeChat AI.app"
   open "$HOME/Applications/WeChat AI.app"

   # 安装在系统目录（需要管理员，命令前加 sudo）
   sudo xattr -dr com.apple.quarantine "/Applications/WeChat AI.app"
   open "/Applications/WeChat AI.app"
   ```

   > 不要对不存在的路径执行 `xattr`；如果 App 被系统移动过（如 App Translocation），先拖到 `~/Applications` 或 `/Applications` 再执行。

4. 这是一个**菜单栏 App**：启动时显示主窗口，关闭后 Dock 图标消失、仅保留菜单栏图标；
   **左键单击菜单栏图标**开合状态面板（打开主窗口、启停机器人、设置与退出），右键 / Control-左键不执行操作。

5. **首次启动向导**（右上角可切换 **语言 / Language**：跟随系统 / 简体中文 / English）：

   - **环境检查**：显示 Xcode Command Line Tools 状态（已安装 / 未安装 / 检测中）。未安装时点「安装 Command Line Tools」会执行
     `xcode-select --install`，按提示完成（通常几分钟）后回向导点「重新检测」；**CLT 未就绪时「备份并安装 Hook」按钮禁用**。
     完整 Xcode 同样视为就绪；不需要 Apple 开发者账号。
   - **检测微信**：显示实际检测路径、版本+build 与进程状态；版本须精确匹配上述版本列表。
     App 会按「运行中的微信 → 设置路径 → LaunchServices/常见安装位置」自动发现微信，路径写错或装在
     `~/Applications` 时会在向导/设置页提示检测路径，可一键「使用该路径」同步。版本不在适配列表时
     显示「未适配」并禁用安装按钮，不要强行安装。
   - **备份并安装 Hook**：先**完全退出微信（包括菜单栏图标，不只是关闭窗口）**，向导会完整备份官方 App 后注入 Gadget 并
     ad-hoc 重签（备份约 670MB、安装约 1–2 分钟，磁盘预留 ≥2.5GB）。完成后 App **不会自动打开微信**，请手动打开并登录。
   - **系统授权（TCC）**：首次读取微信容器会触发「App 数据」授权，请选择允许（拒绝后图片/语音相关功能与 `image_path`
     检测会失败）；修改微信 bundle 时可能再触发「App 管理」授权。App **不会**请求麦克风、语音识别或自动化权限
     （本地 SpeechAnalyzer 不需要麦克风，也不使用 AppleScript）。
   - **配置 AI**：填写通道、Base URL、模型与 API Key；Key 存在 macOS Keychain，不写入 `config.json`。
   - **启动**：完成并启动机器人。

6. **首次发送需捕获句柄**：4.2.0.17 / 4.2.0.12 / 4.2.0.9 / 4.2.0.5 / 4.1.15.55 使用 R3 原生发送
   （4.1.12.53 为 legacy）。首次启用或每次微信重启后，
   需要在本机微信**手动发一条消息**捕获发送句柄（语音回复还需再发一条语音；朋友圈已开启还需手动打开一次朋友圈，朋友圈仅 4.2.0.12 / 4.2.0.17 有 SNS 锚点）；
   句柄未就绪时回复会排队（不会丢失），bridge 重启会从 `r3-seed.json` 自动恢复。App 会在开启语音/朋友圈或
   机器人**每次启动后**弹出统一的「捕获发送句柄」弹窗（条目按已开启功能显示，含 R3 文字句柄；同一次机器人
   运行内最多一次）；关掉后仍可在「机器人 → 语音」的「查看步骤…」或朋友圈页的「重新检测」再次打开/检测。

7. **还原官方微信**：随时可在「设置 → Hook → 还原官方微信」恢复（还原前先完全退出微信），或执行：

   ```bash
   bash tools/manage_wechat.sh restore
   ```

### 2.1 应用内更新（设置 → 更新）

> **3.1.0 起**设置页「应用」组提供「更新」分类；更早版本仍可按本节手动下载覆盖。完整检查接口、状态机、门禁与安全边界见 [`updates.md`](updates.md)。

- **检查与提示**：启动后约 8 秒自动检查 GitHub Releases（6 小时内不重复），也可在 设置 → 更新 手动检查；有新版本时设置侧边栏
  「更新」行显示「新」徽标、主窗口与菜单栏 footer 显示「有新版本 X」并弹一次提醒。只检测**正式版**，不提供 beta 通道。
- **执行更新**：确认后 App 停止机器人，下载 `WeChat-AI-<version>.zip` 并核对同名 `.sha256`、校验 bundle id/版本号/签名，
  然后退出；更新助手把旧 App 备份为同目录 `WeChat AI.app.update-backup-<epoch>`，展开新版本、移除 quarantine、
  ad-hoc 重签并重新打开。全程约一次完整下载（当前包约 70 MB / 66 MiB），更新期间机器人停止，完成后需手动重新启动。
- **更新要求**：必须 `.app` 方式运行（bundle id `com.gusionw.wechatai`，`swift run` 不可更新）；不能处于
  App Translocation 路径；安装目录对当前用户可写（无写权限直接提示，不弹管理员授权）；网络可达 GitHub API
  与资产域名（未认证接口限流 60 次/小时）；开发构建可更新但界面会提示。
- **失败回退**：App 内失败（下载/校验/解压/门禁/助手启动）不退出、保持当前版本并可重试；助手阶段失败（替换/重签/校验/打开）
  会删除半成品、恢复 `.update-backup-*` 并重新打开旧版本，详情见 `~/Library/Logs/WeChatAI/update.log`；
  新版本成功启动后不自动降级，旧备份在新版本**首次启动**时清理。
- **与手动安装的关系**：应用内更新使用与 Releases 相同的 zip 和 SHA256，只是自动化「下载 → 解压 → 拖入 Applications」；
  自动更新不可用（网络/限流/门禁/校验失败）时仍可按方式 A 手动下载覆盖，手动覆盖同样会因 ad-hoc 签名触发 Gatekeeper 首次放行。
- **签名与 Gatekeeper**：App 仍为 ad-hoc 签名、未公证；助手会移除新包 quarantine 并重签，但首次打开仍可能
  需「系统设置 → 隐私与安全性 → 仍要打开」，替换/重签后「App 数据」「App 管理」等 TCC 授权可能需重新允许。

> 如果发布者没有提供 Releases 压缩包，只能用方式 B。

## 3. 方式 B：源码 ZIP（需要 Xcode 27）

Xcode 自带 Command Line Tools，满足 Hook 的 `python3` / `otool` 依赖。

1. 在 GitHub 页面 **Code → Download ZIP**，解压（目录名通常是 `WeChat-ChatBot-Mac-main`）。
2. 打开「终端」，进入解压后的目录：

   ```bash
   cd ~/Downloads/WeChat-ChatBot-Mac-main   # 以实际解压目录为准
   ```

3. 依次执行（首次会下载 Go 1.25.14、Frida devkit 17.8.0 与 Gadget 17.8.0，约需数分钟和数 GB 磁盘）：

   ```bash
   bash scripts/fetch_gadget.sh      # 下载 Frida Gadget 17.8.0（校验 SHA256）
   bash scripts/build_bridge.sh      # 构建 bridge/onebot（含 Go 测试）
   bash scripts/build_app.sh         # 生成 dist/WeChat AI.app
   bash scripts/install_app.sh       # 安装到 ~/Applications（移除 quarantine 并重签）
   open "$HOME/Applications/WeChat AI.app"
   ```

   > `fetch_gadget.sh` 解压 `.xz` 时优先用 `xz`，系统没有时回退 Command Line Tools 自带的
   > `python3` lzma；不需要 Homebrew 或其他额外依赖。

4. 后续与方式 A 的第 4–7 步相同（窗口/菜单栏、首启向导、退出微信后安装 Hook、手动登录、R3 首次手发消息、还原入口）。

> 只想先看看界面、不碰微信：用 `devtools/` 的 Mock 联调，见 [`devtools/README.md`](../devtools/README.md)。

## 4. 发布者：如何制作可下载的 App 压缩包

当前发布版本 **4.1.0（build 37，2026-11-12）**，zip 约 **70 MB（66 MiB）**；在具备 Xcode 27 / CLT 的机器上按顺序构建：

```bash
bash scripts/fetch_gadget.sh
bash scripts/build_bridge.sh
bash scripts/build_app.sh
bash scripts/package_release.sh      # 或 make release
```

脚本会校验必需资源、检查签名、打包并生成 SHA256（`dist/WeChat-AI-4.1.0.zip` + `.sha256`）；
`package_release.sh --skip-build` 可复用 `dist/WeChat AI.app` 重新打包，也可手动执行：

```bash
bash scripts/build_app.sh
/usr/bin/ditto -c -k --norsrc --keepParent "dist/WeChat AI.app" "dist/WeChat-AI-4.1.0.zip"
( cd dist && shasum -a 256 "WeChat-AI-4.1.0.zip" > "WeChat-AI-4.1.0.zip.sha256" )
```

签名与公证的预期：

- App 为 **ad-hoc 签名**、未走 Apple 公证；`codesign -dv --verbose=4 "dist/WeChat AI.app"`
  会显示 `Signature=adhoc`、无 Team ID；
- `codesign --verify --strict "dist/WeChat AI.app"` 应通过；
  `spctl --assess --type execute -vv "dist/WeChat AI.app"` **预期返回 `rejected`**（来源不可识别 / 未公证），
  这是 ad-hoc 分发的正常结果，不代表压缩包损坏；
- 用户首次打开仍需按方式 A 第 3 步的 Gatekeeper 流程操作。

上传前校验：

```bash
cd dist
shasum -a 256 -c WeChat-AI-4.1.0.zip.sha256
```

把 zip 与 `.sha256` 上传到 GitHub **Releases**（tag 与实际版本号一致；已发布 tag 为 `v4.1.0`，新版本请先升版本号再打 tag），在说明里写清：

- 支持 Apple Silicon / macOS 26+ / 微信 4.2.0.17 / 4.2.0.12 / 4.2.0.9 / 4.2.0.5 / 4.1.15.55 / 4.1.12.53；
- **安装 Hook 需要 Xcode Command Line Tools**（`xcode-select --install`，无需开发者账号），首启向导会检测并引导安装；
- App 为 ad-hoc 签名、未公证；macOS 15+ 已无「右键 → 打开」，
  首次需在 系统设置 → 隐私与安全性 → 仍要打开，或用 `xattr -dr com.apple.quarantine`；
- 安装 Hook 会修改微信、需完整备份（约 670MB），存在账号风控与签名失效风险；
- 按 GPL-3.0 提供对应源码（仓库地址即可）；SHA256 指向 `.sha256` 文件，不在说明正文里手抄。

## 5. 常见问题

| 现象 | 处理 |
| --- | --- |
| 双击提示“无法验证开发者”，且找不到「仍要打开」 | macOS 15+ 已取消右键打开。先双击触发拦截，再进 系统设置 → 隐私与安全性 → 仍要打开（需管理员/Touch ID）；仍没有条目就 `xattr -dr com.apple.quarantine "<App 实际路径>"` 后 `open`。两种路径示例见方式 A 第 3 步 |
| 设置里没有「更新」分类 | 应用内更新自 **3.1.0** 起提供，当前 **4.1.0** 已包含；若仍看不到「更新」，请确认运行的是 Releases 里的 `WeChat AI.app`（`swift run` 开发态不计），或按方式 A 手动下载最新 Releases 覆盖安装 |
| 应用内更新失败 / 更新后打不开 | App 内失败不会退出，更新页显示原因并可重试；助手阶段失败会自动恢复旧版并重新打开，详情见 `~/Library/Logs/WeChatAI/update.log`。若新版本仍被 Gatekeeper 拦截，按「仍要打开」流程放行；仍失败则手动重新下载覆盖安装 |
| 提示“App 已损坏” / 校验失败 | 重新下载并核对 `.sha256`；确认 App 完整解压、没有被安全软件截断；不要从不可信镜像下载 |
| 向导提示缺少 Command Line Tools / 安装 Hook 按钮禁用 | 点「安装 Command Line Tools」或终端执行 `xcode-select --install`，完成系统安装后点「重新检测」；完整 Xcode 亦可；不需要开发者账号。终端报 `invalid active developer path` 时执行 `sudo xcode-select -s /Library/Developer/CommandLineTools` |
| 微信从 App Store 安装，或 `/Applications/WeChat.app` 属主是 root | Hook 需要当前用户可写 `/Applications/WeChat.app`。App Store 版路径/签名不同，建议换官网 arm64 版；属主异常时重装微信，或在明确风险后 `sudo chown -R "$USER":staff /Applications/WeChat.app`。可用 `ls -ld /Applications/WeChat.app` 检查 |
| 打开后没有窗口 | 这是菜单栏 App：启动时显示主窗口；关闭窗口后 Dock 图标消失，仅保留菜单栏。**左键**单击顶部菜单栏图标开合状态面板，面板内提供「打开主窗口」、启停、设置与退出；右键 / Control-左键不执行操作 |
| 换微信账号后聊天记录、记忆、会话设置会切换吗 | **会，且旧账号数据不会被删除。** App 以当前登录的微信账号为边界：聊天记录/记忆卡（角色目录）/会话设置/机器人配置/人格/定时任务/新媒体自动切到该账号自己的档案（`~/Library/Application Support/WeChatAI/accounts/<wxid>/`）；AI 通道/Keychain/Hook/OneBot/本地 TTS 安装与音色/崩溃与 bridge 日志仍全局共享。升级旧版时会把旧单库复制到旧 `settings.onebot.self_id` 所属账号（只 copy 不删，旧媒体保留），因此升级后需要**切回原微信账号**才能看到旧聊天。运行中换号会停止机器人、提示后需手动重新启动；App 不提供手动选库。未登录时数据先写 `_unassigned`，登录后自动认领。详见 [`accounts.md`](accounts.md) |
| 微信版本不匹配 | 支持 4.2.0.17 (270353) / 4.2.0.12 (270348) / 4.2.0.9 (270345) / 4.2.0.5 (270341) / 4.1.15.55 (270135) / 4.1.12.53 (269365)。App 会在总览/设置 → Hook 显示版本+build 与实际检测路径，版本不在列表时标「未适配」并禁用安装。用 `/usr/libexec/PlistBuddy -c 'Print :WeChatBundleVersion' /Applications/WeChat.app/Contents/Info.plist` 与 `:CFBundleVersion` 核对（微信 4.x 优先写 `WeChatBundleVersion`；缺失时才回退 `CFBundleShortVersionString`，本机后者可能是 `4.2.0`，按它会误判）。其他版本需自行适配、用 `WECHAT_SUPPORTED_VERSION`/`WECHAT_SUPPORTED_BUILD` 覆盖或还原，**不要强装** |
| 微信装在 `~/Applications` 或状态卡显示「非设置路径」 | App 会自动从运行中的微信/LaunchServices 发现路径并按它检测；到「设置 → Hook」点「使用检测路径」把设置同步过去即可（安装/还原也会使用实际检测路径） |
| 微信启动/退出后状态不更新 | 正常情况下 `NSWorkspace` 通知会实时同步；若仍过期，点总览/设置 → Hook 的「刷新状态」，或切回 App 触发一次轻量核对。持续异常时看运行日志中 `Hook` 来源的错误 |
| 「登录时启动」打不开或系统没反应 | 该开关写入 `~/Library/LaunchAgents/com.gusionw.wechatai.loginitem.plist`；首次可能被 macOS 拦在 系统设置 → 通用 → 登录项，需要允许 WeChat AI 在后台运行。源码 `swift run` 不是 `.app`，开关会禁用；App 移动位置后重新开启即可写回新路径 |
| 退出时没有确认弹窗 / 误触退出 | 只有在「设置 → 通用 → 退出前确认」开启且机器人或 bridge 正在运行时才弹确认，默认按钮是「取消」；关闭机器人后再退出不会打扰 |
| 图片/语音获取失败，或 `image_path` 检测失败 | 检查 系统设置 → 隐私与安全性 → App 数据 中是否允许 WeChat AI；拒绝授权会导致这些功能失败。修改微信时可能还需要「App 管理」授权 |
| 安装 Hook 后微信打不开 | 先完全退出微信，再用 App 的「设置 → Hook → 还原官方微信」或 `bash tools/manage_wechat.sh restore` 还原 |
| 发送不出去 / 一直排队 | 确认「R3 原生发送」开关已开；首次或微信重启后在本机微信手动发一条消息（语音再发一条语音）捕获句柄；`bridge` 刚启动的 60 秒内登录尚未稳定，可等「捕获发送句柄」弹窗/语音面板状态行的倒计时结束后点「重新检测」 |
| 端口被占用（58080 / 27042） | `lsof -nP -iTCP:58080 -sTCP:LISTEN` 与 `lsof -nP -iTCP:27042 -sTCP:LISTEN` 查看占用进程；退出冲突 App，或在「设置 → OneBot」改端口后重启 bridge。27042 是 Gadget 注入端口，只允许一个微信实例 |
| 语音回复没有声音 / 只收到文字 | 先在「机器人 → 语音 → 语音引擎与音色」确认 Qwen3-TTS-1.7B 的「运行环境与模型」已安装、本地服务已启动、已选择音色、运行设备为 GPU（CPU 极慢通常会超时）；未安装/服务未启动/旧版服务仍在/合成失败或超时时该条会自动改发文字。系统中文语音资源缺失时可在 系统设置 → 辅助功能 → 朗读内容 下载，或点「机器人 → 语音」的「下载中文语音资源」 |
| 从源码构建报 `swift: command not found` | 安装 Xcode 27 并执行 `sudo xcode-select -s /Applications/Xcode.app`；只装 CLT 不足以源码构建（Hook 安装只需要 CLT） |

> 换微信账号不需要备份或重装 Hook，账号数据按账号自动归档。首次升级建议先备份
> `~/Library/Application Support/WeChatAI/`（至少旧 `chatbot.sqlite` 与 `media/`），确认正常后再清理旧文件；不要在 App 运行时手动移动 `accounts/` 目录。

## 6. 安全提醒

- 只在自己的设备与账号上使用，不要用于他人账号；修改微信会破坏官方签名，存在账号风控、封号与数据丢失风险，安装前先备份。
- 安装/还原 Hook 前都要完全退出微信；还原入口在「设置 → Hook」。
- 只从本仓库源码或你信任的发布者构建的 App 运行；不要使用来源不明的二进制。

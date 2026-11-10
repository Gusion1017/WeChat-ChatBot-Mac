# Bridge：本地 OneBot 桥接

`bridge/` 是 macOS 原生微信 AI 助手的本地桥接进程，负责两件事：

1. 通过 Frida Gadget 连接已注入 Gadget 的官方微信，加载 `script.js`，接收微信消息并调用
   Hook 的发送能力；
2. 对 App 暴露 OneBot 风格的 WebSocket 事件（`/ws`）、HTTP 发送接口
   （`/send_private_msg`、`/send_group_msg`）与朋友圈接口（`/sns/*`，默认关闭）。

```
WeChat.app (Frida Gadget) ⇄ bridge/onebot ⇄ WeChatAI.app
                              │
                              ├─ WS  /ws       事件推送（Bearer token，仅 127.0.0.1）
                              ├─ HTTP send_*   发送（Authorization: Bearer <token>）
                              └─ HTTP /sns/*   朋友圈读写（默认关，Bearer token）
```

上游来源与许可证：

- 项目：<https://github.com/yincongcyincong/weixin-macos>，子目录 `onebot/`
- 提交：`f222f37321f66d3a199cb3c7642f77f7504d85da`（2026-09-28）
- 许可：**GPL-3.0**（完整文本见 [`bridge/LICENSE`](../bridge/LICENSE)；
  衍生说明见 [`bridge/NOTICE`](../bridge/NOTICE)）
- 本项目以上游 `onebot/` 为基线，**Go 源码有修改与新增**（自消息方向、入站归一化、
  通讯录目录、原生发送状态持久化等）；逐文件清单与原因见 [`bridge/NOTICE`](../bridge/NOTICE)。
  `script.js` 同步 `hook/script.js` 的微信版本化适配（4.1.12 / 4.1.15 / 4.2.0.5 / 4.2.0.9 /
  4.2.0.12 / 4.2.0.17，见 §5）。

> **发布状态（2026-11-10）**：本文描述 **4.0.1**，包含朋友圈 `/sns/*` 与 4.2.0.17 适配；
> 下载用户见 [`install.md`](install.md) 与 [`releases/4.0.1.md`](releases/4.0.1.md)。

---

## 1. 构建

### 1.1 前置条件

| 项 | 要求 |
| --- | --- |
| 硬件/系统 | Apple Silicon（arm64）macOS；已验证 macOS 26.7.1 |
| 编译工具 | Xcode 或 Xcode Command Line Tools（`xcrun --find clang` 可用） |
| 网络 | 首次构建需下载 Go 工具链、Frida devkit、Go modules |
| 磁盘 | 约 2 GB（Go 工具链 / 模块 / 构建缓存约 1.8 GB + 产物约 96 MB） |

构建固定版本（均带 SHA256 校验）：

| 依赖 | 版本 | 来源 |
| --- | --- | --- |
| Go | 1.25.14 darwin-arm64 | <https://go.dev/dl/>（失败时回退 `golang.google.cn` / 阿里云镜像） |
| frida-core-devkit | 17.8.0 macos-arm64 | <https://github.com/frida/frida/releases/tag/17.8.0> |

### 1.2 一键构建

```bash
cd /path/to/ChatBot
scripts/build_bridge.sh
```

脚本行为：

- 工具链与缓存放在 `/tmp/chatbot-bridge-cache`（可用 `BRIDGE_CACHE_DIR` 覆盖），
  不安装 Homebrew 包、不改用户 `PATH`、不读写用户 `go env`（`GOENV=off`）；
  下载 Go tarball 与 frida-core-devkit 后均校验 SHA256；
- 用缓存内的独立 `GOCACHE`/`GOMODCACHE`/`GOPATH` 下载 Go modules；
  默认 `GOPROXY` 失败时自动改用 `https://goproxy.cn,direct` 重试；
- 以 CGO 编译：`CGO_CFLAGS=-I<devkit>`、`CGO_LDFLAGS=-L<devkit>`（`-lfrida-core` 由 `frida-go`
  自带），`CC=$(xcrun --find clang)`、`SDKROOT=$(xcrun --show-sdk-path)`；
  构建参数 `-trimpath -buildvcs=false -ldflags="-s -w"`；
- 自检：产物必须是 Mach-O arm64，`onebot -h` 必须正常；若仓库存在 `hook/script.js`，
  还会对比它与 `bridge/script.js` 的 SHA256，不一致时给出同步警告；
- 运行 `go test ./...`（`bridge/*_test.go`：鉴权/参数校验/WS 动作、入站归一化、`HandleMsg` 字段保留、
  通讯录、protobuf、SNS、工具函数）；`BRIDGE_SKIP_TESTS=1` 可跳过。

干净重建与缓存控制：

```bash
rm -rf bridge/onebot /tmp/chatbot-bridge-cache   # 下载与编译全部重来（约 70 秒，取决于网络）
BRIDGE_CLEAN=1 scripts/build_bridge.sh           # 只清构建缓存，保留已下载工具链
BRIDGE_CACHE_DIR="$PWD/.cache-bridge" scripts/build_bridge.sh   # 自定义缓存目录（如 CI）
```

### 1.3 产物

Frida 以**静态库**链接进可执行文件，产物是单个 Mach-O arm64 可执行文件
（`file` 显示 `Mach-O 64-bit executable arm64`），只依赖系统库/Frameworks，没有
`libfrida-core.dylib`；代价是二进制较大（strip 后约 95 MB）。构建成功后 `bridge/` 结构：

```
bridge/
├── onebot              # 构建产物（被 .gitignore 忽略，发布前需构建）
├── script.js           # 运行时读取；由 hook/script.js 同步（scripts/sync_hook_script.sh）
├── *.go / go.mod / go.sum   # 上游源码 + 本项目修改/新增（清单见 NOTICE）
├── sns*.go / sns_*_test.go  # 朋友圈状态层/HTTP/protobuf/媒体下载与测试
├── proto/                   # gRPC/protobuf 生成代码（编译必需）
├── LICENSE / NOTICE         # 上游 GPL-3.0；NOTICE 列出已修改与新增文件
└── *_test.go           # 本项目新增的 httptest 测试（不连 Frida）
```

`bridge/log/macos.log` 是 `run_bridge.sh` 的默认日志（相对 `-log_file`，已忽略）；
App 启动时把 `-log_file` 指向 `~/Library/Logs/WeChatAI/bridge/macos.log`（见 §6 第 10 条）。

> **script.js 同步**：`bridge/script.js` 是 `hook/script.js` 的运行时副本，不要手改。
> 修改 hook 脚本后运行 `bash scripts/sync_hook_script.sh`；`bash scripts/check.sh`
> 会校验两者一致。具体改动与版本说明见 [`bridge/NOTICE`](../bridge/NOTICE)，
> 文档里不要写死文件大小或 SHA256（会随脚本迭代过期）。

### 1.4 常见构建错误

| 现象 | 原因/处理 |
| --- | --- |
| `fatal error: 'stdlib.h' file not found` | 未设置 SDKROOT 或未安装 CLT。脚本已 `xcrun --show-sdk-path`；手工构建时需 `export SDKROOT=...`。 |
| `ld: warning: ignoring duplicate libraries: '-lfrida-core'` | 同时传了 `-lfrida-core`（frida-go 已带）。无害；脚本只传 `-L` 避免该警告。 |
| Go 模块下载超时 | 脚本会回退 `goproxy.cn`；也可手动 `GOPROXY=https://goproxy.cn,direct scripts/build_bridge.sh`。 |
| frida devkit 下载失败 | 从 §1.1 的 release 手动下载 `frida-core-devkit-17.8.0-macos-arm64.tar.xz`，放到 `/tmp/chatbot-bridge-cache/`（保留原文件名）后重跑。 |
| `go: command not found` | 脚本自带 Go，不会用系统 `go`；直接运行脚本即可。 |

---

## 2. 运行

### 2.1 前置条件

1. 已通过 `tools/manage_wechat.sh install` 给 `WeChat.app` 注入 Frida Gadget，
   Gadget 已监听（默认端口见 §2.2，可在 App 设置中改）；
2. 微信已启动，且 Gadget 已启动；
3. Hook 版本 JSON 存在（默认路径见 §2.2 的 `--wechat-conf`）；
4. 微信图片临时目录存在（`.../xwechat_files/<wxid>/temp/<...>/Img/`），
   App 侧会探测/创建；脚本会检查；
5. `bridge/onebot` 与 `bridge/script.js` 已构建/同目录存在。

> `onebot` 用 `os.ReadFile("./script.js")` 读取脚本，**当前工作目录必须是 `bridge/`**。
> `scripts/run_bridge.sh` 会自动 `cd`；App 启动子进程时把 `currentDirectoryURL` 设为
> bridge 资源目录。

### 2.2 脚本参数

```bash
scripts/run_bridge.sh [选项]
```

| 环境变量 | 命令行参数 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `WECHAT_CONF` | `--wechat-conf` | `hook/versions/4_2_0_17_mac.json` | Hook 版本 JSON |
| `PORT` | `--port` | `58080` | HTTP/WS 监听端口；`run_bridge.sh` 固定只绑定 `127.0.0.1`（App 用设置里的 host，默认 `127.0.0.1`） |
| `TOKEN` | `--token` | 随机生成 64 字符 hex | OneBot token；HTTP 鉴权用 |
| `IMAGE_PATH` | `--image-path` | 无（**必填**） | 微信图片/语音/视频/文件临时目录，必须已存在 |
| `MEDIA_DIR` | `--media-dir` | `$HOME/Library/Application Support/WeChatAI/media` | 入站图片获取的落盘根目录；只写该目录，不写 app bundle |
| `GADGET_ADDR` | `--gadget-addr` | `127.0.0.1:27042` | Frida Gadget 地址 |
| `LOG_LEVEL` | `--log-level` | `info` | `debug` / `info` / `warn` / `error` |
| `BRIDGE_BIN` | `--bin` | `bridge/onebot` | 自定义可执行文件 |
| `HOOK_SEND_DISABLED` | —（仅环境变量） | `true` | 强制关闭 4.1.15 主动发送；显式 `false` 才允许 Hook/JSON 决定 |

除 `HOOK_SEND_DISABLED`（仅环境变量）外，每个环境变量都有等价的命令行参数，示例：

```bash
IMAGE_PATH="$HOME/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_xxxxxxxx/temp/2026-10/Img" \
  scripts/run_bridge.sh --port 58081 --token "$(openssl rand -hex 32)" \
  --wechat-conf hook/versions/4_2_0_17_mac.json
```

脚本会先做前置检查（二进制、`script.js`、版本 JSON、`IMAGE_PATH`、端口占用），
打印脱敏后的配置，然后 `exec`：

```bash
bridge/onebot \
  -type=gadget \
  -gadget_addr=127.0.0.1:27042 \
  -wechat_conf=/path/to/hook/versions/4_2_0_17_mac.json \
  -receive_host=127.0.0.1:58080 \
  -token=<token> \
  -conn_type=websocket \
  -image_path=/path/to/.../xwechat_files/<wxid>_<suffix>/temp \
  -media_dir="$HOME/Library/Application Support/WeChatAI/accounts/<wxid>/media" \
  -log_level=info
```

与 [`docs/architecture.md`](architecture.md) §3.1 是同一套 flag：本节示例只列 `run_bridge.sh`
会传的部分，App 直连启动时固定传 `-log_file` 与 `-send_interval=100`、已知账号时按需传 `-self_id`。已识别微信账号时，
App 强制把 `-image_path` / `-media_dir` 指向当前账号目录（忽略用户配置的
`onebot.imagePath`）；未识别账号时才使用显式路径/自动探测。

### 2.3 行为说明

- 启动顺序：解析参数 → 初始化日志 → **连接 Frida Gadget 并加载 `script.js`** →
  启动发送 worker → HTTP/WS 监听。**Gadget 连不上时进程立即退出（exit 1），
  不会开监听端口，也不会重试**。
- 日志同时输出到 stdout 与 `-log_file`（默认 `bridge/log/macos.log`；App 指到
  `~/Library/Logs/WeChatAI/bridge/macos.log`）。lumberjack 轮转：单文件 100 MB，
  最多 10 份，保留 30 天。
- `-send_interval`（默认 1000ms，App 运行期传 100）只约束真正发往微信的消息；
  入站事件与发送回执立即写出，不做节流。事件级日志为 Debug 级，只记录字节长度与
  最多 256 字符的截断预览；默认 `-log_level=info` 下不产生每事件日志（排障时显式
  `-log_level=debug`），Warn/Error 不受影响。
- 上游启动时会把完整 token 打印到 stdout（`OnebotToken <token>`），鉴权风险见 §7。
- 按 `Ctrl-C`/SIGTERM 时上游会清理 Frida script/session/device 后退出。
- Hook 脚本的诊断/实验环境变量（如 `HOOK_DEBUG=1`）由 `run_bridge.sh` 原样透传，
  完整清单见 `hook/script.js` 顶部。`run_bridge.sh` 默认导出 `HOOK_SEND_DISABLED=true`
  强制关闭主动发送；只有显式 `HOOK_SEND_DISABLED=false` 才允许 Hook 脚本按 JSON 的
  `enableSend`/`req2bufSendMode` 执行。App 直接启动 binary 时建议同样注入
  `HOOK_SEND_DISABLED=true`（安全默认，需开发送时再关）。
- 朋友圈（SNS）没有独立命令行参数：`/sns/*` 是否可用由 `-wechat_conf` 指向的版本 JSON 的
  `snsEnable` / `snsWrite` / `snsProbe` / `snsReadMode` 决定，App 启动 bridge 前按设置合并生成运行期
  配置；仓库 JSON 默认 `snsEnable=false`，因此默认所有 `/sns/*` 返回 404。当前只有
  `hook/versions/4_2_0_12_mac.json` 与 `4_2_0_17_mac.json` 含 SNS 锚点；其它版本即使被 App 运行期
  写入 `snsEnable=true`，具体 op 也会返回 503 `sns_channel_unconfigured`（见 [`sns.md`](sns.md) §6.1）。

---

## 3. 接口契约（与 `docs/architecture.md` §3 核对）

### 3.1 WebSocket 事件（bridge → App）

- 地址：`ws://127.0.0.1:58080/ws`；与 HTTP 接口共用 OneBot token：握手时必须带
  `Authorization: Bearer <token>`（或 `?token=<token>`），用常量时间比较；`-token` 为空
  （未配置鉴权）时放行。App 自 1.6.0 起在 WS 握手带 Bearer 头，旧版 App（不带该头）
  需要先把 bridge `-token` 留空才能连接。
- 事件在完成身份归一化与入站图片登记后**立即**写出（不等待 `-send_interval`），WS 写由
  `wsWriteMu` 串行化；HTTP 推送同样立即发出。
- 上游通过 `json.Marshal(WechatMessage)` 发送紧凑 JSON；`message` 为数组；
  `sender`、`group_id`、`raw_message` 等在 protobuf 解析路径上通常存在。实际字段集合比
  契约示例多 `post_type`、`msgsource`、`show_content`；解析方应忽略未知字段。
- **`time` 的单位是毫秒**（`time.Now().UnixMilli()`，13 位），不是契约示例中的
  10 位秒级时间戳；App 解析时需按毫秒处理或按位数兼容。
- `message[]` 类型：`text`（`data.text`）、`image`（`data.url` 为 `file://...`，
  `data.text` 保留微信 XML）、`record`/`voice`、`video`、`file`、`face`。
  legacy `HandleMsg` 路径的媒体事件在推送前会同步下载/落盘，失败时整条事件可能被丢弃（见 §6）。
- 入站图片（4.1.15 起）：hook 只给文本占位 `[图片]`，图片 XML 在 `raw_message`。
  bridge 在推送前解析 `<img>` 的 `aeskey` / `cdnmidimgurl` / `cdnthumburl` /
  `cdnthumbaeskey` / `md5` / `length`，按 `message_id` 登记 mid → thumb 下载候选，并把
  文本占位替换成**无 data 的** `{"type":"image","data":{}}`。新增结构化字段不携带
  aeskey/CDN key，运行日志也不打印；`raw_message` 仍保留原始图片 XML（与历史行为一致）。
  实际下载发生在 App 调用 `POST /fetch_image` 时（按需，见 §3.4），不会阻塞事件推送；该链路已在
  微信 4.2.0.5 真机验证。4.2.0.17 / 4.2.0.12 / 4.2.0.9 / 4.2.0.5 / 4.1.15 的入站路径不再同步下载媒体，
  推送只带结构化占位，下载由 App 按需发起。

### 3.2 WebSocket 动作（App → bridge）

支持的动作（`websocket.go`）：

| action | 响应 | 说明 |
| --- | --- | --- |
| `get_login_info` | `{"echo":..., "status":"ok", "data":{"user_id":..., "nickname":...}}` | 上游 `nickname` 直接填 `wxid`（不是昵称）；`user_id` 优先取 App 传入的 `-self_id`，缺失时从 `image_path`/已收到事件推断。App 的账号档案以 resolver 为准，回包用于运行期确认。 |
| `get_group_member_info` | `{"echo":..., "status":"ok", "data":{"nickname":...}}` | 只查进程内缓存（曾收到该群该成员消息）；未命中时 `nickname` 为空字符串（不是 `null`）。 |
| `get_contact_directory` | `{"echo":..., "status":"ok", "data":{"ok":true,"users":{...},"groups":{...}}}` | 本机**只读**读取通讯录后的目录；失败回 `{"status":"failed","error":...}`。 |
| `send_private_msg` / `send_group_msg` | **不回包** | 发送结果只写日志；成功/失败不会产生 echo/响应。App 应以 HTTP 发送为主通道。 |

未列出的 action 会被静默忽略。同一时刻只接受一个 WS 连接：已有活动连接时新连接被拒绝
（HTTP 409），避免第二个连接抢占事件流；读限制 8 MB、写超时 5 s，写失败会关闭连接。
WS 入站消息同样受 token 约束；未连接期间的事件会被丢弃（仅记日志）。

### 3.3 HTTP 发送接口

```http
POST http://127.0.0.1:58080/send_private_msg
Authorization: Bearer <token>
Content-Type: application/json

{"user_id":"wxid_x","message":[{"type":"text","data":{"text":"hi"}}]}
```

- 两个路径 `/send_private_msg`、`/send_group_msg` 走**同一个 handler**；
  路径本身不决定私聊/群聊，实际由 body 中的 `user_id`/`group_id` 决定。
- 鉴权：`Authorization` 必须是 `Bearer <token>`。注意上游用
  `strings.TrimPrefix` 解析，**恰好等于 token、不带 `Bearer ` 前缀的 header 也会通过**；
  这是上游的宽松行为，未修改。
- 成功：HTTP 200 `{"status":"ok"}`；请求含语音段时 200 回包为
  `{"ok":true,"duration_ms":...}`（见 [`voice.md`](voice.md)）；失败：HTTP 500
  `{"status":"failed","error":"..."}`。
- 参数校验：非 POST → 405（纯文本）；token 缺失/错误 → 401（`未授权`）；
  JSON 无效或 `message` 为空、`user_id`/`group_id` 都缺失 → 400（`无效的 JSON`/
  `参数缺失`，纯文本）。
- 文本分片会被拼接后一次发送；`at` 元素仅群聊且能解析到该成员昵称时生效
  （进程内缓存未命中会回退通讯录目录），否则被忽略；
  媒体元素使用 `data.file`（支持 `base64://...`）；`record` 会转成 `voice` 发送。
- HTTP handler 会把消息交给发送 worker 并等待结果；`conn_type=websocket` 不影响 HTTP 发送。
- 额外的未鉴权调试端点：`/test_ws`（向当前 WS 连接写任意 body）以及
  `net/http/pprof` 注册的 `/debug/pprof/*`。它们只在 127.0.0.1 上暴露，详见 §7。

### 3.4 入站图片获取接口

```http
POST http://127.0.0.1:58080/fetch_image
Authorization: Bearer <token>
Content-Type: application/json

{"message_id":"<OneBot message_id>"}
```

- 鉴权与 `/send_*` 一致（Bearer + `hmac.Equal`）；非 POST → 405，未授权 → 401，
  `message_id` 缺失/未登记/已过期 → 400，下载失败 → 502。
- 成功：HTTP 200

  ```json
  {"status":"ok","data":{"file":"file:///Users/<user>/Library/Application%20Support/WeChatAI/media/2026-10-23/<name>.jpg","message_id":"..."}}
  ```

- 失败：HTTP 502 `{"status":"failed","error":"中文原因"}`。
- 处理流程：按 `message_id` 查登记 → 并发槽（上限 2）→ 对 mid/thumb 候选逐个触发微信
  CDN 下载 → 等待下载分片稳定 → 用 XML 的 `aeskey` AES-ECB 解密 → 校验图片魔数 →
  写入 `<media_dir>/<yyyy-MM-dd>/<md5>.<ext>`（缩略图回退加 `-thumb` 后缀）→ 返回
  `file://` 路径。单次总预算约 12 秒；成功/失败都会移除该 `message_id` 的登记（不重复下载）。
- 图片只写入 `-media_dir`（`filepath.Rel` 校验，拒绝目录穿越），绝不写入 app bundle；
  日志不打印 aeskey / CDN key / XML。
- 该接口**不会**主动下载：该会话的「获取图片」关闭时 App 不会调用，因此不会发起新的下载
  （已在途的单次请求可能完成）。

### 3.5 朋友圈（SNS）接口

`bridge/sns.go`（状态/开关/缓存）、`bridge/sns_http.go`（HTTP 层）、`bridge/sns_proto.go`（protobuf）、
`bridge/sns_media_download.go`（图片 CDN 下载/解密）实现朋友圈旁路；完整字段、错误码与阶段状态见
[`sns.md`](sns.md) §3–§5：

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/sns/status` | 只读就绪状态：`ready` / `seed_ready` / `write_ready` / `comment_ready` / `enabled` / `write_enabled` / `passive` / `read_mode` / `captured` / `body_captured` / `account` / `last_error`；`write_ready` 对应 post 发布样本，`comment_ready` 对应 0xD5 评论/点赞句柄，二者独立 |
| POST | `/sns/timeline` | 时间线分页；返回 `posts` / `cursor` / `source`（`native` 或 `passive` 缓存）。首页刷新在已捕获真实请求体时原生发送，未捕获时直接读被动缓存；返回前把 sync 评论按 `comment_id` 补到原生评论末尾（count 取 max、重算 `comments_truncated`） |
| POST | `/sns/detail` | 单条详情；主动补齐不可用（Mac UI 不触发 0xd2 objectdetail，路线已放弃），请求失败后回退时间线缓存（`source=cache`，见 sns.md §4.3/§8）；sns.db 只读评论补全已真机端到端验证（正文 + P7 自动回复） |
| POST | `/sns/media` | 图片下载到当前账号 `sns-media/`，返回 `file://` 路径（复用已解密文件时顶层返回 `cached=true`）；时间线注册 raw media（url/key/token）+ ISAAC-64 解密，同参数复用已解密文件，网络错误/5xx 重试一次 |
| POST | `/sns/sync` | 增量同步；返回 `events` / `commands` / `cursor`。`CmdBuf` 先剥外层信封 `{1: len, 2: payload}`：cmd45（SnsObject）正常解为新动态；cmd46（SnsActionGroup）的 Type 1/2/3 解为点赞/评论，**Type=11 只产 `sns_comment_hint`**（无正文，不写缓存；hint 本身不能直接自动回复）。Mac UI 不触发 0xd2，回复正文由 sns.db 只读补全，32 位 comment_id 已确认可作 reply_comment_id；其余未知命令计入 `unsupported_cmd_count` |
| POST | `/sns/db/schema` | sns.db 只读 schema 探针（仅 `snsProbe=true` 或版本 JSON `snsDbRead=true`）；返回脱敏 `tables`/`page_count`/`key_source`/`decrypt_ms`/`wal_applied`，不返回 key/内容；解密切到容器 tmp、查完删除。冷启动无 key 时 `sns_db_key_missing`（打开朋友圈触发 CCCrypt 后回灌）；timeline 补全在 `snsEnable=true` 时自动启用，`snsDbRead=true` 支持仅 DB 模式；真机已端到端验证（读到回复正文，P7 自动回复 c<id3>、页面评论闭环；仅 4.2.0.17） |
| POST | `/sns/db/comments` | 仅 `snsProbe=true` 的调试卷；请求 `{"post_ids":["<uint64>"]}`（1–50），返回 `comments{post_id:[snsCommentJSON]}`；不返回 key/原始行。timeline 自动补全不依赖该端点 |
| POST | `/sns/post`、`/sns/comment`、`/sns/like`、`/sns/objectop` | 写接口：写开关默认关时 404。post 文字发布（partial/public 联调）已真机验证；comment 为 App 评论/回复入口（`confirm:true`，需 0xD5 句柄，缺失时 503 `sns_comment_unavailable`），回包与写前缓存合并并尽力返回 `comment_id`；like/objectop 只有接口与用例，App 暂不调用（hook 任务表未配置 0xDA objectop 锚点，取消赞/删除类请求当前返回 503 `sns_channel_unconfigured`） |

- 所有 `/sns/*` 仅支持 POST、要求 Bearer token；功能关闭时 404，未授权 401，微信未就绪映射
  503、回包/发送失败 502、超时 504（响应统一 `{"status":"failed","code":...,"error":"..."}`）。
- **DB 补全评论字段**：`comment` 可带可选 `comment_id_confirmed:true` 与 `source:"db"`；4.2.0.17 的
  `SnsMessage_tmp3.comment_id`（32 位，真机实测）已手动抓包确认可作 `/sns/comment` 的 `reply_comment_id`，
  `comment64_id` 有效时也 confirmed。`comment_id_unconfirmed` 只保留给旧 schema/回退；两列均为 0 时
  comment_id 为空。原生评论直接信任服务端 ID（短数字 3/35/67/99/131 正常）。
- **评论/点赞句柄**：hook 的 slot13 捕获覆盖 0xD3/0xD6/0xD1/0xD5；首次评论前需用户在微信里手动点一次
  评论一次（点赞也可能），`comment_ready` 才会变 true（样本随 `sns-capture.json` 持久化，同一微信进程内可恢复）。
- **不控制微信界面**：读取在主动发送不可用时回退 `source=passive`（用户手动打开一次朋友圈后缓存）；
  bridge 不截图、不点击、不模拟刷新。
- **WS 事件**：App 已预留 `sns_new_post` / `sns_comment` / `sns_like` 帧解析，但 **bridge 当前不推送**
  这类 WS 帧；同步内容以 `/sns/sync` 返回为准，避免把协议设计误当已实现能力。

---

> **语音接口**：`POST /fetch_voice`、`POST /send_voice` 与 `GET /voice_status` 的完整契约、
> 状态与 4.2.0.17 / 4.2.0.12 / 4.2.0.9 / 4.2.0.5 限制见 [`voice.md`](voice.md)。入站下载默认
> `fileType=15` 已真机验证；出站经官方 SILK SDK 24k 编码后由 R3 原生发送（App 运行期按
> 「R3 原生发送」开关注入 `r3VoiceSend`），未开启或句柄/门禁未就绪时 App 自动降级文字；
> `/voice_status` 提供登录稳定倒计时与句柄状态。

## 4. 验证记录

- **构建与测试**：从完全干净状态（删除 `bridge/onebot` 与 `/tmp/chatbot-bridge-cache`）重跑
  `scripts/build_bridge.sh` 成功：下载并校验 Go 1.25.14 与 devkit 17.8.0，编译、`-h` 自检与
  `bridge/*_test.go` 全部通过（19 个 `_test.go`、Go 312 项用例 = 180 顶层 + 132 子测试，0 失败）；
  Swift 886 项执行（884 通过 / 2 跳过 / 0 失败，41 个测试文件）；Python sidecar 72 项（2026-11-09 基线）。
  `script.js` 的 4.1.15 / 4.1.12 模板渲染结果 `node --check` 均通过。
- **SNS 同步 CmdBuf**：`bridge/sns_sync_envelope_test.go` 覆盖外层信封 `{1: len, 2: payload}`、cmd45 与
  cmd46 的 Type 1/2/3 解码、评论合并去重与 timeline `reply_to_user_id`；解码结构来自 2026-11-09 真机样本。
  真机同时确认 Type=11 回复无正文，只产 `sns_comment_hint`（不计 unsupported、不伪造正文）；这是已知限制，不代表回复已打通。
- **sns.db 只读补全**：`sns_db_schema_test.go` 覆盖 schema 探针 404/Bearer/keys 剥离/key_missing；
  `sns_db_comments_test.go` 覆盖 signed `feed_id`、`SnsMessage_tmp3` 行映射、timeline 合并（原生优先/只补缺/
  count/truncated）、DB 不可用静默降级、同一 32 位 `comment_id` 的多条正文保留；`/sns/db/comments` 仅 `snsProbe`。
  真机已端到端验证：读到两条回复正文，P7 自动回复 c<id3>（reply_to=<id>、reply_to_user_id=<uid>）、页面评论；边界仅 4.2.0.17/依赖 key 缓存。
- **无 Gadget**：`-gadget_addr` 指向无监听端口时，进程约 0.07 秒内 `exit 1`，打印
  `FATAL ... 附加失败`，不挂起、不开端口、不重试（退出前会先创建 `./log/macos.log`）。
  因为 HTTP 监听在 Gadget attach 成功之后才启动，无 Gadget 时无法对真实进程测 401。
- **鉴权与参数校验**：`bridge/http_auth_test.go` 用 `httptest`（不连 Frida、不占真实端口）
  覆盖 405/401/400 与 WS `get_login_info` 回包；并在真实 bridge 进程上用 curl 复测
  `GET` → 405、无/错误 token → 401、非法 JSON / 空 `message` / 缺目标 → 400，与 §3.3 一致。
  成功发送路径由真机联调覆盖（本项目不主动发送真实消息）。
- **运行脚本**：无 Gadget 时同步输出配置并快速退出（exit 1）；`--wechat-conf`/`--image-path`
  的相对路径会被转为绝对路径；缺少版本 JSON、`IMAGE_PATH` 或二进制时给出明确中文错误。

---

## 5. 与上游差异

完整清单以 [`bridge/NOTICE`](../bridge/NOTICE) 为准（逐文件列出与上游一致、已修改与新增的
文件及原因）。概要：

1. **构建方式**：上游 `setup_frida_and_build.sh` 使用 `go build`（未 strip）；
   本项目用 `-trimpath -buildvcs=false -ldflags="-s -w"`，产物约 95 MB（上游约 133 MB）。
   调用方只是 App 启动进程，不受影响；如需保留符号调试，去掉这些参数即可。
2. **已修改文件**：`main.go`（`-self_id`、`-log_file`、`-media_dir`、通讯录 DB key 回灌、
   `/fetch_image` 路由）、`logger.go`（`-log_file`）、`param.go`（自消息方向与 `pat_*` 字段、
   `media_dir`）、`incoming.go`（事件归一化、非法群 ID 清洗、通讯录昵称补全、入站图片登记）、
   `websocket.go` / `http.go`（`get_contact_directory`、`at` 昵称回退、`/fetch_image`）、
   `worker.go`（原生发送路径跳过 legacy 缓冲回复）、`msg.go`（下载代次）；逐文件原因见 NOTICE。
3. **本项目新增**：`contact.go`（通讯录目录与本地受限密钥缓存）、`media.go`（入站图片登记、
   按需下载/解密/落盘）、`r3seed.go`（原生发送状态按 PID 持久化）、`sns.go` / `sns_http.go` /
   `sns_proto.go` / `sns_media_download.go`（朋友圈状态层、HTTP、protobuf 与媒体下载）、`NOTICE`、
   `.gitignore`、`*_test.go`、`UPSTREAM_README.md`（上游 `readme.md` 重命名）与 `Makefile.upstream`（仅参考）。
4. **工程脚本**：`scripts/build_bridge.sh`（下载/校验/离线缓存/Go 工具链隔离/构建自检）
   与 `scripts/run_bridge.sh`（参数化启动与前置检查）。
5. **`script.js`**：唯一被修改的上游脚本，已同步 `hook/script.js` 的版本化适配（入站消息、原生发送、
   通讯录、SNS 捕获/发送；4.1.12 / 4.1.15 / 4.2.0.5 / 4.2.0.9 / 4.2.0.12 / 4.2.0.17）。
   其中 4.2.0.17 版本文件自 4.0.0 起随发布包分发。
   它以 `hook/script.js` 为唯一事实来源，细节见 NOTICE。

---

## 6. 已知限制

1. **Gadget 必须先就绪**：bridge 不重试 Gadget 连接；失败即退出，需要 App/用户重启。
2. **`script.js` 必须与 binary 同目录且以该目录为 cwd**：否则加载脚本阶段直接退出。
3. **`image_path` 启动时不校验**：上游只在媒体写入/下载时用到它，`os.MkdirAll`
   可能自动建目录；若目录不可写/沙箱不允许，媒体相关事件会失败。`run_bridge.sh`
   会提前检查目录存在，App 侧也应探测/创建。
4. **`time` 为毫秒**（见 §3.1），与架构示例的秒级值不同。
5. **WS 单连接**：断线期间事件丢失；重连会替换连接。WS `send_*` 无 echo，
   发送结果不可靠，App 应使用 HTTP。
6. **HTTP `Authorization` 解析宽松**：无 `Bearer ` 前缀但等于 token 也会通过。
7. **legacy 媒体同步下载**：图片/文件/视频/语音在事件推送前下载到 `image_path`；
   下载失败会导致该条事件不推送；大文件会阻塞该事件。
8. **昵称缓存依赖历史消息**：`get_group_member_info` 只查进程内缓存，`at` 在该缓存
   未命中时会回退通讯录目录；冷启动且通讯录目录不可用时，两者都可能缺失。
9. **`myWechatId` 推断**：优先用 App 传入的 `-self_id`；未传时从 `image_path` 的
   `xwechat_files/<wxid>_xxx/...` 推断，路径格式不符时可能为空或截断。
10. **日志含聊天内容**：事件日志会记录完整事件 JSON；日志文件
    （`run_bridge.sh` 默认 `bridge/log/`，App 默认 `~/Library/Logs/WeChatAI/bridge/`）
    应按敏感数据保护并定期清理。
11. **静态链接 Frida**：二进制约 95 MB，冷启动/内存占用高于普通 Go 程序；
    未在真实微信 Gadget 环境下测量 RSS（目标 <80 MB 需联调确认）。
12. **无健康检查端点**：只能通过 WS 是否可连接判断；`/debug/pprof` 与 `/test_ws`
    不属于契约，勿依赖。
13. **`script.js` 是手同步副本**：Hook 脚本迭代时容易忘记同步，发布前务必对比
    `hook/script.js` 与 `bridge/script.js` 的 SHA256（见 §1.3）。
14. **`pat` 出站段保留但产品不再使用**：bridge 的 HTTP/WS 仍能解析 `{"type":"pat"}`
    并调用 Hook 的拍一拍发送，属于历史/实验路径；App 已移除 `sendPat`，
    `r3PatSend` 永久保持 `false`，不要启用原生回拍。
15. **入站图片获取**：优先用微信收到图片后**自然下载**的分片，没有分片时才主动触发，触发被
    拒绝也不直接失败而是继续等分片。按图片自身结束标记（JPEG EOI / PNG IEND 等）裁掉 AES
    补齐字节，数据不完整时不落盘；4.2 的 mid 图常见 HEVC，无 HEVC 解码时自动改用 JPEG 缩略图。
    限制：只处理实时入站图片（历史消息不回填），只支持图片（不含表情/语音/视频/文件），
    主动触发带 10 秒超时。
16. **朋友圈写通道（post 已真机验证部分可见）**：timeline 与 post 的合成发送均已真机验证
    （复用真实 service + closure + 捕获请求体；post 逐字段保留模板未知字段 + ClientCheckDat）；
    comment 发送已真机验证（2026-11-08），like/objectop 仍待验证。写操作默认关；App 无手动发布入口，
    仅自动发布调度器在写开关下调用。
17. **朋友圈同步（CmdBuf 信封已解码，回复仍受限）**：`/sns/sync` 先剥 `CmdBuf` 外层信封再解码；cmd45 正常，
    cmd46 的 Type 1/2/3 产生点赞/评论事件，评论并入缓存并由 timeline 合并。真机样本（2026-11-09）同时确认
    **好友回复机器人评论为 Type=11、无 Content/CommentID，hint 本身只触发静默刷新，不能直接自动回复**；
    正文由 sns.db 只读补全，32 位 comment_id=<id> 已确认可作 reply_comment_id，P7 自动回复已生成 c<id3>、
    页面闭环。边界：仅 4.2.0.17、依赖 sns key 缓存、其它 schema 可能不同。`bridge/sns_sync_envelope_test.go` 覆盖信封/Type 1-3/合并/去重；主动同步
    已实现请求体重放（首次用捕获体、之后替换 KeyBuf），是否稳定触发 0xd6 仍受微信时机影响。WS 推送未实现，
    App 另有时间线 diff 的 `source=fallback` 兜底，不做界面自动化。

---

## 7. 安全

- **仅回环**：`run_bridge.sh` 固定 `-receive_host=127.0.0.1:<port>`；App 用设置里的
  OneBot host（默认 `127.0.0.1`，设置页可改），不要把 host 改成 `0.0.0.0`/局域网地址。
- **HTTP token**：`/send_*`、`/fetch_image`、语音接口与 `/sns/*` 要求 `Authorization: Bearer <token>`；
  token 建议用 `openssl rand -hex 32` 生成（App 首次启动机器人时生成 64 字符 hex）。
  `run_bridge.sh` 未提供 token 时会随机生成并打印。
- **token 可见性**：上游启动时把完整 token 打印到 stdout，且 token 通过命令行参数
  传给进程，同机用户可用 `ps` 看到；仅适用于单用户桌面环境。App 日志如需脱敏，
  应在读取 bridge stdout 时过滤 `OnebotToken`。
- **未鉴权端点**：`/test_ws`、`/debug/pprof/*` 无鉴权（`/test_ws` 可向当前 App WS
  连接注入任意 JSON）。它们默认只监听 `127.0.0.1`（由 `-receive_host`/App host 决定）；
  本机其他进程仍可访问，因此不要在不受信任的多用户机器上运行。
- **日志**：`bridge/log/macos.log` 含消息内容，轮转上限 100 MB × 10、保留 30 天。
  入站图片获取的日志只记 `message_id`、字节数与失败原因，**不记** aeskey / CDN key / XML。
- **媒体写入边界**：`/fetch_image` 只写 `-media_dir`（默认
  `~/Library/Application Support/WeChatAI/media`），写入前用 `filepath.Rel` 拒绝
  `..`/绝对路径越界；不会写 app bundle（避免破坏 ad-hoc 签名）。
- **许可证**：本项目是 GPL-3.0 衍生作品。分发 App/二进制时需按 GPL-3.0 提供
  `bridge/` 对应源码（含本项目修改），并保留 `LICENSE`、`NOTICE`。
  Frida 静态链接遵循 wxWindows Library Licence 3.1 的二进制例外；Go module
  依赖各自许可证见 `go.sum` 对应模块。

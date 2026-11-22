package main

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"runtime/debug"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

// logPreviewMaxRunes 是事件调试日志预览的最大字符数。
// 历史回放/批量消息时不打印完整事件 JSON，避免大量字符串分配与磁盘 IO
// （App 还会消费 bridge stdout，完整 payload 会放大到 SQLite/UI 刷新）。
const logPreviewMaxRunes = 256

// wsReadLimit 单条 WS 消息上限（8MB）：入站动作可能带 base64 图片，
// 同时防止异常客户端用超大帧把 bridge 内存打爆。
const wsReadLimit = 8 << 20

// wsWriteTimeout 单次 WS 写超时：对端不读/半开时 WriteJSON 会永久阻塞并一直
// 持有 wsWriteMu，后续所有事件推送都会卡死，因此每次写都设置截止时间。
const wsWriteTimeout = 5 * time.Second

// wsConnWait 等待旧连接退出的窗口：App 断线重连时旧连接 handler 可能尚未返回，
// 直接判「已有连接」会误拒正常重连；超过窗口仍被占用才拒绝新连接。
const wsConnWait = 300 * time.Millisecond

// wsPingInterval 是服务端 ping 周期，wsReadTimeout 是读空闲上限（默认 2×ping）。
// 半开连接（对端休眠/进程被杀/网络切换）上 ReadMessage 永远不会返回，全局 conn
// 一直非空，App 重连只会得到 409。服务端定时 ping、客户端回 pong 即续期读截止
// 时间；超过上限没收到 pong/入站消息就主动断开并清空全局 conn，让重连自愈。
// 两个值都是变量，便于 httptest 用毫秒级窗口覆盖。
var (
	wsPingInterval = 15 * time.Second
	wsReadTimeout  = 30 * time.Second
)

// truncateForLog 把 s 截断到最多 maxRunes 个字符（rune），超出部分以 "..." 结尾。
// 只用于日志预览，不改变任何实际发送/解析的数据。
func truncateForLog(s string, maxRunes int) string {
	if maxRunes <= 0 {
		return ""
	}
	runes := []rune(s)
	if len(runes) <= maxRunes {
		return s
	}
	return string(runes[:maxRunes]) + "..."
}

// logEventDebug 以 Debug 级别记录一条事件负载的「字节长度 + 截断预览」。
// 默认日志级别是 Info，此时直接返回，不为被丢弃的日志构造完整字符串。
func logEventDebug(msg string, data []byte) {
	if !Logger.logger.Debug().Enabled() {
		return
	}
	Debug(msg, "data_len", len(data), "preview", truncateForLog(string(data), logPreviewMaxRunes))
}

var upgrader = websocket.Upgrader{}
var conn *websocket.Conn

// wsConnMu 保护全局 conn 指针的读/写：Upgrade、连接退出、写失败都会改写它。
// 与 wsWriteMu（串行化写操作）分开，避免用「关闭中的连接」写数据。
var wsConnMu sync.Mutex

// wsWriteMu 串行化 WebSocket 写：gorilla/websocket 只允许一个并发 writer。
// 通讯录目录动作的同步回包与事件推送来自不同 goroutine，没有这把锁会触发
// "concurrent write to websocket connection" 并把连接打掉（2026-10-21 真机）。
var wsWriteMu sync.Mutex

// currentWSConn 在锁内读取全局连接，避免与 handleWebSocket 的清空/替换竞态。
func currentWSConn() *websocket.Conn {
	wsConnMu.Lock()
	defer wsConnMu.Unlock()
	return conn
}

// dropWSConn 关闭连接，并只在全局指针仍指向它时置空：
// 迟到的旧连接不能把重连后的新连接清掉。
func dropWSConn(c *websocket.Conn) {
	wsConnMu.Lock()
	if conn == c {
		conn = nil
	}
	wsConnMu.Unlock()
	_ = c.Close()
}

// acquireWSConn 把 c 登记为全局连接；已有活动连接时返回 false。
// 并发 Upgrade 时只有第一个能登记成功，避免第二个连接覆盖全局 conn。
func acquireWSConn(c *websocket.Conn) bool {
	wsConnMu.Lock()
	defer wsConnMu.Unlock()
	if conn != nil {
		return false
	}
	conn = c
	return true
}

// waitWSConnIdle 等待现有连接退出，返回 true 表示可以接受新连接。
func waitWSConnIdle() bool {
	deadline := time.Now().Add(wsConnWait)
	for {
		if currentWSConn() == nil {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// wsToken 读取 WS 握手 token：`Authorization: Bearer <token>` 或 `?token=`。
// 与 HTTP 侧一致，只接受 Bearer 前缀形式；两种方式都不带时返回空串。
func wsToken(r *http.Request) string {
	const bearer = "Bearer "
	if header := r.Header.Get("Authorization"); header != "" {
		if strings.HasPrefix(header, bearer) {
			return strings.TrimSpace(strings.TrimPrefix(header, bearer))
		}
		return ""
	}
	return strings.TrimSpace(r.URL.Query().Get("token"))
}

// wsAuthorized 校验 /ws 连接 token，防止任意本地进程订阅事件流/伪造动作。
// token 为空表示未配置鉴权（仅用于开发/测试；注意 http.go 对空 token 是一律 401，
// 两侧语义不同。scripts/run_bridge.sh 与 App 始终传非空 token，因此只影响手工以
// -token="" 直跑二进制的场景）；比较使用常量时间，避免计时侧信道。
func wsAuthorized(r *http.Request) bool {
	if config.OnebotToken == "" {
		return true
	}
	token := wsToken(r)
	if token == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(token), []byte(config.OnebotToken)) == 1
}

func wsWriteJSON(v any) error {
	wsWriteMu.Lock()
	defer wsWriteMu.Unlock()
	c := currentWSConn()
	if c == nil {
		return errors.New("连接为空")
	}
	// 写超时失败时关闭连接并清空全局指针，让读循环尽快退出、App 重连。
	_ = c.SetWriteDeadline(time.Now().Add(wsWriteTimeout))
	if err := c.WriteJSON(v); err != nil {
		dropWSConn(c)
		return err
	}
	return nil
}

func wsWriteMessage(messageType int, data []byte) error {
	wsWriteMu.Lock()
	defer wsWriteMu.Unlock()
	c := currentWSConn()
	if c == nil {
		return errors.New("连接为空")
	}
	_ = c.SetWriteDeadline(time.Now().Add(wsWriteTimeout))
	if err := c.WriteMessage(messageType, data); err != nil {
		dropWSConn(c)
		return err
	}
	return nil
}

// wsWriteControl 在 wsWriteMu 内写控制帧（ping），与数据帧共用同一把写锁，
// 避免 ping 与事件推送并发写坏 gorilla 连接。
func wsWriteControl(c *websocket.Conn, messageType int, data []byte) error {
	wsWriteMu.Lock()
	defer wsWriteMu.Unlock()
	deadline := time.Now().Add(wsWriteTimeout)
	return c.WriteControl(messageType, data, deadline)
}

// wsPingLoop 周期性给当前连接发 ping。写失败说明连接已半开/对端不读，
// 主动 dropWSConn 让读循环退出、App 重连不再被 409 卡住；stop 关闭即返回。
func wsPingLoop(c *websocket.Conn, stop <-chan struct{}) {
	ticker := time.NewTicker(wsPingInterval)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			if err := wsWriteControl(c, websocket.PingMessage, nil); err != nil {
				Error("WS ping 写入失败，关闭连接", "err", err)
				dropWSConn(c)
				return
			}
		}
	}
}

type OneBotWSMsg struct {
	Action string    `json:"action"`
	Echo   string    `json:"echo"`
	Params *WSParams `json:"params"`
}

type WSParams struct {
	Message interface{} `json:"message"`
	UserID  string      `json:"user_id"`
	GroupID string      `json:"group_id"`
}

func handleWebSocket(w http.ResponseWriter, r *http.Request) {
	if !wsAuthorized(r) {
		http.Error(w, "未授权", http.StatusUnauthorized)
		Error("WS 未授权")
		return
	}

	// 单连接：已有活动连接时拒绝新连接（HTTP 409），避免第二个连接覆盖全局
	// conn 后，事件被写进一个即将断开的 socket（App 只有一个 WS 客户端）。
	if !waitWSConnIdle() {
		http.Error(w, "已有活动连接", http.StatusConflict)
		Error("已有活动 WS 连接，拒绝新连接")
		return
	}

	c, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		Error("升级失败", "err", err)
		return
	}
	// 并发 Upgrade 竞态兜底：只允许一个连接成为全局连接。
	if !acquireWSConn(c) {
		Error("已有活动 WS 连接，关闭新连接")
		_ = c.Close()
		return
	}

	c.SetReadLimit(wsReadLimit)

	// 连接健康：读截止时间由 pong（以及每条入站消息）续期；ping 循环保证即使
	// App 长时间不发动作，也能发现半开连接。退出时先通知 ping 循环停止，再清空
	// 全局 conn，避免 ping 在锁内写一个已关闭的连接。
	pingStop := make(chan struct{})
	defer func() {
		close(pingStop)
		dropWSConn(c)
	}()
	_ = c.SetReadDeadline(time.Now().Add(wsReadTimeout))
	c.SetPongHandler(func(string) error {
		return c.SetReadDeadline(time.Now().Add(wsReadTimeout))
	})
	// App 每 20s 主动发一次 ping（OneBotClient.pingInterval）。收到 ping 也续期读
	// 截止时间，这样即使某些客户端/系统网络栈不回 pong，只要还有 ping 就不会被
	// 误判断线；回包保持 WebSocket 协议要求的 pong（替代 gorilla 默认处理器）。
	c.SetPingHandler(func(appData string) error {
		_ = c.SetReadDeadline(time.Now().Add(wsReadTimeout))
		return wsWriteControl(c, websocket.PongMessage, []byte(appData))
	})
	go wsPingLoop(c, pingStop)

	for {
		m := new(OneBotWSMsg)
		_, msgByte, err := c.ReadMessage()
		if err != nil {
			// 读空闲超时是最常见的「半开连接」形态：对端进程被冻结/休眠后
			// socket 没有 FIN/RST，只有读截止时间能发现。这里与普通断线区分日志，
			// 便于排障时判断是网络还是 App 主动关闭。
			var netErr net.Error
			if errors.As(err, &netErr) && netErr.Timeout() {
				Warn("WS 读空闲超时，主动断开连接", "timeout", wsReadTimeout)
			} else {
				Error("读取失败", "err", err)
			}
			break
		}
		_ = c.SetReadDeadline(time.Now().Add(wsReadTimeout))

		logEventDebug("收到消息", msgByte)
		err = json.Unmarshal(msgByte, m)
		if err != nil {
			Error("解析失败", "err", err)
			continue
		}

		// params 缺失时不能解引用（会 panic 丢连接）：需要参数的动作用失败回包，
		// 与 OneBot 的 status:failed 契约一致。
		if m.Params == nil {
			switch m.Action {
			case "get_group_member_info", "send_private_msg", "send_group_msg":
				Error("params 缺失", "action", m.Action)
				if err := wsWriteJSON(map[string]any{
					"echo":   m.Echo,
					"status": "failed",
					"error":  "params is nil",
				}); err != nil {
					Error("写入失败", "err", err)
					return
				}
				continue
			}
		}

		switch m.Action {
		case "get_login_info":
			err = wsWriteJSON(map[string]any{
				"echo":   m.Echo,
				"status": "ok",
				"data": map[string]any{
					"user_id":  myWechatId,
					"nickname": myWechatId,
				},
			})
			if err != nil {
				Error("写入失败", "err", err)
				return
			}
		case "get_group_member_info":
			// 未命中时返回空字符串而不是 null（docs/bridge.md §3.2）：sync.Map.Load 的
			// 第二个返回值不能丢，否则 map 里是 nil interface，JSON 编码成 "nickname":null，
			// 按 String 解析的 OneBot 客户端会解包失败。
			nickname := ""
			if value, ok := userID2NicknameMap.Load(m.Params.GroupID + "_" + m.Params.UserID); ok {
				nickname, _ = value.(string)
			}
			err = wsWriteJSON(map[string]any{
				"echo":   m.Echo,
				"status": "ok",
				"data": map[string]any{
					"nickname": nickname,
				},
			})
			if err != nil {
				Error("写入失败", "err", err)
				return
			}
		case "get_contact_directory":
			// 通讯录目录：hook 在微信进程内解密 contact.db 后返回 JSON，原样放进 data；
			// 失败（未捕获 DB key / 解密失败 / 未实现）只回 failed，不影响消息链路。
			directory, contactErr := refreshContactDirectory()
			resp := map[string]any{
				"echo":   m.Echo,
				"status": "ok",
				"data":   directory.publicCopy(),
			}
			if contactErr != nil {
				Warn("获取通讯录目录失败", "err", contactErr)
				resp = map[string]any{
					"echo":   m.Echo,
					"status": "failed",
					"error":  contactErr.Error(),
				}
			}
			if err = wsWriteJSON(resp); err != nil {
				Error("写入失败", "err", err)
				return
			}
		case "send_private_msg", "send_group_msg":
			// 单条动作参数错误只记日志，不关连接：否则客户端发错一次消息就会
			// 丢掉事件流（App 需要重连，断线期间事件全部丢失）。
			if err = SendWS(m.Params); err != nil {
				Error("发送失败", "err", err)
			}
		}
	}
}

func SendWebSocketMsg(jsonData []byte) {
	defer func() {
		if r := recover(); r != nil {
			Error("ws panic", "err", r, "stack", string(debug.Stack()))
		}
	}()

	if currentWSConn() == nil {
		Error("连接为空")
		return
	}

	// 事件推送不节流：入站事件需要立即写入 WS，send_interval 只约束真正
	// 发往微信的消息（worker.go SendWechatMsg）。历史回放不再被固定 1s 拖慢。
	jsonReq, err := HandleMsg(jsonData)
	if err != nil {
		Error("JSON 序列化失败", "err", err)
		return
	}
	if jsonReq == nil {
		return
	}

	logEventDebug("发送数据", jsonReq)
	err = wsWriteMessage(websocket.TextMessage, jsonReq)
	if err != nil {
		Error("发送消息失败", "err", err)
		return
	}
}

func SendWS(req *WSParams) error {
	// params 缺失时按空参数处理：至少不要 panic 丢掉整条 WS 连接。
	if req == nil {
		return errors.New("params is nil")
	}

	sendContent := ""
	atUserID := ""
	if msg, ok := req.Message.(string); ok {
		sendContent = msg
	} else {
		bytes, err := json.Marshal(req.Message)
		if err != nil {
			Error("JSON 序列化失败", "err", err)
			return err
		}
		msgs := make([]*Message, 0)
		err = json.Unmarshal(bytes, &msgs)
		if err != nil {
			Error("JSON 反序列化失败", "err", err)
			return err
		}

		for _, v := range msgs {
			// 数组里出现 null 时 v 为 nil，直接解引用会 panic。
			if v == nil {
				continue
			}
			if v.Type == "text" {
				if v.Data != nil {
					sendContent += v.Data.Text
				}
			} else if v.Type == "at" {
				// 群成员缓存未命中时回退通讯录昵称（docs/architecture.md §3）。
				if v.Data != nil {
					if nickname, ok := resolveAtNickname(req.GroupID, v.Data.QQ); ok {
						sendContent += fmt.Sprintf("@%s\u2005", nickname)
						atUserID += v.Data.QQ + ","
					}
				}
			} else if v.Type == "image" || v.Type == "video" {
				if v.Data == nil {
					continue
				}
				msgChan <- &SendMsg{
					UserId:  req.UserID,
					GroupID: req.GroupID,
					Content: v.Data.File,
					Type:    v.Type,
				}
			} else if v.Type == "pat" {
				target := ""
				if v.Data != nil {
					target = v.Data.QQ
				}
				if target == "" && req.GroupID == "" {
					target = req.UserID
				}
				if target != "" {
					msgChan <- &SendMsg{
						UserId:  target,
						GroupID: req.GroupID,
						Type:    "pat",
					}
				}
			}
		}
	}

	if sendContent != "" {
		msgChan <- &SendMsg{
			UserId:  req.UserID,
			GroupID: req.GroupID,
			Content: sendContent,
			Type:    "text",
			AtUser:  strings.TrimRight(atUserID, ","),
		}
	}

	return nil
}

// testWSBodyMaxBytes 是 POST /test_ws 的请求体上限。
// /test_ws 无鉴权、把 body 原样写进 App 的 WS 连接，只用于本机联调；1 MiB 足够
// 注入任意事件负载，同时防止本机异常进程用超大 body 占满 bridge 内存。
var testWSBodyMaxBytes int64 = 1 << 20

func testWebSocket(w http.ResponseWriter, r *http.Request) {
	body := http.MaxBytesReader(w, r.Body, testWSBodyMaxBytes)
	jsonData, err := io.ReadAll(body)
	if err != nil {
		var maxErr *http.MaxBytesError
		if errors.As(err, &maxErr) {
			http.Error(w, "请求体过大", http.StatusRequestEntityTooLarge)
			Error("test_ws 请求体过大", "limit", testWSBodyMaxBytes)
			return
		}
		Error("读取消息失败", "err", err)
		http.Error(w, "读取请求体失败", http.StatusBadRequest)
		return
	}

	err = wsWriteMessage(websocket.TextMessage, jsonData)
	if err != nil {
		Error("发送消息失败", "err", err)
		return
	}
}

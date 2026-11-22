package main

import (
	"encoding/json"
	"runtime/debug"
	"strings"
	"sync"
)

// isChatroomID 微信群 ID 契约：一律以 @chatroom 结尾（大小写不敏感）。
// 旧 hook 曾把私聊拍一拍的 <chatusername>（wxid）当成群 ID，用这个判定
// 把非法值挡掉，避免 App 为同一好友拆出独立的「群」会话（2026-10-21 修复）。
func isChatroomID(value string) bool {
	return strings.HasSuffix(strings.ToLower(value), "@chatroom")
}

// sanitizeIncomingChatIDs 清洗旧版本 hook 上报的非法群 ID。
//
// 旧 hook 把自己发出的群消息（from=自己、to=群）当成私聊，又把私聊拍一拍的
// <chatusername>（wxid）当成群 ID，App 因此会把同一好友的拍一拍拆成独立会话。
// 这里只纠正字段、不猜测消息方向，所以 selfID 为空（老 bridge / 无法推导账号）
// 时也执行。
func sanitizeIncomingChatIDs(payload map[string]interface{}) {
	if groupID, _ := payload["group_id"].(string); groupID != "" && !isChatroomID(groupID) {
		payload["group_id"] = ""
		// 只有明确标成群的才降级；其它消息类型保持原值，避免扩大影响面。
		if messageType, _ := payload["message_type"].(string); messageType == "group" {
			payload["message_type"] = "private"
		}
	}
	if patChat, _ := payload["pat_chat_wxid"].(string); patChat != "" && !isChatroomID(patChat) {
		payload["pat_chat_wxid"] = ""
	}
}

// incomingEventQueueSize 是入站事件队列容量。1024 足够覆盖 App 侧 HTTP 短暂变慢
// （单条 SendHttpReq 预算 10s）时的积压；队列本身只存 map 指针，不复制消息体。
const incomingEventQueueSize = 1024

// incomingEvents 串行化入站事件：hook 的 incoming_message 由 Frida message 回调
// 投递，旧实现直接 go HandleIncomingMessage，多个 goroutine 完工顺序不确定，
// 同一会话的连续消息可能乱序（App 侧会话列表/上下文顺序错乱）。这里用单 worker
// channel 按入队顺序处理，读循环只做非阻塞入队（见 enqueueIncomingMessage），
// 不等待真实推送完成。
var incomingEvents = make(chan map[string]interface{}, incomingEventQueueSize)

var incomingWorkerOnce sync.Once

// startIncomingWorker 启动唯一的入站事件消费者（幂等）。main 启动时显式调用一次，
// 第一个事件到达时 enqueueIncomingMessage 也会兜底启动，避免测试/旧调用路径漏启。
func startIncomingWorker() {
	incomingWorkerOnce.Do(func() {
		go runIncomingWorker(incomingEvents, HandleIncomingMessage)
	})
}

// enqueueIncomingMessage 把事件交给串行 worker。
//
// 队列满时阻塞投递而不是丢弃：聊天消息丢一条用户就永远看不到，而正常负载下
// worker 远快于到达速度；只有 App 侧 HTTP 接收长时间卡住才会积压，此时让 Frida
// 回调短暂背压优于静默丢事件（日志会先告警，便于定位 App 侧卡顿）。
func enqueueIncomingMessage(payload map[string]interface{}) {
	startIncomingWorker()
	select {
	case incomingEvents <- payload:
	default:
		Warn("入站事件队列已满，等待消费", "capacity", cap(incomingEvents))
		incomingEvents <- payload
	}
}

// runIncomingWorker 串行消费 ch 直到关闭；单独一层便于单测验证顺序与串行性。
// 单条事件 panic 只记日志并继续消费：否则一条坏事件会让整个入站链路永久停摆。
func runIncomingWorker(ch <-chan map[string]interface{}, handle func(map[string]interface{})) {
	for payload := range ch {
		func() {
			defer func() {
				if r := recover(); r != nil {
					Error("入站事件处理 panic", "err", r, "stack", string(debug.Stack()))
				}
			}()
			handle(payload)
		}()
	}
}

// HandleIncomingMessage receives a normalized OneBot event produced by the
// Frida Message-finalizer hook (hook/script.js) and pushes it to the configured
// OneBot transport. This bypasses the 4.1.15 buf2resp path, which no longer
// carries ordinary incoming messages.
func HandleIncomingMessage(payload map[string]interface{}) {
	normalizeIncomingIdentity(payload, myWechatId)
	// hook 事件只有 wxid；用已缓存的通讯录目录补全好友昵称/群名（未命中保持原样）。
	enrichIncomingSender(payload)
	// 入站图片：在推送事件前登记下载元数据，并把 [图片] 文本占位替换成
	// image 段（事件里不新增 aeskey / CDN file key 字段）。
	registerIncomingImage(payload)
	// 入站语音（2026-10-26）：解析 <voicemsg>、按 message_id 登记 pending job，
	// 并把 [语音] 文本占位替换成无文件的 voice 段（duration_ms 可空）；
	// 下载由 App 按需调用 POST /fetch_voice，不阻塞事件推送。
	registerIncomingVoice(payload)

	data, err := json.Marshal(payload)
	if err != nil {
		Error("入站消息序列化失败", "err", err)
		return
	}
	logEventDebug("收到入站消息事件", data)
	if config.ConnType == "http" {
		SendHttpReq(data)
	} else {
		SendWebSocketMsg(data)
	}
}

// normalizeIncomingIdentity 修正 hook 事件的账号/方向字段。
//
// hook 只能看到 Message 的 from/to：对**本账号发出**的私聊消息，
// from=自己、to=对方，而它过去把 self_id 写成 to，于是 App 把这个事件当成
// 「对方发来的」，并按 user_id(=自己) 建出一个「自己 wxid」的会话——这正是
// 私聊消息出现在错误会话里的根因。bridge 知道当前账号（myWechatId），
// 因此在这里统一改写：
//
//   - 入站：self_id = 自己，user_id = 发送者（好友/群成员），方向不变；
//   - 自消息·私聊：is_self=true，self_id = 自己，user_id/sender = 自己，
//     target_id = 对方；App 据此把它记进**对方会话**并标为 outgoing；
//   - 自消息·群聊：is_self=true，self_id/user_id = 自己，target_id = 群 ID；
//   - 拍一拍/系统 appmsg 的 from/to 都可能是群 ID，sender_wxid 不是自己时
//     保持入站语义，避免误判成自消息。
//
// 开头先清洗旧 hook 的非法群 ID（见 sanitizeIncomingChatIDs）：selfID 为空
// （老 bridge / 无 -self_id / image_path 无法推导）时保持方向与旧行为一致，
// 但非法群 ID 仍会被清掉。
func normalizeIncomingIdentity(payload map[string]interface{}, selfID string) {
	if payload == nil {
		return
	}
	sanitizeIncomingChatIDs(payload)
	if selfID == "" {
		return
	}
	payload["self_id"] = selfID

	groupID, _ := payload["group_id"].(string)
	from, _ := payload["from_wxid"].(string)
	to, _ := payload["to_wxid"].(string)
	sender, _ := payload["sender_wxid"].(string)
	if sender == "" {
		sender = from
	}

	if sender != selfID {
		// 入站：不要留下旧的 is_self（重放/重试时 map 可能被复用）。
		delete(payload, "is_self")
		return
	}

	payload["is_self"] = true
	payload["sender"] = map[string]interface{}{
		"user_id":  selfID,
		"nickname": selfID,
	}
	// user_id 保持 OneBot 语义（发送者＝自己）；会话目标单独放 target_id。
	// App 旧的 self_id==user_id 判定对群自消息仍然成立，私聊自消息则用 target_id
	// 落进对方会话，不会再把消息记进「自己 wxid」的会话。
	// 旧 hook 的自己群消息：from=自己、to=群，但 group_id 缺失。to_wxid 是合法
	// 群 ID 时补回群字段，否则会落进私聊会话（2026-10-21 修复）。
	if groupID == "" && isChatroomID(to) {
		groupID = to
		payload["group_id"] = groupID
	}
	if groupID != "" {
		payload["target_id"] = groupID
		payload["message_type"] = "group"
		return
	}
	payload["message_type"] = "private"
	if to != "" {
		payload["target_id"] = to
	}
}

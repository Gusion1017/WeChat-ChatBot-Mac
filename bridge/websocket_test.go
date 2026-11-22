package main

// 本文件覆盖 WS 连接健康（task-7）：读空闲超时、服务端 ping/pong 续期、
// 半开连接主动清理与重连不再 409。只使用 httptest，不连接 Frida。
// 相关实现见 websocket.go 的 wsPingInterval / wsReadTimeout / wsPingLoop。

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func withWSTimings(t *testing.T, ping, readTimeout time.Duration) {
	t.Helper()
	oldPing, oldRead := wsPingInterval, wsReadTimeout
	wsPingInterval, wsReadTimeout = ping, readTimeout
	t.Cleanup(func() {
		wsPingInterval, wsReadTimeout = oldPing, oldRead
	})
}

// waitNoWSConn 等待全局 WS 连接被清空（handler 退出）。
// 用例开始/结束都调用：httptest 的上一用例连接可能还在退出中，直接拨号会误吃 409。
func waitNoWSConn(t *testing.T, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if currentWSConn() == nil {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("%v 内全局 WS 连接未被清空（半开连接没有自愈）", timeout)
}

func wsTestURL(srv *httptest.Server) string {
	return "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws"
}

func dialTestWS(t *testing.T, srv *httptest.Server) *websocket.Conn {
	t.Helper()
	conn, _, err := websocket.DefaultDialer.Dial(wsTestURL(srv), nil)
	if err != nil {
		t.Fatalf("dial %s: %v", wsTestURL(srv), err)
	}
	return conn
}

// TestWebSocketReadTimeoutDropsHalfOpenConn 覆盖半开连接：客户端不发 pong
// （模拟进程被冻结/网络切换），服务端读空闲超时后必须关闭连接并清空全局 conn，
// 后续重连不能再得到 409。
func TestWebSocketReadTimeoutDropsHalfOpenConn(t *testing.T) {
	withToken(t, "")
	withWSTimings(t, 30*time.Millisecond, 90*time.Millisecond)
	waitNoWSConn(t, time.Second)

	srv := httptest.NewServer(http.HandlerFunc(handleWebSocket))
	t.Cleanup(srv.Close)

	conn := dialTestWS(t, srv)
	t.Cleanup(func() { _ = conn.Close() })

	// 刻意不启动读循环：gorilla 客户端只在 ReadMessage 时处理 ping 控制帧，
	// 不读就永远不回 pong，正好等价于半开连接。
	waitNoWSConn(t, 3*time.Second)

	// 服务端已主动关闭：旧连接读应失败。
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, _, err := conn.ReadMessage(); err == nil {
		t.Fatal("半开连接应已被服务端关闭，ReadMessage 仍成功")
	}

	// 重连必须成功（旧实现会因全局 conn 未清理一直返回 409）。
	conn2, resp, err := websocket.DefaultDialer.Dial(wsTestURL(srv), nil)
	if err != nil {
		status := 0
		if resp != nil {
			status = resp.StatusCode
		}
		t.Fatalf("半开连接清理后重连失败: err=%v status=%d", err, status)
	}
	t.Cleanup(func() { _ = conn2.Close() })
	_ = conn2.Close()
	waitNoWSConn(t, 3*time.Second)
}

// TestWebSocketPongKeepsConnAlive 覆盖正常路径：客户端在控制帧回调里自动回 pong，
// 读截止时间持续续期；超过 wsReadTimeout 后动作仍能正常回包。
func TestWebSocketPongKeepsConnAlive(t *testing.T) {
	withToken(t, "")
	withWSTimings(t, 30*time.Millisecond, 120*time.Millisecond)
	waitNoWSConn(t, time.Second)

	srv := httptest.NewServer(http.HandlerFunc(handleWebSocket))
	t.Cleanup(srv.Close)

	conn := dialTestWS(t, srv)
	t.Cleanup(func() { _ = conn.Close() })

	messages := make(chan []byte, 8)
	readErrs := make(chan error, 1)
	go func() {
		for {
			_, raw, err := conn.ReadMessage()
			if err != nil {
				readErrs <- err
				return
			}
			messages <- raw
		}
	}()

	// 3 倍读空闲窗口内只有 ping/pong 控制帧，连接不应被断开。
	time.Sleep(3 * wsReadTimeout)

	if err := conn.WriteJSON(map[string]any{
		"action": "get_login_info",
		"echo":   "pong-alive",
		"params": map[string]any{},
	}); err != nil {
		t.Fatalf("write action: %v", err)
	}

	select {
	case raw := <-messages:
		var got map[string]any
		if err := json.Unmarshal(raw, &got); err != nil {
			t.Fatalf("unmarshal %q: %v", raw, err)
		}
		if got["echo"] != "pong-alive" {
			t.Fatalf("echo = %v, want pong-alive", got["echo"])
		}
	case err := <-readErrs:
		t.Fatalf("pong 未续期，连接被读超时关闭: %v", err)
	case <-time.After(3 * time.Second):
		t.Fatal("动作回包超时")
	}
	_ = conn.Close()
	waitNoWSConn(t, 3*time.Second)
}

// TestWebSocketClientPingKeepsConnAlive 覆盖「只有应用层 ping、没有 pong」的客户端：
// App 每 20s 发一次 ping，服务端收到 ping 也要续期读截止时间，不能把活跃连接误杀。
func TestWebSocketClientPingKeepsConnAlive(t *testing.T) {
	withToken(t, "")
	withWSTimings(t, 40*time.Millisecond, 150*time.Millisecond)
	waitNoWSConn(t, time.Second)

	srv := httptest.NewServer(http.HandlerFunc(handleWebSocket))
	t.Cleanup(srv.Close)

	conn := dialTestWS(t, srv)
	// 覆盖客户端默认 ping handler：不回 pong，模拟只有应用层 ping 的客户端。
	conn.SetPingHandler(func(string) error { return nil })

	pingStop := make(chan struct{})
	var stopOnce sync.Once
	var pingWG sync.WaitGroup
	pingWG.Add(1)
	go func() {
		defer pingWG.Done()
		ticker := time.NewTicker(40 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-pingStop:
				return
			case <-ticker.C:
				_ = conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(time.Second))
			}
		}
	}()
	stopPings := func() {
		stopOnce.Do(func() { close(pingStop) })
		pingWG.Wait()
	}
	t.Cleanup(func() {
		stopPings()
		_ = conn.Close()
	})

	// 超过读空闲窗口：连接只靠客户端 ping 续命，服务端不应断开。
	time.Sleep(4 * wsReadTimeout)
	stopPings()

	if err := conn.WriteJSON(map[string]any{
		"action": "get_login_info",
		"echo":   "client-ping-alive",
		"params": map[string]any{},
	}); err != nil {
		t.Fatalf("write action: %v", err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	_, raw, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("客户端 ping 未续期，连接被读超时关闭: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("unmarshal %q: %v", raw, err)
	}
	if got["echo"] != "client-ping-alive" {
		t.Fatalf("echo = %v, want client-ping-alive", got["echo"])
	}
	_ = conn.Close()
	waitNoWSConn(t, 3*time.Second)
}

// TestWebSocketAbruptDisconnectClearsConn 覆盖对端直接断开（无 close 帧）：
// handler 退出后全局 conn 必须清空，否则 App 重启后的重连会被 409 挡住。
func TestWebSocketAbruptDisconnectClearsConn(t *testing.T) {
	withToken(t, "")
	waitNoWSConn(t, time.Second)

	srv := httptest.NewServer(http.HandlerFunc(handleWebSocket))
	t.Cleanup(srv.Close)

	conn := dialTestWS(t, srv)
	// 不走 close 帧，直接关底层 TCP，模拟 App 崩溃/网络断开。
	_ = conn.UnderlyingConn().Close()

	waitNoWSConn(t, 2*time.Second)

	conn2, resp, err := websocket.DefaultDialer.Dial(wsTestURL(srv), nil)
	if err != nil {
		status := 0
		if resp != nil {
			status = resp.StatusCode
		}
		t.Fatalf("断开后重连失败: err=%v status=%d", err, status)
	}
	t.Cleanup(func() { _ = conn2.Close() })
	_ = conn2.Close()
	waitNoWSConn(t, 3*time.Second)
}

// TestWebSocketRejectsSecondConnectionWhileActive 确认「单连接」契约仍在：
// 第一个连接健康时，第二个连接必须得到 409，避免并发连接覆盖全局 conn。
func TestWebSocketRejectsSecondConnectionWhileActive(t *testing.T) {
	withToken(t, "")
	waitNoWSConn(t, time.Second)

	srv := httptest.NewServer(http.HandlerFunc(handleWebSocket))
	t.Cleanup(srv.Close)

	first := dialTestWS(t, srv)
	t.Cleanup(func() { _ = first.Close() })

	// 保持第一个连接可读，确保服务端认到它是活动连接（pong 会持续续期）。
	go func() {
		for {
			if _, _, err := first.ReadMessage(); err != nil {
				return
			}
		}
	}()

	second, resp, err := websocket.DefaultDialer.Dial(wsTestURL(srv), nil)
	if second != nil {
		_ = second.Close()
	}
	if err == nil {
		t.Fatal("已有活动连接时第二个连接不应握手成功")
	}
	if resp == nil || resp.StatusCode != http.StatusConflict {
		status := 0
		if resp != nil {
			status = resp.StatusCode
		}
		t.Fatalf("status = %d, want 409", status)
	}

	_ = first.Close()
	waitNoWSConn(t, 2*time.Second)
}

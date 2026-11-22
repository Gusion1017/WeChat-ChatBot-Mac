package main

// 本文件不是上游源码，由 ChatBot 项目为“无 Gadget 情况下验证 HTTP 鉴权/参数校验
// 与 /ws 动作契约”而添加。它只使用 httptest，不连接 Frida、不启动真实监听端口。
// 上游源码见 NOTICE。

import (
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/rs/zerolog"
)

// TestMain 避免测试期间的日志写入 ./log/macos.log（上游 initLogger 的副作用），
// 同时保证未初始化的 zerolog.Logger 不会影响 handler 的错误分支。
func TestMain(m *testing.M) {
	Logger.logger = zerolog.Nop()
	os.Exit(m.Run())
}

func withToken(t *testing.T, token string) {
	t.Helper()
	old := config.OnebotToken
	config.OnebotToken = token
	t.Cleanup(func() { config.OnebotToken = old })
}

func doRequest(t *testing.T, method, url, auth, body string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(method, url, strings.NewReader(body))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	if auth != "" {
		req.Header.Set("Authorization", auth)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("do request: %v", err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

// TestSendHandlerAuth 覆盖 docs/architecture.md §3.3 的 HTTP 鉴权与参数校验：
// 方法错误 405、缺失/错误 token 401、坏 JSON/缺参数 400。
func TestSendHandlerAuth(t *testing.T) {
	const token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	withToken(t, token)

	// 注意：上游用 strings.TrimPrefix(header, "Bearer ") 解析 Authorization，
	// 若 header 恰好等于 token（无 Bearer 前缀）也会通过鉴权。这里只构造错误
	// token 的场景，避免进入会等待 SendWorker 的真实发送分支（测试不启动 worker）。
	srv := httptest.NewServer(http.HandlerFunc(sendHandler))
	defer srv.Close()
	sendURL := srv.URL + "/send_private_msg"

	tests := []struct {
		name       string
		method     string
		auth       string
		body       string
		wantStatus int
		wantSubstr string
	}{
		{
			name:       "GET 被拒绝",
			method:     http.MethodGet,
			auth:       "Bearer " + token,
			wantStatus: http.StatusMethodNotAllowed,
			wantSubstr: "仅支持 POST",
		},
		{
			name:       "缺少 Authorization",
			method:     http.MethodPost,
			body:       `{"user_id":"wxid_x","message":[{"type":"text","data":{"text":"hi"}}]}`,
			wantStatus: http.StatusUnauthorized,
			wantSubstr: "未授权",
		},
		{
			name:       "错误 token",
			method:     http.MethodPost,
			auth:       "Bearer wrong-token",
			body:       `{"user_id":"wxid_x","message":[{"type":"text","data":{"text":"hi"}}]}`,
			wantStatus: http.StatusUnauthorized,
			wantSubstr: "未授权",
		},
		{
			name:       "无 Bearer 前缀且 token 错误",
			method:     http.MethodPost,
			auth:       "wrong-token",
			body:       `{"user_id":"wxid_x","message":[{"type":"text","data":{"text":"hi"}}]}`,
			wantStatus: http.StatusUnauthorized,
			wantSubstr: "未授权",
		},
		{
			name:       "坏 JSON",
			method:     http.MethodPost,
			auth:       "Bearer " + token,
			body:       `{not-json`,
			wantStatus: http.StatusBadRequest,
			wantSubstr: "无效的 JSON",
		},
		{
			name:       "message 为空",
			method:     http.MethodPost,
			auth:       "Bearer " + token,
			body:       `{"user_id":"wxid_x","message":[]}`,
			wantStatus: http.StatusBadRequest,
			wantSubstr: "参数缺失",
		},
		{
			name:       "缺少 user_id/group_id",
			method:     http.MethodPost,
			auth:       "Bearer " + token,
			body:       `{"message":[{"type":"text","data":{"text":"hi"}}]}`,
			wantStatus: http.StatusBadRequest,
			wantSubstr: "参数缺失",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			resp := doRequest(t, tc.method, sendURL, tc.auth, tc.body)
			if resp.StatusCode != tc.wantStatus {
				t.Fatalf("status = %d, want %d", resp.StatusCode, tc.wantStatus)
			}
			body := readBody(t, resp)
			if !strings.Contains(body, tc.wantSubstr) {
				t.Fatalf("body = %q, want substring %q", body, tc.wantSubstr)
			}
		})
	}
}

// TestWebSocketGetLoginInfo 覆盖 §3.3 的 get_login_info 动作（含 echo 回包）。
func TestWebSocketGetLoginInfo(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(handleWebSocket))
	defer srv.Close()

	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws"
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial %s: %v", wsURL, err)
	}
	defer conn.Close()

	if err := conn.WriteJSON(map[string]any{
		"action": "get_login_info",
		"echo":   "test-echo-1",
		"params": map[string]any{},
	}); err != nil {
		t.Fatalf("write: %v", err)
	}

	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	_, raw, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("read: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("unmarshal %q: %v", raw, err)
	}
	if got["echo"] != "test-echo-1" {
		t.Fatalf("echo = %v, want test-echo-1", got["echo"])
	}
	if got["status"] != "ok" {
		t.Fatalf("status = %v, want ok", got["status"])
	}
	if _, ok := got["data"].(map[string]any); !ok {
		t.Fatalf("data is not object: %v", got["data"])
	}
}

func readBody(t *testing.T, resp *http.Response) string {
	t.Helper()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	return string(b)
}

// TestSendHandlerIgnoresSegmentsWithoutData 覆盖 message 数组里的 null / 缺 data 段：
// 旧实现直接解引用 v.Data 会 panic，handler 被 net/http 中断，客户端拿不到 JSON 错误。
// 新行为：跳过坏段；没有可发送内容时仍返回 {"status":"ok"}（不启动 worker，不发送）。
func TestSendHandlerIgnoresSegmentsWithoutData(t *testing.T) {
	const token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	withToken(t, token)

	srv := httptest.NewServer(http.HandlerFunc(sendHandler))
	defer srv.Close()
	url := srv.URL + "/send_private_msg"

	bodies := []string{
		`{"user_id":"wxid_x","message":[null]}`,
		`{"user_id":"wxid_x","message":[{"type":"text"}]}`,
		`{"user_id":"wxid_x","message":[{"type":"at"}]}`,
		`{"user_id":"wxid_x","message":[{"type":"reply"}]}`,
		`{"user_id":"wxid_x","message":[{"type":"image"}]}`,
	}
	for _, body := range bodies {
		resp := doRequest(t, http.MethodPost, url, "Bearer "+token, body)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("body %s: status = %d, want 200", body, resp.StatusCode)
		}
		if got := readBody(t, resp); !strings.Contains(got, `"status":"ok"`) {
			t.Fatalf("body %s: response = %q, want status ok", body, got)
		}
	}
}

// TestListenAndServeReturnsErrorOnBusyPort 覆盖「端口被占用」：main 依赖
// listenAndServe 返回错误后以非 0 退出，否则 App 会把启动失败当成正常停止。
func TestListenAndServeReturnsErrorOnBusyPort(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()

	if err := listenAndServe(ln.Addr().String()); err == nil {
		t.Fatal("listenAndServe on busy port returned nil, want error")
	}
}

// TestWebSocketSurvivesMalformedSendAction 覆盖 WS 动作参数错误：单条 send_* 解析失败
// 不应关闭连接（旧行为 return 会让 App 断线、丢事件），后续动作仍可正常回包。
func TestWebSocketSurvivesMalformedSendAction(t *testing.T) {
	withToken(t, "")
	srv := httptest.NewServer(http.HandlerFunc(handleWebSocket))
	defer srv.Close()

	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws"
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial %s: %v", wsURL, err)
	}
	defer conn.Close()

	if err := conn.WriteJSON(map[string]any{
		"action": "send_private_msg",
		"echo":   "bad-1",
		"params": map[string]any{"user_id": "wxid_x", "message": 123},
	}); err != nil {
		t.Fatalf("write bad action: %v", err)
	}
	if err := conn.WriteJSON(map[string]any{
		"action": "get_login_info",
		"echo":   "ok-2",
		"params": map[string]any{},
	}); err != nil {
		t.Fatalf("write follow-up: %v", err)
	}

	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	_, raw, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("read follow-up response (connection closed?): %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("unmarshal %q: %v", raw, err)
	}
	if got["echo"] != "ok-2" {
		t.Fatalf("echo = %v, want ok-2 (first action should not kill connection)", got["echo"])
	}
}

// TestSendHandlerTimesOutWhenResultNeverArrives 覆盖「发送结果永远不回」：
// pendingResultMap 只按 target_id 记录一个等待者，并发发往同一会话时后写覆盖
// 先写，先前的请求永远等不到 worker 结果；hook 不回 upload_*_finish 时同理。
// 旧实现直接 <-ch 会永久挂住 handler（连接与 goroutine 一起泄漏），这里要求
// 在 sendResultTimeout 后返回 500 且带可判定的错误串。
func TestSendHandlerTimesOutWhenResultNeverArrives(t *testing.T) {
	const token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	withToken(t, token)

	// 必须在创建 httptest server 之前改预算：handler 运行在 server 的 goroutine 里。
	oldTimeout := sendResultTimeout
	sendResultTimeout = 50 * time.Millisecond
	t.Cleanup(func() { sendResultTimeout = oldTimeout })
	t.Cleanup(func() {
		// 本测试没有 worker，消息会留在 msgChan 里：排空，避免影响后续用例。
		for {
			select {
			case <-msgChan:
			default:
				return
			}
		}
	})

	srv := httptest.NewServer(http.HandlerFunc(sendHandler))
	defer srv.Close()

	started := time.Now()
	resp := doRequest(t, http.MethodPost, srv.URL+"/send_private_msg", "Bearer "+token,
		`{"user_id":"wxid_x","message":[{"type":"text","data":{"text":"hi"}}]}`)
	body := readBody(t, resp)
	// docs/bridge.md §3.3：/send_* 失败一律 HTTP 500（不引入新状态码）。
	if resp.StatusCode != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500（body %q）", resp.StatusCode, body)
	}
	if !strings.Contains(body, "send result timeout") {
		t.Fatalf("body = %q, want 含 send result timeout", body)
	}
	if elapsed := time.Since(started); elapsed > 5*time.Second {
		t.Fatalf("超时预算未生效：耗时 %v", elapsed)
	}
}

// TestWaitSendResultsStopsAtFirstError 覆盖 worker 返回错误时的短路行为与
// 「多个结果按顺序等待」的语义。
func TestWaitSendResultsStopsAtFirstError(t *testing.T) {
	oldTimeout := sendResultTimeout
	sendResultTimeout = 2 * time.Second
	t.Cleanup(func() { sendResultTimeout = oldTimeout })

	failed := make(chan error, 1)
	failed <- errors.New("upload image failed")
	never := make(chan error, 1) // 永远没有结果：短路后不应再等它
	started := time.Now()
	err := waitSendResults([]chan error{failed, never})
	if err == nil || err.Error() != "upload image failed" {
		t.Fatalf("err = %v, want upload image failed", err)
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("首个错误应立即返回，耗时 %v", elapsed)
	}

	ok := make(chan error, 1)
	ok <- nil
	if err := waitSendResults([]chan error{ok}); err != nil {
		t.Fatalf("成功结果应返回 nil，实际 %v", err)
	}
}

// TestWaitSendResultsTimeout 覆盖「没有任何结果」时的等待预算。
func TestWaitSendResultsTimeout(t *testing.T) {
	oldTimeout := sendResultTimeout
	sendResultTimeout = 30 * time.Millisecond
	t.Cleanup(func() { sendResultTimeout = oldTimeout })

	never := make(chan error, 1)
	started := time.Now()
	if err := waitSendResults([]chan error{never}); !errors.Is(err, errSendResultTimeout) {
		t.Fatalf("err = %v, want errSendResultTimeout", err)
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("超时应按预算返回，耗时 %v", elapsed)
	}
}

// TestSendHandlerRejectsOversizedBody 覆盖 /send_* 的请求体上限（MaxBytesReader）：
// 超过上限回 413「请求体过大」，而不是把整个 body 读进内存。上限本身按媒体段取
// 64MiB（见 sendBodyMaxBytes 注释），这里临时改小以便用小请求验证。
func TestSendHandlerRejectsOversizedBody(t *testing.T) {
	const token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	withToken(t, token)

	oldLimit := sendBodyMaxBytes
	sendBodyMaxBytes = 64
	t.Cleanup(func() { sendBodyMaxBytes = oldLimit })

	srv := httptest.NewServer(http.HandlerFunc(sendHandler))
	defer srv.Close()

	body := `{"user_id":"wxid_x","message":[{"type":"text","data":{"text":"` +
		strings.Repeat("a", 256) + `"}}]}`
	resp := doRequest(t, http.MethodPost, srv.URL+"/send_private_msg", "Bearer "+token, body)
	got := readBody(t, resp)
	if resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, want 413（body %q）", resp.StatusCode, got)
	}
	if !strings.Contains(got, "请求体过大") {
		t.Fatalf("body = %q, want 含 请求体过大", got)
	}
}

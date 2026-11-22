package main

// 本文件覆盖 HTTP 请求体上限（task-7）：
//   - POST /test_ws          1 MiB（未鉴权调试端点）
//   - POST /fetch_image      64 KiB
//   - POST /fetch_voice      64 KiB
//   - POST /send_voice       16 MiB
// 超限统一走 http.MaxBytesReader → 413「请求体过大」。用例通过临时改小上限，
// 用小请求验证，不需要真的构造 16 MiB body。

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func withBodyLimit(t *testing.T, target *int64, limit int64) {
	t.Helper()
	old := *target
	*target = limit
	t.Cleanup(func() { *target = old })
}

// oversizedJSON 构造一个超过 limit 的合法 JSON 前缀：json.Decoder 读到上限后
// 返回 *http.MaxBytesError，handler 应转成 413 而不是 400「无效的 JSON」。
func oversizedJSON(limit int64) string {
	return `{"message_id":"` + strings.Repeat("a", int(limit)+64) + `"}`
}

func TestTestWSRejectsOversizedBody(t *testing.T) {
	withBodyLimit(t, &testWSBodyMaxBytes, 64)

	srv := httptest.NewServer(http.HandlerFunc(testWebSocket))
	t.Cleanup(srv.Close)

	resp := doRequest(t, http.MethodPost, srv.URL+"/test_ws", "", oversizedJSON(testWSBodyMaxBytes))
	body := readBody(t, resp)
	if resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, want 413（body %q）", resp.StatusCode, body)
	}
	if !strings.Contains(body, "请求体过大") {
		t.Fatalf("body = %q, want 含 请求体过大", body)
	}
}

func TestFetchImageRejectsOversizedBody(t *testing.T) {
	const token = "7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b"
	withToken(t, token)
	withBodyLimit(t, &fetchBodyMaxBytes, 64)

	srv := httptest.NewServer(http.HandlerFunc(fetchImageHandler))
	t.Cleanup(srv.Close)

	resp := doRequest(t, http.MethodPost, srv.URL+"/fetch_image", "Bearer "+token, oversizedJSON(fetchBodyMaxBytes))
	body := readBody(t, resp)
	if resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, want 413（body %q）", resp.StatusCode, body)
	}
	if !strings.Contains(body, "请求体过大") {
		t.Fatalf("body = %q, want 含 请求体过大", body)
	}
}

func TestFetchVoiceRejectsOversizedBody(t *testing.T) {
	const token = "8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c8c"
	withToken(t, token)
	withBodyLimit(t, &fetchBodyMaxBytes, 64)

	srv := httptest.NewServer(http.HandlerFunc(fetchVoiceHandler))
	t.Cleanup(srv.Close)

	resp := doRequest(t, http.MethodPost, srv.URL+"/fetch_voice", "Bearer "+token, oversizedJSON(fetchBodyMaxBytes))
	body := readBody(t, resp)
	if resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, want 413（body %q）", resp.StatusCode, body)
	}
	if !strings.Contains(body, "请求体过大") {
		t.Fatalf("body = %q, want 含 请求体过大", body)
	}
}

func TestSendVoiceRejectsOversizedBody(t *testing.T) {
	const token = "9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d9d"
	withToken(t, token)
	withBodyLimit(t, &sendVoiceBodyMaxBytes, 64)

	srv := httptest.NewServer(http.HandlerFunc(sendVoiceHandler))
	t.Cleanup(srv.Close)

	// /send_voice 的 PCM 字段叫 pcm16k；用同名超长字段触发上限，避免依赖 message_id 语义。
	body := `{"user_id":"wxid_x","pcm16k":"` + strings.Repeat("A", int(sendVoiceBodyMaxBytes)+64) + `"}`
	resp := doRequest(t, http.MethodPost, srv.URL+"/send_voice", "Bearer "+token, body)
	got := readBody(t, resp)
	if resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, want 413（body %q）", resp.StatusCode, got)
	}
	if !strings.Contains(got, "请求体过大") {
		t.Fatalf("body = %q, want 含 请求体过大", got)
	}
}

// TestFetchImageBoundaryBodyStillHandled 确认边界：不超过上限的合法请求继续走
// 原有参数校验（未登记 message_id → 400），不会被上限误判成 413。
func TestFetchImageBoundaryBodyStillHandled(t *testing.T) {
	const token = "aeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeae"
	withToken(t, token)
	const limit = 64
	withBodyLimit(t, &fetchBodyMaxBytes, limit)

	srv := httptest.NewServer(http.HandlerFunc(fetchImageHandler))
	t.Cleanup(srv.Close)

	prefix, suffix := `{"message_id":"`, `"}`
	body := prefix + strings.Repeat("a", limit-len(prefix)-len(suffix)) + suffix
	if int64(len(body)) != limit {
		t.Fatalf("构造的边界 body 长度 = %d, want %d", len(body), limit)
	}
	resp := doRequest(t, http.MethodPost, srv.URL+"/fetch_image", "Bearer "+token, body)
	got := readBody(t, resp)
	if resp.StatusCode == http.StatusRequestEntityTooLarge {
		t.Fatalf("恰好等于上限的 body 不应 413（body %q）", got)
	}
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400（未登记 message_id）body %q", resp.StatusCode, got)
	}
}

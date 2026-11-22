package main

// 本文件覆盖 R3 媒体止血（task-7）：
//   - hook 返回 "unsupported:media" 时 bridge 映射为明确错误码 media_send_unsupported；
//   - /send_* 对该错误返回 HTTP 501 + 可展示 message（docs/bridge.md §3.3）；
//   - 发送失败时清理 bridge 为 base64 媒体在 -image_path 新建的临时文件。
// 相关实现见 worker.go（hookMediaUnsupportedMarker / pendingMediaTempPaths）与 http.go。

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestMediaSendUnsupportedResult(t *testing.T) {
	tests := []struct {
		name   string
		result any
		want   bool
	}{
		{"hook 标记", "unsupported:media", true},
		{"带空白", " unsupported:media\n", true},
		{"普通失败", "fail", false},
		{"成功", "1", false},
		{"nil", nil, false},
		{"数字", 0.0, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := mediaSendUnsupportedResult(tc.result); got != tc.want {
				t.Fatalf("mediaSendUnsupportedResult(%v) = %v, want %v", tc.result, got, tc.want)
			}
		})
	}
}

func TestRemoveTempMediaFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "123_456.png")
	if err := os.WriteFile(path, []byte("binary"), 0o644); err != nil {
		t.Fatalf("写入临时媒体文件失败: %v", err)
	}

	removeTempMediaFile(path)
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("临时文件未被删除: err=%v", err)
	}
	// 幂等：同一路径重复清理（后续发送/多 target 覆盖）不应报错或 panic。
	removeTempMediaFile(path)
	removeTempMediaFile("")
}

func TestCleanupMediaTempPath(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "789_012.jpg")
	if err := os.WriteFile(path, []byte("binary"), 0o644); err != nil {
		t.Fatalf("写入临时媒体文件失败: %v", err)
	}

	const targetID = "wxid_target_r3"
	rememberMediaTempPath(targetID, path)
	if _, ok := pendingMediaTempPaths.Load(targetID); !ok {
		t.Fatal("临时文件路径未登记")
	}

	cleanupMediaTempPath(targetID)
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("发送失败后临时文件未被删除: err=%v", err)
	}
	if _, ok := pendingMediaTempPaths.Load(targetID); ok {
		t.Fatal("清理后登记仍存在")
	}
	// 幂等：没有登记时调用不应 panic。
	cleanupMediaTempPath(targetID)
	cleanupMediaTempPath("")
}

// TestSendHandlerMapsMediaSendUnsupported 用假 worker 直接回 errMediaSendUnsupported，
// 覆盖 /send_* 的 501 + media_send_unsupported 映射（真实 worker 需要 fridaScript，
// 单测无法注入，错误映射在 handler 层验证）。
func TestSendHandlerMapsMediaSendUnsupported(t *testing.T) {
	const token = "bfbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfbf"
	withToken(t, token)

	oldTimeout := sendResultTimeout
	sendResultTimeout = 2 * time.Second
	t.Cleanup(func() { sendResultTimeout = oldTimeout })

	startFakeWorker := func(t *testing.T, sendErr error) {
		t.Helper()
		stop := make(chan struct{})
		var wg sync.WaitGroup
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case msg := <-msgChan:
					if msg.ResultChan != nil {
						msg.ResultChan <- sendErr
					}
				case <-stop:
					return
				}
			}
		}()
		t.Cleanup(func() {
			close(stop)
			wg.Wait()
			// 没有 worker 消费的消息会留在全局 msgChan，排空避免污染后续用例。
			for {
				select {
				case <-msgChan:
				default:
					return
				}
			}
		})
	}

	body := `{"user_id":"wxid_x","message":[{"type":"image","data":{"file":"base64://aGk="}}]}`

	t.Run("R3 不支持媒体 → 501", func(t *testing.T) {
		startFakeWorker(t, errMediaSendUnsupported)
		srv := httptest.NewServer(http.HandlerFunc(sendHandler))
		t.Cleanup(srv.Close)

		resp := doRequest(t, http.MethodPost, srv.URL+"/send_private_msg", "Bearer "+token, body)
		got := readBody(t, resp)
		if resp.StatusCode != http.StatusNotImplemented {
			t.Fatalf("status = %d, want 501（body %q）", resp.StatusCode, got)
		}
		if !strings.Contains(got, "media_send_unsupported") {
			t.Fatalf("body = %q, want 含 media_send_unsupported", got)
		}
		if !strings.Contains(got, "R3 模式仅支持文本/语音") {
			t.Fatalf("body = %q, want 含可展示的 R3 限制说明", got)
		}
	})

	t.Run("其它发送失败仍是 500", func(t *testing.T) {
		startFakeWorker(t, errors.New("upload image failed"))
		srv := httptest.NewServer(http.HandlerFunc(sendHandler))
		t.Cleanup(srv.Close)

		resp := doRequest(t, http.MethodPost, srv.URL+"/send_private_msg", "Bearer "+token, body)
		got := readBody(t, resp)
		if resp.StatusCode != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500（body %q）", resp.StatusCode, got)
		}
		if !strings.Contains(got, "upload image failed") {
			t.Fatalf("body = %q, want 含 upload image failed", got)
		}
	})
}

package main

// SNS HTTP 端点测试：鉴权/开关/错误码/超时 + fake RPC 的端到端 JSON 契约。
// 不连接微信/Frida；媒体测试写临时目录。

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"google.golang.org/protobuf/encoding/protowire"
)

const snsTestToken = "sns-test-token"

type fakeSNSCall struct {
	op      string
	body    []byte
	timeout time.Duration
}

type fakeSNSRPC struct {
	mu         sync.Mutex
	status     SNSHookStatus
	statusErr  error
	requestFn  func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error)
	mediaFn    func(ctx context.Context, req SNSMediaRequest) (SNSMediaResult, error)
	calls      []fakeSNSCall
	mediaCalls []SNSMediaRequest
	active     int
	maxActive  int
}

func (f *fakeSNSRPC) Status(ctx context.Context) (SNSHookStatus, error) {
	if f.statusErr != nil {
		return f.status, f.statusErr
	}
	return f.status, nil
}

func (f *fakeSNSRPC) Prime(ctx context.Context, seconds int) (SNSPrimeResult, error) {
	return SNSPrimeResult{OK: true}, nil
}

func (f *fakeSNSRPC) Request(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
	f.mu.Lock()
	f.calls = append(f.calls, fakeSNSCall{op: op, body: append([]byte(nil), body...), timeout: timeout})
	f.active++
	if f.active > f.maxActive {
		f.maxActive = f.active
	}
	fn := f.requestFn
	f.mu.Unlock()
	defer func() {
		f.mu.Lock()
		f.active--
		f.mu.Unlock()
	}()
	if fn == nil {
		return SNSHookResponse{}, newSNSError(503, "sns_not_ready", "fake RPC 未设置")
	}
	return fn(ctx, op, body, timeout)
}

func (f *fakeSNSRPC) Media(ctx context.Context, req SNSMediaRequest) (SNSMediaResult, error) {
	f.mu.Lock()
	f.mediaCalls = append(f.mediaCalls, req)
	fn := f.mediaFn
	f.mu.Unlock()
	if fn == nil {
		return SNSMediaResult{}, snsErrorFromHook("unsupported", "")
	}
	return fn(ctx, req)
}

func (f *fakeSNSRPC) callsSnapshot() []fakeSNSCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]fakeSNSCall(nil), f.calls...)
}

func (f *fakeSNSRPC) lastCall(t *testing.T) fakeSNSCall {
	t.Helper()
	calls := f.callsSnapshot()
	if len(calls) == 0 {
		t.Fatal("fake RPC 没有收到请求")
	}
	return calls[len(calls)-1]
}

// setupSNSHTTP 注入 fake RPC / token / 开关，并隔离全局 service 缓存与限流器。
func setupSNSHTTP(t *testing.T, read, write bool) *fakeSNSRPC {
	t.Helper()
	oldRead, oldWrite := snsReadEnabled(), snsWriteEnabled()
	oldRPC := snsRPC
	oldToken := config.OnebotToken
	oldID := myWechatId
	oldSvc := snsSvc
	oldMediaDir := config.MediaDir
	oldPolicy := currentSNSPolicy()
	oldNow := snsNow
	oldReadMode := snsReadMode()

	fake := &fakeSNSRPC{}
	setSNSFeaturesForTest(read, write)
	setSNSReadModeForTest("")
	setSNSRPCForTest(fake)
	setSNSPolicyForTest(defaultSNSPolicy())
	config.OnebotToken = snsTestToken
	config.MediaDir = ""
	myWechatId = "wxid_self"
	snsSvc = newSNSService()
	snsNow = time.Now
	t.Cleanup(func() {
		setSNSFeaturesForTest(oldRead, oldWrite)
		setSNSReadModeForTest(oldReadMode)
		setSNSRPCForTest(oldRPC)
		setSNSPolicyForTest(oldPolicy)
		config.OnebotToken = oldToken
		config.MediaDir = oldMediaDir
		myWechatId = oldID
		snsSvc = oldSvc
		snsNow = oldNow
	})
	return fake
}

func snsPOST(t *testing.T, handler http.HandlerFunc, body, token string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/sns/unknown", strings.NewReader(body))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	handler(rec, req)
	return rec
}

func snsGET(t *testing.T, handler http.HandlerFunc, token string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/sns/unknown", nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	handler(rec, req)
	return rec
}

func snsJSONBody(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &m); err != nil {
		t.Fatalf("响应不是 JSON: %v body=%q", err, rec.Body.String())
	}
	return m
}

func snsDataField(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	m := snsJSONBody(t, rec)
	if m["status"] != "ok" {
		t.Fatalf("期望 status=ok，实际 %v（body=%s）", m["status"], rec.Body.String())
	}
	data, ok := m["data"].(map[string]any)
	if !ok {
		t.Fatalf("缺少 data 对象: %v", m)
	}
	return data
}

func snsErrFields(t *testing.T, rec *httptest.ResponseRecorder) (int, string, string) {
	t.Helper()
	m := snsJSONBody(t, rec)
	if m["status"] != "failed" {
		t.Fatalf("期望 status=failed，实际 %v", m["status"])
	}
	code, _ := m["code"].(string)
	msg, _ := m["error"].(string)
	return rec.Code, code, msg
}

func snsJSONNumber(v any) int64 {
	switch t := v.(type) {
	case float64:
		return int64(t)
	case int64:
		return t
	case json.Number:
		n, _ := t.Int64()
		return n
	default:
		return 0
	}
}

func snsTestXML(text string, media []snsMediaJSON) string {
	var b strings.Builder
	b.WriteString("<TimelineObject><id>0</id><username>wxid_author</username>")
	b.WriteString("<createTime>1794000000</createTime><contentDesc>")
	b.WriteString(text)
	b.WriteString("</contentDesc>")
	if len(media) == 0 {
		b.WriteString("<ContentObject><contentStyle>2</contentStyle><mediaList/></ContentObject>")
	} else {
		b.WriteString("<ContentObject><contentStyle>1</contentStyle><mediaList>")
		for _, m := range media {
			fmt.Fprintf(&b,
				`<media><type>2</type><url type="1">%s</url><thumb type="1">%s</thumb>`+
					`<size width="%d.0" height="%d.0" totalSize="1"></size></media>`,
				m.URLKey, m.ThumbKey, m.Width, m.Height)
		}
		b.WriteString("</mediaList></ContentObject>")
	}
	b.WriteString("</TimelineObject>")
	return b.String()
}

func snsTestObject(id uint64, text string, media ...snsMediaJSON) SNSObject {
	return SNSObject{
		ID:         id,
		Username:   "wxid_author",
		Nickname:   "作者",
		CreateTime: 1794000000,
		ObjectDesc: []byte(snsTestXML(text, media)),
	}
}

func snsTestTimelineResponse(objs ...SNSObject) []byte {
	return MarshalSNSTimeLineResponse(SNSTimeLineResponse{
		Base:           SNSBaseResponse{Ret: 0},
		FirstPageMD5:   "first-page-md5",
		ObjectCount:    uint32(len(objs)),
		Objects:        objs,
		NewRequestTime: 1700000000,
		ControlFlag:    2,
		ServerConfig:   SNSServerConfig{PostMentionLimit: 10, CopyAndPasteWordLimit: 0},
		Session:        []byte("session-next"),
	})
}

// snsSeedPost 通过一次 fake timeline 请求把帖子塞进只读缓存。
func snsSeedPost(t *testing.T, fake *fakeSNSRPC, obj SNSObject) string {
	t.Helper()
	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		if op != "timeline" {
			return SNSHookResponse{}, newSNSError(500, "sns_test_unexpected_op", "unexpected op "+op)
		}
		return SNSHookResponse{Body: snsTestTimelineResponse(obj)}, nil
	}
	rec := snsPOST(t, snsTimelineHandler, "{}", snsTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("seed timeline 失败: %d %s", rec.Code, rec.Body.String())
	}
	return strconv.FormatUint(obj.ID, 10)
}

// ---- 鉴权 / 开关 ----------------------------------------------------------

func TestSNSAuthAndMethod(t *testing.T) {
	setupSNSHTTP(t, true, true)
	endpoints := []struct {
		name string
		h    http.HandlerFunc
	}{
		{"status", snsStatusHandler},
		{"timeline", snsTimelineHandler},
		{"detail", snsDetailHandler},
		{"media", snsMediaHandler},
		{"sync", snsSyncHandler},
		{"post", snsPostHandler},
		{"comment", snsCommentHandler},
		{"like", snsLikeHandler},
		{"objectop", snsObjectOpHandler},
	}
	for _, ep := range endpoints {
		t.Run(ep.name, func(t *testing.T) {
			rec := snsPOST(t, ep.h, "{}", "")
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("无 token 应 401，实际 %d（%s）", rec.Code, rec.Body.String())
			}
			if _, code, _ := snsErrFields(t, rec); code != "sns_unauthorized" {
				t.Fatalf("错误码应为 sns_unauthorized: %s", code)
			}
			rec = snsPOST(t, ep.h, "{}", "wrong-token")
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("错误 token 应 401，实际 %d", rec.Code)
			}
			rec = snsGET(t, ep.h, snsTestToken)
			if rec.Code != http.StatusMethodNotAllowed {
				t.Fatalf("GET 应 405，实际 %d", rec.Code)
			}
		})
	}
}

func TestSNSFeatureDisabled(t *testing.T) {
	setupSNSHTTP(t, false, false)
	rec := snsPOST(t, snsTimelineHandler, "{}", snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 404 || code != "sns_disabled" {
		t.Fatalf("未启用应 404 sns_disabled，实际 %d/%s", status, code)
	}
	rec = snsPOST(t, snsPostHandler, `{"text":"x"}`, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 404 || code != "sns_disabled" {
		t.Fatalf("总开关关闭时写接口应 404 sns_disabled，实际 %d/%s", status, code)
	}
}

func TestSNSWriteDisabled(t *testing.T) {
	setupSNSHTTP(t, true, false)
	for _, ep := range []struct {
		name string
		h    http.HandlerFunc
		body string
	}{
		{"post", snsPostHandler, `{"text":"hello"}`},
		{"comment", snsCommentHandler, `{"post_id":"1","text":"hi"}`},
		{"like", snsLikeHandler, `{"post_id":"1"}`},
		{"objectop", snsObjectOpHandler, `{"post_id":"1","op":"delete_post"}`},
	} {
		rec := snsPOST(t, ep.h, ep.body, snsTestToken)
		if status, code, _ := snsErrFields(t, rec); status != 404 || code != "sns_write_disabled" {
			t.Fatalf("%s 写开关关闭应 404 sns_write_disabled，实际 %d/%s", ep.name, status, code)
		}
	}
}

// ---- /sns/status ----------------------------------------------------------

func TestSNSStatus(t *testing.T) {
	fake := setupSNSHTTP(t, true, false)
	fake.status = SNSHookStatus{
		OK: true, Ready: true, SeedReady: true, WriteReady: false, CommentReady: true,
		TimelineBodyReady: true,
	}
	rec := snsPOST(t, snsStatusHandler, "{}", snsTestToken)
	data := snsDataField(t, rec)
	if data["ready"] != true || data["seed_ready"] != true || data["write_ready"] != false ||
		data["comment_ready"] != true || data["body_captured"] != true {
		t.Fatalf("status 字段错误: %v", data)
	}
	if data["enabled"] != true || data["account"] != "wxid_self" {
		t.Fatalf("status 元信息错误: %v", data)
	}
}

func TestSNSStatusHookUnavailable(t *testing.T) {
	fake := setupSNSHTTP(t, true, true)
	fake.statusErr = snsErrorFromHook("unsupported", "")
	rec := snsPOST(t, snsStatusHandler, "{}", snsTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("hook 未实现时 status 应降级 200，实际 %d", rec.Code)
	}
	data := snsDataField(t, rec)
	if data["ready"] != false || data["last_error"] != "sns_unsupported" {
		t.Fatalf("status 降级字段错误: %v", data)
	}
	// hook 状态未知时 write_ready 必须为 false（写开关 != 写通道就绪），
	// 否则设置面板/自动发布会误显示「写通道已就绪」。
	if data["write_ready"] != false || data["write_enabled"] != true {
		t.Fatalf("hook 不可用时 write_ready 应为 false、write_enabled=true: %v", data)
	}
}

func TestSNSStatusTimeout(t *testing.T) {
	fake := setupSNSHTTP(t, true, false)
	fake.statusErr = context.DeadlineExceeded
	rec := snsPOST(t, snsStatusHandler, "{}", snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 504 || code != "sns_timeout" {
		t.Fatalf("status 超时应 504 sns_timeout，实际 %d/%s", status, code)
	}
}

// ---- /sns/timeline --------------------------------------------------------

func TestSNSTimelineOK(t *testing.T) {
	fake := setupSNSHTTP(t, true, false)
	first := snsTestObject(15040000000000000001, "hello", snsMediaJSON{
		Kind: "image", URLKey: "url-key", ThumbKey: "thumb-key", Width: 1080, Height: 1440,
	})
	first.LikeCount = 2
	first.LikeFlag = 1
	first.CommentCount = 1
	first.CommentUserList = []SNSCommentInfo{{
		Username: "wxid_cmt", Nickname: "评论者", Type: 2, Content: "nice",
		CreateTime: 1794000100, CommentID2: 77,
	}}
	second := snsTestObject(15040000000000000002, "second")
	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		if op != "timeline" {
			return SNSHookResponse{}, fmt.Errorf("unexpected op %s", op)
		}
		return SNSHookResponse{Body: snsTestTimelineResponse(first, second)}, nil
	}
	session := base64.StdEncoding.EncodeToString([]byte{1, 2, 3})
	// 首页（max_id=0）才走主动请求；分页固定走被动缓存（docs/sns.md §1.1.1），
	// 分页路径由 TestSNSTimelinePaginationUsesPassiveCache 覆盖。
	body := fmt.Sprintf(`{"max_id":"0","first_page_md5":"md5x","session":%q,"refresh":true,"limit":20}`, session)
	rec := snsPOST(t, snsTimelineHandler, body, snsTestToken)
	data := snsDataField(t, rec)

	posts, ok := data["posts"].([]any)
	if !ok || len(posts) != 2 {
		t.Fatalf("posts 数量错误: %v", data["posts"])
	}
	p0 := posts[0].(map[string]any)
	if p0["id"] != "15040000000000000001" || p0["author_id"] != "wxid_author" ||
		p0["author_name"] != "作者" || p0["text"] != "hello" || p0["liked"] != true {
		t.Fatalf("post 字段错误: %v", p0)
	}
	if snsJSONNumber(p0["like_count"]) != 2 || snsJSONNumber(p0["comment_count"]) != 1 {
		t.Fatalf("计数错误: %v", p0)
	}
	media := p0["media"].([]any)
	if len(media) != 1 || media[0].(map[string]any)["kind"] != "image" ||
		b64OrString(media[0].(map[string]any)["width"]) != 1080 ||
		b64OrString(media[0].(map[string]any)["height"]) != 1440 {
		t.Fatalf("媒体字段错误: %v", media)
	}
	comments := p0["comments"].([]any)
	if len(comments) != 1 || comments[0].(map[string]any)["comment_id"] != "77" {
		t.Fatalf("评论字段错误: %v", comments)
	}
	cursor := data["cursor"].(map[string]any)
	if cursor["max_id"] != "15040000000000000002" || cursor["first_page_md5"] != "first-page-md5" {
		t.Fatalf("cursor 错误: %v", cursor)
	}
	if cursor["has_more"] != true {
		t.Fatalf("ControlFlag=2 时 has_more 应为 true: %v", cursor)
	}
	wantSession := base64.StdEncoding.EncodeToString([]byte("session-next"))
	if cursor["session"] != wantSession {
		t.Fatalf("cursor session 错误: %v want %s", cursor["session"], wantSession)
	}
	cfg := data["server_config"].(map[string]any)
	if snsJSONNumber(cfg["post_mention_limit"]) != 10 {
		t.Fatalf("server_config 错误: %v", cfg)
	}

	call := fake.lastCall(t)
	if call.op != "timeline" {
		t.Fatalf("RPC op 错误: %s", call.op)
	}
	req, err := UnmarshalSNSTimeLineRequest(call.body)
	if err != nil {
		t.Fatalf("请求体解码失败: %v", err)
	}
	if req.MaxID != 0 || req.FirstPageMD5 != "md5x" || string(req.Session) != "\x01\x02\x03" {
		t.Fatalf("请求字段错误: %+v", req)
	}
}

func b64OrString(v any) int64 {
	if f, ok := v.(float64); ok {
		return int64(f)
	}
	return 0
}

// 首页主动刷新：优先重放 hook 捕获的真实请求体（marshal 的最小请求体拿不到回包）。
func TestSNSTimelineUsesCapturedBody(t *testing.T) {
	fake := setupSNSHTTP(t, true, true)
	oldCall := snsCallFrida
	t.Cleanup(func() { snsCallFrida = oldCall })

	captured := []byte{0x08, 0x01, 0x10, 0x02, 0x1a, 0x03, 'a', 'b', 'c'}
	snsCallFrida = func(fn string, args ...any) (any, error) {
		if fn == "snsCapturedBody" {
			return fmt.Sprintf(`{"ok":true,"len":%d,"hex":%q}`,
				len(captured), hex.EncodeToString(captured)), nil
		}
		return "", fmt.Errorf("unexpected frida call %s", fn)
	}
	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		if op != "timeline" {
			return SNSHookResponse{}, fmt.Errorf("unexpected op %s", op)
		}
		return SNSHookResponse{Body: MarshalSNSTimeLineResponse(SNSTimeLineResponse{
			Base: SNSBaseResponse{},
		})}, nil
	}
	rec := snsPOST(t, snsTimelineHandler, `{"limit":5}`, snsTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("主动刷新应 200，实际 %d %s", rec.Code, rec.Body.String())
	}
	if got := fake.lastCall(t).body; string(got) != string(captured) {
		t.Fatalf("应重放捕获请求体，实际 len=%d", len(got))
	}

	// hook 没有捕获体时回落到 marshal 的最小请求体。
	snsCallFrida = func(fn string, args ...any) (any, error) {
		return `{"ok":false}`, nil
	}
	rec = snsPOST(t, snsTimelineHandler, `{"limit":5}`, snsTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("回落 marshal 请求体应 200，实际 %d", rec.Code)
	}
	if got := fake.lastCall(t).body; string(got) == string(captured) {
		t.Fatalf("未捕获时不应使用旧请求体")
	}
}

// 分页（max_id != 0）只读被动缓存（docs/sns.md §1.1.1）：不再用最小请求体做一次
// 必然超时的主动发送，缓存缺失时直接 503。
func TestSNSTimelinePaginationUsesPassiveCache(t *testing.T) {
	fake := setupSNSHTTP(t, true, true)
	oldCall := snsCallFrida
	t.Cleanup(func() { snsCallFrida = oldCall })

	captured := time.Now().Add(-time.Minute)
	hexBody := hex.EncodeToString(snsTestTimelineResponse(
		snsTestObject(9001, "page"), snsTestObject(9002, "page2")))
	snsCallFrida = func(fn string, args ...any) (any, error) {
		if fn != "snsLastResponse" {
			return nil, fmt.Errorf("unexpected frida call %s", fn)
		}
		return fmt.Sprintf(`{"ok":true,"hex":%q,"ts":%d}`, hexBody, captured.UnixMilli()), nil
	}
	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		return SNSHookResponse{}, fmt.Errorf("分页不应发起主动请求（op=%s）", op)
	}

	rec := snsPOST(t, snsTimelineHandler, `{"max_id":"8000","limit":20}`, snsTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("分页走被动缓存应 200，实际 %d %s", rec.Code, rec.Body.String())
	}
	data := snsDataField(t, rec)
	if data["source"] != "passive" {
		t.Fatalf("分页来源应为 passive: %v", data["source"])
	}
	if got := snsJSONNumber(data["captured_at"]); got != captured.Unix() {
		t.Fatalf("captured_at = %d，应为 %d", got, captured.Unix())
	}
	if posts := data["posts"].([]any); len(posts) != 2 {
		t.Fatalf("应返回缓存里的 2 条动态，实际 %d", len(posts))
	}
	if calls := fake.callsSnapshot(); len(calls) != 0 {
		t.Fatalf("分页不应调用 snsRequest: %+v", calls)
	}

	// 没有可用的被动缓存 → 503，不等待主动请求超时。
	snsCallFrida = func(fn string, args ...any) (any, error) { return `{"ok":false}`, nil }
	rec = snsPOST(t, snsTimelineHandler, `{"max_id":"8000","limit":20}`, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 503 || code != "sns_need_prime" {
		t.Fatalf("缓存缺失应 503 sns_need_prime，实际 %d/%s", status, code)
	}
	if calls := fake.callsSnapshot(); len(calls) != 0 {
		t.Fatalf("缓存缺失时也不应调用 snsRequest: %+v", calls)
	}
}

func TestSNSTimelineLimitClamp(t *testing.T) {
	fake := setupSNSHTTP(t, true, false)
	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		return SNSHookResponse{Body: snsTestTimelineResponse(
			snsTestObject(1, "a"), snsTestObject(2, "b"), snsTestObject(3, "c"))}, nil
	}
	rec := snsPOST(t, snsTimelineHandler, `{"limit":1}`, snsTestToken)
	data := snsDataField(t, rec)
	posts := data["posts"].([]any)
	if len(posts) != 1 {
		t.Fatalf("limit=1 应只返回 1 条，实际 %d", len(posts))
	}
	cursor := data["cursor"].(map[string]any)
	if cursor["has_more"] != true || cursor["max_id"] != "1" {
		t.Fatalf("截断后 cursor 错误: %v", cursor)
	}
}

func TestSNSTimelineInputValidation(t *testing.T) {
	setupSNSHTTP(t, true, false)
	cases := []struct {
		name string
		body string
	}{
		{"bad_json", `{not json`},
		{"empty_body", ``},
		{"bad_max_id", `{"max_id":"abc"}`},
		{"overflow_max_id", `{"max_id":"18446744073709551616"}`},
		{"bad_session", `{"session":"***"}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := snsPOST(t, snsTimelineHandler, tc.body, snsTestToken)
			if status, code, _ := snsErrFields(t, rec); status != 400 || code != "sns_invalid_request" {
				t.Fatalf("应 400 sns_invalid_request，实际 %d/%s", status, code)
			}
		})
	}
}

func TestSNSTimelineErrors(t *testing.T) {
	cases := []struct {
		name       string
		fake       func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error)
		wantStatus int
		wantCode   string
		wantRet    int64
	}{
		{
			name: "native_rejected",
			fake: func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
				return SNSHookResponse{Body: MarshalSNSTimeLineResponse(SNSTimeLineResponse{
					Base: SNSBaseResponse{Ret: 201},
				})}, nil
			},
			wantStatus: 502,
			wantCode:   "sns_native_rejected",
			wantRet:    201,
		},
		{
			name: "parse_failed",
			fake: func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
				return SNSHookResponse{Body: []byte{0xff, 0xff, 0xff}}, nil
			},
			wantStatus: 502,
			wantCode:   "sns_parse_failed",
		},
		{
			name: "hook_timeout",
			fake: func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
				return SNSHookResponse{}, context.DeadlineExceeded
			},
			wantStatus: 504,
			wantCode:   "sns_timeout",
		},
		{
			name: "seed_missing",
			fake: func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
				return SNSHookResponse{}, snsErrorFromHook("seed_missing", "")
			},
			wantStatus: 503,
			wantCode:   "sns_not_ready",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			fake := setupSNSHTTP(t, true, false)
			fake.requestFn = tc.fake
			rec := snsPOST(t, snsTimelineHandler, "{}", snsTestToken)
			status, code, _ := snsErrFields(t, rec)
			if status != tc.wantStatus || code != tc.wantCode {
				t.Fatalf("应 %d/%s，实际 %d/%s", tc.wantStatus, tc.wantCode, status, code)
			}
			if tc.wantRet != 0 {
				if got := snsJSONNumber(snsJSONBody(t, rec)["ret"]); got != tc.wantRet {
					t.Fatalf("ret 透传错误: %d", got)
				}
			}
		})
	}
}

func TestSNSTimelineRealResponseOverHTTP(t *testing.T) {
	fake := setupSNSHTTP(t, true, false)
	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		return SNSHookResponse{Body: snsMustHex(t, snsFixtureTimelineResponseHex)}, nil
	}
	rec := snsPOST(t, snsTimelineHandler, "{}", snsTestToken)
	data := snsDataField(t, rec)
	posts := data["posts"].([]any)
	if len(posts) != 3 {
		t.Fatalf("真机响应应归一化出 3 条动态，实际 %d", len(posts))
	}
	// 第 2 条是图片动态。
	post1 := posts[1].(map[string]any)
	media := post1["media"].([]any)
	if len(media) != 1 || media[0].(map[string]any)["kind"] != "image" {
		t.Fatalf("真机图片动态媒体错误: %v", media)
	}
	if b64OrString(media[0].(map[string]any)["width"]) != 1440 {
		t.Fatalf("真机图片宽度错误: %v", media[0])
	}
	// 第 3 条含 1 条评论 + 1 个赞；富文本评论正文暂为空（不猜测）。
	post2 := posts[2].(map[string]any)
	comments := post2["comments"].([]any)
	if len(comments) != 1 || comments[0].(map[string]any)["comment_id"] != "1" {
		t.Fatalf("真机评论错误: %v", comments)
	}
	// 时间线不返回 likes（详情才返回，docs/sns.md §4.2）。
	if _, exists := post2["likes"]; exists {
		t.Fatalf("时间线不应返回 likes: %v", post2["likes"])
	}
}

// ---- /sns/detail ----------------------------------------------------------

func TestSNSDetail(t *testing.T) {
	fake := setupSNSHTTP(t, true, false)
	obj := snsTestObject(42, "detail", snsMediaJSON{Kind: "image", URLKey: "u", ThumbKey: "t", Width: 10, Height: 20})
	obj.CommentCount = 1
	obj.CommentUserList = []SNSCommentInfo{{Username: "wxid_c", Nickname: "C", Type: 2, Content: "c", CommentID2: 9}}
	obj.LikeCount = 1
	obj.LikeUserList = []SNSCommentInfo{{Username: "wxid_l", Nickname: "L", Type: 1}}
	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		return SNSHookResponse{Body: MarshalSNSObjectDetailResponse(SNSObjectDetailResponse{
			Base: SNSBaseResponse{}, Object: &obj,
		})}, nil
	}
	rec := snsPOST(t, snsDetailHandler, `{"post_id":"18446744073709551615"}`, snsTestToken)
	data := snsDataField(t, rec)
	if data["source"] != "native" {
		t.Fatalf("主动详情应带 source=native: %v", data["source"])
	}
	post := data["post"].(map[string]any)
	if post["id"] != "42" || post["text"] != "detail" {
		t.Fatalf("detail post 错误: %v", post)
	}
	if likes := post["likes"].([]any); len(likes) != 1 {
		t.Fatalf("detail likes 缺失: %v", post["likes"])
	}
	req, err := UnmarshalSNSObjectDetailRequest(fake.lastCall(t).body)
	if err != nil || req.ID != 18446744073709551615 {
		t.Fatalf("detail 请求体错误: %+v %v", req, err)
	}
}

// TestSNSDetailCacheFallback 验证主动失败/被动模式使用时间线缓存兜底，
// 缓存路径带 source=cache 且强制 comments_truncated=true，不伪造全量评论。
func TestSNSDetailCacheFallback(t *testing.T) {
	fake := setupSNSHTTP(t, true, false)
	obj := snsTestObject(4242, "cached body")
	obj.CommentCount = 1
	obj.CommentUserList = []SNSCommentInfo{{
		Username: "wxid_c", Nickname: "C", Type: 2, Content: "c", CommentID2: 9,
	}}
	postID := snsSeedPost(t, fake, obj)

	// 主动读取失败 → 缓存兜底 200。
	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		return SNSHookResponse{}, newSNSError(503, "sns_need_prime", "fake read failed")
	}
	rec := snsPOST(t, snsDetailHandler, fmt.Sprintf(`{"post_id":%q}`, postID), snsTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("缓存兜底应 200，实际 %d %s", rec.Code, rec.Body.String())
	}
	data := snsDataField(t, rec)
	if data["source"] != "cache" {
		t.Fatalf("缓存兜底应带 source=cache: %v", data)
	}
	post := data["post"].(map[string]any)
	if post["id"] != postID || post["text"] != "cached body" {
		t.Fatalf("缓存 post 字段错误: %v", post)
	}
	if post["comments_truncated"] != true {
		t.Fatalf("缓存兜底必须标记 comments_truncated=true: %v", post)
	}
	if snsJSONNumber(post["comment_count"]) != 1 {
		t.Fatalf("缓存兜底应保留真实评论计数: %v", post)
	}
	if comments := post["comments"].([]any); len(comments) != 1 {
		t.Fatalf("缓存兜底应返回缓存评论: %v", post["comments"])
	}

	// 主动失败且缓存没有该动态 → 保留原错误。
	rec = snsPOST(t, snsDetailHandler, `{"post_id":"999"}`, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 503 || code != "sns_need_prime" {
		t.Fatalf("缓存缺失应保留原错误 503/sns_need_prime，实际 %d/%s", status, code)
	}

	// 主动路径优先：成功回包覆盖缓存内容，响应带 source=native（docs/sns.md §4.3）。
	fresh := snsTestObject(4242, "fresh body")
	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		return SNSHookResponse{Body: MarshalSNSObjectDetailResponse(SNSObjectDetailResponse{
			Base: SNSBaseResponse{}, Object: &fresh,
		})}, nil
	}
	rec = snsPOST(t, snsDetailHandler, fmt.Sprintf(`{"post_id":%q}`, postID), snsTestToken)
	data = snsDataField(t, rec)
	if data["source"] != "native" {
		t.Fatalf("主动成功应带 source=native: %v", data)
	}
	if post := data["post"].(map[string]any); post["text"] != "fresh body" {
		t.Fatalf("主动成功应优先于缓存，实际 %v", post["text"])
	}

	// 被动只读模式：不发起主动请求，直接读缓存；缓存缺失仍报 503。
	setSNSReadModeForTest("passive")
	callsBefore := len(fake.callsSnapshot())
	rec = snsPOST(t, snsDetailHandler, fmt.Sprintf(`{"post_id":%q}`, postID), snsTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("被动模式缓存兜底应 200，实际 %d %s", rec.Code, rec.Body.String())
	}
	if data := snsDataField(t, rec); data["source"] != "cache" {
		t.Fatalf("被动模式应带 source=cache: %v", data)
	}
	if calls := len(fake.callsSnapshot()); calls != callsBefore {
		t.Fatalf("被动模式不应发起主动请求（新增 %d 次）", calls-callsBefore)
	}
	rec = snsPOST(t, snsDetailHandler, `{"post_id":"999"}`, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 503 || code != "sns_need_prime" {
		t.Fatalf("被动模式缓存缺失应 503 sns_need_prime，实际 %d/%s", status, code)
	}
}

// ---- 被动缓存：captured_at ------------------------------------------------

func TestSNSTimelinePassiveCapturedAt(t *testing.T) {
	setupSNSHTTP(t, true, false)
	setSNSReadModeForTest("passive")
	oldCall := snsCallFrida
	t.Cleanup(func() { snsCallFrida = oldCall })

	captured := time.Now().Add(-2 * time.Minute)
	hexBody := hex.EncodeToString(MarshalSNSTimeLineResponse(SNSTimeLineResponse{
		Base:        SNSBaseResponse{},
		ObjectCount: 1,
		Objects:     []SNSObject{snsTestObject(11, "passive body")},
	}))
	snsCallFrida = func(fn string, args ...any) (any, error) {
		if fn != "snsLastResponse" {
			return nil, fmt.Errorf("unexpected frida call %s", fn)
		}
		return fmt.Sprintf(`{"ok":true,"hex":%q,"ts":%d}`, hexBody, captured.UnixMilli()), nil
	}

	rec := snsPOST(t, snsTimelineHandler, `{"limit":20}`, snsTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("被动模式时间线应 200，实际 %d %s", rec.Code, rec.Body.String())
	}
	data := snsDataField(t, rec)
	if data["source"] != "passive" {
		t.Fatalf("应标记 source=passive: %v", data)
	}
	if got := snsJSONNumber(data["captured_at"]); got != captured.Unix() {
		t.Fatalf("captured_at 应为缓存捕获时间（%d），实际 %d", captured.Unix(), got)
	}
	posts, _ := data["posts"].([]any)
	if len(posts) != 1 {
		t.Fatalf("应解析出 1 条动态，实际 %d", len(posts))
	}

	// 超过 10 分钟的缓存不再使用：返回原错误 503 sns_need_prime。
	snsCallFrida = func(fn string, args ...any) (any, error) {
		return fmt.Sprintf(`{"ok":true,"hex":%q,"ts":%d}`, hexBody,
			time.Now().Add(-11*time.Minute).UnixMilli()), nil
	}
	rec = snsPOST(t, snsTimelineHandler, `{"limit":20}`, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 503 || code != "sns_need_prime" {
		t.Fatalf("过期缓存应 503/sns_need_prime，实际 %d/%s", status, code)
	}
}

// ---- /sns/media -----------------------------------------------------------

func TestSNSMedia(t *testing.T) {
	fake := setupSNSHTTP(t, true, false)
	base := filepath.Join(t.TempDir(), "accounts", "wxid_self", "media")
	config.MediaDir = base
	wantDir := filepath.Join(filepath.Dir(base), "sns-media")

	postID := snsSeedPost(t, fake, snsTestObject(7, "pic", snsMediaJSON{
		Kind: "image", URLKey: "url-key", ThumbKey: "thumb-key", Width: 10, Height: 20,
	}))
	textOnlyID := snsSeedPost(t, fake, snsTestObject(8, "text only"))
	// 本用例验证 legacy RPC 路径；raw 媒体由专门的用例覆盖。
	snsClearRawMediaForTest()

	// 未知动态。
	rec := snsPOST(t, snsMediaHandler, `{"post_id":"999"}`, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 404 || code != "sns_post_not_found" {
		t.Fatalf("未知动态应 404，实际 %d/%s", status, code)
	}
	// 非法 variant。
	rec = snsPOST(t, snsMediaHandler, fmt.Sprintf(`{"post_id":%q,"media_index":0,"variant":"huge"}`, postID), snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 400 || code != "sns_invalid_request" {
		t.Fatalf("非法 variant 应 400，实际 %d/%s", status, code)
	}
	// 越界。
	rec = snsPOST(t, snsMediaHandler, fmt.Sprintf(`{"post_id":%q,"media_index":5}`, postID), snsTestToken)
	if status, _, _ := snsErrFields(t, rec); status != 400 {
		t.Fatalf("越界 media_index 应 400，实际 %d", status)
	}
	// 无媒体。
	rec = snsPOST(t, snsMediaHandler, fmt.Sprintf(`{"post_id":%q}`, textOnlyID), snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 404 || code != "sns_media_not_found" {
		t.Fatalf("无媒体应 404 sns_media_not_found，实际 %d/%s", status, code)
	}
	// hook 未就绪。
	fake.mediaFn = func(ctx context.Context, req SNSMediaRequest) (SNSMediaResult, error) {
		return SNSMediaResult{}, snsErrorFromHook("media_unavailable", "")
	}
	rec = snsPOST(t, snsMediaHandler, fmt.Sprintf(`{"post_id":%q,"media_index":0}`, postID), snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 503 || code != "sns_media_unavailable" {
		t.Fatalf("媒体通道未就绪应 503，实际 %d/%s", status, code)
	}
	// 成功：fake 在 handler 指定的路径落盘。
	fake.mediaFn = func(ctx context.Context, req SNSMediaRequest) (SNSMediaResult, error) {
		if !strings.HasPrefix(req.Path, wantDir+string(filepath.Separator)) {
			t.Fatalf("handler 传入路径不在 sns-media 目录: %s", req.Path)
		}
		if err := os.MkdirAll(filepath.Dir(req.Path), 0o700); err != nil {
			t.Fatalf("建目录失败: %v", err)
		}
		if err := os.WriteFile(req.Path, []byte("jpeg-data"), 0o600); err != nil {
			t.Fatalf("写媒体文件失败: %v", err)
		}
		return SNSMediaResult{OK: true, File: req.Path}, nil
	}
	rec = snsPOST(t, snsMediaHandler, fmt.Sprintf(`{"post_id":%q,"media_index":0}`, postID), snsTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("媒体成功路径应 200，实际 %d %s", rec.Code, rec.Body.String())
	}
	body := snsJSONBody(t, rec)
	file, _ := body["file"].(string)
	if !strings.HasPrefix(file, "file://") {
		t.Fatalf("file 字段应为 file:// URL: %q", file)
	}
	if _, err := os.Stat(strings.TrimPrefix(file, "file://")); err != nil {
		t.Fatalf("媒体文件不存在: %v", err)
	}
	mediaCall := fake.mediaCalls[len(fake.mediaCalls)-1]
	if mediaCall.Action != "download" || mediaCall.Kind != "thumb" ||
		mediaCall.Key != "thumb-key" || mediaCall.PostID != postID {
		t.Fatalf("snsMedia 参数错误: %+v", mediaCall)
	}
	// 第二次同参数请求应复用已解密文件，不再调用媒体下载。
	callsBefore := len(fake.mediaCalls)
	rec = snsPOST(t, snsMediaHandler, fmt.Sprintf(`{"post_id":%q,"media_index":0}`, postID), snsTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("缓存命中应 200，实际 %d", rec.Code)
	}
	if cached, _ := snsJSONBody(t, rec)["cached"].(bool); !cached {
		t.Fatalf("缓存命中应带 cached=true")
	}
	if len(fake.mediaCalls) != callsBefore {
		t.Fatalf("缓存命中不应再调用媒体下载（before=%d after=%d）", callsBefore, len(fake.mediaCalls))
	}
	// 越权路径拒绝：先删掉缓存文件，确保走到 RPC 而不是复用历史解密结果。
	_ = os.Remove(filepath.Join(wantDir, fmt.Sprintf("%s-%d-%s", postID, 0, "thumb")))
	fake.mediaFn = func(ctx context.Context, req SNSMediaRequest) (SNSMediaResult, error) {
		return SNSMediaResult{OK: true, File: "/etc/passwd"}, nil
	}
	rec = snsPOST(t, snsMediaHandler, fmt.Sprintf(`{"post_id":%q,"media_index":0}`, postID), snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 502 || code != "sns_media_failed" {
		t.Fatalf("越权路径应 502，实际 %d/%s", status, code)
	}
}

// 时间线解析时注册 raw 媒体后，/sns/media 直接走 CDN 下载/解密路径，不再依赖 hook media。
func TestSNSMediaUsesRawTimelineURL(t *testing.T) {
	fake := setupSNSHTTP(t, true, false)
	base := filepath.Join(t.TempDir(), "accounts", "wxid_self", "media")
	config.MediaDir = base
	postID := snsSeedPost(t, fake, snsTestObject(7, "pic", snsMediaJSON{
		Kind: "image", URLKey: "url-key", ThumbKey: "thumb-key", Width: 10, Height: 20,
	}))

	var downloads int
	oldDownload := snsDownloadImageFunc
	t.Cleanup(func() { snsDownloadImageFunc = oldDownload })
	snsDownloadImageFunc = func(ctx context.Context, raw SNSMedia, variant, dest string) (string, error) {
		downloads++
		if err := os.MkdirAll(filepath.Dir(dest), 0o700); err != nil {
			return "", err
		}
		body := []byte{0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x00, 0x00}
		if err := os.WriteFile(dest, body, 0o600); err != nil {
			return "", err
		}
		return dest, nil
	}

	rec := snsPOST(t, snsMediaHandler, fmt.Sprintf(`{"post_id":%q,"media_index":0}`, postID), snsTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("raw 媒体下载应 200，实际 %d %s", rec.Code, rec.Body.String())
	}
	if downloads != 1 {
		t.Fatalf("应调用一次 CDN 下载，实际 %d", downloads)
	}
	if len(fake.mediaCalls) != 0 {
		t.Fatalf("raw 媒体路径不应调用 hook media: %v", fake.mediaCalls)
	}
	// 第二次同参数应复用已解密文件。
	callsBefore := len(fake.callsSnapshot())
	rec = snsPOST(t, snsMediaHandler, fmt.Sprintf(`{"post_id":%q,"media_index":0}`, postID), snsTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("缓存命中应 200，实际 %d", rec.Code)
	}
	if downloads != 1 {
		t.Fatalf("缓存命中不应重复下载，实际下载 %d 次", downloads)
	}
	if cached, _ := snsJSONBody(t, rec)["cached"].(bool); !cached {
		t.Fatalf("缓存命中应带 cached=true")
	}
	if len(fake.callsSnapshot()) != callsBefore {
		t.Fatalf("缓存命中不应调用 hook")
	}
}

// 评论写回包只带摘要 XML（空 mediaList）时，不能清掉时间线已注册的 raw 媒体，
// 否则评论后图片再也下载不了（会退回未实现的 hook snsMedia 路径）。
func TestSNSMediaSurvivesPartialWriteResponse(t *testing.T) {
	fake := setupSNSHTTP(t, true, true)
	base := filepath.Join(t.TempDir(), "accounts", "wxid_self", "media")
	config.MediaDir = base
	now := time.Unix(1794000000, 0)
	snsNow = func() time.Time { return now }

	obj := snsTestObject(7, "pic", snsMediaJSON{
		Kind: "image", URLKey: "url-key", ThumbKey: "thumb-key", Width: 10, Height: 20,
	})
	postID := snsSeedPost(t, fake, obj)

	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		if op != "comment" {
			return SNSHookResponse{}, fmt.Errorf("unexpected op %s", op)
		}
		// 摘要 XML：有 TimelineObject 但 mediaList 为空。
		return SNSHookResponse{Body: MarshalSNSCommentResponse(SNSPostResponse{
			Base: SNSBaseResponse{},
			Object: &SNSObject{
				ID:           7,
				Username:     "wxid_self",
				CreateTime:   1794000000,
				ObjectDesc:   []byte(snsTestXML("pic", nil)),
				CommentCount: 1,
			},
		})}, nil
	}
	rec := snsPOST(t, snsCommentHandler, fmt.Sprintf(`{"post_id":%q,"text":"hi"}`, postID), snsTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("评论应 200，实际 %d %s", rec.Code, rec.Body.String())
	}

	var downloads int
	oldDownload := snsDownloadImageFunc
	t.Cleanup(func() { snsDownloadImageFunc = oldDownload })
	snsDownloadImageFunc = func(ctx context.Context, raw SNSMedia, variant, dest string) (string, error) {
		downloads++
		if err := os.MkdirAll(filepath.Dir(dest), 0o700); err != nil {
			return "", err
		}
		if err := os.WriteFile(dest, []byte{0xff, 0xd8, 0xff, 0xe0}, 0o600); err != nil {
			return "", err
		}
		return dest, nil
	}
	now = now.Add(11 * time.Second)
	rec = snsPOST(t, snsMediaHandler, fmt.Sprintf(`{"post_id":%q,"media_index":0}`, postID), snsTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("评论后媒体下载应仍走 raw 路径: %d %s", rec.Code, rec.Body.String())
	}
	if downloads != 1 {
		t.Fatalf("应调用一次 CDN 下载，实际 %d", downloads)
	}
	if len(fake.mediaCalls) != 0 {
		t.Fatalf("不应退回 hook snsMedia: %v", fake.mediaCalls)
	}
}

// ---- /sns/sync ------------------------------------------------------------

func TestSNSSyncUsesCapturedBody(t *testing.T) {
	fake := setupSNSHTTP(t, true, true)
	oldCall := snsCallFrida
	t.Cleanup(func() { snsCallFrida = oldCall })

	captured := MarshalSNSSyncRequest(SNSSyncRequest{Selector: 256, KeyBuf: []byte{7, 7}})
	captured = append(captured, 0xA2, 0x01, 0x07)
	captured = append(captured, []byte("keep-me")...)
	snsCallFrida = func(fn string, args ...any) (any, error) {
		if fn == "snsCapturedBody" {
			return fmt.Sprintf(`{"ok":true,"len":%d,"hex":%q}`,
				len(captured), hex.EncodeToString(captured)), nil
		}
		return "", fmt.Errorf("unexpected frida call %s", fn)
	}
	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		if op != "sync" {
			return SNSHookResponse{}, fmt.Errorf("unexpected op %s", op)
		}
		return SNSHookResponse{Body: MarshalSNSSyncResponse(SNSSyncResponse{
			Base:         SNSBaseResponse{},
			CmdList:      SNSCmdList{},
			ContinueFlag: 0,
		})}, nil
	}
	rec := snsPOST(t, snsSyncHandler, `{"wait_ms":0}`, snsTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("sync 应 200，实际 %d %s", rec.Code, rec.Body.String())
	}
	body := fake.lastCall(t).body
	req, err := UnmarshalSNSSyncRequest(body)
	if err != nil {
		t.Fatalf("请求体无法解析: %v", err)
	}
	if req.Selector != 256 {
		t.Fatalf("Selector = %d", req.Selector)
	}
	if !strings.Contains(string(body), "keep-me") {
		t.Fatalf("应保留捕获请求体里的 App 侧字段")
	}
}

// 主动同步失败回退到 hook 缓存响应时，不能用缓存回包的 KeyBuf 覆盖 bridge
// 当前同步游标（旧的缓存会把游标回滚）。
func TestSNSSyncFallbackDoesNotRewindCursor(t *testing.T) {
	fake := setupSNSHTTP(t, true, false)
	oldCall := snsCallFrida
	t.Cleanup(func() { snsCallFrida = oldCall })
	snsCallFrida = func(fn string, args ...any) (any, error) {
		if fn != "snsLastResponse" {
			return nil, fmt.Errorf("unexpected frida call %s", fn)
		}
		cached := MarshalSNSSyncResponse(SNSSyncResponse{
			Base:         SNSBaseResponse{},
			ContinueFlag: 0,
			KeyBuf:       []byte{9, 9, 9},
		})
		return fmt.Sprintf(`{"ok":true,"hex":%q,"ts":%d}`,
			hex.EncodeToString(cached), time.Now().UnixMilli()), nil
	}

	// 先用一次成功的主动同步把游标推进到 {1,2,3}。
	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		return SNSHookResponse{Body: MarshalSNSSyncResponse(SNSSyncResponse{
			Base:   SNSBaseResponse{},
			KeyBuf: []byte{1, 2, 3},
		})}, nil
	}
	rec := snsPOST(t, snsSyncHandler, `{"wait_ms":0}`, snsTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("主动同步应 200，实际 %d %s", rec.Code, rec.Body.String())
	}
	if got := snsSvc.syncCursor(); string(got) != "\x01\x02\x03" {
		t.Fatalf("游标应推进到 {1,2,3}，实际 %v", got)
	}

	// 主动失败 → 回退缓存；缓存回包里的 {9,9,9} 不能覆盖当前游标。
	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		return SNSHookResponse{}, newSNSError(504, "sns_timeout", "fake timeout")
	}
	rec = snsPOST(t, snsSyncHandler, `{"wait_ms":0}`, snsTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("缓存兜底应 200，实际 %d %s", rec.Code, rec.Body.String())
	}
	if data := snsDataField(t, rec); data["source"] != "passive" {
		t.Fatalf("应标记 source=passive: %v", data["source"])
	}
	if got := snsSvc.syncCursor(); string(got) != "\x01\x02\x03" {
		t.Fatalf("缓存兜底不应回滚同步游标，实际 %v", got)
	}
}

func TestSNSSyncProbeDebugCommands(t *testing.T) {
	fake := setupSNSHTTP(t, true, false)
	setSNSProbeForTest(true)
	t.Cleanup(func() { setSNSProbeForTest(false) })
	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		if op != "sync" {
			return SNSHookResponse{}, fmt.Errorf("unexpected op %s", op)
		}
		return SNSHookResponse{Body: MarshalSNSSyncResponse(SNSSyncResponse{
			Base:         SNSBaseResponse{},
			CmdList:      SNSCmdList{Items: []SNSCmdItem{{CmdID: 7, CmdBuf: []byte{0x08, 0x01, 0x12}}}},
			ContinueFlag: 0,
		})}, nil
	}
	rec := snsPOST(t, snsSyncHandler, `{"wait_ms":0}`, snsTestToken)
	data := snsDataField(t, rec)
	debug, ok := data["debug_commands"].([]any)
	if !ok || len(debug) != 1 {
		t.Fatalf("probe 开启时应返回 debug_commands: %v", data["debug_commands"])
	}
	item, ok := debug[0].(map[string]any)
	if !ok || item["prefix_hex"] != "080112" || snsJSONNumber(item["buf_len"]) != 3 {
		t.Fatalf("debug_commands 内容错误: %v", item)
	}

	setSNSProbeForTest(false)
	rec = snsPOST(t, snsSyncHandler, `{"wait_ms":0}`, snsTestToken)
	if _, exists := snsDataField(t, rec)["debug_commands"]; exists {
		t.Fatalf("probe 关闭时不得返回 debug_commands")
	}
}

func TestSNSSync(t *testing.T) {
	fake := setupSNSHTTP(t, true, false)
	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		if op != "sync" {
			return SNSHookResponse{}, fmt.Errorf("unexpected op %s", op)
		}
		return SNSHookResponse{Body: MarshalSNSSyncResponse(SNSSyncResponse{
			Base:         SNSBaseResponse{},
			CmdList:      SNSCmdList{Items: []SNSCmdItem{{CmdID: 1, CmdBuf: []byte("<unknown/>")}}},
			ContinueFlag: 1,
			KeyBuf:       []byte{9, 9},
		})}, nil
	}
	rec := snsPOST(t, snsSyncHandler, `{"wait_ms":0}`, snsTestToken)
	data := snsDataField(t, rec)
	if events, ok := data["events"].([]any); !ok || len(events) != 0 {
		t.Fatalf("未知 CmdList 不应伪造事件: %v", data["events"])
	}
	if snsJSONNumber(data["unsupported_cmd_count"]) != 1 {
		t.Fatalf("unsupported_cmd_count 错误: %v", data)
	}
	cursor := data["cursor"].(map[string]any)
	if cursor["key_buf"] != base64.StdEncoding.EncodeToString([]byte{9, 9}) ||
		snsJSONNumber(cursor["continue_flag"]) != 1 {
		t.Fatalf("sync cursor 错误: %v", cursor)
	}
	req, err := UnmarshalSNSSyncRequest(fake.lastCall(t).body)
	if err != nil || req.Selector != snsSyncSelector {
		t.Fatalf("sync 请求体错误: %+v %v", req, err)
	}

	// 第二次应回填上次 KeyBuf。
	rec = snsPOST(t, snsSyncHandler, `{}`, snsTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("第二次 sync 失败: %d", rec.Code)
	}
	req, err = UnmarshalSNSSyncRequest(fake.lastCall(t).body)
	if err != nil || string(req.KeyBuf) != "\x09\x09" {
		t.Fatalf("sync 游标未回填: %+v %v", req, err)
	}
}

// ---- /sns/post（P3 门禁） --------------------------------------------------

func TestSNSPostGates(t *testing.T) {
	fake := setupSNSHTTP(t, true, true)
	now := time.Unix(1794000000, 0)
	snsNow = func() time.Time { return now }

	// 显式 confirm=false → 403。
	rec := snsPOST(t, snsPostHandler, `{"text":"hello","confirm":false}`, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 403 || code != "sns_not_confirmed" {
		t.Fatalf("confirm=false 应 403，实际 %d/%s", status, code)
	}
	// 非法可见性。
	rec = snsPOST(t, snsPostHandler, `{"text":"hello","visibility":"friends"}`, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 400 || code != "sns_invalid_visibility" {
		t.Fatalf("非法 visibility 应 400，实际 %d/%s", status, code)
	}
	// public 本迭代拒绝。
	rec = snsPOST(t, snsPostHandler, `{"text":"hello","visibility":"public"}`, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 403 || code != "sns_visibility_unsupported" {
		t.Fatalf("public 应 403，实际 %d/%s", status, code)
	}
	// partial 的 visible_user_ids 与 target_user_id 不一致 → 403。
	rec = snsPOST(t, snsPostHandler,
		`{"text":"hello","visibility":"partial","target_user_id":"wxid_a","visible_user_ids":["wxid_b"]}`, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 403 || code != "sns_visibility_mismatch" {
		t.Fatalf("可见范围不一致应 403，实际 %d/%s", status, code)
	}
	// partial 多个好友：本迭代只允许 1 个。
	rec = snsPOST(t, snsPostHandler,
		`{"text":"hello","visibility":"partial","visible_user_ids":["wxid_a","wxid_b"]}`, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 403 || code != "sns_visibility_unsupported" {
		t.Fatalf("多好友 partial 应 403，实际 %d/%s", status, code)
	}
	// 空正文。
	rec = snsPOST(t, snsPostHandler, `{"text":"   "}`, snsTestToken)
	if status, _, _ := snsErrFields(t, rec); status != 400 {
		t.Fatalf("空正文应 400，实际 %d", status)
	}
	// 媒体发布暂不支持。
	rec = snsPOST(t, snsPostHandler, `{"text":"hello","media":[{"kind":"image"}]}`, snsTestToken)
	if status, _, _ := snsErrFields(t, rec); status != 400 {
		t.Fatalf("带媒体发布应 400，实际 %d", status)
	}
	// 合法 partial：发布通道未就绪 → 503（不发送半成品）；失败不扣配额。
	rec = snsPOST(t, snsPostHandler,
		`{"text":"hello","visibility":"partial","target_user_id":"wxid_friend"}`, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 503 || code != "sns_publish_unavailable" {
		t.Fatalf("发布通道未就绪应 503，实际 %d/%s", status, code)
	}
	dayStart := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	if n := snsSvc.limiter.countSince("post", dayStart); n != 0 {
		t.Fatalf("发布失败不应记录配额，实际记录 %d 次", n)
	}
	// 连续失败（不同 client_id / 无 client_id）仍是 503，不会触发最小间隔。
	rec = snsPOST(t, snsPostHandler, `{"text":"again","client_id":"different"}`, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 503 || code != "sns_publish_unavailable" {
		t.Fatalf("失败尝试不应占用最小间隔，实际 %d/%s", status, code)
	}
	// 模拟一次成功提交后才记录配额：随后 10 分钟内的发布被 429 拦下。
	recordSNSPostAttempt(now)
	if n := snsSvc.limiter.countSince("post", dayStart); n != 1 {
		t.Fatalf("成功提交应记录 1 次配额，实际 %d", n)
	}
	rec = snsPOST(t, snsPostHandler, `{"text":"after success","client_id":"after-success"}`, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 429 || code != "sns_rate_limited" {
		t.Fatalf("最小间隔内应 429，实际 %d/%s", status, code)
	}
	if retry := snsJSONNumber(snsJSONBody(t, rec)["retry_after_seconds"]); retry <= 0 {
		t.Fatalf("429 应带 retry_after_seconds: %v", retry)
	}

	// 无上下文默认 partial → 降级 private，仍走到通道未就绪 503。
	snsSvc = newSNSService()
	rec = snsPOST(t, snsPostHandler, `{"text":"no context"}`, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 503 || code != "sns_publish_unavailable" {
		t.Fatalf("无上下文应降级 private 后 503，实际 %d/%s", status, code)
	}
	if calls := fake.callsSnapshot(); len(calls) != 0 {
		t.Fatalf("发布通道未就绪时不应调用 snsRequest: %v", calls)
	}

	// 时段外 → 409。
	snsSvc = newSNSService()
	now = time.Date(2026, 11, 7, 3, 0, 0, 0, time.Local)
	snsNow = func() time.Time { return now }
	setSNSPolicyForTest(snsPolicy{
		PostMinInterval: 0,
		PostDailyLimit:  5,
		PostWindows:     []snsTimeWindow{{StartMinute: 9 * 60, EndMinute: 22 * 60}},
	})
	rec = snsPOST(t, snsPostHandler, `{"text":"night"}`, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 409 || code != "sns_outside_window" {
		t.Fatalf("时段外应 409 sns_outside_window，实际 %d/%s", status, code)
	}

	// 每日上限 → 429 sns_daily_limit + retry_after_seconds（配额仅在成功提交后记录）。
	snsSvc = newSNSService()
	setSNSPolicyForTest(snsPolicy{PostMinInterval: 0, PostDailyLimit: 1})
	now = time.Date(2026, 11, 7, 12, 0, 0, 0, time.Local)
	snsNow = func() time.Time { return now }
	recordSNSPostAttempt(now)
	rec = snsPOST(t, snsPostHandler, `{"text":"second"}`, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 429 || code != "sns_daily_limit" {
		t.Fatalf("超过每日上限应 429 sns_daily_limit，实际 %d/%s", status, code)
	}
	if retry := snsJSONNumber(snsJSONBody(t, rec)["retry_after_seconds"]); retry <= 0 {
		t.Fatalf("每日上限 429 应带 retry_after_seconds: %v", retry)
	}
}

// 捕获到真实 SnsPost 模板后：保留 ClientCheckDat 等字段，替换正文/可见性并提交。
func TestSNSCapturePersistAndRestore(t *testing.T) {
	setupSNSHTTP(t, true, true)
	resetSNSCaptureRestoreForTest()
	t.Cleanup(resetSNSCaptureRestoreForTest)
	root := t.TempDir()
	config.MediaDir = filepath.Join(root, "accounts", "wxid_self", "media")

	exportJSON := `{"ok":true,"pid":1,"moduleBase":"0x100000000","records":{"mmsnspost":{"opHex":"0xd1"}},"bodies":{"post":"deadbeef"},"seeds":{}}`
	var imported string
	oldCall := snsCallFrida
	t.Cleanup(func() { snsCallFrida = oldCall })
	snsCallFrida = func(fn string, args ...any) (any, error) {
		switch fn {
		case "snsExportCapture":
			return exportJSON, nil
		case "snsImportCapture":
			if len(args) > 0 {
				imported = fmt.Sprint(args[0])
			}
			return `{"ok":true,"restored":["mmsnspost"]}`, nil
		default:
			return "", fmt.Errorf("unexpected frida call %s", fn)
		}
	}

	snsPersistCaptureState(false)
	path := snsCaptureStatePath()
	if path == "" {
		t.Fatalf("样本路径为空")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读取样本失败: %v", err)
	}
	if string(raw) != exportJSON {
		t.Fatalf("样本内容不一致: %s", raw)
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("样本权限应为 0600，实际 %v err=%v", info.Mode().Perm(), err)
	}

	snsRestoreCaptureState()
	if imported != exportJSON {
		t.Fatalf("恢复时未传入样本内容")
	}
}

func TestSNSPublicVisibilityOnlyInProbeTestMode(t *testing.T) {
	setupSNSHTTP(t, true, true)
	if _, se := snsPlanVisibility("public", nil, ""); se == nil {
		t.Fatalf("默认应拒绝 public")
	}
	setSNSProbeForTest(true)
	t.Setenv("SNS_ALLOW_PUBLIC_TEST", "1")
	plan, se := snsPlanVisibility("public", nil, "")
	if se != nil || plan.Visibility != "public" {
		t.Fatalf("联调模式应允许 public: plan=%+v err=%+v", plan, se)
	}
	setSNSProbeForTest(false)
	if _, se := snsPlanVisibility("public", nil, ""); se == nil {
		t.Fatalf("关闭 probe 后应拒绝 public")
	}
}

func TestSNSPostSendsWithCapturedTemplate(t *testing.T) {
	fake := setupSNSHTTP(t, true, true)
	now := time.Unix(1794000000, 0)
	snsNow = func() time.Time { return now }

	template := MarshalSNSPostRequest(SNSPostRequest{
		ObjectDesc:     []byte("<TimelineObject><content>old</content></TimelineObject>"),
		Privacy:        0,
		ClientID:       "sns_post_old",
		ClientCheckDat: []byte("check-dat"),
	})
	template = append(template, 0x9A, 0x06, 0x07)
	template = append(template, []byte("keep-me")...)
	oldCall := snsCallFrida
	t.Cleanup(func() { snsCallFrida = oldCall })
	snsCallFrida = func(fn string, args ...any) (any, error) {
		if fn == "snsCapturedBody" && len(args) > 0 && fmt.Sprint(args[0]) == "post" {
			return fmt.Sprintf(`{"ok":true,"len":%d,"hex":%q}`,
				len(template), hex.EncodeToString(template)), nil
		}
		return "", fmt.Errorf("unexpected frida call %s", fn)
	}
	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		if op != "post" {
			return SNSHookResponse{}, fmt.Errorf("unexpected op %s", op)
		}
		parsed, err := UnmarshalSNSPostRequest(body)
		if err != nil {
			return SNSHookResponse{}, fmt.Errorf("post body parse: %w", err)
		}
		if string(parsed.ClientCheckDat) != "check-dat" {
			return SNSHookResponse{}, fmt.Errorf("ClientCheckDat 丢失: %v", parsed.ClientCheckDat)
		}
		if !strings.Contains(string(parsed.ObjectDesc), "hello-template") {
			return SNSHookResponse{}, fmt.Errorf("正文未替换: %s", parsed.ObjectDesc)
		}
		if !strings.Contains(string(body), "keep-me") {
			return SNSHookResponse{}, fmt.Errorf("未知字段丢失")
		}
		return SNSHookResponse{Body: MarshalSNSPostResponse(SNSPostResponse{
			Base: SNSBaseResponse{},
			Object: &SNSObject{
				ID:         999,
				Username:   "wxid_self",
				CreateTime: uint32(now.Unix()),
			},
		})}, nil
	}

	rec := snsPOST(t, snsPostHandler,
		`{"text":"hello-template","visibility":"private","confirm":true,"client_id":"ok-1"}`, snsTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("发布应成功 200，实际 %d %s", rec.Code, rec.Body.String())
	}
	data := snsDataField(t, rec)
	if data["post_id"] != "999" {
		t.Fatalf("post_id = %v", data["post_id"])
	}
	calls := fake.callsSnapshot()
	if len(calls) != 1 || calls[0].op != "post" {
		t.Fatalf("应提交一次 post 请求: %+v", calls)
	}
	dayStart := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	if n := snsSvc.limiter.countSince("post", dayStart); n != 1 {
		t.Fatalf("成功提交应记录 1 次配额，实际 %d", n)
	}
}

// 4.2.0.17 真机抓包：原生「部分可见」是 Privacy=0 + GroupUsers=[目标好友]。
// 旧实现写 Privacy=2，回包成功但目标好友看不到；这里守住 /sns/post 的端到端编码，
// 同时确认模板原帖的 withUser/分组/blackList 不会泄漏到新动态。
func TestSNSPostPartialUsesNativeVisibilityFields(t *testing.T) {
	fake := setupSNSHTTP(t, true, true)
	now := time.Unix(1794000000, 0)
	snsNow = func() time.Time { return now }
	setSNSPolicyForTest(snsPolicy{PostMinInterval: 0, PostDailyLimit: 50})

	template := MarshalSNSPostRequest(SNSPostRequest{
		ObjectDesc:     []byte("<TimelineObject><content>old</content></TimelineObject>"),
		WithUserList:   []string{"wxid_at"},
		Groups:         []SNSGroup{{GroupID: 42}},
		BlackList:      []string{"wxid_blocked"},
		ClientCheckDat: []byte("check-dat"),
	})
	oldCall := snsCallFrida
	t.Cleanup(func() { snsCallFrida = oldCall })
	snsCallFrida = func(fn string, args ...any) (any, error) {
		if fn == "snsCapturedBody" && len(args) > 0 && fmt.Sprint(args[0]) == "post" {
			return fmt.Sprintf(`{"ok":true,"len":%d,"hex":%q}`,
				len(template), hex.EncodeToString(template)), nil
		}
		return "", fmt.Errorf("unexpected frida call %s", fn)
	}
	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		if op != "post" {
			return SNSHookResponse{}, fmt.Errorf("unexpected op %s", op)
		}
		parsed, err := UnmarshalSNSPostRequest(body)
		if err != nil {
			return SNSHookResponse{}, fmt.Errorf("post body parse: %w", err)
		}
		if parsed.Privacy != 0 {
			return SNSHookResponse{}, fmt.Errorf("Privacy=%d，原生部分可见应为 0", parsed.Privacy)
		}
		if len(parsed.GroupUsers) != 1 || parsed.GroupUsers[0] != "wxid_friend" {
			return SNSHookResponse{}, fmt.Errorf("GroupUsers=%v，应只含目标好友", parsed.GroupUsers)
		}
		if len(parsed.WithUserList) != 0 || len(parsed.Groups) != 0 || len(parsed.BlackList) != 0 {
			return SNSHookResponse{}, fmt.Errorf("模板可见范围残留: withUser=%v groups=%v blackList=%v",
				parsed.WithUserList, parsed.Groups, parsed.BlackList)
		}
		if !strings.Contains(string(parsed.ObjectDesc), "hello-partial") {
			return SNSHookResponse{}, fmt.Errorf("正文未替换: %s", parsed.ObjectDesc)
		}
		if !strings.Contains(string(parsed.ObjectDesc), "<private>0</private>") {
			return SNSHookResponse{}, fmt.Errorf("部分可见 XML 的 private 应为 0: %s", parsed.ObjectDesc)
		}
		return SNSHookResponse{Body: MarshalSNSPostResponse(SNSPostResponse{
			Base: SNSBaseResponse{},
			Object: &SNSObject{
				ID:         1001,
				Username:   "wxid_self",
				CreateTime: uint32(now.Unix()),
			},
		})}, nil
	}

	rec := snsPOST(t, snsPostHandler,
		`{"text":"hello-partial","visibility":"partial","visible_user_ids":["wxid_friend"],"client_id":"partial-1"}`,
		snsTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("部分可见发布应成功 200，实际 %d %s", rec.Code, rec.Body.String())
	}
	data := snsDataField(t, rec)
	if data["post_id"] != "1001" {
		t.Fatalf("post_id = %v", data["post_id"])
	}
}

// 发布（post）必须和其它写操作一样串行（docs/sns.md §3：写请求串行），
// 不能绕过 snsService.write 直连 RPC。
func TestSNSPostWritesAreSerialized(t *testing.T) {
	fake := setupSNSHTTP(t, true, true)
	now := time.Unix(1794000000, 0)
	snsNow = func() time.Time { return now }
	setSNSPolicyForTest(snsPolicy{PostMinInterval: 0, PostDailyLimit: 50})

	template := MarshalSNSPostRequest(SNSPostRequest{
		ObjectDesc:     []byte("<TimelineObject><content>old</content></TimelineObject>"),
		ClientCheckDat: []byte("check-dat"),
	})
	oldCall := snsCallFrida
	t.Cleanup(func() { snsCallFrida = oldCall })
	snsCallFrida = func(fn string, args ...any) (any, error) {
		if fn == "snsCapturedBody" && len(args) > 0 && fmt.Sprint(args[0]) == "post" {
			return fmt.Sprintf(`{"ok":true,"len":%d,"hex":%q}`,
				len(template), hex.EncodeToString(template)), nil
		}
		return "", fmt.Errorf("unexpected frida call %s", fn)
	}
	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		time.Sleep(20 * time.Millisecond) // 留出并发窗口：没串行时 maxActive 会是 2
		return SNSHookResponse{Body: MarshalSNSPostResponse(SNSPostResponse{
			Base: SNSBaseResponse{},
			Object: &SNSObject{
				ID:         1,
				Username:   "wxid_self",
				CreateTime: uint32(now.Unix()),
			},
		})}, nil
	}

	codes := make([]int, 2)
	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			body := fmt.Sprintf(`{"text":"p%d","visibility":"private","client_id":"serial-%d"}`, i, i)
			req := httptest.NewRequest(http.MethodPost, "/sns/unknown", strings.NewReader(body))
			req.Header.Set("Authorization", "Bearer "+snsTestToken)
			rec := httptest.NewRecorder()
			snsPostHandler(rec, req)
			codes[i] = rec.Code
		}(i)
	}
	wg.Wait()
	for i, code := range codes {
		if code != http.StatusOK {
			t.Fatalf("第 %d 次发布应 200，实际 %d", i, code)
		}
	}
	if fake.maxActive != 1 {
		t.Fatalf("发布写请求应串行（maxActive=%d）", fake.maxActive)
	}
	if calls := fake.callsSnapshot(); len(calls) != 2 {
		t.Fatalf("应提交 2 次 post 请求，实际 %d", len(calls))
	}
}

// 发布路径的 503 必须按写通道细分：hook 报告 post 句柄失效（need_prime）时返回
// sns_publish_unavailable，不能退化成读路径的 sns_need_prime（App 文案会误导）。
func TestSNSPostHandleUnavailableMapsToPublishUnavailable(t *testing.T) {
	fake := setupSNSHTTP(t, true, true)
	now := time.Unix(1794000000, 0)
	snsNow = func() time.Time { return now }
	template := MarshalSNSPostRequest(SNSPostRequest{
		ObjectDesc:     []byte("<TimelineObject><content>old</content></TimelineObject>"),
		ClientCheckDat: []byte("check-dat"),
	})
	oldCall := snsCallFrida
	t.Cleanup(func() { snsCallFrida = oldCall })
	snsCallFrida = func(fn string, args ...any) (any, error) {
		if fn == "snsCapturedBody" && len(args) > 0 && fmt.Sprint(args[0]) == "post" {
			return fmt.Sprintf(`{"ok":true,"len":%d,"hex":%q}`,
				len(template), hex.EncodeToString(template)), nil
		}
		return "", fmt.Errorf("unexpected frida call %s", fn)
	}
	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		return SNSHookResponse{}, snsErrorFromHook("need_prime", "")
	}
	rec := snsPOST(t, snsPostHandler,
		`{"text":"hello","visibility":"private","client_id":"unavail-1"}`, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 503 || code != "sns_publish_unavailable" {
		t.Fatalf("post 句柄缺失应 503 sns_publish_unavailable，实际 %d/%s", status, code)
	}
	// 失败尝试不记配额。
	dayStart := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	if n := snsSvc.limiter.countSince("post", dayStart); n != 0 {
		t.Fatalf("失败尝试不应记录配额，实际 %d", n)
	}
}

// TestSNSPostFailureDoesNotConsumeQuota 验证写通道未就绪（必然 503）的失败尝试
// 不扣每日配额/最小间隔——配额只在提交成功后由 recordSNSPostAttempt 记录。
func TestSNSPostFailureDoesNotConsumeQuota(t *testing.T) {
	setupSNSHTTP(t, true, true)
	now := time.Unix(1794000000, 0)
	snsNow = func() time.Time { return now }

	for i := 0; i < 8; i++ {
		body := fmt.Sprintf(`{"text":"fail %d","client_id":"quota-%d"}`, i, i)
		rec := snsPOST(t, snsPostHandler, body, snsTestToken)
		if status, code, _ := snsErrFields(t, rec); status != 503 || code != "sns_publish_unavailable" {
			t.Fatalf("第 %d 次失败尝试应 503，实际 %d/%s", i+1, status, code)
		}
	}
	dayStart := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	if n := snsSvc.limiter.countSince("post", dayStart); n != 0 {
		t.Fatalf("失败尝试不应记录配额，实际 %d", n)
	}
	if e := checkSNSPostPolicy(now); e != nil {
		t.Fatalf("连续失败后配额检查应放行: %+v", e)
	}
}

// TestSNSPostIdempotency 验证 client_id 幂等：同键第二次 409 且不重复构造/尝试，
// 不同/空 client_id 行为不变，10 分钟窗口后键过期，校验失败不占用幂等键。
func TestSNSPostIdempotency(t *testing.T) {
	fake := setupSNSHTTP(t, true, true)
	now := time.Unix(1794000000, 0)
	snsNow = func() time.Time { return now }
	dayStart := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())

	body := `{"text":"hello","visibility":"private","client_id":"idem-1"}`
	rec := snsPOST(t, snsPostHandler, body, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 503 || code != "sns_publish_unavailable" {
		t.Fatalf("首次请求应 503，实际 %d/%s", status, code)
	}
	rec = snsPOST(t, snsPostHandler, body, snsTestToken)
	status, code, msg := snsErrFields(t, rec)
	if status != 409 || code != "sns_duplicate_request" {
		t.Fatalf("重复 client_id 应 409 sns_duplicate_request，实际 %d/%s", status, code)
	}
	if msg != "重复的发布请求（幂等键已处理）" {
		t.Fatalf("重复请求错误文案错误: %q", msg)
	}
	if calls := fake.callsSnapshot(); len(calls) != 0 {
		t.Fatalf("发布未就绪/幂等路径不应调用 snsRequest: %v", calls)
	}
	if n := snsSvc.limiter.countSince("post", dayStart); n != 0 {
		t.Fatalf("幂等/失败尝试不应记录配额，实际 %d", n)
	}

	// 不同 client_id 行为不变（仍走到通道未就绪 503）。
	rec = snsPOST(t, snsPostHandler, `{"text":"hello","visibility":"private","client_id":"idem-2"}`, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 503 || code != "sns_publish_unavailable" {
		t.Fatalf("不同 client_id 应仍为 503，实际 %d/%s", status, code)
	}

	// 不提供 client_id：不启用幂等，连续两次仍是 503。
	for i := 0; i < 2; i++ {
		rec = snsPOST(t, snsPostHandler, `{"text":"hello","visibility":"private"}`, snsTestToken)
		if status, code, _ := snsErrFields(t, rec); status != 503 || code != "sns_publish_unavailable" {
			t.Fatalf("空 client_id 第 %d 次应 503，实际 %d/%s", i+1, status, code)
		}
	}

	// 校验失败的请求不登记幂等键：同一 client_id 随后合法请求应正常处理。
	rec = snsPOST(t, snsPostHandler, `{"text":"","client_id":"idem-invalid"}`, snsTestToken)
	if status, _, _ := snsErrFields(t, rec); status != 400 {
		t.Fatalf("空正文应 400，实际 %d", status)
	}
	rec = snsPOST(t, snsPostHandler, `{"text":"hello","visibility":"private","client_id":"idem-invalid"}`, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 503 || code != "sns_publish_unavailable" {
		t.Fatalf("校验失败不应占用幂等键，实际 %d/%s", status, code)
	}

	// 超长 client_id → 400，不占用内存。
	longBody := fmt.Sprintf(`{"text":"hello","client_id":%q}`, strings.Repeat("a", snsPostClientIDMaxLen+1))
	rec = snsPOST(t, snsPostHandler, longBody, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 400 || code != "sns_invalid_request" {
		t.Fatalf("超长 client_id 应 400，实际 %d/%s", status, code)
	}

	// 10 分钟窗口过后同一 client_id 可再次处理（仍先走到通道未就绪 503）。
	now = now.Add(snsPostIdempotencyWindow + time.Second)
	snsNow = func() time.Time { return now }
	rec = snsPOST(t, snsPostHandler, body, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 503 || code != "sns_publish_unavailable" {
		t.Fatalf("窗口过期后同一 client_id 应重新处理，实际 %d/%s", status, code)
	}
}

// ---- /sns/comment / like / objectop --------------------------------------

func TestSNSComment(t *testing.T) {
	fake := setupSNSHTTP(t, true, true)
	now := time.Unix(1794000000, 0)
	snsNow = func() time.Time { return now }
	obj := snsTestObject(100, "post")
	obj.CommentCount = 1
	obj.CommentUserList = []SNSCommentInfo{{
		Username: "wxid_cmt", Nickname: "评论者", Type: 2, Content: "old",
		CreateTime: 1794000100, CommentID2: 77,
	}}
	postID := snsSeedPost(t, fake, obj)

	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		if op != "comment" {
			return SNSHookResponse{}, fmt.Errorf("unexpected op %s", op)
		}
		updated := obj
		updated.CommentCount = 2
		updated.CommentUserList = append(append([]SNSCommentInfo(nil), obj.CommentUserList...), SNSCommentInfo{
			Username: "wxid_self", Nickname: "我", Type: 2, Content: "hello",
			CreateTime: uint32(now.Unix()), CommentID2: 88,
		})
		return SNSHookResponse{Body: MarshalSNSCommentResponse(SNSPostResponse{
			Base: SNSBaseResponse{}, Object: &updated,
		})}, nil
	}

	rec := snsPOST(t, snsCommentHandler, `{"post_id":"100","text":"hello"}`, snsTestToken)
	data := snsDataField(t, rec)
	if _, ok := data["post"]; !ok {
		t.Fatalf("评论响应应带回更新后的动态: %v", data)
	}
	// 回包 diff 出的新评论：App 用它做本地回显/高亮，不能依赖「列表最后一条」。
	if data["comment_id"] != "88" {
		t.Fatalf("应返回新评论 id 88: %v", data)
	}
	if c, ok := data["comment"].(map[string]any); !ok || c["text"] != "hello" {
		t.Fatalf("应返回新评论对象: %v", data["comment"])
	}
	call := fake.lastCall(t)
	if call.op != "comment" {
		t.Fatalf("RPC op 错误: %s", call.op)
	}
	req, err := UnmarshalSNSCommentRequest(call.body)
	if err != nil {
		t.Fatalf("评论请求解码失败: %v", err)
	}
	action := req.Action.CurrentAction
	if req.Action.ID != 100 || action == nil || action.Type != 2 || action.Content != "hello" {
		t.Fatalf("评论请求字段错误: %+v", req.Action)
	}
	if action.FromUsername != "wxid_self" || action.ToUsername != "wxid_author" {
		t.Fatalf("评论用户名错误: %+v", action)
	}
	if !strings.HasPrefix(req.ClientID, "sns_comment:100_") {
		t.Fatalf("clientId 格式错误: %q", req.ClientID)
	}
	if req.Action.ClientID != "" {
		t.Fatalf("SnsActionGroup 不应带 clientId（与真机捕获同构）: %q", req.Action.ClientID)
	}

	// 回复顶层评论：ReplyCommentId2 + ToUsername 指向被回复者。
	now = now.Add(11 * time.Second)
	rec = snsPOST(t, snsCommentHandler, fmt.Sprintf(`{"post_id":%q,"text":"re","reply_comment_id":"77"}`, postID), snsTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("回复失败: %d %s", rec.Code, rec.Body.String())
	}
	req, err = UnmarshalSNSCommentRequest(fake.lastCall(t).body)
	if err != nil {
		t.Fatalf("回复请求解码失败: %v", err)
	}
	if req.Action.CurrentAction.ReplyCommentID2 != 77 ||
		req.Action.CurrentAction.ToUsername != "wxid_cmt" {
		t.Fatalf("回复字段错误: %+v", req.Action.CurrentAction)
	}

	// 10s 内再次评论 → 429。
	rec = snsPOST(t, snsCommentHandler, fmt.Sprintf(`{"post_id":%q,"text":"fast"}`, postID), snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 429 || code != "sns_rate_limited" {
		t.Fatalf("评论频率限制错误: %d/%s", status, code)
	}

	// 未读过的动态 / 不存在的回复目标。
	rec = snsPOST(t, snsCommentHandler, `{"post_id":"999","text":"x"}`, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 404 || code != "sns_post_not_found" {
		t.Fatalf("未知动态应 404，实际 %d/%s", status, code)
	}
	now = now.Add(11 * time.Second)
	rec = snsPOST(t, snsCommentHandler, fmt.Sprintf(`{"post_id":%q,"text":"x","reply_comment_id":"123"}`, postID), snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 404 || code != "sns_comment_not_found" {
		t.Fatalf("未知回复目标应 404，实际 %d/%s", status, code)
	}
}

// 评论失败（评论句柄未捕获）不能占用 10s/20 次频率配额：用户按提示在微信里
// 点一次评论/赞后应立即能重试，而不是先吃一个 429。
func TestSNSCommentFailureDoesNotConsumeRate(t *testing.T) {
	fake := setupSNSHTTP(t, true, true)
	now := time.Unix(1794000000, 0)
	snsNow = func() time.Time { return now }
	obj := snsTestObject(110, "post")
	postID := snsSeedPost(t, fake, obj)

	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		return SNSHookResponse{}, snsErrorFromHook("need_prime", "")
	}
	rec := snsPOST(t, snsCommentHandler, fmt.Sprintf(`{"post_id":%q,"text":"hello"}`, postID), snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 503 || code != "sns_comment_unavailable" {
		t.Fatalf("未捕获评论句柄应 503 sns_comment_unavailable，实际 %d/%s", status, code)
	}

	updated := obj
	updated.CommentCount = 1
	updated.CommentUserList = []SNSCommentInfo{{
		Username: "wxid_self", Nickname: "我", Type: 2, Content: "hello",
		CreateTime: uint32(now.Unix()), CommentID2: 91,
	}}
	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		return SNSHookResponse{Body: MarshalSNSCommentResponse(SNSPostResponse{
			Base: SNSBaseResponse{}, Object: &updated,
		})}, nil
	}
	// 同一时刻立即重试：失败尝试不记账，不应 429。
	rec = snsPOST(t, snsCommentHandler, fmt.Sprintf(`{"post_id":%q,"text":"hello"}`, postID), snsTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("失败后立即重试不应被限流: %d %s", rec.Code, rec.Body.String())
	}
	if data := snsDataField(t, rec); data["comment_id"] != "91" {
		t.Fatalf("重试成功应返回新评论 id: %v", data)
	}
}

// 写回包只带计数/摘要时，不能丢掉缓存里的正文与旧评论（否则后续回复目标消失）。
func TestSNSCommentMergesPartialWriteResponse(t *testing.T) {
	fake := setupSNSHTTP(t, true, true)
	now := time.Unix(1794000000, 0)
	snsNow = func() time.Time { return now }
	obj := snsTestObject(120, "post")
	obj.CommentCount = 1
	obj.CommentUserList = []SNSCommentInfo{{
		Username: "wxid_cmt", Nickname: "评论者", Type: 2, Content: "old",
		CreateTime: 1794000100, CommentID2: 77,
	}}
	postID := snsSeedPost(t, fake, obj)

	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		if op != "comment" {
			return SNSHookResponse{}, fmt.Errorf("unexpected op %s", op)
		}
		// 只回 ID + 计数，没有 ObjectDesc/正文/评论列表。
		return SNSHookResponse{Body: MarshalSNSCommentResponse(SNSPostResponse{
			Base:   SNSBaseResponse{},
			Object: &SNSObject{ID: 120, CommentCount: 2},
		})}, nil
	}
	rec := snsPOST(t, snsCommentHandler, fmt.Sprintf(`{"post_id":%q,"text":"hello"}`, postID), snsTestToken)
	data := snsDataField(t, rec)
	post, ok := data["post"].(map[string]any)
	if !ok {
		t.Fatalf("应返回合并后的动态: %v", data)
	}
	if post["text"] != "post" || len(post["comments"].([]any)) != 1 {
		t.Fatalf("回包摘要不应覆盖缓存正文/旧评论: %v", post)
	}
	if snsJSONNumber(post["comment_count"]) != 2 || post["comments_truncated"] != true {
		t.Fatalf("评论计数应合并且标记截断: %v", post)
	}
	if _, has := data["comment_id"]; has {
		t.Fatalf("无法确定新评论时不应伪造 comment_id: %v", data)
	}

	// 旧评论仍在缓存里 -> 仍可作为回复目标。
	now = now.Add(11 * time.Second)
	rec = snsPOST(t, snsCommentHandler, fmt.Sprintf(`{"post_id":%q,"text":"re","reply_comment_id":"77"}`, postID), snsTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("合并后应仍能回复旧评论: %d %s", rec.Code, rec.Body.String())
	}
}

// 写回包只带新增评论（旧评论缺失）时，也要与写前缓存按 comment_id 合并：
// 旧评论不能丢，否则后续回复旧评论会 404；comments_truncated 按计数重新计算。
func TestSNSCommentMergesPartialCommentList(t *testing.T) {
	fake := setupSNSHTTP(t, true, true)
	now := time.Unix(1794000000, 0)
	snsNow = func() time.Time { return now }
	obj := snsTestObject(140, "post")
	obj.CommentCount = 1
	obj.CommentUserList = []SNSCommentInfo{{
		Username: "wxid_cmt", Nickname: "评论者", Type: 2, Content: "old",
		CreateTime: 1794000100, CommentID2: 77,
	}}
	postID := snsSeedPost(t, fake, obj)

	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		if op != "comment" {
			return SNSHookResponse{}, fmt.Errorf("unexpected op %s", op)
		}
		// 回包只带本次新增评论（旧评论不在列表里），且计数是更新后的全量。
		return SNSHookResponse{Body: MarshalSNSCommentResponse(SNSPostResponse{
			Base: SNSBaseResponse{},
			Object: &SNSObject{
				ID:           140,
				CommentCount: 2,
				CommentUserList: []SNSCommentInfo{{
					Username: "wxid_self", Nickname: "我", Type: 2, Content: "hello",
					CreateTime: uint32(now.Unix()), CommentID2: 88,
				}},
			},
		})}, nil
	}
	rec := snsPOST(t, snsCommentHandler, fmt.Sprintf(`{"post_id":%q,"text":"hello"}`, postID), snsTestToken)
	data := snsDataField(t, rec)
	post := data["post"].(map[string]any)
	comments := post["comments"].([]any)
	if len(comments) != 2 {
		t.Fatalf("回包新增评论应与你写前缓存合并为 2 条，实际 %d: %v", len(comments), comments)
	}
	if data["comment_id"] != "88" {
		t.Fatalf("应 diff 出本次新评论 88: %v", data)
	}
	if snsJSONNumber(post["comment_count"]) != 2 || post["comments_truncated"] == true {
		t.Fatalf("计数=列表长度时不应标记截断: %v", post)
	}
	if cached, ok := snsSvc.lookupPost(140); !ok || len(cached.Comments) != 2 {
		t.Fatalf("缓存应保留合并后的评论: %+v", cached.Comments)
	}

	// 旧评论仍可作为回复目标。
	now = now.Add(11 * time.Second)
	rec = snsPOST(t, snsCommentHandler, fmt.Sprintf(`{"post_id":%q,"text":"re","reply_comment_id":"77"}`, postID), snsTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("合并后应仍能回复旧评论: %d %s", rec.Code, rec.Body.String())
	}
	if _, err := UnmarshalSNSCommentRequest(fake.lastCall(t).body); err != nil {
		t.Fatalf("回复请求构造失败: %v", err)
	}
}

// 回复评论的展示名：优先用回包 ReplyUsername 查通讯录，查不到用评论列表兜底。
func TestSNSCommentReplyToName(t *testing.T) {
	obj := snsTestObject(130, "post")
	obj.CommentUserList = []SNSCommentInfo{
		{Username: "wxid_a", Nickname: "甲", Type: 2, Content: "top", CommentID2: 11},
		{Username: "wxid_b", Nickname: "乙", Type: 2, Content: "re",
			ReplyCommentID2: 11, ReplyUsername: "wxid_a", CommentID2: 12},
	}
	post := snsNormalizePost(&obj, false)
	if len(post.Comments) != 2 {
		t.Fatalf("评论数错误: %v", post.Comments)
	}
	if post.Comments[1].ReplyTo != "11" || post.Comments[1].ReplyToName != "甲" {
		t.Fatalf("回复展示名兜底错误: %+v", post.Comments[1])
	}
}

func TestSNSStatusOpSeedReady(t *testing.T) {
	m := map[string]any{
		"mmsnscomment": map[string]any{"op": "0xd5", "hasSeed": true},
	}
	if !snsStatusOpSeedReady(m, "mmsnscomment") {
		t.Fatal("hasSeed=true 应视为评论句柄就绪")
	}
	if snsStatusOpSeedReady(m, "mmsnspost") {
		t.Fatal("未捕获的 op 不应视为就绪")
	}
	if snsStatusOpSeedReady(map[string]any{"mmsnscomment": "yes"}, "mmsnscomment") {
		t.Fatal("非对象记录不应视为就绪")
	}
}

func TestSNSLike(t *testing.T) {
	fake := setupSNSHTTP(t, true, true)
	now := time.Unix(1794000000, 0)
	snsNow = func() time.Time { return now }
	obj := snsTestObject(200, "post")
	postID := snsSeedPost(t, fake, obj)

	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		switch op {
		case "comment":
			updated := obj
			updated.LikeFlag = 1
			updated.LikeCount = 1
			return SNSHookResponse{Body: MarshalSNSCommentResponse(SNSPostResponse{
				Base: SNSBaseResponse{}, Object: &updated,
			})}, nil
		case "objectop":
			return SNSHookResponse{Body: MarshalSNSObjectOpResponse(SNSObjectOpResponse{
				Base: SNSBaseResponse{}, OpRetList: []int32{0},
			})}, nil
		default:
			return SNSHookResponse{}, fmt.Errorf("unexpected op %s", op)
		}
	}

	rec := snsPOST(t, snsLikeHandler, fmt.Sprintf(`{"post_id":%q}`, postID), snsTestToken)
	data := snsDataField(t, rec)
	if data["liked"] != true {
		t.Fatalf("点赞响应错误: %v", data)
	}
	req, err := UnmarshalSNSCommentRequest(fake.lastCall(t).body)
	if err != nil || req.Action.CurrentAction.Type != 1 || req.Action.CurrentAction.Content != "" {
		t.Fatalf("点赞请求字段错误: %+v %v", req, err)
	}

	now = now.Add(11 * time.Second)
	rec = snsPOST(t, snsLikeHandler, fmt.Sprintf(`{"post_id":%q,"cancel":true}`, postID), snsTestToken)
	if rec.Code != http.StatusOK {
		t.Fatalf("取消赞失败: %d %s", rec.Code, rec.Body.String())
	}
	if got := fake.lastCall(t).op; got != "objectop" {
		t.Fatalf("取消赞应走 objectop，实际 %s", got)
	}
	opReq, err := UnmarshalSNSObjectOpRequest(fake.lastCall(t).body)
	if err != nil || len(opReq.Ops) != 1 || opReq.Ops[0].OpType != SNSObjectOpTypeCancelLike ||
		opReq.Ops[0].ID != 200 {
		t.Fatalf("取消赞 objectop 请求错误: %+v %v", opReq, err)
	}
}

func TestSNSObjectOp(t *testing.T) {
	fake := setupSNSHTTP(t, true, true)
	now := time.Unix(1794000000, 0)
	snsNow = func() time.Time { return now }
	postID := snsSeedPost(t, fake, snsTestObject(300, "post"))

	var opRet int32 = 0
	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		if op != "objectop" {
			return SNSHookResponse{}, fmt.Errorf("unexpected op %s", op)
		}
		return SNSHookResponse{Body: MarshalSNSObjectOpResponse(SNSObjectOpResponse{
			Base: SNSBaseResponse{}, OpRetList: []int32{opRet},
		})}, nil
	}
	rec := snsPOST(t, snsObjectOpHandler, fmt.Sprintf(`{"post_id":%q,"op":"delete_comment","comment_id":"77"}`, postID), snsTestToken)
	data := snsDataField(t, rec)
	rets := data["op_ret"].([]any)
	if len(rets) != 1 || snsJSONNumber(rets[0]) != 0 {
		t.Fatalf("objectop 响应错误: %v", data)
	}
	req, err := UnmarshalSNSObjectOpRequest(fake.lastCall(t).body)
	if err != nil || len(req.Ops) != 1 || req.Ops[0].OpType != SNSObjectOpTypeDeleteComment {
		t.Fatalf("objectop 请求错误: %+v %v", req, err)
	}
	del, err := UnmarshalSNSObjectOpDeleteComment(req.Ops[0].Ext)
	if err != nil || del.CommentID != 77 {
		t.Fatalf("delete_comment Ext 错误: %+v %v", del, err)
	}

	// 服务端拒绝 → 502 带 ret。
	now = now.Add(11 * time.Second)
	snsNow = func() time.Time { return now }
	opRet = 204
	rec = snsPOST(t, snsObjectOpHandler, fmt.Sprintf(`{"post_id":%q,"op":"set_private"}`, postID), snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != 502 || code != "sns_native_rejected" {
		t.Fatalf("op ret 非 0 应 502，实际 %d/%s", status, code)
	}
	if got := snsJSONNumber(snsJSONBody(t, rec)["ret"]); got != 204 {
		t.Fatalf("op ret 透传错误: %d", got)
	}

	// 非法 op。
	rec = snsPOST(t, snsObjectOpHandler, fmt.Sprintf(`{"post_id":%q,"op":"nuke"}`, postID), snsTestToken)
	if status, _, _ := snsErrFields(t, rec); status != 400 {
		t.Fatalf("非法 op 应 400，实际 %d", status)
	}
}

func TestSNSWriteConfirm(t *testing.T) {
	setupSNSHTTP(t, true, true)
	for _, ep := range []struct {
		name string
		h    http.HandlerFunc
		body string
	}{
		{"comment", snsCommentHandler, `{"post_id":"1","text":"x","confirm":false}`},
		{"like", snsLikeHandler, `{"post_id":"1","confirm":false}`},
		{"objectop", snsObjectOpHandler, `{"post_id":"1","op":"delete_post","confirm":false}`},
	} {
		rec := snsPOST(t, ep.h, ep.body, snsTestToken)
		if status, code, _ := snsErrFields(t, rec); status != 403 || code != "sns_not_confirmed" {
			t.Fatalf("%s confirm=false 应 403，实际 %d/%s", ep.name, status, code)
		}
	}
}

// ---- 同步事件 best-effort 解码 --------------------------------------------

func TestSNSDecodeSyncCommandObject(t *testing.T) {
	obj := SNSObject{
		ID:         4242,
		Username:   "wxid_author",
		Nickname:   "示例昵称",
		CreateTime: 1700000000,
	}
	buf := MarshalSNSObject(obj)
	events, ok := snsDecodeSyncCommand(1, buf)
	if !ok || len(events) != 1 {
		t.Fatalf("object payload: ok=%v events=%d", ok, len(events))
	}
	if events[0]["type"] != "sns_new_post" {
		t.Fatalf("event type = %v", events[0]["type"])
	}
	data, ok := events[0]["data"].(map[string]any)
	if !ok {
		t.Fatalf("event data type = %T", events[0]["data"])
	}
	post, ok := data["post"].(snsPostJSON)
	if !ok || post.ID != "4242" {
		t.Fatalf("post = %+v", data["post"])
	}
}

func TestSNSDecodeSyncCommandActionGroup(t *testing.T) {
	like := MarshalSNSActionGroup(SNSActionGroup{
		ID: 4242,
		CurrentAction: &SNSAction{
			FromUsername: "wxid_liker",
			Type:         1,
			CreateTime:   1700000001,
		},
	})
	events, ok := snsDecodeSyncCommand(2, like)
	if !ok || len(events) != 1 || events[0]["type"] != "sns_like" {
		t.Fatalf("like payload: ok=%v events=%v", ok, events)
	}

	comment := MarshalSNSActionGroup(SNSActionGroup{
		ID: 4242,
		CurrentAction: &SNSAction{
			FromUsername: "wxid_commenter",
			FromNickname: "示例昵称",
			Type:         2,
			Content:      "评论内容",
			CreateTime:   1700000002,
		},
	})
	events, ok = snsDecodeSyncCommand(3, comment)
	if !ok || len(events) != 1 || events[0]["type"] != "sns_comment" {
		t.Fatalf("comment payload: ok=%v events=%v", ok, events)
	}
}

func TestSNSDecodeSyncCommandRejectsUnknown(t *testing.T) {
	if _, ok := snsDecodeSyncCommand(9, nil); !ok {
		t.Fatalf("empty command should be supported")
	}
	if _, ok := snsDecodeSyncCommand(9, []byte{0xde, 0xad, 0xbe, 0xef}); ok {
		t.Fatalf("garbage payload must not decode into events")
	}
	// 自洽性不足（缺作者/时间）的对象不得产出事件。
	buf := MarshalSNSObject(SNSObject{ID: 7})
	if _, ok := snsDecodeSyncCommand(1, buf); ok {
		t.Fatalf("incomplete object must not decode")
	}
}

// 真机抓包对齐：评论请求必须带 FromNickname（自己不在通讯录时用动态作者名兜底）、
// ToNickname 用对方 wxid、SnsAction field 23 = 0；否则 mac 服务端会静默丢弃。
func TestSNSBuildCommentRequestMatchesCapturedShape(t *testing.T) {
	oldID := myWechatId
	myWechatId = "wxid_self"
	t.Cleanup(func() { myWechatId = oldID })

	post := snsPostJSON{ID: "15050352638144033321", AuthorID: "wxid_self", AuthorName: "示例昵称"}
	req, se := snsBuildCommentRequest(post, 2, "验证评论", nil)
	if se != nil {
		t.Fatalf("构造失败: %+v", se)
	}
	action := req.Action.CurrentAction
	if action == nil {
		t.Fatal("缺少 CurrentAction")
	}
	if action.FromNickname != "示例昵称" {
		t.Fatalf("评论自己的动态时 FromNickname 应退回作者名: %q", action.FromNickname)
	}
	if action.ToNickname != "wxid_self" {
		t.Fatalf("ToNickname 应与抓包一致使用 wxid: %q", action.ToNickname)
	}
	raw := MarshalSNSCommentRequest(req)
	var hasField23 bool
	if err := snsWalk(raw, func(f snsWireField) error {
		if f.num == 2 && f.typ == protowire.BytesType {
			if err := snsWalk(f.bytes, func(g snsWireField) error {
				if g.num == 3 && g.typ == protowire.BytesType {
					return snsWalk(g.bytes, func(a snsWireField) error {
						if a.num == 23 && a.typ == protowire.VarintType {
							hasField23 = true
						}
						return nil
					})
				}
				return nil
			}); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		t.Fatalf("解析请求失败: %v", err)
	}
	if !hasField23 {
		t.Fatalf("评论请求缺少 SnsAction field 23: %x", raw)
	}
}

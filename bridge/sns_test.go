package main

// SNS 状态层测试：开关解析、并发串行、超时、限流、缓存、错误映射与归一化。
// 全部使用 fake RPC/临时文件，不连接微信或 Frida。

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestSNSFeatureConfigFromHookJSON(t *testing.T) {
	oldConf := config.WechatConf
	oldRead, oldWrite := snsReadEnabled(), snsWriteEnabled()
	t.Cleanup(func() {
		config.WechatConf = oldConf
		setSNSFeaturesForTest(oldRead, oldWrite)
	})

	dir := t.TempDir()
	cases := []struct {
		name  string
		body  string
		read  bool
		write bool
	}{
		{"strings", `{"snsEnable":"true","snsWrite":"true"}`, true, true},
		{"bools", `{"snsEnable":true,"snsWrite":false}`, true, false},
		{"off", `{"snsEnable":"false","snsWrite":"0"}`, false, false},
		{"missing", `{}`, false, false},
		{"invalid", `not-json`, false, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(dir, tc.name+".json")
			if err := os.WriteFile(path, []byte(tc.body), 0o600); err != nil {
				t.Fatalf("写临时配置失败: %v", err)
			}
			config.WechatConf = path
			initSNSConfig()
			if snsReadEnabled() != tc.read || snsWriteEnabled() != tc.write {
				t.Fatalf("开关解析错误: read=%v write=%v want %v/%v",
					snsReadEnabled(), snsWriteEnabled(), tc.read, tc.write)
			}
		})
	}
}

func TestSNSTimeouts(t *testing.T) {
	cases := map[string]time.Duration{
		"timeline": snsDefaultTimeout,
		"detail":   snsLongTimeout,
		"sync":     snsLongTimeout,
		"post":     snsWriteTimeout,
		"comment":  snsWriteTimeout,
		"like":     snsWriteTimeout,
		"objectop": snsWriteTimeout,
		"unknown":  snsDefaultTimeout,
	}
	for op, want := range cases {
		if got := snsTimeoutFor(op); got != want {
			t.Fatalf("op=%s timeout=%s want %s", op, got, want)
		}
	}
}

func TestSNSReadSerialization(t *testing.T) {
	oldSvc := snsSvc
	oldRPC := snsRPC
	t.Cleanup(func() { snsSvc = oldSvc; snsRPC = oldRPC })

	fake := &fakeSNSRPC{}
	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		time.Sleep(5 * time.Millisecond)
		return SNSHookResponse{Body: []byte{}}, nil
	}
	snsSvc = newSNSService()
	snsRPC = fake

	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			_, _ = snsSvc.read(ctx, "timeline", []byte{0x12, 0x00})
		}()
	}
	wg.Wait()
	fake.mu.Lock()
	maxActive := fake.maxActive
	fake.mu.Unlock()
	if maxActive != 1 {
		t.Fatalf("读取请求应串行（maxActive=%d）", maxActive)
	}
}

func TestSNSWriteSerialization(t *testing.T) {
	oldSvc := snsSvc
	oldRPC := snsRPC
	t.Cleanup(func() { snsSvc = oldSvc; snsRPC = oldRPC })

	fake := &fakeSNSRPC{}
	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		time.Sleep(3 * time.Millisecond)
		return SNSHookResponse{Body: []byte{}}, nil
	}
	snsSvc = newSNSService()
	snsRPC = fake
	var wg sync.WaitGroup
	for i := 0; i < 3; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			_, _ = snsSvc.write(ctx, "comment", []byte{0x12, 0x00})
		}()
	}
	wg.Wait()
	if fake.maxActive != 1 {
		t.Fatalf("写请求应串行（maxActive=%d）", fake.maxActive)
	}
}

func TestSNSRateLimiter(t *testing.T) {
	limiter := newSNSRateLimiter()
	now := time.Unix(1794000000, 0)

	ok, _ := limiter.allow("comment", now)
	if !ok {
		t.Fatal("首次评论应放行")
	}
	ok, wait := limiter.allow("comment", now.Add(time.Second))
	if ok {
		t.Fatal("10s 内第二次评论应被限流")
	}
	if wait < 8*time.Second || wait > 10*time.Second {
		t.Fatalf("重试等待时间异常: %s", wait)
	}
	ok, _ = limiter.allow("comment", now.Add(11*time.Second))
	if !ok {
		t.Fatal("间隔满足后应放行")
	}

	// 每小时上限 20 次：模拟 10s 一次，第 21 次应被拒。
	limiter = newSNSRateLimiter()
	base := time.Unix(1794000000, 0)
	for i := 0; i < 20; i++ {
		ts := base.Add(time.Duration(i) * 11 * time.Second)
		if ok, _ := limiter.allow("comment", ts); !ok {
			t.Fatalf("第 %d 次评论不应被限流", i+1)
		}
	}
	if ok, _ := limiter.allow("comment", base.Add(20*11*time.Second)); ok {
		t.Fatal("超过每小时 20 次应被限流")
	}

}

func TestCheckSNSWriteRate429(t *testing.T) {
	oldSvc := snsSvc
	oldNow := snsNow
	t.Cleanup(func() { snsSvc = oldSvc; snsNow = oldNow })
	snsSvc = newSNSService()
	now := time.Unix(1794000000, 0)
	snsNow = func() time.Time { return now }
	// 校验与记账分离：check 只读，连续 check 不应互相限流。
	if e := checkSNSWriteRate("comment"); e != nil {
		t.Fatalf("首次不应限流: %v", e)
	}
	if e := checkSNSWriteRate("comment"); e != nil {
		t.Fatalf("未提交成功前重复校验不应限流: %v", e)
	}
	// 真正提交成功后才记账；随后 10s 内的 check 应返回 429。
	recordSNSWriteRate("comment")
	if e := checkSNSWriteRate("comment"); e == nil || e.Status != 429 || e.Code != "sns_rate_limited" {
		t.Fatalf("成功后 10s 内应返回 429: %+v", e)
	}
	now = now.Add(11 * time.Second)
	if e := checkSNSWriteRate("comment"); e != nil {
		t.Fatalf("间隔后应放行: %v", e)
	}
}

func TestSNSMediaDir(t *testing.T) {
	old := config.MediaDir
	t.Cleanup(func() { config.MediaDir = old })

	config.MediaDir = "/tmp/WeChatAI/accounts/wxid_demo/media"
	if got, want := snsMediaDir(), "/tmp/WeChatAI/accounts/wxid_demo/sns-media"; got != want {
		t.Fatalf("media_dir 推导错误: %q want %q", got, want)
	}
	config.MediaDir = "/tmp/custom"
	if got, want := snsMediaDir(), "/tmp/custom/sns-media"; got != want {
		t.Fatalf("非 media 结尾目录推导错误: %q want %q", got, want)
	}
	config.MediaDir = ""
	if got := snsMediaDir(); got != "" {
		t.Fatalf("空 media_dir 应返回空: %q", got)
	}
}

func TestSNSPathWithin(t *testing.T) {
	base := "/tmp/sns-media"
	if !snsPathWithin(base, "/tmp/sns-media/a.jpg") {
		t.Fatal("目录内文件应通过")
	}
	if !snsPathWithin(base, "/tmp/sns-media") {
		t.Fatal("目录自身应通过")
	}
	for _, bad := range []string{"/tmp/sns-media/../x", "/etc/passwd", "/tmp/sns-media2/a", ""} {
		if snsPathWithin(base, bad) {
			t.Fatalf("越界路径不应通过: %q", bad)
		}
	}
}

func TestSNSDecodeOptionalBase64(t *testing.T) {
	raw := []byte{0x08, 0x01, 0xff}
	want := []string{
		base64.StdEncoding.EncodeToString(raw),
		base64.RawStdEncoding.EncodeToString(raw),
		base64.URLEncoding.EncodeToString(raw),
		base64.RawURLEncoding.EncodeToString(raw),
		"",
	}
	for _, s := range want {
		got, err := snsDecodeOptionalBase64(s)
		if err != nil {
			t.Fatalf("base64 解码失败 %q: %v", s, err)
		}
		if s == "" {
			if len(got) != 0 {
				t.Fatalf("空串应返回空字节: %x", got)
			}
			continue
		}
		if string(got) != string(raw) {
			t.Fatalf("base64 回读不一致: %x", got)
		}
	}
	if _, err := snsDecodeOptionalBase64("not base64!!!"); err == nil {
		t.Fatal("非法 base64 应返回错误")
	}
}

func TestSNSParseSNSID(t *testing.T) {
	if id, err := parseSNSID("18446744073709551615"); err != nil || id != 18446744073709551615 {
		t.Fatalf("uint64 上限解析失败: %d %v", id, err)
	}
	for _, bad := range []string{"", "abc", "18446744073709551616", "-1", "12 34"} {
		if _, err := parseSNSID(bad); err == nil {
			t.Fatalf("非法 ID 应报错: %q", bad)
		}
	}
}

func TestSNSNormalizePost(t *testing.T) {
	xml := `<TimelineObject><id>1</id><username>wxid_author</username>` +
		`<createTime>1794000000</createTime><contentDesc>正文</contentDesc>` +
		`<ContentObject><contentStyle>1</contentStyle><mediaList>` +
		`<media><type>2</type><url type="1">full-key</url><thumb type="1">thumb-key</thumb>` +
		`<size width="1080.0" height="1440.0"></size></media></mediaList></ContentObject></TimelineObject>`
	obj := &SNSObject{
		ID:         99,
		Username:   "wxid_author",
		Nickname:   "作者",
		CreateTime: 1794000001,
		ObjectDesc: []byte(xml),
		LikeFlag:   1,
		LikeCount:  2,
		LikeUserList: []SNSCommentInfo{
			{Username: "wxid_a", Nickname: "A", Type: 1},
			{Username: "wxid_a", Nickname: "A", Type: 1},
			{Username: "wxid_deleted", Nickname: "X", Type: 1, DeleteFlag: 1},
		},
		CommentCount: 3, // 服务端计数 > 列表长度，表示时间线评论被截断
		CommentUserList: []SNSCommentInfo{
			{Username: "wxid_b", Nickname: "B", Type: 2, Content: "评论", CreateTime: 1794000002, CommentID2: 77, ReplyCommentID2: 76},
			{Username: "wxid_c", Type: 1}, // 点赞混在评论列表里
			{Username: "wxid_d", Type: 2, Content: "已删除", DeleteFlag: 1},
		},
	}
	post := snsNormalizePost(obj, true)
	if post.ID != "99" || post.AuthorID != "wxid_author" || post.AuthorName != "作者" ||
		post.CreateTime != 1794000001 || post.Text != "正文" {
		t.Fatalf("基础字段错误: %+v", post)
	}
	if len(post.Media) != 1 || post.Media[0].Kind != "image" ||
		post.Media[0].ThumbKey != "thumb-key" || post.Media[0].URLKey != "full-key" ||
		post.Media[0].Width != 1080 || post.Media[0].Height != 1440 {
		t.Fatalf("媒体归一化错误: %+v", post.Media)
	}
	if len(post.Comments) != 1 || post.Comments[0].CommentID != "77" ||
		post.Comments[0].ReplyTo != "76" || post.Comments[0].Text != "评论" {
		t.Fatalf("评论归一化错误: %+v", post.Comments)
	}
	if !post.CommentsTruncated {
		t.Fatal("CommentCount 大于列表长度应标记 comments_truncated")
	}
	if len(post.Likes) != 1 || post.Likes[0].UserID != "wxid_a" {
		t.Fatalf("点赞去重/过滤错误: %+v", post.Likes)
	}
	if !post.Liked || post.LikeCount != 2 {
		t.Fatalf("liked/like_count 错误: %+v", post)
	}
}

func TestSNSNormalizePostTruncation(t *testing.T) {
	longText := strings.Repeat("好", 2500)
	obj := &SNSObject{
		ID:         1,
		Username:   "wxid_author",
		ObjectDesc: []byte("<TimelineObject><contentDesc>" + longText + "</contentDesc></TimelineObject>"),
	}
	post := snsNormalizePost(obj, false)
	if !post.TextTruncated {
		t.Fatal("超长正文应标记 text_truncated")
	}
	if n := len([]rune(post.Text)); n != snsTextRuneLimit {
		t.Fatalf("正文应截断到 %d 字符，实际 %d", snsTextRuneLimit, n)
	}
}

func TestSNSNormalizePostRawObjectDesc(t *testing.T) {
	// 少数版本/空对象里 ObjectDesc 可能不是 XML，按裸文本降级。
	obj := &SNSObject{ID: 2, Username: "wxid_a", ObjectDesc: []byte("plain text")}
	post := snsNormalizePost(obj, false)
	if post.Text != "plain text" {
		t.Fatalf("裸文本降级失败: %q", post.Text)
	}
}

func TestSNSRememberPostsCache(t *testing.T) {
	oldID := myWechatId
	t.Cleanup(func() { myWechatId = oldID })
	myWechatId = "wxid_self"
	svc := newSNSService()

	posts := make([]snsPostJSON, 0, snsPostCacheLimit+10)
	for i := 0; i < snsPostCacheLimit+10; i++ {
		posts = append(posts, snsPostJSON{ID: fmt.Sprint(i + 1), AuthorID: "wxid_a", AuthorName: "A"})
	}
	svc.rememberPosts(posts)
	if _, ok := svc.lookupPost(1); ok {
		t.Fatal("最旧帖子应被淘汰")
	}
	if _, ok := svc.lookupPost(uint64(snsPostCacheLimit + 10)); !ok {
		t.Fatal("最新帖子应在缓存中")
	}

	// 切号后缓存失效。
	myWechatId = "wxid_other"
	if _, ok := svc.lookupPost(uint64(snsPostCacheLimit + 10)); ok {
		t.Fatal("切号后不应命中旧账号缓存")
	}
}

func TestSNSHookErrorMapping(t *testing.T) {
	cases := []struct {
		reason string
		status int
		code   string
	}{
		{"unsupported", 503, "sns_unsupported"},
		{"seed_missing", 503, "sns_not_ready"},
		{"timeout", 504, "sns_timeout"},
		{"parse_failed", 502, "sns_parse_failed"},
		{"native_rejected", 502, "sns_native_rejected"},
		{"invalid_param", 400, "sns_invalid_request"},
		{"publish_disabled", 403, "sns_write_disabled"},
		{"send_failed", 502, "sns_send_failed"},
		{"need_prime", 503, "sns_need_prime"},
		{"open_moments_once", 503, "sns_need_prime"},
		{"not_implemented", 503, "sns_media_unavailable"},
		{"weird_new_error", 502, "sns_hook_error"},
	}
	for _, tc := range cases {
		e := snsErrorFromHook(tc.reason, "internal detail")
		if e.Status != tc.status || e.Code != tc.code {
			t.Fatalf("reason=%s → %d/%s，期望 %d/%s", tc.reason, e.Status, e.Code, tc.status, tc.code)
		}
	}
	if e := snsHTTPError(context.DeadlineExceeded); e.Status != 504 || e.Code != "sns_timeout" {
		t.Fatalf("ctx 超时应映射 504: %+v", e)
	}
	se := &snsError{Status: 429, Code: "sns_rate_limited", Message: "x"}
	if got := snsHTTPError(se); got != se {
		t.Fatal("snsError 应原样透传")
	}
	if e := snsHTTPError(errors.New("boom")); e.Status != 502 || e.Code != "sns_hook_error" {
		t.Fatalf("未知错误应映射 502: %+v", e)
	}
}

func TestSNSJSONHelpers(t *testing.T) {
	var m map[string]any
	if err := decodeSNSHookJSON(`{"ok":true}`, &m); err != nil || m["ok"] != true {
		t.Fatalf("string JSON 解析失败: %v %v", m, err)
	}
	m = nil
	if err := decodeSNSHookJSON(map[string]any{"ok": true}, &m); err != nil || m["ok"] != true {
		t.Fatalf("map JSON 解析失败: %v %v", m, err)
	}
	if err := decodeSNSHookJSON("", &m); err == nil {
		t.Fatal("空 hook 返回应报错")
	}
	if got := snsMapBool(map[string]any{"seed_ready": "true"}, "seedReady", "seed_ready"); !got {
		t.Fatal("snake_case bool 解析失败")
	}
	if got := snsMapString(map[string]any{"last_error": "x"}, "lastError", "last_error"); got != "x" {
		t.Fatal("snake_case string 解析失败")
	}
	if got := snsMapInt64(map[string]any{"elapsedMs": float64(12)}, "elapsedMs"); got != 12 {
		t.Fatal("int64 解析失败")
	}
}

func TestSNSFridaAdapterContextTimeout(t *testing.T) {
	oldCall := snsCallFrida
	t.Cleanup(func() { snsCallFrida = oldCall })
	release := make(chan struct{})
	snsCallFrida = func(fn string, args ...any) (any, error) {
		<-release
		return `{"ok":true,"ready":true}`, nil
	}
	t.Cleanup(func() { close(release) })

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	_, err := (fridaSNSPRC{}).Status(ctx)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("应在 bridge 超时后返回 DeadlineExceeded，实际 %v", err)
	}
}

func TestSNSFridaAdapterErrors(t *testing.T) {
	oldCall := snsCallFrida
	t.Cleanup(func() { snsCallFrida = oldCall })

	snsCallFrida = func(fn string, args ...any) (any, error) {
		switch fn {
		case "snsRequest":
			return `{"ok":false,"error":"seed_missing","message":"open moments first"}`, nil
		case "snsStatus":
			return nil, errors.New("frida 未就绪")
		}
		return nil, nil
	}
	ctx := context.Background()
	var nilResp SNSHookResponse
	if _, err := (fridaSNSPRC{}).Request(ctx, "timeline", nil, time.Second); err == nil {
		t.Fatal("hook ok=false 应返回错误")
	} else {
		se := snsHTTPError(err)
		if se.Status != 503 || se.Code != "sns_not_ready" {
			t.Fatalf("seed_missing 映射错误: %+v", se)
		}
	}
	if _, err := (fridaSNSPRC{}).Status(ctx); err == nil {
		t.Fatal("Frida 调用失败应透传错误")
	}
	_ = nilResp
}

// captured 只统计任务类型；body_captured 必须按 timeline 记录的 bodyLen 判定，
// 否则 4.2.0.12（缺 bodyReturn 锚点）会被误判成「可主动刷新」。
func TestSNSStatusParsesTimelineBodyCaptured(t *testing.T) {
	oldCall := snsCallFrida
	t.Cleanup(func() { snsCallFrida = oldCall })

	cases := []struct {
		name string
		raw  string
		want bool
	}{
		{
			name: "body captured",
			raw:  `{"ok":true,"enabled":true,"ready":true,"captured":2,"mmsnstimeline":{"op":"0xd3","bodyLen":321,"hasSeed":true}}`,
			want: true,
		},
		{
			name: "task captured without body",
			raw:  `{"ok":true,"enabled":true,"ready":true,"captured":2,"mmsnstimeline":{"op":"0xd3","bodyLen":0,"hasSeed":true}}`,
			want: false,
		},
		{
			name: "no timeline record",
			raw:  `{"ok":true,"enabled":true,"ready":false,"captured":0}`,
			want: false,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			snsCallFrida = func(fn string, args ...any) (any, error) {
				return tc.raw, nil
			}
			st, err := (fridaSNSPRC{}).Status(context.Background())
			if err != nil {
				t.Fatalf("Status 解析失败: %v", err)
			}
			if st.TimelineBodyReady != tc.want {
				t.Fatalf("TimelineBodyReady=%v want %v (raw=%s)", st.TimelineBodyReady, tc.want, tc.raw)
			}
		})
	}
}

func TestSNSNoRealAccountDataInFixtures(t *testing.T) {
	// fixture 里只允许出现等长占位符；真实 wxid 形状（wxid_ + 非 x 字符）不应出现。
	raw := snsMustHex(t, snsFixtureCommentRequestHex)
	req, err := UnmarshalSNSCommentRequest(raw)
	if err != nil {
		t.Fatalf("comment fixture 解码失败: %v", err)
	}
	a := req.Action.CurrentAction
	for _, s := range []string{a.FromUsername, a.ToUsername, a.FromNickname, a.ToNickname} {
		if strings.Contains(s, "wxid_") {
			rest := strings.TrimPrefix(s, "wxid_")
			if strings.Trim(rest, "x") != "" {
				t.Fatalf("fixture 可能包含真实 wxid: %q", s)
			}
		}
	}
	if a.Content != strings.Repeat("c", len(a.Content)) {
		t.Fatalf("fixture 评论正文未脱敏: %q", a.Content)
	}
	if !strings.HasPrefix(req.ClientID, "sns_comment:1777") {
		t.Fatalf("fixture clientId 未脱敏: %q", req.ClientID)
	}
}

func TestSNSPlanVisibility(t *testing.T) {
	cases := []struct {
		name       string
		visibility string
		ids        []string
		target     string
		wantVis    string
		wantIDs    []string
		wantStatus int
		wantCode   string
	}{
		{"default_no_context", "", nil, "", "private", nil, 0, ""},
		{"partial_target", "partial", nil, "wxid_friend", "partial", []string{"wxid_friend"}, 0, ""},
		{"partial_same_target", "partial", []string{"wxid_friend"}, "wxid_friend", "partial", []string{"wxid_friend"}, 0, ""},
		{"partial_mismatch", "partial", []string{"wxid_friend"}, "wxid_other", "", nil, 403, "sns_visibility_mismatch"},
		{"partial_multi", "partial", []string{"wxid_a", "wxid_b"}, "", "", nil, 403, "sns_visibility_unsupported"},
		{"partial_empty_ids", "partial", []string{"", " "}, "", "private", nil, 0, ""},
		{"private", "private", nil, "", "private", nil, 0, ""},
		{"public_rejected", "public", nil, "", "", nil, 403, "sns_visibility_unsupported"},
		{"invalid", "friends", nil, "", "", nil, 400, "sns_invalid_visibility"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			plan, se := snsPlanVisibility(tc.visibility, tc.ids, tc.target)
			if tc.wantStatus != 0 {
				if se == nil || se.Status != tc.wantStatus || se.Code != tc.wantCode {
					t.Fatalf("期望 %d/%s，实际 %+v", tc.wantStatus, tc.wantCode, se)
				}
				return
			}
			if se != nil {
				t.Fatalf("不应报错: %+v", se)
			}
			if plan.Visibility != tc.wantVis {
				t.Fatalf("visibility=%s want %s", plan.Visibility, tc.wantVis)
			}
			if len(plan.VisibleUserIDs) != len(tc.wantIDs) {
				t.Fatalf("ids=%v want %v", plan.VisibleUserIDs, tc.wantIDs)
			}
			for i := range tc.wantIDs {
				if plan.VisibleUserIDs[i] != tc.wantIDs[i] {
					t.Fatalf("ids=%v want %v", plan.VisibleUserIDs, tc.wantIDs)
				}
			}
			// 4.2 真机：partial 与 public 的 Privacy 都是 0，可见范围由 GroupUsers 表达；
			// 只有 private 用 1。把 partial 写成 2 会让目标好友看不到动态。
			wantPrivacy := uint32(0)
			if tc.wantVis == "private" {
				wantPrivacy = 1
			}
			if plan.Privacy != wantPrivacy {
				t.Fatalf("privacy=%d want %d", plan.Privacy, wantPrivacy)
			}
		})
	}
}

func TestSNSPolicyConfigParse(t *testing.T) {
	raw := map[string]any{
		"snsPostMinIntervalMs": "900000",
		"snsPostDailyLimit":    float64(3),
		"snsPostTimeWindows":   []any{"09:00-12:00", "23:30-01:30", "bad"},
	}
	p := parseSNSPolicy(raw)
	if p.PostMinInterval != 15*time.Minute || p.PostDailyLimit != 3 {
		t.Fatalf("策略解析错误: %+v", p)
	}
	if len(p.PostWindows) != 2 {
		t.Fatalf("时间窗解析错误: %+v", p.PostWindows)
	}
	if p.PostWindows[0].StartMinute != 9*60 || p.PostWindows[0].EndMinute != 12*60 {
		t.Fatalf("时间窗边界错误: %+v", p.PostWindows[0])
	}

	// 默认值。
	def := parseSNSPolicy(map[string]any{})
	if def.PostMinInterval != 10*time.Minute || def.PostDailyLimit != 5 || len(def.PostWindows) != 0 {
		t.Fatalf("默认策略错误: %+v", def)
	}

	if w, ok := parseSNSTimeWindow("22:00-06:00"); !ok || !w.contains(23*60) || !w.contains(1*60) || w.contains(12*60) {
		t.Fatalf("跨午夜窗口解析错误: %+v", w)
	}
	for _, bad := range []string{"09:00", "25:00-26:00", "9-10", ""} {
		if _, ok := parseSNSTimeWindow(bad); ok {
			t.Fatalf("非法时间窗应失败: %q", bad)
		}
	}
}

func TestCheckSNSPostPolicy(t *testing.T) {
	oldSvc := snsSvc
	oldPolicy := currentSNSPolicy()
	t.Cleanup(func() { snsSvc = oldSvc; setSNSPolicyForTest(oldPolicy) })
	snsSvc = newSNSService()

	now := time.Date(2026, 11, 7, 12, 0, 0, 0, time.Local)
	setSNSPolicyForTest(snsPolicy{
		PostMinInterval: 10 * time.Minute,
		PostDailyLimit:  2,
		PostWindows:     []snsTimeWindow{{StartMinute: 9 * 60, EndMinute: 22 * 60}},
	})
	dayStart := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	// 只检查不记录：通过检查本身不消耗配额/不启动最小间隔。
	if e := checkSNSPostPolicy(now); e != nil {
		t.Fatalf("窗口内首次发布应放行: %+v", e)
	}
	if n := snsSvc.limiter.countSince("post", dayStart); n != 0 {
		t.Fatalf("checkSNSPostPolicy 不应记录发布，实际 %d", n)
	}
	recordSNSPostAttempt(now)
	if e := checkSNSPostPolicy(now.Add(time.Minute)); e == nil || e.Code != "sns_rate_limited" || e.RetryAfterSeconds <= 0 {
		t.Fatalf("最小间隔应 429 并带 retry_after: %+v", e)
	}
	if e := checkSNSPostPolicy(now.Add(11 * time.Minute)); e != nil {
		t.Fatalf("间隔后第二次发布应放行: %+v", e)
	}
	recordSNSPostAttempt(now.Add(11 * time.Minute))
	if e := checkSNSPostPolicy(now.Add(22 * time.Minute)); e == nil || e.Code != "sns_daily_limit" || e.RetryAfterSeconds <= 0 {
		t.Fatalf("每日上限应 429 sns_daily_limit: %+v", e)
	}

	// 时段外 409。
	setSNSPolicyForTest(snsPolicy{PostMinInterval: 0, PostDailyLimit: 5,
		PostWindows: []snsTimeWindow{{StartMinute: 9 * 60, EndMinute: 10 * 60}}})
	if e := checkSNSPostPolicy(now); e == nil || e.Status != 409 || e.Code != "sns_outside_window" {
		t.Fatalf("时段外应 409: %+v", e)
	}
}

func TestSNSPostIdempotencyStore(t *testing.T) {
	base := time.Date(2026, 11, 7, 12, 0, 0, 0, time.Local)
	store := newSNSPostIdempotency()
	if !store.claim("a", base) {
		t.Fatal("首次 client_id 应登记成功")
	}
	if store.claim("a", base.Add(9*time.Minute)) {
		t.Fatal("窗口内重复 client_id 应判重")
	}
	if store.claim("a", base.Add(snsPostIdempotencyWindow)) {
		t.Fatal("恰好 10 分钟边界仍应判重")
	}
	if !store.claim("a", base.Add(snsPostIdempotencyWindow+time.Nanosecond)) {
		t.Fatal("超过窗口的 client_id 应过期")
	}

	// 容量上限：满 512 后淘汰最旧键，新键仍可登记，最近键仍判重。
	store = newSNSPostIdempotency()
	for i := 0; i < snsPostIdempotencyLimit; i++ {
		ts := base.Add(time.Duration(i) * time.Second)
		if !store.claim(fmt.Sprintf("k%d", i), ts) {
			t.Fatalf("第 %d 个 client_id 应登记成功", i)
		}
	}
	overflowAt := base.Add(time.Duration(snsPostIdempotencyLimit) * time.Second)
	if !store.claim("overflow", overflowAt) {
		t.Fatal("容量满时应淘汰最旧键并接受新键")
	}
	if store.claim(fmt.Sprintf("k%d", snsPostIdempotencyLimit-1), overflowAt) {
		t.Fatal("最近的键应仍判重")
	}
	if !store.claim("k0", overflowAt) {
		t.Fatal("最旧键应被淘汰")
	}

	// client_id 为空时不启用幂等。
	svc := newSNSService()
	if !svc.claimSNSPostClientID("", base) || !svc.claimSNSPostClientID("", base) {
		t.Fatal("空 client_id 不应启用幂等")
	}
}

// ---- 捕获样本持久化/恢复 ------------------------------------------------

// hook 尚未就绪时的一次恢复失败不能永久丢失持久化样本：按固定间隔重试，
// 恢复成功后不再尝试；hook 给出确定失败（进程已变）也不重试。
func TestSNSCaptureRestoreRetriesAfterHookUnavailable(t *testing.T) {
	oldMediaDir := config.MediaDir
	oldCall := snsCallFrida
	oldNow := snsNow
	t.Cleanup(func() {
		config.MediaDir = oldMediaDir
		snsCallFrida = oldCall
		snsNow = oldNow
		resetSNSCaptureRestoreForTest()
	})
	resetSNSCaptureRestoreForTest()
	config.MediaDir = filepath.Join(t.TempDir(), "accounts", "wxid_self", "media")

	path := snsCaptureStatePath()
	if path == "" {
		t.Fatal("样本路径为空")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("建目录失败: %v", err)
	}
	raw := []byte(`{"ok":true,"pid":1,"records":{"mmsnspost":{"opHex":"0xd1"}}}`)
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatalf("写样本失败: %v", err)
	}

	now := time.Unix(1794000000, 0)
	snsNow = func() time.Time { return now }
	var imports int
	hookReady := false
	snsCallFrida = func(fn string, args ...any) (any, error) {
		if fn != "snsImportCapture" {
			return "", fmt.Errorf("unexpected frida call %s", fn)
		}
		imports++
		if !hookReady {
			return nil, errors.New("frida 未就绪")
		}
		if len(args) == 0 || fmt.Sprint(args[0]) != string(raw) {
			t.Fatalf("恢复时未传入样本内容")
		}
		return `{"ok":true,"restored":["mmsnspost"]}`, nil
	}

	// 第一次请求早于 hook 初始化：失败但不标记已恢复，也不在重试间隔内重复调用。
	snsRestoreCaptureState()
	if imports != 1 {
		t.Fatalf("首次应尝试一次 import，实际 %d", imports)
	}
	snsRestoreCaptureState()
	if imports != 1 {
		t.Fatalf("重试间隔内不应重复 import，实际 %d", imports)
	}
	// 超过重试间隔后 hook 就绪：恢复成功。
	hookReady = true
	now = now.Add(snsCaptureRestoreRetryDelay + time.Second)
	snsRestoreCaptureState()
	if imports != 2 {
		t.Fatalf("超过间隔应重试 import，实际 %d", imports)
	}
	// 恢复成功后不再尝试。
	now = now.Add(10 * snsCaptureRestoreRetryDelay)
	snsRestoreCaptureState()
	if imports != 2 {
		t.Fatalf("恢复成功后不应再次 import，实际 %d", imports)
	}

	// hook 返回确定失败（微信进程已变）时不再重试。
	resetSNSCaptureRestoreForTest()
	imports = 0
	hookReady = false
	snsCallFrida = func(fn string, args ...any) (any, error) {
		if fn != "snsImportCapture" {
			return "", fmt.Errorf("unexpected frida call %s", fn)
		}
		imports++
		return `{"ok":false,"error":"process_changed"}`, nil
	}
	now = now.Add(time.Minute)
	snsRestoreCaptureState()
	now = now.Add(10 * snsCaptureRestoreRetryDelay)
	snsRestoreCaptureState()
	if imports != 1 {
		t.Fatalf("确定失败（process_changed）不应重试，实际 %d", imports)
	}
}

// 样本持久化：同一内容不重复写盘（hook 每次导出带新的 exportedAt）、
// 默认导出被节流、force 绕过；内容变化时重新落盘。
func TestSNSCapturePersistDedupAndThrottle(t *testing.T) {
	oldMediaDir := config.MediaDir
	oldCall := snsCallFrida
	oldNow := snsNow
	t.Cleanup(func() {
		config.MediaDir = oldMediaDir
		snsCallFrida = oldCall
		snsNow = oldNow
		resetSNSCaptureRestoreForTest()
	})
	resetSNSCaptureRestoreForTest()
	config.MediaDir = filepath.Join(t.TempDir(), "accounts", "wxid_self", "media")

	now := time.Unix(1794000000, 0)
	snsNow = func() time.Time { return now }
	var exports int
	body := "deadbeef"
	snsCallFrida = func(fn string, args ...any) (any, error) {
		if fn != "snsExportCapture" {
			return "", fmt.Errorf("unexpected frida call %s", fn)
		}
		exports++
		return fmt.Sprintf(
			`{"ok":true,"pid":1,"moduleBase":"0x1","exportedAt":%d,`+
				`"records":{"mmsnspost":{"opHex":"0xd1"}},`+
				`"bodies":{"post":%q},"seeds":{}}`,
			now.UnixMilli(), body), nil
	}
	path := snsCaptureStatePath()
	if path == "" {
		t.Fatal("样本路径为空")
	}

	snsPersistCaptureState(false)
	if exports != 1 {
		t.Fatalf("首次应导出一次，实际 %d", exports)
	}
	if raw, err := os.ReadFile(path); err != nil || !strings.Contains(string(raw), body) {
		t.Fatalf("样本内容未落盘: %v", err)
	}

	// 节流窗口内不再导出。
	now = now.Add(snsCapturePersistMinInterval / 2)
	snsPersistCaptureState(false)
	if exports != 1 {
		t.Fatalf("节流窗口内不应导出，实际 %d", exports)
	}

	// 窗口外但内容未变（只有 exportedAt 变化）：导出一次但不重写文件。
	now = now.Add(2 * snsCapturePersistMinInterval)
	if err := os.Remove(path); err != nil {
		t.Fatalf("删除样本失败: %v", err)
	}
	snsPersistCaptureState(false)
	if exports != 2 {
		t.Fatalf("窗口外应再次导出，实际 %d", exports)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("样本内容未变时不应重写文件，stat err=%v", err)
	}

	// 内容变化：重新落盘。
	body = "cafebabe"
	now = now.Add(2 * snsCapturePersistMinInterval)
	snsPersistCaptureState(false)
	raw, err := os.ReadFile(path)
	if err != nil || !strings.Contains(string(raw), "cafebabe") {
		t.Fatalf("内容变化应重新落盘: %v", err)
	}

	// force 绕过最小间隔。
	now = now.Add(time.Second)
	body = "f00d"
	snsPersistCaptureState(true)
	if exports != 4 {
		t.Fatalf("force 应绕过导出节流，实际 %d", exports)
	}
	if raw, err := os.ReadFile(path); err != nil || !strings.Contains(string(raw), "f00d") {
		t.Fatalf("force 应写入最新样本: %v", err)
	}
}

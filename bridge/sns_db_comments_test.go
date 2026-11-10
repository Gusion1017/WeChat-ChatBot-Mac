package main

// sns.db 评论补全回归：signed feed_id 转换、SnsMessage_tmp3 行映射、
// timeline 合并去重/降级。全部用桩 RPC，不连微信。

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestSNSDbSignedFeedID(t *testing.T) {
	cases := []struct {
		in   string
		want string
		ok   bool
	}{
		{"42", "42", true},
		{"9223372036854775807", "9223372036854775807", true},
		{"9223372036854775808", "-9223372036854775808", true},
		{"15051131911065449117", "-3395612162644102499", true},
		{"18446744073709551615", "-1", true},
		{"", "", false},
		{"abc", "", false},
	}
	for _, tc := range cases {
		got, ok := snsDbSignedFeedID(tc.in)
		if ok != tc.ok || got != tc.want {
			t.Errorf("snsDbSignedFeedID(%q) = (%q,%v), want (%q,%v)", tc.in, got, ok, tc.want, tc.ok)
		}
	}
}

func TestSNSDbCommentFromRow(t *testing.T) {
	row := snsDbCommentRow{
		Content: "回复你的评论", FromUsername: "wxid_friend", FromNickname: "好友",
		ToUsername: "wxid_self", ToNickname: "机器人", CreateTime: 1794234885,
		CommentID: "35", Type: 2, IsRelativeMe: 1,
	}
	comment, ok := snsDbCommentFromRow(row)
	if !ok {
		t.Fatal("type=2/del=0 应映射为评论")
	}
	if comment.CommentID != "35" || comment.Text != "回复你的评论" ||
		comment.UserID != "wxid_friend" || comment.UserName != "好友" ||
		comment.CreateTime != 1794234885 || comment.ReplyTo != "" ||
		comment.ReplyToUserID != "wxid_self" || comment.ReplyToName != "机器人" {
		t.Fatalf("行映射错误: %+v", comment)
	}
	// 32 位列 comment_id 已经真机手动回复抓包确认可作 reply_comment_id
	// （ReplyCommentID=35 被服务端接受）：标记 confirmed + source=db。
	if !comment.CommentIDConfirmed || comment.CommentIDUnconfirmed || comment.Source != "db" {
		t.Fatalf("32 位 comment_id 应标记 confirmed/source=db: %+v", comment)
	}
	rawJSON, err := json.Marshal(comment)
	if err != nil {
		t.Fatalf("marshal comment: %v", err)
	}
	if !strings.Contains(string(rawJSON), `"comment_id_confirmed":true`) ||
		!strings.Contains(string(rawJSON), `"source":"db"`) {
		t.Fatalf("标记字段名错误: %s", rawJSON)
	}

	// comment64_id 优先于 comment_id，且是服务端语义，不做未确认标记。
	row.Comment64ID = "9002"
	comment, ok = snsDbCommentFromRow(row)
	if !ok || comment.CommentID != "9002" {
		t.Fatalf("comment64_id 应优先: %+v", comment)
	}
	if !comment.CommentIDConfirmed || comment.CommentIDUnconfirmed || comment.Source != "db" {
		t.Fatalf("有效 comment64_id 应标记 confirmed/source=db: %+v", comment)
	}

	// 删除/点赞行跳过。
	row.Comment64ID = ""
	row.DelStatus = 1
	if _, ok := snsDbCommentFromRow(row); ok {
		t.Fatal("del_status!=0 不应映射")
	}
	row.DelStatus = 0
	row.Type = 1
	if _, ok := snsDbCommentFromRow(row); ok {
		t.Fatal("type!=2 不应映射")
	}

	// 列字段缺失时用 serialized_comment_buf（SnsAction）补齐正文/用户/时间。
	action := SNSAction{
		FromUsername: "wxid_friend", FromNickname: "好友",
		ToUsername: "wxid_self", ToNickname: "机器人",
		Content: "buffer 里的回复", CreateTime: 1794234999,
	}
	buf, err := hex.DecodeString(hex.EncodeToString(MarshalSNSAction(action)))
	if err != nil {
		t.Fatalf("buffer: %v", err)
	}
	row = snsDbCommentRow{Type: 2, SerializedCommentBufHex: hex.EncodeToString(buf)}
	comment, ok = snsDbCommentFromRow(row)
	if !ok || comment.Text != "buffer 里的回复" || comment.UserID != "wxid_friend" ||
		comment.ReplyToUserID != "wxid_self" || comment.CreateTime != 1794234999 {
		t.Fatalf("buffer 兜底失败: %+v", comment)
	}

	// 无正文且无 buffer：丢弃，不猜测。
	if _, ok := snsDbCommentFromRow(snsDbCommentRow{Type: 2}); ok {
		t.Fatal("空正文不应映射")
	}
}

func TestSNSTimelineMergesDbComments(t *testing.T) {
	fake := setupSNSHTTP(t, true, false)
	// snsEnable=true 时 DB 评论补全默认启用（probe/dbRead 都为 false）。
	setSNSProbeForTest(false)
	setSNSDbReadForTest(false)
	oldImagePath := config.ImagePath
	config.ImagePath = "/tmp/xwechat_files/wxid_test/temp"
	t.Cleanup(func() {
		setSNSProbeForTest(false)
		setSNSDbReadForTest(false)
		config.ImagePath = oldImagePath
	})

	obj := snsTestObject(15051131911065449117, "post")
	// 原生 count=3、列表只带 1 条：补入 DB 回复后应仍 truncated=true。
	obj.CommentCount = 3
	obj.CommentUserList = []SNSCommentInfo{{
		Username: "wxid_native", Nickname: "原生", Type: 2, Content: "native",
		CreateTime: 1794000100, CommentID2: 501,
	}}
	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		if op != "timeline" {
			return SNSHookResponse{}, fmt.Errorf("unexpected op %s", op)
		}
		return SNSHookResponse{Body: snsTestTimelineResponse(obj)}, nil
	}

	oldCall := callFridaExport
	t.Cleanup(func() { callFridaExport = oldCall })
	var gotIDs []string
	dbCalls := 0
	callFridaExport = func(fn string, args ...any) (any, error) {
		if fn != "snsDbComments" {
			return nil, fmt.Errorf("unexpected frida call %s", fn)
		}
		dbCalls++
		if len(args) >= 2 {
			var ids []string
			if err := json.Unmarshal([]byte(fmt.Sprint(args[1])), &ids); err == nil {
				gotIDs = ids
			}
		}
		payload, _ := json.Marshal(map[string]any{
			"ok":    true,
			"count": 1,
			"rows": []map[string]any{{
				"feed_id":        "-3395612162644102499",
				"content":        "回复正文",
				"from_username":  "wxid_friend",
				"from_nickname":  "好友",
				"to_username":    "wxid_self",
				"to_nickname":    "机器人",
				"create_time":    1794234885,
				"comment_id":     "35",
				"comment64_id":   "0",
				"type":           2,
				"is_relative_me": 1,
				"del_status":     0,
			}},
		})
		return string(payload), nil
	}

	rec := snsPOST(t, snsTimelineHandler, "{\"limit\":20}", snsTestToken)
	data := snsDataField(t, rec)
	posts := data["posts"].([]any)
	if len(posts) != 1 {
		t.Fatalf("posts 数量错误: %v", posts)
	}
	p0 := posts[0].(map[string]any)
	comments := p0["comments"].([]any)
	if len(comments) != 2 {
		t.Fatalf("timeline 应补入 sns.db 评论，实际 %v", comments)
	}
	if comments[0].(map[string]any)["comment_id"] != "501" || comments[1].(map[string]any)["comment_id"] != "35" {
		t.Fatalf("评论顺序错误（原生在前）: %v", comments)
	}
	reply := comments[1].(map[string]any)
	if reply["text"] != "回复正文" || reply["reply_to_user_id"] != "wxid_self" ||
		reply["reply_to"] != "" || reply["reply_to_name"] != "机器人" {
		t.Fatalf("DB 回复字段错误: %v", reply)
	}
	if reply["comment_id_confirmed"] != true || reply["comment_id_unconfirmed"] == true ||
		reply["source"] != "db" {
		t.Fatalf("DB 32 位 comment_id 应带 confirmed/source=db 标记: %v", reply)
	}
	if snsJSONNumber(p0["comment_count"]) != 3 || p0["comments_truncated"] != true {
		t.Fatalf("count/truncated 错误: count=%v truncated=%v", p0["comment_count"], p0["comments_truncated"])
	}
	if len(gotIDs) != 1 || gotIDs[0] != "-3395612162644102499" {
		t.Fatalf("batch feed_id 错误: %v", gotIDs)
	}

	// 再次刷新按 comment_id 去重，不重复追加。
	rec = snsPOST(t, snsTimelineHandler, "{\"limit\":20}", snsTestToken)
	data = snsDataField(t, rec)
	comments = data["posts"].([]any)[0].(map[string]any)["comments"].([]any)
	if len(comments) != 2 || dbCalls != 2 {
		t.Fatalf("重复刷新应去重: comments=%d calls=%d", len(comments), dbCalls)
	}
}

func TestSNSTimelineDegradesWhenDbCommentsUnavailable(t *testing.T) {
	fake := setupSNSHTTP(t, true, false)
	setSNSProbeForTest(false)
	setSNSDbReadForTest(false)
	oldImagePath := config.ImagePath
	config.ImagePath = "/tmp/xwechat_files/wxid_test/temp"
	t.Cleanup(func() {
		setSNSProbeForTest(false)
		setSNSDbReadForTest(false)
		config.ImagePath = oldImagePath
	})

	obj := snsTestObject(42, "post")
	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		return SNSHookResponse{Body: snsTestTimelineResponse(obj)}, nil
	}
	oldCall := callFridaExport
	t.Cleanup(func() { callFridaExport = oldCall })
	callFridaExport = func(fn string, args ...any) (any, error) {
		if fn == "snsDbComments" {
			return nil, fmt.Errorf("key_missing")
		}
		return nil, fmt.Errorf("unexpected frida call %s", fn)
	}

	rec := snsPOST(t, snsTimelineHandler, "{\"limit\":20}", snsTestToken)
	data := snsDataField(t, rec)
	if len(data["posts"].([]any)) != 1 {
		t.Fatalf("DB 失败不应影响 timeline: %v", data)
	}
	if rec.Code != 200 {
		t.Fatalf("DB 失败应静默降级，实际 %d", rec.Code)
	}
}

func TestMergeSNSDbCommentsNoopWhenSnsReadDisabled(t *testing.T) {
	setupSNSHTTP(t, false, false)
	setSNSProbeForTest(false)
	setSNSDbReadForTest(false)
	t.Cleanup(func() {
		setSNSProbeForTest(false)
		setSNSDbReadForTest(false)
	})
	oldCall := callFridaExport
	t.Cleanup(func() { callFridaExport = oldCall })
	called := false
	callFridaExport = func(fn string, args ...any) (any, error) {
		called = true
		return nil, fmt.Errorf("unexpected frida call %s", fn)
	}
	posts := []snsPostJSON{{ID: "43"}}
	got := mergeSNSDbComments(posts)
	if called {
		t.Fatal("SNS 读关闭时不应调用 snsDbComments")
	}
	if len(got) != 1 || got[0].ID != "43" {
		t.Fatalf("关闭时应原样返回: %+v", got)
	}
}

// comment_id=35 的语义未确认：同一帖子下多条回复共用它时不能互相覆盖；
// 这里用组合键，只去掉完全重复的行。
func TestSNSMergeDbCommentListsKeepsSameLocalID(t *testing.T) {
	native := []snsCommentJSON{{CommentID: "501", UserID: "wxid_native", Text: "native", CreateTime: 10}}
	dbComments := []snsCommentJSON{
		{CommentID: "35", UserID: "wxid_friend", Text: "第一条回复", CreateTime: 20},
		{CommentID: "35", UserID: "wxid_friend", Text: "第二条回复", CreateTime: 21},
		{CommentID: "35", UserID: "wxid_friend", Text: "第一条回复", CreateTime: 20},
	}
	merged := snsMergeDbCommentLists(native, dbComments)
	if len(merged) != 3 {
		t.Fatalf("同 comment_id 的不同回复应保留、完全重复行去重，实际 %+v", merged)
	}
	if merged[0].Text != "native" || merged[1].Text != "第一条回复" || merged[2].Text != "第二条回复" {
		t.Fatalf("顺序错误: %+v", merged)
	}
}

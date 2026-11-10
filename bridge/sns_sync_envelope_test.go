package main

// 朋友圈同步 CmdBuf 外层信封 + 回复评论合并回归（docs/sns.md §4.2/§4.5）。
//
// 真机 2026-11-09 定位：mmsnssync 的 CmdBuf 是外层信封
//   {1: varint payload_len, 2: bytes payload}
// payload 才是 SnsObject（cmd 45）/ SnsActionGroup（cmd 46）。旧实现把整个信封
// 当 SnsObject/SnsActionGroup 解析，cmd45/46 全部 unsupported，导致
// 「好友回复机器人评论」既不出现在 timeline 也进不了缓存。

import (
	"bytes"
	"context"
	"strconv"
	"testing"
	"time"
)

// snsTestCmdEnvelope 按真机结构构造 CmdBuf 信封：field1=payload 长度，field2=payload。
func snsTestCmdEnvelope(payload []byte) []byte {
	out := snsAppendVarintField(nil, 1, uint64(len(payload)))
	return snsAppendBytesField(out, 2, payload)
}

func TestSNSUnwrapSyncCmdBuf(t *testing.T) {
	obj := snsTestObject(15040000000000000031, "post")
	payload := MarshalSNSObject(obj)
	envelope := snsTestCmdEnvelope(payload)
	if got := snsUnwrapSyncCmdBuf(envelope); !bytes.Equal(got, payload) {
		t.Fatalf("信封应解包为 payload，got len=%d want len=%d", len(got), len(payload))
	}
	// 直接载荷（没有信封）原样返回。
	if got := snsUnwrapSyncCmdBuf(payload); !bytes.Equal(got, payload) {
		t.Fatalf("非信封载荷不应被改写，got len=%d", len(got))
	}
	// 长度字段与 field2 不一致：不猜，原样返回。
	badLen := snsAppendVarintField(nil, 1, uint64(len(payload)+7))
	badLen = snsAppendBytesField(badLen, 2, payload)
	if got := snsUnwrapSyncCmdBuf(badLen); !bytes.Equal(got, badLen) {
		t.Fatal("长度不匹配时不应解包")
	}
	// 多余字段：不满足「恰好两个字段」，原样返回。
	extra := append(append([]byte(nil), envelope...), snsAppendVarintField(nil, 3, 1)...)
	if got := snsUnwrapSyncCmdBuf(extra); !bytes.Equal(got, extra) {
		t.Fatal("带额外字段时不应解包")
	}
	if got := snsUnwrapSyncCmdBuf(nil); len(got) != 0 {
		t.Fatalf("空输入应原样返回，got len=%d", len(got))
	}
}

func TestSNSDecodeSyncCmdEnvelope(t *testing.T) {
	setupSNSHTTP(t, true, false)
	obj := snsTestObject(15040000000000000032, "post")
	obj.CommentCount = 1
	obj.CommentUserList = []SNSCommentInfo{{
		Username: "wxid_self", Nickname: "我", Type: 2, Content: "我的评论",
		CreateTime: 1794000100, CommentID2: 901,
	}}

	// cmd 45：SnsObject 外层信封 → sns_new_post，并进入只读缓存。
	events, ok := snsDecodeSyncCommand(45, snsTestCmdEnvelope(MarshalSNSObject(obj)))
	if !ok || len(events) != 1 || events[0]["type"] != "sns_new_post" {
		t.Fatalf("cmd45 应解出新动态: ok=%v events=%v", ok, events)
	}

	// cmd 46：SnsActionGroup 外层信封 → sns_comment；ToUsername 是被回复者。
	action := &SNSAction{
		FromUsername: "wxid_friend", ToUsername: "wxid_self",
		FromNickname: "好友", ToNickname: "我", Type: 2,
		CreateTime: 1794000200, Content: "回复我的评论",
		CommentID2: 902, ReplyCommentID2: 901,
	}
	group := SNSActionGroup{ID: obj.ID, CurrentAction: action}
	events, ok = snsDecodeSyncCommand(46, snsTestCmdEnvelope(MarshalSNSActionGroup(group)))
	if !ok || len(events) != 1 || events[0]["type"] != "sns_comment" {
		t.Fatalf("cmd46 应解出评论事件: ok=%v events=%v", ok, events)
	}
	data := events[0]["data"].(map[string]any)
	if data["post_id"] != strconv.FormatUint(obj.ID, 10) {
		t.Fatalf("post_id 错误: %v", data["post_id"])
	}
	comment, ok := data["comment"].(snsCommentJSON)
	if !ok {
		t.Fatalf("comment 类型错误: %T", data["comment"])
	}
	if comment.CommentID != "902" || comment.ReplyTo != "901" {
		t.Fatalf("评论 ID/回复目标错误: %+v", comment)
	}
	if comment.ReplyToUserID != "wxid_self" {
		t.Fatalf("reply_to_user_id 应为被回复者 wxid_self，实际 %q", comment.ReplyToUserID)
	}

	// 评论已并入缓存动态（timeline 刷新时可见）。
	cached, ok := snsSvc.lookupPost(obj.ID)
	if !ok || len(cached.Comments) != 2 {
		t.Fatalf("缓存评论合并错误: ok=%v comments=%+v", ok, cached.Comments)
	}
	// 同一条命令重复投递（游标回滚）不重复追加。
	if _, ok := snsDecodeSyncCommand(46, snsTestCmdEnvelope(MarshalSNSActionGroup(group))); !ok {
		t.Fatal("重复 cmd46 应仍可解码")
	}
	cached, _ = snsSvc.lookupPost(obj.ID)
	if len(cached.Comments) != 2 {
		t.Fatalf("重复同步不应重复追加评论: %+v", cached.Comments)
	}
}

func TestSNSTimelineMergesSyncComments(t *testing.T) {
	fake := setupSNSHTTP(t, true, false)
	obj := snsTestObject(15040000000000000033, "post")
	obj.CommentCount = 3
	obj.CommentUserList = []SNSCommentInfo{{
		Username: "wxid_native", Nickname: "原生", Type: 2, Content: "native",
		CreateTime: 1794000100, CommentID2: 501,
	}}
	postID := strconv.FormatUint(obj.ID, 10)
	// 模拟 /sns/sync 已并入一条「好友回复我的评论」（不在 timeline 回包里）。
	snsSvc.rememberComments(postID, []snsCommentJSON{{
		CommentID: "502", UserID: "wxid_friend", UserName: "好友", Text: "回复",
		CreateTime: 1794000200, ReplyTo: "500", ReplyToUserID: "wxid_self",
	}})

	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		if op != "timeline" {
			return SNSHookResponse{}, newSNSError(500, "sns_test_unexpected_op", "unexpected op "+op)
		}
		return SNSHookResponse{Body: snsTestTimelineResponse(obj)}, nil
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
		t.Fatalf("timeline 应合并 sync 评论，实际 %v", comments)
	}
	first := comments[0].(map[string]any)
	second := comments[1].(map[string]any)
	if first["comment_id"] != "501" || second["comment_id"] != "502" {
		t.Fatalf("评论顺序错误（原生在前、缓存补缺）: %v", comments)
	}
	if second["reply_to"] != "500" || second["reply_to_user_id"] != "wxid_self" {
		t.Fatalf("回复字段错误: %v", second)
	}
	if snsJSONNumber(p0["comment_count"]) != 3 || p0["comments_truncated"] != true {
		t.Fatalf("count/truncated 错误: count=%v truncated=%v", p0["comment_count"], p0["comments_truncated"])
	}

	// 再次刷新不应重复追加缓存评论。
	rec = snsPOST(t, snsTimelineHandler, "{\"limit\":20}", snsTestToken)
	data = snsDataField(t, rec)
	comments = data["posts"].([]any)[0].(map[string]any)["comments"].([]any)
	if len(comments) != 2 {
		t.Fatalf("重复刷新不应重复追加评论: %v", comments)
	}
}

func TestSNSSyncHandlerDecodesEnvelopeCommands(t *testing.T) {
	fake := setupSNSHTTP(t, true, false)
	obj := snsTestObject(15040000000000000034, "post")
	action := &SNSAction{
		FromUsername: "wxid_friend", ToUsername: "wxid_self", Type: 2,
		CreateTime: 1794000200, Content: "回复", CommentID2: 902, ReplyCommentID2: 901,
	}
	fake.requestFn = func(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
		if op != "sync" {
			return SNSHookResponse{}, newSNSError(500, "sns_test_unexpected_op", "unexpected op "+op)
		}
		return SNSHookResponse{Body: MarshalSNSSyncResponse(SNSSyncResponse{
			Base: SNSBaseResponse{},
			CmdList: SNSCmdList{Items: []SNSCmdItem{
				{CmdID: 45, CmdBuf: snsTestCmdEnvelope(MarshalSNSObject(obj))},
				{CmdID: 46, CmdBuf: snsTestCmdEnvelope(MarshalSNSActionGroup(SNSActionGroup{ID: obj.ID, CurrentAction: action}))},
				{CmdID: 46, CmdBuf: snsTestCmdEnvelope(MarshalSNSActionGroup(SNSActionGroup{ID: obj.ID, CurrentAction: &SNSAction{
					FromUsername: "wxid_friend", ToUsername: "wxid_self", Type: 11,
					CreateTime: 1794234885, IsNotRichText: 1,
				}}))},
			}},
			ContinueFlag: 1,
			KeyBuf:       []byte{2, 3},
		})}, nil
	}
	rec := snsPOST(t, snsSyncHandler, "{}", snsTestToken)
	data := snsDataField(t, rec)
	if n := snsJSONNumber(data["unsupported_cmd_count"]); n != 0 {
		t.Fatalf("信封解包后不应有 unsupported，实际 %d", n)
	}
	events := data["events"].([]any)
	if len(events) != 3 {
		t.Fatalf("应解出 3 个事件，实际 %v", events)
	}
	if events[0].(map[string]any)["type"] != "sns_new_post" ||
		events[1].(map[string]any)["type"] != "sns_comment" ||
		events[2].(map[string]any)["type"] != "sns_comment_hint" {
		t.Fatalf("事件类型错误: %v", events)
	}
	cached, ok := snsSvc.lookupPost(obj.ID)
	if !ok || len(cached.Comments) != 1 || cached.Comments[0].ReplyToUserID != "wxid_self" {
		t.Fatalf("sync 评论未进入缓存: ok=%v comments=%+v", ok, cached.Comments)
	}
}

// 真机 2026-11-09：好友回复机器人评论时 cmd46 的 CurrentAction.Type=11，
// 没有正文/CommentID；只发 sns_comment_hint，不能当自动回复候选。
func TestSNSDecodeSyncCmdType11Hint(t *testing.T) {
	setupSNSHTTP(t, true, false)
	obj := snsTestObject(15040000000000000036, "post")
	action := &SNSAction{
		FromUsername: "wxid_friend", ToUsername: "wxid_self",
		FromNickname: "好友", ToNickname: "机器人", Type: 11,
		CreateTime: 1794234885, IsNotRichText: 1,
	}
	events, ok := snsDecodeSyncCommand(46, snsTestCmdEnvelope(MarshalSNSActionGroup(SNSActionGroup{ID: obj.ID, CurrentAction: action})))
	if !ok || len(events) != 1 || events[0]["type"] != "sns_comment_hint" {
		t.Fatalf("Type=11 应产出 sns_comment_hint: ok=%v events=%v", ok, events)
	}
	data := events[0]["data"].(map[string]any)
	if data["post_id"] != strconv.FormatUint(obj.ID, 10) || data["from_user"] != "wxid_friend" {
		t.Fatalf("hint 字段错误: %v", data)
	}
	if snsJSONNumber(data["create_time"]) != 1794234885 || data["reply_to_user_id"] != "wxid_self" {
		t.Fatalf("hint 时间/被回复者错误: %v", data)
	}
	if _, exists := data["text"]; exists {
		t.Fatal("hint 不应伪造正文 text 字段")
	}
	if _, exists := data["comment"]; exists {
		t.Fatal("hint 不应伪装成可自动回复的 comment")
	}
	// 不写入评论缓存（没有正文/comment_id，不能当候选）。
	if _, ok := snsSvc.lookupPost(obj.ID); ok {
		t.Fatal("Type=11 hint 不应创建缓存动态/评论")
	}
}

func TestSNSCommentReplyToUserIDFromTimeline(t *testing.T) {
	obj := snsTestObject(15040000000000000035, "post")
	obj.CommentUserList = []SNSCommentInfo{
		{Username: "wxid_b", Nickname: "乙", Type: 2, Content: "re",
			ReplyCommentID2: 11, ReplyUsername: "wxid_a", CommentID2: 12},
	}
	post := snsNormalizePost(&obj, false)
	if len(post.Comments) != 1 || post.Comments[0].ReplyToUserID != "wxid_a" {
		t.Fatalf("timeline reply_to_user_id 应取 ReplyUsername: %+v", post.Comments)
	}
}

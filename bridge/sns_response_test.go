package main

// 用 mac 微信 4.2.0.12 真机 SnsTimeLineResponse 的脱敏子集（3 条动态）校准解析器。
// 真机实测与公开 schema 的差异：
//   - SnsObject.ObjectDesc(field 5) 也是 SKBuiltinBuffer_t 包裹；
//   - SnsObject 有大量新增未知字段（f16..f56），解析必须跳过；
//   - SnsCommentInfo 出现 field 15/21 富内容（语义待实测），这里只要求不丢包；
//   - 响应 field 11 Session 是 SKBuiltinBuffer_t 包裹。
// fixture 中 wxid/昵称/正文/媒体 key/snsId/评论 id/session 均已等长脱敏。

import (
	"bytes"
	"strings"
	"testing"
)

func TestSNSRealTimelineResponseFixture(t *testing.T) {
	raw := snsMustHex(t, snsFixtureTimelineResponseHex)
	resp, err := UnmarshalSNSTimeLineResponse(raw)
	if err != nil {
		t.Fatalf("真机响应 fixture 解码失败: %v", err)
	}
	if resp.Base.Ret != 0 || resp.Base.ErrMsg != "" {
		t.Fatalf("BaseResponse 异常: %+v", resp.Base)
	}
	if resp.FirstPageMD5 != strings.Repeat("0", 16) {
		t.Fatalf("first_page_md5 未按 16B 处理: %q", resp.FirstPageMD5)
	}
	if resp.ObjectCount != 3 || len(resp.Objects) != 3 {
		t.Fatalf("ObjectCount/ObjectList 不一致: %d/%d", resp.ObjectCount, len(resp.Objects))
	}
	if resp.NewRequestTime != 1700000000 || resp.ObjectCountForSameMD5 != 3 || resp.ControlFlag != 2 {
		t.Fatalf("响应控制字段不一致: new=%d same_md5=%d control=%d",
			resp.NewRequestTime, resp.ObjectCountForSameMD5, resp.ControlFlag)
	}
	if resp.ServerConfig.PostMentionLimit != 10 || resp.ServerConfig.CopyAndPasteWordLimit != 0 {
		t.Fatalf("ServerConfig 不一致: %+v", resp.ServerConfig)
	}
	if len(resp.Session) != 688 {
		t.Fatalf("Session 长度应为 688，实际 %d", len(resp.Session))
	}
	for i, b := range resp.Session {
		if b != 0xA5 {
			t.Fatalf("Session 第 %d 字节未脱敏: %#x", i, b)
		}
	}

	// 动态 0：纯文字，ObjectDesc 是包裹的 XML。
	obj0 := resp.Objects[0]
	if obj0.ID != 17000000000000001234 {
		t.Fatalf("obj0 id 错误: %d", obj0.ID)
	}
	if obj0.Username != "wxid_"+strings.Repeat("x", 14) || obj0.Nickname != strings.Repeat("x", 14) {
		t.Fatalf("obj0 作者未脱敏: %q/%q", obj0.Username, obj0.Nickname)
	}
	if obj0.CreateTime != 1700000000 {
		t.Fatalf("obj0 createTime 错误: %d", obj0.CreateTime)
	}
	xml0, err := ParseSNSTimelineObject(obj0.ObjectDesc)
	if err != nil {
		t.Fatalf("obj0 ObjectDesc 解析失败: %v", err)
	}
	if xml0.ContentDesc != strings.Repeat("x", 15) || xml0.ContentObject == nil ||
		xml0.ContentObject.ContentStyle != "2" {
		t.Fatalf("obj0 正文/样式错误: style=%v desc=%q", xml0.ContentObject, xml0.ContentDesc)
	}
	post0 := snsNormalizePost(&obj0, false)
	if len(post0.Media) != 0 || post0.Text != strings.Repeat("x", 15) {
		t.Fatalf("obj0 归一化错误: %+v", post0)
	}

	// 动态 1：单图；尺寸来自 XML size 属性（1440x2067）。
	obj1 := resp.Objects[1]
	xml1, err := ParseSNSTimelineObject(obj1.ObjectDesc)
	if err != nil {
		t.Fatalf("obj1 ObjectDesc 解析失败: %v", err)
	}
	if xml1.ContentObject == nil || xml1.ContentObject.MediaList == nil ||
		len(xml1.ContentObject.MediaList.Media) != 1 {
		t.Fatalf("obj1 媒体数量错误: %+v", xml1.ContentObject)
	}
	post1 := snsNormalizePost(&obj1, false)
	if len(post1.Media) != 1 || post1.Media[0].Kind != "image" ||
		post1.Media[0].Width != 1440 || post1.Media[0].Height != 2067 {
		t.Fatalf("obj1 媒体归一化错误: %+v", post1.Media)
	}
	if len(post1.Media[0].ThumbKey) != 111 || strings.Trim(post1.Media[0].ThumbKey, "x") != "" {
		t.Fatalf("obj1 thumb key 未脱敏: len=%d", len(post1.Media[0].ThumbKey))
	}

	// 动态 2：单图 + 1 条评论 + 1 个赞；评论的富内容 field 15 原样保留。
	obj2 := resp.Objects[2]
	if obj2.CommentCount != 1 || len(obj2.CommentUserList) != 1 {
		t.Fatalf("obj2 评论数不一致: count=%d list=%d", obj2.CommentCount, len(obj2.CommentUserList))
	}
	comment := obj2.CommentUserList[0]
	if comment.Type != 2 || comment.Username != "wxid_"+strings.Repeat("x", 14) ||
		comment.Nickname != "userxx" || comment.CommentID != 1 || comment.CreateTime != 1700000000 {
		t.Fatalf("obj2 评论字段错误: %+v", comment)
	}
	if len(comment.RichContent) != 1524 || strings.Trim(string(comment.RichContent), "Q") != "" {
		t.Fatalf("obj2 评论富内容未脱敏/未保留: len=%d", len(comment.RichContent))
	}
	if obj2.LikeCount != 0 || len(obj2.LikeUserList) != 0 {
		t.Fatalf("obj2 本无点赞，实际 count=%d list=%+v", obj2.LikeCount, obj2.LikeUserList)
	}
	post2 := snsNormalizePost(&obj2, true)
	if len(post2.Comments) != 1 || post2.Comments[0].CommentID != "1" ||
		post2.Comments[0].Text != "" || len(post2.Likes) != 0 {
		t.Fatalf("obj2 归一化错误: comments=%+v likes=%+v", post2.Comments, post2.Likes)
	}

	// 时间线游标/更多页语义：ControlFlag=2 视为有更多。
	if resp.ControlFlag == 0 {
		t.Fatal("ControlFlag=2 时应视为有更多页")
	}

	// 重新编码后仍可解析（对象 XML 包裹规则保持）。
	reencoded := MarshalSNSTimeLineResponse(*resp)
	round, err := UnmarshalSNSTimeLineResponse(reencoded)
	if err != nil || len(round.Objects) != 3 || round.Objects[2].CommentCount != 1 {
		t.Fatalf("真机响应重编码不一致: %v", err)
	}
	if !bytes.Equal(snsUnwrapBuffer(mustFieldBytes(t, reencoded, 11)), resp.Session) {
		t.Fatal("Session 重编码未保持 SKBuiltinBuffer_t")
	}
}

func mustFieldBytes(t *testing.T, data []byte, num int) []byte {
	t.Helper()
	var out []byte
	if err := snsWalk(data, func(f snsWireField) error {
		if int(f.num) == num && f.typ == 2 {
			out = f.bytes
		}
		return nil
	}); err != nil {
		t.Fatalf("遍历字段失败: %v", err)
	}
	return out
}

package main

// SNS protobuf 编解码单元测试。
// 请求 fixture 来自 mac 微信 4.2.0.12 真机抓包的脱敏副本（见 sns_fixtures_test.go）；
// 响应样本用本文件的 encoder 合成，覆盖评论/点赞/媒体与未知字段容忍。

import (
	"bytes"
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"google.golang.org/protobuf/encoding/protowire"
)

func snsMustHex(t *testing.T, s string) []byte {
	t.Helper()
	data, err := hex.DecodeString(s)
	if err != nil {
		t.Fatalf("fixture 不是合法 hex: %v", err)
	}
	return data
}

func snsTopLevelFieldNums(t *testing.T, data []byte) []int {
	t.Helper()
	var nums []int
	if err := snsWalk(data, func(f snsWireField) error {
		nums = append(nums, int(f.num))
		return nil
	}); err != nil {
		t.Fatalf("遍历 protobuf 字段失败: %v", err)
	}
	return nums
}

func snsContainsField(nums []int, want int) bool {
	for _, n := range nums {
		if n == want {
			return true
		}
	}
	return false
}

func TestSNSFixtureTimelineRequest(t *testing.T) {
	raw := snsMustHex(t, snsFixtureTimelineRequestHex)
	req, err := UnmarshalSNSTimeLineRequest(raw)
	if err != nil {
		t.Fatalf("timeline 请求解码失败: %v", err)
	}
	if req.MaxID != 0 || req.MinFilterID != 0 || req.LastRequestTime != 0 || req.ClientLatestID != 0 {
		t.Fatalf("首屏游标字段应为 0，实际 %+v", req)
	}
	if req.FirstPageMD5 != "" && req.FirstPageMD5 != strings.Repeat("0", len(req.FirstPageMD5)) {
		t.Fatalf("first_page_md5 未脱敏: %q", req.FirstPageMD5)
	}
	if len(req.Session) == 0 {
		t.Fatal("session 不应为空")
	}
	for i, b := range req.Session {
		if b != 0xA5 {
			t.Fatalf("session 第 %d 字节未脱敏: %#x", i, b)
		}
	}
	nums := snsTopLevelFieldNums(t, raw)
	if snsContainsField(nums, 1) {
		t.Fatal("mac 4.2 SNS body 不应包含 BaseRequest(field 1)")
	}
	for _, want := range []int{2, 3, 4, 5, 6, 7, 8} {
		if !snsContainsField(nums, want) {
			t.Fatalf("缺少字段 %d（fields=%v）", want, nums)
		}
	}
	// field 7 必须是 SKBuiltinBuffer_t 包裹。
	var f7 []byte
	_ = snsWalk(raw, func(f snsWireField) error {
		if f.num == 7 && f.typ == 2 {
			f7 = f.bytes
		}
		return nil
	})
	if len(f7) == 0 {
		t.Fatal("缺少 timeline session 包裹字段")
	}
	buf, ok := ParseSKBuiltinBuffer(f7)
	if !ok || int(buf.Len) != len(buf.Data) {
		t.Fatalf("field 7 不是合法 SKBuiltinBuffer_t")
	}
}

func TestSNSBuildTimelineRequest(t *testing.T) {
	session := []byte{1, 2, 3, 4, 5}
	body := MarshalSNSTimeLineRequest(SNSTimeLineRequest{
		FirstPageMD5: "0123456789abcdef",
		MaxID:        18446744073709551615,
		Session:      session,
	})
	req, err := UnmarshalSNSTimeLineRequest(body)
	if err != nil {
		t.Fatalf("编码后解码失败: %v", err)
	}
	if req.FirstPageMD5 != "0123456789abcdef" || req.MaxID != 18446744073709551615 {
		t.Fatalf("字段回读不一致: %+v", req)
	}
	if !bytes.Equal(req.Session, session) {
		t.Fatalf("session 回读不一致: %x", req.Session)
	}
	nums := snsTopLevelFieldNums(t, body)
	if snsContainsField(nums, 1) {
		t.Fatal("bridge 构造的请求不应含 BaseRequest")
	}
	var f7 []byte
	_ = snsWalk(body, func(f snsWireField) error {
		if f.num == 7 && f.typ == 2 {
			f7 = f.bytes
		}
		return nil
	})
	buf, ok := ParseSKBuiltinBuffer(f7)
	if !ok || !bytes.Equal(buf.Data, session) {
		t.Fatalf("session 未按 SKBuiltinBuffer_t 包裹: ok=%v data=%x", ok, buf.Data)
	}
	// mac 4.2 同构字段：NetworkType=1。
	if buf8 := snsFieldVarint(t, body, 8); buf8 != 1 {
		t.Fatalf("NetworkType(field 8) 应为 1，实际 %d", buf8)
	}
}

func snsFieldVarint(t *testing.T, data []byte, num int) uint64 {
	t.Helper()
	var v uint64
	var seen bool
	_ = snsWalk(data, func(f snsWireField) error {
		if int(f.num) == num && f.typ == 0 {
			v = f.varint
			seen = true
		}
		return nil
	})
	if !seen {
		t.Fatalf("缺少 varint 字段 %d", num)
	}
	return v
}

func TestSNSFixturePostRequest(t *testing.T) {
	raw := snsMustHex(t, snsFixturePostRequestHex)
	req, err := UnmarshalSNSPostRequest(raw)
	if err != nil {
		t.Fatalf("post 请求解码失败: %v", err)
	}
	if len(req.ObjectDesc) == 0 {
		t.Fatal("ObjectDesc 为空")
	}
	xmlObj, err := ParseSNSTimelineObject(req.ObjectDesc)
	if err != nil {
		t.Fatalf("TimelineObject 解析失败: %v", err)
	}
	if xmlObj.Username != "wxid_"+strings.Repeat("x", 14) {
		t.Fatalf("username 未脱敏: %q", xmlObj.Username)
	}
	if xmlObj.ContentDesc != strings.Repeat("x", 15) {
		t.Fatalf("contentDesc 未脱敏: %q", xmlObj.ContentDesc)
	}
	if xmlObj.ContentObject == nil || xmlObj.ContentObject.ContentStyle != "2" {
		t.Fatalf("contentStyle 应为 2（纯文字）")
	}
	if req.Privacy != 0 || req.SyncFlag != 0 {
		t.Fatalf("privacy/syncFlag 应为 0: %d/%d", req.Privacy, req.SyncFlag)
	}
	if req.ClientID != strings.Repeat("a", 32) {
		t.Fatalf("clientId 未脱敏: %q", req.ClientID)
	}
	if len(req.ClientCheckDat) != 3368 {
		t.Fatalf("ClientCheckDat 长度应为 3368，实际 %d", len(req.ClientCheckDat))
	}
	if !bytes.Equal(req.ClientCheckDat, bytes.Repeat([]byte{'Z'}, 3368)) {
		t.Fatal("ClientCheckDat 未脱敏")
	}
	if req.ClientCheckDatLegacy27 != nil {
		t.Fatal("mac 4.2 不应命中旧 field 27")
	}
	nums := snsTopLevelFieldNums(t, raw)
	if snsContainsField(nums, 1) {
		t.Fatal("post 请求不应含 BaseRequest")
	}
	if !snsContainsField(nums, 28) {
		t.Fatalf("mac ClientCheckDat 应在 field 28（fields=%v）", nums)
	}
	if snsContainsField(nums, 27) {
		t.Fatal("不应出现 field 27")
	}
	// field 2 是 SKBuiltinBuffer_t 包裹的 XML。
	var f2 []byte
	_ = snsWalk(raw, func(f snsWireField) error {
		if f.num == 2 && f.typ == 2 {
			f2 = f.bytes
		}
		return nil
	})
	buf, ok := ParseSKBuiltinBuffer(f2)
	if !ok || int(buf.Len) != len(buf.Data) || !bytes.Equal(buf.Data, req.ObjectDesc) {
		t.Fatal("ObjectDesc 未按 SKBuiltinBuffer_t 包裹")
	}

	// 重新编码保持 mac 字段号。
	reencoded := MarshalSNSPostRequest(*req)
	round, err := UnmarshalSNSPostRequest(reencoded)
	if err != nil {
		t.Fatalf("重编码后解码失败: %v", err)
	}
	if round.Privacy != req.Privacy || round.ClientID != req.ClientID ||
		!bytes.Equal(round.ClientCheckDat, req.ClientCheckDat) ||
		!bytes.Equal(round.ObjectDesc, req.ObjectDesc) {
		t.Fatal("SnsPostRequest 重编码字段不一致")
	}
	if !snsContainsField(snsTopLevelFieldNums(t, reencoded), 28) {
		t.Fatal("重编码后 ClientCheckDat 应仍在 field 28")
	}
}

func TestSNSFixtureCommentRequest(t *testing.T) {
	raw := snsMustHex(t, snsFixtureCommentRequestHex)
	req, err := UnmarshalSNSCommentRequest(raw)
	if err != nil {
		t.Fatalf("comment 请求解码失败: %v", err)
	}
	if req.Action.ID != 17000000000000001234 {
		t.Fatalf("snsId 不一致: %d", req.Action.ID)
	}
	if req.Action.CurrentAction == nil {
		t.Fatal("缺少 CurrentAction")
	}
	a := req.Action.CurrentAction
	if a.Type != 2 || a.Content != "cccc" || a.CreateTime != 1794062721 {
		t.Fatalf("action 字段不一致: %+v", a)
	}
	if a.FromUsername != "wxid_"+strings.Repeat("x", 14) || a.ToUsername != a.FromUsername {
		t.Fatalf("username 未脱敏: %q/%q", a.FromUsername, a.ToUsername)
	}
	if a.FromNickname != "user"+strings.Repeat("x", 10) {
		t.Fatalf("nickname 未脱敏: %q", a.FromNickname)
	}
	wantClientID := "sns_comment:17777777777777777777_1794062721_2"
	if req.ClientID != wantClientID {
		t.Fatalf("clientId 不一致: %q", req.ClientID)
	}
	if req.Action.ClientID != "" {
		t.Fatalf("实测 action group 无 clientId，实际 %q", req.Action.ClientID)
	}
	if snsContainsField(snsTopLevelFieldNums(t, raw), 1) {
		t.Fatal("comment 请求不应含 BaseRequest")
	}
	// SnsActionGroup 未包裹（field 2 是 message，不是 SKBuiltinBuffer_t）。
	var f2 []byte
	_ = snsWalk(raw, func(f snsWireField) error {
		if f.num == 2 && f.typ == 2 {
			f2 = f.bytes
		}
		return nil
	})
	if _, isBuf := ParseSKBuiltinBuffer(f2); isBuf {
		t.Fatal("SnsActionGroup 不应被 SKBuiltinBuffer_t 包裹")
	}
	// 重编码后回读一致。
	round, err := UnmarshalSNSCommentRequest(MarshalSNSCommentRequest(*req))
	if err != nil {
		t.Fatalf("重编码后解码失败: %v", err)
	}
	if round.Action.ID != req.Action.ID || round.ClientID != req.ClientID ||
		round.Action.CurrentAction.Content != a.Content {
		t.Fatal("SnsCommentRequest 重编码字段不一致")
	}
}

func TestSNSFixtureObjectOpRequest(t *testing.T) {
	raw := snsMustHex(t, snsFixtureObjectOpRequestHex)
	req, err := UnmarshalSNSObjectOpRequest(raw)
	if err != nil {
		t.Fatalf("objectop 请求解码失败: %v", err)
	}
	if len(req.Ops) != 1 {
		t.Fatalf("OpList 数量错误: %d", len(req.Ops))
	}
	op := req.Ops[0]
	if op.ID != 17000000000000001234 || op.OpType != SNSObjectOpTypeDeleteComment {
		t.Fatalf("op 字段不一致: %+v", op)
	}
	if !bytes.Equal(op.Ext, MarshalSNSObjectOpDeleteComment(SNSObjectOpDeleteComment{CommentID: 3})) {
		t.Fatalf("Ext 未正确拆包: %x", op.Ext)
	}
	// 线上 Ext 必须是 SKBuiltinBuffer_t 包裹。
	var opBytes []byte
	_ = snsWalk(raw, func(f snsWireField) error {
		if f.num == 3 && f.typ == 2 {
			opBytes = f.bytes
		}
		return nil
	})
	if len(opBytes) == 0 {
		t.Fatal("缺少 OpList")
	}
	var ext []byte
	_ = snsWalk(opBytes, func(f snsWireField) error {
		if f.num == 3 && f.typ == 2 {
			ext = f.bytes
		}
		return nil
	})
	if _, ok := ParseSKBuiltinBuffer(ext); !ok {
		t.Fatal("ObjectOp.Ext 未按 SKBuiltinBuffer_t 包裹")
	}
	if snsContainsField(snsTopLevelFieldNums(t, raw), 1) {
		t.Fatal("objectop 请求不应含 BaseRequest")
	}
	round, err := UnmarshalSNSObjectOpRequest(MarshalSNSObjectOpRequest(*req))
	if err != nil {
		t.Fatalf("重编码后解码失败: %v", err)
	}
	if len(round.Ops) != 1 || round.Ops[0].OpType != op.OpType || !bytes.Equal(round.Ops[0].Ext, op.Ext) {
		t.Fatal("SnsObjectOpRequest 重编码不一致")
	}
}

func TestSNSFixtureSyncRequest(t *testing.T) {
	raw := snsMustHex(t, snsFixtureSyncRequestHex)
	req, err := UnmarshalSNSSyncRequest(raw)
	if err != nil {
		t.Fatalf("sync 请求解码失败: %v", err)
	}
	if req.Selector != 256 {
		t.Fatalf("selector 应为 256，实际 %d", req.Selector)
	}
	key, err := UnmarshalSNSSyncKey(req.KeyBuf)
	if err != nil {
		t.Fatalf("SyncKey 解码失败: %v", err)
	}
	if len(key.Items) != 47 {
		t.Fatalf("SyncKey 项数应为 47，实际 %d", len(key.Items))
	}
	if key.Items[0].KeyID != 1 || key.Items[len(key.Items)-1].KeyID != 2003 {
		t.Fatalf("SyncKey 首尾 keyId 不符合抓包: %+v ... %+v", key.Items[0], key.Items[len(key.Items)-1])
	}
	for _, it := range key.Items {
		// 脱敏时把每个 value 替换成「同 varint 长度」的最小值，保持字节长度不变。
		if n := snsVarintLen(uint64(it.Value)); n > 1 && uint64(it.Value) != uint64(1)<<(7*(n-1)) {
			t.Fatalf("SyncKey 值未按等长占位替换: %+v", it)
		}
	}
	// KeyBuf 在 mac 4.2 是 SKBuiltinBuffer_t 包裹。
	var f3 []byte
	_ = snsWalk(raw, func(f snsWireField) error {
		if f.num == 3 && f.typ == 2 {
			f3 = f.bytes
		}
		return nil
	})
	buf, ok := ParseSKBuiltinBuffer(f3)
	if !ok || !bytes.Equal(buf.Data, req.KeyBuf) {
		t.Fatal("Sync.KeyBuf 未按 SKBuiltinBuffer_t 包裹")
	}
	if snsContainsField(snsTopLevelFieldNums(t, raw), 1) {
		t.Fatal("sync 请求不应含 BaseRequest")
	}
	round, err := UnmarshalSNSSyncRequest(MarshalSNSSyncRequest(*req))
	if err != nil {
		t.Fatalf("重编码后解码失败: %v", err)
	}
	if round.Selector != req.Selector || !bytes.Equal(round.KeyBuf, req.KeyBuf) {
		t.Fatal("SnsSyncRequest 重编码不一致")
	}
}

func TestSKBuiltinBuffer(t *testing.T) {
	for _, data := range [][]byte{nil, {}, {1}, bytes.Repeat([]byte{7}, 300)} {
		buf, ok := ParseSKBuiltinBuffer(MarshalSKBuiltinBuffer(data))
		if !ok {
			t.Fatalf("合法包裹解析失败: len=%d", len(data))
		}
		if int(buf.Len) != len(data) || !bytes.Equal(buf.Data, data) {
			t.Fatalf("包裹回读不一致: %+v", buf)
		}
	}
	// 裸 bytes 不应被误判为包裹。
	if _, ok := ParseSKBuiltinBuffer([]byte{0x08, 0x03}); ok {
		t.Fatal("裸 bytes 被误判为 SKBuiltinBuffer_t")
	}
	if _, ok := ParseSKBuiltinBuffer([]byte{0x08, 0x03, 0x12, 0x02, 0x08, 0x01}); ok {
		t.Fatal("Len 与 data 长度不一致时不应视为合法包裹")
	}
}

func TestSNSBaseResponseCompat(t *testing.T) {
	// 标准：field 2 是 BaseErrMsg{1:msg}。
	encoded := MarshalSNSBaseResponse(SNSBaseResponse{Ret: 201, ErrMsg: "spam"})
	base, err := unmarshalSNSBaseResponse(encoded)
	if err != nil || base.Ret != 201 || base.ErrMsg != "spam" {
		t.Fatalf("BaseResponse 回读失败: %+v err=%v", base, err)
	}
	// 兼容：field 2 直接是 string。
	raw := snsAppendVarintField(nil, 1, 202)
	raw = snsAppendStringField(raw, 2, "ban")
	base, err = unmarshalSNSBaseResponse(raw)
	if err != nil || base.Ret != 202 || base.ErrMsg != "ban" {
		t.Fatalf("裸 string ErrMsg 兼容失败: %+v err=%v", base, err)
	}
}

func TestSNSTimelineResponseDecode(t *testing.T) {
	xml := []byte(`<TimelineObject><id>1</id><username>wxid_demo</username>` +
		`<createTime>1794000000</createTime><contentDesc>hello</contentDesc>` +
		`<ContentObject><contentStyle>1</contentStyle><mediaList>` +
		`<media><id>0</id><type>2</type><url type="1">cdn-url-key</url>` +
		`<thumb type="1">cdn-thumb-key</thumb><size totalSize="12345.0" width="1080.0" height="1440.0"></size></media>` +
		`</mediaList></ContentObject></TimelineObject>`)
	obj := SNSObject{
		ID:         15049688834160144930,
		Username:   "wxid_demo",
		Nickname:   "演示",
		CreateTime: 1794000000,
		ObjectDesc: xml,
		LikeCount:  2,
		LikeFlag:   1,
		LikeUserList: []SNSCommentInfo{
			{Username: "wxid_like", Nickname: "点赞者", Type: 1},
		},
		CommentCount: 1,
		CommentUserList: []SNSCommentInfo{
			{Username: "wxid_cmt", Nickname: "评论者", Type: 2, Content: "nice", CreateTime: 1794000100, CommentID2: 77},
			{Username: "wxid_like2", Type: 1},
			{Username: "wxid_del", Type: 2, Content: "deleted", DeleteFlag: 1},
		},
	}
	resp := SNSTimeLineResponse{
		Base:           SNSBaseResponse{Ret: 0},
		FirstPageMD5:   "0011223344556677",
		ObjectCount:    1,
		Objects:        []SNSObject{obj},
		NewRequestTime: 1794000200,
		ControlFlag:    1,
		ServerConfig:   SNSServerConfig{PostMentionLimit: 10, CopyAndPasteWordLimit: 0},
		Session:        []byte("session-bytes"),
	}
	raw := MarshalSNSTimeLineResponse(resp)
	// 注入未知字段，验证解析容忍。
	raw = snsAppendVarintField(raw, 999, 1)
	raw = snsAppendStringField(raw, 1000, "future")

	got, err := UnmarshalSNSTimeLineResponse(raw)
	if err != nil {
		t.Fatalf("时间线响应解析失败: %v", err)
	}
	if got.FirstPageMD5 != "0011223344556677" || got.ControlFlag != 1 ||
		got.ServerConfig.PostMentionLimit != 10 ||
		!bytes.Equal(got.Session, []byte("session-bytes")) {
		t.Fatalf("响应字段不一致: %+v", got)
	}
	if len(got.Objects) != 1 || got.Objects[0].ID != obj.ID ||
		len(got.Objects[0].CommentUserList) != 3 {
		t.Fatalf("SnsObject 回读不一致: %+v", got.Objects)
	}
	if _, err := UnmarshalSNSTimeLineResponse([]byte{0x12, 0x05, 0x01}); err == nil {
		t.Fatal("截断的响应应返回错误")
	}
}

func TestSNSDetailAndWriteResponses(t *testing.T) {
	obj := SNSObject{ID: 42, Username: "wxid_demo", Nickname: "演示", ObjectDesc: []byte("<TimelineObject><contentDesc>hi</contentDesc></TimelineObject>")}
	detail := MarshalSNSObjectDetailResponse(SNSObjectDetailResponse{
		Base:   SNSBaseResponse{Ret: 0},
		Object: &obj,
	})
	gotDetail, err := UnmarshalSNSObjectDetailResponse(detail)
	if err != nil || gotDetail.Object == nil || gotDetail.Object.ID != 42 {
		t.Fatalf("详情响应回读失败: %+v err=%v", gotDetail, err)
	}

	post := MarshalSNSPostResponse(SNSPostResponse{Base: SNSBaseResponse{Ret: 0}, Object: &obj})
	gotPost, err := UnmarshalSNSPostResponse(post)
	if err != nil || gotPost.Object == nil || gotPost.Object.ID != 42 {
		t.Fatalf("发布响应回读失败: %+v err=%v", gotPost, err)
	}
	gotComment, err := UnmarshalSNSCommentResponse(post)
	if err != nil || gotComment.Object == nil || gotComment.Object.ID != 42 {
		t.Fatalf("评论响应回读失败: %+v err=%v", gotComment, err)
	}

	opRaw := MarshalSNSObjectOpResponse(SNSObjectOpResponse{
		Base:      SNSBaseResponse{Ret: 0},
		OpRetList: []int32{0, 201},
	})
	gotOp, err := UnmarshalSNSObjectOpResponse(opRaw)
	if err != nil || len(gotOp.OpRetList) != 2 || gotOp.OpRetList[1] != 201 {
		t.Fatalf("objectop 响应回读失败: %+v err=%v", gotOp, err)
	}

	syncRaw := MarshalSNSSyncResponse(SNSSyncResponse{
		Base:         SNSBaseResponse{Ret: 0},
		CmdList:      SNSCmdList{Items: []SNSCmdItem{{CmdID: 7, CmdBuf: []byte("<xml/>")}}},
		ContinueFlag: 1,
		KeyBuf:       []byte("cursor"),
	})
	gotSync, err := UnmarshalSNSSyncResponse(syncRaw)
	if err != nil || gotSync.ContinueFlag != 1 || !bytes.Equal(gotSync.KeyBuf, []byte("cursor")) ||
		len(gotSync.CmdList.Items) != 1 || gotSync.CmdList.Items[0].CmdID != 7 {
		t.Fatalf("sync 响应回读失败: %+v err=%v", gotSync, err)
	}
}

func TestSNSTimelineObjectXML(t *testing.T) {
	raw := []byte(`<TimelineObject><id>1</id><username>wxid_demo</username>` +
		`<createTime>1794000000</createTime><contentDesc><![CDATA[a &amp; b]]></contentDesc>` +
		`<ContentObject><contentStyle>1</contentStyle><mediaList>` +
		`<media><type>2</type><url type="1">img-key</url><thumb type="1">thumb-key</thumb>` +
		`<size totalSize="200.0" width="1080.0" height="1440.0"></size></media>` +
		`<media><type>4</type><url>video-key</url><thumb>video-thumb</thumb></media>` +
		`</mediaList></ContentObject></TimelineObject>`)
	obj, err := ParseSNSTimelineObject(raw)
	if err != nil {
		t.Fatalf("XML 解析失败: %v", err)
	}
	if obj.ContentDesc != "a &amp; b" {
		t.Fatalf("CDATA 正文解析错误: %q", obj.ContentDesc)
	}
	if obj.ContentObject == nil || obj.ContentObject.MediaList == nil || len(obj.ContentObject.MediaList.Media) != 2 {
		t.Fatalf("媒体列表解析失败: %+v", obj.ContentObject)
	}
	img := obj.ContentObject.MediaList.Media[0]
	if SNSMediaKind(img.Type) != "image" || img.URL.Value != "img-key" || img.Thumb.Value != "thumb-key" {
		t.Fatalf("图片媒体字段错误: %+v", img)
	}
	if w, h := SNSMediaDimensions(img.Size); w != 1080 || h != 1440 {
		t.Fatalf("宽高解析错误: %d x %d", w, h)
	}
	if video := obj.ContentObject.MediaList.Media[1]; SNSMediaKind(video.Type) != "video" {
		t.Fatalf("视频 kind 错误: %+v", video)
	}
}

func TestSNSBuildTimelineObjectText(t *testing.T) {
	raw, err := BuildSNSTimelineObjectText("wxid_demo", `hello <world> & "friends"`, 1794000000, 0)
	if err != nil {
		t.Fatalf("构造 XML 失败: %v", err)
	}
	obj, err := ParseSNSTimelineObject(raw)
	if err != nil {
		t.Fatalf("构造的 XML 无法解析: %v", err)
	}
	if obj.Username != "wxid_demo" || obj.ContentDesc != `hello <world> & "friends"` ||
		obj.Private != "0" || obj.CreateTime != "1794000000" {
		t.Fatalf("构造字段不一致: %+v", obj)
	}
	if obj.ContentObject == nil || obj.ContentObject.ContentStyle != "2" {
		t.Fatalf("纯文字 contentStyle 应为 2: %+v", obj.ContentObject)
	}
}

func TestSNSFridaAdapterJSON(t *testing.T) {
	// 验证生产适配器对 hook 新契约的解析（提交 snsRequest + 轮询 snsPoll）。
	oldCall := snsCallFrida
	t.Cleanup(func() { snsCallFrida = oldCall })

	var mu sync.Mutex
	var calls []string
	var pollCount int
	snsCallFrida = func(fn string, args ...any) (any, error) {
		mu.Lock()
		defer mu.Unlock()
		calls = append(calls, fn)
		switch fn {
		case "snsStatus":
			return `{"ok":true,"enabled":true,"probe":false,"captured":2,"anchors":{},"pending":0,"lastError":""}`, nil
		case "snsRequest":
			if len(args) != 2 {
				t.Fatalf("snsRequest 应为 (op, bodyHex) 两个参数，实际 %v", args)
			}
			if args[0] != "timeline" || args[1] != "1200" {
				t.Fatalf("snsRequest 参数错误: %v", args)
			}
			return `{"ok":true,"requestId":"sns-1-1","taskId":123,"ret":0}`, nil
		case "snsPoll":
			if len(args) != 1 || args[0] != "sns-1-1" {
				t.Fatalf("snsPoll 参数错误: %v", args)
			}
			pollCount++
			if pollCount == 1 {
				return `{"ok":true,"state":"pending"}`, nil
			}
			return `{"ok":true,"state":"done","responseHex":"0a00","elapsedMs":12}`, nil
		case "snsPrime":
			return `{"ok":false,"reason":"open_moments_once","captured":0,"seeds":[]}`, nil
		case "snsMedia":
			return `{"ok":true,"file":"/tmp/x.jpg"}`, nil
		default:
			return nil, fmt.Errorf("unexpected export %s", fn)
		}
	}
	adapter := fridaSNSPRC{}
	ctx := context.Background()
	st, err := adapter.Status(ctx)
	if err != nil || !st.Ready || !st.SeedReady || st.WriteReady {
		t.Fatalf("Status 适配失败: %+v err=%v", st, err)
	}
	_, err = adapter.Prime(ctx, 30)
	se := snsHTTPError(err)
	if se.Code != "sns_need_prime" || se.Status != 503 {
		t.Fatalf("Prime 的 open_moments_once 应映射 need_prime: %+v", se)
	}
	resp, err := adapter.Request(ctx, "timeline", []byte{0x12, 0x00}, 2*time.Second)
	if err != nil || !bytes.Equal(resp.Body, []byte{0x0a, 0x00}) || resp.ElapsedMS != 12 {
		t.Fatalf("Request 提交+轮询失败: %+v err=%v", resp, err)
	}
	if pollCount != 2 {
		t.Fatalf("应轮询到 done（pending 一次），实际 poll=%d", pollCount)
	}
	media, err := adapter.Media(ctx, SNSMediaRequest{Action: "download", Key: "k", Kind: "thumb", PostID: "1", Path: "/tmp/p"})
	if err != nil || media.File != "/tmp/x.jpg" {
		t.Fatalf("Media 适配失败: %+v err=%v", media, err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(calls) < 4 || calls[2] != "snsRequest" || calls[3] != "snsPoll" {
		t.Fatalf("RPC 调用顺序错误: %v", calls)
	}
}

func TestSNSFridaAdapterPollErrorAndTimeout(t *testing.T) {
	oldCall := snsCallFrida
	t.Cleanup(func() { snsCallFrida = oldCall })

	// 提交后 poll 返回 error（例如 need_prime/seed 失效）。
	snsCallFrida = func(fn string, args ...any) (any, error) {
		switch fn {
		case "snsRequest":
			return `{"ok":true,"requestId":"req-1","taskId":1,"ret":0}`, nil
		case "snsPoll":
			return `{"ok":true,"state":"error","error":"need_prime"}`, nil
		}
		return nil, nil
	}
	_, err := (fridaSNSPRC{}).Request(context.Background(), "timeline", nil, time.Second)
	if se := snsHTTPError(err); se.Code != "sns_need_prime" {
		t.Fatalf("poll error 映射错误: %+v", se)
	}

	// 提交后一直 pending，bridge 侧 ctx 超时 → DeadlineExceeded。
	snsCallFrida = func(fn string, args ...any) (any, error) {
		switch fn {
		case "snsRequest":
			return `{"ok":true,"requestId":"req-2","taskId":2,"ret":0}`, nil
		case "snsPoll":
			return `{"ok":true,"state":"pending"}`, nil
		}
		return nil, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	_, err = (fridaSNSPRC{}).Request(ctx, "timeline", nil, 0)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("轮询超时应返回 DeadlineExceeded: %v", err)
	}
}

func TestSNSPatchSyncRequestKeyBuf(t *testing.T) {
	captured := MarshalSNSSyncRequest(SNSSyncRequest{Selector: 256, KeyBuf: []byte{1, 2, 3}})
	// 追加 App 侧未知字段：field 20 (bytes) + field 4 (varint)
	captured = append(captured, 0xA2, 0x01, 0x07)
	captured = append(captured, []byte("keep-me")...)
	captured = append(captured, 0x20, 0x07)

	patched, err := snsPatchSyncRequestKeyBuf(captured, []byte{9, 9})
	if err != nil {
		t.Fatalf("patch: %v", err)
	}
	req, err := UnmarshalSNSSyncRequest(patched)
	if err != nil {
		t.Fatalf("unmarshal patched: %v", err)
	}
	if req.Selector != 256 {
		t.Fatalf("Selector = %d", req.Selector)
	}
	if string(req.KeyBuf) != "\x09\x09" {
		t.Fatalf("KeyBuf = %v", req.KeyBuf)
	}
	if !strings.Contains(string(patched), "keep-me") {
		t.Fatalf("未知 bytes 字段丢失")
	}
	foundVarint := false
	if err := snsWalk(patched, func(f snsWireField) error {
		if f.num == 4 && f.varint == 7 {
			foundVarint = true
		}
		return nil
	}); err != nil {
		t.Fatalf("walk patched: %v", err)
	}
	if !foundVarint {
		t.Fatalf("未知 varint 字段丢失")
	}
}

// 4.2 真机抓包：原生「部分可见」请求是 Privacy=0 + GroupUsers=[好友]。
// 模板可能来自用户手动发的任意一条动态，原帖的 withUser/分组/blackList 不能带到
// 新动态里（曾出现 privacy=2 回包成功、目标好友看不到）。
func TestSNSPatchPostRequestPreservesUnknownFields(t *testing.T) {
	template := MarshalSNSPostRequest(SNSPostRequest{
		ObjectDesc:     []byte("<TimelineObject><content>old</content></TimelineObject>"),
		WithUserList:   []string{"wxid_at"},
		Privacy:        0,
		ClientID:       "sns_post_old",
		Groups:         []SNSGroup{{GroupID: 42}},
		BlackList:      []string{"wxid_blocked"},
		GroupUsers:     []string{"wxid_sample_visible"},
		ClientCheckDat: []byte("check-dat"),
	})
	// 未知字段 99（bytes）：必须原样保留。
	template = append(template, 0x9A, 0x06, 0x07)
	template = append(template, []byte("keep-me")...)

	patched, err := snsPatchPostRequest(template, []byte("<TimelineObject><content>new</content></TimelineObject>"), 0, "sns_post_new", []string{"wxid_friend"})
	if err != nil {
		t.Fatalf("patch: %v", err)
	}
	if !strings.Contains(string(patched), "keep-me") {
		t.Fatalf("未知字段 99 丢失")
	}
	req, err := UnmarshalSNSPostRequest(patched)
	if err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if !strings.Contains(string(req.ObjectDesc), "new") {
		t.Fatalf("正文未替换: %s", req.ObjectDesc)
	}
	if req.Privacy != 0 {
		t.Fatalf("Privacy = %d，原生部分可见应为 0", req.Privacy)
	}
	if req.ClientID != "sns_post_new" {
		t.Fatalf("ClientID = %q", req.ClientID)
	}
	if len(req.GroupUsers) != 1 || req.GroupUsers[0] != "wxid_friend" {
		t.Fatalf("GroupUsers = %v", req.GroupUsers)
	}
	if len(req.WithUserList) != 0 {
		t.Fatalf("模板的 withUser 未清空: %v", req.WithUserList)
	}
	if len(req.Groups) != 0 {
		t.Fatalf("模板的分组未清空: %v", req.Groups)
	}
	if len(req.BlackList) != 0 {
		t.Fatalf("模板的 blackList 未清空: %v", req.BlackList)
	}
	if string(req.ClientCheckDat) != "check-dat" {
		t.Fatalf("ClientCheckDat 丢失: %v", req.ClientCheckDat)
	}
}

// mac 原生 serializer 在 SnsAction 里显式写 field 23 = 0；合成评论请求缺少它时
// 真机表现为「任务提交 ret=0 但无回包」，因此编码必须保留该字段。
func TestSNSActionMarshalIncludesMacField23(t *testing.T) {
	b := MarshalSNSAction(SNSAction{
		FromUsername: "wxid_self", ToUsername: "wxid_peer",
		FromNickname: "self", ToNickname: "peer",
		Type: 2, Source: 0, CreateTime: 1794062721, Content: "hello",
	})
	var hasField23 bool
	if err := snsWalk(b, func(f snsWireField) error {
		if f.num == 23 && f.typ == protowire.VarintType && f.varint == 0 {
			hasField23 = true
		}
		return nil
	}); err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	if !hasField23 {
		t.Fatalf("MarshalSNSAction 缺少 field 23=0（mac 原生语义）: %x", b)
	}
	back, err := UnmarshalSNSAction(b)
	if err != nil {
		t.Fatalf("回读失败: %v", err)
	}
	if back.Content != "hello" || back.Type != 2 || back.ToUsername != "wxid_peer" {
		t.Fatalf("字段回读错误: %+v", back)
	}
}

// 评论模板 patch：替换目标动态/动作/clientId，同时保留 mac 原生报文里的未知字段
// （SnsAction field 23、Group/Request 上的额外字段）。
func TestSNSPatchCommentRequestPreservesUnknownFields(t *testing.T) {
	action := MarshalSNSAction(SNSAction{
		FromUsername: "wxid_self", ToUsername: "wxid_peer",
		FromNickname: "old-from", ToNickname: "wxid_peer",
		Type: 2, Source: 0, CreateTime: 1, Content: "old",
	})
	action = snsAppendVarintField(action, 77, 5) // 模板未知字段
	group := snsAppendVarintField(nil, 1, 111)
	group = snsAppendBytesField(group, 3, action)
	group = snsAppendVarintField(group, 88, 6) // 模板未知字段
	template := snsAppendBytesField(nil, 2, group)
	template = snsAppendStringField(template, 3, "sns_comment:111_1_2")
	template = snsAppendVarintField(template, 77, 9) // 模板未知字段

	req := SNSCommentRequest{
		Action: SNSActionGroup{ID: 222, CurrentAction: &SNSAction{
			FromUsername: "wxid_self", ToUsername: "wxid_new",
			FromNickname: "new-from", ToNickname: "wxid_new",
			Type: 2, CreateTime: 2, Content: "new text",
		}},
		ClientID: "sns_comment:222_2_2",
	}
	body, err := snsPatchCommentRequest(template, req)
	if err != nil {
		t.Fatalf("patch 失败: %v", err)
	}
	parsed, err := UnmarshalSNSCommentRequest(body)
	if err != nil {
		t.Fatalf("回读失败: %v", err)
	}
	if parsed.Action.ID != 222 || parsed.ClientID != "sns_comment:222_2_2" {
		t.Fatalf("目标/幂等键未替换: %+v", parsed)
	}
	a := parsed.Action.CurrentAction
	if a == nil || a.Content != "new text" || a.ToUsername != "wxid_new" ||
		a.FromNickname != "new-from" || a.ToNickname != "wxid_new" {
		t.Fatalf("动作字段未替换: %+v", a)
	}
	// 未知字段仍在：顶层 77=9、group 88=6、action 77=5。
	top := map[protowire.Number]uint64{}
	snsMustWalkVarints(t, body, top)
	if top[77] != 9 {
		t.Fatalf("顶层未知字段 77 丢失: %v", top)
	}
	var groupBytes []byte
	if err := snsWalk(body, func(f snsWireField) error {
		if f.num == 2 && f.typ == protowire.BytesType {
			groupBytes = f.bytes
		}
		return nil
	}); err != nil {
		t.Fatalf("解析 group 失败: %v", err)
	}
	grp := map[protowire.Number]uint64{}
	var actionBytes []byte
	if err := snsWalk(groupBytes, func(f snsWireField) error {
		if f.typ == protowire.VarintType {
			grp[f.num] = f.varint
		}
		if f.num == 3 && f.typ == protowire.BytesType {
			actionBytes = f.bytes
		}
		return nil
	}); err != nil {
		t.Fatalf("解析 group 失败: %v", err)
	}
	if grp[88] != 6 {
		t.Fatalf("group 未知字段 88 丢失: %v", grp)
	}
	act := map[protowire.Number]uint64{}
	snsMustWalkVarints(t, actionBytes, act)
	if act[77] != 5 {
		t.Fatalf("action 未知字段 77 丢失: %v", act)
	}
}

func snsMustWalkVarints(t *testing.T, data []byte, out map[protowire.Number]uint64) {
	t.Helper()
	if err := snsWalk(data, func(f snsWireField) error {
		if f.typ == protowire.VarintType {
			out[f.num] = f.varint
		}
		return nil
	}); err != nil {
		t.Fatalf("walk varints 失败: %v", err)
	}
}

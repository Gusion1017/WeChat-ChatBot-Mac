package main

// 朋友圈（SNS）protobuf 编解码 —— 只覆盖 bridge 读取/写入所需的报文。
//
// 为什么手写而不是 protoc：
//   - 本目录的 proto/ 由上游 onebot 生成，SNS 定义不在其中；为 SNS 单独引入
//     protoc-gen-go 会新增不可复现的构建步骤。
//   - mac 4.2.0.12 的 SNS 报文与公开 schema 有差异（见下），手写更直观。
//
// mac 4.2.0.12 实测差异（`_local/sns-research/capture-findings.md`）：
//   1. 业务 body 里没有 BaseRequest（field 1），BaseRequest 由原生任务层补齐；
//      因此本文件所有请求 Marshal 都不写 field 1。
//   2. 4 处 bytes 字段在线上是 SKBuiltinBuffer_t{1:uint32 len,2:bytes data}：
//      TimeLine.Session / Sync.KeyBuf / Post.ObjectDesc / ObjectOp.Ext。
//      解码时对「恰好是合法 wrapper」的字节自动拆包，兼容未来回到裸 bytes 的情况。
//   3. SnsPostRequest.ClientCheckDat 在 mac 是 field 28（公开 schema 为 27）；
//      解码时 28 优先，27 存入 ClientCheckDatLegacy27 仅作诊断。
//   4. snsId 一律 uint64（禁止 int64），JSON 层再转十进制字符串。
//
// 容忍策略：未知字段按 wire type 跳过；缺失字段取零值；错误返回带字段号的
// error（不包含报文字节，避免把朋友圈内容写进错误/日志）。

import (
	"encoding/xml"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"google.golang.org/protobuf/encoding/protowire"
)

// ---- 底层 wire 读写 -------------------------------------------------------

type snsWireField struct {
	num    protowire.Number
	typ    protowire.Type
	varint uint64
	bytes  []byte
}

// snsWalk 遍历一段 protobuf 字节，未知字段/分组按 wire 规则跳过。
func snsWalk(data []byte, fn func(f snsWireField) error) error {
	for len(data) > 0 {
		num, typ, n := protowire.ConsumeTag(data)
		if n < 0 {
			return fmt.Errorf("sns proto: 非法 tag: %w", protowire.ParseError(n))
		}
		data = data[n:]
		f := snsWireField{num: num, typ: typ}
		switch typ {
		case protowire.VarintType:
			v, m := protowire.ConsumeVarint(data)
			if m < 0 {
				return fmt.Errorf("sns proto: 字段 %d varint 截断: %w", num, protowire.ParseError(m))
			}
			f.varint = v
			data = data[m:]
		case protowire.BytesType:
			v, m := protowire.ConsumeBytes(data)
			if m < 0 {
				return fmt.Errorf("sns proto: 字段 %d bytes 截断: %w", num, protowire.ParseError(m))
			}
			f.bytes = v
			data = data[m:]
		case protowire.Fixed32Type:
			v, m := protowire.ConsumeFixed32(data)
			if m < 0 {
				return fmt.Errorf("sns proto: 字段 %d fixed32 截断", num)
			}
			f.varint = uint64(v)
			data = data[m:]
		case protowire.Fixed64Type:
			v, m := protowire.ConsumeFixed64(data)
			if m < 0 {
				return fmt.Errorf("sns proto: 字段 %d fixed64 截断", num)
			}
			f.varint = v
			data = data[m:]
		default:
			// StartGroup/EndGroup/未知 wire type：按 protobuf 规则整体跳过。
			m := protowire.ConsumeFieldValue(num, typ, data)
			if m < 0 {
				return fmt.Errorf("sns proto: 字段 %d 无法跳过: %w", num, protowire.ParseError(m))
			}
			data = data[m:]
			continue
		}
		if err := fn(f); err != nil {
			return err
		}
	}
	return nil
}

func snsAppendVarintField(dst []byte, num protowire.Number, v uint64) []byte {
	dst = protowire.AppendTag(dst, num, protowire.VarintType)
	return protowire.AppendVarint(dst, v)
}

func snsAppendBytesField(dst []byte, num protowire.Number, b []byte) []byte {
	dst = protowire.AppendTag(dst, num, protowire.BytesType)
	return protowire.AppendBytes(dst, b)
}

func snsAppendStringField(dst []byte, num protowire.Number, s string) []byte {
	dst = protowire.AppendTag(dst, num, protowire.BytesType)
	return protowire.AppendString(dst, s)
}

func snsVarintLen(v uint64) int {
	n := 1
	for v >= 0x80 {
		v >>= 7
		n++
	}
	return n
}

// ---- SKBuiltinBuffer_t ----------------------------------------------------

// SKBuiltinBuffer 对应 wx 的 SKBuiltinBuffer_t（mac 4.2 SNS 的 bytes 字段包裹）。
// 线上形态固定为 {1:uint32 len, 2:bytes data}。
type SKBuiltinBuffer struct {
	Len  uint32
	Data []byte
}

// MarshalSKBuiltinBuffer 按捕获格式写 {1:len,2:data}；空 data 也写两个字段。
func MarshalSKBuiltinBuffer(data []byte) []byte {
	out := make([]byte, 0, 8+len(data))
	out = snsAppendVarintField(out, 1, uint64(len(data)))
	out = snsAppendBytesField(out, 2, data)
	return out
}

// ParseSKBuiltinBuffer 严格解析：必须恰好是 {1:varint,2:bytes}，且 len 与
// data 长度一致，否则返回 ok=false（用于区分裸 bytes 与包裹）。
func ParseSKBuiltinBuffer(data []byte) (SKBuiltinBuffer, bool) {
	var (
		gotLen  bool
		gotData bool
		buf     SKBuiltinBuffer
	)
	err := snsWalk(data, func(f snsWireField) error {
		switch f.num {
		case 1:
			if f.typ != protowire.VarintType || gotLen {
				return errSNSNotBuffer
			}
			buf.Len = uint32(f.varint)
			gotLen = true
		case 2:
			if f.typ != protowire.BytesType || gotData {
				return errSNSNotBuffer
			}
			buf.Data = append([]byte(nil), f.bytes...)
			gotData = true
		default:
			return errSNSNotBuffer
		}
		return nil
	})
	if err != nil || !gotLen || !gotData || buf.Len != uint32(len(buf.Data)) {
		return SKBuiltinBuffer{}, false
	}
	return buf, true
}

var errSNSNotBuffer = errors.New("sns proto: 不是 SKBuiltinBuffer_t")

// snsUnwrapBuffer 在「合法包裹」时拆包，否则原样返回（兼容裸 bytes）。
func snsUnwrapBuffer(data []byte) []byte {
	if buf, ok := ParseSKBuiltinBuffer(data); ok {
		return buf.Data
	}
	return data
}

// ---- BaseResponse ---------------------------------------------------------

// SNSBaseResponse 对应 BaseResponse{1:ret,2:BaseErrMsg{1:msg}}。
// 部分实现把 field 2 直接写成 string，解码时两种都兼容。
type SNSBaseResponse struct {
	Ret    int32
	ErrMsg string
}

func MarshalSNSBaseResponse(resp SNSBaseResponse) []byte {
	var out []byte
	out = snsAppendVarintField(out, 1, uint64(uint32(resp.Ret)))
	if resp.ErrMsg != "" {
		var inner []byte
		inner = snsAppendStringField(inner, 1, resp.ErrMsg)
		out = snsAppendBytesField(out, 2, inner)
	}
	return out
}

func unmarshalSNSBaseResponse(data []byte) (SNSBaseResponse, error) {
	var resp SNSBaseResponse
	err := snsWalk(data, func(f snsWireField) error {
		switch f.num {
		case 1:
			if f.typ == protowire.VarintType {
				resp.Ret = int32(f.varint)
			}
		case 2:
			if f.typ != protowire.BytesType {
				return nil
			}
			// 优先按 BaseErrMsg{1:msg} 解；否则当作裸 string。
			var msg string
			nested := true
			err := snsWalk(f.bytes, func(g snsWireField) error {
				if g.num == 1 && g.typ == protowire.BytesType {
					msg = string(g.bytes)
					return nil
				}
				nested = false
				return errSNSNotBuffer
			})
			if err == nil && nested {
				resp.ErrMsg = msg
			} else {
				resp.ErrMsg = string(f.bytes)
			}
		}
		return nil
	})
	return resp, err
}

// ---- SnsTimeLineRequest / Response ---------------------------------------

// SNSTimeLineRequest 是 mac 4.2 的业务 body（不含 BaseRequest）。
// Session 在线上是 SKBuiltinBuffer_t；此处按裸 data 保存，Marshal 时包裹。
type SNSTimeLineRequest struct {
	FirstPageMD5    string
	MaxID           uint64
	MinFilterID     uint64
	LastRequestTime uint32
	ClientLatestID  uint64
	Session         []byte
}

func MarshalSNSTimeLineRequest(req SNSTimeLineRequest) []byte {
	var out []byte
	out = snsAppendStringField(out, 2, req.FirstPageMD5)
	out = snsAppendVarintField(out, 3, req.MaxID)
	out = snsAppendVarintField(out, 4, req.MinFilterID)
	out = snsAppendVarintField(out, 5, uint64(req.LastRequestTime))
	out = snsAppendVarintField(out, 6, req.ClientLatestID)
	out = snsAppendBytesField(out, 7, MarshalSKBuiltinBuffer(req.Session))
	// mac 4.2.0.12 实测：field 8 NetworkType=1；field 11/13/14/15/16 由原生
	// serializer 显式写 0。业务上无意义，但保持与真机同构，降低服务端风控差异。
	out = snsAppendVarintField(out, 8, 1)
	out = snsAppendVarintField(out, 11, 0)
	out = snsAppendVarintField(out, 13, 0)
	out = snsAppendVarintField(out, 14, 0)
	out = snsAppendVarintField(out, 15, 0)
	out = snsAppendVarintField(out, 16, 0)
	return out
}

func UnmarshalSNSTimeLineRequest(data []byte) (*SNSTimeLineRequest, error) {
	req := &SNSTimeLineRequest{}
	err := snsWalk(data, func(f snsWireField) error {
		switch f.num {
		case 2:
			if f.typ == protowire.BytesType {
				req.FirstPageMD5 = string(f.bytes)
			}
		case 3:
			if f.typ == protowire.VarintType {
				req.MaxID = f.varint
			}
		case 4:
			if f.typ == protowire.VarintType {
				req.MinFilterID = f.varint
			}
		case 5:
			if f.typ == protowire.VarintType {
				req.LastRequestTime = uint32(f.varint)
			}
		case 6:
			if f.typ == protowire.VarintType {
				req.ClientLatestID = f.varint
			}
		case 7:
			if f.typ == protowire.BytesType {
				req.Session = append([]byte(nil), snsUnwrapBuffer(f.bytes)...)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return req, nil
}

// SNSServerConfig 对应 SnsServerConfig。
type SNSServerConfig struct {
	PostMentionLimit      int32
	CopyAndPasteWordLimit int32
}

func MarshalSNSServerConfig(cfg SNSServerConfig) []byte {
	var out []byte
	out = snsAppendVarintField(out, 1, uint64(uint32(cfg.PostMentionLimit)))
	out = snsAppendVarintField(out, 2, uint64(uint32(cfg.CopyAndPasteWordLimit)))
	return out
}

func unmarshalSNSServerConfig(data []byte) (SNSServerConfig, error) {
	var cfg SNSServerConfig
	err := snsWalk(data, func(f snsWireField) error {
		switch f.num {
		case 1:
			if f.typ == protowire.VarintType {
				cfg.PostMentionLimit = int32(f.varint)
			}
		case 2:
			if f.typ == protowire.VarintType {
				cfg.CopyAndPasteWordLimit = int32(f.varint)
			}
		}
		return nil
	})
	return cfg, err
}

// SNSTimeLineResponse 对应 SnsTimeLineResponse。
type SNSTimeLineResponse struct {
	Base                  SNSBaseResponse
	FirstPageMD5          string
	ObjectCount           uint32
	Objects               []SNSObject
	NewRequestTime        uint32
	ObjectCountForSameMD5 uint32
	ControlFlag           uint32
	ServerConfig          SNSServerConfig
	Session               []byte
}

func UnmarshalSNSTimeLineResponse(data []byte) (*SNSTimeLineResponse, error) {
	resp := &SNSTimeLineResponse{}
	err := snsWalk(data, func(f snsWireField) error {
		switch f.num {
		case 1:
			if f.typ == protowire.BytesType {
				base, err := unmarshalSNSBaseResponse(f.bytes)
				if err != nil {
					return fmt.Errorf("sns proto: TimeLineResponse.BaseResponse: %w", err)
				}
				resp.Base = base
			}
		case 2:
			if f.typ == protowire.BytesType {
				resp.FirstPageMD5 = string(f.bytes)
			}
		case 3:
			if f.typ == protowire.VarintType {
				resp.ObjectCount = uint32(f.varint)
			}
		case 4:
			if f.typ == protowire.BytesType {
				obj, err := UnmarshalSNSObject(f.bytes)
				if err != nil {
					return fmt.Errorf("sns proto: TimeLineResponse.ObjectList: %w", err)
				}
				resp.Objects = append(resp.Objects, *obj)
			}
		case 5:
			if f.typ == protowire.VarintType {
				resp.NewRequestTime = uint32(f.varint)
			}
		case 6:
			if f.typ == protowire.VarintType {
				resp.ObjectCountForSameMD5 = uint32(f.varint)
			}
		case 7:
			if f.typ == protowire.VarintType {
				resp.ControlFlag = uint32(f.varint)
			}
		case 8:
			if f.typ == protowire.BytesType {
				cfg, err := unmarshalSNSServerConfig(f.bytes)
				if err != nil {
					return fmt.Errorf("sns proto: TimeLineResponse.ServerConfig: %w", err)
				}
				resp.ServerConfig = cfg
			}
		case 11:
			if f.typ == protowire.BytesType {
				resp.Session = append([]byte(nil), snsUnwrapBuffer(f.bytes)...)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return resp, nil
}

// MarshalSNSTimeLineResponse 主要用于测试/回放，生产路径只解析。
func MarshalSNSTimeLineResponse(resp SNSTimeLineResponse) []byte {
	var out []byte
	out = snsAppendBytesField(out, 1, MarshalSNSBaseResponse(resp.Base))
	out = snsAppendStringField(out, 2, resp.FirstPageMD5)
	out = snsAppendVarintField(out, 3, uint64(resp.ObjectCount))
	for i := range resp.Objects {
		out = snsAppendBytesField(out, 4, MarshalSNSObject(resp.Objects[i]))
	}
	if resp.NewRequestTime != 0 {
		out = snsAppendVarintField(out, 5, uint64(resp.NewRequestTime))
	}
	if resp.ObjectCountForSameMD5 != 0 {
		out = snsAppendVarintField(out, 6, uint64(resp.ObjectCountForSameMD5))
	}
	if resp.ControlFlag != 0 {
		out = snsAppendVarintField(out, 7, uint64(resp.ControlFlag))
	}
	if resp.ServerConfig != (SNSServerConfig{}) {
		out = snsAppendBytesField(out, 8, MarshalSNSServerConfig(resp.ServerConfig))
	}
	if resp.Session != nil {
		out = snsAppendBytesField(out, 11, MarshalSKBuiltinBuffer(resp.Session))
	}
	return out
}

// ---- SnsObject / SnsCommentInfo -------------------------------------------

// SNSCommentInfo 对应 SnsCommentInfo（评论或点赞者）。
type SNSCommentInfo struct {
	Username        string
	Nickname        string
	Source          uint32
	Type            uint32 // 1=赞 2=评论
	Content         string
	CreateTime      uint32
	CommentID       int32 // 旧 32 位
	ReplyCommentID  int32 // 旧 32 位
	ReplyUsername   string
	IsNotRichText   uint32
	ReplyCommentID2 uint64 // 新 64 位，主用
	CommentID2      uint64
	DeleteFlag      uint32
	// CommentFlag 是公开 schema 的 field 14；mac 4.2 真机回包里还出现
	// field 15/21（嵌套二进制，疑似富文本/表情评论载荷，语义待实测）。
	// 这里原样保留，避免归一化时丢弃；不猜测其内容。
	CommentFlag  uint32
	RichContent  []byte
	RichContent2 []byte
}

func MarshalSNSCommentInfo(c SNSCommentInfo) []byte {
	var out []byte
	if c.Username != "" {
		out = snsAppendStringField(out, 1, c.Username)
	}
	if c.Nickname != "" {
		out = snsAppendStringField(out, 2, c.Nickname)
	}
	out = snsAppendVarintField(out, 3, uint64(c.Source))
	out = snsAppendVarintField(out, 4, uint64(c.Type))
	if c.Content != "" {
		out = snsAppendStringField(out, 5, c.Content)
	}
	out = snsAppendVarintField(out, 6, uint64(c.CreateTime))
	if c.CommentID != 0 {
		out = snsAppendVarintField(out, 7, uint64(uint32(c.CommentID)))
	}
	if c.ReplyCommentID != 0 {
		out = snsAppendVarintField(out, 8, uint64(uint32(c.ReplyCommentID)))
	}
	if c.ReplyUsername != "" {
		out = snsAppendStringField(out, 9, c.ReplyUsername)
	}
	if c.IsNotRichText != 0 {
		out = snsAppendVarintField(out, 10, uint64(c.IsNotRichText))
	}
	if c.ReplyCommentID2 != 0 {
		out = snsAppendVarintField(out, 11, c.ReplyCommentID2)
	}
	if c.CommentID2 != 0 {
		out = snsAppendVarintField(out, 12, c.CommentID2)
	}
	if c.DeleteFlag != 0 {
		out = snsAppendVarintField(out, 13, uint64(c.DeleteFlag))
	}
	if c.CommentFlag != 0 {
		out = snsAppendVarintField(out, 14, uint64(c.CommentFlag))
	}
	if c.RichContent != nil {
		out = snsAppendBytesField(out, 15, c.RichContent)
	}
	if c.RichContent2 != nil {
		out = snsAppendBytesField(out, 21, c.RichContent2)
	}
	return out
}

func UnmarshalSNSCommentInfo(data []byte) (*SNSCommentInfo, error) {
	c := &SNSCommentInfo{}
	err := snsWalk(data, func(f snsWireField) error {
		switch f.num {
		case 1:
			if f.typ == protowire.BytesType {
				c.Username = string(f.bytes)
			}
		case 2:
			if f.typ == protowire.BytesType {
				c.Nickname = string(f.bytes)
			}
		case 3:
			if f.typ == protowire.VarintType {
				c.Source = uint32(f.varint)
			}
		case 4:
			if f.typ == protowire.VarintType {
				c.Type = uint32(f.varint)
			}
		case 5:
			if f.typ == protowire.BytesType {
				c.Content = string(f.bytes)
			}
		case 6:
			if f.typ == protowire.VarintType {
				c.CreateTime = uint32(f.varint)
			}
		case 7:
			if f.typ == protowire.VarintType {
				c.CommentID = int32(f.varint)
			}
		case 8:
			if f.typ == protowire.VarintType {
				c.ReplyCommentID = int32(f.varint)
			}
		case 9:
			if f.typ == protowire.BytesType {
				c.ReplyUsername = string(f.bytes)
			}
		case 10:
			if f.typ == protowire.VarintType {
				c.IsNotRichText = uint32(f.varint)
			}
		case 11:
			if f.typ == protowire.VarintType {
				c.ReplyCommentID2 = f.varint
			}
		case 12:
			if f.typ == protowire.VarintType {
				c.CommentID2 = f.varint
			}
		case 13:
			if f.typ == protowire.VarintType {
				c.DeleteFlag = uint32(f.varint)
			}
		case 14:
			if f.typ == protowire.VarintType {
				c.CommentFlag = uint32(f.varint)
			}
		case 15:
			if f.typ == protowire.BytesType {
				c.RichContent = append([]byte(nil), f.bytes...)
			}
		case 21:
			if f.typ == protowire.BytesType {
				c.RichContent2 = append([]byte(nil), f.bytes...)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return c, nil
}

// SNSGroup 对应 SnsGroup{1:GroupId}。
type SNSGroup struct {
	GroupID uint64
}

// SNSObject 对应 SnsObject（只保留 bridge 读取需要的字段）。
type SNSObject struct {
	ID                   uint64
	Username             string
	Nickname             string
	CreateTime           uint32
	ObjectDesc           []byte
	LikeFlag             uint32
	LikeCount            uint32
	LikeUserListCount    uint32
	LikeUserList         []SNSCommentInfo
	CommentCount         uint32
	CommentUserListCount uint32
	CommentUserList      []SNSCommentInfo
	WithUserCount        uint32
	WithUserListCount    uint32
	WithUserList         []SNSCommentInfo
	ExtFlag              uint32
	NoChange             uint32
	GroupCount           uint32
	Groups               []SNSGroup
	IsNotRichText        uint32
	ReferUsername        string
	ReferID              uint64
	BlackListCount       uint32
	BlackList            []string
	DeleteFlag           uint32
	GroupUserCount       uint32
	GroupUsers           []string
}

func MarshalSNSObject(obj SNSObject) []byte {
	var out []byte
	out = snsAppendVarintField(out, 1, obj.ID)
	if obj.Username != "" {
		out = snsAppendStringField(out, 2, obj.Username)
	}
	if obj.Nickname != "" {
		out = snsAppendStringField(out, 3, obj.Nickname)
	}
	out = snsAppendVarintField(out, 4, uint64(obj.CreateTime))
	if obj.ObjectDesc != nil {
		// 与 mac 4.2 真机回包同构：ObjectDesc 包一层 SKBuiltinBuffer_t。
		out = snsAppendBytesField(out, 5, MarshalSKBuiltinBuffer(obj.ObjectDesc))
	}
	out = snsAppendVarintField(out, 6, uint64(obj.LikeFlag))
	out = snsAppendVarintField(out, 7, uint64(obj.LikeCount))
	out = snsAppendVarintField(out, 8, uint64(len(obj.LikeUserList)))
	for i := range obj.LikeUserList {
		out = snsAppendBytesField(out, 9, MarshalSNSCommentInfo(obj.LikeUserList[i]))
	}
	out = snsAppendVarintField(out, 10, uint64(obj.CommentCount))
	out = snsAppendVarintField(out, 11, uint64(len(obj.CommentUserList)))
	for i := range obj.CommentUserList {
		out = snsAppendBytesField(out, 12, MarshalSNSCommentInfo(obj.CommentUserList[i]))
	}
	if obj.WithUserCount != 0 {
		out = snsAppendVarintField(out, 13, uint64(obj.WithUserCount))
	}
	if len(obj.WithUserList) > 0 {
		out = snsAppendVarintField(out, 14, uint64(len(obj.WithUserList)))
		for i := range obj.WithUserList {
			out = snsAppendBytesField(out, 15, MarshalSNSCommentInfo(obj.WithUserList[i]))
		}
	}
	if obj.ExtFlag != 0 {
		out = snsAppendVarintField(out, 16, uint64(obj.ExtFlag))
	}
	if obj.NoChange != 0 {
		out = snsAppendVarintField(out, 17, uint64(obj.NoChange))
	}
	if len(obj.Groups) > 0 {
		out = snsAppendVarintField(out, 18, uint64(len(obj.Groups)))
		for _, g := range obj.Groups {
			var gb []byte
			gb = snsAppendVarintField(gb, 1, g.GroupID)
			out = snsAppendBytesField(out, 19, gb)
		}
	}
	if obj.IsNotRichText != 0 {
		out = snsAppendVarintField(out, 20, uint64(obj.IsNotRichText))
	}
	if obj.ReferUsername != "" {
		out = snsAppendStringField(out, 21, obj.ReferUsername)
	}
	if obj.ReferID != 0 {
		out = snsAppendVarintField(out, 22, obj.ReferID)
	}
	if len(obj.BlackList) > 0 {
		out = snsAppendVarintField(out, 23, uint64(len(obj.BlackList)))
		for _, s := range obj.BlackList {
			var sb []byte
			sb = snsAppendStringField(sb, 1, s)
			out = snsAppendBytesField(out, 24, sb)
		}
	}
	if obj.DeleteFlag != 0 {
		out = snsAppendVarintField(out, 25, uint64(obj.DeleteFlag))
	}
	if len(obj.GroupUsers) > 0 {
		out = snsAppendVarintField(out, 26, uint64(len(obj.GroupUsers)))
		for _, s := range obj.GroupUsers {
			var sb []byte
			sb = snsAppendStringField(sb, 1, s)
			out = snsAppendBytesField(out, 27, sb)
		}
	}
	return out
}

func UnmarshalSNSObject(data []byte) (*SNSObject, error) {
	obj := &SNSObject{}
	err := snsWalk(data, func(f snsWireField) error {
		switch f.num {
		case 1:
			if f.typ == protowire.VarintType {
				obj.ID = f.varint
			}
		case 2:
			if f.typ == protowire.BytesType {
				obj.Username = string(f.bytes)
			}
		case 3:
			if f.typ == protowire.BytesType {
				obj.Nickname = string(f.bytes)
			}
		case 4:
			if f.typ == protowire.VarintType {
				obj.CreateTime = uint32(f.varint)
			}
		case 5:
			if f.typ == protowire.BytesType {
				// mac 4.2 真机回包里 ObjectDesc 也是 SKBuiltinBuffer_t 包裹
				// （与请求侧一致）；解码时自动拆包，兼容裸 XML。
				obj.ObjectDesc = append([]byte(nil), snsUnwrapBuffer(f.bytes)...)
			}
		case 6:
			if f.typ == protowire.VarintType {
				obj.LikeFlag = uint32(f.varint)
			}
		case 7:
			if f.typ == protowire.VarintType {
				obj.LikeCount = uint32(f.varint)
			}
		case 8:
			if f.typ == protowire.VarintType {
				obj.LikeUserListCount = uint32(f.varint)
			}
		case 9:
			if f.typ == protowire.BytesType {
				c, err := UnmarshalSNSCommentInfo(f.bytes)
				if err != nil {
					return fmt.Errorf("sns proto: SnsObject.LikeUserList: %w", err)
				}
				obj.LikeUserList = append(obj.LikeUserList, *c)
			}
		case 10:
			if f.typ == protowire.VarintType {
				obj.CommentCount = uint32(f.varint)
			}
		case 11:
			if f.typ == protowire.VarintType {
				obj.CommentUserListCount = uint32(f.varint)
			}
		case 12:
			if f.typ == protowire.BytesType {
				c, err := UnmarshalSNSCommentInfo(f.bytes)
				if err != nil {
					return fmt.Errorf("sns proto: SnsObject.CommentUserList: %w", err)
				}
				obj.CommentUserList = append(obj.CommentUserList, *c)
			}
		case 13:
			if f.typ == protowire.VarintType {
				obj.WithUserCount = uint32(f.varint)
			}
		case 14:
			if f.typ == protowire.VarintType {
				obj.WithUserListCount = uint32(f.varint)
			}
		case 15:
			if f.typ == protowire.BytesType {
				c, err := UnmarshalSNSCommentInfo(f.bytes)
				if err != nil {
					return fmt.Errorf("sns proto: SnsObject.WithUserList: %w", err)
				}
				obj.WithUserList = append(obj.WithUserList, *c)
			}
		case 16:
			if f.typ == protowire.VarintType {
				obj.ExtFlag = uint32(f.varint)
			}
		case 17:
			if f.typ == protowire.VarintType {
				obj.NoChange = uint32(f.varint)
			}
		case 18:
			if f.typ == protowire.VarintType {
				obj.GroupCount = uint32(f.varint)
			}
		case 19:
			if f.typ == protowire.BytesType {
				var g SNSGroup
				err := snsWalk(f.bytes, func(gf snsWireField) error {
					if gf.num == 1 && gf.typ == protowire.VarintType {
						g.GroupID = gf.varint
					}
					return nil
				})
				if err != nil {
					return fmt.Errorf("sns proto: SnsObject.GroupList: %w", err)
				}
				obj.Groups = append(obj.Groups, g)
			}
		case 20:
			if f.typ == protowire.VarintType {
				obj.IsNotRichText = uint32(f.varint)
			}
		case 21:
			if f.typ == protowire.BytesType {
				obj.ReferUsername = string(f.bytes)
			}
		case 22:
			if f.typ == protowire.VarintType {
				obj.ReferID = f.varint
			}
		case 23:
			if f.typ == protowire.VarintType {
				obj.BlackListCount = uint32(f.varint)
			}
		case 24:
			if f.typ == protowire.BytesType {
				if s, ok := snsParseBuiltinString(f.bytes); ok {
					obj.BlackList = append(obj.BlackList, s)
				}
			}
		case 25:
			if f.typ == protowire.VarintType {
				obj.DeleteFlag = uint32(f.varint)
			}
		case 26:
			if f.typ == protowire.VarintType {
				obj.GroupUserCount = uint32(f.varint)
			}
		case 27:
			if f.typ == protowire.BytesType {
				if s, ok := snsParseBuiltinString(f.bytes); ok {
					obj.GroupUsers = append(obj.GroupUsers, s)
				}
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return obj, nil
}

// snsParseBuiltinString 解析 SKBuiltinString_t{1:string}。
func snsParseBuiltinString(data []byte) (string, bool) {
	var (
		val string
		ok  bool
	)
	_ = snsWalk(data, func(f snsWireField) error {
		if f.num == 1 && f.typ == protowire.BytesType {
			val = string(f.bytes)
			ok = true
		}
		return nil
	})
	return val, ok
}

// ---- SnsObjectDetail ------------------------------------------------------

// SNSObjectDetailRequest 对应服务端结构，但业务 body 不含 BaseRequest。
type SNSObjectDetailRequest struct {
	ID          uint64
	GroupDetail uint32
}

func MarshalSNSObjectDetailRequest(req SNSObjectDetailRequest) []byte {
	var out []byte
	out = snsAppendVarintField(out, 2, req.ID)
	if req.GroupDetail != 0 {
		out = snsAppendVarintField(out, 3, uint64(req.GroupDetail))
	}
	return out
}

func UnmarshalSNSObjectDetailRequest(data []byte) (*SNSObjectDetailRequest, error) {
	req := &SNSObjectDetailRequest{}
	err := snsWalk(data, func(f snsWireField) error {
		switch f.num {
		case 2:
			if f.typ == protowire.VarintType {
				req.ID = f.varint
			}
		case 3:
			if f.typ == protowire.VarintType {
				req.GroupDetail = uint32(f.varint)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return req, nil
}

// SNSObjectDetailResponse 对应 {1:BaseResponse,2:SnsObject}。
type SNSObjectDetailResponse struct {
	Base   SNSBaseResponse
	Object *SNSObject
}

func UnmarshalSNSObjectDetailResponse(data []byte) (*SNSObjectDetailResponse, error) {
	resp := &SNSObjectDetailResponse{}
	err := snsWalk(data, func(f snsWireField) error {
		switch f.num {
		case 1:
			if f.typ == protowire.BytesType {
				base, err := unmarshalSNSBaseResponse(f.bytes)
				if err != nil {
					return fmt.Errorf("sns proto: ObjectDetailResponse.BaseResponse: %w", err)
				}
				resp.Base = base
			}
		case 2:
			if f.typ == protowire.BytesType {
				obj, err := UnmarshalSNSObject(f.bytes)
				if err != nil {
					return fmt.Errorf("sns proto: ObjectDetailResponse.Object: %w", err)
				}
				resp.Object = obj
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return resp, nil
}

func MarshalSNSObjectDetailResponse(resp SNSObjectDetailResponse) []byte {
	var out []byte
	out = snsAppendBytesField(out, 1, MarshalSNSBaseResponse(resp.Base))
	if resp.Object != nil {
		out = snsAppendBytesField(out, 2, MarshalSNSObject(*resp.Object))
	}
	return out
}

// ---- SnsPostRequest / Response -------------------------------------------

// SNSPostRequest 对应 SnsPostRequest；ClientCheckDat 在 mac 是 field 28。
type SNSPostRequest struct {
	ObjectDesc     []byte // <TimelineObject> XML
	WithUserList   []string
	Privacy        uint32
	SyncFlag       uint32
	ClientID       string
	PostBGImgType  uint32
	Groups         []SNSGroup
	ObjectSource   uint32
	ReferID        uint64
	BlackList      []string
	GroupUsers     []string
	ClientCheckDat []byte
	// ClientCheckDatLegacy27 只在解析公开 schema 的旧 field 27 时填充，不参与编码。
	ClientCheckDatLegacy27 []byte
}

func MarshalSNSPostRequest(req SNSPostRequest) []byte {
	var out []byte
	if req.ObjectDesc != nil {
		out = snsAppendBytesField(out, 2, MarshalSKBuiltinBuffer(req.ObjectDesc))
	}
	out = snsAppendVarintField(out, 3, uint64(len(req.WithUserList)))
	for _, u := range req.WithUserList {
		var ub []byte
		ub = snsAppendStringField(ub, 1, u)
		out = snsAppendBytesField(out, 4, ub)
	}
	out = snsAppendVarintField(out, 5, uint64(req.Privacy))
	out = snsAppendVarintField(out, 6, uint64(req.SyncFlag))
	if req.ClientID != "" {
		out = snsAppendStringField(out, 7, req.ClientID)
	}
	if req.PostBGImgType != 0 {
		out = snsAppendVarintField(out, 8, uint64(req.PostBGImgType))
	}
	out = snsAppendVarintField(out, 9, uint64(len(req.Groups)))
	for _, g := range req.Groups {
		var gb []byte
		gb = snsAppendVarintField(gb, 1, g.GroupID)
		out = snsAppendBytesField(out, 10, gb)
	}
	if req.ObjectSource != 0 {
		out = snsAppendVarintField(out, 11, uint64(req.ObjectSource))
	}
	if req.ReferID != 0 {
		out = snsAppendVarintField(out, 12, req.ReferID)
	}
	out = snsAppendVarintField(out, 13, uint64(len(req.BlackList)))
	for _, u := range req.BlackList {
		var ub []byte
		ub = snsAppendStringField(ub, 1, u)
		out = snsAppendBytesField(out, 14, ub)
	}
	out = snsAppendVarintField(out, 16, uint64(len(req.GroupUsers)))
	for _, u := range req.GroupUsers {
		var ub []byte
		ub = snsAppendStringField(ub, 1, u)
		out = snsAppendBytesField(out, 17, ub)
	}
	if req.ClientCheckDat != nil {
		out = snsAppendBytesField(out, 28, req.ClientCheckDat)
	}
	// mac 4.2.0.12 捕获里还有 field 38=0（未知新字段），保持同构。
	out = snsAppendVarintField(out, 38, 0)
	return out
}

// snsPatchPostRequest 以真实捕获的 SnsPostRequest 为模板重建发布请求：
// 逐字段拷贝**所有未知字段**（包括 ClientCheckDat field 28、背景/来源等），只替换
// 正文 XML（field 2）、withUser 列表（3/4）、Privacy（5）、ClientID（7）、GroupUsers（16/17）。
// 同时清空模板里可能残留的分组（9/10）与 blackList（13/14）：发布样本是用户
// 手动发的某一条动态，原帖的可见范围不能泄漏到新动态（否则目标好友可能被排除）。
// 不能先 Unmarshal 再 Marshal——未建模字段会被丢弃，服务端可能静默拒绝。
func snsPatchPostRequest(template, objectDesc []byte, privacy uint32, clientID string, groupUsers []string) ([]byte, error) {
	if len(template) == 0 {
		return nil, fmt.Errorf("sns proto: post 模板为空")
	}
	out := make([]byte, 0, len(template)+len(objectDesc)+len(clientID)+64)
	data := template
	for len(data) > 0 {
		num, typ, n := protowire.ConsumeTag(data)
		if n < 0 {
			return nil, fmt.Errorf("sns proto: post 模板 tag 截断: %w", protowire.ParseError(n))
		}
		data = data[n:]
		raw, m, err := snsConsumeRawField(typ, data)
		if err != nil {
			return nil, fmt.Errorf("sns proto: post 模板字段 %d: %w", num, err)
		}
		data = data[m:]
		switch num {
		// 2/3/4/5/7/16/17 下面统一重建；9/10 是分组、13/14 是 blackList，
		// 属于模板原帖的可见范围，必须清空，避免把发布样本的隐私设置带到新动态。
		case 2, 3, 4, 5, 7, 9, 10, 13, 14, 16, 17:
			continue
		}
		out = protowire.AppendTag(out, num, typ)
		out = append(out, raw...)
	}
	out = snsAppendBytesField(out, 2, MarshalSKBuiltinBuffer(objectDesc))
	out = snsAppendVarintField(out, 3, 0)
	out = snsAppendVarintField(out, 5, uint64(privacy))
	if clientID != "" {
		out = snsAppendStringField(out, 7, clientID)
	}
	out = snsAppendVarintField(out, 16, uint64(len(groupUsers)))
	for _, u := range groupUsers {
		var ub []byte
		ub = snsAppendStringField(ub, 1, u)
		out = snsAppendBytesField(out, 17, ub)
	}
	return out, nil
}

// snsConsumeRawField 读取一个 already-tagged 顶层字段的原始 value 字节（含长度前缀）。
func snsConsumeRawField(typ protowire.Type, data []byte) ([]byte, int, error) {
	switch typ {
	case protowire.VarintType:
		_, m := protowire.ConsumeVarint(data)
		if m < 0 {
			return nil, 0, fmt.Errorf("varint 截断")
		}
		return data[:m], m, nil
	case protowire.BytesType:
		_, m := protowire.ConsumeBytes(data)
		if m < 0 {
			return nil, 0, fmt.Errorf("bytes 截断")
		}
		return data[:m], m, nil
	case protowire.Fixed32Type:
		_, m := protowire.ConsumeFixed32(data)
		if m < 0 {
			return nil, 0, fmt.Errorf("fixed32 截断")
		}
		return data[:m], m, nil
	case protowire.Fixed64Type:
		_, m := protowire.ConsumeFixed64(data)
		if m < 0 {
			return nil, 0, fmt.Errorf("fixed64 截断")
		}
		return data[:m], m, nil
	default:
		return nil, 0, fmt.Errorf("不支持的 wire type %d", typ)
	}
}

func UnmarshalSNSPostRequest(data []byte) (*SNSPostRequest, error) {
	req := &SNSPostRequest{}
	err := snsWalk(data, func(f snsWireField) error {
		switch f.num {
		case 2:
			if f.typ == protowire.BytesType {
				req.ObjectDesc = append([]byte(nil), snsUnwrapBuffer(f.bytes)...)
			}
		case 3:
			if f.typ == protowire.VarintType {
				// WithUserListCount，长度以实际列表为准。
			}
		case 4:
			if f.typ == protowire.BytesType {
				if s, ok := snsParseBuiltinString(f.bytes); ok {
					req.WithUserList = append(req.WithUserList, s)
				}
			}
		case 5:
			if f.typ == protowire.VarintType {
				req.Privacy = uint32(f.varint)
			}
		case 6:
			if f.typ == protowire.VarintType {
				req.SyncFlag = uint32(f.varint)
			}
		case 7:
			if f.typ == protowire.BytesType {
				req.ClientID = string(f.bytes)
			}
		case 8:
			if f.typ == protowire.VarintType {
				req.PostBGImgType = uint32(f.varint)
			}
		case 10:
			if f.typ == protowire.BytesType {
				var g SNSGroup
				_ = snsWalk(f.bytes, func(gf snsWireField) error {
					if gf.num == 1 && gf.typ == protowire.VarintType {
						g.GroupID = gf.varint
					}
					return nil
				})
				req.Groups = append(req.Groups, g)
			}
		case 11:
			if f.typ == protowire.VarintType {
				req.ObjectSource = uint32(f.varint)
			}
		case 12:
			if f.typ == protowire.VarintType {
				req.ReferID = f.varint
			}
		case 14:
			if f.typ == protowire.BytesType {
				if s, ok := snsParseBuiltinString(f.bytes); ok {
					req.BlackList = append(req.BlackList, s)
				}
			}
		case 17:
			if f.typ == protowire.BytesType {
				if s, ok := snsParseBuiltinString(f.bytes); ok {
					req.GroupUsers = append(req.GroupUsers, s)
				}
			}
		case 27:
			if f.typ == protowire.BytesType {
				req.ClientCheckDatLegacy27 = append([]byte(nil), f.bytes...)
			}
		case 28:
			if f.typ == protowire.BytesType {
				req.ClientCheckDat = append([]byte(nil), f.bytes...)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return req, nil
}

// SNSPostResponse 对应 {1:BaseResponse,2:SnsObject}。
type SNSPostResponse struct {
	Base   SNSBaseResponse
	Object *SNSObject
}

func UnmarshalSNSPostResponse(data []byte) (*SNSPostResponse, error) {
	resp := &SNSPostResponse{}
	err := snsWalk(data, func(f snsWireField) error {
		switch f.num {
		case 1:
			if f.typ == protowire.BytesType {
				base, err := unmarshalSNSBaseResponse(f.bytes)
				if err != nil {
					return fmt.Errorf("sns proto: PostResponse.BaseResponse: %w", err)
				}
				resp.Base = base
			}
		case 2:
			if f.typ == protowire.BytesType {
				obj, err := UnmarshalSNSObject(f.bytes)
				if err != nil {
					return fmt.Errorf("sns proto: PostResponse.Object: %w", err)
				}
				resp.Object = obj
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return resp, nil
}

func MarshalSNSPostResponse(resp SNSPostResponse) []byte {
	var out []byte
	out = snsAppendBytesField(out, 1, MarshalSNSBaseResponse(resp.Base))
	if resp.Object != nil {
		out = snsAppendBytesField(out, 2, MarshalSNSObject(*resp.Object))
	}
	return out
}

// ---- SnsCommentRequest / SnsActionGroup ----------------------------------

// SNSAction 对应 SnsAction（评论/点赞/回复）。
//
// 真机抓包（`_local/sns-research/capture-findings.md` §4.3，mac 4.2.0.17）显示
// 原生 serializer 会显式写 field 23 = 0；该字段在公开 schema 里没有，语义未知，
// 这里保留为 CommentScene 以便与原生报文同构（proto2 风格的 presence 语义可能影响服务端）。
type SNSAction struct {
	FromUsername    string
	ToUsername      string
	FromNickname    string
	ToNickname      string
	Type            uint32 // 1=赞 2=评论
	Source          uint32
	CreateTime      uint32
	Content         string
	ReplyCommentID  int32
	CommentID       int32
	IsNotRichText   uint32
	ReplyCommentID2 uint64
	CommentID2      uint64
	CommentScene    uint32 // mac field 23：真机始终写 0
}

func MarshalSNSAction(a SNSAction) []byte {
	var out []byte
	if a.FromUsername != "" {
		out = snsAppendStringField(out, 1, a.FromUsername)
	}
	if a.ToUsername != "" {
		out = snsAppendStringField(out, 2, a.ToUsername)
	}
	if a.FromNickname != "" {
		out = snsAppendStringField(out, 3, a.FromNickname)
	}
	if a.ToNickname != "" {
		out = snsAppendStringField(out, 4, a.ToNickname)
	}
	out = snsAppendVarintField(out, 5, uint64(a.Type))
	out = snsAppendVarintField(out, 6, uint64(a.Source))
	out = snsAppendVarintField(out, 7, uint64(a.CreateTime))
	// 点赞时 Content 为空串：仍显式写 field 8，与原生 serializer 的
	// 「字段已设置」语义一致。
	out = snsAppendStringField(out, 8, a.Content)
	if a.ReplyCommentID != 0 {
		out = snsAppendVarintField(out, 9, uint64(uint32(a.ReplyCommentID)))
	}
	if a.CommentID != 0 {
		out = snsAppendVarintField(out, 10, uint64(uint32(a.CommentID)))
	}
	if a.IsNotRichText != 0 {
		out = snsAppendVarintField(out, 11, uint64(a.IsNotRichText))
	}
	if a.ReplyCommentID2 != 0 {
		out = snsAppendVarintField(out, 12, a.ReplyCommentID2)
	}
	if a.CommentID2 != 0 {
		out = snsAppendVarintField(out, 13, a.CommentID2)
	}
	// mac 原生 serializer 显式写 field 23（值 0）；保持同构，避免服务端因字段
	// presence 差异静默丢弃评论（真机 2026-11-08：缺该字段时请求无回包）。
	out = snsAppendVarintField(out, 23, uint64(a.CommentScene))
	return out
}

func UnmarshalSNSAction(data []byte) (*SNSAction, error) {
	a := &SNSAction{}
	err := snsWalk(data, func(f snsWireField) error {
		switch f.num {
		case 1:
			if f.typ == protowire.BytesType {
				a.FromUsername = string(f.bytes)
			}
		case 2:
			if f.typ == protowire.BytesType {
				a.ToUsername = string(f.bytes)
			}
		case 3:
			if f.typ == protowire.BytesType {
				a.FromNickname = string(f.bytes)
			}
		case 4:
			if f.typ == protowire.BytesType {
				a.ToNickname = string(f.bytes)
			}
		case 5:
			if f.typ == protowire.VarintType {
				a.Type = uint32(f.varint)
			}
		case 6:
			if f.typ == protowire.VarintType {
				a.Source = uint32(f.varint)
			}
		case 7:
			if f.typ == protowire.VarintType {
				a.CreateTime = uint32(f.varint)
			}
		case 8:
			if f.typ == protowire.BytesType {
				a.Content = string(f.bytes)
			}
		case 9:
			if f.typ == protowire.VarintType {
				a.ReplyCommentID = int32(f.varint)
			}
		case 10:
			if f.typ == protowire.VarintType {
				a.CommentID = int32(f.varint)
			}
		case 11:
			if f.typ == protowire.VarintType {
				a.IsNotRichText = uint32(f.varint)
			}
		case 12:
			if f.typ == protowire.VarintType {
				a.ReplyCommentID2 = f.varint
			}
		case 13:
			if f.typ == protowire.VarintType {
				a.CommentID2 = f.varint
			}
		case 23:
			if f.typ == protowire.VarintType {
				a.CommentScene = uint32(f.varint)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return a, nil
}

// SNSActionGroup 对应 SnsActionGroup。
type SNSActionGroup struct {
	ID            uint64
	ParentID      uint64
	CurrentAction *SNSAction
	ReferAction   *SNSAction
	ClientID      string
}

func MarshalSNSActionGroup(g SNSActionGroup) []byte {
	var out []byte
	out = snsAppendVarintField(out, 1, g.ID)
	if g.ParentID != 0 {
		out = snsAppendVarintField(out, 2, g.ParentID)
	}
	if g.CurrentAction != nil {
		out = snsAppendBytesField(out, 3, MarshalSNSAction(*g.CurrentAction))
	}
	if g.ReferAction != nil {
		out = snsAppendBytesField(out, 4, MarshalSNSAction(*g.ReferAction))
	}
	if g.ClientID != "" {
		out = snsAppendStringField(out, 5, g.ClientID)
	}
	return out
}

func UnmarshalSNSActionGroup(data []byte) (*SNSActionGroup, error) {
	g := &SNSActionGroup{}
	err := snsWalk(data, func(f snsWireField) error {
		switch f.num {
		case 1:
			if f.typ == protowire.VarintType {
				g.ID = f.varint
			}
		case 2:
			if f.typ == protowire.VarintType {
				g.ParentID = f.varint
			}
		case 3:
			if f.typ == protowire.BytesType {
				a, err := UnmarshalSNSAction(f.bytes)
				if err != nil {
					return fmt.Errorf("sns proto: SnsActionGroup.CurrentAction: %w", err)
				}
				g.CurrentAction = a
			}
		case 4:
			if f.typ == protowire.BytesType {
				a, err := UnmarshalSNSAction(f.bytes)
				if err != nil {
					return fmt.Errorf("sns proto: SnsActionGroup.ReferAction: %w", err)
				}
				g.ReferAction = a
			}
		case 5:
			if f.typ == protowire.BytesType {
				g.ClientID = string(f.bytes)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return g, nil
}

// SNSCommentRequest 对应 {2:SnsActionGroup,3:ClientId}，无 BaseRequest。
type SNSCommentRequest struct {
	Action   SNSActionGroup
	ClientID string
}

func MarshalSNSCommentRequest(req SNSCommentRequest) []byte {
	var out []byte
	out = snsAppendBytesField(out, 2, MarshalSNSActionGroup(req.Action))
	if req.ClientID != "" {
		out = snsAppendStringField(out, 3, req.ClientID)
	}
	return out
}

func UnmarshalSNSCommentRequest(data []byte) (*SNSCommentRequest, error) {
	req := &SNSCommentRequest{}
	err := snsWalk(data, func(f snsWireField) error {
		switch f.num {
		case 2:
			if f.typ == protowire.BytesType {
				g, err := UnmarshalSNSActionGroup(f.bytes)
				if err != nil {
					return fmt.Errorf("sns proto: SnsCommentRequest.Action: %w", err)
				}
				req.Action = *g
			}
		case 3:
			if f.typ == protowire.BytesType {
				req.ClientID = string(f.bytes)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return req, nil
}

// ---- 评论模板 patch（mac 原生报文同构） --------------------------------
//
// 真机抓包显示 SnsCommentRequest/SnsAction 里有公开 schema 之外的字段（SnsAction
// field 23）与 mac 特有的昵称取值；自己拼报文时服务端会静默丢弃。这里以 hook 捕获的
// **真实评论请求**为模板，逐字段保留未知字段、只替换目标动态/正文/类型/clientId，
// 与发布（snsPatchPostRequest）采用同一策略。

type snsRewriteMode int

const (
	snsRewriteKeep snsRewriteMode = iota
	snsRewriteReplace
	snsRewriteSkip
)

// snsRewriteFields 逐字段复制 protobuf 报文。handler 返回 Replace 时用新值替换
// （新值不含 tag，wire type 沿用原字段），Skip 表示丢弃该字段，Keep 表示原样保留。
func snsRewriteFields(data []byte, handled map[protowire.Number]func(typ protowire.Type, value []byte) ([]byte, snsRewriteMode, error)) ([]byte, error) {
	out := make([]byte, 0, len(data))
	rest := data
	for len(rest) > 0 {
		num, typ, n := protowire.ConsumeTag(rest)
		if n < 0 {
			return nil, fmt.Errorf("sns proto: 模板 tag 截断: %w", protowire.ParseError(n))
		}
		rest = rest[n:]
		// raw 保留「值」的完整 wire 编码（bytes 含长度前缀）；handler 拿到 bytes 的
		// 裸 payload（不含长度前缀），varint/fixed 拿原样值。
		raw := []byte(nil)
		value := []byte(nil)
		switch typ {
		case protowire.VarintType:
			_, n := protowire.ConsumeVarint(rest)
			if n < 0 {
				return nil, fmt.Errorf("sns proto: 模板字段 %d varint 截断", num)
			}
			raw = rest[:n]
			value = raw
		case protowire.BytesType:
			payload, n := protowire.ConsumeBytes(rest)
			if n < 0 {
				return nil, fmt.Errorf("sns proto: 模板字段 %d bytes 截断", num)
			}
			raw = rest[:n]
			value = payload
		case protowire.Fixed32Type:
			_, n := protowire.ConsumeFixed32(rest)
			if n < 0 {
				return nil, fmt.Errorf("sns proto: 模板字段 %d fixed32 截断", num)
			}
			raw = rest[:n]
			value = raw
		case protowire.Fixed64Type:
			_, n := protowire.ConsumeFixed64(rest)
			if n < 0 {
				return nil, fmt.Errorf("sns proto: 模板字段 %d fixed64 截断", num)
			}
			raw = rest[:n]
			value = raw
		default:
			return nil, fmt.Errorf("sns proto: 模板字段 %d wire type %d 不支持", num, typ)
		}
		rest = rest[len(raw):]
		if handler, ok := handled[num]; ok {
			newValue, mode, err := handler(typ, value)
			if err != nil {
				return nil, err
			}
			switch mode {
			case snsRewriteReplace:
				out = protowire.AppendTag(out, num, typ)
				out = append(out, newValue...)
				continue
			case snsRewriteSkip:
				continue
			}
		}
		out = protowire.AppendTag(out, num, typ)
		out = append(out, raw...)
	}
	return out, nil
}

func snsConsumeRawValueLen(data []byte, typ protowire.Type) int {
	switch typ {
	case protowire.VarintType:
		_, n := protowire.ConsumeVarint(data)
		return n
	case protowire.BytesType:
		_, n := protowire.ConsumeBytes(data)
		return n
	case protowire.Fixed32Type:
		_, n := protowire.ConsumeFixed32(data)
		return n
	case protowire.Fixed64Type:
		_, n := protowire.ConsumeFixed64(data)
		return n
	}
	return -1
}

func snsReplaceString(value string) ([]byte, snsRewriteMode, error) {
	out := make([]byte, 0, len(value))
	out = append(out, protowire.AppendString(nil, value)...)
	return out, snsRewriteReplace, nil
}

func snsReplaceVarint(value uint64) ([]byte, snsRewriteMode, error) {
	out := make([]byte, 0, protowire.SizeVarint(value))
	out = protowire.AppendVarint(out, value)
	return out, snsRewriteReplace, nil
}

func snsPatchCommentAction(template []byte, a SNSAction) ([]byte, error) {
	seen := map[protowire.Number]bool{}
	handled := map[protowire.Number]func(protowire.Type, []byte) ([]byte, snsRewriteMode, error){
		1: func(typ protowire.Type, _ []byte) ([]byte, snsRewriteMode, error) {
			seen[1] = true
			return snsReplaceString(a.FromUsername)
		},
		2: func(typ protowire.Type, _ []byte) ([]byte, snsRewriteMode, error) {
			seen[2] = true
			return snsReplaceString(a.ToUsername)
		},
		3: func(typ protowire.Type, _ []byte) ([]byte, snsRewriteMode, error) {
			seen[3] = true
			return snsReplaceString(a.FromNickname)
		},
		4: func(typ protowire.Type, _ []byte) ([]byte, snsRewriteMode, error) {
			seen[4] = true
			return snsReplaceString(a.ToNickname)
		},
		5: func(typ protowire.Type, _ []byte) ([]byte, snsRewriteMode, error) {
			seen[5] = true
			return snsReplaceVarint(uint64(a.Type))
		},
		7: func(typ protowire.Type, _ []byte) ([]byte, snsRewriteMode, error) {
			seen[7] = true
			return snsReplaceVarint(uint64(a.CreateTime))
		},
		8: func(typ protowire.Type, _ []byte) ([]byte, snsRewriteMode, error) {
			seen[8] = true
			return snsReplaceString(a.Content)
		},
		// 回复字段由本函数在末尾按需重建，避免模板里的旧回复指向残留。
		9:  func(protowire.Type, []byte) ([]byte, snsRewriteMode, error) { return nil, snsRewriteSkip, nil },
		10: func(protowire.Type, []byte) ([]byte, snsRewriteMode, error) { return nil, snsRewriteSkip, nil },
		11: func(protowire.Type, []byte) ([]byte, snsRewriteMode, error) { return nil, snsRewriteSkip, nil },
		12: func(protowire.Type, []byte) ([]byte, snsRewriteMode, error) { return nil, snsRewriteSkip, nil },
		13: func(protowire.Type, []byte) ([]byte, snsRewriteMode, error) { return nil, snsRewriteSkip, nil },
	}
	out, err := snsRewriteFields(template, handled)
	if err != nil {
		return nil, err
	}
	// 模板缺字段时补齐（正常抓包模板不会缺，这里只是防御）。
	if !seen[1] && a.FromUsername != "" {
		out = snsAppendStringField(out, 1, a.FromUsername)
	}
	if !seen[2] && a.ToUsername != "" {
		out = snsAppendStringField(out, 2, a.ToUsername)
	}
	if !seen[3] && a.FromNickname != "" {
		out = snsAppendStringField(out, 3, a.FromNickname)
	}
	if !seen[4] && a.ToNickname != "" {
		out = snsAppendStringField(out, 4, a.ToNickname)
	}
	if !seen[5] {
		out = snsAppendVarintField(out, 5, uint64(a.Type))
	}
	if !seen[7] {
		out = snsAppendVarintField(out, 7, uint64(a.CreateTime))
	}
	if !seen[8] {
		out = snsAppendStringField(out, 8, a.Content)
	}
	if a.ReplyCommentID != 0 {
		out = snsAppendVarintField(out, 9, uint64(uint32(a.ReplyCommentID)))
	}
	if a.ReplyCommentID2 != 0 {
		out = snsAppendVarintField(out, 12, a.ReplyCommentID2)
	}
	return out, nil
}

func snsPatchCommentGroup(template []byte, g SNSActionGroup) ([]byte, error) {
	handled := map[protowire.Number]func(protowire.Type, []byte) ([]byte, snsRewriteMode, error){
		1: func(typ protowire.Type, _ []byte) ([]byte, snsRewriteMode, error) {
			return snsReplaceVarint(g.ID)
		},
		3: func(typ protowire.Type, value []byte) ([]byte, snsRewriteMode, error) {
			if g.CurrentAction == nil {
				return nil, snsRewriteKeep, nil
			}
			patch, err := snsPatchCommentAction(value, *g.CurrentAction)
			if err != nil {
				return nil, snsRewriteKeep, err
			}
			return protowire.AppendBytes(nil, patch), snsRewriteReplace, nil
		},
	}
	return snsRewriteFields(template, handled)
}

// snsPatchCommentRequest 以真实评论请求为模板重建：保留未知字段（含 SnsAction
// field 23、SnsActionGroup/Request 上 mac 特有字段），只替换目标动态、动作与 clientId。
func snsPatchCommentRequest(template []byte, req SNSCommentRequest) ([]byte, error) {
	handled := map[protowire.Number]func(protowire.Type, []byte) ([]byte, snsRewriteMode, error){
		2: func(typ protowire.Type, value []byte) ([]byte, snsRewriteMode, error) {
			if typ != protowire.BytesType {
				return nil, snsRewriteKeep, nil
			}
			patch, err := snsPatchCommentGroup(value, req.Action)
			if err != nil {
				return nil, snsRewriteKeep, err
			}
			return protowire.AppendBytes(nil, patch), snsRewriteReplace, nil
		},
		3: func(typ protowire.Type, _ []byte) ([]byte, snsRewriteMode, error) {
			if typ != protowire.BytesType {
				return nil, snsRewriteKeep, nil
			}
			return protowire.AppendString(nil, req.ClientID), snsRewriteReplace, nil
		},
	}
	return snsRewriteFields(template, handled)
}

// SNSCommentResponse 与 PostResponse 同构（返回更新后的 SnsObject）。
type SNSCommentResponse = SNSPostResponse

func UnmarshalSNSCommentResponse(data []byte) (*SNSCommentResponse, error) {
	return UnmarshalSNSPostResponse(data)
}

func MarshalSNSCommentResponse(resp SNSCommentResponse) []byte {
	return MarshalSNSPostResponse(resp)
}

// ---- SnsObjectOp ----------------------------------------------------------

// SNSObjectOp 对应 SnsObjectOp{1:Id,2:OpType,3:Ext}，Ext 在 mac 上包裹。
type SNSObjectOp struct {
	ID     uint64
	OpType uint32
	Ext    []byte
}

// SNSObjectOpType 枚举（与公开资料一致）。
const (
	SNSObjectOpTypeDelete        = 1
	SNSObjectOpTypeSetPrivacy    = 2
	SNSObjectOpTypeSetOpen       = 3
	SNSObjectOpTypeDeleteComment = 4
	SNSObjectOpTypeCancelLike    = 5
)

// SNSObjectOpDeleteComment 对应 OpType=4 时的 Ext 内容。
type SNSObjectOpDeleteComment struct {
	CommentID uint32
}

func MarshalSNSObjectOpDeleteComment(c SNSObjectOpDeleteComment) []byte {
	return snsAppendVarintField(nil, 1, uint64(c.CommentID))
}

func UnmarshalSNSObjectOpDeleteComment(data []byte) (*SNSObjectOpDeleteComment, error) {
	c := &SNSObjectOpDeleteComment{}
	err := snsWalk(data, func(f snsWireField) error {
		if f.num == 1 && f.typ == protowire.VarintType {
			c.CommentID = uint32(f.varint)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return c, nil
}

func MarshalSNSObjectOp(op SNSObjectOp) []byte {
	var out []byte
	out = snsAppendVarintField(out, 1, op.ID)
	out = snsAppendVarintField(out, 2, uint64(op.OpType))
	if op.Ext != nil {
		out = snsAppendBytesField(out, 3, MarshalSKBuiltinBuffer(op.Ext))
	}
	return out
}

func UnmarshalSNSObjectOp(data []byte) (*SNSObjectOp, error) {
	op := &SNSObjectOp{}
	err := snsWalk(data, func(f snsWireField) error {
		switch f.num {
		case 1:
			if f.typ == protowire.VarintType {
				op.ID = f.varint
			}
		case 2:
			if f.typ == protowire.VarintType {
				op.OpType = uint32(f.varint)
			}
		case 3:
			if f.typ == protowire.BytesType {
				op.Ext = append([]byte(nil), snsUnwrapBuffer(f.bytes)...)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return op, nil
}

// SNSObjectOpRequest 对应 {2:OpCount,3:OpList[]}，无 BaseRequest。
type SNSObjectOpRequest struct {
	Ops []SNSObjectOp
}

func MarshalSNSObjectOpRequest(req SNSObjectOpRequest) []byte {
	var out []byte
	out = snsAppendVarintField(out, 2, uint64(len(req.Ops)))
	for i := range req.Ops {
		out = snsAppendBytesField(out, 3, MarshalSNSObjectOp(req.Ops[i]))
	}
	return out
}

func UnmarshalSNSObjectOpRequest(data []byte) (*SNSObjectOpRequest, error) {
	req := &SNSObjectOpRequest{}
	err := snsWalk(data, func(f snsWireField) error {
		switch f.num {
		case 3:
			if f.typ == protowire.BytesType {
				op, err := UnmarshalSNSObjectOp(f.bytes)
				if err != nil {
					return fmt.Errorf("sns proto: SnsObjectOpRequest.OpList: %w", err)
				}
				req.Ops = append(req.Ops, *op)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return req, nil
}

// SNSObjectOpResponse 对应 {1:BaseResponse,2:OpCount,3:OpRetList[]}。
type SNSObjectOpResponse struct {
	Base      SNSBaseResponse
	OpRetList []int32
}

func UnmarshalSNSObjectOpResponse(data []byte) (*SNSObjectOpResponse, error) {
	resp := &SNSObjectOpResponse{}
	err := snsWalk(data, func(f snsWireField) error {
		switch f.num {
		case 1:
			if f.typ == protowire.BytesType {
				base, err := unmarshalSNSBaseResponse(f.bytes)
				if err != nil {
					return fmt.Errorf("sns proto: ObjectOpResponse.BaseResponse: %w", err)
				}
				resp.Base = base
			}
		case 3:
			if f.typ == protowire.VarintType {
				resp.OpRetList = append(resp.OpRetList, int32(f.varint))
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return resp, nil
}

func MarshalSNSObjectOpResponse(resp SNSObjectOpResponse) []byte {
	var out []byte
	out = snsAppendBytesField(out, 1, MarshalSNSBaseResponse(resp.Base))
	out = snsAppendVarintField(out, 2, uint64(len(resp.OpRetList)))
	for _, ret := range resp.OpRetList {
		out = snsAppendVarintField(out, 3, uint64(uint32(ret)))
	}
	return out
}

// ---- SnsSync --------------------------------------------------------------

// SNSSyncKeyItem 是 SyncKey 的一项；KeyBuf 内层就是 SnsSyncKey。
type SNSSyncKeyItem struct {
	KeyID uint32
	Value uint32
}

type SNSSyncKey struct {
	Items []SNSSyncKeyItem
}

func MarshalSNSSyncKey(key SNSSyncKey) []byte {
	var out []byte
	out = snsAppendVarintField(out, 1, uint64(len(key.Items)))
	for _, it := range key.Items {
		var ib []byte
		ib = snsAppendVarintField(ib, 1, uint64(it.KeyID))
		ib = snsAppendVarintField(ib, 2, uint64(it.Value))
		out = snsAppendBytesField(out, 2, ib)
	}
	return out
}

func UnmarshalSNSSyncKey(data []byte) (*SNSSyncKey, error) {
	key := &SNSSyncKey{}
	err := snsWalk(data, func(f snsWireField) error {
		switch f.num {
		case 2:
			if f.typ == protowire.BytesType {
				var it SNSSyncKeyItem
				err := snsWalk(f.bytes, func(inf snsWireField) error {
					switch inf.num {
					case 1:
						if inf.typ == protowire.VarintType {
							it.KeyID = uint32(inf.varint)
						}
					case 2:
						if inf.typ == protowire.VarintType {
							it.Value = uint32(inf.varint)
						}
					}
					return nil
				})
				if err != nil {
					return fmt.Errorf("sns proto: SnsSyncKey.Item: %w", err)
				}
				key.Items = append(key.Items, it)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return key, nil
}

// SNSSyncRequest 对应 {2:Selector,3:KeyBuf}，无 BaseRequest。
type SNSSyncRequest struct {
	Selector uint32
	KeyBuf   []byte
}

func MarshalSNSSyncRequest(req SNSSyncRequest) []byte {
	var out []byte
	out = snsAppendVarintField(out, 2, uint64(req.Selector))
	out = snsAppendBytesField(out, 3, MarshalSKBuiltinBuffer(req.KeyBuf))
	return out
}

func UnmarshalSNSSyncRequest(data []byte) (*SNSSyncRequest, error) {
	req := &SNSSyncRequest{}
	err := snsWalk(data, func(f snsWireField) error {
		switch f.num {
		case 2:
			if f.typ == protowire.VarintType {
				req.Selector = uint32(f.varint)
			}
		case 3:
			if f.typ == protowire.BytesType {
				req.KeyBuf = append([]byte(nil), snsUnwrapBuffer(f.bytes)...)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return req, nil
}

// snsPatchSyncRequestKeyBuf 保留捕获的 sync 请求体里的未知字段，只替换 KeyBuf（field 3）。
// 4.2.0.17 的真实 mmsnssync 请求含大量 App 侧字段；直接用最小 marshal 会丢字段，
// 整包重放又会用旧游标，因此按「拷贝其他字段 + 换 KeyBuf」处理。
func snsPatchSyncRequestKeyBuf(captured, keyBuf []byte) ([]byte, error) {
	out := make([]byte, 0, len(captured)+len(keyBuf)+8)
	data := captured
	for len(data) > 0 {
		num, typ, n := protowire.ConsumeTag(data)
		if n < 0 {
			return nil, fmt.Errorf("sns proto: sync 请求 tag 截断: %w", protowire.ParseError(n))
		}
		data = data[n:]
		var raw []byte
		switch typ {
		case protowire.VarintType:
			_, m := protowire.ConsumeVarint(data)
			if m < 0 {
				return nil, fmt.Errorf("sns proto: sync 请求字段 %d varint 截断", num)
			}
			raw = data[:m]
		case protowire.BytesType:
			_, m := protowire.ConsumeBytes(data)
			if m < 0 {
				return nil, fmt.Errorf("sns proto: sync 请求字段 %d bytes 截断", num)
			}
			raw = data[:m]
		case protowire.Fixed32Type:
			_, m := protowire.ConsumeFixed32(data)
			if m < 0 {
				return nil, fmt.Errorf("sns proto: sync 请求字段 %d fixed32 截断", num)
			}
			raw = data[:m]
		case protowire.Fixed64Type:
			_, m := protowire.ConsumeFixed64(data)
			if m < 0 {
				return nil, fmt.Errorf("sns proto: sync 请求字段 %d fixed64 截断", num)
			}
			raw = data[:m]
		default:
			return nil, fmt.Errorf("sns proto: sync 请求含不支持的 wire type %d", typ)
		}
		data = data[len(raw):]
		if num == 3 && typ == protowire.BytesType {
			continue // KeyBuf 稍后替换
		}
		out = protowire.AppendTag(out, num, typ)
		out = append(out, raw...)
	}
	out = protowire.AppendTag(out, 3, protowire.BytesType)
	out = protowire.AppendBytes(out, MarshalSKBuiltinBuffer(keyBuf))
	return out, nil
}

// SNSCmdItem / SNSCmdList 对应 CmdList{1:Count,2:List[]CmdItem{1:CmdId,2:CmdBuf}}。
type SNSCmdItem struct {
	CmdID  int32
	CmdBuf []byte
}

type SNSCmdList struct {
	Items []SNSCmdItem
}

func UnmarshalSNSCmdList(data []byte) (*SNSCmdList, error) {
	list := &SNSCmdList{}
	err := snsWalk(data, func(f snsWireField) error {
		if f.num == 2 && f.typ == protowire.BytesType {
			var item SNSCmdItem
			err := snsWalk(f.bytes, func(inf snsWireField) error {
				switch inf.num {
				case 1:
					if inf.typ == protowire.VarintType {
						item.CmdID = int32(inf.varint)
					}
				case 2:
					if inf.typ == protowire.BytesType {
						item.CmdBuf = append([]byte(nil), inf.bytes...)
					}
				}
				return nil
			})
			if err != nil {
				return fmt.Errorf("sns proto: CmdList.Item: %w", err)
			}
			list.Items = append(list.Items, item)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return list, nil
}

func MarshalSNSCmdList(list SNSCmdList) []byte {
	var out []byte
	out = snsAppendVarintField(out, 1, uint64(len(list.Items)))
	for _, it := range list.Items {
		var ib []byte
		ib = snsAppendVarintField(ib, 1, uint64(uint32(it.CmdID)))
		ib = snsAppendBytesField(ib, 2, it.CmdBuf)
		out = snsAppendBytesField(out, 2, ib)
	}
	return out
}

// SNSSyncResponse 对应 {1:BaseResponse,2:CmdList,3:ContinueFlag,4:KeyBuf}。
type SNSSyncResponse struct {
	Base         SNSBaseResponse
	CmdList      SNSCmdList
	ContinueFlag uint32
	KeyBuf       []byte
}

func UnmarshalSNSSyncResponse(data []byte) (*SNSSyncResponse, error) {
	resp := &SNSSyncResponse{}
	err := snsWalk(data, func(f snsWireField) error {
		switch f.num {
		case 1:
			if f.typ == protowire.BytesType {
				base, err := unmarshalSNSBaseResponse(f.bytes)
				if err != nil {
					return fmt.Errorf("sns proto: SyncResponse.BaseResponse: %w", err)
				}
				resp.Base = base
			}
		case 2:
			if f.typ == protowire.BytesType {
				list, err := UnmarshalSNSCmdList(f.bytes)
				if err != nil {
					return fmt.Errorf("sns proto: SyncResponse.CmdList: %w", err)
				}
				resp.CmdList = *list
			}
		case 3:
			if f.typ == protowire.VarintType {
				resp.ContinueFlag = uint32(f.varint)
			}
		case 4:
			if f.typ == protowire.BytesType {
				resp.KeyBuf = append([]byte(nil), snsUnwrapBuffer(f.bytes)...)
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return resp, nil
}

func MarshalSNSSyncResponse(resp SNSSyncResponse) []byte {
	var out []byte
	out = snsAppendBytesField(out, 1, MarshalSNSBaseResponse(resp.Base))
	if len(resp.CmdList.Items) > 0 {
		out = snsAppendBytesField(out, 2, MarshalSNSCmdList(resp.CmdList))
	}
	if resp.ContinueFlag != 0 {
		out = snsAppendVarintField(out, 3, uint64(resp.ContinueFlag))
	}
	if resp.KeyBuf != nil {
		out = snsAppendBytesField(out, 4, MarshalSKBuiltinBuffer(resp.KeyBuf))
	}
	return out
}

// ---- <TimelineObject> XML -------------------------------------------------

// SNSTimelineObject 是朋友圈正文/媒体对象。ObjectDesc 字段即该 XML。
type SNSTimelineObject struct {
	XMLName                    xml.Name          `xml:"TimelineObject"`
	ID                         string            `xml:"id"`
	Username                   string            `xml:"username"`
	CreateTime                 string            `xml:"createTime"`
	ContentDescShowType        string            `xml:"contentDescShowType"`
	ContentDescScene           string            `xml:"contentDescScene"`
	Private                    string            `xml:"private"`
	ContentDesc                string            `xml:"contentDesc"`
	SourceUserName             string            `xml:"sourceUserName"`
	SourceNickName             string            `xml:"sourceNickName"`
	PublicPhotoAccountUserName string            `xml:"publicPhotoAccountUserName"`
	PublicPhotoAccountNickName string            `xml:"publicPhotoAccountNickName"`
	SightFolded                string            `xml:"sightFolded"`
	ShowFlag                   string            `xml:"showFlag"`
	ContentObject              *SNSContentObject `xml:"ContentObject"`
}

type SNSContentObject struct {
	ContentStyle    string        `xml:"contentStyle"`
	ContentSubStyle string        `xml:"contentSubStyle"`
	Title           string        `xml:"title"`
	Description     string        `xml:"description"`
	ContentURL      string        `xml:"contentUrl"`
	MediaList       *SNSMediaList `xml:"mediaList"`
}

type SNSMediaList struct {
	Media []SNSMedia `xml:"media"`
}

// SNSMediaURL 是 <url>/<thumb> 元素：mac 4.2 把 key/token/enc_idx 放在属性上，
// 正文是 CDN 地址。token/key 只在 bridge 内存里用于下载，不写日志/文档。
type SNSMediaURL struct {
	Type   string `xml:"type,attr"`
	MD5    string `xml:"md5,attr"`
	Key    string `xml:"key,attr"`
	Token  string `xml:"token,attr"`
	EncIdx string `xml:"enc_idx,attr"`
	Value  string `xml:",chardata"`
}

type SNSMedia struct {
	ID          string      `xml:"id"`
	Type        string      `xml:"type"`
	Title       string      `xml:"title"`
	Description string      `xml:"description"`
	Private     string      `xml:"private"`
	URL         SNSMediaURL `xml:"url"`
	Thumb       SNSMediaURL `xml:"thumb"`
	// 兼容旧版/其他平台：key/token 也可能是 <media> 子元素。
	Key   string       `xml:"key"`
	Token string       `xml:"token"`
	Size  SNSMediaSize `xml:"size"`
}

type SNSMediaSize struct {
	TotalSize float64 `xml:"totalSize,attr"`
	Width     float64 `xml:"width,attr"`
	Height    float64 `xml:"height,attr"`
}

// ParseSNSTimelineObject 解析 ObjectDesc；解析失败时返回 error，调用方应降级
// 为「无正文/无媒体」而不是让整个时间线请求失败。
func ParseSNSTimelineObject(data []byte) (*SNSTimelineObject, error) {
	if len(data) == 0 {
		return nil, errors.New("sns proto: ObjectDesc 为空")
	}
	var obj SNSTimelineObject
	if err := xml.Unmarshal(data, &obj); err != nil {
		return nil, fmt.Errorf("sns proto: ObjectDesc XML 解析失败: %w", err)
	}
	return &obj, nil
}

// BuildSNSTimelineObjectText 构造纯文字朋友圈的 <TimelineObject> XML。
// contentStyle=2 表示纯文字；私密/公开由 private 字段与 SnsPostRequest.Privacy
// 共同决定（P3，写通道未就绪前只用于测试）。
func BuildSNSTimelineObjectText(selfWxid, text string, createTime int64, private uint32) ([]byte, error) {
	obj := SNSTimelineObject{
		ID:          "0",
		Username:    selfWxid,
		CreateTime:  strconv.FormatInt(createTime, 10),
		Private:     strconv.FormatUint(uint64(private), 10),
		ContentDesc: text,
		ContentObject: &SNSContentObject{
			ContentStyle: "2",
		},
	}
	data, err := xml.Marshal(obj)
	if err != nil {
		return nil, fmt.Errorf("sns proto: 构造 TimelineObject 失败: %w", err)
	}
	return data, nil
}

// SNSMediaKind 把 XML 的 media type 映射为 App 契约的 kind。
// SnsMediaType: 1=TEXT, 2=PHOTO, 3=VOICE, 4=VIDEO, 5=MUSIC, 6=SIGHT。
func SNSMediaKind(typeStr string) string {
	switch strings.TrimSpace(typeStr) {
	case "2":
		return "image"
	case "4", "6":
		return "video"
	default:
		return "unknown"
	}
}

// SNSMediaDimensions 把 XML 的 size 属性（"1080.0"）转成整数宽高。
func SNSMediaDimensions(size SNSMediaSize) (int, int) {
	return int(size.Width + 0.5), int(size.Height + 0.5)
}

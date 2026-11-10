package main

// 朋友圈（SNS）HTTP 层：/sns/status|timeline|detail|media|sync|post|comment|like|objectop。
//
// 契约见 docs/sns.md §4：
//   - 全部 POST + `Authorization: Bearer <token>`；
//   - 成功 {"status":"ok","data":{...}}，失败 {"status":"failed","code":"...","error":"..."}；
//   - 未启用 404，未授权 401，微信未就绪 503，超时 504，回包/服务端拒绝 502；
//   - 写接口默认关闭（404），需要版本 JSON 的 snsWrite=true 且 App 二次确认；
//   - 媒体接口在 hook snsMedia 未实现前返回 503，不让 App 猜测成功。
//
// 隐私：日志只记条数/长度/错误码与耗时；不打印正文、wxid、CDN key 或 protobuf hex。

import (
	"context"
	"crypto/hmac"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"google.golang.org/protobuf/encoding/protowire"
)

const (
	snsMaxBodyBytes     = 1 << 20 // 请求体上限 1MiB（时间线请求很小）
	snsMediaCallTimeout = 20 * time.Second
	snsStatusTimeout    = 3 * time.Second
	snsTextRuneLimit    = 2000 // 正文超过 2000 字符截断（docs/sns.md §4.2）
	snsCommentRuneLimit = 1000
	snsPostRuneLimit    = 1500
)

// registerSNSHandlers 在 main.go 启动时注册全部 SNS 路由。
// 是否启用由 handler 内检查开关决定（未启用 404），便于 App 运行期切开关。
func registerSNSHandlers() {
	http.HandleFunc("/sns/status", snsStatusHandler)
	http.HandleFunc("/sns/timeline", snsTimelineHandler)
	http.HandleFunc("/sns/detail", snsDetailHandler)
	http.HandleFunc("/sns/media", snsMediaHandler)
	http.HandleFunc("/sns/sync", snsSyncHandler)
	http.HandleFunc("/sns/post", snsPostHandler)
	http.HandleFunc("/sns/comment", snsCommentHandler)
	http.HandleFunc("/sns/like", snsLikeHandler)
	http.HandleFunc("/sns/objectop", snsObjectOpHandler)
	// P0 探针：sns.db 只读解密后的表结构（默认关闭，见 snsDbSchemaHandler）。
	http.HandleFunc("/sns/db/schema", snsDbSchemaHandler)
	http.HandleFunc("/sns/db/comments", snsDbCommentsHandler)
}

// ---- 鉴权 / 响应 ----------------------------------------------------------

// snsAuthorized 复用 OneBot 的 Bearer token 校验（常量时间比较）。
func snsAuthorized(r *http.Request) bool {
	want := config.OnebotToken
	if want == "" {
		return false
	}
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if token == "" || token == r.Header.Get("Authorization") {
		return false
	}
	return hmac.Equal([]byte(token), []byte(want))
}

func writeSNSJSON(w http.ResponseWriter, status int, payload map[string]any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func snsWriteOK(w http.ResponseWriter, data any) {
	writeSNSJSON(w, http.StatusOK, map[string]any{"status": "ok", "data": data})
}

func snsWriteError(w http.ResponseWriter, err error) {
	se := snsHTTPError(err)
	// 只记录错误码/状态/ret；不记录回包内容。
	Warn("SNS 请求失败", "code", se.Code, "status", se.Status, "hook_reason", se.HookReason)
	payload := map[string]any{
		"status": "failed",
		"code":   se.Code,
		"error":  se.Message,
	}
	if se.Ret != 0 {
		payload["ret"] = se.Ret
	}
	if se.RetryAfterSeconds > 0 {
		payload["retry_after_seconds"] = se.RetryAfterSeconds
	}
	writeSNSJSON(w, se.Status, payload)
}

// snsPrepare 统一处理：POST 校验 → Bearer 鉴权 → SNS 总开关 → 写开关。
// 返回 false 时已写出错误响应。
func snsPrepare(w http.ResponseWriter, r *http.Request, write bool) bool {
	if r.Method != http.MethodPost {
		snsWriteError(w, newSNSError(http.StatusMethodNotAllowed, "sns_method_not_allowed", "仅支持 POST"))
		return false
	}
	if !snsAuthorized(r) {
		snsWriteError(w, newSNSError(http.StatusUnauthorized, "sns_unauthorized", "未授权"))
		return false
	}
	if !snsReadEnabled() {
		snsWriteError(w, newSNSError(http.StatusNotFound, "sns_disabled", "朋友圈功能未启用"))
		return false
	}
	// bridge 重启后尝试恢复上一次的 service/closure/body 样本（同一微信进程内有效）。
	snsRestoreCaptureState()
	if write && !snsWriteEnabled() {
		// docs/sns.md §4.6：写开关未开 → 404（App 侧不会显示入口）。
		snsWriteError(w, newSNSError(http.StatusNotFound, "sns_write_disabled", "朋友圈写操作未开启"))
		return false
	}
	return true
}

func snsDecodeJSONBody(w http.ResponseWriter, r *http.Request, dst any) bool {
	body := http.MaxBytesReader(w, r.Body, snsMaxBodyBytes)
	defer body.Close()
	dec := json.NewDecoder(body)
	if err := dec.Decode(dst); err != nil {
		if errors.Is(err, io.EOF) {
			snsWriteError(w, newSNSError(http.StatusBadRequest, "sns_invalid_request", "请求体不能为空"))
			return false
		}
		snsWriteError(w, newSNSError(http.StatusBadRequest, "sns_invalid_request", "请求 JSON 无效"))
		return false
	}
	return true
}

// snsConfirmError 处理可选 confirm 字段：仅当 App 显式传 false 时返回
// 403（写操作的二次确认）。未传时信任 App 侧确认弹窗（docs/sns.md §4.6/4.7）。
func snsConfirmError(confirm *bool) *snsError {
	if confirm != nil && !*confirm {
		return newSNSError(http.StatusForbidden, "sns_not_confirmed", "写操作需要二次确认")
	}
	return nil
}

func snsReadCtx(r *http.Request, op string) (context.Context, context.CancelFunc) {
	return context.WithTimeout(r.Context(), snsTimeoutFor(op))
}

func snsCheckBaseRet(base SNSBaseResponse) error {
	if base.Ret == 0 {
		return nil
	}
	e := newSNSError(http.StatusBadGateway, "sns_native_rejected",
		fmt.Sprintf("微信接口返回错误码 %d", base.Ret))
	e.Ret = base.Ret
	return e
}

// ---- JSON 归一化 ----------------------------------------------------------

type snsMediaJSON struct {
	Kind     string `json:"kind"`
	ThumbKey string `json:"thumb_key"`
	URLKey   string `json:"url_key"`
	Width    int    `json:"width"`
	Height   int    `json:"height"`
}

type snsCommentJSON struct {
	CommentID  string `json:"comment_id"`
	UserID     string `json:"user_id"`
	UserName   string `json:"user_name"`
	Text       string `json:"text"`
	CreateTime int64  `json:"create_time"`
	ReplyTo    string `json:"reply_to"`
	// ReplyToUserID 是被回复者的用户 ID（可能是 wxid）。timeline 用
	// SnsCommentInfo.ReplyUsername；sync 用 SnsAction.ToUsername。用于判断
	// 「好友回复了我的评论」，不依赖被回复评论是否出现在评论列表里。
	ReplyToUserID string `json:"reply_to_user_id,omitempty"`
	ReplyToName   string `json:"reply_to_name,omitempty"`
	// CommentIDUnconfirmed=true 表示 CommentID 来自 32 位本地/父评论列
	// （SnsMessage_tmp3.comment_id，语义未确认）。App 仍展示该评论，但不能把它
	// 当 /sns/comment 的 reply_comment_id；comment64_id 有效时不会带该标记。
	CommentIDUnconfirmed bool `json:"comment_id_unconfirmed,omitempty"`
	// CommentIDConfirmed=true 表示 comment_id 已通过真机「手动回复」抓包确认
	// 可作为 reply_comment_id（4.2.0.17 SnsMessage_tmp3.comment_id 实测：
	// 手动回复 A 的 reply 时请求 ReplyCommentID=35，服务端接受并生成新评论）。
	// App 可在确认后允许自动/手动回复；未确认时仍展示但不回复。
	CommentIDConfirmed bool `json:"comment_id_confirmed,omitempty"`
	// Source="db" 是同一含义的显式来源标记（App 兼容 comment_id_unconfirmed
	// 或 source 任一）；原生 timeline/同步评论不带。
	Source string `json:"source,omitempty"`
}

type snsLikeJSON struct {
	UserID     string `json:"user_id"`
	UserName   string `json:"user_name"`
	CreateTime int64  `json:"create_time"`
}

type snsPostJSON struct {
	ID                string           `json:"id"`
	AuthorID          string           `json:"author_id"`
	AuthorName        string           `json:"author_name"`
	CreateTime        int64            `json:"create_time"`
	Text              string           `json:"text"`
	TextTruncated     bool             `json:"text_truncated,omitempty"`
	Media             []snsMediaJSON   `json:"media"`
	LikeCount         uint32           `json:"like_count"`
	CommentCount      uint32           `json:"comment_count"`
	Liked             bool             `json:"liked"`
	Comments          []snsCommentJSON `json:"comments"`
	CommentsTruncated bool             `json:"comments_truncated,omitempty"`
	Likes             []snsLikeJSON    `json:"likes,omitempty"`
}

type snsCursorJSON struct {
	MaxID        string `json:"max_id"`
	FirstPageMD5 string `json:"first_page_md5"`
	Session      string `json:"session"`
	HasMore      bool   `json:"has_more"`
}

type snsServerConfigJSON struct {
	PostMentionLimit      int32 `json:"post_mention_limit"`
	CopyAndPasteWordLimit int32 `json:"copy_paste_word_limit"`
}

type snsTimelineData struct {
	Posts        []snsPostJSON       `json:"posts"`
	Cursor       snsCursorJSON       `json:"cursor"`
	ServerConfig snsServerConfigJSON `json:"server_config"`
	// Source: native（主动请求）/ passive（用户原生刷新的缓存兜底）。
	Source string `json:"source,omitempty"`
	// CapturedAt 为被动缓存的捕获时间（Unix 秒）；native 请求为 0/缺省。
	CapturedAt int64 `json:"captured_at,omitempty"`
}

// snsNormalizePost 把 SnsObject/XML 归一化为 App 契约 JSON。
// 解析失败时降级为「无正文/无媒体」，不返回猜测数据。
func snsNormalizePost(obj *SNSObject, includeLikes bool) snsPostJSON {
	post := snsPostJSON{
		ID:           strconv.FormatUint(obj.ID, 10),
		AuthorID:     obj.Username,
		AuthorName:   obj.Nickname,
		CreateTime:   int64(obj.CreateTime),
		Media:        make([]snsMediaJSON, 0, 4),
		LikeCount:    obj.LikeCount,
		CommentCount: obj.CommentCount,
		Liked:        obj.LikeFlag != 0,
		Comments:     make([]snsCommentJSON, 0, len(obj.CommentUserList)),
	}
	if post.AuthorName == "" && obj.Username != "" {
		post.AuthorName = contactDisplayName(obj.Username)
	}

	// ObjectDesc 正常是 <TimelineObject> XML；个别版本/空对象可能是裸文本。
	var xmlObj *SNSTimelineObject
	if len(obj.ObjectDesc) > 0 {
		if parsed, err := ParseSNSTimelineObject(obj.ObjectDesc); err == nil {
			xmlObj = parsed
		} else {
			Debug("SNS ObjectDesc XML 解析失败", "len", len(obj.ObjectDesc))
			if !strings.HasPrefix(strings.TrimSpace(string(obj.ObjectDesc)), "<") {
				post.Text = string(obj.ObjectDesc)
			}
		}
	}
	if xmlObj != nil {
		// 记录原始 media 元数据（url/key/token），/sns/media 下载需要；
		// 时间线/详情/发布回包都会经过这里。
		snsRememberRawMedia(post.ID, xmlObj)
		post.Text = xmlObj.ContentDesc
		if post.CreateTime == 0 {
			if ts, err := strconv.ParseInt(strings.TrimSpace(xmlObj.CreateTime), 10, 64); err == nil {
				post.CreateTime = ts
			}
		}
		if xmlObj.ContentObject != nil && xmlObj.ContentObject.MediaList != nil {
			for _, m := range xmlObj.ContentObject.MediaList.Media {
				if m.Type == "" {
					continue
				}
				w, h := SNSMediaDimensions(m.Size)
				post.Media = append(post.Media, snsMediaJSON{
					Kind:     SNSMediaKind(m.Type),
					ThumbKey: m.Thumb.Value,
					URLKey:   m.URL.Value,
					Width:    w,
					Height:   h,
				})
			}
		}
	}
	if truncated, was := snsTruncateRunes(post.Text, snsTextRuneLimit); was {
		post.Text = truncated
		post.TextTruncated = true
	}

	for i := range obj.CommentUserList {
		c := obj.CommentUserList[i]
		if c.DeleteFlag != 0 || c.Type == 1 {
			continue
		}
		post.Comments = append(post.Comments, snsCommentFromInfo(c))
	}
	// 回复评论的展示名：优先用回包里的 ReplyUsername（可能是 wxid，查通讯录换成昵称），
	// 查不到时再用同一动态里被回复评论的作者名兜底（评论区通常按时间顺序返回）。
	commentNames := make(map[string]string, len(post.Comments))
	for i := range post.Comments {
		c := &post.Comments[i]
		if c.CommentID != "" && c.UserName != "" {
			commentNames[c.CommentID] = c.UserName
		}
	}
	for i := range post.Comments {
		c := &post.Comments[i]
		if c.ReplyTo != "" && c.ReplyToName == "" {
			c.ReplyToName = commentNames[c.ReplyTo]
		}
	}
	if includeLikes {
		post.Likes = make([]snsLikeJSON, 0, len(obj.LikeUserList))
		seen := make(map[string]struct{}, len(obj.LikeUserList))
		for i := range obj.LikeUserList {
			like := obj.LikeUserList[i]
			if like.DeleteFlag != 0 || like.Username == "" {
				continue
			}
			if _, dup := seen[like.Username]; dup {
				continue
			}
			seen[like.Username] = struct{}{}
			name := like.Nickname
			if name == "" {
				name = contactDisplayName(like.Username)
			}
			post.Likes = append(post.Likes, snsLikeJSON{
				UserID:     like.Username,
				UserName:   name,
				CreateTime: int64(like.CreateTime),
			})
		}
	}
	if post.CommentCount == 0 && len(post.Comments) > 0 {
		post.CommentCount = uint32(len(post.Comments))
	}
	if post.CommentCount > uint32(len(post.Comments)) {
		post.CommentsTruncated = true
	}
	return post
}

func snsCommentFromInfo(c SNSCommentInfo) snsCommentJSON {
	commentID := ""
	if c.CommentID2 != 0 {
		commentID = strconv.FormatUint(c.CommentID2, 10)
	} else if c.CommentID != 0 {
		commentID = strconv.FormatUint(uint64(uint32(c.CommentID)), 10)
	}
	replyTo := ""
	if c.ReplyCommentID2 != 0 {
		replyTo = strconv.FormatUint(c.ReplyCommentID2, 10)
	} else if c.ReplyCommentID != 0 {
		replyTo = strconv.FormatUint(uint64(uint32(c.ReplyCommentID)), 10)
	}
	name := c.Nickname
	if name == "" && c.Username != "" {
		name = contactDisplayName(c.Username)
	}
	// ReplyUsername 在不同版本里可能是 wxid 或昵称：先按 wxid 查通讯录，
	// 查不到且不像 wxid 时按昵称原样返回；仍为空则由调用方用评论列表兜底。
	replyName := ""
	if c.ReplyUsername != "" {
		replyName = contactDisplayName(c.ReplyUsername)
		if replyName == "" && !strings.HasPrefix(c.ReplyUsername, "wxid_") {
			replyName = c.ReplyUsername
		}
	}
	return snsCommentJSON{
		CommentID:     commentID,
		UserID:        c.Username,
		UserName:      name,
		Text:          c.Content,
		CreateTime:    int64(c.CreateTime),
		ReplyTo:       replyTo,
		ReplyToUserID: c.ReplyUsername,
		ReplyToName:   replyName,
	}
}

func snsTruncateRunes(s string, limit int) (string, bool) {
	if limit <= 0 {
		return s, false
	}
	r := []rune(s)
	if len(r) <= limit {
		return s, false
	}
	return string(r[:limit]), true
}

func snsEncodeBase64(data []byte) string {
	if len(data) == 0 {
		return ""
	}
	return base64.StdEncoding.EncodeToString(data)
}

// snsDecodeOptionalBase64 兼容标准/URL-safe、带/不带 padding 的 base64。
func snsDecodeOptionalBase64(s string) ([]byte, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil, nil
	}
	encodings := []*base64.Encoding{
		base64.StdEncoding,
		base64.RawStdEncoding,
		base64.URLEncoding,
		base64.RawURLEncoding,
	}
	for _, enc := range encodings {
		if data, err := enc.DecodeString(s); err == nil {
			return data, nil
		}
	}
	return nil, errors.New("session 不是合法 base64")
}

// ---- GET /sns/status ------------------------------------------------------

func snsStatusHandler(w http.ResponseWriter, r *http.Request) {
	if !snsPrepare(w, r, false) {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), snsStatusTimeout)
	defer cancel()

	data := map[string]any{
		"ready":      false,
		"seed_ready": false,
		// write_ready 只代表发布句柄（post 样本），不代表写开关；hook 未就绪时
		// 按「未知/未就绪」返回 false，避免 App 误显示「写通道已就绪」。
		"write_ready":   false,
		"comment_ready": false,
		// body_captured 只代表 timeline 的真实请求体是否已捕获（主动刷新的前提）。
		// captured 只统计任务类型数，缺 bodyReturn 锚点的版本会出现 captured>0 但
		// body_captured=false；App 用后者决定是否显示「原生通道」。
		"body_captured": false,
		"enabled":       true,
		"write_enabled": snsWriteEnabled(),
		// passive=true：hook 已缓存最近一次手动打开朋友圈的真实响应，可直接读取。
		"passive": len(snsPassiveResponse("timeline", 10*time.Minute)) > 0,
		// read_mode=native：主动刷新可用（复用捕获请求体）；passive：只读原生缓存。
		"read_mode": snsReadModeLabel(),
	}
	if myWechatId != "" {
		data["account"] = myWechatId
	}

	st, err := currentSNSRPC().Status(ctx)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
			snsWriteError(w, err)
			return
		}
		// status 本身是就绪探测：hook 未实现/未就绪时返回 200 + ready=false，
		// 让 App 展示引导，而不是把状态查询变成错误弹窗。
		se := snsHTTPError(err)
		data["last_error"] = se.Code
		snsWriteOK(w, data)
		return
	}
	data["ready"] = st.Ready
	data["seed_ready"] = st.SeedReady
	data["write_ready"] = st.WriteReady
	data["comment_ready"] = st.CommentReady
	data["body_captured"] = st.TimelineBodyReady
	data["captured"] = st.Captured
	if st.LastError != "" {
		data["last_error"] = st.LastError
	}
	// 捕获到新的 SNS 样本时落到账号目录，供 bridge 重启后恢复（按最小间隔节流，
	// 避免「捕获发送句柄」弹窗 1s 轮询 /sns/status 时高频导出）。
	snsPersistCaptureState(false)
	snsWriteOK(w, data)
}

// ---- POST /sns/db/schema（P0 探针，默认关闭）------------------------------
//
// 走 hook 的 sns.db 只读解密路径：解密到容器 tmp → 只查 sqlite_master /
// COUNT(*) / PRAGMA page_count → 返回脱敏 schema。仅在 snsProbe=true 或显式
// snsDbRead=true 时可用，Bearer 鉴权与其它 /sns/* 一致。
// 响应绝不包含 DB key：hook 回传的 keys 只用于 bridge 落盘（0600 缓存）后剥离。
type snsDBTable struct {
	Name string `json:"name"`
	SQL  string `json:"sql"`
	Rows int    `json:"rows"`
}

type snsDBSchemaResult struct {
	OK          bool                  `json:"ok"`
	Reason      string                `json:"reason,omitempty"`
	Message     string                `json:"message,omitempty"`
	GeneratedAt int64                 `json:"generated_at,omitempty"`
	KeySource   string                `json:"key_source,omitempty"`
	DecryptMS   int64                 `json:"decrypt_ms,omitempty"`
	QueryMS     int64                 `json:"query_ms,omitempty"`
	WALApplied  int                   `json:"wal_applied,omitempty"`
	Pages       int                   `json:"pages,omitempty"`
	PageCount   int                   `json:"page_count,omitempty"`
	Tables      []snsDBTable          `json:"tables,omitempty"`
	KeyStatus   map[string]any        `json:"key_status,omitempty"`
	Keys        map[string]ContactKey `json:"keys,omitempty"`
}

func snsDbSchemaEnabled() bool {
	return snsProbeEnabled() || snsDbReadEnabled()
}

// snsDbPrepare 只校验 POST / Bearer / sns.db 开关；不要求 snsEnable，
// 这样原生读通道未就绪时也能做只读 schema 探针。
func snsDbPrepare(w http.ResponseWriter, r *http.Request) bool {
	if r.Method != http.MethodPost {
		snsWriteError(w, newSNSError(http.StatusMethodNotAllowed, "sns_method_not_allowed", "仅支持 POST"))
		return false
	}
	if !snsAuthorized(r) {
		snsWriteError(w, newSNSError(http.StatusUnauthorized, "sns_unauthorized", "未授权"))
		return false
	}
	if !snsDbSchemaEnabled() {
		snsWriteError(w, newSNSError(http.StatusNotFound, "sns_db_disabled",
			"sns.db 只读未启用（需要 snsProbe=true 或 snsDbRead=true）"))
		return false
	}
	return true
}

// snsDbSchemaError 把 hook 的 reason 映射成 App 可行动的 HTTP 错误码。
func snsDbSchemaError(reason string) *snsError {
	switch strings.TrimSpace(reason) {
	case "key_missing":
		// 正常路径下 bridge 会从 db-keys.json 回灌已捕获的 sns key；只有真正
		// 没有缓存（首次运行/缓存被清）时才需要用户打开一次朋友圈触发 CCCrypt。
		return newSNSError(http.StatusServiceUnavailable, "sns_db_key_missing",
			"sns.db 密钥暂不可用：请确认 bridge 能读取 db-keys.json 缓存；若缓存中没有 sns key，请在微信打开一次朋友圈触发捕获后重试")
	case "db_missing":
		return newSNSError(http.StatusServiceUnavailable, "sns_db_not_found",
			"未找到 sns.db（期望 <db_storage>/sns/sns.db）")
	case "db_too_small", "db_too_large":
		return newSNSError(http.StatusBadGateway, "sns_db_invalid_size", "sns.db 大小异常")
	case "decrypt_failed", "query_failed":
		return newSNSError(http.StatusBadGateway, "sns_db_decrypt_failed", "sns.db 解密或查询失败")
	case "unsupported":
		return newSNSError(http.StatusServiceUnavailable, "sns_db_unsupported",
			"当前 Hook 未启用 sns.db 只读（snsProbe / snsDbRead）")
	default:
		return newSNSError(http.StatusBadGateway, "sns_db_failed", "sns.db 探针失败")
	}
}

// ---- POST /sns/db/comments（P1 探针，仅 snsProbe=true）--------------------
// 调试/验证用：按 post_id 批量读 sns.db 的评论并返回 bridge 映射后的
// snsCommentJSON（不返回 key/原始行）。生产（snsProbe=false）不注册行为 404。
type snsDbCommentsRequest struct {
	PostIDs []string `json:"post_ids"`
}

func snsDbCommentsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		snsWriteError(w, newSNSError(http.StatusMethodNotAllowed, "sns_method_not_allowed", "仅支持 POST"))
		return
	}
	if !snsAuthorized(r) {
		snsWriteError(w, newSNSError(http.StatusUnauthorized, "sns_unauthorized", "未授权"))
		return
	}
	if !snsProbeEnabled() {
		snsWriteError(w, newSNSError(http.StatusNotFound, "sns_db_disabled",
			"sns.db 评论探针仅在 snsProbe=true 时可用"))
		return
	}
	var req snsDbCommentsRequest
	if !snsDecodeJSONBody(w, r, &req) {
		return
	}
	postIDs := make([]string, 0, len(req.PostIDs))
	for _, id := range req.PostIDs {
		id = strings.TrimSpace(id)
		if id == "" {
			continue
		}
		if _, err := parseSNSID(id); err != nil {
			snsWriteError(w, newSNSError(http.StatusBadRequest, "sns_invalid_request", "post_id 不是合法的 uint64 十进制字符串"))
			return
		}
		postIDs = append(postIDs, id)
		if len(postIDs) >= snsDbCommentsMaxFeedIDs {
			break
		}
	}
	if len(postIDs) == 0 {
		snsWriteError(w, newSNSError(http.StatusBadRequest, "sns_invalid_request", "post_ids 不能为空"))
		return
	}
	started := time.Now()
	commentsByPost, rowCount, err := fetchSNSDbComments(postIDs)
	if err != nil {
		code := "sns_db_unavailable"
		status := http.StatusServiceUnavailable
		if strings.Contains(err.Error(), "key_missing") {
			code = "sns_db_key_missing"
		}
		Debug("SNS DB 评论探针失败", "reason", err.Error())
		snsWriteError(w, newSNSError(status, code, "sns.db 评论探针失败"))
		return
	}
	if commentsByPost == nil {
		commentsByPost = map[string][]snsCommentJSON{}
	}
	Info("SNS DB 评论探针完成", "posts", len(postIDs), "rows", rowCount,
		"elapsed_ms", time.Since(started).Milliseconds())
	snsWriteOK(w, map[string]any{
		"rows":     rowCount,
		"comments": commentsByPost,
	})
}

func snsDbSchemaHandler(w http.ResponseWriter, r *http.Request) {
	if !snsDbPrepare(w, r) {
		return
	}
	dbStoragePath := deriveDBStoragePath(config.ImagePath)
	if dbStoragePath == "" {
		snsWriteError(w, newSNSError(http.StatusServiceUnavailable, "sns_db_path_unknown",
			"无法从 image_path 推导 db_storage 目录"))
		return
	}
	started := time.Now()
	raw, err := callFridaExport("snsDbSchema", dbStoragePath)
	if err != nil {
		Warn("SNS DB schema 探针调用失败", "err", err)
		snsWriteError(w, newSNSError(http.StatusServiceUnavailable, "sns_db_unavailable",
			"sns.db 探针不可用（Hook 未就绪或超时）"))
		return
	}
	text, err := contactRPCResultString(raw)
	if err != nil {
		snsWriteError(w, newSNSError(http.StatusBadGateway, "sns_db_parse_failed", "sns.db 探针回包无效"))
		return
	}
	var res snsDBSchemaResult
	if err := json.Unmarshal([]byte(text), &res); err != nil {
		Warn("SNS DB schema 探针回包解析失败", "err", err)
		snsWriteError(w, newSNSError(http.StatusBadGateway, "sns_db_parse_failed", "sns.db 探针回包解析失败"))
		return
	}
	if len(res.Keys) > 0 {
		if err := persistContactDBKeysMerged(res.Keys); err != nil {
			Warn("SNS DB key 缓存写入失败", "err", err)
		} else {
			Info("SNS DB key 已缓存", "dbs", len(res.Keys))
		}
		res.Keys = nil // 绝不下发 App
	}
	if !res.OK {
		se := snsDbSchemaError(res.Reason)
		payload := map[string]any{
			"status": "failed",
			"code":   se.Code,
			"error":  se.Message,
		}
		if res.KeyStatus != nil {
			payload["key_status"] = res.KeyStatus
		}
		Warn("SNS DB schema 探针失败", "reason", res.Reason, "elapsed_ms", time.Since(started).Milliseconds())
		writeSNSJSON(w, se.Status, payload)
		return
	}
	Info("SNS DB schema 探针完成", "tables", len(res.Tables), "key_source", res.KeySource,
		"decrypt_ms", res.DecryptMS, "wal_applied", res.WALApplied,
		"elapsed_ms", time.Since(started).Milliseconds())
	snsWriteOK(w, res)
}

// ---- POST /sns/timeline ---------------------------------------------------

type snsTimelineRequestJSON struct {
	MaxID        string `json:"max_id"`
	FirstPageMD5 string `json:"first_page_md5"`
	Session      string `json:"session"`
	Refresh      bool   `json:"refresh"`
	Limit        int    `json:"limit"`
	// BodyHex 仅 snsProbe=true 时生效：直接使用抓包业务 body（调试/对照），
	// 不走 MarshalSNSTimeLineRequest；默认关闭，生产请求不会带。
	BodyHex string `json:"body_hex,omitempty"`
}

// snsPassiveCapture 读取 hook 最近一次「原生刷新」捕获的响应与捕获时间。
// 只在数据新鲜（≤maxAge）时返回 ok；供时间线/同步把「缓存于何时」透出给 App。
func snsPassiveCapture(op string, maxAge time.Duration) (body []byte, capturedAt time.Time, ok bool) {
	if !snsReadEnabled() {
		return nil, time.Time{}, false
	}
	raw, err := snsCallFrida("snsLastResponse", op)
	if err != nil {
		return nil, time.Time{}, false
	}
	var payload struct {
		OK  bool   `json:"ok"`
		Hex string `json:"hex"`
		TS  int64  `json:"ts"`
	}
	if err := json.Unmarshal([]byte(fmt.Sprint(raw)), &payload); err != nil || !payload.OK || payload.Hex == "" {
		return nil, time.Time{}, false
	}
	var seen time.Time
	if payload.TS > 0 {
		seen = time.UnixMilli(payload.TS)
		if time.Since(seen) > maxAge {
			return nil, time.Time{}, false
		}
	}
	decoded, err := hex.DecodeString(payload.Hex)
	if err != nil || len(decoded) == 0 {
		return nil, time.Time{}, false
	}
	return decoded, seen, true
}

// snsPassiveResponse 兼容旧调用点：只关心字节内容。
// snsCapturedSNSBody 读取 hook 捕获的真实 SNS 请求体（timeline/sync）。
// hook 未捕获或解码失败时返回 nil，调用方继续用 marshal 的最小请求体。
func snsCapturedSNSBody(opName string) []byte {
	raw, err := snsCallFrida("snsCapturedBody", opName)
	if err != nil {
		return nil
	}
	var payload struct {
		OK  bool   `json:"ok"`
		Hex string `json:"hex"`
		Len int    `json:"len"`
	}
	if err := json.Unmarshal([]byte(fmt.Sprint(raw)), &payload); err != nil ||
		!payload.OK || payload.Hex == "" {
		return nil
	}
	decoded, err := hex.DecodeString(payload.Hex)
	if err != nil || len(decoded) == 0 || len(decoded) > 256*1024 {
		return nil
	}
	return decoded
}

func snsPassiveResponse(op string, maxAge time.Duration) []byte {
	body, _, ok := snsPassiveCapture(op, maxAge)
	if !ok {
		return nil
	}
	return body
}

func snsTimelineHandler(w http.ResponseWriter, r *http.Request) {
	if !snsPrepare(w, r, false) {
		return
	}
	var req snsTimelineRequestJSON
	if !snsDecodeJSONBody(w, r, &req) {
		return
	}
	maxID := uint64(0)
	if strings.TrimSpace(req.MaxID) != "" {
		id, err := parseSNSID(req.MaxID)
		if err != nil {
			snsWriteError(w, newSNSError(http.StatusBadRequest, "sns_invalid_request", "max_id 不是合法的 uint64 十进制字符串"))
			return
		}
		maxID = id
	}
	session, err := snsDecodeOptionalBase64(req.Session)
	if err != nil {
		snsWriteError(w, newSNSError(http.StatusBadRequest, "sns_invalid_request", "session 不是合法 base64"))
		return
	}
	limit := req.Limit
	if limit <= 0 {
		limit = 20
	}
	if limit > 50 {
		limit = 50
	}
	// refresh 不是协议字段：App 主动刷新时仍通过 MaxId=0 + FirstPageMd5 表达，
	// 这里只做兼容读取，不影响请求字段（protocol-web.md §3.3）。
	_ = req.Refresh

	var body []byte
	// 未捕获真实请求体时，首页请求直接用被动缓存（避免发必然超时的最小请求体）。
	var directPassive []byte
	var directSeen time.Time
	probeReplay := snsProbeEnabled() && strings.TrimSpace(req.BodyHex) != ""
	if probeReplay {
		decoded, hexErr := hex.DecodeString(strings.TrimSpace(req.BodyHex))
		if hexErr != nil || len(decoded) == 0 {
			snsWriteError(w, newSNSError(http.StatusBadRequest, "sns_invalid_request", "body_hex 非法"))
			return
		}
		body = decoded
	} else {
		body = MarshalSNSTimeLineRequest(SNSTimeLineRequest{
			FirstPageMD5: req.FirstPageMD5,
			MaxID:        maxID,
			Session:      session,
		})
		// 主动刷新：用户手动打开朋友圈时 hook 会捕获真实请求体；首页请求优先重放它。
		// 4.2.0.17 真机验证：真实请求体 → 原生响应；marshal 的最小请求体拿不到回包。
		// 分页（max_id != 0）不走主动发送（docs/sns.md §1.1.1）：最小请求体拿不到回包，
		// 只会白等 8s 超时后再回退缓存，因此直接读被动缓存。
		if !snsPassiveReadMode() && maxID == 0 {
			if captured := snsCapturedSNSBody("timeline"); len(captured) > 0 {
				body = captured
				Info("SNS 时间线复用捕获请求体", "len", len(captured))
			} else if passive, seen, ok := snsPassiveCapture("timeline", 10*time.Minute); ok {
				// 还没捕获到请求体：直接用被动缓存，避免发一个必然超时的最小请求体。
				directPassive = passive
				directSeen = seen
			}
		}
	}
	started := snsNow()
	// 不控制电脑界面：写通道关闭时直接读取用户手动打开朋友圈时 hook 捕获的响应；
	// 写通道开启时才尝试主动 R3 发送，失败后同样回退缓存。
	var hookResp SNSHookResponse
	var readErr error
	source := "native"
	var capturedAt time.Time
	switch {
	case maxID != 0 && !probeReplay:
		// 分页只走被动缓存（docs/sns.md §1.1.1）：主动发送未就绪时最小请求体必然超时，
		// 这里不再发一次注定失败的 8s 请求，直接返回 hook 缓存的原生响应。
		if passive, seen, ok := snsPassiveCapture("timeline", 10*time.Minute); ok {
			hookResp = SNSHookResponse{Body: passive}
			source = "passive"
			capturedAt = seen
		} else {
			readErr = newSNSError(http.StatusServiceUnavailable, "sns_need_prime",
				"请先在微信打开一次朋友圈以捕获发送上下文")
		}
	case directPassive != nil:
		hookResp = SNSHookResponse{Body: directPassive}
		source = "passive"
		capturedAt = directSeen
	case snsPassiveReadMode():
		if passive, seen, ok := snsPassiveCapture("timeline", 10*time.Minute); ok {
			hookResp = SNSHookResponse{Body: passive}
			source = "passive"
			capturedAt = seen
		} else {
			readErr = newSNSError(http.StatusServiceUnavailable, "sns_need_prime",
				"请先在微信打开一次朋友圈以捕获发送上下文")
		}
	default:
		ctx, cancel := snsReadCtx(r, "timeline")
		defer cancel()
		hookResp, readErr = snsSvc.read(ctx, "timeline", body)
		if readErr != nil {
			if passive, seen, ok := snsPassiveCapture("timeline", 10*time.Minute); ok {
				hookResp = SNSHookResponse{Body: passive}
				source = "passive"
				capturedAt = seen
				readErr = nil
				Info("SNS 时间线使用原生刷新缓存兜底", "len", len(passive))
			}
		}
	}
	if readErr != nil {
		snsWriteError(w, readErr)
		return
	}
	tl, err := UnmarshalSNSTimeLineResponse(hookResp.Body)
	if err != nil {
		Warn("SNS 时间线回包解析失败", "len", len(hookResp.Body))
		snsWriteError(w, newSNSError(http.StatusBadGateway, "sns_parse_failed", "朋友圈回包解析失败"))
		return
	}
	if err := snsCheckBaseRet(tl.Base); err != nil {
		snsWriteError(w, err)
		return
	}

	posts := make([]snsPostJSON, 0, len(tl.Objects))
	for i := range tl.Objects {
		posts = append(posts, snsNormalizePost(&tl.Objects[i], false))
	}
	// 原生 timeline 常不返回「评论的回复」；把 /sns/sync 增量并入的缓存评论补回来，
	// 按 comment_id 去重（原生顺序在前，缓存只补缺）。被动缓存模式同样适用。
	for i := range posts {
		id, err := parseSNSID(posts[i].ID)
		if err != nil {
			continue
		}
		if cached, ok := snsSvc.lookupPost(id); ok {
			posts[i] = snsMergeCachedComments(posts[i], cached)
		}
	}
	// ControlFlag 在公开资料中表示「有更多/走增量」（protocol-web.md §3.2）；
	// 服务端分页大小未知，不能依赖 len(posts) 判断，先按该位近似。
	hasMore := tl.ControlFlag != 0
	if len(posts) > limit {
		posts = posts[:limit]
		hasMore = true
	}
	// 朋友圈页/P7 只看 timeline：把 sns.db 里（timeline 回包常缺的）评论/回复
	// 补到已截断的 post 上；只读、按 comment_id 去重补缺，失败静默降级。
	posts = mergeSNSDbComments(posts)
	snsSvc.rememberPosts(posts)
	if source == "native" {
		// 用户手动打开朋友圈后捕获的 service/closure/请求体在这里落盘，不依赖 App
		// 打开「捕获发送句柄」弹窗再触发 /sns/status；按最小间隔节流，内容不变不重写。
		snsPersistCaptureState(false)
	}

	cursor := snsCursorJSON{
		MaxID:        req.MaxID,
		FirstPageMD5: tl.FirstPageMD5,
		Session:      snsEncodeBase64(tl.Session),
		HasMore:      hasMore,
	}
	if len(posts) > 0 {
		cursor.MaxID = posts[len(posts)-1].ID
	}
	if strings.TrimSpace(cursor.MaxID) == "" {
		cursor.MaxID = "0"
	}

	commentsTotal, repliesTotal, truncatedTotal := 0, 0, 0
	for i := range posts {
		commentsTotal += len(posts[i].Comments)
		for _, c := range posts[i].Comments {
			if c.ReplyTo != "" || c.ReplyToUserID != "" {
				repliesTotal++
			}
		}
		if posts[i].CommentsTruncated {
			truncatedTotal++
		}
	}
	// 只记录条数/状态，不打印评论正文或 wxid。
	Info("SNS 时间线读取完成", "posts", len(posts), "objects", int(tl.ObjectCount),
		"comments", commentsTotal, "replies", repliesTotal, "truncated_posts", truncatedTotal,
		"has_more", hasMore, "elapsed_ms", time.Since(started).Milliseconds())
	var capturedUnix int64
	if !capturedAt.IsZero() {
		capturedUnix = capturedAt.Unix()
	}
	snsWriteOK(w, snsTimelineData{
		Posts:      posts,
		Source:     source,
		CapturedAt: capturedUnix,
		Cursor:     cursor,
		ServerConfig: snsServerConfigJSON{
			PostMentionLimit:      tl.ServerConfig.PostMentionLimit,
			CopyAndPasteWordLimit: tl.ServerConfig.CopyAndPasteWordLimit,
		},
	})
}

// ---- POST /sns/detail -----------------------------------------------------

type snsDetailRequestJSON struct {
	PostID string `json:"post_id"`
}

// snsDetailCachePayload 构造缓存兜底的详情响应：评论/点赞可能不完整，强制把
// comments_truncated 置为 true；comment_count 保留缓存里的真实计数，不按本地
// 已缓存的评论条数重算（不伪造「全量评论」）。
func snsDetailCachePayload(post snsPostJSON) map[string]any {
	post.CommentsTruncated = true
	return map[string]any{"post": post, "source": "cache"}
}

func snsDetailHandler(w http.ResponseWriter, r *http.Request) {
	if !snsPrepare(w, r, false) {
		return
	}
	var req snsDetailRequestJSON
	if !snsDecodeJSONBody(w, r, &req) {
		return
	}
	id, err := parseSNSID(req.PostID)
	if err != nil {
		snsWriteError(w, newSNSError(http.StatusBadRequest, "sns_invalid_request", "post_id 不是合法的 uint64 十进制字符串"))
		return
	}
	// 被动只读模式不尝试主动 R3（与时间线一致）：直接用时间线缓存兜底，
	// 缓存没有该动态时仍返回「请先打开一次朋友圈」的原错误。
	if snsPassiveReadMode() {
		post, ok := snsSvc.lookupPost(id)
		if !ok {
			snsWriteError(w, newSNSError(http.StatusServiceUnavailable, "sns_need_prime",
				"请先在微信打开一次朋友圈以捕获发送上下文"))
			return
		}
		Debug("SNS 详情使用时间线缓存兜底", "passive", true, "comments", len(post.Comments))
		snsWriteOK(w, snsDetailCachePayload(post))
		return
	}
	body := MarshalSNSObjectDetailRequest(SNSObjectDetailRequest{ID: id})
	ctx, cancel := snsReadCtx(r, "detail")
	defer cancel()
	hookResp, readErr := snsSvc.read(ctx, "detail", body)
	if readErr != nil {
		// 主动通道失败时回退时间线缓存；缓存没有该动态才保留原错误。
		if post, ok := snsSvc.lookupPost(id); ok {
			Debug("SNS 详情使用时间线缓存兜底", "error", snsHTTPError(readErr).Code,
				"comments", len(post.Comments))
			snsWriteOK(w, snsDetailCachePayload(post))
			return
		}
		snsWriteError(w, readErr)
		return
	}
	detail, err := UnmarshalSNSObjectDetailResponse(hookResp.Body)
	if err != nil {
		Warn("SNS 详情回包解析失败", "len", len(hookResp.Body))
		snsWriteError(w, newSNSError(http.StatusBadGateway, "sns_parse_failed", "朋友圈回包解析失败"))
		return
	}
	if err := snsCheckBaseRet(detail.Base); err != nil {
		snsWriteError(w, err)
		return
	}
	if detail.Object == nil {
		snsWriteError(w, newSNSError(http.StatusBadGateway, "sns_parse_failed", "朋友圈详情回包缺少动态对象"))
		return
	}
	post := snsNormalizePost(detail.Object, true)
	snsSvc.rememberPosts([]snsPostJSON{post})
	snsWriteOK(w, map[string]any{"post": post, "source": "native"})
}

// ---- POST /sns/media ------------------------------------------------------

type snsMediaRequestJSON struct {
	PostID     string `json:"post_id"`
	MediaIndex int    `json:"media_index"`
	Variant    string `json:"variant"`
}

func snsMediaHandler(w http.ResponseWriter, r *http.Request) {
	if !snsPrepare(w, r, false) {
		return
	}
	var req snsMediaRequestJSON
	if !snsDecodeJSONBody(w, r, &req) {
		return
	}
	postID, err := parseSNSID(req.PostID)
	if err != nil {
		snsWriteError(w, newSNSError(http.StatusBadRequest, "sns_invalid_request", "post_id 不是合法的 uint64 十进制字符串"))
		return
	}
	variant := strings.TrimSpace(req.Variant)
	if variant == "" {
		variant = "thumb"
	}
	if variant != "thumb" && variant != "full" {
		snsWriteError(w, newSNSError(http.StatusBadRequest, "sns_invalid_request", "variant 必须是 thumb 或 full"))
		return
	}
	post, ok := snsSvc.lookupPost(postID)
	if !ok {
		snsWriteError(w, newSNSError(http.StatusNotFound, "sns_post_not_found", "未找到该动态，请先刷新时间线"))
		return
	}
	if len(post.Media) == 0 {
		snsWriteError(w, newSNSError(http.StatusNotFound, "sns_media_not_found", "该动态没有可下载的媒体"))
		return
	}
	if req.MediaIndex < 0 || req.MediaIndex >= len(post.Media) {
		snsWriteError(w, newSNSError(http.StatusBadRequest, "sns_invalid_request", "media_index 越界"))
		return
	}
	media := post.Media[req.MediaIndex]
	key := media.ThumbKey
	kind := "thumb"
	if variant == "full" {
		key = media.URLKey
		kind = "image"
	}
	if key == "" {
		key = media.URLKey
	}
	if key == "" {
		snsWriteError(w, newSNSError(http.StatusNotFound, "sns_media_not_found", "该动态没有可下载的媒体"))
		return
	}
	dir := snsMediaDir()
	if dir == "" {
		snsWriteError(w, newSNSError(http.StatusServiceUnavailable, "sns_media_unavailable", "未配置朋友圈媒体目录"))
		return
	}
	path := filepath.Join(dir, fmt.Sprintf("%s-%d-%s", req.PostID, req.MediaIndex, variant))

	// 同一动态/索引/变体的解密结果直接复用：下载函数用 tmp+rename 原子落盘并校验图片魔数，
	// 因此同账号目录下的既有文件可以安全复用，避免重复走 CDN/解密。
	if info, statErr := os.Stat(path); statErr == nil && !info.IsDir() && info.Size() > 0 {
		// 与 legacy 下载成功路径保持同一响应形态（file 在顶层），App 两种形态都兼容。
		writeSNSJSON(w, http.StatusOK, map[string]any{
			"status": "ok",
			"file":   "file://" + path,
			"kind":   kind,
			"cached": true,
		})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), snsMediaCallTimeout)
	defer cancel()
	// 新路径：直接用时间线 XML 的 url/key/token 下载（mac 4.2 CDN 需要 token）。
	if raw, ok := snsLookupRawMedia(req.PostID, req.MediaIndex); ok {
		file, dlErr := snsDownloadImageFunc(ctx, raw, variant, path)
		if dlErr == nil {
			snsWriteOK(w, map[string]any{"file": file, "kind": kind})
			return
		}
		msg := dlErr.Error()
		if strings.Contains(msg, "decrypt pending") {
			snsWriteError(w, newSNSError(http.StatusServiceUnavailable, "sns_media_decrypt_pending",
				"朋友圈图片已下载，但解密算法尚未就绪"))
			return
		}
		Warn("SNS 媒体下载失败", "err", msg)
		snsWriteError(w, newSNSError(http.StatusBadGateway, "sns_media_failed", "朋友圈媒体下载失败"))
		return
	}
	res, err := currentSNSRPC().Media(ctx, SNSMediaRequest{
		Action: "download",
		Key:    key,
		Kind:   kind,
		PostID: req.PostID,
		Path:   path,
	})
	if err != nil {
		snsWriteError(w, err)
		return
	}
	file := strings.TrimSpace(res.File)
	if file == "" {
		snsWriteError(w, newSNSError(http.StatusBadGateway, "sns_media_failed", "朋友圈媒体下载失败"))
		return
	}
	fsPath := strings.TrimPrefix(file, "file://")
	if !snsPathWithin(dir, fsPath) {
		Warn("SNS 媒体路径越界，已拒绝", "len", len(fsPath))
		snsWriteError(w, newSNSError(http.StatusBadGateway, "sns_media_failed", "朋友圈媒体路径无效"))
		return
	}
	if info, err := os.Stat(fsPath); err != nil || info.IsDir() {
		snsWriteError(w, newSNSError(http.StatusBadGateway, "sns_media_failed", "朋友圈媒体文件不存在"))
		return
	}
	if !strings.HasPrefix(file, "file://") {
		file = "file://" + fsPath
	}
	Info("SNS 媒体下载完成", "variant", variant, "bytes", func() int64 {
		if info, err := os.Stat(fsPath); err == nil {
			return info.Size()
		}
		return 0
	}())
	writeSNSJSON(w, http.StatusOK, map[string]any{"status": "ok", "file": file})
}

// ---- POST /sns/sync -------------------------------------------------------

type snsSyncRequestJSON struct {
	WaitMS int `json:"wait_ms"`
}

// snsUnwrapSyncCmdBuf 剥离 mmsnssync CmdBuf 的外层信封（mac 4.2 真机 2026-11-09）：
//
//	CmdBuf = { 1: varint payload_len, 2: bytes payload }
//
// payload 才是 SnsObject（cmd 45）或 SnsActionGroup（cmd 46）。只在「恰好两个
// 字段、类型匹配、field1 == len(field2)」时解包，其它载荷原样返回，避免把
// 合法的 SnsObject/SnsActionGroup 误判成信封。
func snsUnwrapSyncCmdBuf(buf []byte) []byte {
	if len(buf) == 0 {
		return buf
	}
	var payloadLen uint64
	var payload []byte
	hasLen, hasPayload := false, false
	fieldCount := 0
	err := snsWalk(buf, func(f snsWireField) error {
		fieldCount++
		switch f.num {
		case 1:
			if f.typ == protowire.VarintType {
				payloadLen = f.varint
				hasLen = true
			}
		case 2:
			if f.typ == protowire.BytesType {
				payload = f.bytes
				hasPayload = true
			}
		}
		return nil
	})
	if err != nil || fieldCount != 2 || !hasLen || !hasPayload || len(payload) == 0 {
		return buf
	}
	if uint64(len(payload)) != payloadLen {
		return buf
	}
	return payload
}

// snsDecodeSyncCommand 尝试把 CmdList 里的 CmdBuf 解成已知 SNS 载荷（best-effort）。
//
// 已知 macOS 4.2 的 CmdBuf 结构（2026-11-09 真机）：外层信封剥掉后只接受
// 「字段自洽」的载荷：
//   - SnsObject：新动态（ID/作者/时间齐全）→ sns_new_post；
//   - SnsActionGroup：评论/点赞（ID + CurrentAction）→ sns_comment / sns_like；
//   - SnsAction type=11：4.2.0.17 的「回复/互动通知」——CurrentAction 只有
//     From/To/ToNickname/CreateTime/IsNotRichText，没有 Content 与 CommentID，
//     不能当可自动回复候选，也不并入评论缓存；只产 sns_comment_hint
//     （post_id/from_user/create_time）供 App 提示或触发 timeline 刷新。
//
// 返回 ok=false 时调用方计入 unsupported_cmd_count，绝不猜测事件。
func snsDecodeSyncCommand(cmdID int32, buf []byte) ([]map[string]any, bool) {
	if len(buf) == 0 {
		return nil, true
	}
	// 真机 CmdBuf 是 {1:len,2:payload} 外层信封，先解包再按已知载荷解码。
	if inner := snsUnwrapSyncCmdBuf(buf); len(inner) > 0 && len(inner) != len(buf) {
		Debug("SNS 同步 CmdBuf 已解包", "cmd_id", cmdID, "inner_len", len(inner))
		buf = inner
	}
	account := strings.TrimSpace(myWechatId)
	wrap := func(typ string, data map[string]any) map[string]any {
		return map[string]any{"type": typ, "account": account, "data": data}
	}
	if obj, err := UnmarshalSNSObject(buf); err == nil &&
		obj.ID != 0 && strings.TrimSpace(obj.Username) != "" && obj.CreateTime != 0 {
		post := snsNormalizePost(obj, false)
		snsSvc.rememberPosts([]snsPostJSON{post})
		return []map[string]any{wrap("sns_new_post", map[string]any{
			"post":   post,
			"source": "native",
		})}, true
	}
	group, err := UnmarshalSNSActionGroup(buf)
	if err != nil || group.ID == 0 || group.CurrentAction == nil {
		return nil, false
	}
	postID := strconv.FormatUint(group.ID, 10)
	action := group.CurrentAction
	switch action.Type {
	case 1: // 点赞
		if strings.TrimSpace(action.FromUsername) == "" {
			return nil, false
		}
		return []map[string]any{wrap("sns_like", map[string]any{
			"post_id":   postID,
			"user_id":   action.FromUsername,
			"cancelled": false,
			"source":    "native",
		})}, true
	case 2, 3: // 评论 / 回复
		if strings.TrimSpace(action.FromUsername) == "" ||
			strings.TrimSpace(action.Content) == "" {
			return nil, false
		}
		comment := snsCommentFromInfo(SNSCommentInfo{
			Username:        action.FromUsername,
			Nickname:        action.FromNickname,
			Type:            action.Type,
			Content:         action.Content,
			CreateTime:      action.CreateTime,
			CommentID:       action.CommentID,
			ReplyCommentID:  action.ReplyCommentID,
			ReplyUsername:   action.ToUsername,
			CommentID2:      action.CommentID2,
			ReplyCommentID2: action.ReplyCommentID2,
		})
		// 同步事件里的评论/回复先并入缓存：timeline 回包常缺这些评论，
		// App 刷新朋友圈时由 timeline 与缓存合并后展示（P7 也能扫到回复）。
		snsSvc.rememberComments(postID, []snsCommentJSON{comment})
		return []map[string]any{wrap("sns_comment", map[string]any{
			"post_id": postID,
			"comment": comment,
			"source":  "native",
		})}, true
	case 11:
		// 真机 2026-11-09：好友回复机器人评论时，cmd46 的 CurrentAction.Type=11，
		// 只有 From/To/ToNickname/CreateTime/IsNotRichText=1，没有 Content/
		// CommentID/ReplyCommentID —— 服务端只推「有新互动」通知，正文需要重新
		// 读 timeline/detail。这里不伪造正文、不写评论缓存（避免自动回复空气），
		// 只发一个明确 hint 让 App 提示用户或触发刷新。
		if strings.TrimSpace(action.FromUsername) == "" || action.CreateTime == 0 {
			return nil, false
		}
		hint := map[string]any{
			"post_id":     postID,
			"from_user":   action.FromUsername,
			"create_time": int64(action.CreateTime),
			"source":      "native",
		}
		if strings.TrimSpace(action.FromNickname) != "" {
			hint["from_name"] = action.FromNickname
		}
		if strings.TrimSpace(action.ToUsername) != "" {
			hint["reply_to_user_id"] = action.ToUsername
		}
		return []map[string]any{wrap("sns_comment_hint", hint)}, true
	default:
		return nil, false
	}
}

func snsSyncHandler(w http.ResponseWriter, r *http.Request) {
	if !snsPrepare(w, r, false) {
		return
	}
	var req snsSyncRequestJSON
	if !snsDecodeJSONBody(w, r, &req) {
		return
	}
	waitMS := req.WaitMS
	if waitMS < 0 {
		waitMS = 0
	}
	if waitMS > 30000 {
		waitMS = 30000
	}
	timeout := snsTimeoutFor("sync") + time.Duration(waitMS)*time.Millisecond
	ctx, cancel := context.WithTimeout(r.Context(), timeout)
	defer cancel()

	keyBuf := snsSvc.syncCursor()
	body := MarshalSNSSyncRequest(SNSSyncRequest{Selector: snsSyncSelector, KeyBuf: keyBuf})
	// 主动同步：复用捕获的真实 mmsnssync 请求体（保留 App 侧字段），只替换当前游标。
	if !snsPassiveReadMode() {
		if captured := snsCapturedSNSBody("sync"); len(captured) > 0 {
			if len(keyBuf) == 0 {
				// 首次同步：捕获体里的 KeyBuf 是服务端要求的初始游标，整包复用。
				body = captured
				Info("SNS 同步复用完整捕获请求体", "len", len(captured))
			} else if patched, patchErr := snsPatchSyncRequestKeyBuf(captured, keyBuf); patchErr == nil && len(patched) > 0 {
				body = patched
				Info("SNS 同步复用捕获请求体", "len", len(patched))
			}
		}
	}
	hookResp, err := snsSvc.read(ctx, "sync", body)
	source := "native"
	if err != nil {
		if passive := snsPassiveResponse("sync", 10*time.Minute); len(passive) > 0 {
			hookResp = SNSHookResponse{Body: passive}
			source = "passive"
			err = nil
			Info("SNS 同步使用原生响应缓存兜底", "len", len(passive))
		}
	}
	if err != nil {
		snsWriteError(w, err)
		return
	}
	syncResp, err := UnmarshalSNSSyncResponse(hookResp.Body)
	if err != nil {
		Warn("SNS 同步回包解析失败", "len", len(hookResp.Body))
		snsWriteError(w, newSNSError(http.StatusBadGateway, "sns_parse_failed", "朋友圈同步回包解析失败"))
		return
	}
	if err := snsCheckBaseRet(syncResp.Base); err != nil {
		snsWriteError(w, err)
		return
	}
	// 只有本次主动请求的回包才能推进同步游标：被动兜底的是 hook 缓存的旧响应，
	// 复用它的 KeyBuf 会把游标回滚（重复投递已处理命令）或跳过来处理区间。
	// 被动模式返回的 cursor 仅供展示，App 不使用同步游标驱动请求（docs/sns.md §4.5）。
	if syncResp.KeyBuf != nil && source == "native" {
		snsSvc.setSyncCursor(syncResp.KeyBuf)
	}
	// CmdList 的 CmdBuf 语义尚未实测（docs/sns.md §4.5）：按「已知 SNS 载荷」做
	// best-effort 解码——能严格解析成 SnsObject / SnsActionGroup 才产出事件，
	// 其余一律计入 unsupported，不伪造通知。
	events := make([]map[string]any, 0, len(syncResp.CmdList.Items))
	unsupported := 0
	for _, item := range syncResp.CmdList.Items {
		decoded, ok := snsDecodeSyncCommand(item.CmdID, item.CmdBuf)
		if !ok {
			unsupported++
			continue
		}
		events = append(events, decoded...)
	}
	Info("SNS 同步完成", "cmds", len(syncResp.CmdList.Items), "events", len(events),
		"decoded_events", len(events), "unsupported_cmds", unsupported,
		"continue_flag", syncResp.ContinueFlag)
	commands := make([]map[string]any, 0, len(syncResp.CmdList.Items))
	for _, item := range syncResp.CmdList.Items {
		commands = append(commands, map[string]any{
			"cmd_id":  item.CmdID,
			"buf_len": len(item.CmdBuf),
		})
	}
	data := map[string]any{
		"events":                events,
		"source":                source,
		"commands":              commands,
		"unsupported_cmd_count": unsupported,
		"cursor": map[string]any{
			"key_buf":       snsEncodeBase64(syncResp.KeyBuf),
			"continue_flag": syncResp.ContinueFlag,
		},
	}
	// 仅调试抓包（snsProbe=true）时返回 CmdBuf 前 64 字节，用于校准真实 CmdList 载荷结构；
	// 默认关闭，不进入产品日志/遥测。
	if snsProbeEnabled() {
		debug := make([]map[string]any, 0, len(syncResp.CmdList.Items))
		for _, item := range syncResp.CmdList.Items {
			prefix := item.CmdBuf
			if len(prefix) > 64 {
				prefix = prefix[:64]
			}
			debug = append(debug, map[string]any{
				"cmd_id":     item.CmdID,
				"buf_len":    len(item.CmdBuf),
				"prefix_hex": hex.EncodeToString(prefix),
			})
		}
		data["debug_commands"] = debug
	}
	snsWriteOK(w, data)
}

// ---- POST /sns/post（P3，默认关闭）---------------------------------------

type snsPostRequestJSON struct {
	Text           string            `json:"text"`
	Visibility     string            `json:"visibility"`
	TargetUserID   string            `json:"target_user_id"`
	VisibleUserIDs []string          `json:"visible_user_ids"`
	Media          []json.RawMessage `json:"media"`
	// ClientID 是可选的幂等键（docs/sns.md §4.6）：同键 10 分钟内重复请求
	// 返回 409 sns_duplicate_request，避免超时重试重复发布。
	ClientID string `json:"client_id"`
	Confirm  *bool  `json:"confirm,omitempty"`
}

func snsPostHandler(w http.ResponseWriter, r *http.Request) {
	if !snsPrepare(w, r, true) {
		return
	}
	var req snsPostRequestJSON
	if !snsDecodeJSONBody(w, r, &req) {
		return
	}
	if se := snsConfirmError(req.Confirm); se != nil {
		snsWriteError(w, se)
		return
	}
	plan, se := snsPlanVisibility(req.Visibility, req.VisibleUserIDs, req.TargetUserID)
	if se != nil {
		snsWriteError(w, se)
		return
	}
	if len(req.Media) > 0 {
		snsWriteError(w, newSNSError(http.StatusBadRequest, "sns_media_post_unsupported", "暂不支持发布图片/视频"))
		return
	}
	text := strings.TrimSpace(req.Text)
	if text == "" {
		snsWriteError(w, newSNSError(http.StatusBadRequest, "sns_invalid_request", "正文不能为空"))
		return
	}
	if _, was := snsTruncateRunes(text, snsPostRuneLimit); was {
		snsWriteError(w, newSNSError(http.StatusBadRequest, "sns_invalid_request", "正文超过长度上限"))
		return
	}
	self := strings.TrimSpace(myWechatId)
	if self == "" {
		snsWriteError(w, newSNSError(http.StatusServiceUnavailable, "sns_not_ready", "尚未识别当前微信账号"))
		return
	}
	clientID := strings.TrimSpace(req.ClientID)
	if len(clientID) > snsPostClientIDMaxLen {
		snsWriteError(w, newSNSError(http.StatusBadRequest, "sns_invalid_request", "client_id 超过长度上限"))
		return
	}
	// 时段 / 每日上限 / 最小间隔（配置见版本 JSON snsPost*，默认 1 条/10 分钟、5 条/天）。
	// 这里只校验不记录：失败尝试（含当前必然的 503 发布通道未就绪）不消耗配额。
	now := snsNow()
	if se := checkSNSPostPolicy(now); se != nil {
		snsWriteError(w, se)
		return
	}
	// 通过全部校验后登记幂等键：窗口内重复的 client_id 直接 409，不再构造/尝试。
	if !snsSvc.claimSNSPostClientID(clientID, now) {
		snsWriteError(w, newSNSError(http.StatusConflict, "sns_duplicate_request", "重复的发布请求（幂等键已处理）"))
		return
	}

	// 构造 SnsPostRequest：正文 XML + 可见性；真实请求模板由 hook 在用户成功发布一次后捕获
	// （含 ClientCheckDat，mac field 28，无法自造），见下方 snsRebuildPostRequest。
	xmlPrivate := uint32(0)
	if plan.Visibility == "private" {
		xmlPrivate = 1
	}
	xmlBody, err := BuildSNSTimelineObjectText(self, text, now.Unix(), xmlPrivate)
	if err != nil {
		Warn("SNS 发布 XML 构造失败", "err", err)
		snsWriteError(w, newSNSError(http.StatusInternalServerError, "sns_post_build_failed", "朋友圈发布请求构造失败"))
		return
	}
	// v3.0：用 hook 捕获的真实 SnsPost 请求做模板（复用 ClientCheckDat 等无法自造字段），
	// 替换正文/可见性后经 R3 合成任务提交；没有模板时明确 503，不发送半成品请求。
	template := snsCapturedSNSBody("post")
	if len(template) == 0 {
		snsWriteError(w, newSNSError(http.StatusServiceUnavailable, "sns_publish_unavailable",
			"还没有捕获发布样本：请先在微信里成功发布一次朋友圈（可仅自己可见），之后再重试"))
		return
	}
	// 样本必须带 ClientCheckDat（mac 4.2 是 field 28；兼容旧 field 27），否则服务端会
	// 静默拒绝。这里提前给出 docs/sns.md §4.6 的 503，不把半成品请求发出去。
	templateReq, templateErr := UnmarshalSNSPostRequest(template)
	if templateErr != nil ||
		(len(templateReq.ClientCheckDat) == 0 && len(templateReq.ClientCheckDatLegacy27) == 0) {
		Warn("SNS 发布样本不完整", "len", len(template))
		snsWriteError(w, newSNSError(http.StatusServiceUnavailable, "sns_publish_unavailable",
			"发布样本不完整（缺少反垃圾字段），请重新在微信里发布一次后重试"))
		return
	}
	body, buildErr := snsPatchPostRequest(
		template, xmlBody, plan.Privacy,
		fmt.Sprintf("sns_post_%d", now.UnixNano()), plan.VisibleUserIDs)
	if buildErr != nil {
		Warn("SNS 发布请求重建失败", "err", buildErr.Error())
		snsWriteError(w, newSNSError(http.StatusServiceUnavailable, "sns_publish_unavailable",
			"发布样本不完整（缺少反垃圾字段），请重新在微信里发布一次后重试"))
		return
	}
	Debug("SNS 发布请求已提交", "visibility", plan.Visibility, "privacy", plan.Privacy,
		"visible_users", len(plan.VisibleUserIDs), "xml_len", len(xmlBody),
		"body_len", len(body))
	ctx, cancel := context.WithTimeout(r.Context(), snsTimeoutFor("post"))
	defer cancel()
	// 写请求必须串行（docs/sns.md §3）：发布也走 snsService.write，避免与评论/点赞
	// 同时提交到同一个合成任务通道。
	hookResp, err := snsSvc.write(ctx, "post", body)
	if err != nil {
		// 写路径 503 按 code 细分：句柄失效/未捕获 → sns_publish_unavailable，
		// 不要退化成读路径的「请先打开一次朋友圈」（docs/sns.md §4.6）。
		snsWriteError(w, snsPublishUnavailable(err))
		return
	}
	postResp, err := UnmarshalSNSPostResponse(hookResp.Body)
	if err != nil {
		Warn("SNS 发布回包解析失败", "len", len(hookResp.Body))
		snsWriteError(w, newSNSError(http.StatusBadGateway, "sns_parse_failed", "朋友圈发布回包解析失败"))
		return
	}
	if err := snsCheckBaseRet(postResp.Base); err != nil {
		snsWriteError(w, err)
		return
	}
	recordSNSPostAttempt(now)
	out := map[string]any{"client_id": clientID}
	if postResp.Object != nil {
		post := snsNormalizePost(postResp.Object, false)
		snsSvc.rememberPosts([]snsPostJSON{post})
		out["post_id"] = post.ID
		out["create_time"] = post.CreateTime
	}
	// 发布成功后 hook 里的 post 模板可能已刷新，强制落盘（不受 /sns/status 节流影响）。
	snsPersistCaptureState(true)
	snsWriteOK(w, out)
}

// ---- POST /sns/comment / like / objectop（P4，默认关闭）------------------

type snsCommentRequestJSON struct {
	PostID         string `json:"post_id"`
	Text           string `json:"text"`
	ReplyCommentID string `json:"reply_comment_id"`
	Confirm        *bool  `json:"confirm,omitempty"`
}

func snsCommentHandler(w http.ResponseWriter, r *http.Request) {
	if !snsPrepare(w, r, true) {
		return
	}
	var req snsCommentRequestJSON
	if !snsDecodeJSONBody(w, r, &req) {
		return
	}
	if se := snsConfirmError(req.Confirm); se != nil {
		snsWriteError(w, se)
		return
	}
	text := strings.TrimSpace(req.Text)
	if text == "" {
		snsWriteError(w, newSNSError(http.StatusBadRequest, "sns_invalid_request", "评论内容不能为空"))
		return
	}
	if _, was := snsTruncateRunes(text, snsCommentRuneLimit); was {
		snsWriteError(w, newSNSError(http.StatusBadRequest, "sns_invalid_request", "评论超过长度上限"))
		return
	}
	post, reply, se := snsResolveWriteTarget(req.PostID, req.ReplyCommentID)
	if se != nil {
		snsWriteError(w, se)
		return
	}
	if se := checkSNSWriteRate("comment"); se != nil {
		snsWriteError(w, se)
		return
	}
	commentReq, se := snsBuildCommentRequest(post, 2, text, reply)
	if se != nil {
		snsWriteError(w, se)
		return
	}
	ctx, cancel := snsReadCtx(r, "comment")
	defer cancel()
	hookResp, err := snsSvc.write(ctx, "comment", snsMarshalCommentBody(commentReq))
	if err != nil {
		snsWriteError(w, snsInteractionUnavailable(err))
		return
	}
	resp, err := UnmarshalSNSCommentResponse(hookResp.Body)
	if err != nil {
		Warn("SNS 评论回包解析失败", "len", len(hookResp.Body))
		snsWriteError(w, newSNSError(http.StatusBadGateway, "sns_parse_failed", "朋友圈回包解析失败"))
		return
	}
	if err := snsCheckBaseRet(resp.Base); err != nil {
		snsWriteError(w, err)
		return
	}
	// 回包的 SnsObject 可能只带计数/对象摘要，不能直接覆盖缓存（会丢正文/媒体/旧评论，
	// 也会让后续「回复某条评论」找不到目标）。先与写前缓存合并，再 diff 出新评论。
	updated := post
	if resp.Object != nil {
		updated = snsNormalizePost(resp.Object, true)
	}
	merged := snsMergeInteractionPost(updated, post)
	snsSvc.rememberPosts([]snsPostJSON{merged})
	recordSNSWriteRate("comment")
	data := map[string]any{"post": merged}
	if c := snsNewCommentFromResponse(merged, post, myWechatId, text); c != nil {
		data["comment"] = c
		if c.CommentID != "" {
			data["comment_id"] = c.CommentID
		}
	}
	snsWriteOK(w, data)
}

type snsLikeRequestJSON struct {
	PostID  string `json:"post_id"`
	Cancel  bool   `json:"cancel"`
	Confirm *bool  `json:"confirm,omitempty"`
}

func snsLikeHandler(w http.ResponseWriter, r *http.Request) {
	if !snsPrepare(w, r, true) {
		return
	}
	var req snsLikeRequestJSON
	if !snsDecodeJSONBody(w, r, &req) {
		return
	}
	if se := snsConfirmError(req.Confirm); se != nil {
		snsWriteError(w, se)
		return
	}
	post, _, se := snsResolveWriteTarget(req.PostID, "")
	if se != nil {
		snsWriteError(w, se)
		return
	}
	if se := checkSNSWriteRate("like"); se != nil {
		snsWriteError(w, se)
		return
	}
	ctx, cancel := snsReadCtx(r, "like")
	defer cancel()

	if req.Cancel {
		opReq := SNSObjectOpRequest{Ops: []SNSObjectOp{{
			ID:     postIDFromJSON(post),
			OpType: SNSObjectOpTypeCancelLike,
		}}}
		hookResp, err := snsSvc.write(ctx, "objectop", MarshalSNSObjectOpRequest(opReq))
		if err != nil {
			snsWriteError(w, err)
			return
		}
		opResp, err := UnmarshalSNSObjectOpResponse(hookResp.Body)
		if err != nil {
			Warn("SNS 取消赞回包解析失败", "len", len(hookResp.Body))
			snsWriteError(w, newSNSError(http.StatusBadGateway, "sns_parse_failed", "朋友圈回包解析失败"))
			return
		}
		if err := snsCheckBaseRet(opResp.Base); err != nil {
			snsWriteError(w, err)
			return
		}
		if err := snsCheckOpRets(opResp.OpRetList); err != nil {
			snsWriteError(w, err)
			return
		}
		recordSNSWriteRate("like")
		snsWriteOK(w, map[string]any{"liked": false})
		return
	}

	commentReq, se := snsBuildCommentRequest(post, 1, "", nil)
	if se != nil {
		snsWriteError(w, se)
		return
	}
	// 点赞与评论是同一个 CGI（0xD5 mmsnscomment），hook op 用 "comment"。
	hookResp, err := snsSvc.write(ctx, "comment", snsMarshalCommentBody(commentReq))
	if err != nil {
		snsWriteError(w, snsInteractionUnavailable(err))
		return
	}
	resp, err := UnmarshalSNSCommentResponse(hookResp.Body)
	if err != nil {
		Warn("SNS 点赞回包解析失败", "len", len(hookResp.Body))
		snsWriteError(w, newSNSError(http.StatusBadGateway, "sns_parse_failed", "朋友圈回包解析失败"))
		return
	}
	if err := snsCheckBaseRet(resp.Base); err != nil {
		snsWriteError(w, err)
		return
	}
	merged := post
	if resp.Object != nil {
		merged = snsMergeInteractionPost(snsNormalizePost(resp.Object, true), post)
		snsSvc.rememberPosts([]snsPostJSON{merged})
	}
	recordSNSWriteRate("like")
	snsWriteOK(w, map[string]any{"liked": true, "post": merged})
}

type snsObjectOpRequestJSON struct {
	PostID    string `json:"post_id"`
	Op        string `json:"op"`
	CommentID string `json:"comment_id"`
	Confirm   *bool  `json:"confirm,omitempty"`
}

func snsObjectOpHandler(w http.ResponseWriter, r *http.Request) {
	if !snsPrepare(w, r, true) {
		return
	}
	var req snsObjectOpRequestJSON
	if !snsDecodeJSONBody(w, r, &req) {
		return
	}
	if se := snsConfirmError(req.Confirm); se != nil {
		snsWriteError(w, se)
		return
	}
	post, _, se := snsResolveWriteTarget(req.PostID, "")
	if se != nil {
		snsWriteError(w, se)
		return
	}
	var op SNSObjectOp
	op.ID = postIDFromJSON(post)
	switch strings.TrimSpace(req.Op) {
	case "delete_post":
		op.OpType = SNSObjectOpTypeDelete
	case "set_private":
		op.OpType = SNSObjectOpTypeSetPrivacy
	case "set_public":
		op.OpType = SNSObjectOpTypeSetOpen
	case "delete_comment":
		commentID, err := strconv.ParseUint(strings.TrimSpace(req.CommentID), 10, 32)
		if err != nil {
			snsWriteError(w, newSNSError(http.StatusBadRequest, "sns_invalid_request", "comment_id 不是合法的 uint32 十进制字符串"))
			return
		}
		op.OpType = SNSObjectOpTypeDeleteComment
		op.Ext = MarshalSNSObjectOpDeleteComment(SNSObjectOpDeleteComment{CommentID: uint32(commentID)})
	default:
		snsWriteError(w, newSNSError(http.StatusBadRequest, "sns_invalid_request", "op 必须是 delete_post/set_private/set_public/delete_comment"))
		return
	}
	if se := checkSNSWriteRate("objectop"); se != nil {
		snsWriteError(w, se)
		return
	}
	ctx, cancel := snsReadCtx(r, "objectop")
	defer cancel()
	hookResp, err := snsSvc.write(ctx, "objectop", MarshalSNSObjectOpRequest(SNSObjectOpRequest{Ops: []SNSObjectOp{op}}))
	if err != nil {
		snsWriteError(w, err)
		return
	}
	opResp, err := UnmarshalSNSObjectOpResponse(hookResp.Body)
	if err != nil {
		Warn("SNS objectop 回包解析失败", "len", len(hookResp.Body))
		snsWriteError(w, newSNSError(http.StatusBadGateway, "sns_parse_failed", "朋友圈回包解析失败"))
		return
	}
	if err := snsCheckBaseRet(opResp.Base); err != nil {
		snsWriteError(w, err)
		return
	}
	if err := snsCheckOpRets(opResp.OpRetList); err != nil {
		snsWriteError(w, err)
		return
	}
	recordSNSWriteRate("objectop")
	snsWriteOK(w, map[string]any{"op_ret": opResp.OpRetList})
}

// ---- 写操作公共辅助 -------------------------------------------------------

func postIDFromJSON(post snsPostJSON) uint64 {
	id, _ := parseSNSID(post.ID)
	return id
}

// snsInteractionUnavailable 把评论/点赞写通道的 hook 错误换成 App 可行动的语义：
// 0xD5 需要用户先在微信里手动点一次评论或赞以捕获闭包句柄，与「打开朋友圈」
// 的读取 priming 不是同一件事，不能复用 sns_need_prime 的提示。
func snsInteractionUnavailable(err error) error {
	se := snsHTTPError(err)
	switch se.Code {
	case "sns_need_prime", "sns_not_ready":
		e := newSNSError(http.StatusServiceUnavailable, "sns_comment_unavailable",
			"评论/点赞发送句柄未就绪：请先在微信里手动点一次评论或赞，然后重新检测")
		e.HookReason = se.HookReason
		e.RetryAfterSeconds = se.RetryAfterSeconds
		return e
	}
	return se
}

// snsPublishUnavailable 把发布写通道的 hook 错误换成 App 可行动的语义。
// 样本请求体已恢复但 service/closure 句柄失效时 hook 返回 need_prime；
// 发布路径不能复用读路径的「请先打开一次朋友圈」提示，必须按 docs/sns.md §4.6
// 返回 sns_publish_unavailable，App 才会显示「发布通道未就绪」。
func snsPublishUnavailable(err error) error {
	se := snsHTTPError(err)
	switch se.Code {
	case "sns_need_prime", "sns_not_ready":
		e := newSNSError(http.StatusServiceUnavailable, "sns_publish_unavailable",
			"发布通道未就绪（需先捕获发布样本），本次未发送")
		e.HookReason = se.HookReason
		return e
	}
	return se
}

// snsCommentKey 是评论去重键：优先 64 位 comment_id，缺失时退化为
// 「作者 + 正文 + 时间」，避免两条不同评论被误合并。
func snsCommentKey(c snsCommentJSON) string {
	if c.CommentID != "" {
		return "id:" + c.CommentID
	}
	return fmt.Sprintf("txt:%s\x00%s\x00%d", c.UserID, c.Text, c.CreateTime)
}

// snsMergeCommentLists 合并写回包与写前缓存的评论列表：回包顺序优先，缓存里
// 回包没带的旧评论补在后面。回包可能只带新增评论（而不是完整列表），直接覆盖会
// 丢掉旧评论，后续「回复某条评论」就会 404（docs/sns.md §1.4/§5.2）。
func snsMergeCommentLists(updated, previous []snsCommentJSON) []snsCommentJSON {
	if len(previous) == 0 {
		return updated
	}
	merged := make([]snsCommentJSON, 0, len(updated)+len(previous))
	seen := make(map[string]struct{}, len(updated)+len(previous))
	for _, c := range updated {
		merged = append(merged, c)
		seen[snsCommentKey(c)] = struct{}{}
	}
	for _, c := range previous {
		key := snsCommentKey(c)
		if _, dup := seen[key]; dup {
			continue
		}
		seen[key] = struct{}{}
		merged = append(merged, c)
	}
	return merged
}

// snsMergeCachedComments 把缓存里的评论补到刚读到的动态上（timeline / sync 新动态）：
// 原生结果的评论保持原有顺序与字段，缓存中 comment_id 未出现的追加到末尾；
// comment_count 取两者最大值，并按 count > len(comments) 重算 comments_truncated。
// 缓存只补缺、不覆盖原生结果（docs/sns.md §4.2/§4.5）。
func snsMergeCachedComments(native, cached snsPostJSON) snsPostJSON {
	if len(cached.Comments) == 0 {
		return native
	}
	merged := native
	merged.Comments = snsMergeCommentLists(native.Comments, cached.Comments)
	if cached.CommentCount > merged.CommentCount {
		merged.CommentCount = cached.CommentCount
	}
	if merged.CommentCount == 0 && len(merged.Comments) > 0 {
		merged.CommentCount = uint32(len(merged.Comments))
	}
	merged.CommentsTruncated = merged.CommentCount > uint32(len(merged.Comments))
	return merged
}

// snsMergeInteractionPost 合并「评论/点赞」回包的动态与写前缓存。
//
// 微信回包的 SnsObject 可能只带计数或对象摘要（甚至 ObjectDesc 为空）；直接覆盖
// 缓存会丢掉正文/媒体/旧评论，后续「回复某条评论」也会找不到目标。这里按字段
// 回退、按 comment_id 合并评论列表，并按 comment_count > len(comments) 重新计算
// comments_truncated（docs/sns.md §5.2），保持接口语义一致。
func snsMergeInteractionPost(updated, previous snsPostJSON) snsPostJSON {
	merged := updated
	// 写回包对应的就是写前缓存里的那条动态：ID 以写前目标为准（回包可能只带
	// 计数/摘要，甚至 ID 缺省），否则合并结果会写进另一个缓存键。
	if previous.ID != "" {
		merged.ID = previous.ID
	}
	if merged.AuthorID == "" {
		merged.AuthorID = previous.AuthorID
	}
	if merged.AuthorName == "" {
		merged.AuthorName = previous.AuthorName
	}
	if merged.CreateTime == 0 {
		merged.CreateTime = previous.CreateTime
	}
	if merged.Text == "" {
		merged.Text = previous.Text
		merged.TextTruncated = previous.TextTruncated
	}
	if len(merged.Media) == 0 {
		merged.Media = previous.Media
	}
	merged.Comments = snsMergeCommentLists(merged.Comments, previous.Comments)
	if len(merged.Likes) == 0 {
		merged.Likes = previous.Likes
	}
	if merged.LikeCount < previous.LikeCount {
		merged.LikeCount = previous.LikeCount
	}
	if merged.CommentCount < previous.CommentCount {
		merged.CommentCount = previous.CommentCount
	}
	if merged.CommentCount == 0 && len(merged.Comments) > 0 {
		merged.CommentCount = uint32(len(merged.Comments))
	}
	merged.Liked = merged.Liked || previous.Liked
	merged.CommentsTruncated = merged.CommentCount > uint32(len(merged.Comments))
	return merged
}

// snsNewCommentFromResponse 在写回包合并后的评论列表里找出本次提交的新评论。
// 只按「self wxid + 正文完全相同 + 不在写前列表里」匹配；找不到就返回 nil，
// 不猜测服务端返回的其它评论（避免把别人的新评论冒充成自己的）。
func snsNewCommentFromResponse(merged, previous snsPostJSON, selfID, text string) *snsCommentJSON {
	selfID = strings.TrimSpace(selfID)
	text = strings.TrimSpace(text)
	if selfID == "" || text == "" {
		return nil
	}
	known := make(map[string]struct{}, len(previous.Comments))
	for _, c := range previous.Comments {
		if c.CommentID != "" {
			known[c.CommentID] = struct{}{}
		}
	}
	for i := len(merged.Comments) - 1; i >= 0; i-- {
		c := merged.Comments[i]
		if c.UserID != selfID || strings.TrimSpace(c.Text) != text {
			continue
		}
		if _, exists := known[c.CommentID]; exists && c.CommentID != "" {
			continue
		}
		found := c
		return &found
	}
	return nil
}

func snsCheckOpRets(rets []int32) error {
	for _, ret := range rets {
		if ret != 0 {
			e := newSNSError(http.StatusBadGateway, "sns_native_rejected",
				fmt.Sprintf("微信接口返回错误码 %d", ret))
			e.Ret = ret
			return e
		}
	}
	return nil
}

// snsResolveWriteTarget 只允许对读取过的动态做写操作（docs/sns.md §1.4），
// 并解析可选的 reply_comment_id。
func snsResolveWriteTarget(postIDStr, replyCommentID string) (snsPostJSON, *snsCommentJSON, *snsError) {
	id, err := parseSNSID(postIDStr)
	if err != nil {
		return snsPostJSON{}, nil, newSNSError(http.StatusBadRequest, "sns_invalid_request", "post_id 不是合法的 uint64 十进制字符串")
	}
	post, ok := snsSvc.lookupPost(id)
	if !ok {
		return snsPostJSON{}, nil, newSNSError(http.StatusNotFound, "sns_post_not_found", "未找到该动态，请先刷新时间线")
	}
	replyCommentID = strings.TrimSpace(replyCommentID)
	if replyCommentID == "" {
		return post, nil, nil
	}
	for i := range post.Comments {
		if post.Comments[i].CommentID == replyCommentID {
			return post, &post.Comments[i], nil
		}
	}
	return snsPostJSON{}, nil, newSNSError(http.StatusNotFound, "sns_comment_not_found", "未找到被回复的评论")
}

// snsBuildCommentRequest 组装 SnsCommentRequest（评论 Type=2 / 点赞 Type=1）。
func snsBuildCommentRequest(post snsPostJSON, typ uint32, content string, reply *snsCommentJSON) (SNSCommentRequest, *snsError) {
	self := strings.TrimSpace(myWechatId)
	if self == "" {
		return SNSCommentRequest{}, newSNSError(http.StatusServiceUnavailable, "sns_not_ready", "尚未识别当前微信账号")
	}
	postID, err := parseSNSID(post.ID)
	if err != nil {
		return SNSCommentRequest{}, newSNSError(http.StatusBadGateway, "sns_invalid_request", "缓存中的 post_id 无效")
	}
	if strings.TrimSpace(post.AuthorID) == "" {
		return SNSCommentRequest{}, newSNSError(http.StatusNotFound, "sns_post_not_found", "动态作者信息缺失，请先刷新详情")
	}
	// 真机抓包（capture-findings §4.3）里 mac 原生评论请求：
	//   field 3 FromNickname = 自己昵称，field 4 ToNickname = **对方 wxid**（不是昵称），
	//   field 23 = 0。缺 FromNickname 时服务端会静默丢弃（2026-11-08 真机复现：
	//   任务提交 ret=0 但无任何 decoder 回包）。自己通常不在通讯录目录里，因此
	//   评论自己的动态时退回该动态的作者名；其它情况仍用通讯录昵称。
	fromNickname := strings.TrimSpace(contactDisplayName(self))
	if fromNickname == "" && post.AuthorID == self {
		fromNickname = strings.TrimSpace(post.AuthorName)
	}
	action := SNSAction{
		FromUsername: self,
		ToUsername:   post.AuthorID,
		FromNickname: fromNickname,
		ToNickname:   post.AuthorID,
		Type:         typ,
		CreateTime:   uint32(snsNow().Unix()),
		Content:      content,
	}
	if reply != nil {
		replyID, _ := parseSNSID(reply.CommentID)
		action.ReplyCommentID2 = replyID
		if replyID > 0 && replyID <= 0x7fffffff {
			action.ReplyCommentID = int32(replyID)
		}
		// SnsAction 公开 schema 没有独立的 ReplyUsername 字段（field 9 是
		// ReplyCommentId）；回复时把 ToUsername/ToNickname 指向被回复者。
		if reply.UserID != "" {
			action.ToUsername = reply.UserID
			action.ToNickname = reply.UserID
		}
	}
	clientID := fmt.Sprintf("sns_comment:%d_%d_%d", postID, snsNow().Unix(), typ)
	// 真机捕获的评论请求只在 SnsCommentRequest 顶层带 clientId（field 3），
	// SnsActionGroup 内没有 field 5；这里保持与真实任务同构。
	return SNSCommentRequest{
		Action: SNSActionGroup{
			ID:            postID,
			CurrentAction: &action,
		},
		ClientID: clientID,
	}, nil
}

// snsMarshalCommentBody 组装 /sns/comment、/sns/like 的业务 body。
//
// 优先用 hook 捕获的**真实评论请求**做模板：mac 4.2.0.17 的 SnsCommentRequest
// 含公开 schema 之外的字段与 mac 特有取值，自己拼报文时服务端会静默丢弃
// （2026-11-08 真机：任务 ret=0 但 12s 无 decoder 回包）。模板 patch 与发布
// （snsPatchPostRequest）同一策略：保留未知字段，只替换目标/动作/clientId。
// 未捕获模板时退回自拼报文（旧行为）。
func snsMarshalCommentBody(req SNSCommentRequest) []byte {
	if template := snsCapturedSNSBody("comment"); len(template) > 0 {
		if body, err := snsPatchCommentRequest(template, req); err == nil && len(body) > 0 {
			return body
		}
	}
	// 真机 4.2.0.17 实测：自拼报文会让服务端静默丢弃（任务 ret=0、12s 无回包）。
	// 退回旧行为只为不改变协议面，日志提示用户先在微信里手动评论一次以捕获模板。
	Warn("SNS 评论缺少真实请求模板，退回自拼报文（服务端可能静默丢弃）")
	return MarshalSNSCommentRequest(req)
}

package main

// sns.db 只读评论补全（P1）：SnsMessage_tmp3 是朋友圈消息/评论表，好友对机器人
// 评论的回复正文常只在这里（timeline 回包缺）。Hook 按 signed feed_id 批量查行，
// bridge 映射成 snsCommentJSON 后补到 timeline 结果（原生优先、只补缺）。
//
// 隐私：只读、只取评论正文；不返回/打印 key；日志只记条数/耗时。
// 开关：snsDbRead=true 或 snsProbe=true；失败静默降级，不影响聊天/其它功能。

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"
)

const (
	// 一次 timeline 最多批量查 50 条动态（与 limit 上限一致）。
	snsDbCommentsMaxFeedIDs = 50
)

// snsDbCommentRow 对应 hook snsDbComments 返回的一行（字段已脱敏）。
type snsDbCommentRow struct {
	FeedID                  string `json:"feed_id"`
	Content                 string `json:"content"`
	FromUsername            string `json:"from_username"`
	FromNickname            string `json:"from_nickname"`
	ToUsername              string `json:"to_username"`
	ToNickname              string `json:"to_nickname"`
	CreateTime              int64  `json:"create_time"`
	CommentID               string `json:"comment_id"`
	Comment64ID             string `json:"comment64_id"`
	Type                    int    `json:"type"`
	IsRelativeMe            int    `json:"is_relative_me"`
	DelStatus               int    `json:"del_status"`
	SerializedCommentBufHex string `json:"serialized_comment_buf_hex"`
	SerializedRefBufHex     string `json:"serialized_ref_buf_hex"`
}

// snsDbCommentsResult 是 hook snsDbComments 的回包。
type snsDbCommentsResult struct {
	OK          bool                  `json:"ok"`
	Reason      string                `json:"reason,omitempty"`
	Message     string                `json:"message,omitempty"`
	GeneratedAt int64                 `json:"generated_at,omitempty"`
	Count       int                   `json:"count,omitempty"`
	Truncated   bool                  `json:"truncated,omitempty"`
	Rows        []snsDbCommentRow     `json:"rows,omitempty"`
	KeyStatus   map[string]any        `json:"key_status,omitempty"`
	Keys        map[string]ContactKey `json:"keys,omitempty"`
}

// snsDbSignedFeedID 把 OneBot/微信的无符号动态 ID 十进制字符串转成 SQLite
// feed_id 的 64 位有符号十进制（uint64 - 2^64）。SQLite INTEGER 是有符号的，
// 直接用 uint64 查会永远无行。
func snsDbSignedFeedID(postID string) (string, bool) {
	id, err := parseSNSID(postID)
	if err != nil {
		return "", false
	}
	return strconv.FormatInt(int64(id), 10), true
}

func snsDbCommentsEnabled() bool {
	// timeline 评论补全是 SNS 读链路的一部分：snsEnable=true 时默认启用；
	// snsDbRead=true 让「只读 DB、不开原生 SNS 通道」时也能用；snsProbe 为排障强制。
	// /sns/db/* 探针入口仍只认 snsProbe/snsDbRead。
	return snsDbReadEnabled() || snsProbeEnabled() || snsReadEnabled()
}

// fetchSNSDbComments 批量取评论。返回 postID（无符号十进制）→ 评论列表，
// 以及原始行数（仅用于日志）。失败返回 error，由调用方静默降级。
func fetchSNSDbComments(postIDs []string) (map[string][]snsCommentJSON, int, error) {
	if !snsDbCommentsEnabled() || len(postIDs) == 0 {
		return nil, 0, nil
	}
	dbStoragePath := deriveDBStoragePath(config.ImagePath)
	if dbStoragePath == "" {
		return nil, 0, errContactPathUnknown
	}
	signedToPost := make(map[string]string, len(postIDs))
	signedIDs := make([]string, 0, len(postIDs))
	seen := make(map[string]struct{}, len(postIDs))
	for _, postID := range postIDs {
		if len(signedIDs) >= snsDbCommentsMaxFeedIDs {
			break
		}
		signed, ok := snsDbSignedFeedID(postID)
		if !ok {
			continue
		}
		if _, dup := seen[signed]; dup {
			continue
		}
		seen[signed] = struct{}{}
		signedToPost[signed] = postID
		signedIDs = append(signedIDs, signed)
	}
	if len(signedIDs) == 0 {
		return nil, 0, nil
	}
	idsJSON, err := json.Marshal(signedIDs)
	if err != nil {
		return nil, 0, err
	}
	raw, err := callFridaExport("snsDbComments", dbStoragePath, string(idsJSON))
	if err != nil {
		return nil, 0, err
	}
	text, err := contactRPCResultString(raw)
	if err != nil {
		return nil, 0, err
	}
	var result snsDbCommentsResult
	if err := json.Unmarshal([]byte(text), &result); err != nil {
		return nil, 0, fmt.Errorf("sns.db 评论回包解析失败: %w", err)
	}
	if len(result.Keys) > 0 {
		if err := persistContactDBKeysMerged(result.Keys); err != nil {
			Warn("SNS DB key 缓存写入失败", "err", err)
		}
	}
	if !result.OK {
		reason := strings.TrimSpace(result.Reason)
		if reason == "" {
			reason = "unknown"
		}
		return nil, 0, fmt.Errorf("sns.db 评论不可用: %s", reason)
	}
	commentsByPost := make(map[string][]snsCommentJSON, len(result.Rows))
	for _, row := range result.Rows {
		postID, ok := signedToPost[strings.TrimSpace(row.FeedID)]
		if !ok {
			continue
		}
		comment, ok := snsDbCommentFromRow(row)
		if !ok {
			continue
		}
		commentsByPost[postID] = append(commentsByPost[postID], comment)
	}
	return commentsByPost, len(result.Rows), nil
}

// snsDbCommentFromRow 把 SnsMessage_tmp3 行映射为 timeline 评论 JSON。
// 只接受 type=2（评论）且 del_status=0 的行；正文/作者/时间缺失时用
// serialized_comment_buf（SnsAction protobuf）补齐，仍缺失则丢弃（不猜测）。
// reply_to 先留空：comment_id=35 的语义尚未确认，避免 App 用错目标回复。
func snsDbCommentFromRow(row snsDbCommentRow) (snsCommentJSON, bool) {
	if row.DelStatus != 0 || row.Type != 2 {
		return snsCommentJSON{}, false
	}
	text := row.Content
	fromUser := strings.TrimSpace(row.FromUsername)
	fromName := strings.TrimSpace(row.FromNickname)
	toUser := strings.TrimSpace(row.ToUsername)
	toName := strings.TrimSpace(row.ToNickname)
	createTime := row.CreateTime
	if action := snsDbParseActionBuf(row.SerializedCommentBufHex); action != nil {
		if strings.TrimSpace(text) == "" {
			text = action.Content
		}
		if fromUser == "" {
			fromUser = strings.TrimSpace(action.FromUsername)
		}
		if fromName == "" {
			fromName = strings.TrimSpace(action.FromNickname)
		}
		if toUser == "" {
			toUser = strings.TrimSpace(action.ToUsername)
		}
		if toName == "" {
			toName = strings.TrimSpace(action.ToNickname)
		}
		if createTime == 0 {
			createTime = int64(action.CreateTime)
		}
	}
	if strings.TrimSpace(text) == "" {
		return snsCommentJSON{}, false
	}
	commentID := ""
	idConfirmed := false
	if id := strings.TrimSpace(row.Comment64ID); id != "" && id != "0" {
		// 64 位评论 ID 是服务端语义，可作为回复目标。
		commentID = id
		idConfirmed = true
	} else if id := strings.TrimSpace(row.CommentID); id != "" && id != "0" {
		// 32 位列（真机 35）经手动回复抓包确认：微信手动回复 A 的 reply 时
		// 请求 ReplyCommentID=35，服务端接受并生成新评论（reply_to=A）。
		// 因此 4.2.0.17 的 SnsMessage_tmp3.comment_id 可作为 reply_comment_id；
		// 仍保留 comment_id_unconfirmed 字段给旧 App/未来 schema 变化时回退。
		commentID = id
		idConfirmed = true
	}
	if fromName == "" && fromUser != "" {
		fromName = contactDisplayName(fromUser)
	}
	if toName == "" && toUser != "" {
		toName = contactDisplayName(toUser)
	}
	comment := snsCommentJSON{
		CommentID:     commentID,
		UserID:        fromUser,
		UserName:      fromName,
		Text:          text,
		CreateTime:    createTime,
		ReplyTo:       "",
		ReplyToUserID: toUser,
		ReplyToName:   toName,
	}
	if commentID != "" {
		comment.Source = "db"
		comment.CommentIDConfirmed = idConfirmed
	}
	return comment, true
}

// snsDbParseActionBuf 解析 SnsMessage_tmp3.serialized_comment_buf（SnsAction）。
// 解析失败返回 nil，不影响列字段。
func snsDbParseActionBuf(hexStr string) *SNSAction {
	hexStr = strings.TrimSpace(hexStr)
	if hexStr == "" {
		return nil
	}
	data, err := hex.DecodeString(hexStr)
	if err != nil || len(data) == 0 {
		return nil
	}
	action, err := UnmarshalSNSAction(data)
	if err != nil {
		return nil
	}
	return action
}

// snsMergeDbCommentLists 把 DB 评论补到原生评论后。
// 注意不能直接复用 snsCommentKey：SnsMessage_tmp3.comment_id 是未确认语义的
// 32 位本地/父评论 ID（真机两行都是 35），同一帖子下多条回复可能共用它；
// 只用 comment_id 去重会把不同正文的第二条回复丢掉。这里用
// comment_id+user_id+text+create_time 组合键：同步重放产生的完全重复行去重，
// 不同正文/时间的回复都保留。原生评论顺序与字段不变。
func snsMergeDbCommentLists(native, comments []snsCommentJSON) []snsCommentJSON {
	if len(comments) == 0 {
		return native
	}
	merged := make([]snsCommentJSON, 0, len(native)+len(comments))
	seen := make(map[string]struct{}, len(native)+len(comments))
	for _, c := range native {
		merged = append(merged, c)
		seen[snsDbCommentMergeKey(c)] = struct{}{}
	}
	for _, c := range comments {
		key := snsDbCommentMergeKey(c)
		if _, dup := seen[key]; dup {
			continue
		}
		seen[key] = struct{}{}
		merged = append(merged, c)
	}
	return merged
}

func snsDbCommentMergeKey(c snsCommentJSON) string {
	return c.CommentID + "\x00" + c.UserID + "\x00" + c.Text + "\x00" + strconv.FormatInt(c.CreateTime, 10)
}

// mergeSNSDbComments 在 timeline 结果（已按 limit 截断）上补 DB 评论：
// 原生/缓存评论保持在前，DB 评论按 comment_id 去重追加；count 取 max 并重算
// comments_truncated。失败静默返回原 posts。
func mergeSNSDbComments(posts []snsPostJSON) []snsPostJSON {
	if len(posts) == 0 || !snsDbCommentsEnabled() {
		return posts
	}
	postIDs := make([]string, 0, len(posts))
	for i := range posts {
		if strings.TrimSpace(posts[i].ID) != "" {
			postIDs = append(postIDs, posts[i].ID)
		}
	}
	started := time.Now()
	commentsByPost, rowCount, err := fetchSNSDbComments(postIDs)
	if err != nil {
		Debug("SNS DB 评论补全跳过", "reason", err.Error())
		return posts
	}
	mergedComments := 0
	for i := range posts {
		comments := commentsByPost[posts[i].ID]
		if len(comments) == 0 {
			continue
		}
		merged := snsMergeDbCommentLists(posts[i].Comments, comments)
		added := len(merged) - len(posts[i].Comments)
		if added <= 0 {
			continue
		}
		posts[i].Comments = merged
		if posts[i].CommentCount < uint32(len(comments)) {
			posts[i].CommentCount = uint32(len(comments))
		}
		if posts[i].CommentCount == 0 && len(merged) > 0 {
			posts[i].CommentCount = uint32(len(merged))
		}
		posts[i].CommentsTruncated = posts[i].CommentCount > uint32(len(merged))
		mergedComments += added
	}
	if rowCount > 0 {
		Info("SNS DB 评论补全", "posts", len(posts), "rows", rowCount,
			"comments", mergedComments, "elapsed_ms", time.Since(started).Milliseconds())
	}
	return posts
}

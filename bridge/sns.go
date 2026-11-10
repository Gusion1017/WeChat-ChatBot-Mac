package main

// 朋友圈（SNS）客户端状态层：开关、Hook RPC 接口、超时/并发/限流与只读缓存。
//
// 契约见 docs/sns.md：
//   - RPC 返回 JSON 字符串；错误统一 {ok:false,error,message}；
//   - 单次请求默认 8s（同步/详情 12s），超时不重试；
//   - 同一账号同一时刻最多 1 个读取请求，写请求串行；
//   - 未启用 → 404，未授权 → 401，微信未就绪 → 503。
//
// Hook 侧导出名：snsStatus / snsPrime / snsRequest / snsMedia（docs/sns.md §3）。
// 本文件的生产实现通过 callFridaExport 调用它们；测试注入 SNSRPC fake，
// 不连接微信/Frida。

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ---- 开关 -----------------------------------------------------------------

// snsFeatures 由微信版本 JSON 的 snsEnable / snsWrite 控制（App 运行期生成，
// 仓库默认 false）。未启用时所有 /sns/* 返回 404。
type snsFeatureState struct {
	mu       sync.RWMutex
	read     bool
	write    bool
	probe    bool
	dbRead   bool
	readMode string
}

var snsFeatures snsFeatureState

// initSNSConfig 从 -wechat_conf 指向的 hook 配置读取 SNS 开关。
// 只读取开关，不做任何微信侧操作；文件缺失/格式错误时保持关闭（bridge 随后
// 的 loadJs 会因同一文件失败而退出，因此这里只 Debug）。
func initSNSConfig() {
	read, write, probe, dbRead, readMode := false, false, false, false, ""
	policy := defaultSNSPolicy()
	if strings.TrimSpace(config.WechatConf) != "" {
		if data, err := os.ReadFile(config.WechatConf); err == nil {
			var raw map[string]any
			if json.Unmarshal(data, &raw) == nil {
				read = snsConfigBool(raw, "snsEnable")
				write = snsConfigBool(raw, "snsWrite")
				probe = snsConfigBool(raw, "snsProbe")
				dbRead = snsConfigBool(raw, "snsDbRead")
				if v, ok := raw["snsReadMode"].(string); ok {
					readMode = strings.TrimSpace(v)
				}
				policy = parseSNSPolicy(raw)
			} else {
				Debug("SNS 开关解析失败，保持关闭")
			}
		}
	}
	snsFeatures.mu.Lock()
	snsFeatures.read = read
	snsFeatures.write = write
	snsFeatures.probe = probe
	snsFeatures.dbRead = dbRead
	snsFeatures.readMode = readMode
	snsFeatures.mu.Unlock()
	setSNSPolicyForTest(policy)
	Info("SNS 功能开关", "read", read, "write", write,
		"post_min_interval", policy.PostMinInterval.String(),
		"post_daily_limit", policy.PostDailyLimit,
		"post_windows", len(policy.PostWindows))
}

func snsConfigBool(raw map[string]any, key string) bool {
	v, ok := raw[key]
	if !ok {
		return false
	}
	switch t := v.(type) {
	case bool:
		return t
	case string:
		s := strings.TrimSpace(t)
		return strings.EqualFold(s, "true") || s == "1"
	case float64:
		return t != 0
	default:
		return false
	}
}

func snsReadEnabled() bool {
	snsFeatures.mu.RLock()
	defer snsFeatures.mu.RUnlock()
	return snsFeatures.read
}

// snsProbeEnabled 只用于调试注入（例如真实抓包 body replay）；默认 false。
func snsProbeEnabled() bool {
	snsFeatures.mu.RLock()
	defer snsFeatures.mu.RUnlock()
	return snsFeatures.probe
}

// setSNSProbeForTest 仅供单元测试切换 probe（调试抓包）开关。
func setSNSProbeForTest(probe bool) {
	snsFeatures.mu.Lock()
	snsFeatures.probe = probe
	snsFeatures.mu.Unlock()
}

// snsPassiveReadMode 表示读取只走 hook 缓存（用户手动打开朋友圈时捕获），
// 不尝试主动 R3 发送。仅版本 JSON 手工配置 `snsReadMode="passive"` 时生效：
// App 在功能开启时下发 `native`（未捕获请求体时由 bridge 自动回退缓存）。
func snsPassiveReadMode() bool {
	return snsReadMode() == "passive"
}

// snsReadMode 返回 snsReadMode 配置值（native/passive/空）。
func snsReadModeLabel() string {
	mode := strings.TrimSpace(snsReadMode())
	if mode == "" {
		return "native"
	}
	return mode
}

func snsReadMode() string {
	snsFeatures.mu.RLock()
	defer snsFeatures.mu.RUnlock()
	return snsFeatures.readMode
}

// setSNSReadModeForTest 仅供单元测试切换读模式（避免启动 main）。
func setSNSReadModeForTest(mode string) {
	snsFeatures.mu.Lock()
	snsFeatures.readMode = mode
	snsFeatures.mu.Unlock()
}

func snsWriteEnabled() bool {
	snsFeatures.mu.RLock()
	defer snsFeatures.mu.RUnlock()
	return snsFeatures.write
}

// snsDbReadEnabled 是 sns.db 只读兜底的显式开关（版本 JSON snsDbRead）。
// 默认关闭；snsProbe=true 时也允许探针调用，便于真机诊断。
func snsDbReadEnabled() bool {
	snsFeatures.mu.RLock()
	defer snsFeatures.mu.RUnlock()
	return snsFeatures.dbRead
}

// setSNSFeaturesForTest 仅供单元测试切换开关（避免启动 main）。
func setSNSFeaturesForTest(read, write bool) {
	snsFeatures.mu.Lock()
	snsFeatures.read = read
	snsFeatures.write = write
	snsFeatures.mu.Unlock()
}

// setSNSDbReadForTest 仅供单元测试切换 sns.db 兜底开关。
func setSNSDbReadForTest(enabled bool) {
	snsFeatures.mu.Lock()
	snsFeatures.dbRead = enabled
	snsFeatures.mu.Unlock()
}

// ---- 错误码 ---------------------------------------------------------------

// snsError 是可直接映射到 HTTP 的错误。Code 使用 docs/sns.md 的 sns_* 命名，
// Message 只放固定中文文案（绝不拼接朋友圈正文/wxid/密钥）。
type snsError struct {
	Status            int
	Code              string
	Message           string
	HookReason        string
	Ret               int32
	RetryAfterSeconds int
}

func (e *snsError) Error() string {
	if e.HookReason != "" {
		return fmt.Sprintf("%s: %s (%s)", e.Code, e.Message, e.HookReason)
	}
	return fmt.Sprintf("%s: %s", e.Code, e.Message)
}

func newSNSError(status int, code, message string) *snsError {
	return &snsError{Status: status, Code: code, Message: message}
}

// snsErrorFromHook 把 hook 的 error code 映射为 bridge 错误码/HTTP 状态。
func snsErrorFromHook(reason, message string) *snsError {
	r := strings.ToLower(strings.TrimSpace(reason))
	e := &snsError{HookReason: r}
	switch r {
	case "need_prime", "open_moments_once", "not_primed", "no_seed", "need_open_moments":
		e.Status, e.Code, e.Message = 503, "sns_need_prime", "请先在微信打开一次朋友圈以捕获发送上下文"
	case "not_implemented", "media_not_implemented":
		e.Status, e.Code, e.Message = 503, "sns_media_unavailable", "朋友圈媒体通道尚未实现"
	case "sns_disabled", "disabled":
		e.Status, e.Code, e.Message = 404, "sns_disabled", "朋友圈原生通道未启用"
	case "unsupported":
		e.Status, e.Code, e.Message = 503, "sns_unsupported", "当前 Hook 版本不支持朋友圈"
	case "not_configured":
		e.Status, e.Code, e.Message = 503, "sns_channel_unconfigured", "当前 Hook 版本未配置该朋友圈任务的发送锚点"
	case "not_ready", "seed_missing", "seed_not_ready", "priming", "not_logged_in":
		e.Status, e.Code, e.Message = 503, "sns_not_ready", "朋友圈通道未就绪，请先在微信打开一次朋友圈"
	case "timeout", "response_timeout", "sns_timeout":
		e.Status, e.Code, e.Message = 504, "sns_timeout", "朋友圈请求超时"
	case "parse_failed", "parse_error":
		e.Status, e.Code, e.Message = 502, "sns_parse_failed", "朋友圈回包解析失败"
	case "native_rejected", "server_rejected":
		e.Status, e.Code, e.Message = 502, "sns_native_rejected", "微信接口拒绝了朋友圈请求"
	case "invalid_param", "bad_request", "unsupported_op", "unknown_op":
		e.Status, e.Code, e.Message = 400, "sns_invalid_request", "朋友圈请求参数无效"
	case "publish_disabled", "write_disabled":
		e.Status, e.Code, e.Message = 403, "sns_write_disabled", "朋友圈写操作未开启"
	case "media_unavailable":
		e.Status, e.Code, e.Message = 503, "sns_media_unavailable", "朋友圈媒体通道未就绪"
	case "send_failed", "closure_failed", "task_build_failed", "proto_missing", "send_exception":
		e.Status, e.Code, e.Message = 502, "sns_send_failed", "朋友圈请求发送失败"
	default:
		e.Status, e.Code, e.Message = 502, "sns_hook_error", "朋友圈请求失败"
	}
	// hook 返回的 message 可能含内部细节，只用于日志，不下发 App。
	return e
}

// snsHTTPError 把任意 error 归一化为 HTTP 错误。
func snsHTTPError(err error) *snsError {
	var se *snsError
	if errors.As(err, &se) {
		return se
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return newSNSError(504, "sns_timeout", "朋友圈请求超时")
	}
	if errors.Is(err, context.Canceled) {
		return newSNSError(504, "sns_timeout", "朋友圈请求已取消")
	}
	return newSNSError(502, "sns_hook_error", "朋友圈请求失败")
}

// ---- Hook RPC 接口 --------------------------------------------------------

// SNSHookStatus 对应 hook snsStatus 的返回（docs/sns.md §3）。
type SNSHookStatus struct {
	OK         bool
	Ready      bool
	SeedReady  bool
	WriteReady bool
	// CommentReady 表示 hook 已捕获评论/点赞任务（0xD5）的闭包句柄；
	// 与 WriteReady（发布 post 样本）相互独立，二者缺一都不能写。
	CommentReady bool
	// TimelineBodyReady 表示 hook 已捕获 timeline 的**真实请求体**（bodyLen>0）。
	// Captured 只统计「捕获到的任务类型数」：4.2.0.12 等缺 bodyReturn 锚点的版本
	// 会出现 Captured>0 但没有任何请求体，此时主动刷新不可用、只能读被动缓存。
	TimelineBodyReady bool
	Captured          int
	LastError         string
}

// SNSPrimeResult 对应 snsPrime。
type SNSPrimeResult struct {
	OK       bool
	Captured int
	Ops      []string
}

// SNSHookResponse 是一次 snsRequest 的原始结果（business protobuf）。
type SNSHookResponse struct {
	Body      []byte
	ElapsedMS int64
	Ret       *int32
}

// SNSMediaRequest 对应 snsMedia 的下载/状态参数。
type SNSMediaRequest struct {
	Action string
	Key    string
	Kind   string // image|thumb
	PostID string
	Path   string
}

// SNSMediaResult 对应 snsMedia 返回。
type SNSMediaResult struct {
	OK    bool
	File  string
	Error string
}

// SNSRPC 是可注入的 hook RPC 边界。生产实现 fridaSNSPRC 走 Frida 导出；
// 单元测试注入 fake，不接触微信进程。
type SNSRPC interface {
	Status(ctx context.Context) (SNSHookStatus, error)
	Prime(ctx context.Context, seconds int) (SNSPrimeResult, error)
	Request(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error)
	Media(ctx context.Context, req SNSMediaRequest) (SNSMediaResult, error)
}

// snsRPC 是当前使用的实现（包级变量便于测试替换）。
var snsRPC SNSRPC = fridaSNSPRC{}

// snsCallFrida 是 Frida 导出调用封装（包级变量，测试可替换为本地假实现）。
var snsCallFrida = func(fn string, args ...any) (any, error) {
	return callFridaExport(fn, args...)
}

// ---- 捕获样本持久化（bridge 重启不丢 service/closure/body） ----------------

var (
	snsCapturePersistMu sync.Mutex
	snsCaptureRestored  bool
	// snsCaptureRestoreAt 是上次 import 尝试的时间：hook 尚未就绪（脚本未加载/微信进程
	// 重建中）时保留「未恢复」状态并按固定间隔重试，避免第一次 /sns/* 请求恰好早于
	// hook 初始化就让持久化样本永久不恢复。
	snsCaptureRestoreAt time.Time
	// snsCapturePersistAt 是上次导出尝试的时间：App 打开「捕获发送句柄」弹窗时约 1s
	// 轮询一次 /sns/status，这里做最小间隔节流，避免高频 Frida 导出。
	snsCapturePersistAt time.Time
	// snsCaptureLastJSON 是上次成功落盘的样本签名（不含每次导出都会变化的 pid/时间戳）。
	snsCaptureLastJSON string
)

const (
	snsCaptureFileMaxBytes       = 1 << 20
	snsCaptureRestoreRetryDelay  = 5 * time.Second
	snsCapturePersistMinInterval = 2 * time.Second
)

// snsCaptureStatePath 返回样本文件路径（账号目录，0600，仅本机）。
// 目录由 media_dir 推导：`<account>/media` → `<account>/sns-capture.json`。
func snsCaptureStatePath() string {
	mediaDir := snsMediaDir()
	if mediaDir == "" {
		return ""
	}
	return filepath.Join(filepath.Dir(mediaDir), "sns-capture.json")
}

// markSNSCaptureRestored 记录「本次 bridge 生命周期内不再尝试恢复」。
func markSNSCaptureRestored() {
	snsCapturePersistMu.Lock()
	snsCaptureRestored = true
	snsCapturePersistMu.Unlock()
}

// snsRestoreCaptureState 在 bridge 启动后尝试恢复上一次捕获的 SNS 样本。
// 只在同一微信进程内有效：hook 会校验 Process.id 与模块基址，指针无效时不恢复。
//
// 只有 hook 给出确定结果（成功/进程已变/指针失效）才标记为「已恢复」；
// hook 暂时不可用（脚本未加载、微信进程重建中）时保留未恢复状态，下一个 /sns/*
// 请求按 snsCaptureRestoreRetryDelay 重试，避免一次失败就永久丢失持久化样本。
func snsRestoreCaptureState() {
	path := snsCaptureStatePath()
	if path == "" {
		return
	}
	now := snsNow()
	snsCapturePersistMu.Lock()
	if snsCaptureRestored {
		snsCapturePersistMu.Unlock()
		return
	}
	if !snsCaptureRestoreAt.IsZero() && now.Sub(snsCaptureRestoreAt) < snsCaptureRestoreRetryDelay {
		snsCapturePersistMu.Unlock()
		return
	}
	// 先登记尝试时间：并发请求不会同时触发 import；hook 未就绪时按间隔重试。
	snsCaptureRestoreAt = now
	snsCapturePersistMu.Unlock()

	raw, err := os.ReadFile(path)
	if err != nil || len(raw) == 0 || len(raw) > snsCaptureFileMaxBytes {
		// 没有可恢复的样本文件：本次进程内无需再试。
		markSNSCaptureRestored()
		return
	}
	out, err := snsCallFrida("snsImportCapture", string(raw))
	if err != nil {
		Warn("SNS 样本恢复失败（hook 尚未就绪，稍后重试）")
		return
	}
	var payload struct {
		OK       bool     `json:"ok"`
		Restored []string `json:"restored"`
		Error    string   `json:"error"`
	}
	if err := json.Unmarshal([]byte(fmt.Sprint(out)), &payload); err != nil {
		Warn("SNS 样本恢复失败（返回不可解析）")
		markSNSCaptureRestored()
		return
	}
	if !payload.OK {
		Info("SNS 样本未恢复", "reason", payload.Error)
		markSNSCaptureRestored()
		return
	}
	markSNSCaptureRestored()
	if len(payload.Restored) > 0 {
		Info("SNS 捕获样本已恢复", "types", len(payload.Restored))
	} else {
		Info("SNS 样本恢复为空（指针失效或类型不匹配）")
	}
}

// snsPersistCaptureState 把 hook 当前捕获导出到账号目录（原子写，0600）。
// 内容含真实请求体（ClientCheckDat 等），只允许本机用户读取，不写日志。
//
// force=false 时按 snsCapturePersistMinInterval 节流（/sns/status 会被 App 以约 1s
// 轮询），发布成功等关键路径传 true 立即落盘。内容未变化时（hook 每次导出都会带新的
// pid/exportedAt）不重复写盘。
func snsPersistCaptureState(force bool) {
	path := snsCaptureStatePath()
	if path == "" {
		return
	}
	now := snsNow()
	snsCapturePersistMu.Lock()
	if !force && !snsCapturePersistAt.IsZero() &&
		now.Sub(snsCapturePersistAt) < snsCapturePersistMinInterval {
		snsCapturePersistMu.Unlock()
		return
	}
	snsCapturePersistAt = now
	snsCapturePersistMu.Unlock()

	out, err := snsCallFrida("snsExportCapture")
	if err != nil {
		return
	}
	stateJSON := fmt.Sprint(out)
	var payload struct {
		OK      bool                       `json:"ok"`
		Records map[string]json.RawMessage `json:"records"`
		Bodies  map[string]json.RawMessage `json:"bodies"`
		Seeds   map[string]json.RawMessage `json:"seeds"`
	}
	if err := json.Unmarshal([]byte(stateJSON), &payload); err != nil || !payload.OK {
		return
	}
	// 不要用空状态覆盖已有的有效样本（bridge 刚启动、hook 尚未捕获时会出现）。
	// 没有任何 record 时整份样本不可恢复（hook import 只按 record 恢复 service/seed），
	// 即使有 body 也不落盘，避免覆盖上一次仍可恢复的样本。
	if len(payload.Records) == 0 {
		return
	}
	// 只比较样本内容：hook 每次导出都带新的 exportedAt/pid，比较原文会永远不相等。
	signature := mustJSONString(map[string]any{
		"records": payload.Records,
		"bodies":  payload.Bodies,
		"seeds":   payload.Seeds,
	})
	snsCapturePersistMu.Lock()
	defer snsCapturePersistMu.Unlock()
	if signature == snsCaptureLastJSON {
		return
	}
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(stateJSON), 0o600); err != nil {
		return
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return
	}
	snsCaptureLastJSON = signature
}

// resetSNSCaptureRestoreForTest 仅供测试重置「只恢复一次」与节流状态。
func resetSNSCaptureRestoreForTest() {
	snsCapturePersistMu.Lock()
	snsCaptureRestored = false
	snsCaptureRestoreAt = time.Time{}
	snsCapturePersistAt = time.Time{}
	snsCaptureLastJSON = ""
	snsCapturePersistMu.Unlock()
}

// setSNSRPCForTest 仅供单元测试注入 fake RPC。
func setSNSRPCForTest(rpc SNSRPC) { snsRPC = rpc }

func currentSNSRPC() SNSRPC { return snsRPC }

// fridaSNSPRC 是生产实现：把参数序列化为 JSON 字符串传给 hook 导出，
// 并遵守 ctx 超时（callFridaExport 自身有 15s 上限，这里用 goroutine +
// select 让 bridge 能在 8/12s 时先返回，避免 App 长时间挂起）。
type fridaSNSPRC struct{}

func (fridaSNSPRC) call(ctx context.Context, fn string, args ...any) (any, error) {
	type callResult struct {
		value any
		err   error
	}
	ch := make(chan callResult, 1)
	go func() {
		v, err := snsCallFrida(fn, args...)
		ch <- callResult{value: v, err: err}
	}()
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case r := <-ch:
		return r.value, r.err
	}
}

// decodeSNSHookJSON 兼容 hook 返回 JSON 字符串 / 字节 / 已反序列化对象。
func decodeSNSHookJSON(raw any, out any) error {
	switch v := raw.(type) {
	case nil:
		return errors.New("hook 返回为空")
	case string:
		if strings.TrimSpace(v) == "" {
			return errors.New("hook 返回为空")
		}
		return json.Unmarshal([]byte(v), out)
	case []byte:
		return json.Unmarshal(v, out)
	default:
		b, err := json.Marshal(v)
		if err != nil {
			return err
		}
		return json.Unmarshal(b, out)
	}
}

func snsMapString(m map[string]any, keys ...string) string {
	for _, k := range keys {
		if v, ok := m[k]; ok {
			if s, ok := v.(string); ok {
				return s
			}
		}
	}
	return ""
}

func snsMapBool(m map[string]any, keys ...string) bool {
	for _, k := range keys {
		v, ok := m[k]
		if !ok {
			continue
		}
		switch t := v.(type) {
		case bool:
			return t
		case string:
			return strings.EqualFold(t, "true") || t == "1"
		case float64:
			return t != 0
		}
	}
	return false
}

func snsMapInt64(m map[string]any, keys ...string) int64 {
	for _, k := range keys {
		v, ok := m[k]
		if !ok {
			continue
		}
		switch t := v.(type) {
		case float64:
			return int64(t)
		case int64:
			return t
		case int:
			return int64(t)
		case string:
			var n int64
			if _, err := fmt.Sscan(t, &n); err == nil {
				return n
			}
		}
	}
	return 0
}

// Status 兼容两版 hook 返回：
//   - 新（2026-11-07 hook 已实现）：{enabled, probe, captured, anchors, pending, lastError}
//   - 旧/文档：{ok, ready, seedReady, writeReady, lastError}
//
// 新版本没有显式 ready：enabled && captured>0 视为可读；anchors 里出现 post/comment
// 才认为写通道可能就绪（保守，不做乐观判断）。
func (r fridaSNSPRC) Status(ctx context.Context) (SNSHookStatus, error) {
	raw, err := r.call(ctx, "snsStatus")
	if err != nil {
		return SNSHookStatus{}, err
	}
	var m map[string]any
	if err := decodeSNSHookJSON(raw, &m); err != nil {
		return SNSHookStatus{}, fmt.Errorf("snsStatus 返回无法解析: %w", err)
	}
	lastError := snsMapString(m, "lastError", "last_error", "error")
	if reason := snsMapString(m, "reason"); reason != "" && lastError == "" {
		lastError = reason
	}
	st := SNSHookStatus{
		OK:           snsMapBool(m, "ok"),
		Ready:        snsMapBool(m, "ready"),
		SeedReady:    snsMapBool(m, "seedReady", "seed_ready"),
		WriteReady:   snsMapBool(m, "writeReady", "write_ready"),
		CommentReady: snsMapBool(m, "commentReady", "comment_ready", "interactionReady", "interaction_ready"),
		LastError:    lastError,
	}
	// 新字段优先覆盖旧语义。
	if _, ok := m["captured"]; ok || m["enabled"] != nil {
		captured := int(snsMapInt64(m, "captured"))
		enabled := snsMapBool(m, "enabled")
		st.Captured = captured
		st.OK = true
		// 显式字段优先（hook 已按 seed 真实状态给出）；旧 hook 才回退启发式。
		if _, has := m["ready"]; has {
			st.Ready = snsMapBool(m, "ready")
		} else {
			st.Ready = enabled && captured > 0
		}
		if _, has := m["seedReady"]; has {
			st.SeedReady = snsMapBool(m, "seedReady")
		} else {
			st.SeedReady = captured > 0
		}
		if _, has := m["writeReady"]; has {
			st.WriteReady = snsMapBool(m, "writeReady")
		} else {
			st.WriteReady = snsAnchorsHave(m["anchors"], "post") || snsAnchorsHave(m["anchors"], "comment")
		}
		// 评论/点赞句柄：新 hook 显式返回 commentReady；没有该字段时按
		// 顶层 mmsnscomment 捕获记录的 hasSeed 回退（旧 hook 没有此字段则为 false，
		// 不做乐观判断——没捕获到 0xD5 闭包时评论一定发不出去）。
		if _, has := m["commentReady"]; !has {
			if _, hasAlt := m["comment_ready"]; !hasAlt {
				st.CommentReady = snsStatusOpSeedReady(m, "mmsnscomment")
			}
		}
		// 请求体是否真的捕获到（主动刷新/发布模板都依赖它）。captured 只数任务类型，
		// 缺 bodyReturn 锚点的版本（如 4.2.0.12）captured>0 但没有 body。
		st.TimelineBodyReady = snsStatusOpBodyReady(m, "mmsnstimeline")
	}
	if !st.OK && st.LastError != "" {
		return st, snsErrorFromHook(st.LastError, snsMapString(m, "message"))
	}
	return st, nil
}

// snsStatusOpBodyReady 读取 hook snsStatus 里某个 SNS op 的捕获记录是否已拿到真实请求体。
// hook 顶层形如 { "mmsnstimeline": { "op": "0xd3", "bodyLen": 123, "hasSeed": true } }。
func snsStatusOpBodyReady(m map[string]any, name string) bool {
	v, ok := m[name]
	if !ok {
		return false
	}
	rec, ok := v.(map[string]any)
	if !ok {
		return false
	}
	return snsMapInt64(rec, "bodyLen", "body_len") > 0
}

// snsStatusOpSeedReady 读取 hook snsStatus 里某个 SNS op 的捕获记录是否已有闭包句柄。
// hook 顶层形如 { "mmsnscomment": { "op": "0xd5", "hasSeed": true, ... } }。
func snsStatusOpSeedReady(m map[string]any, name string) bool {
	v, ok := m[name]
	if !ok {
		return false
	}
	rec, ok := v.(map[string]any)
	if !ok {
		return false
	}
	return snsMapBool(rec, "hasSeed", "has_seed")
}

// snsAnchorsHave 判断 hook anchors 字段是否包含某类任务的锚点。
// anchors 可能是对象/数组，值可能是 bool/字符串；这里只做存在性判断。
func snsAnchorsHave(anchors any, key string) bool {
	switch t := anchors.(type) {
	case map[string]any:
		v, ok := t[key]
		if !ok {
			return false
		}
		switch vv := v.(type) {
		case bool:
			return vv
		case string:
			return vv != ""
		case nil:
			return false
		default:
			return true
		}
	case []any:
		for _, item := range t {
			if sv, ok := item.(string); ok && strings.Contains(strings.ToLower(sv), strings.ToLower(key)) {
				return true
			}
		}
	}
	return false
}

func (r fridaSNSPRC) Prime(ctx context.Context, seconds int) (SNSPrimeResult, error) {
	params, _ := json.Marshal(map[string]any{"seconds": seconds})
	raw, err := r.call(ctx, "snsPrime", string(params))
	if err != nil {
		return SNSPrimeResult{}, err
	}
	var m map[string]any
	if err := decodeSNSHookJSON(raw, &m); err != nil {
		return SNSPrimeResult{}, fmt.Errorf("snsPrime 返回无法解析: %w", err)
	}
	reason := snsMapString(m, "error", "reason")
	if reason != "" && !snsMapBool(m, "ok") {
		return SNSPrimeResult{Captured: int(snsMapInt64(m, "captured"))},
			snsErrorFromHook(reason, snsMapString(m, "message"))
	}
	res := SNSPrimeResult{OK: snsMapBool(m, "ok"), Captured: int(snsMapInt64(m, "captured"))}
	for _, key := range []string{"ops", "seeds"} {
		items, ok := m[key].([]any)
		if !ok {
			continue
		}
		for _, op := range items {
			if s, ok := op.(string); ok {
				res.Ops = append(res.Ops, s)
			}
		}
	}
	return res, nil
}

func (r fridaSNSPRC) Request(ctx context.Context, op string, body []byte, timeout time.Duration) (SNSHookResponse, error) {
	// hook 契约为「提交 + 轮询」：
	//   snsRequest(op, bodyHex) → {ok, requestId, taskId, ret}
	//   snsPoll(requestId)      → {ok, state:"pending"|"done"|"error", responseHex?, elapsedMs, error?}
	// 回包按 task 指针关联，不走 buf2resp（Lead 2026-11-07 同步）。
	if timeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}
	raw, err := r.call(ctx, "snsRequest", op, hex.EncodeToString(body))
	if err != nil {
		return SNSHookResponse{}, err
	}
	var submit map[string]any
	if err := decodeSNSHookJSON(raw, &submit); err != nil {
		return SNSHookResponse{}, fmt.Errorf("snsRequest 返回无法解析: %w", err)
	}
	if !snsMapBool(submit, "ok") {
		reason := snsMapString(submit, "error", "reason")
		return SNSHookResponse{}, snsErrorFromHook(reason, snsMapString(submit, "message"))
	}
	requestID := snsMapString(submit, "requestId", "request_id")
	if strings.TrimSpace(requestID) == "" {
		return SNSHookResponse{}, newSNSError(502, "sns_send_failed", "朋友圈请求提交失败（缺少 requestId）")
	}
	// 注意：不同 hook 版本 ret 语义不同（历史导出用 "1" 表示成功），
	// 这里只记录、不据此判失败；最终以 snsPoll 的 state 为准。

	started := time.Now()
	ticker := time.NewTicker(150 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return SNSHookResponse{}, ctx.Err()
		case <-ticker.C:
		}
		pollRaw, err := r.call(ctx, "snsPoll", requestID)
		if err != nil {
			return SNSHookResponse{}, err
		}
		var poll map[string]any
		if err := decodeSNSHookJSON(pollRaw, &poll); err != nil {
			return SNSHookResponse{}, fmt.Errorf("snsPoll 返回无法解析: %w", err)
		}
		if !snsMapBool(poll, "ok") {
			reason := snsMapString(poll, "error", "reason")
			return SNSHookResponse{}, snsErrorFromHook(reason, snsMapString(poll, "message"))
		}
		switch strings.ToLower(snsMapString(poll, "state")) {
		case "pending":
			continue
		case "done":
			responseHex := snsMapString(poll, "responseHex", "response_hex")
			if strings.TrimSpace(responseHex) == "" {
				return SNSHookResponse{}, newSNSError(502, "sns_parse_failed", "朋友圈回包为空")
			}
			data, err := hex.DecodeString(responseHex)
			if err != nil {
				return SNSHookResponse{}, fmt.Errorf("snsPoll responseHex 非十六进制: %w", err)
			}
			elapsed := snsMapInt64(poll, "elapsedMs", "elapsed_ms")
			if elapsed == 0 {
				elapsed = time.Since(started).Milliseconds()
			}
			resp := SNSHookResponse{Body: data, ElapsedMS: elapsed}
			if v, ok := poll["ret"]; ok {
				if f, ok := v.(float64); ok {
					ret := int32(f)
					resp.Ret = &ret
				}
			}
			return resp, nil
		case "error", "":
			reason := snsMapString(poll, "error", "reason")
			if reason == "" {
				reason = "send_failed"
			}
			return SNSHookResponse{}, snsErrorFromHook(reason, snsMapString(poll, "message"))
		default:
			continue
		}
	}
}

func (r fridaSNSPRC) Media(ctx context.Context, req SNSMediaRequest) (SNSMediaResult, error) {
	params := map[string]any{"action": req.Action}
	if req.Key != "" {
		params["key"] = req.Key
	}
	if req.Kind != "" {
		params["kind"] = req.Kind
	}
	if req.PostID != "" {
		params["postId"] = req.PostID
	}
	if req.Path != "" {
		params["path"] = req.Path
	}
	raw, err := r.call(ctx, "snsMedia", mustJSONString(params))
	if err != nil {
		return SNSMediaResult{}, err
	}
	var m map[string]any
	if err := decodeSNSHookJSON(raw, &m); err != nil {
		return SNSMediaResult{}, fmt.Errorf("snsMedia 返回无法解析: %w", err)
	}
	res := SNSMediaResult{OK: snsMapBool(m, "ok"), File: snsMapString(m, "file"), Error: snsMapString(m, "error")}
	if !res.OK {
		reason := res.Error
		if reason == "" {
			reason = snsMapString(m, "message")
		}
		return res, snsErrorFromHook(reason, snsMapString(m, "message"))
	}
	return res, nil
}

func mustJSONString(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

// ---- 超时 / 并发 / 限流 ---------------------------------------------------

const (
	snsDefaultTimeout = 8 * time.Second
	snsLongTimeout    = 12 * time.Second
	snsWriteTimeout   = 12 * time.Second
)

// snsTimeoutFor 返回某类请求的 bridge 侧超时（docs/sns.md §3）。
func snsTimeoutFor(op string) time.Duration {
	switch op {
	case "detail", "sync":
		return snsLongTimeout
	case "post", "comment", "like", "objectop":
		return snsWriteTimeout
	default:
		return snsDefaultTimeout
	}
}

// snsService 串行化读/写并维护只读帖缓存（媒体/评论回填用）。
type snsService struct {
	readMu  sync.Mutex
	writeMu sync.Mutex

	// 朋友圈增量同步游标（mmsnssync 的 KeyBuf）。只保存在内存：bridge 重启后
	// 由 hook/微信重新给出默认游标；不落盘，避免把账号游标写到日志/文件。
	syncMu     sync.Mutex
	syncKeyBuf []byte

	cacheMu      sync.Mutex
	posts        map[uint64]snsPostJSON
	postOrder    []uint64
	cacheAccount string

	// 发布幂等键（/sns/post 的 client_id），与缓存/限流器一样随 service 重建。
	idem *snsPostIdempotency

	limiter *snsRateLimiter
}

const snsPostCacheLimit = 256

func newSNSService() *snsService {
	return &snsService{
		posts:   make(map[uint64]snsPostJSON),
		idem:    newSNSPostIdempotency(),
		limiter: newSNSRateLimiter(),
	}
}

var snsSvc = newSNSService()

// read 串行执行一个读取请求；ctx 由 handler 带超时创建。
func (s *snsService) read(ctx context.Context, op string, body []byte) (SNSHookResponse, error) {
	s.readMu.Lock()
	defer s.readMu.Unlock()
	return currentSNSRPC().Request(ctx, op, body, snsTimeoutFor(op))
}

// write 串行执行一个写请求（发布/评论/点赞/objectop 共用）。
func (s *snsService) write(ctx context.Context, op string, body []byte) (SNSHookResponse, error) {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	return currentSNSRPC().Request(ctx, op, body, snsTimeoutFor(op))
}

// snsSyncSelector 是 mmsnssync 的 Selector 默认值（mac 4.2 实测 256）。
const snsSyncSelector = 256

func (s *snsService) syncCursor() []byte {
	s.syncMu.Lock()
	defer s.syncMu.Unlock()
	return append([]byte(nil), s.syncKeyBuf...)
}

func (s *snsService) setSyncCursor(keyBuf []byte) {
	s.syncMu.Lock()
	defer s.syncMu.Unlock()
	s.syncKeyBuf = append([]byte(nil), keyBuf...)
}

// rememberPosts 缓存本次读取到的帖子，供 /sns/media 与评论/点赞回填作者信息。
// 切号（selfID 变化）时清空，避免跨账号复用游标/媒体（docs/sns.md §6.3）。
func (s *snsService) rememberPosts(posts []snsPostJSON) {
	account := myWechatId
	s.cacheMu.Lock()
	defer s.cacheMu.Unlock()
	if s.cacheAccount != account {
		s.posts = make(map[uint64]snsPostJSON)
		s.postOrder = nil
		s.cacheAccount = account
	}
	for _, p := range posts {
		id, err := parseSNSID(p.ID)
		if err != nil {
			continue
		}
		if cached, exists := s.posts[id]; exists {
			// 保留 /sns/sync 增量并入的评论：timeline 回包常缺「评论的回复」，
			// 直接覆盖会让 App 刷新后又看不到（只补缺，不覆盖原生字段）。
			p = snsMergeCachedComments(p, cached)
		} else {
			s.postOrder = append(s.postOrder, id)
		}
		s.posts[id] = p
	}
	for len(s.postOrder) > snsPostCacheLimit {
		oldest := s.postOrder[0]
		s.postOrder = s.postOrder[1:]
		delete(s.posts, oldest)
	}
}

// rememberComments 把 /sns/sync 解出的评论/回复增量并入缓存动态。
// 没有缓存动态时只保存评论占位（ID + 评论，不伪造正文/作者），等 timeline
// 回包经 rememberPosts 合并后自然带出。按 comment_id 去重、只追加缺失，
// 不改变已有评论顺序，也不覆盖 timeline 原生评论字段。
func (s *snsService) rememberComments(postID string, comments []snsCommentJSON) {
	id, err := parseSNSID(postID)
	if err != nil || len(comments) == 0 {
		return
	}
	account := myWechatId
	s.cacheMu.Lock()
	defer s.cacheMu.Unlock()
	if s.cacheAccount != account {
		s.posts = make(map[uint64]snsPostJSON)
		s.postOrder = nil
		s.cacheAccount = account
	}
	post, exists := s.posts[id]
	if !exists {
		post = snsPostJSON{ID: postID, Media: make([]snsMediaJSON, 0), Comments: make([]snsCommentJSON, 0)}
		s.postOrder = append(s.postOrder, id)
	}
	post.Comments = snsMergeCommentLists(post.Comments, comments)
	if uint32(len(post.Comments)) > post.CommentCount {
		post.CommentCount = uint32(len(post.Comments))
	}
	post.CommentsTruncated = post.CommentCount > uint32(len(post.Comments))
	s.posts[id] = post
	for len(s.postOrder) > snsPostCacheLimit {
		oldest := s.postOrder[0]
		s.postOrder = s.postOrder[1:]
		delete(s.posts, oldest)
	}
}

func (s *snsService) lookupPost(id uint64) (snsPostJSON, bool) {
	account := myWechatId
	s.cacheMu.Lock()
	defer s.cacheMu.Unlock()
	if s.cacheAccount != account {
		return snsPostJSON{}, false
	}
	p, ok := s.posts[id]
	return p, ok
}

// ---- 写操作频率限制 -------------------------------------------------------

type snsRateRule struct {
	minInterval time.Duration
	perHour     int
}

var snsWriteRateRules = map[string]snsRateRule{
	// post 的频率由 checkSNSPostPolicy 按可配置策略（时段/每日上限/最小间隔）
	// 校验，不再使用固定 20 次/小时的窗口。
	"comment":  {minInterval: 10 * time.Second, perHour: 20},
	"like":     {minInterval: 10 * time.Second, perHour: 20},
	"objectop": {minInterval: 10 * time.Second, perHour: 20},
}

type snsRateLimiter struct {
	mu     sync.Mutex
	events map[string][]time.Time
}

func newSNSRateLimiter() *snsRateLimiter {
	return &snsRateLimiter{events: make(map[string][]time.Time)}
}

// snsNow 可被测试替换以验证 429。
var snsNow = time.Now

// allow 判断某类写操作是否放行并立即记账（仅供不需要区分「校验/成功后记账」的
// 旧调用点与单测使用）。HTTP 写接口应先用 check 校验、成功提交后再 record，
// 避免失败的尝试占用频率配额（docs/sns.md §4.6）。
func (l *snsRateLimiter) allow(key string, now time.Time) (bool, time.Duration) {
	ok, wait := l.check(key, now)
	if !ok {
		return false, wait
	}
	l.record(key, now)
	return true, 0
}

// check 只判断是否放行，不写入事件；返回建议的重试等待时间。
func (l *snsRateLimiter) check(key string, now time.Time) (bool, time.Duration) {
	rule, ok := snsWriteRateRules[key]
	if !ok {
		return true, 0
	}
	l.mu.Lock()
	defer l.mu.Unlock()

	events := l.events[key]
	cutoff := now.Add(-time.Hour)
	kept := events[:0]
	for _, t := range events {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	events = kept
	l.events[key] = events

	if len(events) >= rule.perHour {
		wait := events[0].Add(time.Hour).Sub(now)
		if wait < 0 {
			wait = 0
		}
		return false, wait
	}
	if n := len(events); n > 0 {
		if wait := events[n-1].Add(rule.minInterval).Sub(now); wait > 0 {
			return false, wait
		}
	}
	return true, 0
}

// checkSNSWriteRate 返回 429 错误；key 未知时放行。只校验不记账。
func checkSNSWriteRate(key string) *snsError {
	ok, wait := snsSvc.limiter.check(key, snsNow())
	if ok {
		return nil
	}
	secs := int(wait.Seconds() + 0.999)
	if secs < 1 {
		secs = 1
	}
	e := newSNSError(429, "sns_rate_limited", fmt.Sprintf("操作太频繁，请 %d 秒后重试", secs))
	e.RetryAfterSeconds = secs
	return e
}

// recordSNSWriteRate 在微信确认成功后记账；失败尝试不得调用。
func recordSNSWriteRate(key string) {
	snsSvc.limiter.record(key, snsNow())
}

// ---- 发布幂等（client_id） -------------------------------------------------
//
// App 在 /sns/post 里可带可选 client_id；bridge 记录最近 10 分钟内已处理过的
// 键，窗口内重复的键返回 409 sns_duplicate_request，不再构造/提交请求，避免
// 「服务端已发布、App 超时重试」导致重复朋友圈（docs/sns.md §8 发布幂等）。
//
// 只存进程内存：bridge 重启清零；容量上限 512，超出按时间淘汰最旧键。键只在
// 请求通过全部校验（含配额检查）并即将构造发布请求时登记，校验失败不占用。

const (
	snsPostIdempotencyWindow = 10 * time.Minute
	snsPostIdempotencyLimit  = 512
	snsPostClientIDMaxLen    = 128 // client_id 字节上限，避免无界内存占用
)

type snsPostIdempotency struct {
	mu   sync.Mutex
	seen map[string]time.Time
}

func newSNSPostIdempotency() *snsPostIdempotency {
	return &snsPostIdempotency{seen: make(map[string]time.Time)}
}

// claim 登记 client_id：窗口内首次出现返回 true；重复返回 false（已处理）。
// 同时清理过期键，容量达到上限时淘汰最旧的键。
func (p *snsPostIdempotency) claim(clientID string, now time.Time) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	for id, ts := range p.seen {
		if now.Sub(ts) > snsPostIdempotencyWindow {
			delete(p.seen, id)
		}
	}
	if _, dup := p.seen[clientID]; dup {
		return false
	}
	if len(p.seen) >= snsPostIdempotencyLimit {
		oldestID, oldestTS := "", time.Time{}
		for id, ts := range p.seen {
			if oldestID == "" || ts.Before(oldestTS) {
				oldestID, oldestTS = id, ts
			}
		}
		delete(p.seen, oldestID)
	}
	p.seen[clientID] = now
	return true
}

// claimSNSPostClientID 登记发布幂等键；client_id 为空时不启用幂等（返回 true）。
func (s *snsService) claimSNSPostClientID(clientID string, now time.Time) bool {
	if clientID == "" {
		return true
	}
	return s.idem.claim(clientID, now)
}

// ---- 媒体目录 -------------------------------------------------------------

// snsMediaDir 计算本账号的朋友圈媒体落盘目录：
//   - -media_dir = .../accounts/<wxid>/media 时，SNS 媒体放同级 sns-media；
//   - 其它情况在 -media_dir 下建 sns-media。
//
// hook 负责真正下载；bridge 只校验 hook 返回的文件仍在该目录内。
func snsMediaDir() string {
	base := strings.TrimSpace(config.MediaDir)
	if base == "" {
		return ""
	}
	if filepath.Base(base) == "media" {
		return filepath.Join(filepath.Dir(base), "sns-media")
	}
	return filepath.Join(base, "sns-media")
}

// snsPathWithin 校验 child 位于 parent 目录内（防路径穿越）。
func snsPathWithin(parent, child string) bool {
	if parent == "" || child == "" {
		return false
	}
	rel, err := filepath.Rel(parent, child)
	if err != nil {
		return false
	}
	return rel == "." || (rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)))
}

// parseSNSID 把 HTTP JSON 里的十进制字符串 ID 转 uint64（禁止 int64）。
func parseSNSID(s string) (uint64, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, errors.New("snsID 为空")
	}
	id, err := strconv.ParseUint(s, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("snsID 非 uint64: %w", err)
	}
	return id, nil
}

// ---- 发布策略（时段 / 每日上限 / 最小间隔）--------------------------------
//
// 具体配置键仍在与用户确认中（Lead 2026-11-07 更新）：先支持下列键，缺失时
// 使用 docs 里的保守默认值；字段名确定后只需改 parseSNSPolicy。
//
//	snsPostMinIntervalMs  number/string  默认 600000（1 条/10 分钟）
//	snsPostDailyLimit     number/string  默认 5
//	snsPostTimeWindows    []string       形如 ["09:00-22:00", "23:00-01:00"]
//	                       为空 = 不限制时段；支持跨午夜窗口。
type snsTimeWindow struct {
	StartMinute int
	EndMinute   int
}

type snsPolicy struct {
	PostMinInterval time.Duration
	PostDailyLimit  int
	PostWindows     []snsTimeWindow
}

func defaultSNSPolicy() snsPolicy {
	return snsPolicy{
		PostMinInterval: 10 * time.Minute,
		PostDailyLimit:  5,
	}
}

var snsPolicyState struct {
	mu     sync.RWMutex
	policy snsPolicy
}

func currentSNSPolicy() snsPolicy {
	snsPolicyState.mu.RLock()
	defer snsPolicyState.mu.RUnlock()
	return snsPolicyState.policy
}

func setSNSPolicyForTest(p snsPolicy) {
	snsPolicyState.mu.Lock()
	snsPolicyState.policy = p
	snsPolicyState.mu.Unlock()
}

func snsPolicyInt(raw map[string]any, key string, def int) int {
	v, ok := raw[key]
	if !ok {
		return def
	}
	switch t := v.(type) {
	case float64:
		return int(t)
	case string:
		if n, err := strconv.Atoi(strings.TrimSpace(t)); err == nil {
			return n
		}
	}
	return def
}

func parseSNSPolicy(raw map[string]any) snsPolicy {
	p := defaultSNSPolicy()
	if ms := snsPolicyInt(raw, "snsPostMinIntervalMs", 0); ms > 0 {
		p.PostMinInterval = time.Duration(ms) * time.Millisecond
	}
	if limit := snsPolicyInt(raw, "snsPostDailyLimit", 0); limit > 0 {
		p.PostDailyLimit = limit
	}
	if p.PostDailyLimit > 50 {
		p.PostDailyLimit = 50
	}

	var windowStrs []string
	switch v := raw["snsPostTimeWindows"].(type) {
	case string:
		for _, part := range strings.Split(v, ",") {
			if s := strings.TrimSpace(part); s != "" {
				windowStrs = append(windowStrs, s)
			}
		}
	case []any:
		for _, item := range v {
			if s, ok := item.(string); ok {
				windowStrs = append(windowStrs, s)
			}
		}
	}
	for _, s := range windowStrs {
		if w, ok := parseSNSTimeWindow(s); ok {
			p.PostWindows = append(p.PostWindows, w)
		}
	}
	return p
}

func parseSNSTimeWindow(s string) (snsTimeWindow, bool) {
	parts := strings.SplitN(strings.TrimSpace(s), "-", 2)
	if len(parts) != 2 {
		return snsTimeWindow{}, false
	}
	start, ok1 := parseSNSClock(parts[0])
	end, ok2 := parseSNSClock(parts[1])
	if !ok1 || !ok2 {
		return snsTimeWindow{}, false
	}
	return snsTimeWindow{StartMinute: start, EndMinute: end}, true
}

func parseSNSClock(s string) (int, bool) {
	parts := strings.SplitN(strings.TrimSpace(s), ":", 2)
	if len(parts) != 2 {
		return 0, false
	}
	h, err := strconv.Atoi(strings.TrimSpace(parts[0]))
	if err != nil {
		return 0, false
	}
	m, err := strconv.Atoi(strings.TrimSpace(parts[1]))
	if err != nil {
		return 0, false
	}
	if h < 0 || h > 23 || m < 0 || m > 59 {
		return 0, false
	}
	return h*60 + m, true
}

func (w snsTimeWindow) contains(minute int) bool {
	if w.StartMinute <= w.EndMinute {
		return minute >= w.StartMinute && minute <= w.EndMinute
	}
	// 跨午夜，例如 23:00-01:00。
	return minute >= w.StartMinute || minute <= w.EndMinute
}

func snsPolicyAllowsNow(p snsPolicy, now time.Time) bool {
	if len(p.PostWindows) == 0 {
		return true
	}
	minute := now.Hour()*60 + now.Minute()
	for _, w := range p.PostWindows {
		if w.contains(minute) {
			return true
		}
	}
	return false
}

// checkSNSPostPolicy 只校验时段/每日上限/最小间隔，不记录发布尝试。
// 失败返回 409（时段）或 429（频率/上限），供 App 展示可行动提示。
// 只有真正提交成功后才由 recordSNSPostAttempt 记录配额，失败尝试不占用。
func checkSNSPostPolicy(now time.Time) *snsError {
	p := currentSNSPolicy()
	if !snsPolicyAllowsNow(p, now) {
		return newSNSError(409, "sns_outside_window", "当前不在允许发布朋友圈的时间段")
	}
	limiter := snsSvc.limiter
	dayStart := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	if n := limiter.countSince("post", dayStart); n >= p.PostDailyLimit {
		e := newSNSError(429, "sns_daily_limit", "今日发布次数已达上限")
		e.RetryAfterSeconds = int(dayStart.Add(24*time.Hour).Sub(now).Seconds() + 0.999)
		return e
	}
	if last, ok := limiter.lastEvent("post"); ok {
		if wait := p.PostMinInterval - now.Sub(last); wait > 0 {
			secs := int(wait.Seconds() + 0.999)
			if secs < 1 {
				secs = 1
			}
			e := newSNSError(429, "sns_rate_limited", fmt.Sprintf("操作太频繁，请 %d 秒后重试", secs))
			e.RetryAfterSeconds = secs
			return e
		}
	}
	return nil
}

// recordSNSPostAttempt 记录一次「已成功提交」的发布，用于每日上限与最小间隔。
// 调用方必须在微信确认发布成功后才调用；503 sns_publish_unavailable 等失败
// 尝试不得调用，否则会白扣当天的发布配额。
func recordSNSPostAttempt(now time.Time) {
	snsSvc.limiter.record("post", now)
}

// ---- 发布可见性 -----------------------------------------------------------

// snsVisibilityPlan 是 visibility → 协议字段的映射结果。
//
// 2026-11-10 按 4.2.0.17 真机抓包校准：mac 微信的「部分可见」真实请求是
// Privacy=0 + GroupUsers=[好友]，Privacy 不是可见性枚举（公开/部分可见都由
// GroupUsers/BlackList 表达，1 只表示「仅自己可见」）。旧实现按公开资料把
// partial 写成 Privacy=2，服务端回包成功但目标好友看不到该动态；现在与原生
// 请求字段保持一致。
type snsVisibilityPlan struct {
	Visibility     string
	Privacy        uint32
	VisibleUserIDs []string
}

const snsVisibleUserLimit = 100

// snsPlanVisibility 解析可见性（docs/sns.md §4.6，2026-11-07 更新）：
//   - 默认 partial（仅当前私聊对象可见），需要 target_user_id 或 visible_user_ids；
//   - partial 只允许 1 个好友；若同时给 target 与 ids，两者必须一致；
//   - partial 的请求编码与 mac 原生一致：Privacy=0 + GroupUsers=[好友]；
//   - 无上下文（既无 target 也无 ids）时降级 private；
//   - public 本迭代拒绝（403）；联调时仍按原生 Privacy=0 提交（不带可见列表）。
func snsPlanVisibility(visibility string, visibleUserIDs []string, targetUserID string) (snsVisibilityPlan, *snsError) {
	v := strings.ToLower(strings.TrimSpace(visibility))
	if v == "" {
		v = "partial"
	}
	target := strings.TrimSpace(targetUserID)
	ids := make([]string, 0, len(visibleUserIDs))
	seen := make(map[string]struct{}, len(visibleUserIDs))
	for _, id := range visibleUserIDs {
		id = strings.TrimSpace(id)
		if id == "" {
			continue
		}
		if _, dup := seen[id]; dup {
			continue
		}
		seen[id] = struct{}{}
		ids = append(ids, id)
	}
	if len(ids) > snsVisibleUserLimit {
		return snsVisibilityPlan{}, newSNSError(400, "sns_invalid_request",
			fmt.Sprintf("visible_user_ids 超过 %d 个上限", snsVisibleUserLimit))
	}
	switch v {
	case "partial":
		if target != "" && len(ids) > 0 && (len(ids) != 1 || ids[0] != target) {
			return snsVisibilityPlan{}, newSNSError(403, "sns_visibility_mismatch",
				"visible_user_ids 必须与当前私聊对象一致")
		}
		if len(ids) == 0 && target != "" {
			ids = append(ids, target)
		}
		if len(ids) == 0 {
			// 无会话上下文时不允许「部分可见」退化成公开。
			return snsVisibilityPlan{Visibility: "private", Privacy: 1}, nil
		}
		if len(ids) > 1 {
			return snsVisibilityPlan{}, newSNSError(403, "sns_visibility_unsupported",
				"部分可见仅支持 1 个好友（当前私聊对象）")
		}
		return snsVisibilityPlan{Visibility: "partial", Privacy: 0, VisibleUserIDs: ids}, nil
	case "private":
		return snsVisibilityPlan{Visibility: "private", Privacy: 1}, nil
	case "public":
		// 本迭代 UI 不提供 public，且协议字段与风控未验证。
		// 仅联调：显式设置 SNS_ALLOW_PUBLIC_TEST=1 且开启 snsProbe 时临时允许，
		// 便于用真实公开帖验证写入通道；生产环境不会设置该变量。
		if snsProbeEnabled() && strings.TrimSpace(os.Getenv("SNS_ALLOW_PUBLIC_TEST")) == "1" {
			return snsVisibilityPlan{Visibility: "public"}, nil
		}
		return snsVisibilityPlan{}, newSNSError(403, "sns_visibility_unsupported", "本迭代不支持公开可见")
	default:
		return snsVisibilityPlan{}, newSNSError(400, "sns_invalid_visibility",
			"visibility 必须是 partial/private/public")
	}
}

// ---- 限流器扩展 -----------------------------------------------------------

func (l *snsRateLimiter) countSince(key string, since time.Time) int {
	l.mu.Lock()
	defer l.mu.Unlock()
	n := 0
	for _, t := range l.events[key] {
		if !t.Before(since) {
			n++
		}
	}
	return n
}

func (l *snsRateLimiter) lastEvent(key string) (time.Time, bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	events := l.events[key]
	if len(events) == 0 {
		return time.Time{}, false
	}
	return events[len(events)-1], true
}

func (l *snsRateLimiter) record(key string, now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.events[key] = append(l.events[key], now)
}

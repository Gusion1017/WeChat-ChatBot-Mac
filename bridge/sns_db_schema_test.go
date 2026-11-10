package main

// sns.db 只读 schema 探针（P0）的 HTTP 契约测试：开关/鉴权/路径推导/成功回包
// （含 keys 剥离与合并落盘）以及 key_missing 的可行动错误。全部用桩 RPC，不连微信。

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func setupSNSDbSchemaTest(t *testing.T) {
	t.Helper()
	setupSNSHTTP(t, false, false)
	setSNSProbeForTest(false)
	setSNSDbReadForTest(false)
	t.Cleanup(func() {
		setSNSProbeForTest(false)
		setSNSDbReadForTest(false)
	})
}

func TestSNSDbSchemaGates(t *testing.T) {
	setupSNSDbSchemaTest(t)

	// 默认关闭：即使 Bearer 正确也 404。
	rec := snsPOST(t, snsDbSchemaHandler, "{}", snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != http.StatusNotFound || code != "sns_db_disabled" {
		t.Fatalf("关闭时应收 404 sns_db_disabled，实际 %d/%s", status, code)
	}

	setSNSDbReadForTest(true)
	rec = snsGET(t, snsDbSchemaHandler, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != http.StatusMethodNotAllowed || code != "sns_method_not_allowed" {
		t.Fatalf("GET 应收 405，实际 %d/%s", status, code)
	}
	rec = snsPOST(t, snsDbSchemaHandler, "{}", "")
	if status, code, _ := snsErrFields(t, rec); status != http.StatusUnauthorized || code != "sns_unauthorized" {
		t.Fatalf("未鉴权应收 401，实际 %d/%s", status, code)
	}
}

func TestSNSDbSchemaSuccessStripsKeysAndMergesCache(t *testing.T) {
	setupSNSDbSchemaTest(t)
	setSNSProbeForTest(true)

	oldImagePath := config.ImagePath
	oldKeysPath := contactDBKeysFilePath
	keysPath := filepath.Join(t.TempDir(), "db-keys.json")
	config.ImagePath = "/tmp/xwechat_files/wxid_test/temp/Img"
	contactDBKeysFilePath = func() string { return keysPath }
	t.Cleanup(func() {
		config.ImagePath = oldImagePath
		contactDBKeysFilePath = oldKeysPath
	})

	// 已有 contact key 不能被 SNS 结果覆盖。
	contactKey := ContactKey{Salt: strings.Repeat("a", 32), Key: strings.Repeat("b", 64)}
	if err := persistContactDBKeys(map[string]ContactKey{"contact": contactKey}); err != nil {
		t.Fatalf("预置 contact key 失败: %v", err)
	}

	oldCall := callFridaExport
	t.Cleanup(func() { callFridaExport = oldCall })
	var gotPath string
	snsKey := ContactKey{Salt: strings.Repeat("c", 32), Key: strings.Repeat("d", 64)}
	callFridaExport = func(fn string, args ...any) (any, error) {
		if fn != "snsDbSchema" {
			return nil, fmt.Errorf("unexpected frida call %s", fn)
		}
		if len(args) > 0 {
			gotPath, _ = args[0].(string)
		}
		payload, _ := json.Marshal(map[string]any{
			"ok":           true,
			"generated_at": 1794235000000,
			"key_source":   "candidate",
			"decrypt_ms":   12,
			"query_ms":     3,
			"wal_applied":  5,
			"pages":        45,
			"page_count":   45,
			"tables": []map[string]any{
				{"name": "sns_detail_list", "sql": "CREATE TABLE sns_detail_list(id INTEGER)", "rows": 10},
			},
			"key_status": map[string]any{"installed": true, "candidates": 2, "passphrase": false},
			"keys":       map[string]any{"sns": map[string]any{"salt": snsKey.Salt, "key": snsKey.Key}},
		})
		return string(payload), nil
	}

	rec := snsPOST(t, snsDbSchemaHandler, "{}", snsTestToken)
	data := snsDataField(t, rec)
	if gotPath != "/tmp/xwechat_files/wxid_test/db_storage" {
		t.Fatalf("db_storage 推导错误: %q", gotPath)
	}
	if _, leaked := data["keys"]; leaked {
		t.Fatal("HTTP 响应不应包含 DB key")
	}
	if data["key_source"] != "candidate" || snsJSONNumber(data["wal_applied"]) != 5 {
		t.Fatalf("探针元数据错误: %v", data)
	}
	tables, ok := data["tables"].([]any)
	if !ok || len(tables) != 1 || tables[0].(map[string]any)["name"] != "sns_detail_list" {
		t.Fatalf("tables 错误: %v", data["tables"])
	}

	// 合并落盘：contact 保留 + sns 新增。
	raw, err := os.ReadFile(keysPath)
	if err != nil {
		t.Fatalf("读取 key 缓存失败: %v", err)
	}
	var saved map[string]ContactKey
	if err := json.Unmarshal(raw, &saved); err != nil {
		t.Fatalf("key 缓存不是 JSON: %v", err)
	}
	if saved["contact"] != contactKey {
		t.Fatalf("contact key 被覆盖: %+v", saved["contact"])
	}
	if saved["sns"] != snsKey {
		t.Fatalf("sns key 未落盘: %+v", saved["sns"])
	}
}

func TestSNSDbSchemaKeyMissing(t *testing.T) {
	setupSNSDbSchemaTest(t)
	setSNSProbeForTest(true)
	oldImagePath := config.ImagePath
	config.ImagePath = "/tmp/xwechat_files/wxid_test/temp"
	t.Cleanup(func() { config.ImagePath = oldImagePath })

	oldCall := callFridaExport
	t.Cleanup(func() { callFridaExport = oldCall })
	callFridaExport = func(fn string, args ...any) (any, error) {
		return `{"ok":false,"reason":"key_missing","key_status":{"installed":true,"validated":2,"provided":2,"candidates":3,"passphrase":false}}`, nil
	}
	rec := snsPOST(t, snsDbSchemaHandler, "{}", snsTestToken)
	body := snsJSONBody(t, rec)
	if rec.Code != http.StatusServiceUnavailable || body["code"] != "sns_db_key_missing" {
		t.Fatalf("key_missing 应 503 sns_db_key_missing: %d %v", rec.Code, body)
	}
	status, ok := body["key_status"].(map[string]any)
	if !ok || snsJSONNumber(status["candidates"]) != 3 || status["passphrase"] != false {
		t.Fatalf("key_status 计数错误: %v", body["key_status"])
	}
}

func TestSNSDbSchemaPathAndRPCFailures(t *testing.T) {
	setupSNSDbSchemaTest(t)
	setSNSProbeForTest(true)
	oldImagePath := config.ImagePath
	t.Cleanup(func() { config.ImagePath = oldImagePath })

	// image_path 推导不出 db_storage：503，不应调用 RPC。
	config.ImagePath = ""
	oldCall := callFridaExport
	t.Cleanup(func() { callFridaExport = oldCall })
	called := false
	callFridaExport = func(fn string, args ...any) (any, error) {
		called = true
		return nil, nil
	}
	rec := snsPOST(t, snsDbSchemaHandler, "{}", snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != http.StatusServiceUnavailable || code != "sns_db_path_unknown" {
		t.Fatalf("路径不可推导应 503 sns_db_path_unknown，实际 %d/%s", status, code)
	}
	if called {
		t.Fatal("路径不可推导时不应调用 Frida")
	}

	// Hook 调用失败：503 sns_db_unavailable。
	config.ImagePath = "/tmp/xwechat_files/wxid_test/temp"
	callFridaExport = func(fn string, args ...any) (any, error) {
		return nil, fmt.Errorf("frida unavailable")
	}
	rec = snsPOST(t, snsDbSchemaHandler, "{}", snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != http.StatusServiceUnavailable || code != "sns_db_unavailable" {
		t.Fatalf("RPC 失败应 503 sns_db_unavailable，实际 %d/%s", status, code)
	}
}
func TestSNSDbCommentsProbeGates(t *testing.T) {
	setupSNSDbSchemaTest(t)

	rec := snsPOST(t, snsDbCommentsHandler, `{"post_ids":["1"]}`, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != http.StatusNotFound || code != "sns_db_disabled" {
		t.Fatalf("探针关闭应收 404 sns_db_disabled，实际 %d/%s", status, code)
	}
	setSNSProbeForTest(true)
	rec = snsPOST(t, snsDbCommentsHandler, `{"post_ids":["1"]}`, "")
	if status, code, _ := snsErrFields(t, rec); status != http.StatusUnauthorized || code != "sns_unauthorized" {
		t.Fatalf("未鉴权应收 401，实际 %d/%s", status, code)
	}
	rec = snsPOST(t, snsDbCommentsHandler, `{"post_ids":[]}`, snsTestToken)
	if status, code, _ := snsErrFields(t, rec); status != http.StatusBadRequest || code != "sns_invalid_request" {
		t.Fatalf("空 post_ids 应收 400，实际 %d/%s", status, code)
	}
}

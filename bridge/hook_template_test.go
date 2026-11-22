package main

// hook 脚本模板渲染的缺键校验（hook_template.go）。
// 这些用例只做纯 Go 渲染，不连接 Frida，也不启动 HTTP。

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRenderHookScriptKeepsQuotedMissingKey(t *testing.T) {
	conf := map[string]interface{}{"blrX8Addr": "0x1000"}
	tmplSrc := "var blrX8Addr = baseAddr.add({{.blrX8Addr}});\n" +
		"var snsProbeEnabled = \"{{.snsProbe}}\" === \"true\";\n"

	out, err := renderHookScript(tmplSrc, conf)
	if err != nil {
		t.Fatalf("字符串位置的可选缺键应容忍，实际报错: %v", err)
	}
	if !strings.Contains(out, "var blrX8Addr = baseAddr.add(0x1000);") {
		t.Fatalf("地址占位符未替换: %q", out)
	}
	if !strings.Contains(out, "\"<no value>\" === \"true\"") {
		t.Fatalf("可选开关应渲染为字符串 <no value>（hook 见到的旧行为）: %q", out)
	}
}

func TestRenderHookScriptRejectsBareMissingKey(t *testing.T) {
	conf := map[string]interface{}{"blrX8Addr": "0x1000"}
	tmplSrc := "var a = baseAddr.add({{.blrX8Addr}});\nvar b = baseAddr.add({{.missingAddr}});\n"

	_, err := renderHookScript(tmplSrc, conf)
	if err == nil {
		t.Fatal("代码位置缺键应拒绝渲染（否则注入后整份脚本语法错误）")
	}
	if !strings.Contains(err.Error(), "missingAddr") {
		t.Fatalf("错误应点名缺失字段，实际: %v", err)
	}
}

func TestRenderHookScriptToleratesNoValueInCommentsAndStrings(t *testing.T) {
	// hook/script.js 自身在注释里解释 <no value>，且有可选地址是字符串值；
	// 这些都不应触发拒绝。
	tmplSrc := "// 旧版 JSON 无此键(渲染为 <no value>)，走旧路径\n" +
		"/* 缺键(<no value>)/非法/过小一律回退 */\n" +
		"var structVer = \"{{.structVer}}\";\n" +
		"var guarded = \"<no value>\";\n" +
		"var nested = \"a\\\"<no value>\";\n"
	if _, err := renderHookScript(tmplSrc, map[string]interface{}{}); err != nil {
		t.Fatalf("注释/字符串里的 <no value> 不该被拒绝: %v", err)
	}
}

func TestFindBareNoValueDetectsCodePosition(t *testing.T) {
	cases := []struct {
		name   string
		script string
		want   bool
	}{
		{"代码位置", "baseAddr.add(<no value>)", true},
		{"双引号字符串", "var x = \"<no value>\";", false},
		{"单引号字符串", "var x = '<no value>';", false},
		{"模板字符串", "var x = `<no value>`;", false},
		{"行注释", "// <no value>\nvar x = 1;", false},
		{"块注释", "/* <no value> */ var x = 1;", false},
		{"注释后代码位置", "// ok\nvar y = (<no value>);", true},
		{"字符串转义后代码位置", "var s = \"a\\\"b\"; var y = (<no value>);", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, got := findBareNoValue(tc.script); got != tc.want {
				t.Fatalf("findBareNoValue(%q) = %v, want %v", tc.script, got, tc.want)
			}
		})
	}
}

// TestRenderHookScriptRepositoryVersions 是版本表（hook/versions/*.json）与
// script.js 占位符集合的同步校验：仓库里每个微信版本的配置都必须能安全渲染
// （不允许出现代码位置的 <no value>）。新增地址字段忘了同步版本表时这里会失败。
func TestRenderHookScriptRepositoryVersions(t *testing.T) {
	tmplSrc, err := os.ReadFile("script.js")
	if err != nil {
		t.Skipf("未找到运行期 script.js（%v）", err)
	}
	versionDir := filepath.Join("..", "hook", "versions")
	entries, err := os.ReadDir(versionDir)
	if err != nil {
		t.Skipf("未找到版本表目录 %s（%v）", versionDir, err)
	}
	rendered := 0
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".json") {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(versionDir, entry.Name()))
		if err != nil {
			t.Errorf("%s: 读取失败: %v", entry.Name(), err)
			continue
		}
		var conf map[string]interface{}
		if err := json.Unmarshal(raw, &conf); err != nil {
			t.Errorf("%s: JSON 解析失败: %v", entry.Name(), err)
			continue
		}
		if _, err := renderHookScript(string(tmplSrc), conf); err != nil {
			t.Errorf("%s: 渲染失败（版本表与占位符不同步）: %v", entry.Name(), err)
			continue
		}
		rendered++
	}
	if rendered == 0 {
		t.Skip("没有可校验的版本配置")
	}
}

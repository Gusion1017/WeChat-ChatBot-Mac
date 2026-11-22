package main

// hook/script.js（运行期副本 bridge/script.js）由 Go text/template 用微信版本
// 配置渲染。Go 对缺失键的默认行为是渲染成 "<no value>"，两种落点后果完全不同：
//   - 模板里写作 "{{.key}}" 的占位符会得到字符串 "<no value>"，hook 侧按
//     「缺键 = 保持旧行为」处理（structVer / req2bufLayout / snsXxx 开关、可选地址）；
//   - 模板里写作 baseAddr.add({{.key}}) 的地址占位符会得到裸 <no value>，整份
//     脚本 SyntaxError：script.Load() 之后所有 hook 静默失效（登录后零事件）。
//
// 所以渲染后必须区分这两种落点：字符串/注释里的 <no value> 容忍并记录缺哪些键，
// 代码位置的直接拒绝注入。版本表（hook/versions/*.json）与占位符集合的同步由
// TestRenderHookScriptRepositoryVersions 兜底。

import (
	"bytes"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"text/template"
)

// noValueMarker 是 text/template 缺失键的渲染结果。
const noValueMarker = "<no value>"

// renderHookScript 用版本配置渲染 hook 脚本模板，并在注入前校验缺键。
func renderHookScript(tmplSrc string, hookConf map[string]interface{}) (string, error) {
	tmpl, err := template.New("fridaScript").Parse(tmplSrc)
	if err != nil {
		return "", fmt.Errorf("解析模板失败: %w", err)
	}

	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, hookConf); err != nil {
		return "", fmt.Errorf("执行模板失败: %w", err)
	}
	rendered := buf.String()

	missing := missingHookConfKeys(tmplSrc, hookConf)
	if offset, bare := findBareNoValue(rendered); bare {
		if len(missing) == 0 {
			missing = []string{"(模板字段名未能解析，请检查 script.js 占位符)"}
		}
		return "", fmt.Errorf("版本配置缺少地址/开关字段 %s：渲染结果偏移 %d 处出现裸 %s（注入后整份脚本语法错误）",
			strings.Join(missing, ","), offset, noValueMarker)
	}
	if len(missing) > 0 {
		// 可选字段：保持旧行为（hook 侧已把 "<no value>" 判为非法），只在 Debug 记录，
		// 避免每次启动都在 Info 日志里刷一长串「预期缺失」的键。
		Debug("版本配置缺少可选字段，按字符串 <no value> 渲染（hook 走旧行为）",
			"keys", strings.Join(missing, ","))
	}
	return rendered, nil
}

// findBareNoValue 返回第一个位于 JS 代码（而不是字符串/注释里）的 <no value> 偏移。
// 单测覆盖字符串、模板字符串、行注释、块注释四种容忍场景。
func findBareNoValue(script string) (int, bool) {
	for i := 0; i < len(script); {
		switch c := script[i]; {
		case c == '/' && i+1 < len(script) && script[i+1] == '/':
			// 行注释：跳到换行（注释里的 <no value> 只是文档说明）。
			for i < len(script) && script[i] != '\n' {
				i++
			}
		case c == '/' && i+1 < len(script) && script[i+1] == '*':
			// 块注释。
			i += 2
			for i+1 < len(script) && !(script[i] == '*' && script[i+1] == '/') {
				i++
			}
			if i+1 < len(script) {
				i += 2
			}
		case c == '"' || c == '\'' || c == '`':
			// 字符串/模板字符串：连同转义一起跳过。
			quote := c
			i++
			for i < len(script) {
				if script[i] == '\\' && quote != '`' {
					i += 2
					continue
				}
				if script[i] == quote {
					i++
					break
				}
				i++
			}
		default:
			if strings.HasPrefix(script[i:], noValueMarker) {
				return i, true
			}
			i++
		}
	}
	return 0, false
}

// 模板占位符扫描（只用于缺键诊断，不参与渲染正确性判断）。
var (
	// hookTemplateAction 匹配一个 {{...}} 动作；脚本里的 JS 字面量不会出现 {{。
	hookTemplateAction = regexp.MustCompile(`\{\{[^}]*\}\}`)
	// hookTemplateField 匹配动作里 .key 形式的根字段（排除 a.b 这类属性访问）。
	hookTemplateField = regexp.MustCompile(`(?:^|[^A-Za-z0-9_.])\.([A-Za-z_][A-Za-z0-9_]*)`)
)

// missingHookConfKeys 返回模板引用但版本配置里没有的字段名（排序）。
func missingHookConfKeys(tmplSrc string, hookConf map[string]interface{}) []string {
	missing := make([]string, 0, 8)
	for _, key := range hookTemplateKeys(tmplSrc) {
		if _, ok := hookConf[key]; !ok {
			missing = append(missing, key)
		}
	}
	sort.Strings(missing)
	return missing
}

// hookTemplateKeys 收集模板里 {{.key}} 形式引用的数据键（去重、排序）。
func hookTemplateKeys(tmplSrc string) []string {
	seen := make(map[string]struct{})
	for _, action := range hookTemplateAction.FindAllString(tmplSrc, -1) {
		for _, match := range hookTemplateField.FindAllStringSubmatch(action, -1) {
			seen[match[1]] = struct{}{}
		}
	}
	keys := make([]string, 0, len(seen))
	for key := range seen {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

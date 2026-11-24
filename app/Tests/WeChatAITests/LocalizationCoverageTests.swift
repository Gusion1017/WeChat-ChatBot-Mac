import Foundation
import XCTest

/// 英文界面文案完整性：`L()/Lf()` 找不到 key 时英文界面会回退中文。
///
/// 只校验本次审计涉及的用户可见文案（微信备份、朋友圈只读门禁、版本表未验证引导），
/// 直接读取 `app/Packaging/en.lproj/Localizable.strings`，不依赖测试 bundle 资源。
final class LocalizationCoverageTests: XCTestCase {
    /// `#filePath` = <repo>/app/Tests/WeChatAITests/LocalizationCoverageTests.swift。
    private static var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func englishStrings() throws -> [String: String] {
        let url = Self.appRoot.appendingPathComponent("Packaging/en.lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        let pattern = #""((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var result: [String: String] = [:]
        for match in regex.matches(in: text, range: range) {
            guard match.numberOfRanges == 3,
                  let keyRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text) else { continue }
            result[String(text[keyRange])] = String(text[valueRange])
        }
        return result
    }

    func testAuditedUserFacingStringsExistInEnglish() throws {
        let strings = try englishStrings()
        XCTAssertFalse(strings.isEmpty, "en.lproj/Localizable.strings 解析为空，路径不对？")

        let required = [
            // 微信备份删除确认（BackupService / SettingsView）。
            "将删除 %@ 的官方微信备份。",
            "文件 %@，占用 %@。",
            // 朋友圈只读门禁文案（4.2.1.5 朋友圈写链路未复测；门禁仍会用到）。
            "写链路仅只读",
            "当前微信版本的朋友圈写链路尚未通过真机验证；自动评论与回复已强制关闭，读取不受影响。",
            "当前微信版本的朋友圈写链路尚未通过真机验证；自动发布已强制关闭（演练草稿不受影响），读取不受影响。",
            "当前微信版本的朋友圈写链路尚未验证（强制只读）",
            // 版本表未验证的启动门禁引导。
            "地址表未验证",
            "微信 %@ 的 Hook 地址表尚未真机验证（%@）。启动 bridge 会修改微信内部函数，可能导致微信崩溃，已阻止启动。请换回已验证的微信版本（如 4.2.1.5），或等待该版本适配完成后再试。",
            "当前微信版本的版本表标记为未真机验证；启动机器人会注入错误地址并导致微信崩溃，因此已阻止启动。请换回已验证的微信版本（如 4.2.1.5），或等待该版本适配完成。",
            "当前微信版本的版本表尚未真机验证；安装可以继续，但启动机器人会被阻止，避免错误地址导致微信崩溃。请换回已验证的微信版本（如 4.2.1.5），或等待适配完成。",
            "bridge 未连接",
            "缺少发送句柄：请手动发一条文字和一条语音",
            "缺少文本句柄：请手动发一条文字",
            "缺少语音句柄：请手动发一条语音",
            "未启用 R3 原生发送（语音会降级文字）",
            "可发送语音",
            "旧版 CosyVoice3 服务仍在运行，请先退出旧版/重启 App",
            "删除微信备份",
            "删除后无法用该版本备份还原微信；需要时可重新备份。",
            "Hook 监听端口；修改后需重新安装 Hook 才会生效，bridge 会连接该端口",
            // 定时任务「下次执行」的未来时间文案。
            "即将",
            "%d 分钟后",
            // 清理/删除/压缩失败提示（真实结果未知时不能提示成功）。
            "清理聊天记录失败，请查看运行日志后重试",
            "删除聊天失败，请查看运行日志后重试",
            "压缩失败，请查看运行日志",
            "删除记忆失败，请查看运行日志",
            "删除记忆卡失败，请查看运行日志",
            "条数暂不可用，请重试",
            "消息发送失败，请查看运行日志",
            // Gadget 端口改动需要重新安装 Hook。
            "Gadget 端口已修改：端口在安装 Hook 时写入微信，需要重新「备份并安装 Hook」后才会生效；仅重启机器人不会生效",
        ]
        for key in required {
            let value = strings[key]
            XCTAssertNotNil(value, "英文界面缺少文案：\(key)")
            XCTAssertFalse(value?.isEmpty ?? true, "英文文案为空：\(key)")
        }
    }

    /// 版本支持文案不得再出现已移除的 4.1.x，且必须包含当前默认目标 4.2.1.5。
    func testUserFacingVersionListsExcludeRemovedVersions() throws {
        for language in ["en", "zh-Hans"] {
            let url = Self.appRoot.appendingPathComponent(
                "Packaging/\(language).lproj/Localizable.strings"
            )
            let text = try String(contentsOf: url, encoding: .utf8)
            for removed in ["4.1.15.55", "4.1.12", "4.1.15 /"] {
                XCTAssertFalse(
                    text.contains(removed),
                    "\(language) 文案仍包含已移除的微信版本：\(removed)"
                )
            }
            XCTAssertTrue(
                text.contains("4.2.1.5"),
                "\(language) 文案缺少当前默认目标微信 4.2.1.5"
            )
        }
    }

    /// 同一 key 重复出现时，后一条会静默覆盖前一条，容易造成「看起来翻译了、实际没生效」。
    func testEnglishStringsHaveNoDuplicateKeys() throws {
        let url = Self.appRoot.appendingPathComponent("Packaging/en.lproj/Localizable.strings")
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        let regex = try NSRegularExpression(pattern: #"^"((?:[^"\\]|\\.)*)"\s*="#)
        var seen = Set<String>()
        var duplicates: [String] = []
        for line in lines {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let keyRange = Range(match.range(at: 1), in: text) else { continue }
            let key = String(text[keyRange])
            if !seen.insert(key).inserted { duplicates.append(key) }
        }
        XCTAssertTrue(duplicates.isEmpty, "英文文案存在重复 key：\(duplicates.prefix(5))")
    }

    /// 英文文案里不允许残留中文：L() 未命中时会回退中文源串，英文界面等于没翻译。
    func testEnglishValuesContainNoChinese() throws {
        let strings = try englishStrings()
        XCTAssertFalse(strings.isEmpty)
        let han = try NSRegularExpression(pattern: #"\p{Han}"#)
        var leaking: [String] = []
        for (key, value) in strings {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            if han.firstMatch(in: value, range: range) != nil {
                leaking.append(key)
            }
        }
        XCTAssertTrue(
            leaking.isEmpty,
            "英文文案仍含中文（前 5 条）：\(leaking.sorted().prefix(5))"
        )
    }

    /// key 与英文译文的 %@ / %d / %.1f 等占位符必须完全一致：
    /// 少一个会在 String(format:) 丢参数，多一个会崩溃或输出空值。
    func testFormatPlaceholdersMatchBetweenKeyAndTranslation() throws {
        let strings = try englishStrings()
        let specifier = try NSRegularExpression(
            pattern: #"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:lld|ld|d|i|u|f|g|e|@|s)"#
        )
        func specifiers(_ text: String) -> [String] {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return specifier.matches(in: text, range: range).compactMap { match in
                Range(match.range, in: text).map { String(text[$0]) }
            }.sorted()
        }
        var mismatches: [String] = []
        for (key, value) in strings where key.contains("%") {
            if specifiers(key) != specifiers(value) {
                mismatches.append("\(key) -> \(value)")
            }
        }
        XCTAssertTrue(
            mismatches.isEmpty,
            "占位符不一致（前 5 条）：\(mismatches.sorted().prefix(5))"
        )
    }
}

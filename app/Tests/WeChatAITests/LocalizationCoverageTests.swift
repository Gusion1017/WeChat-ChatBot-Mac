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
            // 朋友圈只读门禁文案（当前无强制只读版本；未来版本未验证时仍会用到）。
            "写链路仅只读",
            "当前微信版本的朋友圈写链路尚未通过真机验证；自动评论与回复已强制关闭，读取不受影响。",
            "当前微信版本的朋友圈写链路尚未通过真机验证；自动发布已强制关闭（演练草稿不受影响），读取不受影响。",
            "当前微信版本的朋友圈写链路尚未验证（强制只读）",
            // 版本表未验证的启动门禁引导。
            "地址表未验证",
            "微信 %@ 的 Hook 地址表尚未真机验证（%@）。启动 bridge 会修改微信内部函数，可能导致微信崩溃，已阻止启动。请换回已验证的微信版本（如 4.2.1.3），或等待该版本适配完成后再试。",
            "当前微信版本的版本表标记为未真机验证；启动机器人会注入错误地址并导致微信崩溃，因此已阻止启动。请换回已验证的微信版本（如 4.2.1.3），或等待该版本适配完成。",
            "当前微信版本的版本表尚未真机验证；安装可以继续，但启动机器人会被阻止，避免错误地址导致微信崩溃。请换回已验证的微信版本（如 4.2.1.3），或等待适配完成。",
        ]
        for key in required {
            let value = strings[key]
            XCTAssertNotNil(value, "英文界面缺少文案：\(key)")
            XCTAssertFalse(value?.isEmpty ?? true, "英文文案为空：\(key)")
        }
    }

    /// 版本支持文案不得再出现已移除的 4.1.x，且必须包含当前默认目标 4.2.1.3。
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
                text.contains("4.2.1.3"),
                "\(language) 文案缺少当前默认目标微信 4.2.1.3"
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
}

import XCTest
@testable import WeChatAI

/// `ReleaseNotesDocument` 的解析测试：GitHub Release 正文包含下载表格、安装步骤、
/// 隐私说明等模板段落，更新页只应展示真正的「本版重点 / 更新内容」。
final class ReleaseNotesTests: XCTestCase {
    private func digest(_ body: String, version: String = "3.1.2") -> ReleaseNotesDocument {
        ReleaseNotesDocument.digest(from: body, versionLabel: version)
    }

    func testExtractsKeyChangesSectionFromReleaseTemplate() {
        let body = """
        # 微信 AI 助手（WeChat AI）v3.1.2

        项目简介不应出现在更新内容里。

        ## 下载

        | 文件 | 大小 | SHA256 |
        | --- | --- | --- |
        | `WeChat-AI-3.1.2.zip` | 65 MB | `abc` |

        ## 本版重点

        - **修复「节能与睡眠设置未生效」**：改为机器人运行期间生效。
        - 补齐反馈：未运行时提示「启动机器人后生效」。
        - 修正电源读取的 CF 所有权。

        ## 隐私说明（更新检查）

        - 更新检查不发送任何本机数据。

        ## 安装

        ```bash
        xattr -dr com.apple.quarantine
        ```

        ## 已知限制

        - 应用内更新未公证。
        """

        let document = digest(body)

        XCTAssertEqual(document.sectionTitle, "本版重点")
        XCTAssertFalse(document.isEmpty)
        XCTAssertEqual(document.versionLabel, "3.1.2")
        XCTAssertEqual(document.blocks.count, 3)
        XCTAssertTrue(document.blocks.allSatisfy {
            if case .bullet = $0 { return true }
            return false
        })
        XCTAssertTrue(document.blocks.contains {
            if case .bullet(let text) = $0 {
                return text.contains("节能与睡眠设置未生效")
            }
            return false
        })
        let joined = document.blocks.map { block -> String in
            if case .bullet(let text) = block { return text }
            if case .paragraph(let text) = block { return text }
            return ""
        }.joined(separator: "\n")
        XCTAssertFalse(joined.contains("WeChat-AI-3.1.2.zip"))
        XCTAssertFalse(joined.contains("隐私说明"))
        XCTAssertFalse(joined.contains("应用内更新未公证"))
    }

    func testPreferredHeadingVariants() {
        for heading in ["## 更新内容", "## 更新说明", "## What's Changed", "## Highlights"] {
            let body = "\(heading)\n\n- 一条更新\n- 另一条更新\n\n## 下载\n\n| a | b |"
            let document = digest(body)
            XCTAssertEqual(document.blocks.count, 2, "heading=\(heading)")
            XCTAssertFalse(document.isEmpty, "heading=\(heading)")
        }
    }

    func testNestedHeadingsStayInsideSectionAndStopAtNextTopLevelHeading() {
        let body = """
        ## 更新内容

        ### 新增

        - 新增能力 A

        ### 修复

        - 修复问题 B

        ## 下载

        - 不应出现
        """
        let document = digest(body)
        XCTAssertEqual(document.sectionTitle, "更新内容")
        XCTAssertEqual(document.blocks, [
            .heading("新增", level: 3),
            .bullet("新增能力 A"),
            .heading("修复", level: 3),
            .bullet("修复问题 B"),
        ])
    }

    func testFallbackFiltersBoilerplateSections() {
        let body = """
        # 标题

        ## 下载

        | 文件 | 大小 |

        ## 安装

        - 安装步骤不应展示

        ## 其他变更

        - 保留这条更新

        ## 已知限制

        - 限制不应展示
        """
        let document = digest(body)
        XCTAssertFalse(document.isEmpty)
        XCTAssertTrue(document.blocks.contains(.heading("其他变更", level: 2)))
        XCTAssertTrue(document.blocks.contains(.bullet("保留这条更新")))
        XCTAssertFalse(document.blocks.contains(.bullet("安装步骤不应展示")))
        XCTAssertFalse(document.blocks.contains(.bullet("限制不应展示")))
    }

    func testFallbackWithoutHeadingsKeepsParagraphsAndLists() {
        let body = """
        修复了若干问题。

        - 第一条
        - 第二条
        """
        let document = digest(body)
        XCTAssertEqual(document.sectionTitle, "更新内容")
        XCTAssertEqual(document.blocks, [
            .paragraph("修复了若干问题。"),
            .bullet("第一条"),
            .bullet("第二条"),
        ])
    }

    func testEmptyBodyProducesEmptyDocument() {
        XCTAssertTrue(digest("").isEmpty)
        XCTAssertTrue(digest("   \n\n  ").isEmpty)
        XCTAssertEqual(digest("").sectionTitle, "更新内容")
    }

    func testCRLFAndBOMNormalized() {
        let body = "\u{FEFF}## 更新内容\r\n\r\n- 第一行\r\n- 第二行\r\n"
        let document = digest(body)
        XCTAssertEqual(document.blocks, [.bullet("第一行"), .bullet("第二行")])
    }

    func testSoftWrappedParagraphJoinsCJKWithoutSpaceAndLatinWithSpace() {
        let body = """
        ## 更新内容

        这是一段
        中文说明

        This is a
        Latin paragraph.
        """
        let document = digest(body)
        XCTAssertEqual(document.blocks, [
            .paragraph("这是一段中文说明"),
            .paragraph("This is a Latin paragraph."),
        ])
    }

    func testCodeFenceBecomesCodeBlockAndIsNotParagraph() {
        let body = """
        ## 更新内容

        修复命令：

        ```bash
        xattr -dr com.apple.quarantine "WeChat AI.app"
        ```

        完成。
        """
        let document = digest(body)
        XCTAssertEqual(document.blocks, [
            .paragraph("修复命令："),
            .code("xattr -dr com.apple.quarantine \"WeChat AI.app\""),
            .paragraph("完成。"),
        ])
    }

    func testNumberedListKeepsNumber() {
        let body = """
        ## 更新内容

        1. 第一项
        2) 第二项
        """
        XCTAssertEqual(digest(body).blocks, [
            .numbered("1. 第一项"),
            .numbered("2) 第二项"),
        ])
    }

    func testTableDividerAndImageLinesIgnored() {
        let body = """
        ## 更新内容

        - 保留

        | 表格 | 不应出现 |
        | --- | --- |
        ---
        ![截图](https://example.com/a.png)
        """
        XCTAssertEqual(digest(body).blocks, [.bullet("保留")])
    }

    func testInlineMarkdownKeptForRenderer() {
        let body = """
        ## 更新内容

        - **加粗**、`代码` 与 [链接](https://example.com) 保留
        """
        XCTAssertEqual(digest(body).blocks, [
            .bullet("**加粗**、`代码` 与 [链接](https://example.com) 保留"),
        ])
    }

    func testBlockquoteParsed() {
        let body = """
        ## 更新内容

        > 重要提示
        """
        XCTAssertEqual(digest(body).blocks, [.quote("重要提示")])
    }

    func testActualReleaseTemplateKeepsOnlyKeyChanges() {
        let body = """
        # 微信 AI 助手（WeChat AI）v3.1.2

        macOS 原生微信 AI 助手：通过 Frida Gadget 注入本机官方微信。

        ## 下载

        | 文件 | 大小 | SHA256 |
        | --- | --- | --- |
        | `WeChat-AI-3.1.2.zip` | 65 MB | `3efd` |

        - 平台：Apple Silicon（arm64）
        - 系统：macOS 26+
        - 版本：`3.1.2 (build 29)`

        ## 本版重点

        - **修复「节能与睡眠设置未生效」**：`general.sleepPrevention` 明确为「机器人运行期间生效」。
        - `startRuntime` / `stopRuntime` 持有/释放 IOKit 断言。
        - 无其他功能变更；应用内更新等功能保持。

        ## 隐私说明（更新检查）

        - 更新检查访问公开 GitHub API。

        ## 安装

        1. 解压 zip。

        ## 包含内容

        - SwiftUI App

        ## 已知限制

        - 未公证。
        """
        let document = digest(body, version: "3.1.2")
        XCTAssertEqual(document.sectionTitle, "本版重点")
        XCTAssertEqual(document.blocks.count, 3)
        XCTAssertFalse(document.blocks.contains { block in
            if case .paragraph(let text) = block { return text.contains("macOS 原生") }
            return false
        })
        XCTAssertFalse(document.blocks.contains { block in
            if case .paragraph(let text) = block { return text.contains("解压 zip") }
            return false
        })
    }

    func testBulletContinuationLinesJoinIntoOneBullet() {
        let body = """
        ## 本版重点

        - `startRuntime` / `stopRuntime` 持有/释放断言；
          机器人未运行时只保存偏好。
        - **第二条**：完整说明
        """
        XCTAssertEqual(digest(body).blocks, [
            .bullet("`startRuntime` / `stopRuntime` 持有/释放断言；机器人未运行时只保存偏好。"),
            .bullet("**第二条**：完整说明"),
        ])
    }

    func testHeadingOnlySectionIsEmpty() {
        let body = """
        ## 更新内容

        ## 下载

        - x
        """
        XCTAssertTrue(digest(body).isEmpty)
    }
}

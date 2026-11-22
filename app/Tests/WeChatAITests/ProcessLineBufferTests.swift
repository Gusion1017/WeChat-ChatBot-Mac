import Foundation
import XCTest
@testable import WeChatAI

/// 管道输出按字节块到达：切在多字节 UTF-8 字符中间时不能丢整块（bridge 日志/安装进度/JSON）。
final class ProcessLineBufferTests: XCTestCase {
    func testMultiByteCharacterSplitAcrossChunksIsPreserved() {
        let buffer = LineBuffer()
        let text = "安装失败：缺少令牌\n完成\n"
        let bytes = Array(text.utf8)
        var lines: [String] = []
        var index = 0
        // 每 3 字节一块：必然落在「败」「少」等 3 字节汉字内部。
        while index < bytes.count {
            let end = min(index + 3, bytes.count)
            lines += buffer.append(Data(bytes[index..<end]))
            index = end
        }
        XCTAssertEqual(lines, ["安装失败：缺少令牌", "完成"])
    }

    func testIncompleteTailIsKeptUntilFlush() {
        let buffer = LineBuffer()
        let text = "进度 42 秒"
        let bytes = Array(text.utf8)
        // 去掉最后一个汉字的一半：append 不应吞掉整段，flush 用替换符兜底。
        let partial = Data(bytes.dropLast(1))
        XCTAssertEqual(buffer.append(partial), [])
        XCTAssertEqual(buffer.append(Data([0x0A])), ["进度 42 �"])
    }

    func testPlainNewlinesSplit() {
        let buffer = LineBuffer()
        let lines = buffer.append(Data("a\nb\n".utf8))
        XCTAssertEqual(lines, ["a", "b"])
    }

    func testAnsiAndCarriageReturnStillStripped() {
        let buffer = LineBuffer()
        let lines = buffer.append(Data("\u{1B}[90mgray\u{1B}[0m\r\nok\n".utf8))
        XCTAssertEqual(lines, ["gray", "ok"])
    }
}

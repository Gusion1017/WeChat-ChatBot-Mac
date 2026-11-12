import XCTest
@testable import WeChatAI

/// R3 发送句柄日志解析回归：
/// 实际 bridge/hook 行格式与旧匹配器不一致，曾导致「句柄已捕获但界面仍等待」。
final class HookR3LogParsingTests: XCTestCase {
    func testCaptureAndPersistLinesMarkSeeded() {
        let lines = [
            "[capture] slot13 newsendmsg 闭包 0x8902fb150 -> clone 0x88ed49a40",
            "R3 发送句柄已持久化 pid=99494 seed=0x88ed49a40",
            "[+] R3: 发送句柄已提交持久化 (seed=0x88ed49a40)",
            "[+] R3: 从 bridge 恢复发送句柄 seed=0x88ed49a40",
            "R3 发送句柄恢复（bridge 重启）",
            "R3: 捕获 newsendmsg 闭包",
        ]
        for line in lines {
            let effect = HookManager.bridgeLineEffect(line)
            XCTAssertEqual(effect?.r3Seeded, true, line)
            XCTAssertEqual(effect?.r3Active, true, line)
            XCTAssertEqual(effect?.r3Queued, 0, line)
        }
    }

    func testStaleAndQueueLinesMarkNotSeeded() {
        let lines = [
            "R3 发送句柄记录已过期（微信已重启），等待重新捕获",
            "R3 发送句柄已失效",
            "尚无发送句柄，等待手动发送",
            "消息已排队，等待发送句柄",
        ]
        for line in lines {
            let effect = HookManager.bridgeLineEffect(line)
            XCTAssertEqual(effect?.r3Seeded, false, line)
            XCTAssertEqual(effect?.r3Active, true, line)
        }
    }

    func testR3InitOnlyActivatesWithoutSeeding() {
        let effect = HookManager.bridgeLineEffect(
            "[+] R3: init 完成 (capture=true, url=/cgi-bin/micromsg-bin/newsendmsg)"
        )
        XCTAssertEqual(effect?.r3Active, true)
        XCTAssertNil(effect?.r3Seeded, "init 完成不代表已经拿到句柄")
    }

    func testUnrelatedLinesDoNotChangeR3() {
        for line in [
            "HTTP 服务启动在 host=127.0.0.1:58080",
            "通讯录目录已更新 group_members=10",
        ] {
            let effect = HookManager.bridgeLineEffect(line)
            XCTAssertNil(effect?.r3Active, line)
            XCTAssertNil(effect?.r3Seeded, line)
        }
    }
}

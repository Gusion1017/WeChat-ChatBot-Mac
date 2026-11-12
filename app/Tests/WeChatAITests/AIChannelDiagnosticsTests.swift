import XCTest

@testable import WeChatAI

/// 默认通道可用性分类与连接测试世代号：页面据此给出可执行按钮、丢弃过期测试结果。
final class AIChannelDiagnosticsTests: XCTestCase {
    func testDiagnosisCoversDisabledAndMissingCredential() {
        let usable = provider(kind: .deepSeek, enabled: true, apiKeyReference: "key")
        XCTAssertTrue(DefaultChannelDiagnosis.evaluate(provider: usable).isUsable)

        let disabled = DefaultChannelDiagnosis.evaluate(
            provider: provider(kind: .deepSeek, enabled: false, apiKeyReference: "key")
        )
        XCTAssertFalse(disabled.isUsable)
        XCTAssertTrue(disabled.needsEnable)
        XCTAssertFalse(disabled.needsCredential)

        let missingKey = DefaultChannelDiagnosis.evaluate(
            provider: provider(kind: .openAI, enabled: true, apiKeyReference: "")
        )
        XCTAssertFalse(missingKey.isUsable)
        XCTAssertFalse(missingKey.needsEnable)
        XCTAssertTrue(missingKey.needsCredential)

        // 同时停用且缺少密钥：两个操作都要给出。
        let both = DefaultChannelDiagnosis.evaluate(
            provider: provider(kind: .openAI, enabled: false, apiKeyReference: "")
        )
        XCTAssertFalse(both.isUsable)
        XCTAssertTrue(both.needsEnable)
        XCTAssertTrue(both.needsCredential)
    }

    func testDiagnosisTreatsKeylessKindsAsUsable() {
        // Ollama / 自定义兼容端点允许无密钥，不应被误判为「缺少 API Key」。
        for kind in [ProviderKind.ollama, .custom] {
            let diagnosis = DefaultChannelDiagnosis.evaluate(
                provider: provider(kind: kind, enabled: true, apiKeyReference: "")
            )
            XCTAssertTrue(diagnosis.isUsable, "\(kind) 无密钥也应可用")
        }
    }

    func testTrackerDiscardsResultsAfterInvalidation() {
        var tracker = ProviderTestTracker()
        let first = tracker.begin("p1")
        XCTAssertTrue(tracker.isCurrent(first, for: "p1"))

        // 编辑保存/删除通道后，旧测试结果（含在途请求）必须失效。
        tracker.invalidate("p1")
        XCTAssertFalse(tracker.isCurrent(first, for: "p1"))

        let second = tracker.begin("p1")
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(tracker.isCurrent(second, for: "p1"))

        // 不同通道互不影响。
        let other = tracker.begin("p2")
        XCTAssertTrue(tracker.isCurrent(other, for: "p2"))
        XCTAssertFalse(tracker.isCurrent(other, for: "p1"))
    }

    // MARK: - Helpers

    private func provider(
        kind: ProviderKind,
        enabled: Bool,
        apiKeyReference: String
    ) -> AIProvider {
        AIProvider(
            id: "provider-\(kind.rawValue)",
            name: "通道",
            kind: kind,
            baseURL: "https://example.test/v1",
            model: "test-model",
            apiKeyReference: apiKeyReference,
            maxTokens: 800,
            timeoutSeconds: 60,
            stream: true,
            enabled: enabled,
            isDefault: false
        )
    }
}

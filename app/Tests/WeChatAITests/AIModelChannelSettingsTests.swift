import XCTest

@testable import WeChatAI

/// 通道温度与新通道类型白名单的纯逻辑：
/// 温度按通道配置、未配置时不发送 temperature；新通道仅 DeepSeek / 自定义。
final class AIModelChannelSettingsTests: XCTestCase {
    // MARK: - 通道温度

    func testProviderRequestTemperatureDefaultsToNilAndClamps() {
        var provider = makeProvider()
        XCTAssertNil(provider.requestTemperature, "未配置时省略 temperature")

        provider.temperatureOverride = 3
        XCTAssertEqual(provider.requestTemperature, ModelTemperature.range.upperBound)
        provider.temperatureOverride = -2
        XCTAssertEqual(provider.requestTemperature, ModelTemperature.range.lowerBound)
        provider.temperatureOverride = 0.7
        XCTAssertEqual(provider.requestTemperature ?? -1, 0.7, accuracy: 0.0001)
    }

    func testModelTemperatureRangeRoundingAndDisplay() {
        XCTAssertEqual(ModelTemperature.range, 0...2)
        XCTAssertEqual(ModelTemperature.clamp(-1), 0)
        XCTAssertEqual(ModelTemperature.clamp(3), 2)
        XCTAssertEqual(ModelTemperature.rounded(0.74), 0.7, accuracy: 0.0001)
        XCTAssertEqual(ModelTemperature.rounded(0.76), 0.8, accuracy: 0.0001)
        XCTAssertEqual(ModelTemperature.display(0.74), "0.7")
        XCTAssertEqual(ModelTemperature.initialValue, 0.7)
    }

    func testRequestBodyOmitsTemperatureWhenUnsetAndClampsWhenSet() throws {
        var provider = makeProvider(model: "deepseek-chat")
        let unset = try requestBody(provider: provider)
        XCTAssertNil(unset["temperature"])

        provider.temperatureOverride = 3
        let clamped = try requestBody(provider: provider)
        XCTAssertEqual(clamped["temperature"] as? Double, ModelTemperature.range.upperBound)
    }

    // MARK: - 新通道类型白名单

    func testNewChannelKindsOnlyDeepSeekAndCustom() {
        XCTAssertEqual(AIProviderKindSelection.creatable, [.deepSeek, .custom])
        XCTAssertEqual(AIProviderKindSelection.options(current: .deepSeek), [.deepSeek, .custom])
        XCTAssertEqual(AIProviderKindSelection.options(current: .custom), [.custom, .deepSeek])
    }

    func testEditingLegacyKindKeepsCurrentOption() {
        // 历史 OpenAI/Ollama 通道必须还能编辑，Picker 不能选中一个不在列表里的值。
        XCTAssertEqual(
            AIProviderKindSelection.options(current: .openAI),
            [.openAI, .deepSeek, .custom]
        )
        XCTAssertEqual(
            AIProviderKindSelection.options(current: .ollama),
            [.ollama, .deepSeek, .custom]
        )
        XCTAssertTrue(AIProviderKindSelection.isLegacy(.openAI))
        XCTAssertTrue(AIProviderKindSelection.isLegacy(.ollama))
        XCTAssertFalse(AIProviderKindSelection.isLegacy(.deepSeek))
        XCTAssertFalse(AIProviderKindSelection.isLegacy(.custom))
    }

    func testCreatableKindsAreValidProviders() {
        for kind in AIProviderKindSelection.creatable {
            XCTAssertFalse(kind.label.isEmpty)
            // 自定义兼容的地址/模型由用户填写，默认值为空是预期行为。
            if kind != .custom {
                XCTAssertFalse(kind.defaultBaseURL.isEmpty)
                XCTAssertFalse(kind.defaultModel.isEmpty)
            }
        }
        XCTAssertEqual(ProviderKind.custom.defaultModel, "")
    }

    // MARK: - Helpers

    private func makeProvider(
        id: String = "p",
        name: String = "P",
        model: String = "m"
    ) -> AIProvider {
        AIProvider(
            id: id,
            name: name,
            kind: .custom,
            baseURL: "https://example.test/v1",
            model: model,
            apiKeyReference: "key-\(id)",
            maxTokens: 800,
            timeoutSeconds: 60,
            stream: true,
            enabled: true,
            isDefault: false
        )
    }

    private func requestBody(provider: AIProvider) throws -> [String: Any] {
        let data = try AIClient.requestBody(
            messages: [.user("hi")],
            provider: provider,
            temperature: provider.requestTemperature,
            stream: false
        )
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}

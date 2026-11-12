import XCTest
@testable import WeChatAI

/// 旧温度配置 → 按通道温度的迁移：
/// - 旧默认 0.7 不代表用户自定义，不能凭空播种；
/// - 旧“按模型温度”表值迁移到对应模型的通道；
/// - 迁移只执行一次，且不覆盖通道里已有的显式温度。
final class TemperatureMigrationTests: XCTestCase {
    private func provider(
        id: String = UUID().uuidString,
        name: String = "DeepSeek",
        kind: ProviderKind = .deepSeek,
        model: String = "deepseek-chat",
        legacyTemperature: Double = AIProvider.legacyDefaultTemperature,
        override: Double? = nil
    ) -> AIProvider {
        var provider = AIProvider(
            id: id,
            name: name,
            kind: kind,
            baseURL: kind.defaultBaseURL,
            model: model,
            apiKeyReference: "ref",
            temperature: legacyTemperature,
            maxTokens: 800,
            timeoutSeconds: 60,
            stream: true,
            enabled: true,
            isDefault: false
        )
        provider.temperatureOverride = override
        return provider
    }

    func testLegacyDefaultTemperatureIsNotMigrated() {
        let providers = [
            provider(),
            provider(name: "Ollama", kind: .ollama, model: "qwen3:8b"),
        ]
        XCTAssertNil(
            AISettings.migratedLegacyTemperatures(providers: providers),
            "旧版默认 0.7 不应变成自定义温度"
        )
    }

    func testCustomLegacyTemperatureIsMigratedPerModel() {
        let providers = [
            provider(model: "deepseek-chat", legacyTemperature: 0.2),
            provider(name: "OpenAI", kind: .openAI, model: "gpt-4o-mini", legacyTemperature: 1.4),
        ]
        let migrated = AISettings.migratedLegacyTemperatures(providers: providers)
        XCTAssertEqual(migrated?["deepseek-chat"], 0.2)
        XCTAssertEqual(migrated?["gpt-4o-mini"], 1.4)
        XCTAssertEqual(migrated?.count, 2)
    }

    func testMigrationUsesEffectiveModelAndKeepsFirstValue() {
        let providers = [
            provider(name: "DeepSeek 1", model: "", legacyTemperature: 0.3),
            provider(name: "DeepSeek 2", model: "deepseek-chat", legacyTemperature: 1.1),
            provider(name: "Broken", model: "  ", legacyTemperature: 0.1),
        ]
        let migrated = AISettings.migratedLegacyTemperatures(providers: providers)
        XCTAssertEqual(migrated?["deepseek-chat"], 0.3)
        XCTAssertEqual(migrated?.count, 1)
    }

    func testLegacyPerChannelTemperatureMovesToOverride() {
        var settings = AISettings()
        settings.modelTemperatures = nil
        var providers = [
            provider(id: "a", model: "deepseek-chat", legacyTemperature: 0.2),
            provider(id: "b", model: "other", legacyTemperature: 1.4),
        ]

        XCTAssertTrue(
            AISettings.migrateTemperaturesToChannels(&settings, providers: &providers)
        )
        XCTAssertEqual(providers[0].temperatureOverride, 0.2)
        XCTAssertEqual(providers[1].temperatureOverride, 1.4)
        XCTAssertTrue(settings.temperaturesMovedToChannels)
        // 只迁移一次：再次调用不应覆盖之后的修改。
        providers[0].temperatureOverride = 1.1
        XCTAssertFalse(
            AISettings.migrateTemperaturesToChannels(&settings, providers: &providers)
        )
        XCTAssertEqual(providers[0].temperatureOverride, 1.1)
    }

    func testPerModelTemperatureTableMovesToChannelsAndClamps() {
        var settings = AISettings()
        settings.modelTemperatures = [
            "deepseek-chat": 0.9,
            "gpt-4o-mini": 3,
        ]
        var providers = [
            provider(id: "a", model: "deepseek-chat"),
            provider(id: "b", kind: .openAI, model: "gpt-4o-mini"),
            provider(id: "c", kind: .custom, model: "other"),
        ]

        XCTAssertTrue(
            AISettings.migrateTemperaturesToChannels(&settings, providers: &providers)
        )
        XCTAssertEqual(providers[0].temperatureOverride, 0.9)
        XCTAssertEqual(providers[1].temperatureOverride, 2, "迁移时 clamp 到 0–2")
        XCTAssertNil(providers[2].temperatureOverride)
        // 旧表保留用于旧版本回滚，但迁移标记阻止再次覆盖。
        XCTAssertEqual(settings.modelTemperatures?["deepseek-chat"], 0.9)
    }

    func testSharedModelChannelsEachReceiveTheLegacyTemperature() {
        var settings = AISettings()
        settings.modelTemperatures = ["deepseek-chat": 0.6]
        var providers = [
            provider(id: "a", model: "deepseek-chat"),
            provider(id: "b", name: "备用", model: "deepseek-chat"),
        ]

        AISettings.migrateTemperaturesToChannels(&settings, providers: &providers)
        XCTAssertEqual(providers[0].temperatureOverride, 0.6)
        XCTAssertEqual(providers[1].temperatureOverride, 0.6)
    }

    func testExplicitChannelTemperatureWinsOverLegacyTable() {
        var settings = AISettings()
        settings.modelTemperatures = ["deepseek-chat": 0.9]
        var providers = [
            provider(id: "a", model: "deepseek-chat", override: 0.3),
        ]

        AISettings.migrateTemperaturesToChannels(&settings, providers: &providers)
        XCTAssertEqual(providers[0].temperatureOverride, 0.3, "新字段已有值时不覆盖")
        XCTAssertTrue(settings.temperaturesMovedToChannels)
    }

    func testAlreadyMigratedSettingsAreNoOp() {
        var settings = AISettings()
        settings.temperaturesMovedToChannels = true
        settings.modelTemperatures = ["deepseek-chat": 1.2]
        var providers = [provider(model: "deepseek-chat")]

        XCTAssertFalse(
            AISettings.migrateTemperaturesToChannels(&settings, providers: &providers)
        )
        XCTAssertNil(providers[0].temperatureOverride)
    }
}

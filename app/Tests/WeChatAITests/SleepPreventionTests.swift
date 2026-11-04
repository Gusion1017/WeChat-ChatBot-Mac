import XCTest
@testable import WeChatAI

/// Unit tests for the idle-sleep prevention preference, its pure decision logic, and
/// (see `SleepPreventionApplyTests` below) the `apply(mode:)` lifecycle driven by an
/// injected fake driver.
///
/// These tests never call IOKit assertion APIs: they decode/encode settings, exercise
/// `SleepPreventionCenter.shouldPreventSleep`, and drive the centre through a fake
/// `SleepPreventionDriver`, so running them cannot change the machine's sleep state.
final class SleepPreventionTests: XCTestCase {
    // MARK: - Backwards-compatible settings decoding

    func testLegacyGeneralSettingsWithoutSleepPreventionFallsBackToNever() throws {
        // 旧配置仍带有已删除的 showInMenuBar / showDockIcon 键：未知键必须被忽略，
        // 且不能影响其余字段的加载。
        let json = """
        {
          "appearance": "dark",
          "showInMenuBar": false,
          "launchAtLogin": true,
          "notificationsEnabled": false,
          "soundEnabled": true,
          "confirmBeforeQuit": false,
          "showDockIcon": false,
          "language": "en"
        }
        """

        let settings = try JSONDecoder().decode(GeneralSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.sleepPrevention, .never)
        XCTAssertEqual(settings.appearance, .dark)
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertFalse(settings.notificationsEnabled)
        XCTAssertTrue(settings.soundEnabled)
        XCTAssertFalse(settings.confirmBeforeQuit)
        XCTAssertEqual(settings.language, "en")
    }

    func testRemovedWindowPreferenceKeysAreIgnored() throws {
        // Dock/菜单栏入口现在跟随窗口状态，不再有用户开关。
        let json = """
        {
          "showInMenuBar": false,
          "showDockIcon": true
        }
        """

        let settings = try JSONDecoder().decode(GeneralSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings, GeneralSettings())
    }

    func testLegacyConfigFileWithoutSleepPreventionStillLoads() throws {
        let encoded = try JSONEncoder().encode(AppSettings.default)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var general = try XCTUnwrap(root["general"] as? [String: Any])
        XCTAssertNotNil(general["sleepPrevention"], "新配置应写入 sleepPrevention")
        general.removeValue(forKey: "sleepPrevention")
        root["general"] = general
        let legacyData = try JSONSerialization.data(withJSONObject: root)

        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacyData)

        XCTAssertEqual(decoded.general.sleepPrevention, .never)
        XCTAssertEqual(decoded.general, AppSettings.default.general)
    }

    func testUnknownSleepPreventionRawValueFallsBackToNever() throws {
        let json = """
        {
          "appearance": "unknown-appearance",
          "sleepPrevention": "sometimes"
        }
        """

        let settings = try JSONDecoder().decode(GeneralSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.sleepPrevention, .never)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertEqual(settings.language, "system")
    }

    func testSleepPreventionEncodingRoundtrip() throws {
        var settings = GeneralSettings()
        settings.appearance = .light
        settings.launchAtLogin = true
        settings.sleepPrevention = .externalPowerOnly

        let data = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["sleepPrevention"] as? String, SleepPreventionMode.externalPowerOnly.rawValue)
        // 已删除的窗口偏好不应再写回配置文件。
        XCTAssertNil(object["showInMenuBar"])
        XCTAssertNil(object["showDockIcon"])

        let decoded = try JSONDecoder().decode(GeneralSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    // MARK: - Mode metadata

    func testSleepPreventionModeRawValuesAndLabels() {
        XCTAssertEqual(SleepPreventionMode.allCases.map(\.rawValue), ["never", "externalPowerOnly", "always"])
        XCTAssertEqual(SleepPreventionMode.never.label, "永不")
        XCTAssertEqual(SleepPreventionMode.externalPowerOnly.label, "接入电源时")
        XCTAssertEqual(SleepPreventionMode.always.label, "始终")
        XCTAssertEqual(Set(SleepPreventionMode.allCases.map(\.id)).count, 3)
    }

    func testSleepPreventionModeDetailsAreNonEmpty() {
        for mode in SleepPreventionMode.allCases {
            XCTAssertFalse(mode.label.isEmpty, "\(mode.rawValue) 缺少标签")
            XCTAssertFalse(mode.detail.isEmpty, "\(mode.rawValue) 缺少说明")
        }
        XCTAssertEqual(SleepPreventionMode.never.rawValue, "never")
        XCTAssertTrue(SleepPreventionMode.externalPowerOnly.detail.contains("电池"))
        XCTAssertTrue(SleepPreventionMode.always.detail.contains("电池"))
    }

    // MARK: - Decision table

    func testShouldPreventSleepNever() {
        XCTAssertFalse(SleepPreventionCenter.shouldPreventSleep(mode: .never, onExternalPower: true))
        XCTAssertFalse(SleepPreventionCenter.shouldPreventSleep(mode: .never, onExternalPower: false))
    }

    func testShouldPreventSleepAlways() {
        XCTAssertTrue(SleepPreventionCenter.shouldPreventSleep(mode: .always, onExternalPower: true))
        XCTAssertTrue(SleepPreventionCenter.shouldPreventSleep(mode: .always, onExternalPower: false))
    }

    func testShouldPreventSleepExternalPowerOnly() {
        XCTAssertTrue(SleepPreventionCenter.shouldPreventSleep(mode: .externalPowerOnly, onExternalPower: true))
        XCTAssertFalse(SleepPreventionCenter.shouldPreventSleep(mode: .externalPowerOnly, onExternalPower: false))
    }
}

// MARK: - 机器人运行期间生效（2026-11-04 回归）

/// 断言只在机器人运行时持有：`apply(mode:)` 在未运行时只保存档位、不创建断言；
/// `setRuntimeActive(true)` 后按「档位 + 电源状态」恢复，`setRuntimeActive(false)` 立即释放。
///
/// 这些用例注入假驱动（假电源 + 假断言），不调用任何 IOKit API，因此在任意机器/CI 上
/// 都能验证门控语义，也保证「未运行时修改档位」不会悄悄改变整机睡眠行为。
final class SleepPreventionApplyTests: XCTestCase {
    /// 假驱动的状态与调用记录；引用类型便于在 `MainActor.run` 闭包里写读。
    private final class DriverSpy: @unchecked Sendable {
        var onExternalPower: Bool? = true
        var createCount = 0
        var releaseCount = 0
        var reasons: [String] = []
        var createError: SleepAssertionError?
        var releaseResult: SleepAssertionResult = 0
        private var nextID: SleepAssertionID = 100

        var driver: SleepPreventionDriver {
            SleepPreventionDriver(
                readExternalPower: { [self] in onExternalPower },
                createAssertion: { [self] reason in
                    if let createError { throw createError }
                    createCount += 1
                    reasons.append(reason)
                    defer { nextID += 1 }
                    return nextID
                },
                releaseAssertion: { [self] _ in
                    releaseCount += 1
                    return releaseResult
                },
                observesPowerSourceChanges: false
            )
        }
    }

    func testApplyWhileRuntimeInactiveDoesNotHoldAssertion() async {
        let spy = DriverSpy()
        spy.onExternalPower = true
        let outcome = await MainActor.run { () -> (preventing: Bool, running: Bool, creates: Int) in
            let center = SleepPreventionCenter(driver: spy.driver)
            center.apply(mode: .always)
            return (center.isPreventingSleep, center.isRuntimeActive, spy.createCount)
        }
        XCTAssertFalse(outcome.preventing, "机器人未运行时不应持有防睡眠断言")
        XCTAssertFalse(outcome.running)
        XCTAssertEqual(outcome.creates, 0, "机器人未运行时不应创建断言")
    }

    func testRuntimeStartAppliesPreferenceAndStopReleases() async {
        let spy = DriverSpy()
        spy.onExternalPower = false   // 电池上也应按「始终」执行
        let outcome = await MainActor.run {
            () -> (before: Bool, running: Bool, stopped: Bool, creates: Int, releases: Int) in
            let center = SleepPreventionCenter(driver: spy.driver)
            center.apply(mode: .always)
            let before = center.isPreventingSleep
            center.setRuntimeActive(true)
            let running = center.isPreventingSleep
            center.setRuntimeActive(false)
            return (before, running, center.isPreventingSleep, spy.createCount, spy.releaseCount)
        }
        XCTAssertFalse(outcome.before, "运行机器人之前不应持有断言")
        XCTAssertTrue(outcome.running, "机器人启动后应按偏好恢复断言")
        XCTAssertFalse(outcome.stopped, "停止机器人后应立即释放断言")
        XCTAssertEqual(outcome.creates, 1)
        XCTAssertEqual(outcome.releases, 1)
    }

    func testExternalPowerOnlyFollowsPowerSourceWhileRuntimeActive() async {
        let spy = DriverSpy()
        let outcome = await MainActor.run { () -> (ac: Bool, battery: Bool, releases: Int) in
            let center = SleepPreventionCenter(driver: spy.driver)
            center.apply(mode: .externalPowerOnly)
            center.setRuntimeActive(true)
            spy.onExternalPower = true
            center.apply(mode: .externalPowerOnly)
            let ac = center.isPreventingSleep
            spy.onExternalPower = false
            center.apply(mode: .externalPowerOnly)
            return (ac, center.isPreventingSleep, spy.releaseCount)
        }
        XCTAssertTrue(outcome.ac)
        XCTAssertFalse(outcome.battery)
        XCTAssertEqual(outcome.releases, 1)
    }

    func testRepeatedApplyIsIdempotent() async {
        let spy = DriverSpy()
        let outcome = await MainActor.run { () -> (creates: Int, releases: Int) in
            let center = SleepPreventionCenter(driver: spy.driver)
            center.setRuntimeActive(true)
            center.apply(mode: .always)
            center.apply(mode: .always)
            center.apply(mode: .always)
            let creates = spy.createCount
            center.apply(mode: .never)
            center.apply(mode: .never)
            return (creates, spy.releaseCount)
        }
        XCTAssertEqual(outcome.creates, 1, "重复应用同一档位不应反复创建断言")
        XCTAssertEqual(outcome.releases, 1, "重复关闭不应反复释放断言")
    }

    func testCreateFailureSurfacesLastError() async {
        let spy = DriverSpy()
        spy.createError = SleepAssertionError(code: -536_870_201)
        let outcome = await MainActor.run { () -> (preventing: Bool, error: String?) in
            let center = SleepPreventionCenter(driver: spy.driver)
            center.setRuntimeActive(true)
            center.apply(mode: .always)
            return (center.isPreventingSleep, center.lastError)
        }
        XCTAssertFalse(outcome.preventing)
        XCTAssertTrue(outcome.error?.contains("-536870201") == true, "失败原因应带 IOKit 返回码")
    }

    func testReleaseFailureSurfacesLastError() async {
        let spy = DriverSpy()
        spy.releaseResult = -1
        let outcome = await MainActor.run { () -> String? in
            let center = SleepPreventionCenter(driver: spy.driver)
            center.setRuntimeActive(true)
            center.apply(mode: .always)
            spy.onExternalPower = false
            center.apply(mode: .externalPowerOnly)   // 电池 → 释放；释放失败应记录原因
            return center.lastError
        }
        XCTAssertTrue(outcome?.contains("-1") == true)
    }
}

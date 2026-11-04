import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import Observation

// MARK: - System seam

/// `IOPMAssertionID`（`UInt32`）与 `IOReturn`（`Int32`）的朴素别名。
///
/// 驱动接口只暴露这两个标量类型，单测 target 因此不必 import IOKit 头文件，
/// 也不会因为「跑测试」而创建真实断言或读取真实电源状态。
typealias SleepAssertionID = UInt32
typealias SleepAssertionResult = Int32

/// `SleepPreventionCenter` 用到的全部系统副作用，集中成一个可注入的驱动。
///
/// 生产实现是 `.system`（直接调 IOKit）；单测注入纯内存假实现，验证「设置是否生效」
/// 而不触碰真实电源与断言（见 `Tests/WeChatAITests/SleepPreventionTests.swift`）。
struct SleepPreventionDriver {
    /// 读取当前是否由外接电源供电。`nil` = 读不到（台式机 / 瞬态 IOKit 失败），
    /// 调用方按外接电源处理，保证 `.externalPowerOnly` 在没有电池的 Mac 上仍然可用。
    var readExternalPower: () -> Bool?
    /// 创建空闲系统睡眠断言并返回断言 ID；失败抛 `SleepAssertionError`。
    var createAssertion: (_ reason: String) throws -> SleepAssertionID
    /// 释放断言，返回 IOKit 返回码。
    var releaseAssertion: (_ assertionID: SleepAssertionID) -> SleepAssertionResult
    /// 是否注册电源状态变化通知。单测关闭：不碰主 RunLoop 与 IOKit 通知源。
    var observesPowerSourceChanges: Bool

    static let system = SleepPreventionDriver(
        readExternalPower: { SleepPreventionCenter.currentlyOnExternalPower() },
        createAssertion: { reason in
            var assertionID: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &assertionID
            )
            guard result == kIOReturnSuccess else {
                throw SleepAssertionError(code: result)
            }
            return assertionID
        },
        releaseAssertion: { assertionID in
            IOPMAssertionRelease(assertionID)
        },
        observesPowerSourceChanges: true
    )
}

/// 断言创建失败时携带 IOKit 返回码，供 `lastError` 展示。
struct SleepAssertionError: Error {
    let code: SleepAssertionResult
}

// MARK: - Centre

/// Applies the `general.sleepPrevention` preference to the power-management system.
///
/// The centre owns at most one `kIOPMAssertionTypePreventUserIdleSystemSleep`
/// assertion. It is created when the bot runtime is running **and** the user's
/// preference plus the current power source require keeping the system awake, and
/// released as soon as any of the three changes.
///
/// **与机器人运行状态绑定（2026-11-04 按产品要求恢复）**：只有机器人运行时才持有断言
/// （`startRuntime` → `setRuntimeActive(true)`，`stopRuntime` → `false` 立即释放）。
/// 停止机器人的 App 没有理由阻止整机空闲睡眠（笔记本待机功耗从 ~0.1W 升到数瓦）。
/// 因此机器人未运行时修改档位不会立刻生效：设置页会提示「启动机器人后生效」，
/// 并在「当前状态」显示「未生效（机器人未运行）」；偏好本身会保存，机器人启动后恢复。
///
/// Scope: only *idle system sleep* is prevented. Closing the lid, choosing
/// "Sleep" from the Apple menu, or letting the display sleep are unaffected.
///
/// The class is `@MainActor` because it feeds SwiftUI state and the power-source run
/// loop source is registered on the main run loop. `apply(mode:)` is idempotent and is
/// called from `AppDelegate` at launch, from the settings UI on appear/change, and from
/// the IOKit power-source callback.
@MainActor
@Observable
final class SleepPreventionCenter {
    static let shared = SleepPreventionCenter()

    /// Last mode applied through this centre.
    private(set) var mode: SleepPreventionMode = .never
    /// `true` while an idle-sleep assertion is held.
    private(set) var isPreventingSleep = false
    /// `true` while the bot runtime is running. The assertion is only held when this is
    /// `true`; the settings UI uses it to explain why a preference is not active yet.
    private(set) var isRuntimeActive = false
    /// Whether the Mac is currently running on an external power adapter. Desktops
    /// without a battery report `true` (treated like AC power so the feature keeps
    /// working on a Mac mini / Mac Studio).
    private(set) var isOnExternalPower = true
    /// Human-readable description of the last assertion/monitor failure, if any.
    private(set) var lastError: String?

    @ObservationIgnored private let driver: SleepPreventionDriver
    @ObservationIgnored private var assertionID: SleepAssertionID = 0
    @ObservationIgnored private var isHoldingAssertion = false
    @ObservationIgnored private var powerSourceRunLoopSource: CFRunLoopSource?
    @ObservationIgnored private var isObservingPowerSource = false

    private static let assertionReason = "WeChat AI 正在运行，按设置防止系统空闲睡眠"

    init(driver: SleepPreventionDriver = .system) {
        self.driver = driver
    }

    // MARK: - Pure decision logic

    /// Whether an idle-sleep assertion should be held for the given preference and
    /// power source. Kept pure so it can be unit-tested without touching IOKit.
    nonisolated static func shouldPreventSleep(
        mode: SleepPreventionMode,
        onExternalPower: Bool
    ) -> Bool {
        switch mode {
        case .never:
            false
        case .externalPowerOnly:
            onExternalPower
        case .always:
            true
        }
    }

    // MARK: - Public control

    /// Applies `mode`: refreshes the power source, then creates or releases the
    /// assertion as needed. Safe to call repeatedly; only real state transitions touch
    /// IOKit. The assertion itself is still gated on `isRuntimeActive`: applying a
    /// preference while the bot is stopped saves it without holding the assertion.
    func apply(mode newMode: SleepPreventionMode) {
        mode = newMode
        startObservingPowerSourceIfNeeded()
        refreshPowerSource()
        evaluate()
        // 关闭功能后不再展示上一次持有断言失败的旧错误。
        if newMode == .never { lastError = nil }
    }

    /// 机器人启动/停止时更新「运行时是否活跃」。
    ///
    /// 只有机器人运行时才需要防睡眠：`stopRuntime` 后立即释放断言（偏好保持不变，
    /// 下次启动机器人时按当前档位与电源状态恢复）。
    func setRuntimeActive(_ active: Bool) {
        guard isRuntimeActive != active else { return }
        isRuntimeActive = active
        startObservingPowerSourceIfNeeded()
        evaluate()
    }

    /// Re-reads the current power source (AC / battery). A `nil` result — desktops and
    /// any transient IOKit failure — is treated as external power.
    func refreshPowerSource() {
        isOnExternalPower = driver.readExternalPower() ?? true
    }

    /// Releases the assertion without changing the saved preference/settings.
    /// Called from `applicationWillTerminate`.
    func release() {
        releaseAssertion()
        lastError = nil
    }

    // MARK: - Power source

    /// Reads the power source the Mac is currently drawing from.
    ///
    /// `IOPSGetProvidingPowerSourceType` follows the CoreFoundation **Get** rule
    /// (it is not a `Copy`/`Create` function), so the returned CFString must not be
    /// consumed: `takeUnretainedValue()`. Returning `nil` means "no power-source
    /// information" and lets the caller fall back to AC-power semantics.
    nonisolated static func currentlyOnExternalPower() -> Bool? {
        guard let sourceType = IOPSGetProvidingPowerSourceType(nil)?.takeUnretainedValue() as String? else {
            return nil
        }
        return sourceType == kIOPSACPowerValue
    }

    private func evaluate() {
        let shouldPrevent = isRuntimeActive
            && Self.shouldPreventSleep(mode: mode, onExternalPower: isOnExternalPower)
        if shouldPrevent {
            acquireAssertionIfNeeded()
        } else {
            releaseAssertion()
        }
        isPreventingSleep = isHoldingAssertion
    }

    private func handlePowerSourceChange() {
        refreshPowerSource()
        evaluate()
    }

    // MARK: - IOKit power-source notifications

    private func startObservingPowerSourceIfNeeded() {
        guard driver.observesPowerSourceChanges, !isObservingPowerSource else { return }
        isObservingPowerSource = true

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let center = Unmanaged<SleepPreventionCenter>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                center.handlePowerSourceChange()
            }
        }

        guard let runLoopSource = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else {
            isObservingPowerSource = false
            lastError = "无法注册电源状态监听，插拔电源后不会自动刷新防睡眠状态。"
            return
        }

        powerSourceRunLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
    }

    // MARK: - Assertion lifecycle

    private func acquireAssertionIfNeeded() {
        guard !isHoldingAssertion, assertionID == 0 else { return }

        do {
            assertionID = try driver.createAssertion(Self.assertionReason)
            isHoldingAssertion = true
            lastError = nil
        } catch {
            assertionID = 0
            isHoldingAssertion = false
            if let failure = error as? SleepAssertionError {
                lastError = "创建防睡眠断言失败（错误码 \(failure.code)），系统仍可能进入空闲睡眠。"
            } else {
                lastError = "创建防睡眠断言失败：\(error.localizedDescription)，系统仍可能进入空闲睡眠。"
            }
        }
    }

    private func releaseAssertion() {
        guard isHoldingAssertion || assertionID != 0 else {
            isPreventingSleep = false
            return
        }

        let result = driver.releaseAssertion(assertionID)
        assertionID = 0
        isHoldingAssertion = false
        isPreventingSleep = false

        if result == kIOReturnSuccess {
            lastError = nil
        } else {
            lastError = "释放防睡眠断言失败（错误码 \(result)）。"
        }
    }
}

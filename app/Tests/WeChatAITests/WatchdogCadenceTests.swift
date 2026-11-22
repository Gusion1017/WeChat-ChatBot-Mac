import XCTest
@testable import WeChatAI

/// 主线程看门狗频率分档：机器人运行且 App 活跃时 1s 精细取证，
/// 其余（机器人停止 / App 非活跃）降到 5s，避免空闲时每秒唤醒主队列。
final class WatchdogCadenceTests: XCTestCase {
    func testActiveCadenceKeepsOneSecondAndTightThreshold() {
        let cadence = MainThreadWatchdog.cadence(botRunning: true, appActive: true)
        XCTAssertEqual(cadence.tickInterval, MainThreadWatchdog.tickInterval)
        XCTAssertEqual(cadence.tickInterval, 1.0)
        XCTAssertEqual(cadence.stallThreshold, MainThreadWatchdog.stallThreshold)
        XCTAssertEqual(cadence.stallThreshold, 1.5)
        XCTAssertEqual(cadence.leewayMilliseconds, 200)
    }

    func testIdleCadenceWhenBotStoppedOrAppInactive() {
        let stopped = MainThreadWatchdog.cadence(botRunning: false, appActive: true)
        let background = MainThreadWatchdog.cadence(botRunning: true, appActive: false)
        let idle = MainThreadWatchdog.cadence(botRunning: false, appActive: false)

        for cadence in [stopped, background, idle] {
            XCTAssertEqual(cadence.tickInterval, MainThreadWatchdog.idleTickInterval)
            XCTAssertEqual(cadence.tickInterval, 5.0)
            XCTAssertEqual(cadence.stallThreshold, MainThreadWatchdog.idleStallThreshold)
            XCTAssertEqual(cadence.stallThreshold, 7.5)
            XCTAssertEqual(cadence.leewayMilliseconds, 500)
        }
    }

    /// 阈值必须随 tick 同步放宽（约 1.5 倍），否则 5s 心跳会把正常 2s 的主线程繁忙误报成卡顿。
    func testIdleThresholdScalesWithIdleTick() {
        let cadence = MainThreadWatchdog.cadence(botRunning: false, appActive: false)
        XCTAssertEqual(
            cadence.stallThreshold,
            cadence.tickInterval * 1.5,
            accuracy: 0.001
        )
    }
}

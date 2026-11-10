import Foundation
import XCTest
@testable import WeChatAI

/// 「发布时机」（设置页）纯逻辑单测。
///
/// 全部使用固定公历 + `Asia/Shanghai` 时区与固定日期，不依赖本机当前时间/时区；
/// 覆盖：时段重叠/合并、时间点归一化、排程预览、容量诊断、常用预设与模式摘要。
final class SnsPublishTimingTests: XCTestCase {
    // MARK: - 固定时钟与构造工具

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.locale = Locale(identifier: "zh_CN")
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private func window(_ id: String, _ start: Int, _ end: Int) -> SnsPublishWindow {
        SnsPublishWindow(id: id, startMinute: start, endMinute: end)
    }

    private func point(_ id: String, _ minute: Int) -> SnsPublishTime {
        SnsPublishTime(id: id, minute: minute)
    }

    private func minutes(of dates: [Date]) -> [Int] {
        dates.map {
            calendar.component(.hour, from: $0) * 60 + calendar.component(.minute, from: $0)
        }
    }

    // MARK: - 1. 时段重叠 windowsOverlap

    func testWindowsOverlapAdjacentWindowsDoNotOverlap() {
        let morning = window("morning", 9 * 60, 12 * 60)
        let afternoon = window("afternoon", 12 * 60, 18 * 60)
        XCTAssertFalse(
            SnsPublishSettings.windowsOverlap(morning, afternoon),
            "09:00–12:00 与 12:00–18:00 首尾相接，不算重叠"
        )
        XCTAssertFalse(
            SnsPublishSettings.windowsOverlap(afternoon, morning),
            "重叠判定必须对称：参数反序也应返回 false"
        )
        XCTAssertFalse(
            SnsPublishSettings.windowsOverlap(window("a", 0, 60), window("b", 60, 120)),
            "00:00–01:00 与 01:00–02:00 也只在端点相接"
        )
    }

    func testWindowsOverlapNestedAndPartial() {
        let outer = window("outer", 9 * 60, 18 * 60)
        XCTAssertTrue(
            SnsPublishSettings.windowsOverlap(outer, window("inner", 10 * 60, 11 * 60)),
            "完全嵌套的时段必须判为重叠"
        )
        XCTAssertTrue(
            SnsPublishSettings.windowsOverlap(window("inner", 10 * 60, 11 * 60), outer),
            "嵌套判定同样要对称"
        )
        XCTAssertTrue(
            SnsPublishSettings.windowsOverlap(outer, window("tail", 17 * 60, 19 * 60)),
            "部分重叠（17:00–19:00）必须判为重叠"
        )
        XCTAssertTrue(
            SnsPublishSettings.windowsOverlap(outer, window("same", 9 * 60, 18 * 60)),
            "完全相同的时段必须判为重叠"
        )
    }

    func testWindowsOverlapCrossMidnight() {
        let overnight = window("overnight", 23 * 60, 1 * 60) // 23:00–次日 01:00
        XCTAssertTrue(
            SnsPublishSettings.windowsOverlap(overnight, window("early", 0, 2 * 60)),
            "23:00–01:00 与 00:00–02:00 在凌晨 00:00–01:00 重叠"
        )
        XCTAssertTrue(
            SnsPublishSettings.windowsOverlap(window("early", 0, 2 * 60), overnight),
            "跨午夜重叠判定要对称"
        )
        XCTAssertFalse(
            SnsPublishSettings.windowsOverlap(overnight, window("day", 15 * 60, 16 * 60)),
            "跨午夜时段不与白天时段重叠"
        )
        XCTAssertTrue(
            SnsPublishSettings.windowsOverlap(overnight, window("same", 23 * 60, 1 * 60)),
            "两个相同的跨午夜时段重叠"
        )
        XCTAssertFalse(
            SnsPublishSettings.windowsOverlap(overnight, window("edge", 60, 120)),
            "23:00–01:00 与 01:00–02:00 只共享 01:00 端点，属相接而非重叠"
        )
    }

    func testWindowsOverlapInvalidWindowIsFalse() {
        let zeroLength = window("zero", 9 * 60, 9 * 60)
        XCTAssertFalse(zeroLength.isValid, "零长度时段本身非法")
        XCTAssertFalse(
            SnsPublishSettings.windowsOverlap(zeroLength, window("normal", 9 * 60, 18 * 60)),
            "非法零长度时段不参与重叠判定"
        )
        XCTAssertFalse(
            SnsPublishSettings.windowsOverlap(window("normal", 9 * 60, 18 * 60), zeroLength),
            "参数顺序颠倒也必须返回 false"
        )
        XCTAssertFalse(
            SnsPublishSettings.windowsOverlap(window("bad", -1, 60), window("normal", 9 * 60, 18 * 60)),
            "越界分钟同样视为非法时段"
        )
    }

    // MARK: - 2. overlappingWindowIDs / hasOverlappingWindows

    func testOverlappingWindowIDsMarksOnlyOverlappingPair() {
        var settings = SnsPublishSettings()
        settings.windows = [
            window("a", 9 * 60, 12 * 60),
            window("b", 10 * 60, 11 * 60), // 与 a 重叠
            window("c", 13 * 60, 14 * 60)  // 与谁都不重叠
        ]
        XCTAssertEqual(settings.overlappingWindowIDs, Set(["a", "b"]), "只有重叠对的两个 id 被标记")
        XCTAssertTrue(settings.hasOverlappingWindows)
    }

    func testNoOverlappingWindowsForAdjacentOrSingleValidWindow() {
        var settings = SnsPublishSettings()
        settings.windows = [window("a", 9 * 60, 12 * 60), window("b", 12 * 60, 18 * 60)]
        XCTAssertTrue(settings.overlappingWindowIDs.isEmpty, "首尾相接不是重叠")
        XCTAssertFalse(settings.hasOverlappingWindows)

        settings.windows = [window("a", 9 * 60, 12 * 60)]
        XCTAssertTrue(settings.overlappingWindowIDs.isEmpty, "只有一个有效时段时不可能重叠")

        settings.windows = [window("a", 9 * 60, 12 * 60), window("bad", 10 * 60, 10 * 60)]
        XCTAssertTrue(settings.overlappingWindowIDs.isEmpty, "非法时段不参与重叠统计")

        settings.windows = []
        XCTAssertTrue(settings.overlappingWindowIDs.isEmpty)
        XCTAssertFalse(settings.hasOverlappingWindows)
    }

    // MARK: - 3. mergedWindows / mergeOverlappingWindows

    func testMergedWindowsMergesOverlapAndKeepsEarliestID() {
        var settings = SnsPublishSettings()
        let morning = window("morning", 9 * 60, 12 * 60)
        let nested = window("nested", 10 * 60, 11 * 60)
        settings.windows = [morning, nested]

        let merged = settings.mergedWindows
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.id, "morning", "合并保留第一段（09:00 开始）的 id")
        XCTAssertEqual(merged.first?.startMinute, 9 * 60)
        XCTAssertEqual(merged.first?.endMinute, 12 * 60, "合并后覆盖两段的并集")

        settings.windows = [nested, morning]
        XCTAssertEqual(settings.mergedWindows.first?.id, "morning", "排序后仍以早段为基准，与输入顺序无关")
    }

    func testMergedWindowsMergesAdjacentWindows() {
        var settings = SnsPublishSettings()
        settings.windows = [window("first", 9 * 60, 12 * 60), window("second", 12 * 60, 18 * 60)]
        let merged = settings.mergedWindows
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.id, "first")
        XCTAssertEqual(merged.first?.startMinute, 9 * 60)
        XCTAssertEqual(merged.first?.endMinute, 18 * 60, "首尾相接也可合并为连续一段")
        XCTAssertTrue(merged.first?.isValid ?? false)
    }

    func testMergedWindowsSortsByStartMinute() {
        var settings = SnsPublishSettings()
        settings.windows = [window("evening", 19 * 60, 22 * 60), window("morning", 8 * 60, 10 * 60)]
        let merged = settings.mergedWindows
        XCTAssertEqual(merged.map(\.id), ["morning", "evening"])
        XCTAssertEqual(merged.map(\.startMinute), [8 * 60, 19 * 60], "结果按开始分钟升序")
    }

    func testMergedWindowsCollapsesFullDayToSentinel() {
        var settings = SnsPublishSettings()
        settings.windows = [
            window("first", 0, 12 * 60),
            window("second", 12 * 60, 0) // 12:00–次日 00:00
        ]
        let merged = settings.mergedWindows
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.id, "first")
        XCTAssertEqual(merged.first?.startMinute, 0)
        XCTAssertEqual(merged.first?.endMinute, 23 * 60 + 59, "协议没有 24:00，覆盖整天收成 00:00–23:59")
        XCTAssertEqual(merged.first?.lengthMinutes, 23 * 60 + 59, "收起后仍是合法非零长度时段")
    }

    func testMergeOverlappingWindowsReturnsFalseWhenNothingToMerge() {
        var settings = SnsPublishSettings()
        settings.windows = [window("a", 9 * 60, 12 * 60), window("b", 13 * 60, 14 * 60)]
        let original = settings.windows
        XCTAssertEqual(settings.windowsMergeableCount, 0)
        XCTAssertFalse(settings.mergeOverlappingWindows(), "没有可合并项时返回 false")
        XCTAssertEqual(settings.windows, original, "返回 false 时不能改动配置")

        settings.windows = [window("only", 9 * 60, 12 * 60)]
        XCTAssertFalse(settings.mergeOverlappingWindows(), "单段无可合并")

        settings.windows = []
        XCTAssertFalse(settings.mergeOverlappingWindows(), "空时段无可合并")
    }

    func testMergeOverlappingWindowsMergesChainAndKeepsSeparateWindow() {
        var settings = SnsPublishSettings()
        settings.windows = [
            window("a", 8 * 60, 10 * 60),
            window("b", 9 * 60, 11 * 60),
            window("c", 10 * 60, 12 * 60),
            window("d", 15 * 60, 16 * 60)
        ]
        XCTAssertTrue(settings.mergeOverlappingWindows(), "存在可合并时段时必须返回 true")
        XCTAssertEqual(settings.windows.count, 2, "链式重叠应合并成一段，独立时段保留")
        XCTAssertEqual(settings.windows[0].id, "a")
        XCTAssertEqual(settings.windows[0].startMinute, 8 * 60)
        XCTAssertEqual(settings.windows[0].endMinute, 12 * 60)
        XCTAssertEqual(settings.windows[1].id, "d")
        XCTAssertEqual(settings.windows[1].startMinute, 15 * 60)
        XCTAssertEqual(settings.windows[1].endMinute, 16 * 60)
        XCTAssertEqual(settings.windowsMergeableCount, 0, "合并后不再有可合并项")
        XCTAssertTrue(settings.windows.allSatisfy(\.isValid), "合并结果必须都是合法时段")
    }

    /// 跨午夜并集回归（Lead 修复后）：并集起点可能是任意一段的起点，
    /// 实现会对两个起点分别计算顺时针跨度并取较小者，避免把非全天并集误收成 00:00–23:59。
    func testMergedWindowsCrossMidnightOverlapUsesTrueUnion() {
        var settings = SnsPublishSettings()
        settings.windows = [
            window("early", 0, 2 * 60),       // 00:00–02:00
            window("night", 23 * 60, 1 * 60)  // 23:00–次日 01:00
        ]
        XCTAssertTrue(settings.hasOverlappingWindows, "两段在凌晨 00:00–01:00 确实重叠")

        let merged = settings.mergedWindows
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.id, "early", "合并保留排序后第一段的 id")
        XCTAssertEqual(merged.first?.startMinute, 23 * 60, "并集起点应为 23:00（较小跨度），不能从 00:00 起算")
        XCTAssertEqual(merged.first?.endMinute, 2 * 60, "并集终点是次日 02:00")
        XCTAssertEqual(merged.first?.lengthMinutes, 3 * 60, "真实并集跨度 3 小时，不是全天")

        // Lead 指定用例：[23:00–01:00, 22:00–02:00] → 22:00–次日 02:00。
        settings.windows = [
            window("night", 23 * 60, 1 * 60),
            window("broad-night", 22 * 60, 2 * 60)
        ]
        let broad = settings.mergedWindows
        XCTAssertEqual(broad.count, 1)
        XCTAssertEqual(broad.first?.startMinute, 22 * 60, "并集起点应为 22:00")
        XCTAssertEqual(broad.first?.endMinute, 2 * 60, "并集终点应为次日 02:00")
        XCTAssertEqual(broad.first?.lengthMinutes, 4 * 60)

        // 同源边界：首尾相接于午夜（00:00–02:00 + 22:00–00:00）→ 22:00–次日 02:00。
        settings.windows = [
            window("early", 0, 2 * 60),
            window("late", 22 * 60, 0)
        ]
        XCTAssertTrue(
            SnsPublishSettings.windowsMergeable(settings.windows[0], settings.windows[1]),
            "两段在 00:00 相接，属于可合并"
        )
        let adjacent = settings.mergedWindows
        XCTAssertEqual(adjacent.count, 1)
        XCTAssertEqual(adjacent.first?.startMinute, 22 * 60, "相接时并集起点是 22:00")
        XCTAssertEqual(adjacent.first?.endMinute, 2 * 60, "相接时并集终点是次日 02:00")
        XCTAssertEqual(adjacent.first?.lengthMinutes, 4 * 60, "跨度 4 小时，不是全天")
    }

    /// Lead 指定的跨午夜 / 覆盖整天 / 相邻合并回归用例（每个 case 同时确认幂等）。
    func testMergeOverlappingWindowsCrossMidnightUnionCases() {
        // 1) 00:00–09:00 + 20:00–00:00 → 20:00–09:00（修复前会被误收成全天）。
        var overnight = SnsPublishSettings()
        overnight.windows = [
            SnsPublishWindow(id: "early", startMinute: 0, endMinute: 540),
            SnsPublishWindow(id: "evening", startMinute: 1200, endMinute: 0)
        ]
        XCTAssertTrue(overnight.mergeOverlappingWindows())
        XCTAssertEqual(overnight.windows.count, 1)
        XCTAssertEqual(overnight.windows[0].startMinute, 1200, "并集起点 20:00")
        XCTAssertEqual(overnight.windows[0].endMinute, 540, "并集终点次日 09:00")
        XCTAssertEqual(overnight.windows[0].lengthMinutes, 13 * 60, "跨度 13 小时，不是全天")
        let overnightMerged = overnight.windows
        XCTAssertFalse(overnight.mergeOverlappingWindows(), "再次合并没有可合并项，返回 false")
        XCTAssertEqual(overnight.windows, overnightMerged, "幂等：配置不变")

        // 2) 23:00–01:00 + 22:00–23:30 → 22:00–01:00。
        var lateNight = SnsPublishSettings()
        lateNight.windows = [
            SnsPublishWindow(id: "night", startMinute: 1380, endMinute: 60),
            SnsPublishWindow(id: "evening", startMinute: 1320, endMinute: 1410)
        ]
        XCTAssertTrue(lateNight.mergeOverlappingWindows())
        XCTAssertEqual(lateNight.windows.count, 1)
        XCTAssertEqual(lateNight.windows[0].startMinute, 1320, "并集起点 22:00")
        XCTAssertEqual(lateNight.windows[0].endMinute, 60, "并集终点次日 01:00")
        XCTAssertEqual(lateNight.windows[0].lengthMinutes, 3 * 60, "跨度 3 小时")
        let lateNightMerged = lateNight.windows
        XCTAssertFalse(lateNight.mergeOverlappingWindows(), "再次合并返回 false")
        XCTAssertEqual(lateNight.windows, lateNightMerged, "幂等：配置不变")

        // 3) 回归：真正覆盖整天仍收成 00:00–23:59（协议没有 24:00）。
        var fullDay = SnsPublishSettings()
        fullDay.windows = [
            SnsPublishWindow(id: "first", startMinute: 0, endMinute: 12 * 60),
            SnsPublishWindow(id: "second", startMinute: 12 * 60, endMinute: 0)
        ]
        XCTAssertTrue(fullDay.mergeOverlappingWindows())
        XCTAssertEqual(fullDay.windows.count, 1)
        XCTAssertEqual(fullDay.windows[0].startMinute, 0)
        XCTAssertEqual(fullDay.windows[0].endMinute, 23 * 60 + 59, "覆盖整天收成 00:00–23:59")
        let fullDayMerged = fullDay.windows
        XCTAssertFalse(fullDay.mergeOverlappingWindows(), "再次合并返回 false")
        XCTAssertEqual(fullDay.windows, fullDayMerged, "幂等：配置不变")

        // 4) 相邻但不重叠的白天时段 → 09:00–18:00。
        var daytime = SnsPublishSettings()
        daytime.windows = [
            SnsPublishWindow(id: "morning", startMinute: 9 * 60, endMinute: 12 * 60),
            SnsPublishWindow(id: "afternoon", startMinute: 12 * 60, endMinute: 18 * 60)
        ]
        XCTAssertTrue(daytime.mergeOverlappingWindows())
        XCTAssertEqual(daytime.windows.count, 1)
        XCTAssertEqual(daytime.windows[0].startMinute, 9 * 60)
        XCTAssertEqual(daytime.windows[0].endMinute, 18 * 60)
        let daytimeMerged = daytime.windows
        XCTAssertFalse(daytime.mergeOverlappingWindows(), "再次合并返回 false")
        XCTAssertEqual(daytime.windows, daytimeMerged, "幂等：配置不变")
    }

    // MARK: - 4. windowsMergeable / windowsMergeableCount

    func testWindowsMergeableDetectsOverlapAdjacencyAndSeparation() {
        XCTAssertTrue(
            SnsPublishSettings.windowsMergeable(window("a", 9 * 60, 12 * 60), window("b", 9 * 60 + 30, 11 * 60)),
            "重叠的时段可合并"
        )
        XCTAssertTrue(
            SnsPublishSettings.windowsMergeable(window("a", 9 * 60, 12 * 60), window("b", 12 * 60, 18 * 60)),
            "首尾相接的时段可合并"
        )
        XCTAssertTrue(
            SnsPublishSettings.windowsMergeable(window("b", 12 * 60, 18 * 60), window("a", 9 * 60, 12 * 60)),
            "相接判定要对称"
        )
        XCTAssertFalse(
            SnsPublishSettings.windowsMergeable(window("a", 9 * 60, 12 * 60), window("b", 13 * 60, 14 * 60)),
            "分离的时段不可合并"
        )
        XCTAssertFalse(
            SnsPublishSettings.windowsMergeable(window("zero", 9 * 60, 9 * 60), window("b", 9 * 60, 12 * 60)),
            "非法时段不可合并"
        )
        XCTAssertTrue(
            SnsPublishSettings.windowsMergeable(window("night", 23 * 60, 1 * 60), window("early", 1 * 60, 2 * 60)),
            "23:00–01:00 与 01:00–02:00 在 01:00 相接，可合并"
        )
    }

    func testWindowsMergeableCountCountsOnlyMergeablePairs() {
        var settings = SnsPublishSettings()
        settings.windows = [
            window("a", 9 * 60, 12 * 60),
            window("b", 12 * 60, 18 * 60),
            window("c", 15 * 60, 16 * 60),
            window("d", 20 * 60, 21 * 60)
        ]
        // a–b 相接；b–c 重叠；其余分离。
        XCTAssertEqual(settings.windowsMergeableCount, 2)

        settings.windows = [window("a", 9 * 60, 12 * 60), window("b", 13 * 60, 14 * 60)]
        XCTAssertEqual(settings.windowsMergeableCount, 0)

        settings.windows = [window("a", 9 * 60, 12 * 60)]
        XCTAssertEqual(settings.windowsMergeableCount, 0, "单段没有可配对的时段")

        settings.windows = [window("zero", 9 * 60, 9 * 60), window("zero2", 10 * 60, 10 * 60)]
        XCTAssertEqual(settings.windowsMergeableCount, 0, "非法时段不参与统计")
    }

    // MARK: - 5. 时间点排序 / 去重

    func testIsTimesSortedAllowsDuplicates() {
        var settings = SnsPublishSettings()
        XCTAssertTrue(settings.isTimesSorted, "默认配置只有一个时间点")
        settings.times = []
        XCTAssertTrue(settings.isTimesSorted, "空数组视为有序")
        settings.times = [point("a", 9 * 60), point("b", 9 * 60), point("c", 10 * 60)]
        XCTAssertTrue(settings.isTimesSorted, "升序且含重复分钟仍算有序")
        settings.times = [point("a", 10 * 60), point("b", 9 * 60)]
        XCTAssertFalse(settings.isTimesSorted, "降序不算有序")
    }

    func testSortedTimesSortsAndDedupesKeepingFirst() {
        var settings = SnsPublishSettings()
        settings.times = [
            point("late", 20 * 60),
            point("am-first", 9 * 60),
            point("am-second", 9 * 60),
            point("mid", 10 * 60)
        ]
        let sorted = settings.sortedTimes
        XCTAssertEqual(sorted.map(\.minute), [9 * 60, 10 * 60, 20 * 60])
        XCTAssertEqual(sorted.map(\.id), ["am-first", "mid", "late"], "同一分钟只保留先出现的那个")
        XCTAssertEqual(settings.times.count, 4, "计算属性不修改原配置")
    }

    func testSortedTimesFiltersInvalidMinutesAndTruncatesToLimit() {
        var settings = SnsPublishSettings()
        settings.times = [
            point("neg", -1),
            point("end", 1440),
            point("over", 24 * 60 + 5),
            point("ok", 0)
        ]
        XCTAssertEqual(settings.sortedTimes.map(\.minute), [0], "越界分钟不参与排序/排程")

        settings.times = Array((0..<12).reversed()).map { point("p\($0)", $0 * 60) }
        let sorted = settings.sortedTimes
        XCTAssertEqual(sorted.count, SnsPublishSettings.maxTimePoints, "时间点最多保留 maxTimePoints 个")
        XCTAssertEqual(
            sorted.map(\.minute),
            Array(0..<SnsPublishSettings.maxTimePoints).map { $0 * 60 },
            "先按分钟排序再截断，取最早的 N 个"
        )
    }

    func testNormalizeTimesSortsDedupesAndIsIdempotent() {
        var settings = SnsPublishSettings()
        settings.times = [point("pm", 20 * 60), point("am", 9 * 60), point("dup", 9 * 60)]
        XCTAssertTrue(settings.normalizeTimes(), "乱序/重复时返回 true")
        XCTAssertEqual(settings.times.map(\.minute), [9 * 60, 20 * 60])
        XCTAssertEqual(settings.times.map(\.id), ["am", "pm"])
        XCTAssertFalse(settings.normalizeTimes(), "第二次调用没有变化，返回 false")
        XCTAssertEqual(settings.times.map(\.minute), [9 * 60, 20 * 60], "返回值 false 时配置不变")

        settings.times = [point("a", 9 * 60), point("b", 10 * 60)]
        XCTAssertFalse(settings.normalizeTimes(), "已归一化时返回 false")
    }

    // MARK: - 6. 排程预览

    func testTodaySlotsUsesLocalCalendarDay() {
        var settings = SnsPublishSettings()
        settings.mode = .times
        settings.times = [point("am", 9 * 60), point("pm", 20 * 60)]
        let now = date(2026, 11, 10, 12, 34)
        let today = settings.todaySlots(now: now, calendar: calendar)
        XCTAssertEqual(today, settings.slots(on: now, calendar: calendar),
                       "时间点模式没有跨午夜槽位，两种口径应一致")
        XCTAssertEqual(minutes(of: today), [9 * 60, 20 * 60])
        XCTAssertTrue(today.allSatisfy { calendar.isDate($0, inSameDayAs: now) }, "todaySlots 只返回当天槽位")

        // 跨午夜时段：今天凌晨的时刻由「昨天那组槽位」生成，todaySlots 必须把它算进今天。
        settings.mode = .windows
        settings.windows = [window("night", 23 * 60, 1 * 60)]
        settings.maxPerDay = 1
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let expected = (settings.slots(on: date(2026, 11, 9, 0, 0), calendar: calendar)
            + settings.slots(on: now, calendar: calendar))
            .filter { $0 >= start && $0 < end }
        let todayWindows = settings.todaySlots(now: now, calendar: calendar)
        XCTAssertEqual(todayWindows, todayWindows.sorted(), "todaySlots 必须升序")
        XCTAssertEqual(Set(todayWindows), Set(expected),
                       "todaySlots 必须覆盖昨天/今天两组槽位里落在今天的部分")
        XCTAssertTrue(todayWindows.allSatisfy { calendar.isDate($0, inSameDayAs: now) },
                      "跨午夜的次日凌晨槽位不能被算进今天")
    }

    func testRemainingSlotCountOnlyCountsStrictlyLaterSlots() {
        var settings = SnsPublishSettings()
        settings.mode = .times
        settings.times = [point("am", 9 * 60), point("pm", 20 * 60)]
        XCTAssertEqual(settings.remainingSlotCount(now: date(2026, 11, 10, 8, 0), calendar: calendar), 2)
        XCTAssertEqual(
            settings.remainingSlotCount(now: date(2026, 11, 10, 9, 0), calendar: calendar),
            1,
            "恰好等于槽位时刻不算「之后」"
        )
        XCTAssertEqual(settings.remainingSlotCount(now: date(2026, 11, 10, 20, 0), calendar: calendar), 0)
        XCTAssertEqual(settings.remainingSlotCount(now: date(2026, 11, 10, 21, 0), calendar: calendar), 0)

        settings.mode = .windows
        settings.windows = []
        XCTAssertEqual(
            settings.remainingSlotCount(now: date(2026, 11, 10, 8, 0), calendar: calendar),
            0,
            "没有可发时段时剩余次数为 0"
        )
    }

    func testUpcomingSlotsTimesModeCrossesDaysInOrder() {
        var settings = SnsPublishSettings()
        settings.mode = .times
        settings.times = [point("am", 9 * 60), point("pm", 20 * 60)]
        let now = date(2026, 11, 10, 10, 0)
        let upcoming = settings.upcomingSlots(limit: 3, after: now, calendar: calendar)
        XCTAssertEqual(
            upcoming,
            [
                date(2026, 11, 10, 20, 0),
                date(2026, 11, 11, 9, 0),
                date(2026, 11, 11, 20, 0)
            ],
            "固定时间点模式跨天预览顺序必须正确"
        )
        XCTAssertTrue(upcoming.allSatisfy { $0 > now }, "预览时刻必须严格晚于 now")
    }

    func testUpcomingSlotsHonorsLimitAndIsStrictlyIncreasing() {
        var settings = SnsPublishSettings()
        settings.mode = .times
        settings.times = [point("am", 9 * 60), point("pm", 20 * 60)]
        let now = date(2026, 11, 10, 10, 0)

        let many = settings.upcomingSlots(limit: 100, after: now, calendar: calendar)
        XCTAssertGreaterThan(many.count, 3, "9 天预览窗口内应能取到多天槽位")
        XCTAssertLessThanOrEqual(many.count, 100, "数量不能超过 limit")
        for (earlier, later) in zip(many, many.dropFirst()) {
            XCTAssertLessThan(earlier, later, "跨天预览必须严格递增")
        }
        XCTAssertTrue(many.allSatisfy { $0 > now }, "所有预览时刻必须严格晚于 now")

        XCTAssertEqual(
            settings.upcomingSlots(limit: 0, after: now, calendar: calendar),
            [],
            "limit 0 返回空数组"
        )
        XCTAssertEqual(
            settings.upcomingSlots(limit: 2, after: now, calendar: calendar),
            Array(many.prefix(2)),
            "limit 只截取前 N 个"
        )
    }

    func testUpcomingSlotsWindowsModeIsStableSortedAndWithinWindow() {
        var settings = SnsPublishSettings()
        settings.mode = .windows
        settings.windows = [window("day", 9 * 60, 18 * 60)]
        settings.maxPerDay = 3
        settings.minIntervalMinutes = 60
        let now = date(2026, 11, 10, 6, 0)

        let first = settings.slots(on: now, calendar: calendar)
        let second = settings.slots(on: now, calendar: calendar)
        XCTAssertEqual(first, second, "确定性随机：同一天重复调用 slots(on:) 结果必须稳定")
        XCTAssertFalse(first.isEmpty)
        XCTAssertLessThanOrEqual(first.count, settings.dailyCapacity)
        XCTAssertTrue(
            first.allSatisfy { settings.isWithinWindow($0, calendar: calendar) },
            "随机槽位必须落在可发时段内"
        )
        for (earlier, later) in zip(first, first.dropFirst()) {
            XCTAssertGreaterThan(later, earlier, "槽位必须升序")
            XCTAssertGreaterThanOrEqual(
                later.timeIntervalSince(earlier),
                60 * 60,
                "相邻槽位间隔不小于 minIntervalMinutes"
            )
        }

        let upcoming = settings.upcomingSlots(limit: 3, after: now, calendar: calendar)
        let repeated = settings.upcomingSlots(limit: 3, after: now, calendar: calendar)
        XCTAssertEqual(upcoming, repeated, "同一天重复预览结果稳定（确定性随机）")
        XCTAssertLessThanOrEqual(upcoming.count, 3)
        XCTAssertTrue(upcoming.allSatisfy { $0 > now }, "预览时刻必须严格晚于 now")
        for (earlier, later) in zip(upcoming, upcoming.dropFirst()) {
            XCTAssertLessThan(earlier, later, "预览必须严格递增")
        }
    }

    /// 跨午夜 + 重叠时段：预览必须严格递增，且第一个时刻等于调度器的 `nextFireDate`。
    func testUpcomingSlotsCrossMidnightOverlapIsSortedAndMatchesNextFire() {
        var settings = SnsPublishSettings()
        settings.mode = .windows
        settings.windows = [
            window("early", 0, 2 * 60),
            window("night", 23 * 60, 1 * 60)
        ]
        settings.maxPerDay = 3
        settings.minIntervalMinutes = 30

        for (hour, minute) in [(0, 1), (23, 1)] {
            let now = date(2026, 11, 10, hour, minute)
            let upcoming = settings.upcomingSlots(limit: 6, after: now, calendar: calendar)
            XCTAssertFalse(upcoming.isEmpty, "now=\(hour):01 时应有个可用槽位")
            for (earlier, later) in zip(upcoming, upcoming.dropFirst()) {
                XCTAssertLessThan(earlier, later,
                                  "跨午夜+重叠时段下预览也必须严格递增（now=\(hour):01）")
            }
            XCTAssertEqual(upcoming.first, settings.nextFireDate(after: now, calendar: calendar),
                           "预览第一个时刻必须等于调度器的下一次触发（now=\(hour):01）")
            let days = (0...2).compactMap { calendar.date(byAdding: .day, value: $0, to: now) }
            let expected = days
                .flatMap { settings.todaySlots(now: $0, calendar: calendar) }
                .filter { $0 > now }
                .sorted()
            XCTAssertEqual(Array(upcoming), Array(expected.prefix(6)),
                           "预览必须是「今天+明天+后天」日历日槽位的严格递增前缀")
        }
    }

    // MARK: - 7. 容量诊断 windowCapacityShortfall

    func testWindowCapacityShortfallUsesCalendarDayCapacity() throws {
        var settings = SnsPublishSettings()
        settings.mode = .windows
        settings.windows = [window("short", 9 * 60, 9 * 60 + 10)]
        settings.maxPerDay = 3
        settings.minIntervalMinutes = 30
        let day = date(2026, 11, 10, 0, 0)

        XCTAssertEqual(settings.calendarDayCapacity, 1, "10 分钟 + 30 分钟间隔只能放 1 个点")
        let shortfall = try XCTUnwrap(settings.windowCapacityShortfall())
        XCTAssertEqual(shortfall.expected, 3, "expected 取每天上限")
        XCTAssertEqual(shortfall.actual, 1, "actual 取日历日容量，而不是当天随机抽到的槽位数")
        XCTAssertLessThan(shortfall.actual, shortfall.expected)
        XCTAssertEqual(settings.slots(on: day, calendar: calendar).count, 1, "该配置下当天也只能排 1 个")
    }

    /// 跨午夜时段：同一日历日会收到「当天批次晚段 + 前一天批次凌晨段」两个来源，
    /// 容量必须按本地日历日（与 ledger 的每好友每日上限同口径）计算，不能按单个批次算少。
    func testCalendarDayCapacityCountsCrossMidnightBatches() throws {
        var settings = SnsPublishSettings()
        settings.mode = .windows
        settings.windows = [window("night", 23 * 60, 1 * 60)]
        settings.minIntervalMinutes = 120
        // 23:00–24:00 可放 1 点 + 00:00–01:00 可放 1 点，两个来源各来自不同批次。
        XCTAssertEqual(settings.calendarDayCapacity, 2)

        settings.maxPerDay = 2
        XCTAssertNil(settings.windowCapacityShortfall(), "每好友每天 2 次时，日历日可排 2 个时刻，不应误报")
        settings.maxPerDay = 1
        XCTAssertNil(settings.windowCapacityShortfall(), "每天 1 次时容量更不是瓶颈")

        settings.maxPerDay = 3
        XCTAssertEqual(settings.calendarDayCapacity, 2, "每个批次每段最多 1 点，两段合计 2 点")
        let shortfall = try XCTUnwrap(settings.windowCapacityShortfall(),
                                      "每天 3 次时跨午夜窗口确实排不下")
        XCTAssertEqual(shortfall.expected, 3)
        XCTAssertEqual(shortfall.actual, 2)
    }

    /// 容量诊断必须与「当天随机抽到几个槽位」解耦：否则可排得下的配置也会随机误报。
    func testWindowCapacityShortfallIsDeterministicAcrossDays() throws {
        // 修复前该配置 30 天里会随机误报 5 天（随机采样偶发只排出 4 个）。
        var fitting = SnsPublishSettings()
        fitting.mode = .windows
        fitting.windows = [window("day", 9 * 60, 18 * 60)]
        fitting.maxPerDay = 5
        fitting.minIntervalMinutes = 90
        XCTAssertEqual(fitting.calendarDayCapacity, 5, "540 分钟 + 90 分钟间隔可放 6 个点，被每天上限 5 截断")
        for offset in 0..<30 {
            let day = calendar.date(byAdding: .day, value: offset, to: date(2026, 11, 10, 0, 0))!
            XCTAssertNil(fitting.windowCapacityShortfall(),
                         "日历日容量足够时不能因当天随机结果误报（第 \(offset) 天）")
            XCTAssertLessThanOrEqual(fitting.slots(on: day, calendar: calendar).count, 6)
        }

        // 真正排不下：780 分钟 + 120 分钟间隔最多 7 个点，却设置了每天 10 次。
        var tight = SnsPublishSettings()
        tight.mode = .windows
        tight.windows = [window("day", 9 * 60, 22 * 60)]
        tight.maxPerDay = 10
        tight.minIntervalMinutes = 120
        XCTAssertEqual(tight.calendarDayCapacity, 7)
        for offset in 0..<30 {
            let shortfall = try XCTUnwrap(tight.windowCapacityShortfall(),
                                          "第 \(offset) 天都应报容量不足")
            XCTAssertEqual(shortfall.expected, 10)
            XCTAssertEqual(shortfall.actual, 7, "actual 始终是日历日容量，不随日期/随机结果变化")
        }
    }

    /// 独立 DP 对照：capacity 必须等于「当天批次当天部分 + 前一天批次跨午夜部分」
    /// 在最小间隔下的精确最大点数（各按每批上限截断后相加）。
    /// 重点覆盖「当天窗口与跨午夜窗口在午夜处重叠」——按合并后的时段切片会把容量算少。
    func testCalendarDayCapacityMatchesBruteForceDP() {
        let cases: [(windows: [SnsPublishWindow], gap: Int, maxPerDay: Int)] = [
            ([window("day", 0, 2 * 60), window("night", 23 * 60, 1 * 60)], 60, 4),
            ([window("day", 0, 2 * 60), window("night", 23 * 60, 1 * 60)], 120, 4),
            ([window("day", 30, 3 * 60), window("night", 22 * 60, 2 * 60)], 45, 5),
            ([window("a", 9 * 60, 11 * 60 + 1), window("b", 11 * 60 + 3, 13 * 60 + 4)], 120, 4),
            ([window("night", 22 * 60, 21 * 60)], 1440, 2)
        ]
        for (windows, gap, maxPerDay) in cases {
            var settings = SnsPublishSettings()
            settings.mode = .windows
            settings.windows = windows
            settings.minIntervalMinutes = gap
            settings.maxPerDay = maxPerDay
            let expected = Self.bruteForceCalendarDayCapacity(windows: windows,
                                                              gap: gap,
                                                              perBatch: maxPerDay)
            XCTAssertEqual(settings.calendarDayCapacity,
                           expected,
                           "配置 \(windows.map(\.summary)) gap=\(gap) max=\(maxPerDay) 应与穷举一致")
        }

        // 午夜处重叠的具体回归：容量 4（当天部分 3 + 前一天凌晨部分 1），不应误报。
        var overlap = SnsPublishSettings()
        overlap.mode = .windows
        overlap.windows = [window("day", 0, 2 * 60), window("night", 23 * 60, 1 * 60)]
        overlap.minIntervalMinutes = 60
        overlap.maxPerDay = 4
        XCTAssertEqual(overlap.calendarDayCapacity, 4)
        XCTAssertNil(overlap.windowCapacityShortfall(), "当天窗口与跨午夜窗口在午夜重叠时不能把容量算少")
    }

    /// 独立穷举：给定可放分钟集合与最小间隔，求最多能放几个点（不依赖实现的贪心）。
    private static func bruteForceMaximumPoints(_ allowed: Set<Int>, gap: Int) -> Int {
        let sorted = allowed.sorted()
        guard !sorted.isEmpty else { return 0 }
        let spacing = max(1, gap)
        var best = Array(repeating: 1, count: sorted.count)
        for i in sorted.indices {
            for j in 0..<i where sorted[i] - sorted[j] >= spacing {
                best[i] = max(best[i], best[j] + 1)
            }
        }
        return best.max() ?? 0
    }

    private static func bruteForceCalendarDayCapacity(windows: [SnsPublishWindow],
                                                      gap: Int,
                                                      perBatch: Int) -> Int {
        var inDay: Set<Int> = []
        var afterMidnight: Set<Int> = []
        for window in windows where window.isValid {
            let range = window.absoluteRange
            for minute in range where minute < 1440 { inDay.insert(minute) }
            for minute in range where minute >= 1440 { afterMidnight.insert(minute - 1440) }
        }
        let spacing = max(1, gap)
        return min(perBatch, bruteForceMaximumPoints(inDay, gap: spacing))
            + min(perBatch, bruteForceMaximumPoints(afterMidnight, gap: spacing))
    }

    func testWindowCapacityShortfallNilWhenNotApplicableOrFitting() {
        var times = SnsPublishSettings()
        times.mode = .times
        times.times = [point("t", 10 * 60)]
        times.maxPerDay = 3
        XCTAssertNil(times.windowCapacityShortfall(), "时间点模式不做容量诊断")

        var unlimited = SnsPublishSettings()
        unlimited.mode = .windows
        unlimited.windows = [window("short", 9 * 60, 9 * 60 + 10)]
        unlimited.maxPerDay = 0
        XCTAssertNil(
            unlimited.windowCapacityShortfall(),
            "无上限（maxPerDay=0）按实际槽位排，不做容量诊断"
        )

        var fits = SnsPublishSettings()
        fits.mode = .windows
        fits.windows = [window("wide", 9 * 60, 18 * 60)]
        fits.maxPerDay = 1
        fits.minIntervalMinutes = 30
        XCTAssertNil(fits.windowCapacityShortfall(), "排得下时返回 nil")
    }

    // MARK: - 8. 模式摘要 timingSummary

    func testTimingSummaryWindowsEmptyAndUnlimited() {
        var settings = SnsPublishSettings()
        settings.mode = .windows
        settings.windows = []
        XCTAssertEqual(settings.timingSummary(for: .windows), L("未设置可发时段"), "空时段显示未设置")

        settings.windows = [window("zero", 10 * 60, 10 * 60)]
        XCTAssertEqual(
            settings.timingSummary(for: .windows),
            L("未设置可发时段"),
            "只有非法时段也算未设置"
        )

        settings.windows = [window("day", 9 * 60, 18 * 60)]
        settings.maxPerDay = 0
        let unlimited = settings.timingSummary(for: .windows)
        XCTAssertTrue(
            unlimited.contains(L("每天无上限")),
            "无上限摘要必须包含「每天无上限」，实际：\(unlimited)"
        )
        XCTAssertTrue(unlimited.contains("09:00–18:00"), "摘要必须包含时段范围，实际：\(unlimited)")

        settings.maxPerDay = 3
        let limited = settings.timingSummary(for: .windows)
        XCTAssertTrue(
            limited.contains(Lf("每天最多 %d 次", 3)),
            "有限上限摘要必须包含每天次数，实际：\(limited)"
        )
    }

    func testTimingSummaryTimesShowsPointSummary() {
        var settings = SnsPublishSettings()
        // 当前选中 windows 时也能量出 times 模式的摘要（切换前预览）。
        settings.mode = .windows
        settings.times = []
        XCTAssertEqual(settings.timingSummary(for: .times), L("未设置时间点"), "空时间点显示未设置")

        settings.times = [point("am", 9 * 60), point("pm", 20 * 60)]
        let summary = settings.timingSummary(for: .times)
        XCTAssertTrue(summary.contains("09:00"), "时间点摘要必须包含 09:00，实际：\(summary)")
        XCTAssertTrue(summary.contains("20:00"), "时间点摘要必须包含 20:00，实际：\(summary)")
        XCTAssertTrue(
            summary.contains(Lf("每天 %d 次", 2)),
            "时间点摘要必须包含每天次数，实际：\(summary)"
        )
    }

    /// 额度用尽后的「下一次」：跨月/跨午夜都要落到下一个本地日历日的第一个可用时刻。
    func testFirstSlotAfterTodayHandlesMonthEndAndCrossMidnight() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var settings = SnsPublishSettings()
        settings.mode = .times
        settings.times = [
            point("am", 30),
            point("ten", 10 * 60)
        ]
        let now = try XCTUnwrap(cal.date(from: DateComponents(
            year: 2026, month: 12, day: 31, hour: 23, minute: 30
        )))
        let newYearEarly = try XCTUnwrap(cal.date(from: DateComponents(
            year: 2027, month: 1, day: 1, hour: 0, minute: 30
        )))
        XCTAssertEqual(
            settings.firstSlotAfterToday(after: now, calendar: cal),
            newYearEarly,
            "12/31 23:30 的下一次应是 1/1 00:30"
        )

        // 跨午夜窗口 22:00–02:00：次日首槽必须落在新年当天（凌晨），不能回到今天。
        settings.mode = .windows
        settings.windows = [SnsPublishWindow(id: "night", startMinute: 22 * 60, endMinute: 2 * 60)]
        settings.maxPerDay = 2
        settings.minIntervalMinutes = 0
        let next = try XCTUnwrap(settings.firstSlotAfterToday(after: now, calendar: cal))
        // 跨午夜窗口的随机取点可能整批落在午夜后：次日「日历日」内未必有槽位，
        // 所以用独立的 9 天扫描求期望值，验证它确实是「今天之后第一个」。
        let expected = (1...9).compactMap { offset -> Date? in
            guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now)) else {
                return nil
            }
            return settings.slots(inLocalDay: day, calendar: cal).first(where: { $0 > now })
        }.first
        XCTAssertEqual(next, expected, "跨午夜窗口应返回今天之后第一个可用时刻")
        XCTAssertGreaterThan(next, now)
        XCTAssertGreaterThan(cal.startOfDay(for: next), cal.startOfDay(for: now),
                             "下一次必须落在下一个本地日历日或更晚")
    }
}

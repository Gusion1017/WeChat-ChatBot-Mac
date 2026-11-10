import Foundation

// MARK: - 发布时机（设置页）
//
// 「发布时机」是自动发布里操作最稠密的一块：两种模式、最多 6 段可发时段、
// 最多 10 个时间点、每天上限与最小间隔。视图只负责展示与写回，所有判定
// （时段重叠/合并、今天排程、容量不足）都收敛在这里，便于单元测试。
//
// 语义约束（与 `SnsPublishSettings.slots` / bridge 一致）：
// - 时段端点都按「本地分钟 0–1439」表示，`end < start` 表示跨午夜；
// - 同一分钟重复的时间点只算一次（排程按分钟去重）；
// - 随机取点按区间总长加权，**重叠的时段会让重叠分钟权重更高**，
//   所以重叠不是错误配置，但值得提示并提供一键合并。

// MARK: - 模式摘要（模式卡片）

extension SnsPublishSettings {
    /// 模式卡片上的一句话摘要：不依赖当前选中的模式，切换前也能看到另一种模式的配置。
    func timingSummary(for mode: SnsPublishMode) -> String {
        switch mode {
        case .windows:
            let perDay = isMaxPerDayUnlimited
                ? L("每天无上限")
                : Lf("每天最多 %d 次", max(maxPerDay, 1))
            return hasValidWindow
                ? "\(windowsSummary) · \(perDay)"
                : L("未设置可发时段")
        case .times:
            guard !times.isEmpty else { return L("未设置时间点") }
            let count = Set(times.map(\.minute)).count
            return Lf("每天 %d 次：%@", count, timesSummary)
        }
    }
}

// MARK: - 时段重叠 / 合并

extension SnsPublishSettings {
    /// 两个有效时段是否重叠（把跨午夜窗口按 ±1 天平移后再比较）。
    ///
    /// 首尾相接（09:00–12:00 / 12:00–18:00）**不算**重叠：排程按区间取点，
    /// 相邻只共享一个端点分钟，合并与否对结果影响可以忽略；只有真正的重叠
    /// 才会让某段分钟在随机取点里被重复加权。
    static func windowsOverlap(_ lhs: SnsPublishWindow, _ rhs: SnsPublishWindow) -> Bool {
        guard lhs.isValid, rhs.isValid else { return false }
        let lhsRange = lhs.absoluteRange
        let rhsRange = rhs.absoluteRange
        if lhsRange.overlaps(rhsRange) { return true }
        let forward = (rhsRange.lowerBound + 1440)..<(rhsRange.upperBound + 1440)
        if lhsRange.overlaps(forward) { return true }
        let backward = (rhsRange.lowerBound - 1440)..<(rhsRange.upperBound - 1440)
        return lhsRange.overlaps(backward)
    }

    /// 参与重叠的有效时段 id 集合；空集表示没有重叠。
    var overlappingWindowIDs: Set<String> {
        let valid = windows.filter(\.isValid)
        guard valid.count > 1 else { return [] }
        var ids: Set<String> = []
        for left in valid.indices {
            for right in valid.indices where right > left {
                guard Self.windowsOverlap(valid[left], valid[right]) else { continue }
                ids.insert(valid[left].id)
                ids.insert(valid[right].id)
            }
        }
        return ids
    }

    var hasOverlappingWindows: Bool { !overlappingWindowIDs.isEmpty }

    /// 合并重叠（或首尾相接）的时段，结果按开始分钟排序；覆盖范围不变。
    ///
    /// 合并后每段仍满足 `startMinute != endMinute`：如果两段合起来覆盖整天，
    /// 收成 `00:00–23:59`（协议里没有「24:00」，零长度时段也无效）。
    var mergedWindows: [SnsPublishWindow] {
        var current = windows.filter(\.isValid).sorted { $0.startMinute < $1.startMinute }
        var didMerge = true
        while didMerge {
            didMerge = false
            outer: for left in current.indices {
                for right in current.indices where right > left {
                    guard Self.windowsMergeable(current[left], current[right]) else { continue }
                    let merged = Self.merge(current[left], current[right])
                    var next: [SnsPublishWindow] = []
                    for (index, window) in current.enumerated() where index != left && index != right {
                        next.append(window)
                    }
                    next.append(merged)
                    current = next.sorted { $0.startMinute < $1.startMinute }
                    didMerge = true
                    break outer
                }
            }
        }
        return current
    }

    /// 就地合并重叠/相接时段；没有可合并的时段时返回 false 且不改动配置。
    @discardableResult
    mutating func mergeOverlappingWindows() -> Bool {
        guard windowsMergeableCount > 0 else { return false }
        let merged = mergedWindows
        guard merged != windows else { return false }
        windows = Array(merged.prefix(Self.maxWindows))
        return true
    }

    /// 可合并的时段对数（重叠或首尾相接）；设置页据此显示「合并」入口。
    var windowsMergeableCount: Int {
        let valid = windows.filter(\.isValid)
        guard valid.count > 1 else { return 0 }
        var count = 0
        for left in valid.indices {
            for right in valid.indices where right > left {
                if Self.windowsMergeable(valid[left], valid[right]) { count += 1 }
            }
        }
        return count
    }

    /// 重叠或首尾相接（只差一个端点分钟）。
    static func windowsMergeable(_ lhs: SnsPublishWindow, _ rhs: SnsPublishWindow) -> Bool {
        guard lhs.isValid, rhs.isValid else { return false }
        if windowsOverlap(lhs, rhs) { return true }
        let lhsEnd = lhs.startMinute + lhs.lengthMinutes
        let rhsEnd = rhs.startMinute + rhs.lengthMinutes
        return lhsEnd % 1440 == rhs.startMinute % 1440
            || rhsEnd % 1440 == lhs.startMinute % 1440
    }

    /// 合并两段可合并时段：保留 `lhs` 的 id 作为新段身份（`ForEach` 稳定）。
    ///
    /// 跨午夜/首尾相接时并集的起点可能是任意一段的起点：分别以两个起点各算一次
    /// 顺时针跨度，取跨度小的那个。否则 `00:00–09:00` + `20:00–00:00` 会从 00:00
    /// 起算成 1440 分钟，被误收成「全天」（真实并集是 `20:00–09:00`）。
    static func merge(_ lhs: SnsPublishWindow, _ rhs: SnsPublishWindow) -> SnsPublishWindow {
        let fromLHS = unionSpan(start: lhs.startMinute,
                                length: lhs.lengthMinutes,
                                otherStart: rhs.startMinute,
                                otherLength: rhs.lengthMinutes)
        let fromRHS = unionSpan(start: rhs.startMinute,
                                length: rhs.lengthMinutes,
                                otherStart: lhs.startMinute,
                                otherLength: lhs.lengthMinutes)
        let start: Int
        let span: Int
        if fromLHS <= fromRHS {
            start = lhs.startMinute
            span = fromLHS
        } else {
            start = rhs.startMinute
            span = fromRHS
        }
        // 覆盖整天：协议没有 24:00，零长度时段也无效，收成 00:00–23:59。
        guard span < 1440 else {
            return SnsPublishWindow(id: lhs.id, startMinute: 0, endMinute: 23 * 60 + 59)
        }
        let endMinute = ((start + span) % 1440 + 1440) % 1440
        return SnsPublishWindow(id: lhs.id, startMinute: start, endMinute: endMinute).sanitized
    }

    /// 以 `start` 为起点顺时针覆盖两段所需分钟数（可 > 1440，调用方取较小值）。
    private static func unionSpan(start: Int,
                                  length: Int,
                                  otherStart: Int,
                                  otherLength: Int) -> Int {
        let otherStartRelative = ((otherStart - start) % 1440 + 1440) % 1440
        return max(length, otherStartRelative + otherLength)
    }
}

// MARK: - 时间点排序 / 去重

extension SnsPublishSettings {
    /// 时间点是否按分钟升序（允许重复分钟：重复由排程去重并另有提示）。
    var isTimesSorted: Bool {
        zip(times.map(\.minute), times.dropFirst().map(\.minute))
            .allSatisfy { $0 <= $1 }
    }

    /// 按分钟升序、同一分钟只留第一个（按当前顺序），并限制到上限。
    var sortedTimes: [SnsPublishTime] {
        let ordered = times.enumerated()
            .sorted { left, right in
                if left.element.minute != right.element.minute {
                    return left.element.minute < right.element.minute
                }
                return left.offset < right.offset
            }
            .map(\.element)
            .filter { (0..<1440).contains($0.minute) }
        var seen: Set<Int> = []
        let deduped = ordered.filter { seen.insert($0.minute).inserted }
        return Array(deduped.prefix(Self.maxTimePoints))
    }

    /// 就地排序 + 去重；没有变化时返回 false。
    @discardableResult
    mutating func normalizeTimes() -> Bool {
        let normalized = sortedTimes
        guard normalized != times else { return false }
        times = normalized
        return true
    }

}

// MARK: - 排程预览

extension SnsPublishSettings {
    /// 某个「本地日历日」内实际会触发的全部时刻。
    ///
    /// 不能直接用 `slots(on: day)`：跨午夜的时段会把次日凌晨的时刻放进**前一天**的
    /// 槽位集合（`absoluteRange` 上界可 > 1440），所以「今天凌晨 00:30」是由昨天的
    /// 配置生成的。这里同时取昨天与今天两组槽位、过滤到目标日并去重排序，得到与
    /// 调度器一致、且按日历日归类的时刻。
    func slots(inLocalDay day: Date, calendar: Calendar = .current) -> [Date] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        var result: [Date] = []
        for offset in -1...0 {
            guard let source = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            result.append(contentsOf: slots(on: source, calendar: calendar)
                .filter { $0 >= start && $0 < end })
        }
        // 跨午夜时段互相重叠时，两组来源可能生成同一时刻（调度器侧无害，预览需去重）。
        var seen: Set<Date> = []
        return result.filter { seen.insert($0).inserted }.sorted()
    }

    /// 今天（本地日历日）的全部触发时刻。
    func todaySlots(now: Date = Date(), calendar: Calendar = .current) -> [Date] {
        slots(inLocalDay: now, calendar: calendar)
    }

    /// 今天 `now` 之后还会触发的次数。
    func remainingSlotCount(now: Date = Date(), calendar: Calendar = .current) -> Int {
        todaySlots(now: now, calendar: calendar).filter { $0 > now }.count
    }

    /// 接下来 `limit` 个触发时刻（跨天、严格晚于 `now`、严格递增）。
    ///
    /// 与 `nextFireDate` / `isDue` 同源（`slots(on:)`），所以设置页列出的时刻就是
    /// 调度器真正会用的时刻；`windows` 模式的确定性随机保证同一天内多次刷新一致。
    /// 按日历日逐个取 `slots(inLocalDay:)`（已排序），跨午夜时段不会把次日的凌晨
    /// 时刻插到更晚日期的槽位之后。
    func upcomingSlots(limit: Int = 3,
                       after now: Date = Date(),
                       calendar: Calendar = .current) -> [Date] {
        guard limit > 0 else { return [] }
        let startOfDay = calendar.startOfDay(for: now)
        var result: [Date] = []
        for dayOffset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfDay) else { continue }
            for slot in slots(inLocalDay: day, calendar: calendar) where slot > now {
                result.append(slot)
                if result.count == limit { return result }
            }
        }
        return result
    }

    /// 从**下一个本地日历日**起扫描 9 天，返回第一个晚于 `now` 的可用时刻。
    ///
    /// 当日每个发布对象的额度都用尽时，调度器与设置页都用它把「下一次」顺延到明天；
    /// 统一放在模型里，避免调度器与视图各写一份实现后漂移。跨午夜时段按
    /// `slots(inLocalDay:)` 的日历日口径取槽位，不会把次日的凌晨时刻算到今天。
    func firstSlotAfterToday(after now: Date, calendar: Calendar = .current) -> Date? {
        guard let tomorrow = calendar.date(byAdding: .day, value: 1,
                                           to: calendar.startOfDay(for: now)) else { return nil }
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: tomorrow) else { continue }
            if let slot = slots(inLocalDay: day, calendar: calendar).first(where: { $0 > now }) {
                return slot
            }
        }
        return nextFireDate(after: tomorrow, calendar: calendar)
    }

    /// `windows` 模式下，一个本地日历日内最多能排出的时刻数（与当天随机结果无关）。
    ///
    /// 日历日 D 的时刻有两个来源：
    /// - 「批次 D」落在当天的部分（`[0, 1440)` 分钟）；
    /// - 「批次 D-1」跨午夜、落到 D 凌晨的部分（`[1440, 2880)` 分钟）。
    ///
    /// 每个批次最多选出 `dailyCapacity` 个时刻，所以两部分各自按「可发时段 + 最小间隔」
    /// 算**精确**可放点数（贪心取最早可行点）后按批次上限截断，再相加。
    /// 不跨午夜的普通配置只有第一部分，结果就等于单批可排点数；
    /// 跨午夜时两个批次会同时落进同一天，这样才不会把容量算少（口径与 ledger 的
    /// 「每好友每本地日历日上限」一致）。
    var calendarDayCapacity: Int {
        guard mode == .windows else { return dailyCapacity }
        let perBatch = dailyCapacity
        let gap = max(1, minIntervalMinutes)
        var inDay: [Range<Int>] = []
        var afterMidnight: [Range<Int>] = []
        // 必须按原始时段切片：先把「当天窗口」与「跨午夜窗口」合并成一条跨午夜时段，
        // 会把「当天窗口的当天部分」错误归到前一天的凌晨部分（容量被算少）。
        // `maxPointCount` 内部会合并重叠区间，所以这里不需要预合并。
        for window in windows.filter(\.isValid) {
            let range = window.absoluteRange
            if let dayPart = Self.slice(range, in: 0..<1440) {
                inDay.append(dayPart)
            }
            if let latePart = Self.slice(range, in: 1440..<2880) {
                afterMidnight.append((latePart.lowerBound - 1440)..<(latePart.upperBound - 1440))
            }
        }
        let inDayCapacity = min(perBatch, Self.maxPointCount(in: inDay, spacing: gap))
        let afterMidnightCapacity = min(perBatch, Self.maxPointCount(in: afterMidnight, spacing: gap))
        return inDayCapacity + afterMidnightCapacity
    }

    /// `windows` 模式下「设置每天 N 次，但可发时段 + 最小间隔排不下 N 次」的诊断。
    ///
    /// 用 `calendarDayCapacity`（而非当天随机结果）判断，避免把随机取点的偶然不足
    /// 误报成配置问题；返回 nil 表示不适用：时间点模式、无上限（本身就按可行槽位排）、
    /// 没有有效时段（由空状态提示），或日历日容量足够。
    func windowCapacityShortfall() -> (expected: Int, actual: Int)? {
        guard mode == .windows, !isMaxPerDayUnlimited, hasValidWindow else { return nil }
        let expected = dailyCapacity
        let capacity = calendarDayCapacity
        guard capacity < expected else { return nil }
        return (expected: expected, actual: capacity)
    }

    /// 在若干分钟内区间里、相邻点间隔 ≥ `spacing` 时最多能放几个点（精确值）。
    ///
    /// 区间先合并（重叠区间不能重复计数），再按「从最早可行分钟起贪心取点」计数：
    /// 对最小间隔约束，取最早可行点的贪心解就是最大点数。
    private static func maxPointCount(in ranges: [Range<Int>], spacing: Int) -> Int {
        let merged = mergedRanges(ranges)
        guard !merged.isEmpty else { return 0 }
        let gap = max(1, spacing)
        var count = 0
        var lastPicked: Int?
        for range in merged {
            var minute = range.lowerBound
            if let last = lastPicked {
                minute = max(minute, last + gap)
            }
            while minute < range.upperBound {
                count += 1
                lastPicked = minute
                minute += gap
            }
        }
        return count
    }

    /// 取区间与 `bounds` 的交集；没有交集时返回 nil（避免构造非法 Range 崩溃）。
    private static func slice(_ range: Range<Int>, in bounds: Range<Int>) -> Range<Int>? {
        let lower = max(range.lowerBound, bounds.lowerBound)
        let upper = min(range.upperBound, bounds.upperBound)
        return lower < upper ? lower..<upper : nil
    }

    /// 合并重叠/相接的分钟区间（输入不保证有序）。
    private static func mergedRanges(_ ranges: [Range<Int>]) -> [Range<Int>] {
        let sorted = ranges.filter { !$0.isEmpty }.sorted { $0.lowerBound < $1.lowerBound }
        var result: [Range<Int>] = []
        for range in sorted {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}

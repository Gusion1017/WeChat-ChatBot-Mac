import Foundation

// MARK: - 可见性

/// 朋友圈发布可见性（契约见 docs/sns.md §4.6、§6.2；2026-11-07 Lead 更新）。
///
/// - **默认 `partial`（部分可见）**：仅勾选当前私聊对象；没有关联私聊对象时按 `private` 处理；
/// - `public` 枚举保留以兼容历史数据/后续开放，但本迭代 UI 隐藏、客户端不会主动发送；
/// - 未知原始值回退 `partial`，避免桥接新增枚举导致整条动态解码失败。
enum SnsVisibility: String, Codable, CaseIterable, Hashable, Identifiable {
    case `public` = "public"
    case partial = "partial"
    case `private` = "private"

    var id: String { rawValue }

    /// 本迭代发布 UI 允许的选项（`public` 不提供）。
    static var publishOptions: [SnsVisibility] { [.partial, .private] }

    var label: String {
        switch self {
        case .public: L("公开")
        case .partial: L("部分可见")
        case .private: L("仅自己可见")
        }
    }

    var detail: String {
        switch self {
        case .public: L("所有好友可见（本迭代不提供）")
        case .partial: L("只有选择的好友可见")
        case .private: L("仅自己可见")
        }
    }

    /// 结合「是否有当前私聊对象」解析实际发布可见性。
    ///
    /// - 偏好 `partial` 但无上下文 → `private`；
    /// - 偏好 `public`（历史配置）→ 有上下文用 `partial`，否则 `private`。
    static func resolvedPublish(preferred: SnsVisibility, hasRecipient: Bool) -> SnsVisibility {
        switch preferred {
        case .partial: return hasRecipient ? .partial : .private
        case .private: return .private
        case .public: return hasRecipient ? .partial : .private
        }
    }

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = SnsVisibility(rawValue: raw.lowercased()) ?? .partial
    }
}

// MARK: - 图片加载

// v2 把旧的「图片下载策略」三档（缩略图 / 原图 / 关闭）收敛为一个开关：
// - 开启：列表自动加载缩略图；
// - 关闭：点击图片后再下载。
// 原图始终只在打开查看器时按需下载（查看器走 force 加载），旧枚举里的「原图」
// 与「缩略图」在实现上完全等价，属于伪设置，已删除。

// MARK: - 发布时段

/// 自动发布的每天可发时段（可多段；分钟为 0–1439 的本地时刻）。
///
/// v2 语义（与 bridge 侧 `snsPostTimeWindows` 对齐）：
/// - `endMinute < startMinute` 表示**跨午夜**，例如 23:00–01:00；
/// - `endMinute == startMinute` 视为零长度无效，`sanitized` 会补成 1 小时；
/// - 时段只表示「允许发布的时间范围」，具体触发点由 `SnsPublishSettings.slots(on:)` 生成。
struct SnsPublishWindow: Identifiable, Codable, Hashable {
    /// 默认时段使用固定 id：`SnsSettings()` 是值类型默认值，读取时不能每次生成新 UUID，
    /// 否则设置页 ForEach 的身份会不断变化。新增时段由设置页显式生成 UUID。
    var id: String = "publish-window-default"
    var startMinute: Int = 9 * 60
    var endMinute: Int = 22 * 60

    var isValid: Bool {
        (0..<1440).contains(startMinute)
            && (0..<1440).contains(endMinute)
            && startMinute != endMinute
    }

    /// 结束时刻落在次日（例如 23:00–01:00）。
    var crossesMidnight: Bool { endMinute < startMinute }

    /// 时段长度（分钟）；跨午夜时按 `end + 1440 - start` 计算。
    var lengthMinutes: Int {
        crossesMidnight ? endMinute + 1440 - startMinute : endMinute - startMinute
    }

    /// 该时段在「当天 0 点起的绝对分钟」区间；跨午夜时上界可大于 1440。
    var absoluteRange: Range<Int> {
        startMinute..<(startMinute + lengthMinutes)
    }

    var sanitized: SnsPublishWindow {
        var copy = self
        copy.startMinute = min(max(copy.startMinute, 0), 1439)
        copy.endMinute = min(max(copy.endMinute, 0), 1439)
        if copy.startMinute == copy.endMinute {
            copy.endMinute = (copy.startMinute + 60) % 1440
            if copy.endMinute == copy.startMinute {
                copy.endMinute = (copy.startMinute + 1) % 1440
            }
        }
        return copy
    }

    /// 例：`09:00–22:00`、`23:00–次日 01:00`。
    var summary: String {
        let start = Self.clockText(startMinute)
        let end = Self.clockText(endMinute)
        return crossesMidnight ? "\(start)–\(L("次日")) \(end)" : "\(start)–\(end)"
    }

    /// 与 bridge 相同的包含规则：同日 `[start, end]`；跨午夜 `[start, 24:00) ∪ [00:00, end]`。
    func contains(minuteOfDay: Int) -> Bool {
        guard isValid, (0..<1440).contains(minuteOfDay) else { return false }
        if crossesMidnight {
            return minuteOfDay >= startMinute || minuteOfDay <= endMinute
        }
        return minuteOfDay >= startMinute && minuteOfDay <= endMinute
    }

    static func clockText(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    static func date(fromMinute minute: Int, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .minute, value: minute, to: start) ?? start
    }

    static func minute(from date: Date, calendar: Calendar = .current) -> Int {
        calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }

    private enum CodingKeys: String, CodingKey {
        case id, startMinute, endMinute, start, end
    }
}

extension SnsPublishWindow {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SnsPublishWindow()
        var window = SnsPublishWindow(
            id: SnsJSON.string(container, .id) ?? UUID().uuidString,
            startMinute: SnsJSON.int(container, .startMinute) ?? defaults.startMinute,
            endMinute: SnsJSON.int(container, .endMinute) ?? defaults.endMinute
        )
        // 兼容手写配置里的 "09:00" 字符串形态。
        if let text = SnsJSON.string(container, .start), let minute = Self.parseClock(text) {
            window.startMinute = minute
        }
        if let text = SnsJSON.string(container, .end), let minute = Self.parseClock(text) {
            window.endMinute = minute
        }
        self = window.sanitized
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(startMinute, forKey: .startMinute)
        try container.encode(endMinute, forKey: .endMinute)
    }

    private static func parseClock(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute)
        else { return nil }
        return hour * 60 + minute
    }
}

// MARK: - 发布判定

/// 自动发布的逐目标判定结果（只表示「这个好友现在能不能发」，不表示「现在是不是排程时刻」）。
enum SnsPublishEligibility: String, Hashable {
    case allowed
    case disabled
    /// 没有有效时段/时间点，排程为空。
    case notScheduled
    case dailyLimitReached
    case intervalTooShort

    var isAllowed: Bool { self == .allowed }

    var message: String {
        switch self {
        case .allowed: L("当前允许自动发布")
        case .disabled: L("自动发布未开启")
        case .notScheduled: L("还没有设置可发布时间")
        case .dailyLimitReached: L("已达到该好友今天的发布上限")
        case .intervalTooShort: L("距上次发布不足最小间隔")
        }
    }
}

// MARK: - 发布时机

/// 自动发布时机（v2 两种，语义互不重叠）：
/// - `windows`：在允许时段内**随机**选取触发时刻（确定性随机，同一天内稳定）；
/// - `times`：每天在**固定时间点**触发。
///
/// 旧版第三档 `random`（时段内随机 1 次）与 `windows` 的 v2 语义重复，已合并进 `windows`，
/// 解码时按 `windows` 处理。
enum SnsPublishMode: String, Codable, CaseIterable, Hashable, Identifiable {
    case windows
    case times

    var id: String { rawValue }

    var label: String {
        switch self {
        case .windows: L("时段内随机")
        case .times: L("固定时间点")
        }
    }

    var detail: String {
        switch self {
        case .windows: L("在可发时段内随机发布")
        case .times: L("每天在固定时间点发布")
        }
    }

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        switch raw.lowercased() {
        case "times": self = .times
        case "random", "windows", "": self = .windows
        default: self = .windows
        }
    }
}

// MARK: - 指定时间点

/// 指定时间点（分钟为 0–1439 的本地时刻）。
struct SnsPublishTime: Identifiable, Codable, Hashable {
    var id: String = "publish-time-default"
    var minute: Int = 20 * 60

    init() {}

    init(id: String, minute: Int) {
        self.id = id
        self.minute = minute
    }

    var isValid: Bool { (0..<1440).contains(minute) }

    var summary: String { SnsPublishWindow.clockText(minute) }

    var sanitized: SnsPublishTime {
        var copy = self
        copy.minute = min(max(copy.minute, 0), 1439)
        return copy
    }

    private enum CodingKeys: String, CodingKey { case id, minute, time }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? "publish-time-default"
        if let value = try? container.decodeIfPresent(Int.self, forKey: .minute) {
            minute = value
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .time),
                  let parsed = SnsPublishTime.parse(text) {
            minute = parsed
        } else {
            minute = 20 * 60
        }
        minute = min(max(minute, 0), 1439)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(minute, forKey: .minute)
    }

    static func parse(_ text: String) -> Int? {
        let parts = text.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }
}

// MARK: - 确定性随机

/// 每天的时间点需要「同一天内稳定、跨进程一致」：用日期 + 时段配置做种子，
/// 这样设置页展示的「下一次发布」就是调度器真正会用的时刻，不会每次刷新都变。
struct SnsSeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// FNV-1a 64 位哈希，用于把配置文本变成种子。
    static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01B3
        }
        return value
    }
}

// MARK: - 自动发布设置

/// 自动发布设置（`bot.sns.publish`）。
///
/// v2 收敛点：
/// - 两种时机（时段内随机 / 固定时间点），取消旧版「时段起点触发」与第三档 random；
/// - 频率只在「时段内随机」下出现：每天上限 + 最小间隔；
/// - 新增 `targetUserIDs`：**必须显式选择发布对象**，空数组表示不发布（旧版会扇出到所有
///   AI 私聊会话，属于隐私风险）；
/** v3.0：完全自动发布——没有手动发布入口，也没有「发布前确认」；
 *  演练模式（bot.dryRun）只生成只读草稿，不发送、不写 ledger。 */
struct SnsPublishSettings: Codable, Hashable {
    /// 0 表示「无上限」：排程上限按 bridge 的全局每日上限 50 条计算，
    /// 实际仍受可发时段与同一好友最小间隔约束。
    static let maxPerDayRange: ClosedRange<Int> = 0...10
    static let minIntervalRange: ClosedRange<Int> = 0...1440
    static let maxTimePoints = 10
    /// 可发时段上限：设置页「最多 6 段」与排程/模型归一化共用同一常量。
    static let maxWindows = 6
    static let unlimitedDailyCapacity = 50
    /// 到点判定容差：调度误差/系统轻微睡眠内仍算「到点」；超过则跳过，不补发。
    static let dueToleranceSeconds: TimeInterval = 150

    /// 自动发布总开关，默认关。
    var enabled: Bool = false
    /// 时机模式，默认「时段内随机」。
    var mode: SnsPublishMode = .windows
    /// 每天可发时段（`mode == .windows` 时使用），默认 09:00–22:00。
    var windows: [SnsPublishWindow] = [SnsPublishWindow()]
    /// 指定时间点（`mode == .times` 时使用），默认 20:00 单点。
    var times: [SnsPublishTime] = [
        SnsPublishTime(id: "publish-time-default-pm", minute: 20 * 60)
    ]
    /// 每个好友每天最多几条（`mode == .windows` 时使用），默认 1；0 = 无上限。
    var maxPerDay: Int = 1
    /// 同一好友最小间隔（分钟，`mode == .windows` 且每天上限 > 1 时有意义），默认 120。
    var minIntervalMinutes: Int = 120
    /// 参与自动发布的私聊对象（用户 wxid）；空 = 不发布。
    var targetUserIDs: [String] = []

    var sanitized: SnsPublishSettings {
        var copy = self
        copy.maxPerDay = min(max(copy.maxPerDay, Self.maxPerDayRange.lowerBound),
                             Self.maxPerDayRange.upperBound)
        copy.minIntervalMinutes = min(max(copy.minIntervalMinutes, Self.minIntervalRange.lowerBound),
                                      Self.minIntervalRange.upperBound)
        copy.windows = Array(copy.windows.map(\.sanitized).prefix(Self.maxWindows))
        // 同一分钟重复的时间点只算一个：否则「每天最多 N 次」的 N 会被重复项虚增，
        // 而排程里同一时刻只生成一个槽位，等于永远发不满、面板数字也对不上。
        var seenMinutes: Set<Int> = []
        copy.times = copy.times
            .map(\.sanitized)
            .filter { seenMinutes.insert($0.minute).inserted }
        copy.times = Array(copy.times.prefix(Self.maxTimePoints))
        var seen: Set<String> = []
        copy.targetUserIDs = copy.targetUserIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return copy
    }

    var hasValidWindow: Bool { windows.contains(where: \.isValid) }

    var windowsSummary: String {
        let valid = windows.filter(\.isValid)
        return valid.isEmpty ? L("未设置可发时段") : valid.map(\.summary).joined(separator: " · ")
    }

    var timesSummary: String {
        times.isEmpty ? L("未设置时间点") : times.map(\.summary).joined(separator: " · ")
    }

    /// 每个好友每天上限是否为「无上限」（0）。
    var isMaxPerDayUnlimited: Bool { sanitized.maxPerDay == 0 }

    /// 单日最多触发次数（按模式计算；设置页用它展示「每天最多 N 次」）。
    /// 无上限时按 bridge 全局每日 50 条兜底计算排程上限，避免生成无限槽位。
    var dailyCapacity: Int {
        switch mode {
        case .times:
            return max(1, min(sanitized.times.count, Self.maxTimePoints))
        case .windows:
            return isMaxPerDayUnlimited
                ? Self.unlimitedDailyCapacity
                : max(1, sanitized.maxPerDay)
        }
    }

    /// 一句话摘要，用于设置页 subtitle。
    var scheduleSummary: String {
        switch mode {
        case .times:
            // 同一分钟重复的时间点排程会去重，摘要与「每天次数」都按去重后的数量展示。
            return Lf("每天 %d 次：%@", sanitized.times.count, timesSummary)
        case .windows:
            if isMaxPerDayUnlimited {
                return Lf("每天不设上限，在 %@ 内随机（受最小间隔与 bridge 每日 %d 条兜底）",
                          windowsSummary, Self.unlimitedDailyCapacity)
            }
            return Lf("每天最多 %d 次，在 %@ 内随机", maxPerDay, windowsSummary)
        }
    }

    func isWithinWindow(_ date: Date, calendar: Calendar = .current) -> Bool {
        let minute = SnsPublishWindow.minute(from: date, calendar: calendar)
        return windows.contains { $0.contains(minuteOfDay: minute) }
    }

    // MARK: 排程

    /// 某一天的全部触发时刻（本地时区）。
    ///
    /// - `.times`：每天的时间点；
    /// - `.windows`：在有效时段内按确定性随机生成 `maxPerDay` 个时刻，
    ///   相邻时刻间隔不小于 `minIntervalMinutes`；放不下时自动减少数量。
    ///
    /// 跨午夜的时段会生成次日凌晨的时刻（`absoluteRange` 上界可 > 1440）。
    func slots(on day: Date, calendar: Calendar = .current) -> [Date] {
        let startOfDay = calendar.startOfDay(for: day)
        var offsets: [Int]
        switch mode {
        case .times:
            var seen: Set<Int> = []
            offsets = times
                .map(\.minute)
                .filter { (0..<1440).contains($0) && seen.insert($0).inserted }
                .sorted()
            offsets = Array(offsets.prefix(dailyCapacity))
        case .windows:
            let ranges = windows.filter(\.isValid).map(\.absoluteRange)
            offsets = Self.randomOffsets(
                ranges: ranges,
                count: dailyCapacity,
                spacing: minIntervalMinutes,
                seed: seed(for: startOfDay, calendar: calendar)
            )
        }
        return offsets.sorted().compactMap {
            calendar.date(byAdding: .minute, value: $0, to: startOfDay)
        }
    }

    /// 下一次触发时刻（严格晚于 `date`）；8 天内没有可用排程时返回 nil。
    func nextFireDate(after date: Date = Date(), calendar: Calendar = .current) -> Date? {
        let startOfDay = calendar.startOfDay(for: date)
        var best: Date?
        for dayOffset in -1...8 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfDay) else { continue }
            for slot in slots(on: day, calendar: calendar) where slot > date {
                if let current = best, slot >= current { continue }
                best = slot
            }
        }
        return best
    }

    /// 当前时刻是否命中排程（允许 `dueToleranceSeconds` 误差）。
    /// 用它在真正发布前二次校验，避免系统睡眠/唤醒后在时段内任意时刻「补发」。
    func isDue(at now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let startOfDay = calendar.startOfDay(for: now)
        for dayOffset in -1...0 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfDay) else { continue }
            for slot in slots(on: day, calendar: calendar)
            where abs(slot.timeIntervalSince(now)) <= Self.dueToleranceSeconds {
                return true
            }
        }
        return false
    }

    /// 逐目标判定：只回答「这个好友现在能不能发」，与「现在是不是排程时刻」无关。
    func eligibility(
        now: Date = Date(),
        sentToday: Int,
        lastSentAt: Date?,
        calendar: Calendar = .current
    ) -> SnsPublishEligibility {
        guard enabled else { return .disabled }
        switch mode {
        case .times:
            guard !times.isEmpty else { return .notScheduled }
            guard sentToday < dailyCapacity else { return .dailyLimitReached }
        case .windows:
            guard hasValidWindow else { return .notScheduled }
            guard sentToday < dailyCapacity else { return .dailyLimitReached }
            if minIntervalMinutes > 0, sentToday > 0, let lastSentAt {
                let elapsed = now.timeIntervalSince(lastSentAt)
                if elapsed < Double(minIntervalMinutes) * 60 { return .intervalTooShort }
            }
        }
        return .allowed
    }

    // MARK: 内部

    /// 在若干（可能跨午夜的）绝对分钟区间里取 `count` 个点，相邻间隔 ≥ `spacing`。
    /// 区间总长不够时返回更少的点，不编造时间。
    private static func randomOffsets(
        ranges: [Range<Int>],
        count: Int,
        spacing: Int,
        seed: UInt64
    ) -> [Int] {
        guard count > 0, !ranges.isEmpty else { return [] }
        let total = ranges.reduce(0) { $0 + $1.count }
        guard total > 0 else { return [] }
        var rng = SnsSeededRandomNumberGenerator(seed: seed)
        let gap = max(1, spacing)
        var chosen: [Int] = []
        var attempts = 0
        let limit = max(60, count * 80)
        while chosen.count < count, attempts < limit {
            attempts += 1
            var index = Int.random(in: 0..<total, using: &rng)
            var offset = 0
            for range in ranges {
                if index < range.count {
                    offset = range.lowerBound + index
                    break
                }
                index -= range.count
            }
            if chosen.allSatisfy({ abs($0 - offset) >= gap }) {
                chosen.append(offset)
            }
        }
        return chosen
    }

    private func seed(for startOfDay: Date, calendar: Calendar) -> UInt64 {
        let comps = calendar.dateComponents([.year, .month, .day], from: startOfDay)
        var text = String(format: "%04d-%02d-%02d",
                          comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
        text += "|\(mode.rawValue)|\(maxPerDay)|\(minIntervalMinutes)|"
        text += windows.filter(\.isValid)
            .map { "\($0.startMinute)-\($0.endMinute)" }
            .sorted()
            .joined(separator: ",")
        return SnsSeededRandomNumberGenerator.hash(text)
    }
}

extension SnsPublishSettings {
    private enum CodingKeys: String, CodingKey {
        case enabled, mode, windows, times, maxPerDay, minIntervalMinutes
        case targetUserIDs, targetUserIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SnsPublishSettings()
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? defaults.enabled
        if let rawMode = try? container.decodeIfPresent(String.self, forKey: .mode) {
            mode = SnsPublishMode(rawValue: rawMode.lowercased()) ?? .windows
        } else {
            mode = defaults.mode
        }
        if container.contains(.times) {
            times = SnsJSON.lossyArray(container, .times, as: SnsPublishTime.self)
                .map { $0.sanitized }
        } else {
            times = defaults.times
        }
        if container.contains(.windows) {
            windows = SnsJSON.lossyArray(container, .windows, as: SnsPublishWindow.self)
                .map { $0.sanitized }
        } else {
            windows = defaults.windows
        }
        maxPerDay = min(max(SnsJSON.int(container, .maxPerDay) ?? defaults.maxPerDay,
                            Self.maxPerDayRange.lowerBound),
                        Self.maxPerDayRange.upperBound)
        minIntervalMinutes = min(max(SnsJSON.int(container, .minIntervalMinutes)
                                        ?? defaults.minIntervalMinutes,
                                     Self.minIntervalRange.lowerBound),
                                 Self.minIntervalRange.upperBound)
        if container.contains(.targetUserIDs) || container.contains(.targetUserIds) {
            let key: CodingKeys = container.contains(.targetUserIDs) ? .targetUserIDs : .targetUserIds
            targetUserIDs = (try? container.decodeIfPresent([String].self, forKey: key)) ?? []
        } else {
            targetUserIDs = defaults.targetUserIDs
        }
        self = sanitized
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(mode, forKey: .mode)
        try container.encode(windows, forKey: .windows)
        try container.encode(times, forKey: .times)
        try container.encode(maxPerDay, forKey: .maxPerDay)
        try container.encode(minIntervalMinutes, forKey: .minIntervalMinutes)
        try container.encode(targetUserIDs, forKey: .targetUserIDs)
    }
}

// MARK: - 发布对象

/// 「部分可见」使用的对端好友。展示名来自会话标题，绝不展示裸 wxid。
struct SnsPublishRecipient: Identifiable, Hashable {
    var userID: String
    var displayName: String

    var id: String { userID }

    var displayTitle: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L("微信好友") : trimmed
    }
}

// MARK: - App 设置（bot.sns）

// MARK: - 演练草稿（自动发布 outbox）

/// 演练模式下自动发布生成的只读草稿（v3.0 起不再有人工确认发布）。
///
/// 只存本机账号目录（`accounts/<wxid>/sns-outbox.json`），不入库、不上传；
/// 确认发布成功后由 App 移除，失败则保留供用户重试。
struct SnsPendingDraft: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var createdAt: Date = Date()
    var text: String = ""
    /// 「部分可见」只勾选该好友；空字符串表示无对象（不应出现）。
    var targetUserID: String = ""
    var targetName: String = ""
    /// 演练模式生成：只用于预览，不允许从列表直接发布。
    var isDryRun: Bool = false
    /// 原计划触发时间（展示用，例如「11-08 14:32」）。
    var scheduledLabel: String = ""

    var displayTarget: String {
        let trimmed = targetName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L("微信好友") : trimmed
    }

    var preview: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
    }
}

// MARK: - 自动互动（AI 评论 / 回复）

/// AI 自动互动类别。
enum SnsInteractionKind: String, Codable, CaseIterable, Hashable, Identifiable {
    /// 给白名单私聊对象的新动态写评论。
    case commentOnPost = "comment_on_post"
    /// 回复自己动态下的评论。
    case replyOnOwnPost = "reply_on_own_post"
    /// 别人回复了我的评论时再回复对方（发生在别人的动态下）。
    case replyToMyComment = "reply_to_my_comment"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .commentOnPost: L("评论新动态")
        case .replyOnOwnPost: L("回复我的动态")
        case .replyToMyComment: L("回复我收到的回复")
        }
    }

    var detail: String {
        switch self {
        case .commentOnPost:
            L("白名单私聊好友发新动态时，AI 写一条简短评论")
        case .replyOnOwnPost:
            L("自己的动态下有白名单私聊好友的评论时，AI 回复")
        case .replyToMyComment:
            L("别人动态下，白名单私聊好友回复我的评论时，AI 再回复")
        }
    }

    var symbol: String {
        switch self {
        case .commentOnPost: "text.bubble"
        case .replyOnOwnPost: "arrowshape.turn.up.left"
        case .replyToMyComment: "arrowshape.turn.up.left.2"
        }
    }
}

/// 自动互动结果（运行期展示，不持久化正文）。
enum SnsInteractionOutcome: String, Codable, Hashable {
    case sent
    case dryRun
    case failed

    var label: String {
        switch self {
        case .sent: L("已发送")
        case .dryRun: L("演练（未发送）")
        case .failed: L("失败")
        }
    }
}

/// 一条自动互动记录：设置页「最近互动」只读展示。
///
/// 仅驻留内存（上限 30 条），不落库、不上传；`text` 为 AI 生成的评论正文，
/// 便于用户核对自动互动内容。运行日志只记计数，不写正文。
struct SnsInteractionActivity: Identifiable, Hashable {
    var id: String = UUID().uuidString
    var at: Date = Date()
    var kind: SnsInteractionKind = .commentOnPost
    var postID: String = ""
    var postAuthorName: String = ""
    /// 被评论/被回复的好友昵称（不含裸 wxid）。
    var targetUserName: String = ""
    /// 被回复的评论正文（直接评论动态时为空）。
    var repliedCommentText: String = ""
    var text: String = ""
    /// 本次生成参考的图片识别描述条数（不保存描述正文）。
    var imageCount: Int = 0
    var outcome: SnsInteractionOutcome = .sent
    var error: String?

    var displayPostAuthor: String {
        let trimmed = postAuthorName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L("微信好友") : trimmed
    }

    var displayTarget: String {
        let trimmed = targetUserName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? displayPostAuthor : trimmed
    }

    var headline: String {
        switch kind {
        case .commentOnPost:
            return Lf("评论了 %@ 的动态", displayPostAuthor)
        case .replyOnOwnPost:
            return Lf("回复了 %@ 的评论", displayTarget)
        case .replyToMyComment:
            return Lf("回复了 %@", displayTarget)
        }
    }

    var preview: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
    }
}

/// 一轮自动互动的汇总（只含计数与首条错误，不保存正文）。
struct SnsInteractionRunSummary: Hashable {
    var checkedAt: Date = Date()
    /// 本轮从 native 时间线读到的动态条数；用于区分「确实没有新内容」与「检查根本没跑」。
    var scannedPostCount: Int = 0
    /// 本轮规划器产出的候选数（0 = 没有符合名单/时效/去重条件的动态或评论）。
    var candidateCount: Int = 0
    var commentedCount: Int = 0
    var repliedCount: Int = 0
    /// 演练模式生成、未发送的条数。
    var draftedCount: Int = 0
    var skippedCount: Int = 0
    var failedCount: Int = 0
    var firstError: String?
    var nextCheckAt: Date?

    var handledCount: Int { commentedCount + repliedCount }
}

/// 自动互动的对象来源：聊天白名单里的私聊对象。
///
/// 2026-11-11 起不再单独维护「互动名单」：直接复用聊天白名单（`bot.effectiveWhitelist`，
/// 即「机器人 → 名单 → 白名单」）里能对应到私聊会话（`Conversation.kind == .direct`）的对象，
/// 避免两套名单互相打架。聊天黑名单仍是硬门槛，由调度器/规划器另行排除。
///
/// 注意与聊天回复的差异：聊天白名单为空表示「不限制」，但这里为空表示**没有互动对象**，
/// 不会退化为「所有好友」——自动评论/回复必须显式配置对象。
enum SnsInteractionTargets {
    /// 从白名单与会话列表推导互动对象。
    ///
    /// - 只保留白名单里与私聊会话 ID 匹配的条目（排除群聊 / 服务号 / 只作为群发言人出现的 wxid）；
    /// - 保持白名单顺序、去空白、去重；空 ID 永远不进入结果。
    static func whitelistDirectUserIDs(
        whitelist: [String],
        conversations: [Conversation]
    ) -> [String] {
        let directIDs = Set(conversations
            .filter { $0.kind == .direct }
            .map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { ConversationIdentity.isPlausiblePeerID($0) })
        guard !directIDs.isEmpty else { return [] }
        var seen: Set<String> = []
        var result: [String] = []
        for raw in whitelist {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ConversationIdentity.isPlausiblePeerID(id),
                  directIDs.contains(id),
                  seen.insert(id).inserted else { continue }
            result.append(id)
        }
        return result
    }
}

/// 朋友圈 AI 自动互动设置（`bot.sns.interaction`）。
///
/// 设计边界：
/// - **默认全关**：互动对象直接取聊天白名单里的私聊对象，白名单为空则不互动；
/// - 聊天黑名单始终是硬门槛（即使好友在聊天白名单里也不会被互动）；
/// - 频率受「每天上限 + 两次互动最小间隔 + 单条动态最多回复几条 + 只处理最近 N 小时」共同约束；
/// - 只写评论/回复，不点赞、不删评论；失败不自动重发（由下一轮检查按退避重试）。
struct SnsInteractionSettings: Codable, Hashable {
    /// 0 表示「无上限」：只受最小间隔、检查节奏以及单轮最多处理条数约束。
    static let maxPerDayRange: ClosedRange<Int> = 0...20
    static let minIntervalRange: ClosedRange<Int> = 0...180
    static let maxAgeHoursRange: ClosedRange<Int> = 1...72
    /// 0 表示「无上限」：同一条动态当天可回复任意条评论，仍受去重与频率设置约束。
    static let maxRepliesPerPostRange: ClosedRange<Int> = 0...5
    static let checkIntervalRange: ClosedRange<Double> = 60...600
    /// 「无上限」哨兵值（0），用于设置面板与调度器判定。
    static let unlimitedValue = 0

    /// 自动互动总开关，默认关。
    var enabled: Bool = false
    /// 给白名单私聊对象的新动态写评论。
    var commentOnNewPosts: Bool = true
    /// 回复自己动态下的评论（评论者需在聊天白名单内）。
    var replyToOwnPostComments: Bool = true
    /// 别人回复了我的评论时，再回复对方的回复。
    var replyToMyCommentReplies: Bool = true
    /// 互动前识别动态图片，帮助 AI 理解内容（复用「AI 模型 → 识图模型」）。
    var useVision: Bool = true
    /// 每天最多互动次数（评论 + 回复合计）。
    var maxPerDay: Int = 6
    /// 两次自动互动的最小间隔（分钟）。
    var minIntervalMinutes: Int = 5
    /// 只处理最近 N 小时内的新动态/新评论，避免开启后回复陈年内容。
    var maxAgeHours: Int = 24
    /// 同一条动态每天最多回复几条评论（评论新动态不计入），避免来回刷屏。
    var maxRepliesPerPost: Int = 2
    /// 检查新内容的间隔（秒）。
    var checkIntervalSeconds: Double = 120

    var sanitized: SnsInteractionSettings {
        var copy = self
        copy.maxPerDay = min(max(copy.maxPerDay, Self.maxPerDayRange.lowerBound),
                             Self.maxPerDayRange.upperBound)
        copy.minIntervalMinutes = min(max(copy.minIntervalMinutes, Self.minIntervalRange.lowerBound),
                                      Self.minIntervalRange.upperBound)
        copy.maxAgeHours = min(max(copy.maxAgeHours, Self.maxAgeHoursRange.lowerBound),
                               Self.maxAgeHoursRange.upperBound)
        copy.maxRepliesPerPost = min(max(copy.maxRepliesPerPost,
                                         Self.maxRepliesPerPostRange.lowerBound),
                                     Self.maxRepliesPerPostRange.upperBound)
        copy.checkIntervalSeconds = min(max(copy.checkIntervalSeconds,
                                            Self.checkIntervalRange.lowerBound),
                                        Self.checkIntervalRange.upperBound)
        return copy
    }

    var effectiveCheckInterval: TimeInterval { sanitized.checkIntervalSeconds }
    var effectiveMinInterval: TimeInterval {
        TimeInterval(sanitized.minIntervalMinutes) * 60
    }
    /// 每天互动次数是否不设上限（0 = 无上限）。
    var isMaxPerDayUnlimited: Bool { sanitized.maxPerDay == Self.unlimitedValue }
    /// 单条动态每天回复数是否不设上限（0 = 无上限）。
    var isMaxRepliesPerPostUnlimited: Bool {
        sanitized.maxRepliesPerPost == Self.unlimitedValue
    }
    /// 至少启用了一种互动动作。
    var hasAction: Bool {
        commentOnNewPosts || replyToOwnPostComments || replyToMyCommentReplies
    }
    /// 配置层面已启用且至少一种动作：真正的「可互动」还要叠加白名单私聊对象非空
    /// （运行期由 `SnsInteractionTargets` 推导，见 `SnsInteractionScheduler.Configuration`）。
    var isActive: Bool { enabled && hasAction }
}

extension SnsInteractionSettings {
    private enum CodingKeys: String, CodingKey {
        case enabled
        case commentOnNewPosts, replyToOwnPostComments, replyToMyCommentReplies
        case useVision, maxPerDay, minIntervalMinutes, maxAgeHours
        case maxRepliesPerPost, checkIntervalSeconds
    }

    /// 逐键容错解码：缺键/类型损坏只回退该字段，不丢整份 `bot.sns`。
    ///
    /// 旧配置里的 `targetUserIDs` / `replyScope` 已移除：解码器自动忽略未知键，
    /// 不需要迁移，也不会因为这两个旧键存在而失败。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SnsInteractionSettings()
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? defaults.enabled
        commentOnNewPosts = (try? container.decodeIfPresent(
            Bool.self, forKey: .commentOnNewPosts)) ?? defaults.commentOnNewPosts
        replyToOwnPostComments = (try? container.decodeIfPresent(
            Bool.self, forKey: .replyToOwnPostComments)) ?? defaults.replyToOwnPostComments
        replyToMyCommentReplies = (try? container.decodeIfPresent(
            Bool.self, forKey: .replyToMyCommentReplies)) ?? defaults.replyToMyCommentReplies
        useVision = (try? container.decodeIfPresent(Bool.self, forKey: .useVision))
            ?? defaults.useVision
        maxPerDay = SnsJSON.int(container, .maxPerDay) ?? defaults.maxPerDay
        minIntervalMinutes = SnsJSON.int(container, .minIntervalMinutes)
            ?? defaults.minIntervalMinutes
        maxAgeHours = SnsJSON.int(container, .maxAgeHours) ?? defaults.maxAgeHours
        maxRepliesPerPost = SnsJSON.int(container, .maxRepliesPerPost)
            ?? defaults.maxRepliesPerPost
        checkIntervalSeconds = (try? container.decodeIfPresent(
            Double.self, forKey: .checkIntervalSeconds)) ?? defaults.checkIntervalSeconds
        self = sanitized
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(commentOnNewPosts, forKey: .commentOnNewPosts)
        try container.encode(replyToOwnPostComments, forKey: .replyToOwnPostComments)
        try container.encode(replyToMyCommentReplies, forKey: .replyToMyCommentReplies)
        try container.encode(useVision, forKey: .useVision)
        try container.encode(maxPerDay, forKey: .maxPerDay)
        try container.encode(minIntervalMinutes, forKey: .minIntervalMinutes)
        try container.encode(maxAgeHours, forKey: .maxAgeHours)
        try container.encode(maxRepliesPerPost, forKey: .maxRepliesPerPost)
        try container.encode(checkIntervalSeconds, forKey: .checkIntervalSeconds)
    }
}

/// 「朋友圈内容写入对方记忆」设置（`bot.sns.memory`）。
///
/// 读取到好友（私聊、开启 AI 自动回复）的动态后，把正文写入该好友的记忆卡，
/// 让之后的聊天与自动互动能自然记得「ta 最近发过什么」。只写本机记忆库，
/// 不上传、不写微信数据；关掉后立即停止写入，既有记忆卡内容保留。
struct SnsMemorySettings: Codable, Hashable {
    /// 默认开启：这是朋友圈读取的自然延伸，用户可以随时关闭。
    var enabled: Bool = true
    /// 若动态图片当轮已被识图模型分析过，把分析摘要一并写入记忆正文（不重复请求模型）。
    var includeImageDescriptions: Bool = true

    /// 只做类型层面的归一化；不因总开关关闭就改写子开关，
    /// 否则「关闭记忆再打开」会静默丢失用户的图片分析偏好。
    var sanitized: SnsMemorySettings { self }
}

extension SnsMemorySettings {
    private enum CodingKeys: String, CodingKey {
        case enabled, includeImageDescriptions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SnsMemorySettings()
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled))
            ?? defaults.enabled
        includeImageDescriptions = (try? container.decodeIfPresent(
            Bool.self, forKey: .includeImageDescriptions)) ?? defaults.includeImageDescriptions
        self = sanitized
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let value = sanitized
        try container.encode(value.enabled, forKey: .enabled)
        try container.encode(value.includeImageDescriptions, forKey: .includeImageDescriptions)
    }
}

/// 朋友圈 App 设置；持久化在账号级 `profile.json` 的 `bot.sns`。
///
/// v2 默认：功能与写操作都关闭；列表自动加载缩略图；可见性固定 `partial`
/// （无当前私聊对象时按 `private` 处理）；自动发布关闭且**未选择任何发布对象**；
/// AI 自动互动关闭（互动对象取聊天白名单里的私聊对象）；好友朋友圈内容默认写入其记忆卡。
struct SnsSettings: Codable, Hashable {
    static let syncIntervalRange: ClosedRange<Double> = 30...300
    static let defaultSyncInterval: Double = 60

    var enabled: Bool = false
    /// 后台同步（轮询 `/sns/sync`）。P5 事件解码完成前设置页不暴露，仅保留配置位与调度代码。
    var autoSync: Bool = true
    var syncIntervalSeconds: Double = SnsSettings.defaultSyncInterval
    /// 列表自动加载缩略图；关闭后点击图片才下载（原图始终按需加载）。
    var autoLoadThumbnails: Bool = true
    /// 发布可见性：本迭代固定 `partial`（无关联会话时降级 `private`），仅保留兼容位。
    var defaultVisibility: SnsVisibility = .partial
    /// 发布写开关；默认关闭。改动需要 bridge 重启后才对 bridge 生效（设置页会提示）。
    var writeEnabled: Bool = false
    /// 自动发布设置（默认关）。
    var publish: SnsPublishSettings = SnsPublishSettings()
    /// AI 自动互动（评论 / 回复）设置（默认关；互动对象取聊天白名单里的私聊对象）。
    var interaction: SnsInteractionSettings = SnsInteractionSettings()
    /// 好友朋友圈内容写入对方记忆卡（默认开）。
    var memory: SnsMemorySettings = SnsMemorySettings()

    /// 收敛同步间隔到契约范围 30–300s；历史 `public` 配置按 `partial` 处理。
    var sanitized: SnsSettings {
        var copy = self
        copy.syncIntervalSeconds = min(max(copy.syncIntervalSeconds, Self.syncIntervalRange.lowerBound),
                                        Self.syncIntervalRange.upperBound)
        if copy.defaultVisibility == .public {
            copy.defaultVisibility = .partial
        }
        copy.publish = copy.publish.sanitized
        copy.interaction = copy.interaction.sanitized
        copy.memory = copy.memory.sanitized
        return copy
    }

    var effectiveSyncInterval: TimeInterval { sanitized.syncIntervalSeconds }
}

extension SnsSettings {
    private enum CodingKeys: String, CodingKey {
        case enabled, autoSync, syncIntervalSeconds, imageDownload, autoLoadThumbnails
        case defaultVisibility, writeEnabled, publish, interaction, memory
    }

    /// 逐键容错解码：缺键或类型损坏只回退该字段，不丢整份 `bot` 段。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SnsSettings()
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? defaults.enabled
        autoSync = (try? container.decodeIfPresent(Bool.self, forKey: .autoSync)) ?? defaults.autoSync
        let interval = (try? container.decodeIfPresent(Double.self, forKey: .syncIntervalSeconds))
            ?? defaults.syncIntervalSeconds
        syncIntervalSeconds = min(max(interval, Self.syncIntervalRange.lowerBound),
                                  Self.syncIntervalRange.upperBound)
        if let value = try? container.decodeIfPresent(Bool.self, forKey: .autoLoadThumbnails) {
            autoLoadThumbnails = value
        } else {
            // 迁移旧三档 imageDownload：只有 off 表示「不自动加载」，其余（含缺键）视为开启。
            let legacy = (try? container.decodeIfPresent(String.self, forKey: .imageDownload)) ?? ""
            autoLoadThumbnails = legacy.lowercased() != "off"
        }
        let visibility = (try? container.decodeIfPresent(String.self, forKey: .defaultVisibility))
            .flatMap(SnsVisibility.init(rawValue:))
        // 本迭代不提供公开；历史 public 配置迁移为 partial。
        defaultVisibility = (visibility == .public ? .partial : visibility) ?? defaults.defaultVisibility
        writeEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .writeEnabled))
            ?? defaults.writeEnabled
        publish = (try? container.decodeIfPresent(SnsPublishSettings.self, forKey: .publish))
            ?? defaults.publish
        interaction = (try? container.decodeIfPresent(
            SnsInteractionSettings.self, forKey: .interaction)) ?? defaults.interaction
        memory = (try? container.decodeIfPresent(
            SnsMemorySettings.self, forKey: .memory)) ?? defaults.memory
        self = sanitized
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(autoSync, forKey: .autoSync)
        try container.encode(syncIntervalSeconds, forKey: .syncIntervalSeconds)
        try container.encode(autoLoadThumbnails, forKey: .autoLoadThumbnails)
        try container.encode(defaultVisibility, forKey: .defaultVisibility)
        try container.encode(writeEnabled, forKey: .writeEnabled)
        try container.encode(publish, forKey: .publish)
        try container.encode(interaction, forKey: .interaction)
        try container.encode(memory, forKey: .memory)
    }
}

// MARK: - 解码工具

/// 朋友圈 JSON 的容错解码工具。
///
/// 契约要求「缺字段/未知字段不导致整段失败」，同时 `id` 等 uint64 字段一律是字符串。
/// 数值字段兼容桥接在调试期偶尔写出的数字/字符串两种形态。
enum SnsJSON {
    static func string<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(UInt64.self, forKey: key) { return String(value) }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return integerText(from: value)
        }
        return nil
    }

    static func int<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return boundedInt(from: value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            if let int = Int(value) { return int }
            if let double = Double(value) { return boundedInt(from: double) }
        }
        return nil
    }

    /// `Int(Double)` 在非有限值/超出 Int64 范围时会直接 trap；解码只做容错，不能崩。
    private static func boundedInt(from value: Double) -> Int? {
        guard value.isFinite, value >= -9.0e18, value <= 9.0e18 else { return nil }
        return Int(value)
    }

    private static func integerText(from value: Double) -> String? {
        guard let value = boundedInt(from: value) else { return nil }
        return String(value)
    }

    static func bool<K: CodingKey>(_ container: KeyedDecodingContainer<K>, _ key: K) -> Bool? {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            switch value.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    /// 先按标准数组解码；失败时逐元素降级，跳过真正损坏的元素而不是丢整页。
    static func lossyArray<T: Decodable, K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        _ key: K,
        as type: T.Type
    ) -> [T] {
        if let values = try? container.decodeIfPresent([T].self, forKey: key) { return values }
        guard let raw = try? container.decodeIfPresent([SnsJSONValue].self, forKey: key) else { return [] }
        var result: [T] = []
        for value in raw {
            guard JSONSerialization.isValidJSONObject(value.foundationValue),
                  let data = try? JSONSerialization.data(withJSONObject: value.foundationValue),
                  let decoded = try? JSONDecoder().decode(T.self, from: data)
            else { continue }
            result.append(decoded)
        }
        return result
    }

    static func object<T: Decodable, K: CodingKey>(
        _ container: KeyedDecodingContainer<K>,
        _ key: K,
        as type: T.Type
    ) -> T? {
        if let value = try? container.decodeIfPresent(T.self, forKey: key) { return value }
        guard let raw = try? container.decodeIfPresent(SnsJSONValue.self, forKey: key),
              JSONSerialization.isValidJSONObject(raw.foundationValue),
              let data = try? JSONSerialization.data(withJSONObject: raw.foundationValue)
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// 任意 JSON 值的降级容器（只在数组/对象单个元素损坏时用于跳过坏元素）。
private enum SnsJSONValue: Decodable {
    case object([String: SnsJSONValue])
    case array([SnsJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(String.self) {
            self = .string(value)
        } else if let value = try? single.decode([String: SnsJSONValue].self) {
            self = .object(value)
        } else if let value = try? single.decode([SnsJSONValue].self) {
            self = .array(value)
        } else if let value = try? single.decode(Double.self) {
            self = .number(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: single,
                debugDescription: "Unsupported SNS JSON value"
            )
        }
    }

    var foundationValue: Any {
        switch self {
        case .object(let value): return value.mapValues { $0.foundationValue }
        case .array(let value): return value.map { $0.foundationValue }
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        }
    }
}

// MARK: - 媒体

enum SnsMediaKind: String, Codable, CaseIterable, Hashable {
    case image
    case video

    var isVideo: Bool { self == .video }
}

/// 朋友圈媒体元数据。`thumb_key` / `url_key` 是微信 CDN key，不含真实 URL，
/// 由 `POST /sns/media` 换成本地文件（见契约 §4.4）。
struct SnsMedia: Identifiable, Codable, Hashable {
    var kind: SnsMediaKind = .image
    var thumbKey: String = ""
    var urlKey: String = ""
    var width: Int = 0
    var height: Int = 0
    /// 视频时长（秒）；图片为空。
    var durationSeconds: Int?

    var id: String { "\(kind.rawValue)|\(thumbKey)|\(urlKey)|\(width)x\(height)" }

    var aspectRatio: Double {
        guard width > 0, height > 0 else { return 1 }
        return Double(width) / Double(height)
    }
}

extension SnsMedia {
    private enum CodingKeys: String, CodingKey {
        case kind, thumbKey = "thumb_key", urlKey = "url_key"
        case width, height, durationSeconds = "duration_seconds"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = (SnsJSON.string(container, .kind) ?? "image").lowercased()
        kind = SnsMediaKind(rawValue: rawKind) ?? .image
        thumbKey = SnsJSON.string(container, .thumbKey) ?? ""
        urlKey = SnsJSON.string(container, .urlKey) ?? ""
        width = SnsJSON.int(container, .width) ?? 0
        height = SnsJSON.int(container, .height) ?? 0
        durationSeconds = SnsJSON.int(container, .durationSeconds)
    }
}

/// 媒体下载请求的变体。
enum SnsMediaVariant: String, Codable, Hashable {
    case thumb
    case full
}

/// `POST /sns/media` 响应中的文件名（`file://…` 或绝对路径）。
struct SnsMediaFile: Codable, Hashable {
    var file: String = ""

    private enum CodingKeys: String, CodingKey { case file, path }
}

extension SnsMediaFile {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        file = SnsJSON.string(container, .file) ?? SnsJSON.string(container, .path) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(file, forKey: .file)
    }
}

// MARK: - 评论 / 点赞

struct SnsComment: Identifiable, Codable, Hashable {
    var commentID: String = ""
    var userID: String = ""
    var userName: String = ""
    var text: String = ""
    var createTime: Int = 0
    /// 回复的评论 ID（空表示直接评论动态）。
    var replyTo: String = ""
    var replyToName: String = ""
    /// 被回复评论的作者 wxid（bridge reply_to_user_id）。
    ///
    /// 朋友圈 native 时间线回包几乎不含评论，机器人自己的评论经常不在列表里：
    /// 此时只靠 replyTo（父评论 ID）无法判断「这条回复是回我的」，
    /// 用被回复者 wxid 兜底（见 SnsInteractionPlanner）。
    var replyToUserID: String = ""

    /// 评论来源：native = 原生/时间线回包；db = bridge 从 sns.db 补全的评论。
    var source: String = "native"
    /// bridge 显式标记：comment_id 来自 sns.db 未经确认的 32 位列，不能当 reply_comment_id。
    var commentIDUnconfirmed: Bool = false
    /// bridge 显式标记：comment_id 已通过真机手动回复抓包确认可作 reply_comment_id
    /// （4.2.0.17 SnsMessage_tmp3.comment_id，实测 35 被服务端接受）。
    var commentIDConfirmed: Bool = false

    var id: String {
        commentID.isEmpty ? "\(userID)-\(createTime)-\(text)" : commentID
    }

    var createDate: Date { Date(timeIntervalSince1970: TimeInterval(createTime)) }

    /// 永远不把裸 wxid 展示给用户。
    var displayUserName: String {
        let trimmed = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L("微信好友") : trimmed
    }

    var isReply: Bool {
        !replyTo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 是否有可用于回复/去重的服务端评论 ID（本地回显的 `local-` 前缀不算）。
    var hasServerID: Bool {
        let trimmed = commentID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("local-")
    }

    /// 是否由指定 wxid 发表（空 wxid 永远返回 false）。
    func isAuthored(by userID: String) -> Bool {
        let target = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        return self.userID.trimmingCharacters(in: .whitespacesAndNewlines) == target
    }

    /// 是否为 bridge 从 sns.db 补全的评论（原生回包常缺评论/回复）。
    var isDatabaseCompleted: Bool {
        source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "db"
    }

    /// 是否可以作为 reply_comment_id 提交。
    ///
    /// - 必须有服务端 ID；
    /// - bridge 标记的「sns.db 32 位未确认 ID」不能用作回复目标（真机 35 语义待确认）；
    /// - 临时保护：bridge 尚未下发标记时，短数字 ID 同样按未确认处理
    ///   （真实微信 CommentId 是 uint64，位数远大于 10；标记就绪后可移除）。
    var canBeReplyTarget: Bool {
        // 真机 4.2.0.17 的原生评论 ID 就是短数字（3/35/67/99），旧「<10 位视为
        // 未确认」启发式会误拦原生回复。现在 bridge 对 DB 32 位回退行显式标记
        // comment_id_unconfirmed，只有该标记才阻止回复；其余有服务端 ID 即可。
        guard hasServerID, !commentIDUnconfirmed else { return false }
        // sns.db 补全评论必须由 bridge 显式确认（真机手动回复抓包）才可作回复目标；
        // 原生 timeline/同步评论直接信任服务端 ID（4.2.0.17 原生 ID 就是短数字）。
        if isDatabaseCompleted { return commentIDConfirmed }
        return true
    }

    /// 该评论是否在回复 `commentID`（用于判断「某条评论已被回复过」）。
    func isReply(toComment commentID: String) -> Bool {
        let target = commentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        return replyTo.trimmingCharacters(in: .whitespacesAndNewlines) == target
    }
}

extension SnsComment {
    private enum CodingKeys: String, CodingKey {
        case commentID = "comment_id", userID = "user_id", userName = "user_name"
        case text, createTime = "create_time", replyTo = "reply_to", replyToName = "reply_to_name"
        case replyToUserID = "reply_to_user_id", source
        case commentIDUnconfirmed = "comment_id_unconfirmed"
        case commentIDConfirmed = "comment_id_confirmed"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commentID = SnsJSON.string(container, .commentID) ?? ""
        userID = SnsJSON.string(container, .userID) ?? ""
        userName = SnsJSON.string(container, .userName) ?? ""
        text = SnsJSON.string(container, .text) ?? ""
        createTime = SnsJSON.int(container, .createTime) ?? 0
        replyTo = SnsJSON.string(container, .replyTo) ?? ""
        replyToName = SnsJSON.string(container, .replyToName) ?? ""
        replyToUserID = SnsJSON.string(container, .replyToUserID) ?? ""
        source = SnsJSON.string(container, .source) ?? "native"
        commentIDUnconfirmed = SnsJSON.bool(container, .commentIDUnconfirmed) ?? false
        commentIDConfirmed = SnsJSON.bool(container, .commentIDConfirmed) ?? false
    }
}

struct SnsLike: Codable, Hashable {
    var userID: String = ""
    var userName: String = ""
    var createTime: Int = 0

    var displayUserName: String {
        let trimmed = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L("微信好友") : trimmed
    }
}

extension SnsLike {
    private enum CodingKeys: String, CodingKey {
        case userID = "user_id", userName = "user_name", createTime = "create_time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userID = SnsJSON.string(container, .userID) ?? ""
        userName = SnsJSON.string(container, .userName) ?? ""
        createTime = SnsJSON.int(container, .createTime) ?? 0
    }
}

// MARK: - 动态 / 游标

/// 一条朋友圈动态。时间线与详情共用；纯文字动态 `media` 为空。
struct SnsPost: Identifiable, Codable, Hashable {
    /// uint64 十进制字符串，禁止转 Int64（契约 §5.1）。
    var id: String = ""
    var authorID: String = ""
    var authorName: String = ""
    /// 秒级 Unix 时间（微信原生字段）。
    var createTime: Int = 0
    var text: String = ""
    var media: [SnsMedia] = []
    var likeCount: Int = 0
    var commentCount: Int = 0
    var liked: Bool = false
    var comments: [SnsComment] = []
    /// 详情返回的可选点赞列表。
    var likes: [SnsLike] = []
    var commentsTruncated: Bool = false
    var textTruncated: Bool = false
    /// 本地回显/发布结果才有；时间线响应不保证返回。
    var visibility: SnsVisibility?

    var createDate: Date { Date(timeIntervalSince1970: TimeInterval(createTime)) }

    var displayAuthorName: String {
        let trimmed = authorName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L("微信好友") : trimmed
    }

    var isTextOnly: Bool { media.isEmpty }

    var effectiveCommentCount: Int { max(commentCount, comments.count) }

    /// 评论是否还有未加载的全量内容（需要 `/sns/detail` 补齐）。
    var hasMoreComments: Bool {
        commentsTruncated || effectiveCommentCount > comments.count
    }

    var mediaCount: Int { media.count }

    var imageCount: Int { media.filter { !$0.kind.isVideo }.count }

    /// 是否由指定 wxid 发布（空 wxid 永远返回 false）。
    func isAuthored(by userID: String) -> Bool {
        let target = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        return authorID.trimmingCharacters(in: .whitespacesAndNewlines) == target
    }

    /// 指定 wxid 是否已经在该动态下留过评论（含回复）。
    func hasCommentAuthored(by userID: String) -> Bool {
        let target = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        return comments.contains { $0.isAuthored(by: target) }
    }

    /// 最近一条评论的时间（Unix 秒）；没有评论返回 0。
    var latestCommentTime: Int {
        comments.map(\.createTime).max() ?? 0
    }
}

extension SnsPost {
    private enum CodingKeys: String, CodingKey {
        case id, authorID = "author_id", authorName = "author_name", createTime = "create_time"
        case text, media, likeCount = "like_count", commentCount = "comment_count"
        case liked, comments, likes
        case commentsTruncated = "comments_truncated", textTruncated = "text_truncated"
        case visibility
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SnsPost()
        id = SnsJSON.string(container, .id) ?? defaults.id
        authorID = SnsJSON.string(container, .authorID) ?? defaults.authorID
        authorName = SnsJSON.string(container, .authorName) ?? defaults.authorName
        createTime = SnsJSON.int(container, .createTime) ?? defaults.createTime
        text = SnsJSON.string(container, .text) ?? defaults.text
        media = SnsJSON.lossyArray(container, .media, as: SnsMedia.self)
        likeCount = max(0, SnsJSON.int(container, .likeCount) ?? defaults.likeCount)
        commentCount = max(0, SnsJSON.int(container, .commentCount) ?? defaults.commentCount)
        liked = SnsJSON.bool(container, .liked) ?? defaults.liked
        comments = SnsJSON.lossyArray(container, .comments, as: SnsComment.self)
        likes = SnsJSON.lossyArray(container, .likes, as: SnsLike.self)
        commentsTruncated = SnsJSON.bool(container, .commentsTruncated) ?? defaults.commentsTruncated
        textTruncated = SnsJSON.bool(container, .textTruncated) ?? defaults.textTruncated
        visibility = nil
        if let raw = SnsJSON.string(container, .visibility) {
            visibility = SnsVisibility(rawValue: raw.lowercased())
        }
    }
}

/// 时间线下一页游标；`max_id` 为 uint64 十进制字符串。
struct SnsCursor: Codable, Hashable {
    var maxID: String = ""
    var firstPageMD5: String = ""
    var session: String = ""
    /// 无更多时桥接返回 false；缺省由 App 按页大小推断。
    var hasMore: Bool?

    init() {}

    init(maxID: String, firstPageMD5: String = "", session: String = "", hasMore: Bool? = nil) {
        self.maxID = maxID
        self.firstPageMD5 = firstPageMD5
        self.session = session
        self.hasMore = hasMore
    }
}

extension SnsCursor {
    private enum CodingKeys: String, CodingKey {
        case maxID = "max_id", firstPageMD5 = "first_page_md5", session, hasMore = "has_more"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxID = SnsJSON.string(container, .maxID) ?? ""
        firstPageMD5 = SnsJSON.string(container, .firstPageMD5) ?? ""
        session = SnsJSON.string(container, .session) ?? ""
        hasMore = SnsJSON.bool(container, .hasMore)
    }
}

struct SnsServerConfig: Codable, Hashable {
    var postMentionLimit: Int = 0
    var copyPasteWordLimit: Int = 0

    private enum CodingKeys: String, CodingKey {
        case postMentionLimit = "post_mention_limit", copyPasteWordLimit = "copy_paste_word_limit"
    }
}

/// `POST /sns/timeline` 的 `data`。
struct SnsTimelinePage: Codable, Hashable {
    var posts: [SnsPost] = []
    var cursor: SnsCursor?
    var serverConfig: SnsServerConfig?
    /// 被动缓存的捕获时间（Unix 秒）；`source=native` 时为空。
    var capturedAt: Int?
    /// `native`（主动刷新回包）/ `passive`（被动缓存兜底）。自动互动只在 native 时执行，
    /// 避免把用户手动打开朋友圈时的旧缓存当成新内容去评论。
    var source: String = "native"

    init() {}

    init(
        posts: [SnsPost],
        cursor: SnsCursor? = nil,
        serverConfig: SnsServerConfig? = nil,
        capturedAt: Int? = nil,
        source: String = "native"
    ) {
        self.posts = posts
        self.cursor = cursor
        self.serverConfig = serverConfig
        self.capturedAt = capturedAt
        self.source = source
    }

    /// 是否为主动刷新返回的真实响应（而不是被动缓存兜底）。
    var isNativeSource: Bool { source.lowercased() == "native" }
}

extension SnsTimelinePage {
    private enum CodingKeys: String, CodingKey {
        case posts, cursor, serverConfig = "server_config", capturedAt = "captured_at", source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        posts = SnsJSON.lossyArray(container, .posts, as: SnsPost.self)
        cursor = SnsJSON.object(container, .cursor, as: SnsCursor.self)
        serverConfig = SnsJSON.object(container, .serverConfig, as: SnsServerConfig.self)
        capturedAt = SnsJSON.int(container, .capturedAt)
        source = SnsJSON.string(container, .source) ?? "native"
    }
}

// MARK: - 就绪状态

/// `POST /sns/status` 的 `data`。
struct SnsStatus: Codable, Hashable {
    var ready: Bool = false
    var seedReady: Bool = false
    var writeReady: Bool = false
    /// hook 已捕获评论/点赞（0xD5）闭包句柄；评论与回复的前置条件。
    /// 与 `writeReady`（发布 post 样本）独立。
    var commentReady: Bool = false
    /// bridge 已缓存最近一次手动打开朋友圈的真实响应。
    var passive: Bool = false
    /// native：可主动刷新（已捕获真实请求体）；passive：只能读原生缓存；off：关闭。
    var readMode: String = ""
    /// hook 已捕获的 SNS 任务类型数；**不等于**已拿到真实请求体（4.2.0.12 缺
    /// bodyReturn 锚点时 captured>0 但没有 body），不要单独用它判断可主动刷新。
    var captured: Int = 0
    /// timeline 的真实请求体是否已捕获（bridge `body_captured`）。nil 表示旧版
    /// bridge 未返回该字段，此时退回 `captured > 0` 的旧判定。
    var bodyCaptured: Bool?
    var account: String = ""
    var lastError: String = ""

    /// 读取时间线是否已就绪：主动发送 priming，或已有手动刷新缓存。
    var isPrimed: Bool { (ready && seedReady) || passive }

    /// 是否具备主动刷新条件（捕获过 timeline 请求体）。
    var canRefreshNatively: Bool {
        guard readMode.lowercased() == "native" else { return false }
        return bodyCaptured ?? (captured > 0)
    }

    init() {}

    init(ready: Bool, seedReady: Bool, writeReady: Bool = false, commentReady: Bool = false,
         passive: Bool = false, readMode: String = "", captured: Int = 0,
         account: String = "", lastError: String = "", bodyCaptured: Bool? = nil) {
        self.ready = ready
        self.seedReady = seedReady
        self.writeReady = writeReady
        self.commentReady = commentReady
        self.passive = passive
        self.readMode = readMode
        self.captured = captured
        self.account = account
        self.lastError = lastError
        self.bodyCaptured = bodyCaptured
    }
}

extension SnsStatus {
    private enum CodingKeys: String, CodingKey {
        case ready, seedReady = "seed_ready", writeReady = "write_ready"
        case commentReady = "comment_ready", passive
        case readMode = "read_mode", captured
        case bodyCaptured = "body_captured"
        case account, lastError = "last_error"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ready = SnsJSON.bool(container, .ready) ?? false
        seedReady = SnsJSON.bool(container, .seedReady) ?? false
        writeReady = SnsJSON.bool(container, .writeReady) ?? false
        commentReady = SnsJSON.bool(container, .commentReady) ?? false
        passive = SnsJSON.bool(container, .passive) ?? false
        readMode = SnsJSON.string(container, .readMode) ?? ""
        captured = SnsJSON.int(container, .captured) ?? 0
        bodyCaptured = SnsJSON.bool(container, .bodyCaptured)
        account = SnsJSON.string(container, .account) ?? ""
        lastError = SnsJSON.string(container, .lastError) ?? ""
    }
}

// MARK: - 同步事件（WS 与 /sns/sync 共用）

enum SnsSyncEventKind: String, Hashable {
    case newPost = "sns_new_post"
    case comment = "sns_comment"
    case like = "sns_like"
    case unknown

    init(type: String) {
        self = SnsSyncEventKind(rawValue: type.lowercased()) ?? .unknown
    }
}

/// bridge → App 的 WS 事件 / `/sns/sync` 事件（契约 §5.3）。
struct SnsSyncEvent: Identifiable, Codable, Hashable {
    var type: String = ""
    var account: String = ""
    var postID: String = ""
    var post: SnsPost?
    var comment: SnsComment?
    var userID: String = ""
    var cancelled: Bool = false
    /// `native`（CmdList 解析）/ `fallback`（时间线 diff）。
    var source: String = "native"

    // MARK: `sns_comment_hint`（cmd46 Type=11 轻量通知）
    //
    // 微信 4.2.0.17 对「好友回复了我的评论/互动」只推 From/To/ToNickname/CreateTime，
    // 没有正文和评论 ID，bridge 不伪造评论、不写缓存、也不会产生 `sns_comment`。
    // 它不能当自动互动候选，只用于「有新回复」提示 + 触发一次 timeline 刷新。

    /// 触发通知的好友 wxid。
    var fromUser: String = ""
    /// 触发通知的好友昵称（bridge 尽力解析，可为空）。
    var fromName: String = ""
    /// 通知创建时间（Unix 秒）；0 表示桥接未提供。
    var eventCreateTime: Int = 0
    /// 被回复者 wxid（可选）。
    var replyToUserID: String = ""

    var kind: SnsSyncEventKind { SnsSyncEventKind(type: type) }

    var isFallback: Bool { source.lowercased() == "fallback" }

    /// 是否为「好友回复了我」的轻量通知（无正文，不能生成互动候选）。
    var isCommentHint: Bool { type.lowercased() == "sns_comment_hint" }

    /// 事件去重键：同一批 `/sns/sync` 被重复轮询、或轮询与 WS 同时投递同一条事件时，
    /// 必须稳定且不同事件之间不能撞键（合并前按它去重，见 `MomentsStore.apply(sync:)`）。
    ///
    /// 注意 bridge 的 `sns_new_post` 事件只带 `post`（没有 `post_id`）：旧实现用
    /// `comment?.id ?? userID` 拼键，同一批里多条新动态会得到同一个 id，既让「N 条更新」
    /// 少算，也会让合并前的事件去重误删真实事件。
    var id: String {
        let postKey = postID.isEmpty ? (post?.id ?? "") : postID
        if isCommentHint {
            // hint 没有评论 ID：用（动态, 触发者, 时间, 被回复者）拼稳定键，
            // 避免同一批/重复轮询的多条 hint 撞键而漏提示或重复刷新。
            return "\(type)|\(postKey)|\(fromUser)|\(eventCreateTime)|\(replyToUserID)"
        }
        switch kind {
        case .newPost:
            return "\(type)|\(postKey)"
        case .comment:
            return "\(type)|\(postKey)|\(comment?.id ?? "")|\(comment?.createTime ?? 0)"
        case .like, .unknown:
            return "\(type)|\(postKey)|\(userID)|\(cancelled)"
        }
    }

    init() {}

    init(type: String, account: String = "", postID: String, post: SnsPost? = nil,
         comment: SnsComment? = nil, userID: String = "", cancelled: Bool = false,
         source: String = "native") {
        self.type = type
        self.account = account
        self.postID = postID
        self.post = post
        self.comment = comment
        self.userID = userID
        self.cancelled = cancelled
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case type, account, data, postID = "post_id", post, comment
        case userID = "user_id", cancelled, source
        case fromUser = "from_user", fromName = "from_name"
        case eventCreateTime = "create_time", replyToUserID = "reply_to_user_id"
    }
}

extension SnsSyncEvent {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = SnsJSON.string(container, .type) ?? ""
        account = SnsJSON.string(container, .account) ?? ""

        // WS 事件/HTTP 同步事件都是 `{type, account, data:{…}}`；同时兼容字段
        // 直接平铺在顶层的旧形态。
        if let data = try? container.nestedContainer(keyedBy: CodingKeys.self, forKey: .data) {
            postID = SnsJSON.string(data, .postID) ?? ""
            post = SnsJSON.object(data, .post, as: SnsPost.self)
            comment = SnsJSON.object(data, .comment, as: SnsComment.self)
            userID = SnsJSON.string(data, .userID) ?? ""
            cancelled = SnsJSON.bool(data, .cancelled) ?? false
            source = SnsJSON.string(data, .source) ?? "native"
            fromUser = SnsJSON.string(data, .fromUser) ?? ""
            fromName = SnsJSON.string(data, .fromName) ?? ""
            eventCreateTime = SnsJSON.int(data, .eventCreateTime) ?? 0
            replyToUserID = SnsJSON.string(data, .replyToUserID) ?? ""
        } else {
            postID = SnsJSON.string(container, .postID) ?? ""
            post = SnsJSON.object(container, .post, as: SnsPost.self)
            comment = SnsJSON.object(container, .comment, as: SnsComment.self)
            userID = SnsJSON.string(container, .userID) ?? ""
            cancelled = SnsJSON.bool(container, .cancelled) ?? false
            source = SnsJSON.string(container, .source) ?? "native"
            fromUser = SnsJSON.string(container, .fromUser) ?? ""
            fromName = SnsJSON.string(container, .fromName) ?? ""
            eventCreateTime = SnsJSON.int(container, .eventCreateTime) ?? 0
            replyToUserID = SnsJSON.string(container, .replyToUserID) ?? ""
        }
    }

    /// 平铺编码（`data` 仅用于解码 WS 包裹）；写入端目前只有 App 内部测试使用。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(account, forKey: .account)
        try container.encode(postID, forKey: .postID)
        try container.encodeIfPresent(post, forKey: .post)
        try container.encodeIfPresent(comment, forKey: .comment)
        try container.encode(userID, forKey: .userID)
        try container.encode(cancelled, forKey: .cancelled)
        try container.encode(source, forKey: .source)
        if !fromUser.isEmpty { try container.encode(fromUser, forKey: .fromUser) }
        if !fromName.isEmpty { try container.encode(fromName, forKey: .fromName) }
        if eventCreateTime != 0 { try container.encode(eventCreateTime, forKey: .eventCreateTime) }
        if !replyToUserID.isEmpty { try container.encode(replyToUserID, forKey: .replyToUserID) }
    }
}

/// `POST /sns/sync` 的响应体（`events` + 游标）。
struct SnsSyncResult: Codable, Hashable {
    var events: [SnsSyncEvent] = []
    var cursor: SnsCursor?

    init() {}

    init(events: [SnsSyncEvent], cursor: SnsCursor? = nil) {
        self.events = events
        self.cursor = cursor
    }
}

extension SnsSyncResult {
    private enum CodingKeys: String, CodingKey { case events, cursor }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        events = SnsJSON.lossyArray(container, .events, as: SnsSyncEvent.self)
        cursor = SnsJSON.object(container, .cursor, as: SnsCursor.self)
    }
}

/// `POST /sns/detail` 的 `data`。
struct SnsDetailPayload: Codable, Hashable {
    var post: SnsPost?
    /// `native` = 主动请求；`cache` = bridge 用时间线缓存兜底（评论/点赞可能不完整）。
    var source: String = "native"

    private enum CodingKeys: String, CodingKey { case post, source }
}

extension SnsDetailPayload {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        post = SnsJSON.object(container, .post, as: SnsPost.self)
        source = SnsJSON.string(container, .source) ?? "native"
    }
}

/// `/sns/detail` 的结果：`isPartial` 表示 bridge 走的是时间线缓存兜底，
/// 评论/点赞可能被截断（mac 微信 UI 不提供单条详情，被动模式下无法主动补齐）。
struct SnsDetailResult: Hashable {
    var post: SnsPost
    var source: String = "native"

    var isPartial: Bool { source.lowercased() != "native" }
}

/// `POST /sns/post` 成功回包。
struct SnsPublishResult: Codable, Hashable {
    var postID: String = ""
    var createTime: Int = 0

    private enum CodingKeys: String, CodingKey {
        case postID = "post_id", createTime = "create_time"
    }
}

extension SnsPublishResult {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        postID = SnsJSON.string(container, .postID) ?? ""
        createTime = SnsJSON.int(container, .createTime) ?? 0
    }
}

/// `POST /sns/comment` 成功回包：更新后的动态 +（bridge 能 diff 出时的）本次新评论。
///
/// `post` 可能只带计数/摘要；调用方必须与本地动态合并，不能直接覆盖。
/// `comment_id` 是 bridge 按「自己 wxid + 正文 + 写前列表」diff 出来的，用于本地回显；
/// bridge 无法确定时为空，此时 App 用本地 id 回显并等待下次详情刷新。
struct SnsCommentResult: Hashable, Decodable {
    var post: SnsPost?
    var comment: SnsComment?
    var commentID: String = ""

    init() {}

    init(post: SnsPost? = nil, comment: SnsComment? = nil, commentID: String = "") {
        self.post = post
        self.comment = comment
        self.commentID = commentID
    }

    private enum CodingKeys: String, CodingKey {
        case post, comment, commentID = "comment_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        post = SnsJSON.object(container, .post, as: SnsPost.self)
        comment = SnsJSON.object(container, .comment, as: SnsComment.self)
        commentID = SnsJSON.string(container, .commentID) ?? comment?.commentID ?? ""
    }
}

// MARK: - 本地时间线 diff

/// 在没有 `mmsnssync` 事件解码（P5）之前，用「刷新前后时间线对比」产生
/// 新动态/新评论/新点赞事件，供朋友圈页的「N 条更新」与新评论预览使用。
///
/// 事件只用于本地展示与合并计数，不写库、不上传；`source=fallback` 与契约 §5.3 一致。
enum SnsLocalDiff {
    static func events(previous: [SnsPost], incoming: [SnsPost]) -> [SnsSyncEvent] {
        // 首次加载（没有上一页）不产生「新动态」，避免把整页都算成更新。
        guard !previous.isEmpty else { return [] }
        let previousByID = Dictionary(
            previous.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var events: [SnsSyncEvent] = []
        for post in incoming where !post.id.isEmpty {
            guard let old = previousByID[post.id] else {
                events.append(SnsSyncEvent(
                    type: "sns_new_post",
                    postID: post.id,
                    post: post,
                    source: "fallback"
                ))
                continue
            }
            let knownComments = Set(old.comments.map(\.id))
            for comment in post.comments
            where !comment.id.isEmpty && !knownComments.contains(comment.id) {
                events.append(SnsSyncEvent(
                    type: "sns_comment",
                    postID: post.id,
                    comment: comment,
                    source: "fallback"
                ))
            }
            let delta = post.likeCount - old.likeCount
            if delta > 0 {
                // 时间线不返回点赞人 ID；用合成 userID 让每条事件 id 唯一，
                // 合并时只累加 likeCount（不会伪装成自己点的赞）。
                for index in 0..<min(delta, 50) {
                    events.append(SnsSyncEvent(
                        type: "sns_like",
                        postID: post.id,
                        userID: "local-\(post.id)-\(old.likeCount + index)",
                        source: "fallback"
                    ))
                }
            }
        }
        return events
    }
}

// MARK: - 排序 / 合并

enum SnsPostOrdering {
    /// 时间线排序：创建时间倒序；同一秒内用 uint64 字符串的数值大小倒序。
    static func isNewer(_ lhs: SnsPost, than rhs: SnsPost) -> Bool {
        if lhs.createTime != rhs.createTime { return lhs.createTime > rhs.createTime }
        return compareID(lhs.id, rhs.id) > 0
    }

    /// uint64 十进制字符串比较（避免转 Int64 溢出）；非数字按字典序兜底。
    static func compareID(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.drop(while: { $0 == "0" })
        let right = rhs.drop(while: { $0 == "0" })
        let leftIsNumber = !left.isEmpty && left.allSatisfy(\.isNumber)
        let rightIsNumber = !right.isEmpty && right.allSatisfy(\.isNumber)
        if leftIsNumber, rightIsNumber {
            if left.count != right.count { return left.count > right.count ? 1 : -1 }
            if left == right { return 0 }
            return left > right ? 1 : -1
        }
        if lhs == rhs { return 0 }
        return lhs > rhs ? 1 : -1
    }

    /// 去重（按 id，后出现的覆盖先出现的）并排序。
    static func normalized(_ posts: [SnsPost]) -> [SnsPost] {
        var byID: [String: SnsPost] = [:]
        var orderedIDs: [String] = []
        for post in posts {
            let id = post.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            var post = post
            post.id = id
            if byID[id] == nil {
                orderedIDs.append(id)
            } else if let existing = byID[id] {
                // 合并时保留详情/后到版本里更完整的一侧。
                post = mergeDuplicate(existing: existing, incoming: post)
            }
            byID[id] = post
        }
        return orderedIDs
            .compactMap { byID[$0] }
            .sorted(by: isNewer)
    }

    static func mergeDuplicate(existing: SnsPost, incoming: SnsPost) -> SnsPost {
        var merged = incoming
        if merged.comments.isEmpty, !existing.comments.isEmpty { merged.comments = existing.comments }
        if merged.media.isEmpty, !existing.media.isEmpty { merged.media = existing.media }
        if merged.text.isEmpty { merged.text = existing.text }
        if merged.authorName.isEmpty { merged.authorName = existing.authorName }
        if merged.authorID.isEmpty { merged.authorID = existing.authorID }
        if merged.createTime == 0 { merged.createTime = existing.createTime }
        if merged.likes.isEmpty, !existing.likes.isEmpty { merged.likes = existing.likes }
        merged.likeCount = max(merged.likeCount, existing.likeCount)
        merged.commentCount = max(merged.commentCount, existing.commentCount, merged.comments.count)
        merged.liked = merged.liked || existing.liked
        merged.commentsTruncated = merged.commentsTruncated || existing.commentsTruncated
        merged.visibility = merged.visibility ?? existing.visibility
        return merged
    }
}

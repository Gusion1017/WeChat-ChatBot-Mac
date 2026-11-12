import Foundation

/// 通道温度的范围、步长与格式化。请求侧由 `AIProvider.requestTemperature`
/// clamp 后交给 `AIClient.requestBody`；编辑器与列表共用同一组常量。
enum ModelTemperature {
    /// 温度合法范围；必须与 `AIProvider.requestTemperature` 和
    /// `AIClient.requestBody(...)` 的 clamp 一致（0–2），不要写更宽范围。
    static let range: ClosedRange<Double> = 0...2
    /// 滑块步长。
    static let step: Double = 0.1
    /// 首次启用自定义温度时的起始值（沿用旧版默认）。
    static let initialValue: Double = 0.7

    static func clamp(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// 按 0.1 对齐，避免浮点误差让「没动过的 0.7」被当成修改。
    static func rounded(_ value: Double) -> Double {
        clamp((clamp(value) * 10).rounded() / 10)
    }

    /// 列表/摘要中的一位小数展示。
    static func display(_ value: Double) -> String {
        String(format: "%.1f", rounded(value))
    }
}

/// 新建通道的类型白名单。
///
/// 产品上只新增 DeepSeek 与自定义兼容通道；OpenAI/Ollama 保留为历史类型，
/// 已存在的旧通道仍可编辑，但新通道不再提供这两个选项。
enum AIProviderKindSelection {
    static let creatable: [ProviderKind] = [.deepSeek, .custom]

    /// 新通道只列出可创建类型；编辑历史通道时把当前类型放在首位，避免 Picker 选中值不存在。
    static func options(current: ProviderKind) -> [ProviderKind] {
        var seen = Set<ProviderKind>()
        return ([current] + creatable).filter { seen.insert($0).inserted }
    }

    static func isCreatable(_ kind: ProviderKind) -> Bool {
        creatable.contains(kind)
    }

    static func isLegacy(_ kind: ProviderKind) -> Bool {
        !isCreatable(kind)
    }
}

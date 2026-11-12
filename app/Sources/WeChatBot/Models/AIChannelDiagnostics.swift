import Foundation

/// 默认通道的健康状态分类（纯逻辑，便于单测与 UI 复用）。
///
/// 默认通道停用或缺少凭据时，自动回复会静默失败；AI 模型页需要同时给出
/// 原因和可执行操作（启用 / 编辑），而不是只显示一行警告。
struct DefaultChannelDiagnosis: Equatable {
    /// 通道被用户停用，自动回复不会使用它。
    let isDisabled: Bool
    /// 通道缺少发起请求所需的凭据（Ollama/自定义允许无密钥）。
    let hasCredential: Bool

    var isUsable: Bool { !isDisabled && hasCredential }

    /// 需要「启用通道」操作。
    var needsEnable: Bool { isDisabled }

    /// 需要「编辑通道」补密钥操作。
    var needsCredential: Bool { !hasCredential }

    static func evaluate(provider: AIProvider) -> DefaultChannelDiagnosis {
        DefaultChannelDiagnosis(
            isDisabled: !provider.enabled,
            hasCredential: provider.hasUsableCredential
        )
    }
}

/// 通道连接测试的世代号。
///
/// 编辑并保存（或删除）通道后，旧测试结果不再对应当前配置：必须清掉列表里的
/// 「连接正常/连接失败」，同时丢弃仍在途的旧请求结果，避免它稍后覆盖新状态。
struct ProviderTestTracker: Equatable {
    private(set) var generations: [String: Int] = [:]

    /// 开始一次测试并返回本次测试的世代号。
    mutating func begin(_ providerID: String) -> Int {
        let next = (generations[providerID] ?? 0) + 1
        generations[providerID] = next
        return next
    }

    /// 让该通道所有在途测试的结果失效（编辑保存、删除通道时调用）。
    mutating func invalidate(_ providerID: String) {
        generations[providerID] = (generations[providerID] ?? 0) + 1
    }

    /// 本次测试是否仍然对应当前配置；false 表示结果应被丢弃。
    func isCurrent(_ generation: Int, for providerID: String) -> Bool {
        (generations[providerID] ?? 0) == generation
    }
}

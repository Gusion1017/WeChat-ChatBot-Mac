import Foundation

// MARK: - Paths

/// 应用文件路径。
///
/// - 全局（不随微信账号切换）：`config.json`、Keychain、bridge 日志、备份、运行期文件；
/// - 账号级（随微信账号切换）：`accounts/<id>/` 下的 `profile.json`、SQLite、媒体与日志。
///
/// 账号级路径全部委托给 `AccountProfile`（见 docs/accounts.md、实施契约 §2.3）。
/// 所有属性都是**纯计算**（只读路径、无副作用），因为 `AppPaths` 也会被
/// `SettingsPersistence` 等后台 actor 读取；`AccountProfile` 内部自行加锁。
enum AppPaths {
    static let appName = "WeChatAI"
    static let bundleID = "com.gusionw.wechatai"

    /// 测试专用覆盖：非 nil 时所有 Application Support 路径改到这个根目录。
    ///
    /// 单测（如音色库 CRUD）必须写临时目录：直接写用户的真实
    /// `~/Library/Application Support/WeChatAI` 既会污染用户数据，在受限沙箱/CI
    /// 里还会因权限不足直接失败（CoreAudio 报 -54）。
    nonisolated(unsafe) static var supportDirectoryOverride: URL?

    static var supportDirectory: URL {
        if let override = supportDirectoryOverride {
            return override
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    /// 全局设置：完整 `AppSettings` 镜像（兼容旧版回滚），不随账号切换。
    static var configFile: URL { supportDirectory.appendingPathComponent("config.json") }

    // MARK: 账号级（委托 AccountProfile，随微信账号切换）

    /// 当前账号的账号级设置（bot / personas / schedules）。
    static var profileFile: URL { AccountProfile.profileFile }
    /// 当前账号的记忆数据库。
    static var databaseFile: URL { AccountProfile.databaseFile }
    /// 当前账号的新媒体目录（入站图片/语音、TTS 输出）。
    static var mediaDirectory: URL { AccountProfile.mediaDirectory }
    /// 当前账号的日志目录。
    static var logsDirectory: URL { AccountProfile.logsDirectory }
    /// 当前账号的角色目录（每会话记忆卡，记忆 v2；人格来自人格设定）。
    static var charactersDirectory: URL { AccountProfile.charactersDirectory }
    /// 所有账号目录的父目录（`accounts/`）。
    static var accountsDirectory: URL { AccountProfile.layout.accountsDirectory }
    /// 当前账号目录（`accounts/<id>/`）。
    static var accountDirectory: URL { AccountProfile.activeDirectory }
    /// 当前账号状态（`accounts/../account-state.json`）。
    static var accountStateFile: URL { AccountProfile.layout.stateFile }
    /// 旧版单库（迁移后保留，只读回退用）。
    static var legacyDatabaseFile: URL { AccountProfile.layout.legacyDatabaseFile }
    /// 旧版遗留媒体目录（只读保留；旧消息里的绝对路径仍可读，不迁移、不删除、不主动创建）。
    static var legacyMediaDirectory: URL { AccountProfile.layout.legacyMediaDirectory }

    // MARK: 全局

    /// bridge 日志必须写在 app bundle 之外：写入 `Contents/Resources/bridge/log`
    /// 会破坏 ad-hoc 签名，导致下次启动被 macOS 以 Launch Constraint Violation 杀掉。
    /// 与 CrashReporter 的崩溃/面包屑保持同一目录（`~/Library/Logs/WeChatAI`）。
    static var bridgeLogDirectory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return library.appendingPathComponent("Logs/WeChatAI/bridge", isDirectory: true)
    }
    static var bridgeLogFile: URL { bridgeLogDirectory.appendingPathComponent("macos.log") }
    static var backupsDirectory: URL { supportDirectory.appendingPathComponent("backups", isDirectory: true) }
    /// 运行期生成的 Hook 配置（含 4.1.15.55 / 4.2.0.x R3 发送开关），不写仓库资源。
    static var runtimeDirectory: URL { supportDirectory.appendingPathComponent("runtime", isDirectory: true) }

    /// 创建全局目录 + 当前账号目录。
    ///
    /// 旧版根目录 `media/` 不再创建（旧媒体只读保留）；新媒体的账号目录由
    /// `AccountProfile` 的当前账号决定（含 `media/` 与 `logs/`）。
    static func ensureDirectories() {
        let urls = [
            supportDirectory,
            accountsDirectory,
            accountDirectory,
            mediaDirectory,
            logsDirectory,
            charactersDirectory,
            bridgeLogDirectory,
            backupsDirectory,
            runtimeDirectory,
        ]
        for url in urls {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

// MARK: - Settings sections

enum AppearanceMode: String, Codable, CaseIterable, Hashable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: L("跟随系统")
        case .light: L("浅色")
        case .dark: L("深色")
        }
    }
}

enum SleepPreventionMode: String, Codable, CaseIterable, Hashable, Identifiable {
    /// 允许系统按节能设置进入空闲睡眠。
    case never
    /// 仅在接入电源适配器时阻止空闲睡眠；使用电池时允许睡眠。
    case externalPowerOnly
    /// 即使使用电池也阻止空闲睡眠。
    case always

    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: L("永不")
        case .externalPowerOnly: L("接入电源时")
        case .always: L("始终")
        }
    }

    var detail: String {
        switch self {
        case .never: L("不阻止系统空闲睡眠。")
        case .externalPowerOnly: L("仅接入电源时阻止空闲睡眠；使用电池时不阻止。")
        case .always: L("电池供电时也阻止空闲睡眠。")
        }
    }
}

struct GeneralSettings: Codable, Hashable {
    var appearance: AppearanceMode = .system
    /// 登录项偏好镜像。真实状态以 LaunchAtLoginService 为准；关闭开关/系统登录项变化后
    /// Settings 页会把这里同步成实际值。
    var launchAtLogin: Bool = false
    var confirmBeforeQuit: Bool = true
    var language: String = "system"
    var sleepPrevention: SleepPreventionMode = .never
}

// Custom Codable so config files written by older versions (which lack newer keys
// such as `sleepPrevention`) keep loading instead of failing the whole settings file.
// The implementation lives in an extension to preserve the synthesized memberwise init.
//
// `showInMenuBar` / `showDockIcon` were removed when the app became a pure menu-bar
// agent whose Dock icon follows the main window. Older config files still contain
// those keys; unknown keys are ignored by `decodeIfPresent`, and `encode` no longer
// writes them.
extension GeneralSettings {
    private enum CodingKeys: String, CodingKey {
        case appearance
        case launchAtLogin
        case confirmBeforeQuit
        case language
        case sleepPrevention
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GeneralSettings()

        // Enums are decoded through their raw value so an unknown value falls back to
        // the default instead of throwing and discarding the user's whole config.
        let appearanceRaw = try container.decodeIfPresent(String.self, forKey: .appearance)
        appearance = appearanceRaw.flatMap { AppearanceMode(rawValue: $0) } ?? defaults.appearance
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        confirmBeforeQuit = try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeQuit)
            ?? defaults.confirmBeforeQuit
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? defaults.language

        let sleepRaw = try container.decodeIfPresent(String.self, forKey: .sleepPrevention)
        sleepPrevention = sleepRaw.flatMap { SleepPreventionMode(rawValue: $0) } ?? defaults.sleepPrevention
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(appearance.rawValue, forKey: .appearance)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(confirmBeforeQuit, forKey: .confirmBeforeQuit)
        try container.encode(language, forKey: .language)
        try container.encode(sleepPrevention.rawValue, forKey: .sleepPrevention)
    }
}

struct HookSettings: Codable, Hashable {
    var wechatPath: String = "/Applications/WeChat.app"
    var gadgetPort: Int = 27042
    var autoStartBridge: Bool = true
    var versionConfigPath: String = ""
    var lastBackupPath: String = ""
    var didInstallGadget: Bool = false
    /// 4.1.15.55 / 4.2.0.x 使用 R3 原生文本发送（由 App 设置开启）。
    /// 首次使用前需在本机微信手动发送一条消息以捕获发送句柄。
    var enableNativeSend: Bool = true

    private enum CodingKeys: String, CodingKey {
        case wechatPath, gadgetPort, autoStartBridge
        case versionConfigPath, lastBackupPath, didInstallGadget, enableNativeSend
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = HookSettings()
        wechatPath = try container.decodeIfPresent(String.self, forKey: .wechatPath) ?? defaults.wechatPath
        gadgetPort = try container.decodeIfPresent(Int.self, forKey: .gadgetPort) ?? defaults.gadgetPort
        autoStartBridge = try container.decodeIfPresent(Bool.self, forKey: .autoStartBridge) ?? defaults.autoStartBridge
        versionConfigPath = try container.decodeIfPresent(String.self, forKey: .versionConfigPath) ?? defaults.versionConfigPath
        lastBackupPath = try container.decodeIfPresent(String.self, forKey: .lastBackupPath) ?? defaults.lastBackupPath
        didInstallGadget = try container.decodeIfPresent(Bool.self, forKey: .didInstallGadget) ?? defaults.didInstallGadget
        enableNativeSend = try container.decodeIfPresent(Bool.self, forKey: .enableNativeSend) ?? defaults.enableNativeSend
    }
}

struct OneBotSettings: Codable, Hashable {
    var host: String = "127.0.0.1"
    var port: Int = 58080
    /// OneBot HTTP 鉴权 Token。默认留空：首次启动机器人时由 App 生成随机值并持久化，
    /// 避免所有部署共用公开的固定默认值。本地 Mock 可手动填 `wechatai-local-token`。
    var token: String = ""
    /// 旧版自定义 bridge/连接类型：运行期固定使用内置 bridge + WebSocket，字段已移除；
    /// 旧配置中的同名键按未知键忽略。
    var imagePath: String = ""
}

extension OneBotSettings {
    private enum CodingKeys: String, CodingKey {
        case host, port, token, imagePath
    }

    /// 逐键解码：旧配置缺 `imagePath` 时不能整段回退，
    /// 否则随机生成的 OneBot token 会被重置，外部 bridge 直接连不上。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = OneBotSettings()
        host = (try? container.decodeIfPresent(String.self, forKey: .host)) ?? defaults.host
        port = (try? container.decodeIfPresent(Int.self, forKey: .port)) ?? defaults.port
        token = (try? container.decodeIfPresent(String.self, forKey: .token)) ?? defaults.token
        imagePath = (try? container.decodeIfPresent(String.self, forKey: .imagePath))
            ?? defaults.imagePath
    }
}

/// 识图（视觉）模型设置（2026-10-23 新增）。
///
/// 图片本身不直接进入回复模型上下文：收到图片后先用这里的通道/模型生成一段
/// 文字描述，描述随 `ChatMessage.imageDescription` 落库，再作为普通文本参与
/// 提示词组装。旧 `config.json` 没有 `vision` 键时按「未配置」处理，默认关闭，
/// 不改变既有回复行为。
struct VisionSettings: Codable, Hashable {
    /// 识图提示词默认值；模型只需要输出画面内容，不参与聊天人格。
    static let defaultPrompt = "请用简洁的中文描述这张图片：画面主体、人物与动作、图片里的文字，"
        + "以及可能影响聊天回复的关键信息。只输出描述本身，不要客套或解释，不超过 120 字。"

    /// 是否启用识图。
    var enabled: Bool = false
    /// 识图通道 ID；nil 表示跟随「默认通道」。
    var providerID: String?
    /// 识图模型名；空字符串表示跟随所选通道自己的模型。
    var model: String = ""
    /// 识图提示词；空字符串使用 `defaultPrompt`。
    var prompt: String = VisionSettings.defaultPrompt

    /// 有效模型覆盖；空字符串/空白视为「跟随通道」。
    var modelOverride: String? {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// 有效提示词；空白回退到默认提示词。
    var promptText: String {
        let value = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? Self.defaultPrompt : value
    }
}

struct AISettings: Codable, Hashable {
    var defaultProviderID: String?
    /// 流式总开关：关闭时所有通道都等待完整回复；开启时由各通道自己的 `stream` 决定。
    var streamReplies: Bool = true
    /// 失败后的**额外**重试次数（0 = 不重试），实际最多请求 `retryCount + 1` 次。
    var retryCount: Int = 1
    /// 旧版“按模型温度”表：仅用于迁移到各通道的 `temperatureOverride` 与旧版本回滚；
    /// 新版本请求不再读取它。`nil` 表示旧配置尚未迁移（或新安装）。
    var modelTemperatures: [String: Double]?
    /// 是否已完成「按模型温度 → 按通道温度」迁移。避免旧表在每次启动时重复覆盖通道配置。
    var temperaturesMovedToChannels: Bool = false
    /// 识图模型设置；nil 表示未配置（旧配置/默认关闭）。
    var vision: VisionSettings?

    /// 旧版按模型温度查询（迁移/回滚兼容）；新请求请读 `AIProvider.requestTemperature`。
    /// 未配置返回 `nil`（模型默认）。
    func temperature(forModel model: String) -> Double? {
        let key = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let value = modelTemperatures?[key] else { return nil }
        return min(max(value, 0), 2)
    }

    /// 旧版按通道温度 → 按模型温度（v1.3 迁移表）。
    ///
    /// 旧字段默认值 `AIProvider.legacyDefaultTemperature`（0.7）不代表用户主动选择：
    /// 一律视为「未配置」，让模型使用自身默认温度。只有真正改过（≠ 0.7）的值才迁移；
    /// 同一模型被多个通道使用且值不同时保留第一个（与请求实际使用的通道顺序一致）。
    static func migratedLegacyTemperatures(providers: [AIProvider]) -> [String: Double]? {
        var seeded: [String: Double] = [:]
        for provider in providers {
            let model = AIClient.effectiveModel(for: provider)
            guard !model.isEmpty, seeded[model] == nil else { continue }
            let value = min(max(provider.temperature, 0), 2)
            guard abs(value - AIProvider.legacyDefaultTemperature) > 0.0001 else { continue }
            seeded[model] = value
        }
        return seeded.isEmpty ? nil : seeded
    }

    /// v1.4 迁移：把旧「按模型温度」表（或更早的按通道温度）迁移到各通道的
    /// `temperatureOverride`。迁移后旧表只保留用于回滚，不再影响请求。
    ///
    /// - 新字段已有值时不覆盖（显式配置优先）；
    /// - 多个通道共用同一模型时，各自拿到同一温度，后续可独立修改；
    /// - 只在 `temperaturesMovedToChannels == false` 时执行一次。
    @discardableResult
    static func migrateTemperaturesToChannels(
        _ settings: inout AISettings,
        providers: inout [AIProvider]
    ) -> Bool {
        guard !settings.temperaturesMovedToChannels else { return false }
        let legacyMap = settings.modelTemperatures ?? migratedLegacyTemperatures(providers: providers)
        if let legacyMap {
            for index in providers.indices {
                let model = AIClient.effectiveModel(for: providers[index])
                guard !model.isEmpty,
                      providers[index].temperatureOverride == nil,
                      let value = legacyMap[model]
                else { continue }
                providers[index].temperatureOverride = min(max(value, 0), 2)
            }
        }
        settings.temperaturesMovedToChannels = true
        return true
    }
}

extension AISettings {
    private enum CodingKeys: String, CodingKey {
        case defaultProviderID, streamReplies, retryCount
        case modelTemperatures, temperaturesMovedToChannels, vision
    }

    /// 旧 `config.json` 没有 `streamReplies` / `retryCount` / `vision` 时只回退这些
    /// 字段的默认值，不让整份 `AppSettings` 解码失败（那会连 onebot token 一起重置）。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AISettings()
        defaultProviderID = try? container.decodeIfPresent(String.self, forKey: .defaultProviderID)
        streamReplies = (try? container.decodeIfPresent(Bool.self, forKey: .streamReplies))
            ?? defaults.streamReplies
        retryCount = (try? container.decodeIfPresent(Int.self, forKey: .retryCount))
            ?? defaults.retryCount
        modelTemperatures = try? container.decodeIfPresent(
            [String: Double].self, forKey: .modelTemperatures)
        temperaturesMovedToChannels = (try? container.decodeIfPresent(
            Bool.self, forKey: .temperaturesMovedToChannels)) ?? defaults.temperaturesMovedToChannels
        vision = try? container.decodeIfPresent(VisionSettings.self, forKey: .vision)
    }
}

/// 应用内更新（GitHub Releases）的全局设置。
///
/// 只保存「是否自动检查 / 上次检查时间 / 跳过与已提示的 tag」；下载与安装过程
/// 全部是运行期状态，不落盘。旧 `config.json` 没有 `updates` 键时整段回退默认值。
struct UpdateSettings: Codable, Hashable {
    /// 启动后自动检查更新（受 `UpdateCheckPolicy.autoCheckInterval` 节流）。
    var autoCheck: Bool = true
    /// 上次成功检查 GitHub Releases 的时间（自动检查据此节流）。
    var lastCheckedAt: Date?
    /// 用户主动「跳过此版本」的 tag；空字符串 = 不跳过。
    var skippedTag: String = ""
    /// 已在界面/通知里提示过的 tag，避免每次启动重复提示。
    var lastNotifiedTag: String = ""
}

extension UpdateSettings {
    private enum CodingKeys: String, CodingKey {
        case autoCheck, lastCheckedAt, skippedTag, lastNotifiedTag
    }

    /// 逐键解码：段内缺键或类型损坏时只回退该字段，不让整份 `config.json` 失效。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = UpdateSettings()
        autoCheck = (try? container.decodeIfPresent(Bool.self, forKey: .autoCheck)) ?? defaults.autoCheck
        lastCheckedAt = try? container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        skippedTag = (try? container.decodeIfPresent(String.self, forKey: .skippedTag)) ?? defaults.skippedTag
        lastNotifiedTag = (try? container.decodeIfPresent(String.self, forKey: .lastNotifiedTag))
            ?? defaults.lastNotifiedTag
    }
}

// MARK: - Full persisted state

struct AppSettings: Codable, Hashable {
    var schemaVersion: Int = 1
    var general = GeneralSettings()
    var hook = HookSettings()
    var onebot = OneBotSettings()
    var ai = AISettings()
    var bot = BotSettings()
    /// 应用内更新设置（全局，不随微信账号切换）。
    var updates = UpdateSettings()

    var providers: [AIProvider] = [AppSettings.makeDefaultProvider()]
    var personas: [Persona] = [AppSettings.makeDefaultPersona()]
    var schedules: [ScheduledTask] = []

    static func makeDefaultProvider() -> AIProvider {
        AIProvider(
            id: "provider-deepseek-default",
            name: "DeepSeek",
            kind: .deepSeek,
            baseURL: ProviderKind.deepSeek.defaultBaseURL,
            model: ProviderKind.deepSeek.defaultModel,
            apiKeyReference: "provider-deepseek-default",
            temperature: 0.7,
            maxTokens: 800,
            timeoutSeconds: 60,
            stream: true,
            enabled: true,
            isDefault: true
        )
    }

    static func makeDefaultPersona() -> Persona {
        Persona(
            id: "persona-default",
            name: "默认助手",
            summary: "自然、简洁、像真人聊天",
            systemPrompt: Persona.defaultSystemPrompt,
            isDefault: true
        )
    }

    static var `default`: AppSettings {
        var settings = AppSettings()
        settings.ai.defaultProviderID = settings.providers.first?.id
        settings.bot.defaultProviderID = settings.providers.first?.id
        settings.bot.defaultPersonaID = settings.personas.first?.id
        return settings
    }

    var defaultProvider: AIProvider? {
        if let id = ai.defaultProviderID, let p = providers.first(where: { $0.id == id }) { return p }
        return providers.first(where: \.isDefault) ?? providers.first
    }

    func provider(id: String?) -> AIProvider? {
        guard let id else { return defaultProvider }
        return providers.first(where: { $0.id == id }) ?? defaultProvider
    }

    /// 识图总开关：未配置 `vision` 视为关闭（旧配置行为不变）。
    var isVisionEnabled: Bool { ai.vision?.enabled == true }

    /// 识图通道：显式选择的通道存在时用它，否则回退到默认通道。
    var visionProvider: AIProvider? {
        if let id = ai.vision?.providerID,
           let provider = providers.first(where: { $0.id == id }) {
            return provider
        }
        return defaultProvider
    }

    /// 识图实际使用的模型名：设置里的覆盖值优先，否则跟随通道模型。
    func visionModel(for provider: AIProvider) -> String {
        ai.vision?.modelOverride ?? AIClient.effectiveModel(for: provider)
    }

    /// 识图请求使用的通道副本：模型换成识图模型，并用更短的超时/更小的输出上限，
    /// 避免识图失败把一次自动回复拖到 60 秒。非流式（只需要最终描述）。
    func visionRequestProvider(from provider: AIProvider) -> AIProvider {
        var copy = provider
        copy.model = visionModel(for: provider)
        copy.timeoutSeconds = min(max(provider.timeoutSeconds, 5), Self.visionTimeoutSeconds)
        copy.maxTokens = min(max(provider.maxTokens, 64), Self.visionMaxTokens)
        copy.stream = false
        return copy
    }

    /// 识图请求的最短/最长等待时间（秒）与输出上限。
    /// DeepSeek `deepseek-flash` 默认开启思考模式；识图请求会显式关闭（见
    /// `VisionSupport.thinkingMode`），因此 800 tokens 足够输出短描述。
    static let visionTimeoutSeconds: Double = 30
    static let visionMaxTokens: Int = 800

    func persona(id: String?) -> Persona? {
        if let id, let p = personas.first(where: { $0.id == id }) { return p }
        return personas.first(where: \.isDefault) ?? personas.first
    }
}

// MARK: - Account-level settings (profile.json)

/// 账号级设置：随微信账号切换，单独持久化到 `accounts/<id>/profile.json`。
///
/// `config.json` 仍然保存完整 `AppSettings` 镜像（兼容旧版回滚与迁移），但加载时
/// 以当前账号的 `profile.json` 覆盖 `bot / personas / schedules`；全局字段
/// （general / hook / onebot / ai / providers）只存在于 `config.json`。
struct ProfileSettings: Codable, Hashable {
    /// `profile.json` 的结构版本，与 `AppSettings.schemaVersion` 相互独立（当前都为 1）。
    var schemaVersion: Int = 1
    var bot = BotSettings()
    var personas: [Persona] = [AppSettings.makeDefaultPersona()]
    var schedules: [ScheduledTask] = []

    static var `default`: ProfileSettings { ProfileSettings() }
}

// 自定义解码：旧版/部分写入/手改的 profile.json 缺某个键时只回退该键的默认值，
// 不丢弃整份文件。实现放在 extension 里以保留合成的 memberwise init。
extension ProfileSettings {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, bot, personas, schedules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ProfileSettings()
        schemaVersion = (try? container.decodeIfPresent(Int.self, forKey: .schemaVersion))
            ?? defaults.schemaVersion
        bot = (try? container.decodeIfPresent(BotSettings.self, forKey: .bot)) ?? defaults.bot
        personas = (try? container.decodeIfPresent([Persona].self, forKey: .personas))
            ?? defaults.personas
        schedules = (try? container.decodeIfPresent([ScheduledTask].self, forKey: .schedules))
            ?? defaults.schedules
    }
}

// 自定义解码：顶层新增 `updates` 段后，旧 `config.json` 缺键不能让整份设置解码失败。
// 逐段读取并在单段损坏时只回退该段，和 `SettingsStore.decodeSectionsLossily` 的降级策略一致。
// 实现放在 extension 里以保留合成的 memberwise init。
extension AppSettings {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, general, hook, onebot, ai, bot, updates
        case providers, personas, schedules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        schemaVersion = (try? container.decodeIfPresent(Int.self, forKey: .schemaVersion))
            ?? defaults.schemaVersion
        general = (try? container.decodeIfPresent(GeneralSettings.self, forKey: .general))
            ?? defaults.general
        hook = (try? container.decodeIfPresent(HookSettings.self, forKey: .hook)) ?? defaults.hook
        onebot = (try? container.decodeIfPresent(OneBotSettings.self, forKey: .onebot))
            ?? defaults.onebot
        ai = (try? container.decodeIfPresent(AISettings.self, forKey: .ai)) ?? defaults.ai
        bot = (try? container.decodeIfPresent(BotSettings.self, forKey: .bot)) ?? defaults.bot
        updates = (try? container.decodeIfPresent(UpdateSettings.self, forKey: .updates))
            ?? defaults.updates
        providers = (try? container.decodeIfPresent([AIProvider].self, forKey: .providers))
            ?? defaults.providers
        personas = (try? container.decodeIfPresent([Persona].self, forKey: .personas))
            ?? defaults.personas
        schedules = (try? container.decodeIfPresent([ScheduledTask].self, forKey: .schedules))
            ?? defaults.schedules
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(general, forKey: .general)
        try container.encode(hook, forKey: .hook)
        try container.encode(onebot, forKey: .onebot)
        try container.encode(ai, forKey: .ai)
        try container.encode(bot, forKey: .bot)
        try container.encode(updates, forKey: .updates)
        try container.encode(providers, forKey: .providers)
        try container.encode(personas, forKey: .personas)
        try container.encode(schedules, forKey: .schedules)
    }
}

extension AppSettings {
    /// 从完整设置中抽出账号级部分（用于写 `profile.json`）。
    var profile: ProfileSettings {
        get {
            // profile 结构版本独立于 AppSettings.schemaVersion，固定 1；
            // 全局 schema 升级不应连带把账号 profile 的版本号抬高。
            ProfileSettings(schemaVersion: 1, bot: bot, personas: personas, schedules: schedules)
        }
        set { applyProfile(newValue) }
    }

    /// 用账号级设置覆盖 `bot / personas / schedules`，其余全局字段保持不变。
    mutating func applyProfile(_ profile: ProfileSettings) {
        bot = profile.bot
        personas = profile.personas
        schedules = profile.schedules
    }
}

// MARK: - Load / save

/// 一次配置加载的降级诊断。损坏文件会先备份再回退，这里记录备份路径供 UI 提示。
struct SettingsLoadDiagnostics: Sendable, Equatable {
    var corruptedConfigBackup: URL?
    var corruptedProfileBackup: URL?

    var hasCorruption: Bool {
        corruptedConfigBackup != nil || corruptedProfileBackup != nil
    }

    static let none = SettingsLoadDiagnostics()
}

struct SettingsLoadResult: Sendable {
    var settings: AppSettings
    var diagnostics: SettingsLoadDiagnostics = .none
    var isDegraded: Bool { diagnostics.hasCorruption }
}

enum SettingsStore {
    /// 应用默认加载：全局 `config.json` + 当前账号 `profile.json`。
    static func load() -> AppSettings {
        AppPaths.ensureDirectories()
        return load(configURL: AppPaths.configFile, profileURL: AppPaths.profileFile)
    }

    /// 可注入加载（测试用）：先读全局 config，再用账号 profile 覆盖账号字段。
    /// `profileURL == nil` 时只读 config（旧版行为，profile 不存在也走这里）。
    static func load(configURL: URL, profileURL: URL?) -> AppSettings {
        loadWithDiagnostics(configURL: configURL, profileURL: profileURL).settings
    }

    /// 与 `load` 相同，但返回损坏文件的备份路径；调用方可据此拒绝覆盖用户配置并提示。
    static func loadWithDiagnostics(configURL: URL, profileURL: URL?) -> SettingsLoadResult {
        var diagnostics = SettingsLoadDiagnostics()
        var settings = loadConfig(configURL: configURL, diagnostics: &diagnostics)
        if let profileURL {
            settings.applyProfile(
                loadProfile(profileURL: profileURL, diagnostics: &diagnostics)
            )
        }
        return SettingsLoadResult(settings: settings, diagnostics: diagnostics)
    }

    /// 读取账号级 profile：缺失 → `.default`；损坏 → 备份 `profile.corrupt-<ts>.json` 后 `.default`。
    static func loadProfile(profileURL: URL) -> ProfileSettings {
        var diagnostics = SettingsLoadDiagnostics()
        return loadProfile(profileURL: profileURL, diagnostics: &diagnostics)
    }

    private static func loadProfile(
        profileURL: URL,
        diagnostics: inout SettingsLoadDiagnostics
    ) -> ProfileSettings {
        guard let data = try? Data(contentsOf: profileURL) else { return .default }
        do {
            return try JSONDecoder().decode(ProfileSettings.self, from: data)
        } catch {
            NSLog("[WeChatAI] profile decode failed: \(error)")
            let backup = profileURL.deletingLastPathComponent()
                .appendingPathComponent("profile.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: profileURL, to: backup)
            if FileManager.default.fileExists(atPath: backup.path) {
                diagnostics.corruptedProfileBackup = backup
            }
            return .default
        }
    }

    private static func loadConfig(
        configURL: URL,
        diagnostics: inout SettingsLoadDiagnostics
    ) -> AppSettings {
        guard let data = try? Data(contentsOf: configURL) else { return .default }
        do {
            let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
            // `AppSettings` 的逐段解码用 `try?` 做兼容（缺键/类型错误回退默认），
            // 因此整体 decode 可能「成功但某段已损坏」。这里再做一次严格段校验：
            // 发现损坏时仍然使用已解码的可用字段，但记录备份，避免 `reload()` 静默覆盖。
            if hasInvalidTopLevelSections(data) {
                diagnostics.corruptedConfigBackup = backupCorruptedFile(
                    configURL,
                    prefix: "config"
                )
            }
            return decoded
        } catch {
            NSLog("[WeChatAI] config decode failed: \(error)")
            diagnostics.corruptedConfigBackup = backupCorruptedFile(configURL, prefix: "config")
            // 整体解码失败时按顶层段逐个降级解析：单个段损坏只丢该段，
            // 不让 onebot token / hook.wechatPath / providers 一起回退默认值。
            return decodeSectionsLossily(data)
        }
    }

    /// 严格校验已知顶层段；缺失的键不算损坏（旧配置兼容），类型/结构错误才算。
    private static func hasInvalidTopLevelSections(_ data: Data) -> Bool {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return true
        }
        let decoder = JSONDecoder()
        func invalid<T: Decodable>(_ key: String, as type: T.Type) -> Bool {
            guard let value = raw[key] else { return false }
            guard JSONSerialization.isValidJSONObject(value),
                  let section = try? JSONSerialization.data(withJSONObject: value)
            else { return true }
            return (try? decoder.decode(T.self, from: section)) == nil
        }
        return invalid("general", as: GeneralSettings.self)
            || invalid("hook", as: HookSettings.self)
            || invalid("onebot", as: OneBotSettings.self)
            || invalid("ai", as: AISettings.self)
            || invalid("bot", as: BotSettings.self)
            || invalid("updates", as: UpdateSettings.self)
            || invalid("providers", as: [AIProvider].self)
            || invalid("personas", as: [Persona].self)
            || invalid("schedules", as: [ScheduledTask].self)
    }

    private static func backupCorruptedFile(_ url: URL, prefix: String) -> URL? {
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(prefix).corrupt-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.copyItem(at: url, to: backup)
        return FileManager.default.fileExists(atPath: backup.path) ? backup : nil
    }

    /// 逐段降级解析 `config.json`。
    ///
    /// 旧版配置缺新键、或某一段被手改坏时，`AppSettings` 整体 `decode` 会抛错；
    /// 这里按顶层 key 分别解码，失败的段保留 `AppSettings.default` 中的默认值。
    private static func decodeSectionsLossily(_ data: Data) -> AppSettings {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .default
        }
        var settings = AppSettings.default
        let decoder = JSONDecoder()

        func decode<T: Decodable>(_ key: String, as type: T.Type) -> T? {
            guard let value = raw[key], JSONSerialization.isValidJSONObject(value),
                  let section = try? JSONSerialization.data(withJSONObject: value),
                  let decoded = try? decoder.decode(T.self, from: section)
            else { return nil }
            return decoded
        }

        if let number = raw["schemaVersion"] as? NSNumber {
            settings.schemaVersion = number.intValue
        }
        if let value = decode("general", as: GeneralSettings.self) { settings.general = value }
        if let value = decode("hook", as: HookSettings.self) { settings.hook = value }
        if let value = decode("onebot", as: OneBotSettings.self) { settings.onebot = value }
        if let value = decode("ai", as: AISettings.self) { settings.ai = value }
        if let value = decode("bot", as: BotSettings.self) { settings.bot = value }
        if let value = decode("updates", as: UpdateSettings.self) { settings.updates = value }
        if let value = decode("providers", as: [AIProvider].self) { settings.providers = value }
        if let value = decode("personas", as: [Persona].self) { settings.personas = value }
        if let value = decode("schedules", as: [ScheduledTask].self) { settings.schedules = value }
        NSLog("[WeChatAI] config decoded lossily: 保留可用段，损坏段回退默认值")
        return settings
    }

    /// 只写全局 `config.json`（账号字段由 `SettingsPersistence.save(_:profileURL:)` 双写）。
    static func save(_ settings: AppSettings) {
        AppPaths.ensureDirectories()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            let tmp = AppPaths.configFile.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(AppPaths.configFile, withItemAt: tmp)
        } catch {
            NSLog("[WeChatAI] config save failed: \(error)")
        }
    }
}

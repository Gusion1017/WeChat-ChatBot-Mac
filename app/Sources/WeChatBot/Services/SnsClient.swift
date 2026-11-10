import Foundation

// MARK: - 错误

/// 朋友圈 HTTP 客户端错误。
///
/// 映射规则（契约 §4）：401 未授权、403 未确认/无权限、404 未启用（发布路径为写开关关闭）、
/// 429 限流、502 媒体下载失败、503 微信未就绪（需要 priming）、504 超时。
enum SnsClientError: Error, Equatable, LocalizedError {
    /// 读取端未启用（HTTP 404，bridge 未打开 SNS 功能）。
    case featureDisabled
    /// 写入端未启用（HTTP 404，bridge 写开关关闭）。
    case writeDisabled
    case unauthorized
    case forbidden
    case notReady
    case rateLimited
    /// bridge 明确拒绝发布：写通道未打通（HTTP 503 `sns_publish_unavailable`）。
    /// 与 `.notReady` 区分开，避免把「发布通道没打通」误报成「请先打开一次朋友圈」。
    case publishUnavailable
    /// 评论/点赞通道未打通：hook 尚未捕获 0xD5 评论任务闭包句柄
    /// （HTTP 503 `sns_comment_unavailable`）。需要用户在微信里手动评论一次以捕获模板。
    case commentUnavailable
    /// 写操作的目标动态不在 bridge 缓存里（HTTP 404 `sns_post_not_found`）。
    case postNotFound
    /// 回复目标评论已不存在（HTTP 404 `sns_comment_not_found`）。
    case replyTargetNotFound
    /// 其它写操作失败：bridge 返回了可展示的错误说明（网络外的服务端拒绝/参数问题）。
    case operationFailed(String)
    /// 当前不在允许发布时段（HTTP 409 `sns_outside_window`）。
    case outsideWindow
    /// bridge 全局每日发布上限（HTTP 429 `sns_daily_limit`）。
    case dailyLimit
    /// 读路径 502：bridge 与微信通信/解析失败（`sns_parse_failed` / `sns_send_failed` /
    /// `sns_hook_error`）。与 `.badGateway`（媒体下载/解密失败）分开，避免解析失败时
    /// 提示「图片或媒体下载失败」（docs/sns.md §8）。
    case bridgeFailure
    case badGateway
    case timedOut
    case http(Int, String)
    case transport(String)
    case invalidResponse(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .featureDisabled: return "朋友圈通道未开启（HTTP 404）：请重启机器人后重试"
        case .writeDisabled: return "发布未开启：请开启「允许发布（写操作）」并重启机器人。"
        case .unauthorized: return "访问 Token 无效或缺失：请检查「设置 → OneBot」中的 Token"
        case .forbidden: return "bridge 拒绝了请求：请检查 bridge 权限后重试"
        case .notReady: return "朋友圈尚未就绪：请在微信打开一次朋友圈后重试"
        case .rateLimited: return "操作过于频繁：请稍后重试"
        case .publishUnavailable: return "发布通道未打通：本次未发送，请检查「设置 → Hook」中的「R3 原生发送」"
        case .commentUnavailable: return "评论通道未就绪：请在微信手动评论一次，再重新检测。"
        case .postNotFound: return "这条动态已不在缓存中：请刷新后重试"
        case .replyTargetNotFound: return "被回复的评论已不存在：请重新加载评论后重试"
        case .operationFailed(let message): return "朋友圈操作失败：\(message)"
        case .outsideWindow: return "当前不在可发时段"
        case .dailyLimit: return "今天的发布次数已达上限"
        case .bridgeFailure: return "朋友圈请求失败：bridge 解析或发送失败，请重试并查看运行日志"
        case .badGateway: return "图片或媒体下载失败：请重试"
        case .timedOut: return "请求超时：请重试"
        case .http(let code, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "朋友圈请求失败（HTTP \(code)）" : "朋友圈请求失败（HTTP \(code)）：\(detail)"
        case .transport(let message): return "无法连接 bridge：\(message)"
        case .invalidResponse(let message): return "朋友圈返回内容无效：\(message)"
        case .decoding(let message): return "朋友圈内容解析失败：\(message)"
        }
    }

    /// 面向界面展示的本地化文案。
    var userMessage: String {
        switch self {
        case .featureDisabled: return L("朋友圈通道未开启（HTTP 404）：请重启机器人后重试")
        case .writeDisabled: return L("发布未开启：请开启「允许发布（写操作）」并重启机器人。")
        case .unauthorized: return L("访问 Token 无效或缺失：请检查「设置 → OneBot」中的 Token")
        case .forbidden: return L("bridge 拒绝了请求：请检查 bridge 权限后重试")
        case .notReady: return L("朋友圈尚未就绪：请在微信打开一次朋友圈后重试")
        case .rateLimited: return L("操作过于频繁：请稍后重试")
        case .publishUnavailable: return L("发布通道未打通：本次未发送，请检查「设置 → Hook」中的「R3 原生发送」")
        case .commentUnavailable:
            return L("评论通道未就绪：请在微信手动评论一次，再重新检测。")
        case .postNotFound: return L("这条动态已不在缓存中：请刷新后重试")
        case .replyTargetNotFound: return L("被回复的评论已不存在：请重新加载评论后重试")
        case .operationFailed(let message): return Lf("朋友圈操作失败：%@", message)
        case .outsideWindow: return L("当前不在可发时段")
        case .dailyLimit: return L("今天的发布次数已达上限")
        case .bridgeFailure: return L("朋友圈请求失败：bridge 解析或发送失败，请重试并查看运行日志")
        case .badGateway: return L("图片或媒体下载失败：请重试")
        case .timedOut: return L("请求超时：请重试")
        case .http(let code, _): return Lf("朋友圈请求失败（HTTP %d）", code)
        case .transport(let message): return Lf("无法连接 bridge：%@", message)
        case .invalidResponse(let message): return Lf("朋友圈返回内容无效：%@", message)
        case .decoding(let message): return Lf("朋友圈内容解析失败：%@", message)
        }
    }
}

// MARK: - 配置

struct SnsClientConfiguration: Hashable, Sendable {
    var baseURL: URL
    var token: String
    var requestTimeout: TimeInterval

    static let defaultBaseURL = URL(string: "http://127.0.0.1:58080")!

    init(
        baseURL: URL = SnsClientConfiguration.defaultBaseURL,
        token: String = "",
        requestTimeout: TimeInterval = 20
    ) {
        self.baseURL = baseURL
        self.token = token
        self.requestTimeout = max(1, requestTimeout)
    }

    /// 复用 OneBot 的 host/port/token（契约 §1.2：App 不新增鉴权通道）。
    init(onebot: OneBotSettings, requestTimeout: TimeInterval = 20) {
        let host = onebot.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedHost = host.isEmpty ? "127.0.0.1" : host
        let url = URL(string: "http://\(resolvedHost):\(onebot.port)")
        self.init(
            baseURL: url ?? SnsClientConfiguration.defaultBaseURL,
            token: onebot.token,
            requestTimeout: requestTimeout
        )
    }
}

// MARK: - 客户端协议（便于测试注入）

protocol SnsClientProtocol: AnyObject {
    func fetchStatus() async throws -> SnsStatus
    func fetchTimeline(
        maxID: String,
        firstPageMD5: String,
        session: String,
        refresh: Bool,
        limit: Int
    ) async throws -> SnsTimelinePage
    func fetchDetail(postID: String) async throws -> SnsDetailResult
    func fetchMedia(postID: String, mediaIndex: Int, variant: SnsMediaVariant) async throws -> URL
    func fetchSync(waitMS: Int) async throws -> SnsSyncResult
    func publish(text: String, visibility: SnsVisibility, visibleUserIDs: [String],
                 clientID: String) async throws -> SnsPublishResult
    /// 发表评论（`replyCommentID` 为空）或回复某条评论（非空）。
    func comment(postID: String, text: String, replyCommentID: String) async throws -> SnsCommentResult
}

// MARK: - 客户端

/// bridge `/sns/*` HTTP 客户端（契约 §4）。
///
/// - 所有请求都是 `POST http://127.0.0.1:<port>/sns/<action>`，Bearer token 复用 OneBot 配置；
/// - async/await + 可注入 `URLSession` / 基址 / 超时，便于 URLProtocol 单测；
/// - 类本身不是 actor，网络与 JSON 解析都跑在协作线程池，不占用 MainActor。
final class SnsClient: SnsClientProtocol, @unchecked Sendable {
    enum RequestContext {
        case read
        case write
    }

    let configuration: SnsClientConfiguration
    private let session: URLSession

    init(configuration: SnsClientConfiguration = SnsClientConfiguration(), session: URLSession? = nil) {
        self.configuration = configuration
        self.session = session ?? Self.makeSession(requestTimeout: configuration.requestTimeout)
    }

    convenience init(
        baseURL: URL,
        token: String = "",
        requestTimeout: TimeInterval = 20,
        session: URLSession? = nil
    ) {
        self.init(
            configuration: SnsClientConfiguration(
                baseURL: baseURL,
                token: token,
                requestTimeout: requestTimeout
            ),
            session: session
        )
    }

    convenience init(onebot: OneBotSettings, session: URLSession? = nil) {
        self.init(configuration: SnsClientConfiguration(onebot: onebot), session: session)
    }

    static func makeSession(requestTimeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = max(1, requestTimeout)
        configuration.timeoutIntervalForResource = max(60, requestTimeout * 2)
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: configuration)
    }

    // MARK: 端点

    func fetchStatus() async throws -> SnsStatus {
        let root = try await perform(path: "/sns/status", body: [:], context: .read)
        return try Self.decodePayload(SnsStatus.self, from: root)
    }

    func fetchTimeline(
        maxID: String = "0",
        firstPageMD5: String = "",
        session: String = "",
        refresh: Bool = false,
        limit: Int = 20
    ) async throws -> SnsTimelinePage {
        let body: [String: Any] = [
            "max_id": maxID,
            "first_page_md5": firstPageMD5,
            "session": session,
            "refresh": refresh,
            "limit": max(1, min(limit, 100))
        ]
        let root = try await perform(path: "/sns/timeline", body: body, context: .read,
                                     timeout: max(configuration.requestTimeout, 25))
        return try Self.decodePayload(SnsTimelinePage.self, from: root)
    }

    func fetchDetail(postID: String) async throws -> SnsDetailResult {
        let root = try await perform(path: "/sns/detail", body: ["post_id": postID], context: .read,
                                     timeout: max(configuration.requestTimeout, 25))
        let payload = Self.payloadObject(from: root)
        let candidate: [String: Any]
        if let post = payload["post"] as? [String: Any] {
            candidate = post
        } else if let post = root["post"] as? [String: Any] {
            candidate = post
        } else {
            candidate = payload
        }
        let post = try Self.decode(SnsPost.self, from: candidate)
        guard !post.id.isEmpty else {
            throw SnsClientError.invalidResponse("详情缺少动态 ID")
        }
        // bridge 在被动模式/主动失败时会用时间线缓存兜底，并返回 source=cache。
        let source = (payload["source"] as? String)
            ?? (root["source"] as? String)
            ?? "native"
        return SnsDetailResult(post: post, source: source)
    }

    func fetchMedia(postID: String, mediaIndex: Int, variant: SnsMediaVariant) async throws -> URL {
        let body: [String: Any] = [
            "post_id": postID,
            "media_index": mediaIndex,
            "variant": variant.rawValue
        ]
        let root = try await perform(path: "/sns/media", body: body, context: .read,
                                     timeout: max(configuration.requestTimeout, 45))
        let payload = Self.payloadObject(from: root)
        let file = (payload["file"] as? String)
            ?? (root["file"] as? String)
            ?? (payload["path"] as? String)
            ?? (root["path"] as? String)
            ?? ""
        guard !file.isEmpty else {
            throw SnsClientError.invalidResponse("缺少媒体文件路径")
        }
        guard let url = Self.localFileURL(from: file) else {
            throw SnsClientError.invalidResponse("媒体文件路径无效")
        }
        return url
    }

    func fetchSync(waitMS: Int = 0) async throws -> SnsSyncResult {
        let body: [String: Any] = ["wait_ms": max(0, waitMS)]
        let root = try await perform(path: "/sns/sync", body: body, context: .read,
                                     timeout: max(configuration.requestTimeout, 25))
        return try Self.decodePayload(SnsSyncResult.self, from: root)
    }

    func publish(
        text: String,
        visibility: SnsVisibility,
        visibleUserIDs: [String] = [],
        clientID: String
    ) async throws -> SnsPublishResult {
        var body: [String: Any] = [
            "text": text,
            "visibility": visibility.rawValue,
            "media": [],
            // 幂等键：超时/重试时 bridge 用它去重，避免重复发一条朋友圈。
            "client_id": clientID
        ]
        if visibility == .partial {
            // 部分可见只传当前私聊对象；绝不把空列表当成公开。
            let recipients = visibleUserIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            body["visible_user_ids"] = recipients
        }
        let root = try await perform(path: "/sns/post", body: body, context: .write,
                                     timeout: max(configuration.requestTimeout, 30))
        return try Self.decodePayload(SnsPublishResult.self, from: root)
    }

    /// 发表评论 / 回复评论。写操作必须显式 `confirm: true`（App 的 composer 已二次确认）。
    func comment(
        postID: String,
        text: String,
        replyCommentID: String = ""
    ) async throws -> SnsCommentResult {
        var body: [String: Any] = [
            "post_id": postID,
            "text": text,
            "confirm": true
        ]
        let reply = replyCommentID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reply.isEmpty {
            body["reply_comment_id"] = reply
        }
        let root = try await perform(path: "/sns/comment", body: body, context: .write,
                                     timeout: max(configuration.requestTimeout, 25))
        return try Self.decodePayload(SnsCommentResult.self, from: root)
    }

    // MARK: 请求

    private func perform(
        path: String,
        body: [String: Any],
        context: RequestContext,
        timeout: TimeInterval? = nil
    ) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: configuration.baseURL) else {
            throw SnsClientError.invalidResponse("请求路径无效：\(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = configuration.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = timeout ?? configuration.requestTimeout
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            throw SnsClientError.invalidResponse("请求体编码失败：\(error.localizedDescription)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut:
                throw SnsClientError.timedOut
            default:
                throw SnsClientError.transport(urlError.localizedDescription)
            }
        } catch {
            throw SnsClientError.transport(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SnsClientError.invalidResponse("非 HTTP 响应")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Self.mapHTTPStatus(httpResponse.statusCode, path: path, context: context, data: data)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw SnsClientError.invalidResponse("响应不是 JSON 对象")
        }
        if let status = (root["status"] as? String)?.lowercased(),
           status != "ok", status != "async" {
            throw Self.mapEnvelopeError(root, path: path, context: context)
        }
        return root
    }

    // MARK: 解码

    static func payloadObject(from root: [String: Any]) -> [String: Any] {
        (root["data"] as? [String: Any]) ?? root
    }

    static func decode<T: Decodable>(_ type: T.Type, from object: [String: Any]) throws -> T {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw SnsClientError.invalidResponse("响应对象无法序列化")
        }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: object)
        } catch {
            throw SnsClientError.invalidResponse(error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw SnsClientError.decoding(error.localizedDescription)
        }
    }

    static func decodePayload<T: Decodable>(_ type: T.Type, from root: [String: Any]) throws -> T {
        try decode(type, from: payloadObject(from: root))
    }

    // MARK: 错误映射

    static func mapHTTPStatus(
        _ status: Int,
        path: String,
        context: RequestContext,
        data: Data = Data()
    ) -> SnsClientError {
        switch status {
        case 401:
            return .unauthorized
        case 403:
            // hook 层写开关关闭时 bridge 用 403 `sns_write_disabled`（总开关/写开关未开
            // 的正常路径是 404，见 §4.6）。这句提示必须可行动，不能说成「没有权限」。
            if context == .write, errorCode(from: data) == "sns_write_disabled" {
                return .writeDisabled
            }
            return .forbidden
        case 404:
            // 先按 `code` 细分（写目标动态 / 回复目标评论 / 媒体），再按请求路径决定
            // 「总开关未开」还是「写开关未开」——同一状态码的语义不同（§4.6）。
            switch errorCode(from: data) ?? "" {
            case "sns_disabled":
                return .featureDisabled
            case "sns_post_not_found":
                return .postNotFound
            case "sns_comment_not_found":
                return .replyTargetNotFound
            case "sns_media_not_found":
                return context == .write
                    ? .operationFailed(serverMessage(from: data) ?? "该动态没有可下载的媒体")
                    : .badGateway
            case "sns_write_disabled":
                return context == .write ? .writeDisabled : .featureDisabled
            case "":
                return context == .read ? .featureDisabled : .writeDisabled
            default:
                if context == .read { return .featureDisabled }
                return .operationFailed(serverMessage(from: data) ?? "朋友圈写操作未开启")
            }
        case 409:
            if errorCode(from: data) == "sns_outside_window" { return .outsideWindow }
            if context == .write {
                return .operationFailed(serverMessage(from: data) ?? "朋友圈写操作被拒绝")
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            return .http(status, String(body.prefix(240)))
        case 429:
            return errorCode(from: data) == "sns_daily_limit" ? .dailyLimit : .rateLimited
        case 502:
            // 写路径的 502 是微信侧拒绝/发送失败，不是媒体下载失败（docs/sns.md §8）。
            if context == .write, let message = serverMessage(from: data) {
                return .operationFailed(message)
            }
            // 读路径 bridge 把「回包解析/发送失败」和「媒体下载失败」都映射成 502：
            // 按 code 区分文案，解析失败不能提示「图片或媒体下载失败」。
            switch errorCode(from: data) ?? "" {
            case "sns_parse_failed", "sns_native_rejected", "sns_send_failed", "sns_hook_error":
                return .bridgeFailure
            default:
                return .badGateway
            }
        case 503:
            // 503 按错误码细分：发布/评论句柄是两套独立通道，媒体通道与「没打开过
            // 朋友圈」也不是一回事（§4.6 / §4.4）。
            switch errorCode(from: data) ?? "" {
            case "sns_publish_unavailable":
                return context == .write ? .publishUnavailable : .notReady
            case "sns_comment_unavailable":
                return context == .write ? .commentUnavailable : .notReady
            case "sns_channel_unconfigured", "sns_unsupported":
                // 版本 JSON 缺锚点：重试/打开朋友圈都没用，不能提示「请先打开一次朋友圈」。
                return .operationFailed(serverMessage(from: data) ?? "当前 Hook 版本不支持该朋友圈任务")
            case "sns_media_unavailable", "sns_media_decrypt_pending":
                return .badGateway
            default:
                return .notReady
            }
        case 504:
            return .timedOut
        default:
            if context == .write, let message = serverMessage(from: data) {
                return .operationFailed(message)
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            return .http(status, String(body.prefix(240)))
        }
    }

    /// 从 bridge 错误体里取出 `code`（HTTP 状态相同、原因不同的场景需要它）。
    static func errorCode(from data: Data) -> String? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return nil }
        let code = (root["code"] as? String) ?? (root["error"] as? String) ?? ""
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 从 bridge 错误体里取出可展示的错误说明（`error` 字段；不含内部细节）。
    static func serverMessage(from data: Data) -> String? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return nil }
        let raw = (root["error"] as? String) ?? (root["message"] as? String) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(240))
    }

    static func mapEnvelopeError(
        _ root: [String: Any],
        path: String,
        context: RequestContext
    ) -> SnsClientError {
        // bridge 失败体是 `{status:"failed", code:"sns_*", error:"<给用户看的文案>"}`
        // （docs/sns.md §4）：`code` 才是错误码，`error` 是说明，别把两者弄反。
        let rawCode = (root["code"] as? String) ?? (root["error"] as? String) ?? ""
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rawMessage = ((root["error"] as? String) ?? (root["message"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = rawMessage.isEmpty ? code : rawMessage
        switch code {
        case "unauthorized", "401", "invalid_token", "sns_unauthorized":
            return .unauthorized
        case "forbidden", "403", "unconfirmed", "sns_not_confirmed":
            return .forbidden
        case "sns_disabled", "disabled":
            // 总开关关闭（读/写都先命中这一层）。
            return .featureDisabled
        case "not_found", "404", "unsupported":
            return context == .write ? .writeDisabled : .featureDisabled
        case "sns_write_disabled", "write_disabled", "publish_disabled":
            return context == .write ? .writeDisabled : .featureDisabled
        case "sns_post_not_found", "post_not_found":
            return .postNotFound
        case "sns_comment_not_found", "comment_not_found":
            return .replyTargetNotFound
        case "not_ready", "notready", "priming", "seed_not_ready", "wechat_not_ready",
             "sns_not_ready", "sns_need_prime":
            return .notReady
        case "rate_limited", "ratelimited", "429", "sns_rate_limited":
            return .rateLimited
        case "sns_daily_limit", "daily_limit":
            return .dailyLimit
        case "sns_outside_window", "outside_window":
            return .outsideWindow
        case "sns_publish_unavailable", "publish_unavailable":
            return context == .write ? .publishUnavailable : .notReady
        case "sns_comment_unavailable", "comment_unavailable":
            return context == .write ? .commentUnavailable : .notReady
        case "sns_channel_unconfigured", "channel_unconfigured", "sns_unsupported":
            return .operationFailed(rawMessage.isEmpty ? "当前 Hook 版本未配置朋友圈发送锚点" : rawMessage)
        case "sns_parse_failed", "sns_send_failed", "sns_hook_error", "sns_native_rejected":
            return context == .write && !rawMessage.isEmpty ? .operationFailed(rawMessage) : .bridgeFailure
        case "sns_media_failed", "sns_media_unavailable", "sns_media_decrypt_pending",
             "bad_gateway", "502":
            return context == .write && !rawMessage.isEmpty ? .operationFailed(rawMessage) : .badGateway
        case "timeout", "timed_out", "504":
            return .timedOut
        default:
            if context == .write {
                return .operationFailed(message.isEmpty ? "未知错误（\(path)）" : message)
            }
            return .invalidResponse(message.isEmpty ? "未知错误（\(path)）" : message)
        }
    }

    // MARK: 路径

    /// `file://…` / 绝对路径 → 本地文件 URL。
    static func localFileURL(from file: String) -> URL? {
        let trimmed = file.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("file://") {
            return URL(string: trimmed)
        }
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        return nil
    }
}

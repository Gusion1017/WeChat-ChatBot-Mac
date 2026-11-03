import Foundation

/// GitHub Releases 更新通道（无鉴权、只读）。
///
/// 只访问公开接口：`GET /repos/<owner>/<repo>/releases/latest` 与 release 资产；
/// 不发送 API Key / Cookie / 本地路径。所有下载地址都要求 https + GitHub 域名，
/// 防止 release JSON 被降级成明文或跳到任意主机。
final class GitHubUpdateClient: @unchecked Sendable {
    struct Configuration: Sendable {
        var owner: String
        var repo: String
        var apiBaseURL: URL
        var userAgent: String

        init(
            owner: String = "Gusion1017",
            repo: String = "WeChat-ChatBot-Mac",
            apiBaseURL: URL = URL(string: "https://api.github.com")!,
            userAgent: String = GitHubUpdateClient.defaultUserAgent
        ) {
            self.owner = owner
            self.repo = repo
            self.apiBaseURL = apiBaseURL
            self.userAgent = userAgent
        }

        /// 手动下载 / 查看发布说明的兜底页面（API 不可用时使用）。
        var releasesPageURL: URL {
            URL(string: "https://github.com/\(owner)/\(repo)/releases")!
        }

        var latestPageURL: URL {
            URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!
        }
    }

    static let defaultUserAgent: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        return "WeChatAI/\(version) (macOS; +https://github.com/Gusion1017/WeChat-ChatBot-Mac)"
    }()

    let configuration: Configuration
    private let session: URLSession

    init(configuration: Configuration = Configuration(), session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.waitsForConnectivity = false
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 120
            config.httpAdditionalHeaders = [
                "Accept": "application/vnd.github+json",
                "User-Agent": configuration.userAgent,
                "X-GitHub-Api-Version": "2022-11-28",
            ]
            self.session = URLSession(configuration: config)
        }
    }

    /// 发布检查接口。
    var latestReleaseURL: URL {
        configuration.apiBaseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(configuration.owner)
            .appendingPathComponent(configuration.repo)
            .appendingPathComponent("releases")
            .appendingPathComponent("latest")
    }

    // MARK: - 检查

    /// 拉取 latest 正式版。没有发布时抛 `releaseNotFound`；限流单独提示。
    func latestRelease() async throws -> AppUpdateRelease? {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.mapTransportError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AppUpdateError.network("响应无效")
        }
        switch http.statusCode {
        case 200:
            return try Self.decodeRelease(from: data)
        case 403, 429:
            let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining")
            if remaining == "0" || http.statusCode == 429 {
                throw AppUpdateError.rateLimited
            }
            throw AppUpdateError.httpStatus(http.statusCode)
        case 404:
            throw AppUpdateError.releaseNotFound
        default:
            throw AppUpdateError.httpStatus(http.statusCode)
        }
    }

    // MARK: - 下载

    /// 下载 release zip 到指定目录，返回本地文件 URL。
    ///
    /// `onProgress` 在后台队列回调（接收字节 / 期望字节，未知时为 0），调用方负责
    /// 切回主线程；回调已按 200ms 节流，避免 68MB 下载把主线程刷爆。
    func download(
        _ asset: AppUpdateAsset,
        to directory: URL,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> URL {
        guard Self.isAllowedDownloadURL(asset.downloadURL) else {
            throw AppUpdateError.malformedResponse("下载地址不是 GitHub 域名")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var request = URLRequest(url: asset.downloadURL)
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 600

        let task = UpdateDownloadTask(destinationDirectory: directory, progress: onProgress)
        return try await task.start(request)
    }

    /// 拉取 `.sha256` 资产并解析出小写十六进制摘要；响应异常时抛错，内容为空返回 nil。
    func fetchChecksum(from url: URL) async throws -> String? {
        guard Self.isAllowedDownloadURL(url) else {
            throw AppUpdateError.malformedResponse("校验文件地址不是 GitHub 域名")
        }
        var request = URLRequest(url: url)
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.mapTransportError(error)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AppUpdateError.httpStatus(status)
        }
        guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else {
            throw AppUpdateError.malformedResponse("校验文件内容无效")
        }
        return UpdateChecksum.parse(text)
    }

    // MARK: - 解析（纯函数，单测复用）

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String
            let size: Int64?

            private enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
                case size
            }
        }

        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: String?
        let publishedAt: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case draft
            case prerelease
            case assets
        }
    }

    static func decodeRelease(from data: Data) throws -> AppUpdateRelease {
        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw AppUpdateError.malformedResponse(error.localizedDescription)
        }
        guard let version = AppVersion(tag: release.tagName) else {
            throw AppUpdateError.invalidVersion(release.tagName)
        }
        let candidates = release.assets.compactMap { asset -> AppUpdateAssetSelector.Candidate? in
            guard let url = URL(string: asset.browserDownloadURL) else { return nil }
            return AppUpdateAssetSelector.Candidate(name: asset.name, url: url, size: asset.size)
        }
        let selected = AppUpdateAssetSelector.asset(from: candidates)
        return AppUpdateRelease(
            tag: release.tagName,
            version: version,
            name: release.name ?? "",
            notes: release.body ?? "",
            pageURL: release.htmlURL.flatMap(URL.init(string:)),
            publishedAt: release.publishedAt.flatMap(parseGitHubDate),
            asset: selected,
            isPrerelease: release.prerelease
        )
    }

    /// GitHub 的 `published_at` 是 RFC3339；同时兼容带小数秒的格式。
    static func parseGitHubDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }

    // MARK: - Helpers

    static func isAllowedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            return false
        }
        return host == "github.com"
            || host == "objects.githubusercontent.com"
            || host == "release-assets.githubusercontent.com"
            || host.hasSuffix(".githubusercontent.com")
    }

    static func mapTransportError(_ error: Error) -> AppUpdateError {
        if let updateError = error as? AppUpdateError { return updateError }
        if error is CancellationError { return .downloadFailed("已取消") }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return .downloadFailed("已取消")
        }
        return .network(error.localizedDescription)
    }
}

// MARK: - 下载任务

/// `URLSessionDownloadDelegate` 的 async 封装：只在 `didWriteData` 里节流回调进度，
/// 下载完成后把临时文件移到目标目录，再 resume continuation。
private final class UpdateDownloadTask: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destinationDirectory: URL
    private let progress: (@Sendable (Int64, Int64) -> Void)?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var lastProgressAt: TimeInterval = 0

    init(destinationDirectory: URL, progress: (@Sendable (Int64, Int64) -> Void)?) {
        self.destinationDirectory = destinationDirectory
        self.progress = progress
    }

    func start(_ request: URLRequest) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 900
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            lock.lock()
            self.session = session
            lock.unlock()
            session.downloadTask(with: request).resume()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            finish(.failure(AppUpdateError.httpStatus(http.statusCode)))
            return
        }
        let filename = downloadTask.response?.suggestedFilename ?? "WeChat-AI-update.zip"
        let destination = destinationDirectory.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(AppUpdateError.downloadFailed(error.localizedDescription)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            finish(.failure(CancellationError()))
        } else {
            finish(.failure(AppUpdateError.downloadFailed(error.localizedDescription)))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let progress else { return }
        let now = Date().timeIntervalSince1970
        let isComplete = totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
        guard isComplete || now - lastProgressAt >= 0.2 else { return }
        lastProgressAt = now
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }
}

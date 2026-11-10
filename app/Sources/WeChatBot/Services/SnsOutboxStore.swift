import Foundation
import Observation

/// 朋友圈自动发布的「演练草稿」存储（只读预览）。
///
/// - 每个账号一份 `accounts/<wxid>/sns-outbox.json`（只存本机，不入库、不上传）；
/// - 由 `SnsPublishScheduler` 在演练模式下写入；
/// - v3.0 起只读：在「机器人 → 朋友圈 → 演练草稿」预览/删除，不发送、不写 ledger。
@MainActor
@Observable
final class SnsOutboxStore {
    static let maxCount = 20

    private(set) var drafts: [SnsPendingDraft] = []
    private(set) var accountID: String = ""

    @ObservationIgnored private let directoryProvider: @MainActor () -> URL
    @ObservationIgnored private var loaded = false

    init(directoryProvider: @escaping @MainActor () -> URL = { AppPaths.accountDirectory }) {
        self.directoryProvider = directoryProvider
    }

    private var fileURL: URL {
        directoryProvider().appendingPathComponent("sns-outbox.json")
    }

    /// 切换账号时重新加载；同一账号重复调用不会覆盖未落盘内容。
    func load(accountID: String) {
        if loaded, accountID == self.accountID { return }
        self.accountID = accountID
        loaded = true
        drafts = Self.read(fileURL)
    }

    /// 重新读盘（账号目录落盘完成/外部修改后）。
    func reload() {
        drafts = Self.read(fileURL)
    }

    /// 追加一条草稿；超出上限时丢弃最旧的。
    func add(_ draft: SnsPendingDraft) {
        var updated = drafts
        updated.removeAll { $0.id == draft.id }
        updated.append(draft)
        if updated.count > Self.maxCount {
            updated.removeFirst(updated.count - Self.maxCount)
        }
        drafts = updated
        persist()
    }

    func remove(id: String) {
        let updated = drafts.filter { $0.id != id }
        guard updated.count != drafts.count else { return }
        drafts = updated
        persist()
    }

    func removeAll() {
        guard !drafts.isEmpty else { return }
        drafts = []
        persist()
    }

    // MARK: 落盘

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(drafts) else { return }
        let url = fileURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            // 草稿是辅助状态；写失败不阻塞发布流程，下次变更会重试。
        }
    }

    private static func read(_ url: URL) -> [SnsPendingDraft] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([SnsPendingDraft].self, from: data) else { return [] }
        let valid = decoded.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // 文件可能由旧版本或手工编辑写入超过上限的条数：内存态与落盘都收敛到 maxCount，
        // 只保留最新（文件顺序 = 追加顺序）。
        return Array(valid.suffix(maxCount))
    }
}

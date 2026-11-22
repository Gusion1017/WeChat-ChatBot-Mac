import Foundation
import XCTest
@testable import WeChatAI

/// 导出数据备份前必须把 WAL 合并回主库：否则备份包里的主库与 -wal 可能来自不同时刻，
/// 恢复后丢失最近提交。这里验证 checkpoint 会截断 WAL 且数据仍可读。
final class SQLiteCheckpointTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-checkpoint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }

    func testMemoryStoreCheckpointTruncatesWALAndKeepsData() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbURL = directory.appendingPathComponent("chatbot.sqlite")
        let store = MemoryStore(databaseURL: dbURL)
        try await store.open()
        try await store.upsertConversation(Conversation(id: "c1", kind: .direct, title: "测试"))
        try await store.upsertMessages([
            ChatMessage(
                id: "m1",
                conversationID: "c1",
                senderID: "c1",
                senderName: "A",
                direction: .incoming,
                text: "你好",
                timestamp: Date()
            )
        ])

        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        XCTAssertGreaterThan(fileSize(walURL), 0, "写入后应存在 WAL 内容")

        await store.checkpointForBackup()
        XCTAssertEqual(fileSize(walURL), 0, "checkpoint 应截断 WAL")
        let count = try await store.messageCount(conversationID: "c1")
        XCTAssertEqual(count, 1, "checkpoint 后数据仍可读")
        await store.close()
    }

    func testCharacterStoreCheckpointTruncatesOpenCardWAL() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CharacterStore(rootDirectory: directory)
        try await store.ensureGlobalCharacter()
        try await store.upsertMemory(CharacterMemory(
            characterID: CharacterStore.globalConversationID,
            content: "用户喜欢喝咖啡"
        ))

        let memoryURL = directory
            .appendingPathComponent(CharacterDirectory.key(for: CharacterStore.globalConversationID), isDirectory: true)
            .appendingPathComponent("memory.sqlite")
        let walURL = URL(fileURLWithPath: memoryURL.path + "-wal")
        XCTAssertGreaterThan(fileSize(walURL), 0, "写入后应存在 WAL 内容")

        await store.checkpointForBackup()
        XCTAssertEqual(fileSize(walURL), 0, "checkpoint 应截断 WAL")

        let memories = try await store.fetchMemories(
            conversationID: CharacterStore.globalConversationID
        )
        XCTAssertEqual(memories.count, 1, "checkpoint 后记忆仍可读")
        await store.suspend()
    }

    func testSQLiteBackupFilesAreCopiedNotHardLinked() {
        for name in ["chatbot.sqlite", "chatbot.sqlite-wal", "chatbot.sqlite-shm",
                     "memory.sqlite", "memory.sqlite-wal"] {
            XCTAssertTrue(BackupService.isSQLiteBackupFile(name), "\(name) 应按 SQLite 备份")
        }
        for name in ["config.json", "m.bin", "profile.json", "p.wav"] {
            XCTAssertFalse(BackupService.isSQLiteBackupFile(name), "\(name) 不应按 SQLite 备份")
        }
    }
}

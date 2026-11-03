import AVFoundation
import Foundation
import XCTest

@testable import WeChatAI

/// 参考音导入简化（2026-11）：
/// - 去掉扩展名白名单：AVFoundation 能解码即可（含非 wav/m4a/aiff 容器与无扩展名文件）；
/// - 单条只保留 1 秒下限，不再有 30 秒单条硬上限；
/// - 总长仍 ≤30 秒，导入时按剩余预算自动截取（保留开头），保存时仍做最终兜底；
/// - 多条参考文本不再要求「全填/全空」，混合文本用非空文本合并、全空按 cross-lingual。
final class ReferenceImportTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "reference-import-tests-\(UUID().uuidString.lowercased())",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - 纯规则

    func testReferenceSpecBudgetAndTrimRules() {
        XCTAssertEqual(CosyVoiceReferenceSpec.maxCount, 5)
        XCTAssertEqual(CosyVoiceReferenceSpec.minClipDuration, 1.0, accuracy: 0.0001)
        XCTAssertEqual(CosyVoiceReferenceSpec.maxTotalDuration, 30, accuracy: 0.0001)
        XCTAssertEqual(CosyVoiceReferenceSpec.gapSeconds, 0.25, accuracy: 0.0001)
        XCTAssertEqual(CosyVoiceReferenceSpec.sampleRate, 24_000)

        // 未超出预算时保留整段；超出时只保留预算内的开头部分。
        XCTAssertEqual(CosyVoiceReferenceSpec.fittedDuration(4, budget: 10), 4, accuracy: 0.0001)
        XCTAssertEqual(CosyVoiceReferenceSpec.fittedDuration(10, budget: 4), 4, accuracy: 0.0001)
        XCTAssertEqual(CosyVoiceReferenceSpec.fittedDuration(10, budget: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(CosyVoiceReferenceSpec.fittedDuration(.nan, budget: 10), 0, accuracy: 0.0001)

        // 追加新片段要预留 gap：已有 10 秒 → 30 − 10 − 0.25 = 19.75。
        XCTAssertEqual(CosyVoiceReferenceSpec.remainingBudget(current: 0), 30, accuracy: 0.0001)
        XCTAssertEqual(CosyVoiceReferenceSpec.remainingBudget(current: 10), 19.75, accuracy: 0.0001)
        XCTAssertEqual(CosyVoiceReferenceSpec.remainingBudget(current: 30), 0, accuracy: 0.0001)
        XCTAssertEqual(CosyVoiceReferenceSpec.remainingBudget(current: 29.9), 0, accuracy: 0.0001)

        // 20 秒 + 9.75 秒 + 0.25 gap = 30 秒整，说明预算与合并规则一致。
        let first = CosyVoiceReferenceSpec.fittedDuration(
            20, budget: CosyVoiceReferenceSpec.remainingBudget(current: 0))
        let second = CosyVoiceReferenceSpec.fittedDuration(
            10, budget: CosyVoiceReferenceSpec.remainingBudget(current: first))
        XCTAssertEqual(first, 20, accuracy: 0.0001)
        XCTAssertEqual(second, 9.75, accuracy: 0.0001)
        XCTAssertEqual(
            CosyVoiceReferenceSpec.combinedDuration([first, second]),
            30, accuracy: 0.001)
    }

    func testMixedTextsUseNonEmptyTextInsteadOfFailing() {
        // 文本一致性不再是保存阻断条件；合并时跳过空文本。
        XCTAssertEqual(CosyVoiceReferenceSpec.combinedText(["A", "", " B "]), "A\nB")
        XCTAssertEqual(CosyVoiceReferenceSpec.combinedText(["", "  "]), "")
        XCTAssertEqual(
            CosyVoiceReferenceSpec.combinedDuration([10, 5]), 15.25, accuracy: 0.0001)
    }

    // MARK: - 时长规则

    func testMinimumClipDurationBoundary() throws {
        let tooShort = try makeAudioFile(seconds: 0.9)
        do {
            _ = try CosyVoiceVoiceStore.prepareAudio(url: tooShort)
            XCTFail("0.9 秒应判为太短")
        } catch let error as CosyVoiceVoiceStoreError {
            guard case .audioTooShort = error else {
                return XCTFail("错误类型不对：\(error)")
            }
            XCTAssertTrue(
                error.errorDescription?.contains("至少需要 1 秒") == true,
                "错误文案应提示 1 秒下限：\(error.errorDescription ?? "nil")")
        }

        // 1.0 秒是边界内（允许 0.05s 取整误差）。
        let boundary = try makeAudioFile(seconds: 1.0)
        let prepared = try CosyVoiceVoiceStore.prepareAudio(url: boundary)
        XCTAssertEqual(prepared.duration, 1.0, accuracy: 0.01)
        XCTAssertEqual(
            prepared.samples.count,
            Int((prepared.duration * Double(CosyVoiceReferenceSpec.sampleRate)).rounded()))
    }

    func testLongClipNoSingleDurationCap() throws {
        // 单条 31 秒不再报 audioTooLong；总长兜底交给保存阶段。
        let long = try makeAudioFile(seconds: 31)
        let prepared = try CosyVoiceVoiceStore.prepareAudio(url: long)
        XCTAssertGreaterThan(prepared.duration, 30.5)
        XCTAssertGreaterThan(prepared.duration, 30, "单条不再被 30 秒上限拦截")
    }

    // MARK: - 格式白名单移除

    func testDecodableAudioWithoutKnownExtensionIsAccepted() throws {
        // 内容仍是可解码的 24k WAV，但扩展名不在旧白名单里（.dat / 无扩展名）。
        for fileName in ["clip.dat", "clip"] {
            let url = try makeAudioFile(seconds: 2, fileName: fileName)
            let prepared = try CosyVoiceVoiceStore.prepareAudio(url: url)
            XCTAssertEqual(prepared.duration, 2.0, accuracy: 0.05, "fileName=\(fileName)")
        }
    }

    func testUndecodableFileReportsClearError() throws {
        let broken = temporaryDirectory.appendingPathComponent("broken.wav")
        try Data("this is not audio".utf8).write(to: broken)
        do {
            _ = try CosyVoiceVoiceStore.prepareAudio(url: broken)
            XCTFail("不可解码文件应报错")
        } catch let error as CosyVoiceVoiceStoreError {
            guard case .invalidAudio = error else {
                return XCTFail("错误类型不对：\(error)")
            }
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        }

        let empty = temporaryDirectory.appendingPathComponent("empty.wav")
        try Data().write(to: empty)
        XCTAssertThrowsError(try CosyVoiceVoiceStore.prepareAudio(url: empty)) { error in
            guard let storeError = error as? CosyVoiceVoiceStoreError,
                  case .invalidAudio = storeError else {
                return XCTFail("空文件应报 invalidAudio：\(error)")
            }
        }
    }

    // MARK: - 预算裁剪 helper

    func testFittedReferenceAudioTrimsToBudget() throws {
        let source = try makeAudioFile(seconds: 10)
        let fitted = try CosyVoiceVoiceStore.fittedReferenceAudio(
            url: source, maxDuration: 4)
        XCTAssertEqual(fitted.duration, 4.0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(
            fitted.duration, 4.0,
            "裁剪后不能超过预算，否则合并总长会越界")
        XCTAssertTrue(
            abs(fitted.samples.count - 96_000) <= 16,
            "裁剪后样本数应约等于 4 秒 × 24k，实际 \(fitted.samples.count)")
        XCTAssertEqual(fitted.originalDuration ?? 0, 10.0, accuracy: 0.05)

        // 预算足够时保留整段，不做裁剪。
        let untouched = try CosyVoiceVoiceStore.fittedReferenceAudio(
            url: source, maxDuration: 12)
        XCTAssertEqual(untouched.duration, 10.0, accuracy: 0.05)
        XCTAssertEqual(untouched.originalDuration ?? 0, 10.0, accuracy: 0.05)
    }

    func testExhaustedBudgetReportsClearError() throws {
        let source = try makeAudioFile(seconds: 2)
        for budget in [0, 0.2] {
            do {
                _ = try CosyVoiceVoiceStore.fittedReferenceAudio(
                    url: source, maxDuration: budget)
                XCTFail("预算 \(budget) 秒不足以加入片段，应报错")
            } catch let error as CosyVoiceVoiceStoreError {
                guard case .invalidReference(let reason) = error else {
                    return XCTFail("错误类型不对：\(error)")
                }
                XCTAssertTrue(reason.contains("30 秒"), "错误应说明总长限制：\(reason)")
                XCTAssertTrue(reason.contains("删除") || reason.contains("缩短"))
            }
        }
    }

    func testWriteTemporaryWAVRoundTrips24kMono() throws {
        let sampleRate = 24_000
        let samples = (0..<(sampleRate * 2)).map { index in
            Float(sin(2 * Double.pi * 220 * Double(index) / Double(sampleRate))) * 0.4
        }
        let url = try CosyVoiceVoiceStore.writeTemporaryWAV(samples)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.pathExtension, "wav")

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.sampleRate, 24_000, accuracy: 0.1)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(Double(file.length) / 24_000, 2.0, accuracy: 0.01)
    }

    // MARK: - Store 保存规则

    func testStoreAcceptsMixedReferenceTexts() async throws {
        let store = try makeVoiceStore()
        let first = try makeAudioFile(seconds: 2)
        let second = try makeAudioFile(seconds: 2)
        let voice = try await store.add(
            name: "混合文本",
            references: [
                .newAudio(first, text: "第一段参考文本"),
                .newAudio(second, text: "   "),
            ],
            description: ""
        )
        XCTAssertEqual(voice.references.count, 2)
        XCTAssertEqual(voice.mode, CosyVoiceManagedVoice.modeZeroShot)
        XCTAssertEqual(voice.referenceText, "第一段参考文本")
        XCTAssertEqual(voice.references[0].text, "第一段参考文本")
        XCTAssertEqual(voice.references[1].text, "")
        XCTAssertEqual(voice.duration ?? 0, 4.25, accuracy: 0.05)

        // prompt.txt 与合并 prompt.wav 仍是保存入口，至少不能为空。
        let promptText = try XCTUnwrap(voice.promptWAVPath)
            .replacingOccurrences(of: "prompt.wav", with: "prompt.txt")
        let savedText = try String(contentsOfFile: promptText, encoding: .utf8)
        XCTAssertEqual(
            savedText.trimmingCharacters(in: .whitespacesAndNewlines),
            "第一段参考文本")
    }

    func testStoreUsesCrossLingualWhenAllTextsEmpty() async throws {
        let store = try makeVoiceStore()
        let first = try makeAudioFile(seconds: 2)
        let second = try makeAudioFile(seconds: 2)
        let voice = try await store.add(
            name: "全空文本",
            references: [
                .newAudio(first, text: ""),
                .newAudio(second, text: "  "),
            ],
            description: ""
        )
        XCTAssertTrue(voice.isCrossLingual)
        XCTAssertEqual(voice.mode, CosyVoiceManagedVoice.modeCrossLingual)
        XCTAssertTrue(voice.referenceText.isEmpty)
    }

    func testStoreKeepsTotalDurationAsFinalFallback() async throws {
        let store = try makeVoiceStore()
        // 单条 31 秒：prepareAudio 已接受，但合并总长仍触发保存兜底。
        let long = try makeAudioFile(seconds: 31)
        do {
            _ = try await store.add(
                name: "总长兜底",
                references: [.newAudio(long, text: "")],
                description: ""
            )
            XCTFail("合并总长 31 秒应触发最终兜底")
        } catch let error as CosyVoiceVoiceStoreError {
            guard case .referenceTotalTooLong(let seconds) = error else {
                return XCTFail("错误类型不对：\(error)")
            }
            XCTAssertEqual(seconds, 31, accuracy: 0.2)
            XCTAssertTrue(
                error.errorDescription?.contains("删除") == true
                    || error.errorDescription?.contains("缩短") == true,
                "兜底文案应提示先删减：\(error.errorDescription ?? "nil")")
        }
    }

    // MARK: - 测试夹具

    private func makeVoiceStore() throws -> CosyVoiceVoiceStore {
        let directory = temporaryDirectory.appendingPathComponent(
            "voices-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return CosyVoiceVoiceStore(
            voicesDirectory: directory,
            serviceReady: { false }
        )
    }

    private func makeAudioFile(
        seconds: Double,
        fileName: String? = nil,
        sampleRate: Int = 24_000,
        amplitude: Float = 0.4
    ) throws -> URL {
        let count = Int((Double(sampleRate) * seconds).rounded())
        let samples = (0..<count).map { index in
            Float(sin(2 * Double.pi * 220 * Double(index) / Double(sampleRate))) * amplitude
        }
        let data = Self.makePCM16WAV(samples: samples, sampleRate: sampleRate)
        let url = temporaryDirectory.appendingPathComponent(
            fileName ?? "audio-\(UUID().uuidString.lowercased()).wav")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 生成单声道 16-bit PCM WAV（测试桩，不依赖 AVAudioFile 写入）。
    private static func makePCM16WAV(samples: [Float], sampleRate: Int) -> Data {
        var payload = Data()
        payload.reserveCapacity(samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let value = Int16((clamped * 32_767).rounded())
            withUnsafeBytes(of: value.littleEndian) { payload.append(contentsOf: $0) }
        }
        var data = Data()
        func appendU16(_ value: Int, to data: inout Data) {
            var little = UInt16(value).littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func appendU32(_ value: Int, to data: inout Data) {
            var little = UInt32(value).littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        appendU32(36 + payload.count, to: &data)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendU32(16, to: &data)
        appendU16(1, to: &data)
        appendU16(1, to: &data)
        appendU32(sampleRate, to: &data)
        appendU32(sampleRate * 2, to: &data)
        appendU16(2, to: &data)
        appendU16(16, to: &data)
        data.append(contentsOf: Array("data".utf8))
        appendU32(payload.count, to: &data)
        data.append(payload)
        return data
    }
}

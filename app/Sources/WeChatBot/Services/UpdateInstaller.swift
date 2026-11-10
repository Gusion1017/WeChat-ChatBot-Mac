import CryptoKit
import Foundation

/// 当前 App 的安装位置（应用内更新的目标）。
struct UpdateInstallTarget: Equatable, Sendable {
    let bundleURL: URL
    let bundleIdentifier: String
    let version: AppVersion
    let build: String

    var displayPath: String { bundleURL.path }

    /// 从仓库 `dist/` 或 SwiftPM 构建目录运行的开发构建；更新行为一致但界面会提示。
    var isDevelopmentBuild: Bool {
        let path = bundleURL.standardizedFileURL.path
        return path.contains("/dist/") || path.contains("/.build")
    }
}

/// 应用内更新的文件操作：解压、校验、原地替换与回滚。
///
/// 所有命令都用绝对路径调用系统工具（`ditto` / `codesign` / `xattr` / `open`），
/// 不经过 shell 拼接用户输入；真正替换 app bundle 的工作交给一个**独立的更新助手
/// 脚本**，它在当前进程退出后才执行，因此不会替换正在运行的二进制。
///
/// 安全契约（改实现时必须保持）：
/// - 只允许替换 bundle id 为 `appBundleIdentifier` 且主可执行文件存在的 App；
/// - 解压目标、安装目标都必须是 `.app` 目录，安装前必须通过 `codesign --verify --strict`；
/// - 失败必须回滚：把旧 bundle 从同目录备份 `mv` 回来，并重新打开旧版本；
/// - 任何路径进入 shell 前都经过单引号转义，脚本内全部用双引号引用。
enum UpdateInstaller {
    /// 只允许更新本项目自己的 App，避免误替换其它 bundle。
    static let appBundleIdentifier = "com.gusionw.wechatai"

    /// 更新工作目录（下载的 zip、解压产物、助手脚本）。位于 App Support，不随 App 删除。
    static var updatesDirectory: URL {
        AppPaths.supportDirectory.appendingPathComponent("updates", isDirectory: true)
    }

    /// 更新助手写出的执行日志（诊断用，位于 `~/Library/Logs/WeChatAI/`）。
    static var logFileURL: URL {
        AppPaths.bridgeLogDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("update.log")
    }

    /// 旧版本备份目录后缀：`WeChat AI.app.update-backup-<timestamp>`。
    static let backupSuffixPrefix = ".update-backup-"

    /// 助手脚本等待旧进程退出的上限（秒），超时后先 SIGTERM 再 SIGKILL。
    static let helperWaitTimeout: TimeInterval = 60

    // MARK: - 安装位置

    /// 解析并校验当前运行 App 的 bundle；不可原地更新时抛出 `AppUpdateError`。
    static func resolveCurrentTarget(bundle: Bundle = .main) throws -> UpdateInstallTarget {
        let bundleURL = bundle.bundleURL.standardizedFileURL
        guard bundleURL.pathExtension.lowercased() == "app" else {
            throw AppUpdateError.notAnApplicationBundle
        }
        if isTranslocated(path: bundleURL.path) {
            throw AppUpdateError.translocated(bundleURL.path)
        }
        let identifier = bundle.bundleIdentifier ?? ""
        guard !identifier.isEmpty else { throw AppUpdateError.notAnApplicationBundle }
        guard identifier == appBundleIdentifier else {
            throw AppUpdateError.invalidBundle("Bundle ID 不匹配（\(identifier)）")
        }
        let parent = bundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw AppUpdateError.readOnlyLocation(parent.path)
        }
        let info = bundle.infoDictionary ?? [:]
        let versionRaw = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let version = AppVersion(tag: versionRaw) ?? AppVersion(major: 0, minor: 0, patch: 0)
        let build = info["CFBundleVersion"] as? String ?? "-"
        return UpdateInstallTarget(
            bundleURL: bundleURL,
            bundleIdentifier: identifier,
            version: version,
            build: build
        )
    }

    /// macOS App Translocation（从 zip/下载目录直接打开）路径判定。
    ///
    /// 只看 `/AppTranslocation/` 路径段（大小写不敏感）。`/private/var/folders/`
    /// 是正常的系统临时目录前缀（临时文件/测试目录也可能落在那里），**不能**据此
    /// 判定为隔离路径，否则会把可正常更新的 App 误判成不可更新。
    static func isTranslocated(path: String) -> Bool {
        path.lowercased().contains("/apptranslocation/")
    }

    // MARK: - 工作目录

    static func makeWorkDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: updatesDirectory, withIntermediateDirectories: true)
        let directory = updatesDirectory.appendingPathComponent(
            "update-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func removeWorkDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// 清理上次更新遗留的工作目录（默认保留 24h，方便排查失败原因）。
    static func cleanupStaleWorkDirectories(olderThan age: TimeInterval = 24 * 60 * 60) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: updatesDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff {
                try? fileManager.removeItem(at: entry)
            }
        }
    }

    // MARK: - 解压与校验

    /// 解压 zip 并返回其中的 `WeChat AI.app`。
    ///
    /// - 使用 `/usr/bin/ditto -x -k --noqtn`（绝对路径，不经过 shell），先建目标目录；
    /// - 只接受顶层或一层子目录里**唯一**的 `.app`；0 个或多个都视为非法发布包；
    /// - `expectedVersion` 只用于错误文案（版本号严格校验在 `validateStagedApp`）。
    static func unpack(zipURL: URL, into directory: URL, expectedVersion: AppVersion) throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: zipURL.path) else {
            throw AppUpdateError.unzipFailed("更新包不存在：\(zipURL.lastPathComponent)")
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw AppUpdateError.unzipFailed("无法创建工作目录：\(error.localizedDescription)")
        }

        let result: ToolResult
        do {
            result = try runSystemTool(
                "/usr/bin/ditto",
                arguments: ["-x", "-k", "--noqtn", zipURL.path, directory.path]
            )
        } catch {
            throw AppUpdateError.unzipFailed("无法启动 ditto：\(error.localizedDescription)")
        }
        guard result.status == 0 else {
            let detail = result.stderr.isEmpty ? "ditto 退出码 \(result.status)" : result.stderr
            throw AppUpdateError.unzipFailed(detail)
        }

        let apps = appBundles(in: directory)
        switch apps.count {
        case 1:
            return apps[0]
        case 0:
            throw AppUpdateError.invalidBundle("解压后没有找到 .app（期望版本 \(expectedVersion)）")
        default:
            let names = apps.map(\.lastPathComponent).joined(separator: "、")
            throw AppUpdateError.invalidBundle("解压后包含多个 .app，无法确定安装目标：\(names)")
        }
    }

    /// 校验解压后的 App：Info.plist / bundle id / 版本号 / 主可执行文件 + 签名。
    static func validateStagedApp(_ appURL: URL, expectedVersion: AppVersion) throws {
        try validateStagedAppMetadata(appURL, expectedVersion: expectedVersion)

        let result: ToolResult
        do {
            result = try runSystemTool(
                "/usr/bin/codesign",
                arguments: ["--verify", "--strict", appURL.path]
            )
        } catch {
            throw AppUpdateError.signatureInvalid("无法启动 codesign：\(error.localizedDescription)")
        }
        guard result.status == 0 else {
            let detail = result.stderr.isEmpty ? "codesign 退出码 \(result.status)" : result.stderr
            throw AppUpdateError.signatureInvalid(detail)
        }
    }

    /// 纯元数据校验（不执行 codesign），便于单测与快速失败。
    ///
    /// 全部走 `Contents/Info.plist` 原始 plist 解析，不依赖 `Bundle` 缓存：
    /// - Info.plist 必须可解析为字典；
    /// - `CFBundleIdentifier` 必须是本项目；
    /// - `CFBundleShortVersionString` 必须能解析且与发布版本完全相等；
    /// - `CFBundleExecutable` 必须是非空单段文件名，且 `Contents/MacOS/<exe>` 可执行。
    static func validateStagedAppMetadata(_ appURL: URL, expectedVersion: AppVersion) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: appURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              appURL.pathExtension.lowercased() == "app"
        else {
            throw AppUpdateError.invalidBundle("不是 .app 目录：\(appURL.lastPathComponent)")
        }

        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard fileManager.fileExists(atPath: infoURL.path) else {
            throw AppUpdateError.invalidBundle("缺少 Info.plist")
        }
        let info: [String: Any]
        do {
            let data = try Data(contentsOf: infoURL)
            guard let plist = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any] else {
                throw AppUpdateError.invalidBundle("Info.plist 格式不正确")
            }
            info = plist
        } catch let error as AppUpdateError {
            throw error
        } catch {
            throw AppUpdateError.invalidBundle("Info.plist 无法解析：\(error.localizedDescription)")
        }

        let identifier = ((info["CFBundleIdentifier"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard identifier == appBundleIdentifier else {
            let actual = identifier.isEmpty ? "缺失" : identifier
            throw AppUpdateError.invalidBundle(
                "Bundle ID 不匹配（期望 \(appBundleIdentifier)，实际 \(actual)）"
            )
        }

        let versionRaw = ((info["CFBundleShortVersionString"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let version = AppVersion(tag: versionRaw), version == expectedVersion else {
            let actual = versionRaw.isEmpty ? "缺失" : versionRaw
            throw AppUpdateError.invalidBundle(
                "版本号不匹配（期望 \(expectedVersion)，实际 \(actual)）"
            )
        }

        let executable = ((info["CFBundleExecutable"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !executable.isEmpty else {
            throw AppUpdateError.invalidBundle("缺少主可执行文件")
        }
        // 只允许单段文件名，拒绝 `../` 之类的路径穿越（不要把校验指到 bundle 外）。
        guard !executable.contains("/"), !executable.contains("\\"),
              executable != ".", executable != ".."
        else {
            throw AppUpdateError.invalidBundle("CFBundleExecutable 非法：\(executable)")
        }
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/\(executable)")
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw AppUpdateError.invalidBundle(
                "主可执行文件不存在或不可执行：Contents/MacOS/\(executable)"
            )
        }
    }

    // MARK: - 助手脚本

    /// 生成更新助手脚本。脚本在当前 App 退出后替换 bundle，失败时回滚到旧版本。
    ///
    /// 所有路径都经 `shellQuote` 单引号转义后写入脚本；脚本内不 `eval`，变量全部加双引号。
    /// 脚本行为（与集成测试 `testHelperScriptReplacesAppAndKeepsBackup` 对齐）：
    /// 1. 等 `pid` 退出（最多 60s；发信号前用 `ps -p` 确认 PID 仍是本 App，避免 PID
    ///    复用误杀其它进程；超时先 SIGTERM 再 SIGKILL）；
    /// 2. 旧 App `mv` 成同目录 `*.update-backup-<epoch>` 备份；
    /// 3. `ditto` 安装暂存 App → `xattr -dr com.apple.quarantine` → ad-hoc `codesign` 重签 →
    ///    `codesign --verify --strict` 验证；
    /// 4. 任一步失败：删半成品、恢复备份、重新打开旧版本、exit 1；
    /// 5. 成功：打开新版本、保留备份（由新版本 `cleanupAfterUpdate` 清理）、删除临时工作目录。
    /// 不使用 `set -e`（失败会跳过回滚），只 `set -u` 并逐条检查返回码。
    static func helperScript(appPath: String, stagedPath: String, pid: Int32, logPath: String) -> String {
        let app = shellQuote(appPath)
        let staged = shellQuote(stagedPath)
        let log = shellQuote(logPath)
        let work = shellQuote(workDirectoryPath(forStagedAppPath: stagedPath))
        let timeout = Int(helperWaitTimeout.rounded())
        return #"""
        #!/bin/bash
        # =============================================================================
        # WeChat AI 应用内更新助手（由 App 自动生成，请勿手工修改）
        #
        # 职责：等旧进程退出后原地替换 .app；任一步失败自动回滚到旧版本并重新打开。
        #
        # 安全边界：
        #   - APP_PATH / STAGED_APP / LOG_FILE / WORK_DIR 由生成方做单引号转义，
        #     脚本内全部加双引号引用，绝不 eval、不拼接未引用变量；
        #   - 不启用 errexit：每条关键命令显式检查返回码，保证失败一定进入 rollback；
        #   - 只在 .../updates/update-* 约定目录内清理临时文件，避免误删用户目录；
        #   - 不做递归深度签名：发布包 build_app.sh 已分别签名 bridge/gadget 子二进制。
        # =============================================================================
        set -u

        APP_PATH=\#(app)
        STAGED_APP=\#(staged)
        APP_PID=\#(pid)
        LOG_FILE=\#(log)
        WORK_DIR=\#(work)

        BACKUP_EPOCH="$(/bin/date +%s)"
        BACKUP_PATH="${APP_PATH}.update-backup-${BACKUP_EPOCH}"
        # 只有本脚本真的把旧 App 移走后才置 1；rollback 依此决定是否删除/恢复，
        # 避免“备份路径被占用”等预检失败时误删当前 App。
        BACKUP_CREATED=0

        /bin/mkdir -p "$(/usr/bin/dirname "${LOG_FILE}")" 2>/dev/null

        log() {
            printf '[%s] %s\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$*" >> "${LOG_FILE}" 2>/dev/null
        }

        bundle_plist_value() {
            # ${1} = .app 路径；${2} = Info.plist 键。读取失败输出 "?"，不影响主流程。
            local value
            value="$(/usr/libexec/PlistBuddy -c "Print :${2}" "${1}/Contents/Info.plist" 2>/dev/null)" || value=""
            if [ -z "${value}" ]; then
                printf '?'
            else
                printf '%s' "${value}"
            fi
        }

        open_app() {
            # ${1} = .app 路径；${2} = 日志描述。
            # WECHATAI_UPDATE_SKIP_OPEN=1 只给自动化集成测试使用；真实运行时不会设置。
            if [ "${WECHATAI_UPDATE_SKIP_OPEN:-0}" = "1" ]; then
                log "WECHATAI_UPDATE_SKIP_OPEN=1：跳过 open（${2}）${1}"
                return 0
            fi
            /usr/bin/open "${1}" >> "${LOG_FILE}" 2>&1
        }

        rollback() {
            local reason="${1:-未知错误}"
            log "❌ 更新失败：${reason}"
            # 只有本脚本确实把旧 App 移动到备份后，才删除当前 App 并恢复备份：
            # 预检失败（例如备份路径被占用）时绝不能删掉正在使用的版本。
            if [ "${BACKUP_CREATED}" = "1" ] && [ -e "${BACKUP_PATH}" ]; then
                log "清理半成品：${APP_PATH}"
                /bin/rm -rf "${APP_PATH}" 2>>"${LOG_FILE}" || log "无法删除半成品，继续尝试恢复备份"
                if /bin/mv "${BACKUP_PATH}" "${APP_PATH}" 2>>"${LOG_FILE}"; then
                    log "已从备份恢复旧版本：${APP_PATH}"
                else
                    log "严重：无法从备份恢复旧版本，请手动把 ${BACKUP_PATH} 重命名回 ${APP_PATH}"
                fi
            else
                log "尚未替换旧 App，不删除、不恢复（避免误删当前版本）"
            fi
            if [ -d "${APP_PATH}" ]; then
                open_app "${APP_PATH}" "旧版本" || log "无法重新打开旧版本：${APP_PATH}"
            fi
            log "回滚结束（exit 1），详细信息见 ${LOG_FILE}"
            exit 1
        }

        wait_for_exit() {
            local pid="${1}"
            local start=${SECONDS}
            local current_comm
            log "等待旧进程 ${pid} 退出（最多 \#(timeout) 秒）"
            while kill -0 "${pid}" 2>/dev/null; do
                if [ $((SECONDS - start)) -ge \#(timeout) ]; then
                    # PID 可能被系统复用：发信号前先确认它仍是当前 App，避免误杀别的进程。
                    # macOS 的 `ps -p <pid> -o comm=` 返回可执行文件路径
                    # （.../WeChat AI.app/Contents/MacOS/WeChatAI）；PID 已消失时输出为空。
                    current_comm="$(/bin/ps -p "${pid}" -o comm= 2>/dev/null || true)"
                    case "${current_comm}" in
                        *WeChatAI*)
                            ;;
                        *)
                            log "PID ${pid} 已不是 WeChat AI（当前：${current_comm:-无}），视为已退出"
                            return 0
                            ;;
                    esac
                    log "等待超时，先发送 SIGTERM"
                    kill -TERM "${pid}" 2>/dev/null || true
                    /bin/sleep 2
                    if kill -0 "${pid}" 2>/dev/null; then
                        log "SIGTERM 无效，发送 SIGKILL"
                        kill -KILL "${pid}" 2>/dev/null || true
                        /bin/sleep 1
                    fi
                    break
                fi
                /bin/sleep 0.25
            done
            if kill -0 "${pid}" 2>/dev/null; then
                return 1
            fi
            return 0
        }

        log "================================================================"
        log "WeChat AI 更新助手启动（旧进程 pid=${APP_PID}）"
        log "旧 App：${APP_PATH}（版本 $(bundle_plist_value "${APP_PATH}" CFBundleShortVersionString)，build $(bundle_plist_value "${APP_PATH}" CFBundleVersion)）"
        log "新 App：${STAGED_APP}（版本 $(bundle_plist_value "${STAGED_APP}" CFBundleShortVersionString)，build $(bundle_plist_value "${STAGED_APP}" CFBundleVersion)）"
        log "备份：${BACKUP_PATH}"
        log "工作目录：${WORK_DIR}"

        # 1. 预检：此时还没动旧 App，失败也不会丢数据。
        if [ ! -d "${APP_PATH}" ]; then
            rollback "旧 App 不存在：${APP_PATH}"
        fi
        if [ ! -d "${STAGED_APP}" ]; then
            rollback "暂存 App 不存在：${STAGED_APP}"
        fi
        if [ -e "${BACKUP_PATH}" ]; then
            rollback "备份路径已被占用：${BACKUP_PATH}"
        fi

        # 2. 等旧进程退出；超时先 SIGTERM 再 SIGKILL。
        if ! wait_for_exit "${APP_PID}"; then
            rollback "旧进程 ${APP_PID} 在 \#(timeout) 秒内未能退出"
        fi
        log "旧进程已退出"

        # 3. 同目录 rename 备份旧版本（同一文件系统内原子操作）。
        if ! /bin/mv "${APP_PATH}" "${BACKUP_PATH}" 2>>"${LOG_FILE}"; then
            rollback "无法把旧版本移动到备份：${BACKUP_PATH}"
        fi
        BACKUP_CREATED=1
        log "旧版本已备份：${BACKUP_PATH}"

        # 4. ditto 安装新版本：保留权限、符号链接与资源分叉。
        if ! /usr/bin/ditto --noqtn "${STAGED_APP}" "${APP_PATH}" 2>>"${LOG_FILE}"; then
            rollback "ditto 复制新版本失败"
        fi
        log "新版本已复制到：${APP_PATH}"

        # 5. 清理隔离属性（从下载目录解压的 bundle 可能带 com.apple.quarantine）。
        if ! /usr/bin/xattr -dr com.apple.quarantine "${APP_PATH}" 2>>"${LOG_FILE}"; then
            log "xattr 清理隔离属性返回非 0（通常是本来没有该属性，继续）"
        fi

        # 6. ad-hoc 重签名（与 build_app.sh 一致：/usr/bin/codesign -f -s - --timestamp=none）。
        if ! /usr/bin/codesign -f -s - --timestamp=none "${APP_PATH}" 2>>"${LOG_FILE}"; then
            rollback "codesign 重新签名失败"
        fi
        log "已重新签名（ad-hoc）"

        # 7. 严格校验签名，失败必须回滚。
        if ! /usr/bin/codesign --verify --strict "${APP_PATH}" 2>>"${LOG_FILE}"; then
            rollback "codesign --verify --strict 校验失败"
        fi
        log "签名校验通过"

        # 8. 启动新版本；打不开视为安装失败并回滚。
        if ! open_app "${APP_PATH}" "新版本"; then
            rollback "无法打开新版本：${APP_PATH}"
        fi
        log "✅ 更新成功：${APP_PATH}"
        log "旧版本备份保留在 ${BACKUP_PATH}，由新版本启动时 cleanupAfterUpdate 清理"

        # 9. 清理下载/解压的临时工作目录（含 zip 与本脚本自身）。
        #    只允许删除 .../updates/update-* 约定目录：路径异常时宁可不清理，也不误删。
        case "${WORK_DIR}" in
            */updates/update-*)
                log "清理临时工作目录：${WORK_DIR}"
                /bin/rm -rf "${WORK_DIR}" 2>>"${LOG_FILE}" || true
                ;;
            *)
                log "工作目录不符合 .../updates/update-* 约定，跳过清理：${WORK_DIR}"
                ;;
        esac
        exit 0
        """#
    }

    /// 写入并启动更新助手。返回后调用方应立即退出 App（助手会等本进程退出）。
    ///
    /// 用 Foundation `Process` 直接执行 `/bin/bash <script>`，**不** `waitUntilExit()`：
    /// 脚本第一步就是等本进程退出，等待会死锁。stdio 全部重定向到 nullDevice，
    /// 避免 App 退出后子进程写已关闭的管道收到 SIGPIPE。
    static func launchInstaller(
        stagedApp: URL,
        target: UpdateInstallTarget,
        workDirectory: URL
    ) throws {
        let scriptURL = workDirectory.appendingPathComponent("update-helper.sh")
        let script = helperScript(
            appPath: target.bundleURL.path,
            stagedPath: stagedApp.path,
            pid: ProcessInfo.processInfo.processIdentifier,
            logPath: logFileURL.path
        )
        do {
            try FileManager.default.createDirectory(
                at: workDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: logFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scriptURL.path
            )
        } catch {
            throw AppUpdateError.helperLaunchFailed(error.localizedDescription)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AppUpdateError.helperLaunchFailed(error.localizedDescription)
        }
        // 进程对象在这里自然释放即可：助手脚本独立于本进程运行，且不等待本进程的
        // 任何 stdio。绝不 waitUntilExit()（那会阻塞到 App 退出之后）。
    }

    // MARK: - 收尾

    /// 新版本启动后清理旧的 `.update-backup-*` 备份与遗留工作目录。
    ///
    /// 只删除同目录下以 `<当前 App 名>.update-backup-` 开头的条目；不碰其它文件，
    /// 避免误删用户的同名备份/其它 App。
    static func cleanupAfterUpdate(target: UpdateInstallTarget?) {
        cleanupStaleWorkDirectories()
        guard let target else { return }
        let parent = target.bundleURL.deletingLastPathComponent()
        let prefix = target.bundleURL.lastPathComponent + backupSuffixPrefix
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: - 内部工具

    /// 系统工具的退出结果（stderr 已按 UTF-8 解码并去掉首尾空白）。
    private struct ToolResult {
        let status: Int32
        let stderr: String
    }

    /// 用绝对路径执行系统工具并捕获 stderr。
    ///
    /// 只负责启动进程与收集结果：启动失败抛出原始错误，由调用方映射成
    /// `unzipFailed` / `signatureInvalid`。stderr 与进程运行**并行**读取
    /// （`readDataToEndOfFile` 阻塞到 EOF），避免输出塞满管道导致死锁。
    private static func runSystemTool(_ executablePath: String, arguments: [String]) throws -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ToolResult(status: process.terminationStatus, stderr: stderr)
    }

    /// 解压目录里定位 `.app`：只看顶层与一层子目录，避免把 App 内部资源里的
    /// 嵌套 `.app`（helper/插件）误当成安装目标。返回按路径排序，结果稳定可测。
    private static func appBundles(in directory: URL) -> [URL] {
        let fileManager = FileManager.default
        func isAppDirectory(_ url: URL) -> Bool {
            guard url.pathExtension.lowercased() == "app" else { return false }
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        func children(of url: URL) -> [URL] {
            ((try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []).sorted { $0.path < $1.path }
        }

        var found: [URL] = []
        for entry in children(of: directory) {
            if isAppDirectory(entry) {
                found.append(entry)
                continue
            }
            for nested in children(of: entry) where isAppDirectory(nested) {
                found.append(nested)
            }
        }
        return found
    }

    /// 单引号包裹的 shell 字面量；内部单引号写成 `'\''`，其余字符原样保留。
    ///
    /// 例：`WeChat AI.app` → `'WeChat AI.app'`；`a'b` → `'a'\''b'`。
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 由暂存 App 路径反推下载/解压的工作目录（`.../updates/update-<uuid>`）。
    ///
    /// `unpack` 总是解压到 `makeWorkDirectory()` 创建的目录，App 可能在顶层或一层
    /// 子目录；这里向上找到 `updatesDirectory` 的直接子目录。找不到时退回暂存 App
    /// 的父目录——助手脚本只会清理符合 `.../updates/update-*` 约定的目录，因此退回
    /// 值不会造成误删。
    private static func workDirectoryPath(forStagedAppPath path: String) -> String {
        let stagedParent = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL
        let updatesPath = updatesDirectory.standardizedFileURL.path
        var candidate = stagedParent
        while candidate.path.hasPrefix(updatesPath + "/") {
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            if parent.path == updatesPath {
                return candidate.path
            }
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return stagedParent.path
    }
}

// MARK: - SHA256

/// 发布包完整性校验：GitHub release 同时提供 `WeChat-AI-<version>.zip.sha256`
/// （`shasum -a 256` 输出格式：`<hex>  <filename>`）。
enum UpdateChecksum {
    /// 从校验文件文本中解析摘要；无效返回 nil。
    static func parse(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let token = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).first
        guard let token else { return nil }
        let hex = String(token).lowercased()
        guard hex.count == 64, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hex
    }

    /// 流式计算文件 SHA256（不把 68MB 读进内存）。
    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verify(fileURL: URL, expectedHex: String) throws {
        let expected = UpdateChecksum.parse(expectedHex) ?? expectedHex.lowercased()
        let actual: String
        do {
            actual = try sha256Hex(ofFileAt: fileURL)
        } catch {
            throw AppUpdateError.downloadFailed(error.localizedDescription)
        }
        guard actual == expected else {
            throw AppUpdateError.checksumMismatch
        }
    }
}

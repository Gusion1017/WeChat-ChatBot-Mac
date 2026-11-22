import XCTest
@testable import WeChatAI

/// Hook 安装失败的可操作提示：macOS「App 管理」拦截写入微信时应识别为专门错误，
/// 而不是只显示「脚本退出码 1」。
final class HookInstallFailureTests: XCTestCase {
    func testDetectsAppManagementDenialFromDittoStderr() {
        let line = "ditto: /Applications/WeChat.app/Contents/Frameworks/FridaGadget.dylib: Operation not permitted"
        XCTAssertTrue(HookManager.isAppManagementDenial(line))
    }

    func testDetectsAppManagementDenialFromChineseScriptError() {
        XCTAssertTrue(HookManager.isAppManagementDenial(
            "ERROR: 无法写入 /Applications/WeChat.app（Operation not permitted）。这是 macOS「App 管理」权限"
        ))
    }

    func testDoesNotMatchGenericInstallError() {
        XCTAssertFalse(HookManager.isAppManagementDenial("ERROR: 脚本退出码 1"))
        XCTAssertFalse(HookManager.isAppManagementDenial("微信正在运行，请完全退出微信后再安装"))
        XCTAssertFalse(HookManager.isAppManagementDenial(""))
    }

    func testDedicatedErrorIsActionableAndDistinguishable() {
        let error = HookError.appManagementPermissionDenied
        XCTAssertTrue(error.isAppManagementPermissionDenied)
        XCTAssertTrue(error.localizedDescription.contains("App 管理"))
        XCTAssertFalse(HookError.installFailed("Operation not permitted").isAppManagementPermissionDenied)
    }
}

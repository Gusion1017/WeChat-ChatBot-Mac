import XCTest
@testable import WeChatAI

/// 侧栏悬停状态机：进入/离开/切页清理。
/// 覆盖 macOS 26 NavigationSplitView 换页时可能吞掉 onHover(false) 导致的错位高亮。
final class SidebarHoverStateTests: XCTestCase {
    func testEnteringRowSetsHover() {
        XCTAssertEqual(SidebarHoverState.entered(.ai), SidebarItem.ai)
    }

    /// 离开事件只清理仍指向该行的悬停，避免「先进入新行、后收到旧行离开」误清当前悬停。
    func testLeavingOnlyClearsMatchingRow() {
        XCTAssertNil(SidebarHoverState.exited(.ai, item: .ai))
        XCTAssertEqual(SidebarHoverState.exited(.ai, item: .moments), SidebarItem.ai)
        XCTAssertEqual(SidebarHoverState.exited(.moments, item: .ai), SidebarItem.moments)
        XCTAssertNil(SidebarHoverState.exited(nil, item: .ai))
    }

    /// 页面切换（点击行、⌘ 快捷键、命令/菜单跳动）后必须清空悬停，
    /// 否则侧栏重排后灰色高亮块会停在错误的行上。
    func testSelectionChangeClearsStaleHover() {
        XCTAssertNil(SidebarHoverState.afterSelectionChange())
    }
}

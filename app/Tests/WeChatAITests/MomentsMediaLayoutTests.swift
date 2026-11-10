import AppKit
import XCTest
@testable import WeChatAI

/// 朋友圈媒体布局的计算规则：多图网格的列数/正方形边长、单图展示宽度。
///
/// 这些规则必须由布局自己算准：LazyVGrid + aspectRatio 会被图片自身比例撑变形，
/// 表现为同一行格子宽窄不一、网格向左溢出卡片（2026-11-09 真机问题）。
final class MomentsMediaLayoutTests: XCTestCase {

    // MARK: 列数

    func testGridColumnsFollowMomentsConvention() {
        XCTAssertEqual(MomentMediaMetrics.gridColumns(for: 1), 3, "单图不走网格，按三列兜底")
        XCTAssertEqual(MomentMediaMetrics.gridColumns(for: 2), 2)
        XCTAssertEqual(MomentMediaMetrics.gridColumns(for: 3), 3)
        XCTAssertEqual(MomentMediaMetrics.gridColumns(for: 4), 2)
        for count in 5...9 {
            XCTAssertEqual(MomentMediaMetrics.gridColumns(for: count), 3, "\(count) 张应为三列")
        }
    }

    // MARK: 格子尺寸

    func testThreeColumnGridFillsMaxWidthExactly() {
        let columns = 3
        let side = MomentMediaMetrics.gridCellSide(availableWidth: 696, columns: columns)
        let total = side * CGFloat(columns) + MomentMediaMetrics.gridSpacing * CGFloat(columns - 1)
        XCTAssertEqual(side, (340 - 12) / 3, accuracy: 0.0001)
        XCTAssertEqual(total, MomentMediaMetrics.maxWidth, accuracy: 0.0001)
    }

    func testTwoColumnGridFillsMaxWidthExactly() {
        let side = MomentMediaMetrics.gridCellSide(availableWidth: 340, columns: 2)
        let total = side * 2 + MomentMediaMetrics.gridSpacing
        XCTAssertEqual(side, 167, accuracy: 0.0001)
        XCTAssertEqual(total, 340, accuracy: 0.0001)
    }

    func testGridCellSideShrinksWithNarrowContainer() {
        let side = MomentMediaMetrics.gridCellSide(availableWidth: 296, columns: 3)
        let total = side * 3 + MomentMediaMetrics.gridSpacing * 2
        XCTAssertEqual(total, 296, accuracy: 0.0001)
        XCTAssertLessThan(side, 100)
    }

    func testGridCellSideNeverCollapses() {
        XCTAssertGreaterThan(MomentMediaMetrics.gridCellSide(availableWidth: 0, columns: 3), 0)
        XCTAssertGreaterThan(MomentMediaMetrics.gridCellSide(availableWidth: 6, columns: 3), 0)
        XCTAssertGreaterThan(MomentMediaMetrics.gridCellSide(availableWidth: 6, columns: 2), 0)
    }

    // MARK: 可用宽度

    func testUsableWidthHandlesMissingProposalAndClamps() {
        XCTAssertEqual(MomentMediaMetrics.usableWidth(for: nil), 340)
        XCTAssertEqual(MomentMediaMetrics.usableWidth(for: 696), 340)
        XCTAssertEqual(MomentMediaMetrics.usableWidth(for: 200), 200)
        XCTAssertEqual(MomentMediaMetrics.usableWidth(for: -10), 0)
    }

    // MARK: 单图宽度

    func testSingleImageWidthCapsLargeImagesAtMaxWidth() {
        XCTAssertEqual(MomentMediaMetrics.singleImageWidth(pixelWidth: 0), 340)
        XCTAssertEqual(MomentMediaMetrics.singleImageWidth(pixelWidth: 4032), 340)
        XCTAssertEqual(MomentMediaMetrics.singleImageWidth(pixelWidth: 680), 340)
    }

    func testSingleImageWidthDoesNotUpscaleSmallImages() {
        XCTAssertEqual(MomentMediaMetrics.singleImageWidth(pixelWidth: 500), 250)
        XCTAssertEqual(MomentMediaMetrics.singleImageWidth(pixelWidth: 300), 150)
    }

    func testSingleImageWidthKeepsMinimumTapTarget() {
        XCTAssertEqual(MomentMediaMetrics.singleImageWidth(pixelWidth: 160), 100)
        XCTAssertEqual(MomentMediaMetrics.singleImageWidth(pixelWidth: 80), 100)
    }

    // MARK: 单图高度

    func testSingleImageHeightAppliesMaxHeightCap() {
        XCTAssertEqual(MomentMediaMetrics.singleImageHeight(width: 340, aspect: 1), 340, accuracy: 0.0001)
        XCTAssertEqual(MomentMediaMetrics.singleImageHeight(width: 340, aspect: 4.0 / 3.0), 255, accuracy: 0.0001)
        XCTAssertEqual(MomentMediaMetrics.singleImageHeight(width: 340, aspect: 4), 85, accuracy: 0.0001)
        // 超出 460 pt 上限的长图裁到上限
        XCTAssertEqual(MomentMediaMetrics.singleImageHeight(width: 340, aspect: 0.5), 460, accuracy: 0.0001)
        // 小图本来就不高时完整展示，不裁切
        XCTAssertEqual(MomentMediaMetrics.singleImageHeight(width: 100, aspect: 0.5), 200, accuracy: 0.0001)
        // 非法输入退回高度上限（由调用方的原比例兜底）
        XCTAssertEqual(MomentMediaMetrics.singleImageHeight(width: 0, aspect: 0), 460, accuracy: 0.0001)
    }

}

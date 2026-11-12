import AppKit
import Foundation
import XCTest
@testable import WeChatAI

// MARK: - 模型解码

final class SnsModelTests: XCTestCase {
    func testTimelineDecodesTextOnlyAndNineImagePosts() throws {
        let json = """
        {
          "posts": [
            {
              "id": "18446744073709551615",
              "author_id": "wxid_example",
              "author_name": "示例昵称",
              "create_time": 1794062712,
              "text": "这是一条纯文字动态",
              "media": [],
              "like_count": 3,
              "comment_count": 1,
              "liked": true,
              "comments": [
                {
                  "comment_id": "comment-1",
                  "user_id": "wxid_example",
                  "user_name": "示例昵称",
                  "text": "一条评论",
                  "create_time": 1794062800,
                  "reply_to": ""
                }
              ],
              "unexpected_field": { "ignored": [1, 2, 3] }
            },
            {
              "id": "15040000000000000002",
              "author_id": "wxid_example",
              "create_time": 1794062700,
              "text": "九张图片",
              "media": [
                {"kind":"image","thumb_key":"t0","url_key":"u0","width":1080,"height":1440},
                {"kind":"image","thumb_key":"t1","url_key":"u1","width":1080,"height":1440},
                {"kind":"image","thumb_key":"t2","url_key":"u2","width":1080,"height":1440},
                {"kind":"image","thumb_key":"t3","url_key":"u3","width":1080,"height":1440},
                {"kind":"image","thumb_key":"t4","url_key":"u4","width":1080,"height":1440},
                {"kind":"image","thumb_key":"t5","url_key":"u5","width":1080,"height":1440},
                {"kind":"image","thumb_key":"t6","url_key":"u6","width":1080,"height":1440},
                {"kind":"image","thumb_key":"t7","url_key":"u7","width":1080,"height":1440},
                {"kind":"video","thumb_key":"t8","url_key":"u8","width":1080,"height":1440,"duration_seconds":12}
              ],
              "like_count": 0,
              "comment_count": 9,
              "comments_truncated": true
            }
          ],
          "cursor": {
            "max_id": "15040000000000000000",
            "first_page_md5": "md5-value",
            "session": "session-value",
            "has_more": true
          },
          "server_config": { "post_mention_limit": 10, "copy_paste_word_limit": 0 },
          "extra": "ignored"
        }
        """
        let page = try JSONDecoder().decode(SnsTimelinePage.self, from: Data(json.utf8))
        XCTAssertEqual(page.posts.count, 2)
        XCTAssertEqual(page.posts[0].id, "18446744073709551615")
        XCTAssertEqual(page.posts[0].authorName, "示例昵称")
        XCTAssertTrue(page.posts[0].isTextOnly)
        XCTAssertEqual(page.posts[0].likeCount, 3)
        XCTAssertTrue(page.posts[0].liked)
        XCTAssertEqual(page.posts[0].comments.first?.text, "一条评论")
        XCTAssertFalse(page.posts[0].commentsTruncated)

        let nine = page.posts[1]
        XCTAssertEqual(nine.media.count, 9)
        XCTAssertEqual(nine.media[8].kind, .video)
        XCTAssertEqual(nine.media[8].durationSeconds, 12)
        XCTAssertTrue(nine.commentsTruncated)
        XCTAssertTrue(nine.hasMoreComments)
        XCTAssertEqual(nine.media[0].aspectRatio, 0.75, accuracy: 0.001)

        XCTAssertEqual(page.cursor?.maxID, "15040000000000000000")
        XCTAssertEqual(page.cursor?.firstPageMD5, "md5-value")
        XCTAssertEqual(page.cursor?.hasMore, true)
        XCTAssertEqual(page.serverConfig?.postMentionLimit, 10)
    }

    func testTolerantDecodingMissingAndMalformedFields() throws {
        // 缺字段、数字写成字符串、未知媒体 kind、数组中夹坏元素都要能降级解析。
        let json = """
        {
          "id": 123456789012345678,
          "author_name": "",
          "like_count": "7",
          "liked": "true",
          "media": [{"kind":"unknown"}, null, "bad"],
          "comments": [{"user_id":"wxid_example","text":"ok"}],
          "comments_truncated": "false"
        }
        """
        let post = try JSONDecoder().decode(SnsPost.self, from: Data(json.utf8))
        XCTAssertEqual(post.id, "123456789012345678")
        XCTAssertEqual(post.likeCount, 7)
        XCTAssertTrue(post.liked)
        XCTAssertEqual(post.media.count, 1)
        XCTAssertEqual(post.media[0].kind, .image)
        XCTAssertEqual(post.comments.count, 1)
        XCTAssertFalse(post.commentsTruncated)
        XCTAssertEqual(post.displayAuthorName, "微信好友")
    }

    func testCursorAndPublishResultDecoding() throws {
        let cursor = try JSONDecoder().decode(
            SnsCursor.self,
            from: Data(#"{"max_id":"18446744073709551615","has_more":false}"#.utf8)
        )
        XCTAssertEqual(cursor.maxID, "18446744073709551615")
        XCTAssertEqual(cursor.hasMore, false)

        let publish = try JSONDecoder().decode(
            SnsPublishResult.self,
            from: Data(#"{"post_id":"15040000000000000001","create_time":1794063000}"#.utf8)
        )
        XCTAssertEqual(publish.postID, "15040000000000000001")
        XCTAssertEqual(publish.createTime, 1794063000)
    }

    func testSyncEventDecodingNativeAndFallback() throws {
        let commentJSON = """
        {
          "type": "sns_comment",
          "account": "wxid_example",
          "data": {
            "post_id": "15040000000000000001",
            "comment": {
              "comment_id": "comment-9",
              "user_id": "wxid_example",
              "user_name": "示例昵称",
              "text": "新评论",
              "create_time": 1794062900
            },
            "source": "native"
          }
        }
        """
        let comment = try JSONDecoder().decode(SnsSyncEvent.self, from: Data(commentJSON.utf8))
        XCTAssertEqual(comment.kind, .comment)
        XCTAssertEqual(comment.postID, "15040000000000000001")
        XCTAssertEqual(comment.comment?.text, "新评论")
        XCTAssertEqual(comment.source, "native")
        XCTAssertFalse(comment.isFallback)

        let likeJSON = """
        {
          "type": "sns_like",
          "account": "wxid_example",
          "data": {
            "post_id": "15040000000000000001",
            "user_id": "wxid_example",
            "cancelled": true,
            "source": "fallback"
          }
        }
        """
        let like = try JSONDecoder().decode(SnsSyncEvent.self, from: Data(likeJSON.utf8))
        XCTAssertEqual(like.kind, .like)
        XCTAssertTrue(like.cancelled)
        XCTAssertTrue(like.isFallback)
        XCTAssertEqual(like.userID, "wxid_example")

        let unknown = try JSONDecoder().decode(
            SnsSyncEvent.self,
            from: Data(#"{"type":"sns_future_event","data":{"post_id":"1"}}"#.utf8)
        )
        XCTAssertEqual(unknown.kind, .unknown)
        XCTAssertEqual(unknown.postID, "1")
    }

    func testTimelinePageDecodesCapturedAt() throws {
        let json = #"{"posts":[],"cursor":{"max_id":"1"},"captured_at":1800000000}"#
        let page = try JSONDecoder().decode(SnsTimelinePage.self, from: Data(json.utf8))
        XCTAssertEqual(page.capturedAt, 1_800_000_000)
        // native 响应不带 captured_at。
        let native = try JSONDecoder().decode(
            SnsTimelinePage.self,
            from: Data(#"{"posts":[],"cursor":{"max_id":"1"}}"#.utf8)
        )
        XCTAssertNil(native.capturedAt)
    }

    func testSnsStatusReadModeAndCaptured() throws {
        let json = #"{"status":"ok","data":{"ready":true,"seed_ready":true,"passive":true,"read_mode":"native","captured":1,"account":"wxid_x"}}"#
        struct Wrapper: Decodable { let data: SnsStatus }
        let status = try JSONDecoder().decode(Wrapper.self, from: Data(json.utf8)).data
        XCTAssertEqual(status.readMode, "native")
        XCTAssertEqual(status.captured, 1)
        XCTAssertTrue(status.canRefreshNatively)
        XCTAssertTrue(status.isPrimed)

        let passive = try JSONDecoder().decode(
            Wrapper.self,
            from: Data(#"{"data":{"ready":true,"passive":true,"read_mode":"passive","captured":0}}"#.utf8)
        ).data
        XCTAssertFalse(passive.canRefreshNatively)
    }

    /// `captured` 只统计任务类型；缺 bodyReturn 锚点的版本（4.2.0.12）captured>0
    /// 但没有请求体，不能显示「原生通道」。bridge 用 `body_captured` 单独表达。
    func testSnsStatusBodyCapturedGatesNativeRefresh() throws {
        struct Wrapper: Decodable { let data: SnsStatus }
        let withoutBody = try JSONDecoder().decode(
            Wrapper.self,
            from: Data(#"{"data":{"ready":true,"seed_ready":true,"read_mode":"native","captured":2,"body_captured":false}}"#.utf8)
        ).data
        XCTAssertEqual(withoutBody.captured, 2)
        XCTAssertEqual(withoutBody.bodyCaptured, false)
        XCTAssertFalse(withoutBody.canRefreshNatively, "只捕获到任务类型、没有请求体时不能主动刷新")

        let withBody = try JSONDecoder().decode(
            Wrapper.self,
            from: Data(#"{"data":{"ready":true,"seed_ready":true,"read_mode":"native","captured":2,"body_captured":true}}"#.utf8)
        ).data
        XCTAssertTrue(withBody.canRefreshNatively)

        // 旧 bridge 不返回 body_captured：退回 captured>0 的旧判定，不能把老版本判死。
        let legacy = try JSONDecoder().decode(
            Wrapper.self,
            from: Data(#"{"data":{"ready":true,"seed_ready":true,"read_mode":"native","captured":1}}"#.utf8)
        ).data
        XCTAssertNil(legacy.bodyCaptured)
        XCTAssertTrue(legacy.canRefreshNatively)
    }

    func testSnsStatusCommentReadyAndCommentResultDecoding() throws {
        let statusJSON = #"{"data":{"ready":true,"seed_ready":true,"write_ready":false,"comment_ready":true}}"#
        struct Wrapper: Decodable { let data: SnsStatus }
        let status = try JSONDecoder().decode(Wrapper.self, from: Data(statusJSON.utf8)).data
        XCTAssertTrue(status.commentReady)
        XCTAssertFalse(status.writeReady, "评论句柄与发布样本是两套独立通道")

        let resultJSON = """
        {"post":{"id":"42","comment_count":2,"comments":[{"comment_id":"88","text":"hi"}]},
         "comment":{"comment_id":"88","text":"hi","user_id":"wxid_self"},
         "comment_id":"88"}
        """
        let result = try JSONDecoder().decode(SnsCommentResult.self, from: Data(resultJSON.utf8))
        XCTAssertEqual(result.post?.id, "42")
        XCTAssertEqual(result.comment?.commentID, "88")
        XCTAssertEqual(result.commentID, "88")

        // 只带回 post 的旧版本 bridge 也要能解码（不因缺 comment_id 失败）。
        let legacy = try JSONDecoder().decode(
            SnsCommentResult.self,
            from: Data(#"{"post":{"id":"43"}}"#.utf8)
        )
        XCTAssertEqual(legacy.post?.id, "43")
        XCTAssertNil(legacy.comment)
        XCTAssertTrue(legacy.commentID.isEmpty)
    }

    func testSnsSettingsDefaultsAndClamping() throws {
        let defaults = try JSONDecoder().decode(SnsSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(defaults.enabled)
        XCTAssertTrue(defaults.autoSync)
        XCTAssertEqual(defaults.syncIntervalSeconds, 60)
        XCTAssertTrue(defaults.autoLoadThumbnails)
        XCTAssertEqual(defaults.defaultVisibility, .partial)
        XCTAssertFalse(defaults.writeEnabled)
        XCTAssertFalse(defaults.publish.enabled)
        XCTAssertEqual(defaults.publish.mode, .windows)
        XCTAssertEqual(defaults.publish.windows.count, 1)
        XCTAssertEqual(defaults.publish.times.count, 1)
        XCTAssertEqual(defaults.publish.times[0].minute, 20 * 60)
        XCTAssertEqual(defaults.publish.maxPerDay, 1)
        XCTAssertEqual(defaults.publish.minIntervalMinutes, 120)
        XCTAssertTrue(defaults.publish.targetUserIDs.isEmpty, "默认不选择发布对象")

        // 旧配置：三档 imageDownload / 三档 mode / public 可见性 / 越界数值都要被安全收敛。
        let json = """
        {
          "enabled": true,
          "autoSync": false,
          "syncIntervalSeconds": 9999,
          "imageDownload": "off",
          "defaultVisibility": "public",
          "writeEnabled": true,
          "publish": {
            "enabled": true,
            "mode": "random",
            "windows": [
              {"startMinute": 600, "endMinute": 700},
              {"start": "22:00", "end": "23:30"}
            ],
            "times": [{"minute": 600}, {"time": "20:00"}],
            "maxPerDay": 99,
            "minIntervalMinutes": -5,
            "targetUserIDs": ["wxid_a", " wxid_a ", "", "wxid_b"]
          },
          "futureKey": 1
        }
        """
        let settings = try JSONDecoder().decode(SnsSettings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.enabled)
        XCTAssertFalse(settings.autoSync)
        XCTAssertEqual(settings.syncIntervalSeconds, 300)
        XCTAssertFalse(settings.autoLoadThumbnails, "旧 imageDownload=off 迁移为不自动加载")
        XCTAssertEqual(settings.defaultVisibility, .partial)
        XCTAssertTrue(settings.writeEnabled)
        XCTAssertTrue(settings.publish.enabled)
        // 旧第三档 random 合并进 windows。
        XCTAssertEqual(settings.publish.mode, .windows)
        XCTAssertEqual(settings.publish.windows.count, 2)
        XCTAssertEqual(settings.publish.windows[1].startMinute, 22 * 60)
        XCTAssertEqual(settings.publish.windows[1].endMinute, 23 * 60 + 30)
        XCTAssertEqual(settings.publish.times.count, 2)
        XCTAssertEqual(settings.publish.maxPerDay, 10)
        XCTAssertEqual(settings.publish.minIntervalMinutes, 0)
        // 发布对象去空白、去重、丢弃空串。
        XCTAssertEqual(settings.publish.targetUserIDs, ["wxid_a", "wxid_b"])

        var low = settings
        low.syncIntervalSeconds = 5
        XCTAssertEqual(low.sanitized.syncIntervalSeconds, 30)

        var publicSettings = SnsSettings()
        publicSettings.defaultVisibility = .public
        XCTAssertEqual(publicSettings.sanitized.defaultVisibility, .partial)

        // 新键优先于旧键。
        let migrated = try JSONDecoder().decode(
            SnsSettings.self,
            from: Data(#"{"imageDownload":"off","autoLoadThumbnails":true}"#.utf8)
        )
        XCTAssertTrue(migrated.autoLoadThumbnails)
        let newKeyWins = try JSONDecoder().decode(
            SnsSettings.self,
            from: Data(#"{"imageDownload":"full","autoLoadThumbnails":false}"#.utf8)
        )
        XCTAssertFalse(newKeyWins.autoLoadThumbnails)
    }

    func testPublishVisibilityResolutionAndWindows() {
        // public 枚举保留，但解析时永远落到 partial/private。
        XCTAssertEqual(SnsVisibility.resolvedPublish(preferred: .partial, hasRecipient: true), .partial)
        XCTAssertEqual(SnsVisibility.resolvedPublish(preferred: .partial, hasRecipient: false), .private)
        XCTAssertEqual(SnsVisibility.resolvedPublish(preferred: .private, hasRecipient: true), .private)
        XCTAssertEqual(SnsVisibility.resolvedPublish(preferred: .public, hasRecipient: true), .partial)
        XCTAssertEqual(SnsVisibility.resolvedPublish(preferred: .public, hasRecipient: false), .private)
        XCTAssertEqual(SnsVisibility.publishOptions, [.partial, .private])

        let window = SnsPublishWindow(startMinute: 9 * 60, endMinute: 22 * 60)
        XCTAssertTrue(window.isValid)
        XCTAssertEqual(window.summary, "09:00–22:00")
        XCTAssertFalse(window.crossesMidnight)
        XCTAssertTrue(window.contains(minuteOfDay: 9 * 60))
        // 与 bridge 一致：包含结束时刻。
        XCTAssertTrue(window.contains(minuteOfDay: 22 * 60))
        XCTAssertFalse(window.contains(minuteOfDay: 22 * 60 + 1))

        // 跨午夜时段：23:00–01:00（不再被静默改写）。
        let overnight = SnsPublishWindow(startMinute: 23 * 60, endMinute: 60).sanitized
        XCTAssertTrue(overnight.isValid)
        XCTAssertTrue(overnight.crossesMidnight)
        XCTAssertEqual(overnight.lengthMinutes, 120)
        XCTAssertTrue(overnight.contains(minuteOfDay: 23 * 60 + 30))
        XCTAssertTrue(overnight.contains(minuteOfDay: 30))
        XCTAssertFalse(overnight.contains(minuteOfDay: 12 * 60))

        // 零长度时段补成 1 小时，避免「看起来配置了却永远不生效」。
        let zero = SnsPublishWindow(startMinute: 600, endMinute: 600).sanitized
        XCTAssertTrue(zero.isValid)
        XCTAssertEqual(zero.lengthMinutes, 60)
    }

    func testPublishWindowsAreCappedToPanelLimit() {
        var settings = SnsPublishSettings()
        settings.windows = (0..<9).map { index in
            SnsPublishWindow(
                id: "window-\(index)",
                startMinute: 8 * 60 + index * 60,
                endMinute: 9 * 60 + index * 60
            )
        }
        let sanitized = settings.sanitized
        XCTAssertEqual(sanitized.windows.count, SnsPublishSettings.maxWindows)
        XCTAssertEqual(sanitized.windows.first?.id, "window-0")
        // 设置页上限与模型归一化必须一致，否则「加不进去却删不掉」。
        XCTAssertEqual(SnsPublishSettings.maxWindows, 6)
    }

    func testDuplicateTimePointsCountOnceForCapacity() {
        var settings = SnsPublishSettings()
        settings.mode = .times
        settings.times = [
            SnsPublishTime(id: "a", minute: 20 * 60),
            SnsPublishTime(id: "b", minute: 20 * 60),
            SnsPublishTime(id: "c", minute: 21 * 60)
        ]
        XCTAssertEqual(settings.dailyCapacity, 2, "同一分钟只排一个槽位，次数不应被重复项虚增")
        XCTAssertTrue(settings.scheduleSummary.contains("2"))
    }

    func testUnlimitedPublishDailyCapAndSlots() {
        var settings = SnsPublishSettings()
        settings.enabled = true
        settings.maxPerDay = 0
        settings.minIntervalMinutes = 60
        settings.windows = [SnsPublishWindow(
            id: "window-unlimited", startMinute: 9 * 60, endMinute: 22 * 60
        )]
        let sanitized = settings.sanitized
        XCTAssertEqual(sanitized.maxPerDay, 0)
        XCTAssertTrue(sanitized.isMaxPerDayUnlimited)
        XCTAssertEqual(sanitized.dailyCapacity, SnsPublishSettings.unlimitedDailyCapacity)
        XCTAssertTrue(sanitized.scheduleSummary.contains("不设上限"))

        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let slots = sanitized.slots(on: day)
        XCTAssertFalse(slots.isEmpty)
        XCTAssertLessThanOrEqual(slots.count, SnsPublishSettings.unlimitedDailyCapacity)
        for (earlier, later) in zip(slots, slots.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later.timeIntervalSince(earlier), 60 * 60 - 1)
        }

        // 0 不会被夹到 1（无上限与「每天 1 次」是两种语义）。
        XCTAssertEqual(sanitized.eligibility(now: day, sentToday: 20, lastSentAt: nil).isAllowed,
                       true)
    }

    func testPublishEligibilityWindowsAndLimits() {
        var publish = SnsPublishSettings()
        publish.windows = [SnsPublishWindow(startMinute: 9 * 60, endMinute: 22 * 60)]
        publish.maxPerDay = 1
        publish.minIntervalMinutes = 360

        let calendar = Calendar.current
        let noon = calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 7, hour: 12, minute: 0
        ))!
        let lateNight = calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 7, hour: 23, minute: 0
        ))!

        XCTAssertEqual(publish.eligibility(now: noon, sentToday: 0, lastSentAt: nil), .disabled)
        publish.enabled = true
        XCTAssertEqual(publish.eligibility(now: noon, sentToday: 0, lastSentAt: nil), .allowed)
        // eligibility 只回答频率；「现在是否到点」由 isDue 独立校验。
        XCTAssertEqual(publish.eligibility(now: lateNight, sentToday: 0, lastSentAt: nil), .allowed)
        XCTAssertEqual(publish.eligibility(now: noon, sentToday: 1, lastSentAt: nil), .dailyLimitReached)
        publish.maxPerDay = 2
        XCTAssertEqual(
            publish.eligibility(now: noon, sentToday: 1, lastSentAt: noon.addingTimeInterval(-60)),
            .intervalTooShort
        )
        XCTAssertEqual(
            publish.eligibility(now: noon, sentToday: 1, lastSentAt: noon.addingTimeInterval(-7 * 3600)),
            .allowed
        )
        publish.windows = []
        XCTAssertFalse(publish.hasValidWindow)
        XCTAssertEqual(publish.eligibility(now: noon, sentToday: 0, lastSentAt: nil), .notScheduled)

        // 固定时间点模式不再被「可发时段」卡死（旧版缺陷：windows 为空时 times 100% 失效）。
        var times = SnsPublishSettings()
        times.enabled = true
        times.mode = .times
        times.windows = []
        times.times = [
            SnsPublishTime(id: "am", minute: 10 * 60),
            SnsPublishTime(id: "pm", minute: 20 * 60)
        ]
        XCTAssertFalse(times.hasValidWindow)
        XCTAssertEqual(times.eligibility(now: noon, sentToday: 0, lastSentAt: nil), .allowed)
        XCTAssertEqual(times.eligibility(now: noon, sentToday: 2, lastSentAt: nil), .dailyLimitReached)

        // 时段内随机排程：数量、顺序、间隔、确定性与到点判定。
        var windows = SnsPublishSettings()
        windows.windows = [SnsPublishWindow(startMinute: 9 * 60, endMinute: 22 * 60)]
        windows.maxPerDay = 3
        windows.minIntervalMinutes = 180
        let slots = windows.slots(on: noon, calendar: calendar)
        XCTAssertEqual(slots.count, 3)
        let minutes = slots.map {
            calendar.component(.hour, from: $0) * 60 + calendar.component(.minute, from: $0)
        }
        XCTAssertEqual(minutes, minutes.sorted())
        XCTAssertTrue(minutes.allSatisfy { (9 * 60..<22 * 60).contains($0) })
        XCTAssertGreaterThanOrEqual(minutes[1] - minutes[0], 180)
        XCTAssertGreaterThanOrEqual(minutes[2] - minutes[1], 180)
        // 同一天/同一设置计算结果稳定（设置页展示的下一次就是调度器实际使用的时刻）。
        XCTAssertEqual(
            windows.slots(on: noon, calendar: calendar).map(\.timeIntervalSince1970),
            slots.map(\.timeIntervalSince1970)
        )
        XCTAssertTrue(windows.isDue(at: slots[0], calendar: calendar))
        XCTAssertFalse(windows.isDue(at: slots[0].addingTimeInterval(1800), calendar: calendar))
    }

    /// 跨午夜时段：23:00–次日 01:00 的排程、下一次触发与到点判定。
    func testCrossMidnightSlotsAndDue() throws {
        var settings = SnsPublishSettings()
        settings.mode = .windows
        settings.windows = [SnsPublishWindow(id: "night", startMinute: 23 * 60, endMinute: 60)]
        settings.maxPerDay = 2
        settings.minIntervalMinutes = 30
        let calendar = self.calendar()
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let slots = settings.slots(on: day, calendar: calendar)
        XCTAssertEqual(slots.count, 2)
        let offsets = slots.map { Int($0.timeIntervalSince(day) / 60) }.sorted()
        for offset in offsets {
            XCTAssertTrue((23 * 60..<25 * 60).contains(offset), "应落在 23:00–次日 01:00，实际 \(offset)")
        }
        XCTAssertGreaterThanOrEqual(offsets[1] - offsets[0], 30)

        // 从 22:00 看下一次：必须晚于当前时刻，且到点判定命中（含次日凌晨的槽位）。
        let evening = calendar.date(byAdding: .minute, value: 22 * 60, to: day)!
        let next = try XCTUnwrap(settings.nextFireDate(after: evening, calendar: calendar))
        XCTAssertGreaterThan(next, evening)
        XCTAssertTrue(settings.isDue(at: next, calendar: calendar))
    }

    /// 到点判定容差：±150s 内算到点，超出则跳过（不补发）。
    func testIsDueToleranceBoundary() throws {
        var settings = SnsPublishSettings()
        settings.mode = .times
        settings.times = [SnsPublishTime(id: "t", minute: 10 * 60)]
        let calendar = self.calendar()
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let slot = try XCTUnwrap(settings.slots(on: day, calendar: calendar).first)
        XCTAssertTrue(settings.isDue(at: slot, calendar: calendar))
        XCTAssertTrue(settings.isDue(at: slot.addingTimeInterval(149), calendar: calendar))
        XCTAssertFalse(settings.isDue(at: slot.addingTimeInterval(151), calendar: calendar))
        XCTAssertTrue(settings.isDue(at: slot.addingTimeInterval(-149), calendar: calendar))
        XCTAssertFalse(settings.isDue(at: slot.addingTimeInterval(-151), calendar: calendar))
    }

    /// 测试用固定时钟（UTC），避免依赖本机时区。
    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testBotSettingsLegacyAndSnsRoundtrip() throws {
        // 旧 profile 没有 sns 键：BotSettings 仍能解码，朋友圈设置回退默认（关闭）。
        let legacy = try JSONDecoder().decode(BotSettings.self, from: Data(#"{"enabled":true}"#.utf8))
        XCTAssertTrue(legacy.enabled)
        XCTAssertNil(legacy.sns)
        XCTAssertFalse(legacy.snsSettings.enabled)
        XCTAssertEqual(legacy.snsSettings.defaultVisibility, .partial)

        var modern = BotSettings()
        modern.snsSettings.enabled = true
        modern.snsSettings.syncIntervalSeconds = 120
        modern.snsSettings.writeEnabled = true
        modern.snsSettings.publish.enabled = true
        modern.snsSettings.publish.maxPerDay = 2
        modern.snsSettings.publish.minIntervalMinutes = 120
        modern.snsSettings.publish.windows = [
            SnsPublishWindow(startMinute: 600, endMinute: 720)
        ]
        modern.snsSettings.publish.targetUserIDs = ["wxid_friend"]
        let data = try JSONEncoder().encode(modern)
        let decoded = try JSONDecoder().decode(BotSettings.self, from: data)
        XCTAssertEqual(decoded.snsSettings.enabled, true)
        XCTAssertEqual(decoded.snsSettings.syncIntervalSeconds, 120)
        XCTAssertEqual(decoded.snsSettings.writeEnabled, true)
        XCTAssertEqual(decoded.snsSettings.publish.enabled, true)
        XCTAssertEqual(decoded.snsSettings.publish.maxPerDay, 2)
        XCTAssertEqual(decoded.snsSettings.publish.minIntervalMinutes, 120)
        XCTAssertEqual(decoded.snsSettings.publish.windows.count, 1)
        XCTAssertEqual(decoded.snsSettings.publish.windows[0].startMinute, 600)
        XCTAssertEqual(decoded.snsSettings.publish.windows[0].endMinute, 720)
        XCTAssertEqual(decoded.snsSettings.publish.targetUserIDs, ["wxid_friend"])
        XCTAssertEqual(decoded.snsSettings.publish.mode, .windows)
        XCTAssertTrue(decoded.snsSettings.autoLoadThumbnails)
    }

    func testPostOrderingDedupesAndSortsByUint64() {
        var newer = SnsPost()
        newer.id = "18446744073709551615"
        newer.createTime = 100
        var older = SnsPost()
        older.id = "9"
        older.createTime = 100
        var oldest = SnsPost()
        oldest.id = "8"
        oldest.createTime = 99

        let sorted = SnsPostOrdering.normalized([oldest, older, newer])
        XCTAssertEqual(sorted.map(\.id), ["18446744073709551615", "9", "8"])

        var richer = SnsPost()
        richer.id = "9"
        richer.createTime = 100
        richer.text = "后到内容"
        var comment = SnsComment()
        comment.commentID = "c1"
        comment.text = "评论"
        richer.comments = [comment]
        richer.commentCount = 1

        let merged = SnsPostOrdering.normalized([older, richer])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].text, "后到内容")
        XCTAssertEqual(merged[0].comments.count, 1)
        XCTAssertEqual(merged[0].commentCount, 1)
        XCTAssertEqual(SnsPostOrdering.compareID("18446744073709551615", "99"), 1)
    }

    /// 重复的时间点只算一个：否则「每天最多 N 次」被虚增，而同一时刻只生成一个槽位。
    func testDuplicateTimePointsAreDeduped() throws {
        var publish = SnsPublishSettings()
        publish.mode = .times
        publish.times = [
            SnsPublishTime(id: "a", minute: 20 * 60),
            SnsPublishTime(id: "b", minute: 20 * 60),
            SnsPublishTime(id: "c", minute: 21 * 60)
        ]
        XCTAssertEqual(publish.sanitized.times.map(\.minute), [20 * 60, 21 * 60])
        XCTAssertEqual(publish.sanitized.dailyCapacity, 2)

        let calendar = self.calendar()
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(publish.sanitized.slots(on: day, calendar: calendar).count, 2)

        let decoded = try JSONDecoder().decode(
            SnsPublishSettings.self,
            from: Data(#"{"mode":"times","times":[{"minute":600},{"minute":600}]}"#.utf8)
        )
        XCTAssertEqual(decoded.times.count, 1)
        XCTAssertEqual(decoded.dailyCapacity, 1)
    }

    /// bridge 原生 `sns_new_post` 事件没有 `post_id`：不同新动态必须得到不同的去重键，
    /// 否则「N 条更新」少算、合并前的事件去重还会误删真实事件。
    func testNativeNewPostEventsWithoutPostIDHaveDistinctIDs() throws {
        func event(postID: String) throws -> SnsSyncEvent {
            let json = """
            {"type":"sns_new_post","account":"wxid_example","data":{
              "post":{"id":"\(postID)","author_id":"wxid_example","create_time":100,"text":"正文"},
              "source":"native"}}
            """
            return try JSONDecoder().decode(SnsSyncEvent.self, from: Data(json.utf8))
        }
        let first = try event(postID: "11")
        let second = try event(postID: "12")
        XCTAssertEqual(first.postID, "")
        XCTAssertEqual(first.id, "sns_new_post|11")
        XCTAssertNotEqual(first.id, second.id)
        // 同一事件重复解码仍是同一个键（重放去重依赖它）。
        XCTAssertEqual(first.id, try event(postID: "11").id)
    }

    /// bridge 的评论 JSON 新增 reply_to_user_id：被回复者 wxid 用于识别「回复我的评论」。
    func testCommentDecodesReplyToUserID() throws {
        let json = #"{"comment_id":"c1","user_id":"wxid_friend","user_name":"好友","# +
            #""text":"回你一句","create_time":100,"reply_to":"c0","reply_to_user_id":"wxid_bot"}"#
        let comment = try JSONDecoder().decode(SnsComment.self, from: Data(json.utf8))
        XCTAssertEqual(comment.replyTo, "c0")
        XCTAssertEqual(comment.replyToUserID, "wxid_bot")

        // 缺字段（旧 bridge）保持空字符串，不丢整条评论。
        let legacy = #"{"comment_id":"c2","user_id":"wxid_friend","text":"旧回包"}"#
        let decoded = try JSONDecoder().decode(SnsComment.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.replyToUserID, "")
    }

    /// cmd46 Type=11 的轻量通知（sns_comment_hint）：没有正文/评论 ID，
    /// 解码后由 MomentsStore 只做「有新回复」提示 + 触发 timeline 刷新，不能当互动候选。
    func testCommentHintEventDecodesWithStableID() throws {
        func decode(_ json: String) throws -> SnsSyncEvent {
            try JSONDecoder().decode(SnsSyncEvent.self, from: Data(json.utf8))
        }
        let base = #"{"type":"sns_comment_hint","account":"wxid_example","data":{"# +
            #""post_id":"1504","from_user":"wxid_friend","from_name":"好友","# +
            #""create_time":1794062800,"reply_to_user_id":"wxid_example","source":"native"}}"#
        let event = try decode(base)
        XCTAssertTrue(event.isCommentHint)
        XCTAssertEqual(event.kind, .unknown, "hint 不能映射成评论事件")
        XCTAssertEqual(event.postID, "1504")
        XCTAssertEqual(event.fromUser, "wxid_friend")
        XCTAssertEqual(event.fromName, "好友")
        XCTAssertEqual(event.eventCreateTime, 1_794_062_800)
        XCTAssertEqual(event.replyToUserID, "wxid_example")
        XCTAssertEqual(event.id, try decode(base).id, "重复轮询必须得到稳定去重键")

        let other = #"{"type":"sns_comment_hint","account":"wxid_example","data":{"# +
            #""post_id":"1504","from_user":"wxid_friend2","from_name":"好友2","# +
            #""create_time":1794062801,"reply_to_user_id":"wxid_example","source":"native"}}"#
        XCTAssertNotEqual(event.id, try decode(other).id, "不同好友/时间的 hint 不能撞键")
    }

    /// sns.db 补全评论的 comment_id 语义未确认（真机 35）：不能作为 reply_comment_id。
    func testCommentReplyTargetGuardRejectsUnconfirmedDatabaseIDs() throws {
        func decode(_ json: String) throws -> SnsComment {
            try JSONDecoder().decode(SnsComment.self, from: Data(json.utf8))
        }
        let native = try decode(#"{"comment_id":"1794234885123456789","user_id":"wxid_a","text":"真不错"}"#)
        XCTAssertTrue(native.canBeReplyTarget)

        // bridge 显式标记：32 位列未确认。
        let marked = try decode(#"{"comment_id":"1794234885123456789","user_id":"wxid_a","text":"真不错","comment_id_unconfirmed":true}"#)
        XCTAssertFalse(marked.canBeReplyTarget)

        // bridge 标记 db 来源但没有 confirmed：仍不能作为回复目标。
        let db = try decode(#"{"comment_id":"1794234885123456789","user_id":"wxid_a","text":"真不错","source":"db"}"#)
        XCTAssertTrue(db.isDatabaseCompleted)
        XCTAssertFalse(db.canBeReplyTarget)

        // 真机手动回复抓包确认 DB 32 位 comment_id（35）可作为回复目标。
        let dbConfirmed = try decode(#"{"comment_id":"35","user_id":"wxid_a","text":"真不错","source":"db","comment_id_confirmed":true}"#)
        XCTAssertTrue(dbConfirmed.isDatabaseCompleted)
        XCTAssertTrue(dbConfirmed.canBeReplyTarget)

        // 原生 timeline 评论的短数字 ID（真机 3/35/67/99）同样合法。
        let nativeShort = try decode(#"{"comment_id":"35","user_id":"wxid_a","text":"真不错"}"#)
        XCTAssertTrue(nativeShort.canBeReplyTarget)

        // 非数字 ID（测试/本地回显以外）与 local- 前缀仍在既有规则内处理。
        let local = try decode(#"{"comment_id":"local-abc","user_id":"wxid_a","text":"真不错"}"#)
        XCTAssertFalse(local.canBeReplyTarget)
    }

    /// 极端数值不能把容错解码变成崩溃（`Int(Double)` 越界会 trap）。
    func testExtremeNumericFieldsFallBackWithoutCrashing() throws {
        let json = #"{"id":1e308,"like_count":1e308,"comment_count":"1e308","create_time":1e308}"#
        let post = try JSONDecoder().decode(SnsPost.self, from: Data(json.utf8))
        XCTAssertEqual(post.id, "")
        XCTAssertEqual(post.likeCount, 0)
        XCTAssertEqual(post.commentCount, 0)
        XCTAssertEqual(post.createTime, 0)
    }
}

// MARK: - SnsClient（URLProtocol mock）

final class SnsMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    static var requests: [URLRequest] = []

    static func reset() {
        handler = nil
        requests = []
    }

    static func bodyObject(of request: URLRequest) -> [String: Any] {
        guard let data = bodyData(of: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        SnsMockURLProtocol.requests.append(request)
        guard let handler = SnsMockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class SnsClientTests: XCTestCase {
    private func makeClient(token: String = "secret-token") -> SnsClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SnsMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return SnsClient(
            baseURL: URL(string: "http://127.0.0.1:58080")!,
            token: token,
            requestTimeout: 5,
            session: session
        )
    }

    private func respond(_ status: Int, _ json: String) {
        SnsMockURLProtocol.handler = { _ in (status, Data(json.utf8)) }
    }

    override func setUp() {
        super.setUp()
        SnsMockURLProtocol.reset()
    }

    override func tearDown() {
        SnsMockURLProtocol.reset()
        super.tearDown()
    }

    func testStatusRequestUsesBearerTokenAndDecodes() async throws {
        respond(200, """
        {"status":"ok","data":{"ready":true,"seed_ready":true,"account":"wxid_example"}}
        """)
        let status = try await makeClient().fetchStatus()
        XCTAssertTrue(status.isPrimed)
        XCTAssertEqual(status.account, "wxid_example")

        let request = try XCTUnwrap(SnsMockURLProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/sns/status")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testTimelineRequestBodyAndDecoding() async throws {
        respond(200, """
        {"status":"ok","data":{"posts":[{"id":"1504","author_name":"示例昵称","create_time":1,"text":"hi","media":[]}],"cursor":{"max_id":"1504","has_more":false}}}
        """)
        let page = try await makeClient().fetchTimeline(
            maxID: "1503",
            firstPageMD5: "md5",
            session: "session",
            refresh: true,
            limit: 25
        )
        XCTAssertEqual(page.posts.count, 1)
        XCTAssertEqual(page.posts[0].id, "1504")
        XCTAssertEqual(page.cursor?.maxID, "1504")

        let body = SnsMockURLProtocol.bodyObject(of: try XCTUnwrap(SnsMockURLProtocol.requests.first))
        XCTAssertEqual(body["max_id"] as? String, "1503")
        XCTAssertEqual(body["first_page_md5"] as? String, "md5")
        XCTAssertEqual(body["session"] as? String, "session")
        XCTAssertEqual(body["refresh"] as? Bool, true)
        XCTAssertEqual(body["limit"] as? Int, 25)
    }

    func testDetailSupportsNestedAndTopLevelPost() async throws {
        respond(200, """
        {"status":"ok","data":{"post":{"id":"42","text":"详情","comments":[{"comment_id":"c1","text":"评论"}]}}}
        """)
        let client = makeClient()
        let nested = try await client.fetchDetail(postID: "42")
        XCTAssertEqual(nested.post.id, "42")
        XCTAssertEqual(nested.post.comments.count, 1)
        XCTAssertFalse(nested.isPartial)

        respond(200, """
        {"status":"ok","post":{"id":"43","text":"顶层"}}
        """)
        let topLevel = try await client.fetchDetail(postID: "43")
        XCTAssertEqual(topLevel.post.id, "43")

        let body = SnsMockURLProtocol.bodyObject(of: try XCTUnwrap(SnsMockURLProtocol.requests.last))
        XCTAssertEqual(body["post_id"] as? String, "43")
    }

    func testDetailCacheSourceIsMarkedPartial() async throws {
        respond(200, #"{"status":"ok","data":{"post":{"id":"44","text":"缓存详情","comments":[]},"source":"cache"}}"#)
        let detail = try await makeClient().fetchDetail(postID: "44")
        XCTAssertEqual(detail.post.id, "44")
        XCTAssertEqual(detail.source, "cache")
        XCTAssertTrue(detail.isPartial)
    }

    func testMediaReturnsLocalFileURL() async throws {
        respond(200, """
        {"status":"ok","file":"file:///tmp/wechatai-sns-test.jpg"}
        """)
        let url = try await makeClient().fetchMedia(postID: "42", mediaIndex: 2, variant: .full)
        XCTAssertEqual(url.path, "/tmp/wechatai-sns-test.jpg")

        let body = SnsMockURLProtocol.bodyObject(of: try XCTUnwrap(SnsMockURLProtocol.requests.first))
        XCTAssertEqual(body["post_id"] as? String, "42")
        XCTAssertEqual(body["media_index"] as? Int, 2)
        XCTAssertEqual(body["variant"] as? String, "full")
    }

    func testSyncAndPublishBodies() async throws {
        respond(200, """
        {"status":"ok","events":[{"type":"sns_like","account":"wxid_example","data":{"post_id":"42","source":"native"}}],"cursor":{"max_id":"42"}}
        """)
        let client = makeClient()
        let sync = try await client.fetchSync(waitMS: 0)
        XCTAssertEqual(sync.events.count, 1)
        XCTAssertEqual(sync.events[0].kind, .like)
        XCTAssertEqual(
            SnsMockURLProtocol.bodyObject(of: try XCTUnwrap(SnsMockURLProtocol.requests.last))["wait_ms"] as? Int,
            0
        )

        respond(200, #"{"status":"ok","data":{"post_id":"99","create_time":1700000000}}"#)
        let publish = try await client.publish(
            text: "正文",
            visibility: .partial,
            visibleUserIDs: ["wxid_friend"],
            clientID: "cid-1"
        )
        XCTAssertEqual(publish.postID, "99")
        let body = SnsMockURLProtocol.bodyObject(of: try XCTUnwrap(SnsMockURLProtocol.requests.last))
        XCTAssertEqual(body["text"] as? String, "正文")
        XCTAssertEqual(body["visibility"] as? String, "partial")
        XCTAssertEqual(body["visible_user_ids"] as? [String], ["wxid_friend"])
        XCTAssertEqual((body["media"] as? [Any])?.count, 0)
        XCTAssertEqual(body["client_id"] as? String, "cid-1")

        respond(200, #"{"status":"ok","data":{"post_id":"100","create_time":1700000000}}"#)
        _ = try await client.publish(text: "仅自己", visibility: .private, clientID: "cid-2")
        let privateBody = SnsMockURLProtocol.bodyObject(
            of: try XCTUnwrap(SnsMockURLProtocol.requests.last)
        )
        XCTAssertEqual(privateBody["visibility"] as? String, "private")
        XCTAssertNil(privateBody["visible_user_ids"])
    }

    func testCommentRequestBodyAndDecoding() async throws {
        respond(200, """
        {"status":"ok","data":{
          "post":{"id":"42","text":"正文","comment_count":2,
                  "comments":[{"comment_id":"88","text":"hello","user_id":"wxid_self"}]},
          "comment":{"comment_id":"88","text":"hello","user_id":"wxid_self"},
          "comment_id":"88"}}
        """)
        let client = makeClient()
        let result = try await client.comment(postID: "42", text: "hello")
        XCTAssertEqual(result.post?.id, "42")
        XCTAssertEqual(result.comment?.text, "hello")
        XCTAssertEqual(result.commentID, "88")
        let body = SnsMockURLProtocol.bodyObject(of: try XCTUnwrap(SnsMockURLProtocol.requests.last))
        XCTAssertEqual(body["post_id"] as? String, "42")
        XCTAssertEqual(body["text"] as? String, "hello")
        XCTAssertEqual(body["confirm"] as? Bool, true)
        XCTAssertNil(body["reply_comment_id"])

        respond(200, #"{"status":"ok","data":{"post":{"id":"42"},"comment_id":"89"}}"#)
        _ = try await client.comment(postID: "42", text: "re", replyCommentID: "88")
        let replyBody = SnsMockURLProtocol.bodyObject(
            of: try XCTUnwrap(SnsMockURLProtocol.requests.last)
        )
        XCTAssertEqual(replyBody["reply_comment_id"] as? String, "88")
        XCTAssertEqual(replyBody["confirm"] as? Bool, true)
    }

    /// 评论写路径的错误必须可行动：句柄未捕获 / 动态过期 / 回复目标消失分别有独立文案。
    func testCommentErrorMapping() async throws {
        let cases: [(Int, String, SnsClientError)] = [
            (503, #"{"status":"failed","code":"sns_comment_unavailable","error":"句柄未就绪"}"#,
             .commentUnavailable),
            (404, #"{"status":"failed","code":"sns_post_not_found","error":"动态不存在"}"#,
             .postNotFound),
            (404, #"{"status":"failed","code":"sns_comment_not_found","error":"评论不存在"}"#,
             .replyTargetNotFound),
            (429, #"{"status":"failed","code":"sns_rate_limited","error":"太快"}"#,
             .rateLimited),
            (502, #"{"status":"failed","code":"sns_native_rejected","error":"微信接口返回错误码 201"}"#,
             .operationFailed("微信接口返回错误码 201"))
        ]
        for (status, json, expected) in cases {
            respond(status, json)
            do {
                _ = try await makeClient().comment(postID: "42", text: "hi")
                XCTFail("expected error for HTTP \(status)")
            } catch let error as SnsClientError {
                XCTAssertEqual(error, expected, "HTTP \(status)")
            }
        }
    }

    func testHTTPStatusMapping() async throws {
        let cases: [(Int, SnsClientError)] = [
            (401, .unauthorized),
            (403, .forbidden),
            (404, .featureDisabled),
            (429, .rateLimited),
            (502, .badGateway),
            (503, .notReady),
            (504, .timedOut)
        ]
        for (code, expected) in cases {
            respond(code, "{}")
            do {
                _ = try await makeClient().fetchStatus()
                XCTFail("expected error for HTTP \(code)")
            } catch let error as SnsClientError {
                XCTAssertEqual(error, expected, "HTTP \(code)")
            }
        }
    }

    /// 写路径的错误语义必须可行动：503 不再一律说「请先打开一次朋友圈」。
    func testWriteChannelErrorsMapToActionableCases() async throws {
        respond(503, #"{"status":"failed","code":"sns_publish_unavailable","error":"写通道未打通"}"#)
        do {
            _ = try await makeClient().publish(text: "正文", visibility: .private, clientID: "cid-3")
            XCTFail("expected publishUnavailable")
        } catch let error as SnsClientError {
            XCTAssertEqual(error, .publishUnavailable)
        }

        respond(409, #"{"status":"failed","code":"sns_outside_window","error":"时段外"}"#)
        do {
            _ = try await makeClient().publish(text: "正文", visibility: .private, clientID: "cid-3")
            XCTFail("expected outsideWindow")
        } catch let error as SnsClientError {
            XCTAssertEqual(error, .outsideWindow)
        }

        respond(429, #"{"status":"failed","code":"sns_daily_limit","error":"上限"}"#)
        do {
            _ = try await makeClient().publish(text: "正文", visibility: .private, clientID: "cid-3")
            XCTFail("expected dailyLimit")
        } catch let error as SnsClientError {
            XCTAssertEqual(error, .dailyLimit)
        }

        // 同一状态码在读路径仍是「微信未就绪」。
        respond(503, "{}")
        do {
            _ = try await makeClient().fetchStatus()
            XCTFail("expected notReady")
        } catch let error as SnsClientError {
            XCTAssertEqual(error, .notReady)
        }
    }

    func testPublish404MapsToWriteDisabled() async throws {
        respond(404, "{}")
        do {
            _ = try await makeClient().publish(text: "正文", visibility: .private, clientID: "cid-3")
            XCTFail("expected writeDisabled")
        } catch let error as SnsClientError {
            XCTAssertEqual(error, .writeDisabled)
        }
    }

    func testEnvelopeErrorMapping() async throws {
        respond(200, #"{"status":"error","error":"not_ready","message":"needs priming"}"#)
        do {
            _ = try await makeClient().fetchStatus()
            XCTFail("expected notReady")
        } catch let error as SnsClientError {
            XCTAssertEqual(error, .notReady)
        }

        respond(200, #"{"status":"error","error":"rate_limited"}"#)
        do {
            _ = try await makeClient().fetchStatus()
            XCTFail("expected rateLimited")
        } catch let error as SnsClientError {
            XCTAssertEqual(error, .rateLimited)
        }
    }

    func testTransportAndInvalidJSONErrors() async throws {
        SnsMockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do {
            _ = try await makeClient().fetchStatus()
            XCTFail("expected timedOut")
        } catch let error as SnsClientError {
            XCTAssertEqual(error, .timedOut)
        }

        SnsMockURLProtocol.handler = { _ in (200, Data("not json".utf8)) }
        do {
            _ = try await makeClient().fetchStatus()
            XCTFail("expected invalidResponse")
        } catch let error as SnsClientError {
            guard case .invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        }
    }

    func testEmptyTokenOmitsAuthorizationHeader() async throws {
        respond(200, #"{"status":"ok","data":{"ready":true,"seed_ready":true}}"#)
        _ = try await makeClient(token: "").fetchStatus()
        let request = try XCTUnwrap(SnsMockURLProtocol.requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testLocalFileURLHelper() {
        XCTAssertEqual(SnsClient.localFileURL(from: "file:///tmp/a.jpg")?.path, "/tmp/a.jpg")
        XCTAssertEqual(SnsClient.localFileURL(from: "/tmp/a.jpg")?.path, "/tmp/a.jpg")
        XCTAssertNil(SnsClient.localFileURL(from: ""))
        XCTAssertNil(SnsClient.localFileURL(from: "https://example.com/a.jpg"))
    }

    /// 读路径 502 语义过载（docs/sns.md §8）：解析/发送失败与媒体下载失败文案要分开。
    func testReadPath502CodesDistinguishParseFromMedia() async throws {
        respond(502, #"{"status":"failed","code":"sns_parse_failed","error":"朋友圈回包解析失败"}"#)
        do {
            _ = try await makeClient().fetchTimeline()
            XCTFail("expected bridgeFailure")
        } catch let error as SnsClientError {
            XCTAssertEqual(error, .bridgeFailure)
        }

        respond(502, #"{"status":"failed","code":"sns_media_failed","error":"朋友圈媒体下载失败"}"#)
        do {
            _ = try await makeClient().fetchMedia(postID: "42", mediaIndex: 0, variant: .thumb)
            XCTFail("expected badGateway")
        } catch let error as SnsClientError {
            XCTAssertEqual(error, .badGateway)
        }

        // 没有 code 时无法判断，保持旧文案（不能误导成解析失败）。
        respond(502, "{}")
        do {
            _ = try await makeClient().fetchStatus()
            XCTFail("expected badGateway")
        } catch let error as SnsClientError {
            XCTAssertEqual(error, .badGateway)
        }
    }

    /// 读路径 404 按 code 细分（写目标动态/回复目标/媒体），不再一律「未启用」。
    func testReadPath404CodesAnd403WriteDisabled() async throws {
        respond(404, #"{"status":"failed","code":"sns_post_not_found","error":"未找到该动态"}"#)
        do {
            _ = try await makeClient().fetchDetail(postID: "42")
            XCTFail("expected postNotFound")
        } catch let error as SnsClientError {
            XCTAssertEqual(error, .postNotFound)
        }

        respond(404, #"{"status":"failed","code":"sns_media_not_found","error":"该动态没有可下载的媒体"}"#)
        do {
            _ = try await makeClient().fetchMedia(postID: "42", mediaIndex: 0, variant: .thumb)
            XCTFail("expected badGateway")
        } catch let error as SnsClientError {
            XCTAssertEqual(error, .badGateway)
        }

        // hook 层写开关关闭是 403（正常路径是 404），文案必须可行动。
        respond(403, #"{"status":"failed","code":"sns_write_disabled","error":"朋友圈写操作未开启"}"#)
        do {
            _ = try await makeClient().publish(text: "正文", visibility: .private, clientID: "cid")
            XCTFail("expected writeDisabled")
        } catch let error as SnsClientError {
            XCTAssertEqual(error, .writeDisabled)
        }
    }

    /// 读路径 503 按 code 细分：缺锚点/媒体通道未就绪不是「请先打开一次朋友圈」。
    func testReadPath503CodesAreActionable() async throws {
        respond(503, #"{"status":"failed","code":"sns_channel_unconfigured","error":"当前 Hook 版本未配置该朋友圈任务的发送锚点"}"#)
        do {
            _ = try await makeClient().fetchTimeline()
            XCTFail("expected operationFailed")
        } catch let error as SnsClientError {
            guard case .operationFailed(let message) = error else {
                return XCTFail("expected operationFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("未配置"))
        }

        respond(503, #"{"status":"failed","code":"sns_unsupported","error":"当前 Hook 版本不支持朋友圈"}"#)
        do {
            _ = try await makeClient().fetchStatus()
            XCTFail("expected operationFailed")
        } catch let error as SnsClientError {
            guard case .operationFailed = error else {
                return XCTFail("expected operationFailed, got \(error)")
            }
        }

        respond(503, #"{"status":"failed","code":"sns_media_decrypt_pending","error":"解密尚未就绪"}"#)
        do {
            _ = try await makeClient().fetchMedia(postID: "42", mediaIndex: 0, variant: .full)
            XCTFail("expected badGateway")
        } catch let error as SnsClientError {
            XCTAssertEqual(error, .badGateway)
        }
    }

    /// bridge 失败体里 `code` 是错误码、`error` 是给人看的文案：envelope 错误必须按
    /// `code` 匹配，否则会退化成「未知错误」。
    func testEnvelopePrefersCodeOverHumanMessage() async throws {
        respond(200, #"{"status":"failed","code":"sns_rate_limited","error":"操作太频繁，请 3 秒后重试"}"#)
        do {
            _ = try await makeClient().fetchSync()
            XCTFail("expected rateLimited")
        } catch let error as SnsClientError {
            XCTAssertEqual(error, .rateLimited)
        }

        respond(200, #"{"status":"failed","code":"sns_write_disabled","error":"朋友圈写操作未开启"}"#)
        do {
            _ = try await makeClient().publish(text: "正文", visibility: .private, clientID: "cid")
            XCTFail("expected writeDisabled")
        } catch let error as SnsClientError {
            XCTAssertEqual(error, .writeDisabled)
        }

        respond(200, #"{"status":"failed","code":"sns_parse_failed","error":"朋友圈同步回包解析失败"}"#)
        do {
            _ = try await makeClient().fetchSync()
            XCTFail("expected bridgeFailure")
        } catch let error as SnsClientError {
            XCTAssertEqual(error, .bridgeFailure)
        }
    }
}

// MARK: - MomentsStore（mock 客户端）

/// 单次放行的测试闩锁：让「请求挂起期间切号」这类竞态可以稳定复现。
private final class SnsTestLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var held = false

    var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return held
    }

    func hold() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            self.continuation = continuation
            held = true
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        let waiter = continuation
        continuation = nil
        held = false
        lock.unlock()
        waiter?.resume()
    }
}

private final class MockSnsClient: SnsClientProtocol {
    var statusResult: Result<SnsStatus, Error> = .success(
        SnsStatus(ready: true, seedReady: true, writeReady: false, account: "wxid_example")
    )
    var pages: [SnsTimelinePage] = []
    var syncResults: [SnsSyncResult] = []
    var detailResult: Result<SnsPost, Error>?
    /// bridge 详情来源：native | cache。
    var detailSource = "native"
    var publishResult: Result<SnsPublishResult, Error> = .success(
        SnsPublishResult(postID: "pub-1", createTime: 1_800_000_000)
    )
    var commentResult: Result<SnsCommentResult, Error> = .success(SnsCommentResult())
    var mediaResult: Result<URL, Error> = .failure(SnsClientError.badGateway)

    /// 依次返回的详情（优先于 `detailResult`），用于「请求期间切号」竞态用例。
    var detailQueue: [SnsPost] = []
    /// 让下一次 `fetchDetail` 挂起，直到测试 `detailHoldLatch.release()`。
    var holdNextDetail = false
    let detailHoldLatch = SnsTestLatch()
    /// 按调用顺序挂起多次 `fetchDetail`（nil 表示该次不挂起），用于「连续切换动态」竞态用例。
    var detailHoldLatches: [SnsTestLatch?] = []
    /// 按调用顺序挂起多次 `fetchTimeline`（nil 表示该次不挂起），用于「旧请求返回不能
    /// 结束新请求加载态」的竞态用例。
    var pageHoldLatches: [SnsTestLatch?] = []
    /// `fetchSync` 返回前在主线程执行的钩子（模拟请求在途时切号/改设置）。
    var onFetchSync: (@MainActor () -> Void)?

    private(set) var timelineCalls: [(maxID: String, refresh: Bool)] = []
    private(set) var syncCalls = 0
    private(set) var mediaCalls = 0
    private(set) var publishCalls: [(text: String, visibility: SnsVisibility,
                                     visibleUserIDs: [String], clientID: String)] = []
    private(set) var commentCalls: [(postID: String, text: String, replyCommentID: String)] = []

    func fetchStatus() async throws -> SnsStatus {
        try statusResult.get()
    }

    func fetchTimeline(
        maxID: String,
        firstPageMD5: String,
        session: String,
        refresh: Bool,
        limit: Int
    ) async throws -> SnsTimelinePage {
        timelineCalls.append((maxID, refresh))
        guard !pages.isEmpty else { return SnsTimelinePage() }
        let page = pages.removeFirst()
        if !pageHoldLatches.isEmpty, let latch = pageHoldLatches.removeFirst() {
            await latch.hold()
        }
        return page
    }

    func fetchDetail(postID: String) async throws -> SnsDetailResult {
        let post: SnsPost
        if !detailQueue.isEmpty {
            post = detailQueue.removeFirst()
        } else {
            guard let detailResult else {
                throw SnsClientError.invalidResponse("no detail")
            }
            post = try detailResult.get()
        }
        if !detailHoldLatches.isEmpty {
            if let latch = detailHoldLatches.removeFirst() {
                await latch.hold()
            }
        } else if holdNextDetail {
            holdNextDetail = false
            await detailHoldLatch.hold()
        }
        return SnsDetailResult(post: post, source: detailSource)
    }

    func fetchMedia(postID: String, mediaIndex: Int, variant: SnsMediaVariant) async throws -> URL {
        mediaCalls += 1
        return try mediaResult.get()
    }

    func fetchSync(waitMS: Int) async throws -> SnsSyncResult {
        syncCalls += 1
        if let onFetchSync {
            await MainActor.run { onFetchSync() }
        }
        guard !syncResults.isEmpty else { return SnsSyncResult() }
        return syncResults.removeFirst()
    }

    func publish(
        text: String,
        visibility: SnsVisibility,
        visibleUserIDs: [String],
        clientID: String
    ) async throws -> SnsPublishResult {
        publishCalls.append((text, visibility, visibleUserIDs, clientID))
        return try publishResult.get()
    }

    func comment(postID: String, text: String, replyCommentID: String) async throws -> SnsCommentResult {
        commentCalls.append((postID, text, replyCommentID))
        return try commentResult.get()
    }
}

@MainActor
final class SnsMomentsStoreTests: XCTestCase {
    private func makeSettings(
        enabled: Bool = true,
        writeEnabled: Bool = false,
        autoLoadThumbnails: Bool = true
    ) -> SnsSettings {
        SnsSettings(
            enabled: enabled,
            autoSync: false,
            syncIntervalSeconds: 60,
            autoLoadThumbnails: autoLoadThumbnails,
            defaultVisibility: .partial,
            writeEnabled: writeEnabled
        )
    }

    private func makeStore(
        client: MockSnsClient,
        settings: SnsSettings? = nil,
        accountID: String = "wxid_example"
    ) -> MomentsStore {
        let store = MomentsStore(client: client)
        store.apply(settings: settings ?? makeSettings(), onebot: OneBotSettings(), accountID: accountID)
        return store
    }

    private func makePost(_ id: String, createTime: Int, text: String = "正文") -> SnsPost {
        var post = SnsPost()
        post.id = id
        post.createTime = createTime
        post.text = text
        post.authorName = "示例昵称"
        return post
    }

    private func makePage(
        _ posts: [SnsPost],
        maxID: String = "0",
        hasMore: Bool = false,
        capturedAt: Int? = nil
    ) -> SnsTimelinePage {
        SnsTimelinePage(
            posts: posts,
            cursor: SnsCursor(maxID: maxID, hasMore: hasMore),
            capturedAt: capturedAt
        )
    }

    private func makeCommentHint(
        postID: String,
        fromUser: String = "wxid_friend",
        fromName: String = "好友",
        createTime: Int = 200,
        replyToUserID: String = "wxid_example"
    ) -> SnsSyncEvent {
        var event = SnsSyncEvent(type: "sns_comment_hint", postID: postID)
        event.fromUser = fromUser
        event.fromName = fromName
        event.eventCreateTime = createTime
        event.replyToUserID = replyToUserID
        return event
    }

    func testRefreshForwardsPostsToMemoryIngestHandler() async {
        let client = MockSnsClient()
        let post = makePost("p1", createTime: 200)
        client.pages = [
            makePage([post], maxID: "1", hasMore: true),
            makePage([makePost("p0", createTime: 100)], maxID: "0", hasMore: false)
        ]
        let store = makeStore(client: client)
        var calls: [([SnsPost], String)] = []
        store.memoryIngestHandler = { posts, selfID in
            calls.append((posts, selfID))
        }

        await store.loadInitialIfNeeded()
        for _ in 0..<20 where calls.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0.map(\.id), ["p1"])
        XCTAssertEqual(calls.first?.1, "wxid_example")

        // 「加载更多」只读更旧的一页，不重复灌入记忆。
        await store.loadMore()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(calls.count, 1)
    }

    func testInitialLoadAndPaginationDedupesAndSorts() async {
        let client = MockSnsClient()
        let older = makePost("2", createTime: 200)
        let oldest = makePost("1", createTime: 100)
        let newest = makePost("3", createTime: 300)
        client.pages = [
            makePage([older, newest], maxID: "2", hasMore: true),
            makePage([oldest, older], maxID: "1", hasMore: false)
        ]
        let store = makeStore(client: client)

        await store.loadInitialIfNeeded()
        XCTAssertEqual(store.posts.map(\.id), ["3", "2"])
        XCTAssertTrue(store.hasMore)
        XCTAssertEqual(client.timelineCalls.first?.maxID, "0")
        XCTAssertEqual(client.timelineCalls.first?.refresh, false)

        await store.loadMore()
        XCTAssertEqual(store.posts.map(\.id), ["3", "2", "1"])
        XCTAssertFalse(store.hasMore)
        XCTAssertEqual(client.timelineCalls.count, 2)
        XCTAssertEqual(client.timelineCalls.last?.maxID, "2")
        XCTAssertEqual(Set(store.posts.map(\.id)).count, 3)
    }

    /// 被动分页会重复返回同一页：没有新动态且游标未前进时必须停止「加载更多」，
    /// 否则按钮会一直转圈、反复请求同一页。
    func testLoadMoreStopsWhenPassivePageRepeats() async {
        let client = MockSnsClient()
        let page = makePage([makePost("10", createTime: 100)], maxID: "10", hasMore: true)
        client.pages = [page, page]
        let store = makeStore(client: client)

        await store.loadInitialIfNeeded()
        XCTAssertTrue(store.hasMore)

        await store.loadMore()
        XCTAssertEqual(store.posts.map(\.id), ["10"])
        XCTAssertFalse(store.hasMore)
    }

    /// 分页返回更旧的新动态时 hasMore 仍按 bridge 游标为准（不能误判为「卡住」）。
    func testLoadMoreKeepsHasMoreWhenNewPageArrives() async {
        let client = MockSnsClient()
        client.pages = [
            makePage([makePost("10", createTime: 100)], maxID: "10", hasMore: true),
            makePage([makePost("9", createTime: 90)], maxID: "9", hasMore: true)
        ]
        let store = makeStore(client: client)

        await store.loadInitialIfNeeded()
        await store.loadMore()
        XCTAssertEqual(store.posts.map(\.id), ["10", "9"])
        XCTAssertTrue(store.hasMore)
    }

    /// 回归：`/sns/sync` 返回的是同步游标（key_buf），不能覆盖时间线的 max_id 游标，
    /// 否则「加载更多」会因为 maxID 为空而永远无法翻页。
    func testSyncCursorDoesNotClobberTimelineCursor() async {
        let client = MockSnsClient()
        client.pages = [
            makePage([makePost("10", createTime: 100)], maxID: "10", hasMore: true),
            makePage([makePost("9", createTime: 90)], maxID: "9", hasMore: false)
        ]
        client.syncResults = [
            SnsSyncResult(events: [], cursor: SnsCursor(maxID: "", hasMore: true))
        ]
        let store = makeStore(client: client)
        await store.loadInitialIfNeeded()
        XCTAssertTrue(store.hasMore)
        await store.loadMore()
        XCTAssertEqual(store.posts.map(\.id), ["10", "9"])
        XCTAssertEqual(client.timelineCalls.last?.maxID, "10")
    }

    func testRefreshReplacesFeedAndPreservesSortOrder() async {
        let client = MockSnsClient()
        client.pages = [
            makePage([makePost("5", createTime: 500)], maxID: "5", hasMore: false),
            makePage([makePost("6", createTime: 600), makePost("4", createTime: 400)], maxID: "6", hasMore: false)
        ]
        let store = makeStore(client: client)
        await store.loadInitialIfNeeded()
        XCTAssertEqual(store.posts.map(\.id), ["5"])

        await store.refresh()
        XCTAssertEqual(store.posts.map(\.id), ["6", "4"])
        XCTAssertEqual(client.timelineCalls.last?.refresh, true)
    }

    func testStatusNotPrimedShowsPrimingGuide() async {
        let client = MockSnsClient()
        client.statusResult = .success(SnsStatus(ready: true, seedReady: false))
        let store = makeStore(client: client)

        await store.loadInitialIfNeeded()
        XCTAssertTrue(store.primingRequired)
        XCTAssertTrue(store.posts.isEmpty)
        XCTAssertNil(store.error)
        XCTAssertTrue(client.timelineCalls.isEmpty)
    }

    /// 捕获弹窗轮询用的轻量检测：只查 `/sns/status`，不拉时间线。
    func testRefreshPrimingStatusOnlyQueriesStatus() async {
        let client = MockSnsClient()
        client.statusResult = .success(SnsStatus(ready: false, seedReady: false))
        let store = makeStore(client: client)

        let primed = await store.refreshPrimingStatus()
        XCTAssertFalse(primed)
        XCTAssertTrue(store.primingRequired)
        XCTAssertNotNil(store.status)
        XCTAssertTrue(client.timelineCalls.isEmpty, "轻量检测不应拉时间线")

        client.statusResult = .success(SnsStatus(ready: true, seedReady: true))
        let becamePrimed = await store.refreshPrimingStatus()
        XCTAssertTrue(becamePrimed)
        XCTAssertFalse(store.primingRequired)
        XCTAssertTrue(client.timelineCalls.isEmpty)
    }

    func testRefreshPrimingStatusDisabledDoesNotRequest() async {
        let client = MockSnsClient()
        let store = makeStore(client: client, settings: makeSettings(enabled: false))
        let primed = await store.refreshPrimingStatus()
        XCTAssertFalse(primed)
        XCTAssertNil(store.status)
    }

    func testRefreshPrimingStatusFailureKeepsLastKnownState() async {
        let client = MockSnsClient()
        client.statusResult = .success(SnsStatus(ready: true, seedReady: true))
        let store = makeStore(client: client)
        let first = await store.refreshPrimingStatus()
        XCTAssertTrue(first)

        client.statusResult = .failure(SnsClientError.timedOut)
        let fallback = await store.refreshPrimingStatus()
        XCTAssertTrue(fallback, "读取失败时保留上一次已知就绪状态")
        XCTAssertNotNil(store.status)
    }

    /// 启动检测只信本次请求成功返回的状态：机器人重启后不能拿上一次运行的「已就绪」误判。
    func testFetchPrimingStatusForStartupDoesNotTrustStaleState() async {
        let client = MockSnsClient()
        client.statusResult = .success(SnsStatus(ready: true, seedReady: true))
        let store = makeStore(client: client)
        let fresh = await store.fetchPrimingStatusForStartup()
        XCTAssertEqual(fresh?.isPrimed, true)

        client.statusResult = .failure(SnsClientError.timedOut)
        let stale = await store.fetchPrimingStatusForStartup()
        XCTAssertNil(stale, "本次请求失败时返回 nil，交给启动检测继续等待")
        XCTAssertNotNil(store.status, "失败只影响启动检测，不清空弹窗/页面展示用的旧状态")

        let fallback = await store.refreshPrimingStatus()
        XCTAssertTrue(fallback, "常规刷新仍保留上一次已知状态")
    }

    func testNotReadyErrorMapsToPriming() async {
        let client = MockSnsClient()
        client.statusResult = .failure(SnsClientError.notReady)
        let store = makeStore(client: client)

        await store.loadInitialIfNeeded()
        XCTAssertTrue(store.primingRequired)
        XCTAssertNil(store.error)
    }

    func testErrorStateForUnauthorized() async {
        let client = MockSnsClient()
        client.statusResult = .failure(SnsClientError.unauthorized)
        let store = makeStore(client: client)

        await store.refresh()
        XCTAssertFalse(store.primingRequired)
        XCTAssertNotNil(store.error)
        XCTAssertTrue(store.posts.isEmpty)
    }

    func testDisabledFeatureDoesNotRequest() async {
        let client = MockSnsClient()
        let store = makeStore(client: client, settings: makeSettings(enabled: false))
        await store.loadInitialIfNeeded()
        XCTAssertFalse(store.isEnabled)
        XCTAssertEqual(client.syncCalls, 0)
        XCTAssertTrue(client.timelineCalls.isEmpty)
    }

    func testSyncEventsMergeCommentsLikesAndNewPosts() async {
        let client = MockSnsClient()
        client.pages = [makePage([makePost("10", createTime: 100)], maxID: "10", hasMore: false)]

        var comment = SnsComment()
        comment.commentID = "c1"
        comment.userName = "示例昵称"
        comment.text = "新评论"
        comment.createTime = 120
        let commentEvent = SnsSyncEvent(type: "sns_comment", postID: "10", comment: comment)
        let likeEvent = SnsSyncEvent(type: "sns_like", postID: "10", userID: "wxid_other")
        let newPost = makePost("11", createTime: 130, text: "同步到的新动态")
        let postEvent = SnsSyncEvent(type: "sns_new_post", postID: "11", post: newPost)
        client.syncResults = [
            SnsSyncResult(),
            SnsSyncResult(events: [commentEvent, likeEvent, postEvent]),
            SnsSyncResult(events: [commentEvent, likeEvent, postEvent])
        ]

        let store = makeStore(client: client)
        await store.loadInitialIfNeeded()
        await store.pollSync()

        XCTAssertEqual(store.posts.map(\.id), ["11", "10"])
        let post = try? XCTUnwrap(store.posts.first(where: { $0.id == "10" }))
        XCTAssertEqual(post?.comments.count, 1)
        XCTAssertEqual(post?.commentCount, 1)
        XCTAssertEqual(post?.likeCount, 1)
        XCTAssertEqual(store.syncEvents.count, 3)

        // 重复投递同一批事件：点赞/评论计数不再累加，事件列表按 id 去重。
        await store.pollSync()
        let updated = store.posts.first(where: { $0.id == "10" })
        XCTAssertEqual(updated?.comments.count, 1)
        XCTAssertEqual(updated?.commentCount, 1)
        XCTAssertEqual(updated?.likeCount, 1, "重复批次不能再累加点赞")
        XCTAssertEqual(store.syncEvents.count, 3)
    }

    /// 同一批 `/sns/sync` 被重复轮询（或轮询与 WS 同时投递）时，点赞/评论只能累加一次。
    func testReplayedSyncBatchDoesNotDoubleCount() async {
        let client = MockSnsClient()
        client.pages = [makePage([makePost("10", createTime: 100)], maxID: "10", hasMore: false)]
        let store = makeStore(client: client)
        await store.loadInitialIfNeeded()

        var comment = SnsComment()
        comment.commentID = "c1"
        comment.text = "新评论"
        comment.createTime = 120
        let batch = SnsSyncResult(events: [
            SnsSyncEvent(type: "sns_like", postID: "10", userID: "wxid_other"),
            SnsSyncEvent(type: "sns_comment", postID: "10", comment: comment),
            // 只有计数、没有评论对象的旧形态事件（不能按 comment.id 去重）。
            SnsSyncEvent(type: "sns_comment", postID: "10")
        ])
        client.syncResults = [batch, batch]
        await store.pollSync()
        await store.pollSync()

        let post = store.posts.first(where: { $0.id == "10" })
        XCTAssertEqual(post?.likeCount, 1, "重放批次不能再累加点赞")
        XCTAssertEqual(post?.comments.count, 1)
        XCTAssertEqual(post?.commentCount, 2, "带评论 +1、纯计数 +1；重放不再累加")
        XCTAssertEqual(store.syncEvents.count, 3)
        XCTAssertEqual(store.lastSyncAt != nil, true)
    }

    /// 不同用户的点赞是不同事件，不能被合并前的事件去重误删。
    func testDistinctLikeEventsAreCountedSeparately() async {
        let client = MockSnsClient()
        client.pages = [makePage([makePost("10", createTime: 100)], maxID: "10", hasMore: false)]
        let store = makeStore(client: client)
        await store.loadInitialIfNeeded()

        client.syncResults = [
            SnsSyncResult(events: [
                SnsSyncEvent(type: "sns_like", postID: "10", userID: "wxid_a"),
                SnsSyncEvent(type: "sns_like", postID: "10", userID: "wxid_b")
            ]),
            SnsSyncResult(events: [SnsSyncEvent(type: "sns_like", postID: "10", userID: "wxid_c")])
        ]
        await store.pollSync()
        await store.pollSync()
        XCTAssertEqual(store.posts.first?.likeCount, 3)
    }

    /// bridge 原生的 `sns_new_post` 事件只带 `post`（没有 `post_id`）：同一批两条新动态
    /// 都要合并，展示事件也不能因为去重键相同而被合并/误删。
    func testSyncNewPostEventsWithoutPostIDAreBothApplied() async {
        let client = MockSnsClient()
        client.pages = [makePage([makePost("10", createTime: 100)], maxID: "10", hasMore: false)]
        let store = makeStore(client: client)
        await store.loadInitialIfNeeded()

        let batch = SnsSyncResult(events: [
            SnsSyncEvent(type: "sns_new_post", postID: "",
                         post: makePost("11", createTime: 200, text: "一")),
            SnsSyncEvent(type: "sns_new_post", postID: "",
                         post: makePost("12", createTime: 210, text: "二"))
        ])
        client.syncResults = [batch, batch]
        await store.pollSync()
        await store.pollSync()

        XCTAssertEqual(store.posts.map(\.id), ["12", "11", "10"])
        XCTAssertEqual(store.syncEvents.count, 2, "两条新动态各算一条更新")
    }

    func testDetailReplacesTruncatedComments() async {
        let client = MockSnsClient()
        let preview = makePost("20", createTime: 100)
        var full = preview
        var first = SnsComment()
        first.commentID = "c1"
        first.text = "一"
        var second = SnsComment()
        second.commentID = "c2"
        second.text = "二"
        full.comments = [first, second]
        full.commentCount = 2
        client.pages = [makePage([preview], maxID: "20", hasMore: false)]
        client.detailResult = .success(full)

        let store = makeStore(client: client)
        await store.loadInitialIfNeeded()
        await store.loadDetail(postID: "20")

        XCTAssertEqual(store.detailPostID, "20")
        XCTAssertEqual(store.detail?.comments.count, 2)
        XCTAssertEqual(store.posts.first?.comments.count, 2)
    }

    func testPublishRequiresWriteFlag() async {
        let client = MockSnsClient()
        let store = makeStore(client: client, settings: makeSettings(enabled: true, writeEnabled: false))
        await store.loadInitialIfNeeded()

        let ok = await store.publish(text: "正文", visibility: .partial)
        XCTAssertFalse(ok)
        XCTAssertNotNil(store.publishError)
        XCTAssertTrue(client.publishCalls.isEmpty)
    }

    func testPublishAddsLocalEchoAndRefreshes() async {
        let client = MockSnsClient()
        client.pages = [
            makePage([], maxID: "0", hasMore: false),
            makePage([], maxID: "0", hasMore: false)
        ]
        client.publishResult = .success(SnsPublishResult(postID: "pub-9", createTime: 1_800_000_000))
        let store = makeStore(client: client, settings: makeSettings(enabled: true, writeEnabled: true))
        await store.loadInitialIfNeeded()

        let recipient = SnsPublishRecipient(userID: "wxid_friend", displayName: "示例好友")
        let ok = await store.publish(text: "  新动态  ", recipient: recipient, visibility: .partial)
        XCTAssertTrue(ok)
        XCTAssertEqual(client.publishCalls.count, 1)
        XCTAssertEqual(client.publishCalls.first?.text, "新动态")
        XCTAssertEqual(client.publishCalls.first?.visibility, .partial)
        XCTAssertEqual(client.publishCalls.first?.visibleUserIDs, ["wxid_friend"])
        XCTAssertEqual(store.posts.map(\.id), ["pub-9"])
        XCTAssertEqual(store.posts.first?.text, "新动态")
        XCTAssertEqual(store.posts.first?.visibility, .partial)
        XCTAssertNil(store.publishError)
    }

    /// 自动发布恒为「部分可见（仅该好友）」：即使 defaultVisibility 是 private 也不跟随。
    func testPublishPartialVisibilityIgnoresDefaultVisibility() async {
        let client = MockSnsClient()
        var settings = makeSettings(enabled: true, writeEnabled: true)
        settings.defaultVisibility = .private
        let store = makeStore(client: client, settings: settings)
        let recipient = SnsPublishRecipient(userID: "wxid_friend", displayName: "示例昵称")
        let ok = await store.publish(text: "正文", recipient: recipient, visibility: .partial)
        XCTAssertTrue(ok)
        XCTAssertEqual(client.publishCalls.last?.visibility, .partial)
        XCTAssertEqual(client.publishCalls.last?.visibleUserIDs, ["wxid_friend"])
    }

    func testPublishWithoutRecipientFallsBackToPrivate() async {
        let client = MockSnsClient()
        client.pages = [
            makePage([], maxID: "0", hasMore: false),
            makePage([], maxID: "0", hasMore: false)
        ]
        let store = makeStore(client: client, settings: makeSettings(enabled: true, writeEnabled: true))
        await store.loadInitialIfNeeded()

        let ok = await store.publish(text: "仅自己可见", recipient: nil, visibility: .partial)
        XCTAssertTrue(ok)
        XCTAssertEqual(client.publishCalls.first?.visibility, .private)
        XCTAssertEqual(client.publishCalls.first?.visibleUserIDs, [])
        XCTAssertEqual(store.posts.first?.visibility, .private)
    }

    func testPublishFailureKeepsErrorAndDoesNotEcho() async {
        let client = MockSnsClient()
        client.pages = [makePage([], maxID: "0", hasMore: false)]
        client.publishResult = .failure(SnsClientError.writeDisabled)
        let store = makeStore(client: client, settings: makeSettings(enabled: true, writeEnabled: true))
        await store.loadInitialIfNeeded()

        let ok = await store.publish(text: "正文", visibility: .partial)
        XCTAssertFalse(ok)
        XCTAssertNotNil(store.publishError)
        XCTAssertTrue(store.posts.isEmpty)
    }

    func testAccountChangeClearsFeedAndMedia() async {
        let client = MockSnsClient()
        client.pages = [makePage([makePost("30", createTime: 100)], maxID: "30", hasMore: false)]
        let store = makeStore(client: client)
        await store.loadInitialIfNeeded()
        XCTAssertEqual(store.posts.count, 1)

        store.apply(settings: makeSettings(), onebot: OneBotSettings(), accountID: "wxid_other")
        XCTAssertTrue(store.posts.isEmpty)
        XCTAssertNil(store.cursor)
        XCTAssertTrue(store.mediaImages.isEmpty)
    }

    func testWebSocketEventIngestDedupes() async {
        let client = MockSnsClient()
        client.pages = [
            makePage([makePost("50", createTime: 100)], maxID: "50", hasMore: false)
        ]
        let store = makeStore(client: client)
        await store.loadInitialIfNeeded()

        var comment = SnsComment()
        comment.commentID = "ws-c1"
        comment.text = "WS 评论"
        let event = SnsSyncEvent(type: "sns_comment", postID: "50", comment: comment)
        store.ingest(event: event)
        store.ingest(event: event)

        XCTAssertEqual(store.posts.first?.comments.count, 1)
        XCTAssertEqual(store.posts.first?.commentCount, 1)
        XCTAssertEqual(store.syncEvents.count, 1)
    }

    /// 媒体内存缓存有上限：连续加载超过上限后，最旧条目被淘汰（图片+路径一起清）。
    func testMediaCacheIsBounded() async throws {
        let client = MockSnsClient()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sns-media-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemGreen.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: tempURL)
        client.mediaResult = .success(tempURL)

        let store = makeStore(
            client: client,
            settings: makeSettings(enabled: true, autoLoadThumbnails: true)
        )
        let total = MomentsStore.mediaCacheLimit + 5
        for index in 0..<total {
            await store.loadMedia(postID: "p\(index)", mediaIndex: 0, variant: .thumb)
        }
        XCTAssertEqual(store.mediaImages.count, MomentsStore.mediaCacheLimit)
        XCTAssertNil(store.image(postID: "p0", mediaIndex: 0, variant: .thumb), "最旧条目应被淘汰")
        XCTAssertNotNil(
            store.image(postID: "p\(total - 1)", mediaIndex: 0, variant: .thumb),
            "最新条目应保留"
        )
    }

    /// 被动缓存时间透出：时间线响应带 captured_at 时记录 feedCapturedAt。
    func testTimelineCapturedAtIsExposed() async {
        let client = MockSnsClient()
        let captured: Int = 1_800_000_000
        client.pages = [makePage(
            [makePost("31", createTime: 100)],
            maxID: "31",
            hasMore: false,
            capturedAt: captured
        )]
        let store = makeStore(client: client)
        await store.loadInitialIfNeeded()
        XCTAssertEqual(
            store.feedCapturedAt?.timeIntervalSince1970,
            TimeInterval(captured)
        )
    }

    /// 页面重新出现：数据新鲜时不重复拉取；超过阈值才刷新一次。
    func testRefreshIfStaleSkipsFreshAndRefreshesOld() async {
        let client = MockSnsClient()
        client.pages = [
            makePage([makePost("41", createTime: 100)], maxID: "41"),
            makePage([makePost("41", createTime: 100), makePost("42", createTime: 200)], maxID: "42")
        ]
        let store = makeStore(client: client)
        await store.loadInitialIfNeeded()
        XCTAssertEqual(client.timelineCalls.count, 1)

        await store.refreshIfStale(maxAge: 3600)
        XCTAssertEqual(client.timelineCalls.count, 1, "新鲜数据不应重复刷新")

        await store.refreshIfStale(maxAge: -1)
        XCTAssertEqual(client.timelineCalls.count, 2)
        XCTAssertEqual(store.posts.count, 2)
    }

    /// 刷新后本地 diff 产生新动态/新评论/新点赞事件；重复刷新不重复产生。
    func testTimelineDiffEmitsLocalEvents() async {
        let client = MockSnsClient()
        let first = makePost("10", createTime: 100)
        var updated = first
        var comment = SnsComment()
        comment.commentID = "c1"
        comment.text = "新评论"
        comment.createTime = 120
        updated.comments = [comment]
        updated.commentCount = 1
        updated.likeCount = 2
        let added = makePost("11", createTime: 130, text: "新动态")
        client.pages = [
            makePage([first], maxID: "10", hasMore: false),
            makePage([added, updated], maxID: "11", hasMore: false),
            makePage([added, updated], maxID: "11", hasMore: false)
        ]
        let store = makeStore(client: client)
        await store.loadInitialIfNeeded()
        XCTAssertTrue(store.syncEvents.isEmpty, "首次加载不应产生更新事件")

        await store.refresh()
        let kinds = store.syncEvents.map(\.kind)
        XCTAssertTrue(kinds.contains(.newPost))
        XCTAssertTrue(kinds.contains(.comment))
        XCTAssertTrue(kinds.contains(.like))
        XCTAssertEqual(store.syncEvents.filter { $0.kind == .like }.count, 2)
        XCTAssertNil(store.lastSyncError)

        // 没有变化时不重复产生事件。
        let before = store.syncEvents.count
        await store.refresh()
        XCTAssertEqual(store.syncEvents.count, before)
    }

    /// 详情补齐失败时保留时间线评论，用提示代替错误态。
    func testDetailFailureFallsBackToTimelineComments() async {
        let client = MockSnsClient()
        var post = makePost("20", createTime: 100)
        var comment = SnsComment()
        comment.commentID = "c1"
        comment.text = "时间线里的评论"
        post.comments = [comment]
        post.commentCount = 1
        client.pages = [makePage([post], maxID: "20", hasMore: false)]
        client.detailResult = .failure(SnsClientError.notReady)
        let store = makeStore(client: client)
        await store.loadInitialIfNeeded()
        await store.loadDetail(postID: "20")
        XCTAssertTrue(store.detailIsPartial)
        XCTAssertNotNil(store.detailFallbackMessage)
        XCTAssertNil(store.detailError)
        XCTAssertEqual(store.posts.first(where: { $0.id == "20" })?.comments.count, 1)
    }

    /// bridge 用缓存兜底详情时标记为 partial（不显示错误态）。
    func testDetailCacheSourceIsPartial() async {
        let client = MockSnsClient()
        let post = makePost("21", createTime: 100)
        client.pages = [makePage([post], maxID: "21", hasMore: false)]
        client.detailResult = .success(post)
        client.detailSource = "cache"
        let store = makeStore(client: client)
        await store.loadInitialIfNeeded()
        await store.loadDetail(postID: "21")
        XCTAssertTrue(store.detailIsPartial)
        XCTAssertNil(store.detailFallbackMessage)
    }

    // MARK: 评论 / 回复

    /// 写开关关闭时评论直接拒绝，不发请求。
    func testSubmitCommentRequiresWriteFlag() async {
        let client = MockSnsClient()
        client.statusResult = .success(
            SnsStatus(ready: true, seedReady: true, commentReady: true, account: "wxid_example")
        )
        let post = makePost("29", createTime: 100)
        client.pages = [makePage([post], maxID: "29", hasMore: false)]
        let store = makeStore(client: client, settings: makeSettings(writeEnabled: false))
        await store.loadInitialIfNeeded()

        let ok = await store.submitComment(post: store.posts[0], text: "hello")
        XCTAssertFalse(ok)
        XCTAssertTrue(client.commentCalls.isEmpty)
        XCTAssertNotNil(store.commentError)
    }

    /// 评论句柄未捕获时直接给可行动提示，不发注定失败的请求。
    func testSubmitCommentBlockedWhenCommentChannelNotReady() async {        let client = MockSnsClient()
        client.statusResult = .success(
            SnsStatus(ready: true, seedReady: true, commentReady: false, account: "wxid_example")
        )
        let post = makePost("30", createTime: 100)
        client.pages = [makePage([post], maxID: "30", hasMore: false)]
        let store = makeStore(client: client, settings: makeSettings(writeEnabled: true))
        await store.loadInitialIfNeeded()

        let ok = await store.submitComment(post: store.posts[0], text: "hello")
        XCTAssertFalse(ok)
        XCTAssertTrue(client.commentCalls.isEmpty)
        XCTAssertEqual(store.isCommentChannelReady, false)
        XCTAssertNotNil(store.commentError)
        XCTAssertFalse(store.isCommenting)
    }

    /// sns.db 补全的评论 ID 语义未确认（32 位，真机 35）：手动回复也不能拿它当
    /// reply_comment_id（可能回复到错误目标），直接给出可行动提示、不发请求。
    func testSubmitCommentRejectsUnconfirmedReplyTarget() async {
        let client = MockSnsClient()
        client.statusResult = .success(
            SnsStatus(ready: true, seedReady: true, commentReady: true, account: "wxid_example")
        )
        let post = makePost("30b", createTime: 100)
        client.pages = [makePage([post], maxID: "30b", hasMore: false)]
        let store = makeStore(client: client, settings: makeSettings(writeEnabled: true))
        await store.loadInitialIfNeeded()

        var dbComment = SnsComment()
        dbComment.commentID = "35"
        dbComment.userID = "wxid_friend"
        dbComment.userName = "好友"
        dbComment.text = "回复你"
        dbComment.createTime = 200
        dbComment.replyToUserID = "wxid_example"
        dbComment.source = "db"
        dbComment.commentIDUnconfirmed = true
        let ok = await store.submitComment(
            post: store.posts[0], replyTo: dbComment, text: "收到")
        XCTAssertFalse(ok)
        XCTAssertTrue(client.commentCalls.isEmpty, "未确认的目标不能发出评论请求")
        XCTAssertTrue(store.commentError?.contains("暂时无法回复") == true)

        // 真机抓包确认后可回复：bridge 标记 confirmed 时允许发出请求。
        dbComment.commentIDUnconfirmed = false
        dbComment.commentIDConfirmed = true
        let okConfirmed = await store.submitComment(
            post: store.posts[0], replyTo: dbComment, text: "收到")
        XCTAssertTrue(okConfirmed)
        XCTAssertEqual(client.commentCalls.count, 1)
    }

    /// 评论成功后合并 bridge 返回的新评论与更新后的动态。
    func testSubmitCommentMergesReturnedComment() async {
        let client = MockSnsClient()
        client.statusResult = .success(
            SnsStatus(ready: true, seedReady: true, commentReady: true, account: "wxid_example")
        )
        let post = makePost("31", createTime: 100)
        client.pages = [makePage([post], maxID: "31", hasMore: false)]
        var updated = post
        var newComment = SnsComment()
        newComment.commentID = "c-88"
        newComment.userID = "wxid_self"
        newComment.userName = "我"
        newComment.text = "hello"
        newComment.createTime = 200
        updated.comments = [newComment]
        updated.commentCount = 1
        client.commentResult = .success(
            SnsCommentResult(post: updated, comment: newComment, commentID: "c-88")
        )
        let store = makeStore(client: client, settings: makeSettings(writeEnabled: true))
        await store.loadInitialIfNeeded()

        let ok = await store.submitComment(post: store.posts[0], text: "hello")
        XCTAssertTrue(ok)
        XCTAssertEqual(client.commentCalls.count, 1)
        XCTAssertEqual(client.commentCalls.first?.postID, "31")
        XCTAssertEqual(client.commentCalls.first?.text, "hello")
        XCTAssertTrue(client.commentCalls.first?.replyCommentID.isEmpty == true)
        let merged = store.posts.first(where: { $0.id == "31" })
        XCTAssertEqual(merged?.comments.first?.commentID, "c-88")
        XCTAssertEqual(merged?.comments.first?.text, "hello")
        XCTAssertFalse(merged?.commentsTruncated == true)
        XCTAssertNil(store.commentError)
    }

    /// 回复评论：把 reply_comment_id 传给 bridge，并在本地把新评论挂到被回复评论上。
    func testSubmitReplyMergesReplyAndPassesTargetID() async {
        let client = MockSnsClient()
        client.statusResult = .success(
            SnsStatus(ready: true, seedReady: true, commentReady: true, account: "wxid_example")
        )
        var post = makePost("32", createTime: 100)
        var parent = SnsComment()
        parent.commentID = "c-1"
        parent.userID = "wxid_friend"
        parent.userName = "好友"
        parent.text = "原评论"
        post.comments = [parent]
        post.commentCount = 1
        client.pages = [makePage([post], maxID: "32", hasMore: false)]
        var reply = SnsComment()
        reply.commentID = "c-2"
        reply.userID = "wxid_self"
        reply.userName = "我"
        reply.text = "回复内容"
        reply.replyTo = "c-1"
        reply.replyToName = "好友"
        reply.createTime = 200
        client.commentResult = .success(
            SnsCommentResult(comment: reply, commentID: "c-2")
        )
        let store = makeStore(client: client, settings: makeSettings(writeEnabled: true))
        await store.loadInitialIfNeeded()

        let ok = await store.submitComment(
            post: store.posts[0],
            replyTo: store.posts[0].comments.first,
            text: "回复内容"
        )
        XCTAssertTrue(ok)
        XCTAssertEqual(client.commentCalls.first?.replyCommentID, "c-1")
        let merged = store.posts.first(where: { $0.id == "32" })
        XCTAssertEqual(merged?.comments.last?.commentID, "c-2")
        XCTAssertEqual(merged?.comments.last?.replyTo, "c-1")
        XCTAssertEqual(merged?.comments.last?.replyToName, "好友")
        XCTAssertEqual(merged?.commentCount, 2)
    }

    /// bridge 回包没有 diff 出新评论时本地回显（不伪造 comment_id）。
    func testSubmitCommentEchoesLocallyWithoutBridgeComment() async {
        let client = MockSnsClient()
        client.statusResult = .success(
            SnsStatus(ready: true, seedReady: true, commentReady: true, account: "wxid_example")
        )
        let post = makePost("33", createTime: 100)
        client.pages = [makePage([post], maxID: "33", hasMore: false)]
        client.commentResult = .success(SnsCommentResult())
        let store = makeStore(client: client, settings: makeSettings(writeEnabled: true))
        await store.loadInitialIfNeeded()

        let ok = await store.submitComment(post: store.posts[0], text: "本地回显")
        XCTAssertTrue(ok)
        let merged = store.posts.first(where: { $0.id == "33" })
        XCTAssertEqual(merged?.comments.count, 1)
        XCTAssertEqual(merged?.comments.first?.text, "本地回显")
        XCTAssertEqual(merged?.comments.first?.userName, "我")
        XCTAssertTrue(merged?.comments.first?.commentID.hasPrefix("local-") == true)
        XCTAssertEqual(merged?.commentCount, 1)
        XCTAssertFalse(merged?.commentsTruncated == true)
    }

    /// 发送失败保留面板并给出可行动错误，不自动重试。
    func testSubmitCommentFailureSurfacesError() async {
        let client = MockSnsClient()
        client.statusResult = .success(
            SnsStatus(ready: true, seedReady: true, commentReady: true, account: "wxid_example")
        )
        let post = makePost("34", createTime: 100)
        client.pages = [makePage([post], maxID: "34", hasMore: false)]
        client.commentResult = .failure(SnsClientError.commentUnavailable)
        let store = makeStore(client: client, settings: makeSettings(writeEnabled: true))
        await store.loadInitialIfNeeded()

        let ok = await store.submitComment(post: store.posts[0], text: "hello")
        XCTAssertFalse(ok)
        XCTAssertEqual(store.commentError, SnsClientError.commentUnavailable.userMessage)
        XCTAssertEqual(client.commentCalls.count, 1)
        XCTAssertFalse(store.isCommenting)
    }

    /// 手动发布写入共享账本（与自动发布同一口径），并带幂等键。
    func testManualPublishRecordsLedger() async {
        let suite = "SnsMomentsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = SnsPublishLedger(accountID: "wxid_test", defaults: defaults)
        let client = MockSnsClient()
        let store = makeStore(client: client, settings: makeSettings(enabled: true, writeEnabled: true))
        store.publishLedger = ledger
        let recipient = SnsPublishRecipient(userID: "wxid_friend", displayName: "示例昵称")
        let ok = await store.publish(text: "正文", recipient: recipient, visibility: .partial)
        XCTAssertTrue(ok)
        let state = await ledger.state(for: "wxid_friend")
        XCTAssertEqual(state.count, 1)
        XCTAssertFalse(client.publishCalls.last?.clientID.isEmpty ?? true, "发布必须带幂等键")
        // 二次发布仍带不同的 client_id（每次是新请求，由超时重试场景才复用）。
        _ = await store.publish(text: "正文 2", recipient: recipient, visibility: .partial)
        XCTAssertNotEqual(client.publishCalls.last?.clientID, client.publishCalls.first?.clientID)
    }

    /// 超时语义：结果未知，提示去微信确认，不自动重发。
    func testPublishTimeoutReportsUnknownResult() async {
        let client = MockSnsClient()
        client.publishResult = .failure(SnsClientError.timedOut)
        let store = makeStore(client: client, settings: makeSettings(enabled: true, writeEnabled: true))
        let ok = await store.publish(text: "正文", visibility: .private)
        XCTAssertFalse(ok)
        XCTAssertTrue(store.publishError?.contains("结果未知") ?? false)
        XCTAssertEqual(client.publishCalls.count, 1, "失败不自动重发")
    }

    func testMediaPolicyAndForceLoad() async {
        let client = MockSnsClient()
        let store = makeStore(
            client: client,
            settings: makeSettings(enabled: true, autoLoadThumbnails: false)
        )
        // 策略关闭：自动加载不请求。
        await store.loadMedia(postID: "40", mediaIndex: 0, variant: .thumb)
        XCTAssertEqual(client.mediaCalls, 0)

        // 用户点击（force）忽略策略，失败记录可重试。
        await store.loadMedia(postID: "40", mediaIndex: 0, variant: .thumb, force: true)
        XCTAssertEqual(client.mediaCalls, 1)
        XCTAssertTrue(store.hasMediaFailed(postID: "40", mediaIndex: 0, variant: .thumb))
    }

    /// 本地回显（`local-` 前缀）在拿到 bridge 真实 `comment_id` 后原地替换，
    /// 不能既保留回显又追加真实评论（会重复显示、commentCount 多算）。
    func testNativeCommentEventReplacesLocalEcho() async {
        let client = MockSnsClient()
        client.statusResult = .success(
            SnsStatus(ready: true, seedReady: true, commentReady: true, account: "wxid_example")
        )
        let post = makePost("36", createTime: 100)
        client.pages = [makePage([post], maxID: "36", hasMore: false)]
        client.commentResult = .success(SnsCommentResult())
        let store = makeStore(client: client, settings: makeSettings(writeEnabled: true))
        await store.loadInitialIfNeeded()

        let ok = await store.submitComment(post: store.posts[0], text: "同一条评论")
        XCTAssertTrue(ok)
        XCTAssertEqual(store.posts.first?.comments.count, 1)
        XCTAssertTrue(store.posts.first?.comments.first?.commentID.hasPrefix("local-") == true)

        var real = SnsComment()
        real.commentID = "c-real"
        real.userID = "wxid_example"
        real.userName = "我"
        real.text = "同一条评论"
        real.createTime = 300
        store.ingest(event: SnsSyncEvent(type: "sns_comment", postID: "36", comment: real))

        let merged = store.posts.first
        XCTAssertEqual(merged?.comments.count, 1, "本地回显应被替换，而不是追加成两条")
        XCTAssertEqual(merged?.comments.first?.commentID, "c-real")
        XCTAssertEqual(merged?.commentCount, 1)
    }

    /// bridge 回包里的评论如果其实已经在本地列表里（例如旧 bridge 拿不到 64 位
    /// comment_id，只能按用户 + 时间 + 正文匹配），不能再把 commentCount 加一。
    func testCommentMergeDoesNotDoubleCountKnownComment() async {
        let client = MockSnsClient()
        client.statusResult = .success(
            SnsStatus(ready: true, seedReady: true, commentReady: true, account: "wxid_example")
        )
        var post = makePost("37", createTime: 100)
        var known = SnsComment()
        known.userID = "wxid_example"
        known.text = "重复正文"
        known.createTime = 200
        post.comments = [known]
        post.commentCount = 1
        client.pages = [makePage([post], maxID: "37", hasMore: false)]
        client.commentResult = .success(
            SnsCommentResult(post: post, comment: known, commentID: "")
        )
        let store = makeStore(client: client, settings: makeSettings(writeEnabled: true))
        await store.loadInitialIfNeeded()

        let ok = await store.submitComment(post: store.posts[0], text: "重复正文")
        XCTAssertTrue(ok)
        let merged = store.posts.first
        XCTAssertEqual(merged?.comments.count, 1)
        XCTAssertEqual(merged?.commentCount, 1, "已存在的评论不能重复计数")
        XCTAssertFalse(merged?.commentsTruncated == true)
    }

    /// bridge 回包没带 `reply_to` / `reply_to_name` 时，用请求上下文补齐回复关系。
    func testCommentMergeFillsMissingReplyTarget() async {
        let client = MockSnsClient()
        client.statusResult = .success(
            SnsStatus(ready: true, seedReady: true, commentReady: true, account: "wxid_example")
        )
        var post = makePost("38", createTime: 100)
        var parent = SnsComment()
        parent.commentID = "c-1"
        parent.userID = "wxid_friend"
        parent.userName = "好友"
        parent.text = "原评论"
        post.comments = [parent]
        post.commentCount = 1
        client.pages = [makePage([post], maxID: "38", hasMore: false)]

        var reply = SnsComment()
        reply.commentID = "c-2"
        reply.userID = "wxid_example"
        reply.userName = "我"
        reply.text = "回复内容"
        reply.createTime = 300
        client.commentResult = .success(SnsCommentResult(comment: reply, commentID: "c-2"))

        let store = makeStore(client: client, settings: makeSettings(writeEnabled: true))
        await store.loadInitialIfNeeded()
        let ok = await store.submitComment(
            post: store.posts[0],
            replyTo: store.posts[0].comments.first,
            text: "回复内容"
        )
        XCTAssertTrue(ok)
        let merged = store.posts.first
        XCTAssertEqual(merged?.comments.last?.commentID, "c-2")
        XCTAssertEqual(merged?.comments.last?.replyTo, "c-1")
        XCTAssertEqual(merged?.comments.last?.replyToName, "好友")
        XCTAssertEqual(merged?.commentCount, 2)
    }

    /// 竞态：`/sns/sync` 返回前切号，旧账号的事件不能写进新账号的时间线。
    func testSyncResultAfterAccountSwitchIsDiscarded() async {
        let client = MockSnsClient()
        client.pages = [makePage([makePost("10", createTime: 100)], maxID: "10", hasMore: false)]
        let store = makeStore(client: client)
        await store.loadInitialIfNeeded()
        XCTAssertEqual(store.status?.account, "wxid_example")

        client.syncResults = [SnsSyncResult(events: [
            SnsSyncEvent(type: "sns_new_post", postID: "",
                         post: makePost("11", createTime: 200, text: "旧账号的新动态"))
        ])]
        client.onFetchSync = { [weak store] in
            guard let store else { return }
            store.apply(
                settings: self.makeSettings(),
                onebot: OneBotSettings(),
                accountID: "wxid_other"
            )
        }
        await store.pollSync()
        XCTAssertTrue(store.posts.isEmpty, "切号后旧账号的同步事件必须丢弃")
    }

    /// 竞态：切号前发出的详情请求在切号后返回，不能覆盖新账号的详情
    /// （同一个 snsId 可能同时出现在两个账号的时间线里）。
    func testStaleDetailResponseAfterAccountSwitchIsDiscarded() async {
        let client = MockSnsClient()
        let preview = makePost("39", createTime: 100)
        client.pages = [makePage([preview], maxID: "39", hasMore: false)]
        client.detailQueue = [
            makePost("39", createTime: 100, text: "旧账号详情"),
            makePost("39", createTime: 100, text: "新账号详情")
        ]
        let store = makeStore(client: client)
        await store.loadInitialIfNeeded()

        client.holdNextDetail = true
        let stale = Task { await store.loadDetail(postID: "39") }
        await waitUntil { client.detailHoldLatch.isHeld }

        store.apply(
            settings: makeSettings(),
            onebot: OneBotSettings(),
            accountID: "wxid_other"
        )
        await store.loadDetail(postID: "39")
        XCTAssertEqual(store.detail?.text, "新账号详情")

        client.detailHoldLatch.release()
        await stale.value
        XCTAssertEqual(store.detail?.text, "新账号详情", "切号前的详情响应必须丢弃")
    }

    /// 连续切换动态（A→B，A 请求仍在途）：A 先返回既不能结束 B 的 loading，
    /// 也不能把 A 的详情写进 B 的视图状态。
    func testSwitchingDetailKeepsLatestLoadingState() async {
        let client = MockSnsClient()
        client.pages = [makePage([makePost("20", createTime: 200), makePost("21", createTime: 210)],
                                 maxID: "21", hasMore: false)]
        client.detailQueue = [
            makePost("20", createTime: 200, text: "详情 A"),
            makePost("21", createTime: 210, text: "详情 B")
        ]
        let gateA = SnsTestLatch()
        let gateB = SnsTestLatch()
        client.detailHoldLatches = [gateA, gateB]

        let store = makeStore(client: client)
        await store.loadInitialIfNeeded()

        let first = Task { await store.loadDetail(postID: "20") }
        await waitUntil { gateA.isHeld }
        let second = Task { await store.loadDetail(postID: "21") }
        await waitUntil { gateB.isHeld }
        XCTAssertEqual(store.detailPostID, "21")

        // A 先返回：B 仍在途时 loading 不能被 A 的 defer 复位，详情也不能是 A。
        gateA.release()
        await first.value
        XCTAssertTrue(store.isDetailLoading, "旧请求返回后，新请求的加载态应保持")
        XCTAssertNil(store.detail)

        gateB.release()
        await second.value
        XCTAssertFalse(store.isDetailLoading)
        XCTAssertEqual(store.detail?.id, "21")
        XCTAssertEqual(store.detail?.text, "详情 B")
    }

    /// 「N 条更新」只影响提示：清空事件不能清掉时间线动态，也不能回退已合并的计数。
    func testClearSyncEventsKeepsTimelinePosts() async {
        let client = MockSnsClient()
        client.pages = [makePage([makePost("10", createTime: 100)], maxID: "10", hasMore: false)]
        let store = makeStore(client: client)
        await store.loadInitialIfNeeded()

        store.ingest(event: SnsSyncEvent(type: "sns_like", postID: "10", userID: "wxid_other"))
        XCTAssertEqual(store.syncEvents.count, 1)
        XCTAssertEqual(store.posts.first?.likeCount, 1)

        store.clearSyncEvents()
        XCTAssertTrue(store.syncEvents.isEmpty)
        XCTAssertEqual(store.posts.map(\.id), ["10"])
        XCTAssertEqual(store.posts.first?.likeCount, 1)
    }

    /// 机器人停止/重启时只清就绪与在途状态，保留已读到的列表内容。
    func testResetRuntimeReadinessKeepsPosts() async {
        let client = MockSnsClient()
        client.pages = [makePage([makePost("10", createTime: 100)], maxID: "10", hasMore: false)]
        let store = makeStore(client: client)
        await store.loadInitialIfNeeded()
        XCTAssertNotNil(store.status)

        store.resetRuntimeReadiness()
        XCTAssertNil(store.status)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.isDetailLoading)
        XCTAssertFalse(store.primingRequired)
        XCTAssertEqual(store.posts.map(\.id), ["10"])
    }

    /// 发布结果未知（超时）后，重试完全相同的请求复用 client_id，让 bridge 幂等去重；
    /// 成功之后再发同样内容则换新键（那是新的一次发布）。
    func testPublishReusesClientIDAfterUnknownOutcome() async {
        let client = MockSnsClient()
        let store = makeStore(client: client, settings: makeSettings(writeEnabled: true))
        let recipient = SnsPublishRecipient(userID: "wxid_friend", displayName: "好友")

        client.publishResult = .failure(SnsClientError.timedOut)
        _ = await store.publish(text: "同一段内容", recipient: recipient)
        let firstID = try? XCTUnwrap(client.publishCalls.last?.clientID)

        client.publishResult = .success(SnsPublishResult(postID: "pub-1", createTime: 1_800_000_000))
        _ = await store.publish(text: "同一段内容", recipient: recipient)
        XCTAssertEqual(client.publishCalls.last?.clientID, firstID, "结果未知后的重试必须复用幂等键")

        _ = await store.publish(text: "同一段内容", recipient: recipient)
        XCTAssertNotEqual(client.publishCalls.last?.clientID, firstID, "成功后再发是新请求")
    }

    /// 明确失败（如限流）说明请求没有提交，下一次用新的 client_id。
    func testPublishUsesFreshClientIDAfterDefinitiveFailure() async {
        let client = MockSnsClient()
        let store = makeStore(client: client, settings: makeSettings(writeEnabled: true))
        let recipient = SnsPublishRecipient(userID: "wxid_friend", displayName: "好友")

        client.publishResult = .failure(SnsClientError.rateLimited)
        _ = await store.publish(text: "同一段内容", recipient: recipient)
        let firstID = try? XCTUnwrap(client.publishCalls.last?.clientID)

        _ = await store.publish(text: "同一段内容", recipient: recipient)
        XCTAssertNotEqual(client.publishCalls.last?.clientID, firstID)

        // 内容不同同样换新键。
        client.publishResult = .failure(SnsClientError.timedOut)
        _ = await store.publish(text: "另一段内容", recipient: recipient)
        let timeoutID = try? XCTUnwrap(client.publishCalls.last?.clientID)
        _ = await store.publish(text: "另外一段内容", recipient: recipient)
        XCTAssertNotEqual(client.publishCalls.last?.clientID, timeoutID)
    }

    /// bridge 发布成功但没返回 post_id：刷新到真实动态后按正文/作者配对，丢弃本地回显，
    /// 避免回显永久残留成重复条目。
    func testRefreshReconcilesLocalEchoWithoutServerPostID() async {
        let client = MockSnsClient()
        let now = Int(Date().timeIntervalSince1970)
        var real = makePost("1504", createTime: now, text: "新动态")
        real.authorID = "wxid_example"
        client.pages = [
            makePage([], maxID: "0", hasMore: false),
            makePage([real], maxID: "1504", hasMore: false)
        ]
        client.publishResult = .success(SnsPublishResult(postID: "", createTime: 0))
        let store = makeStore(client: client, settings: makeSettings(writeEnabled: true))
        await store.loadInitialIfNeeded()

        let recipient = SnsPublishRecipient(userID: "wxid_friend", displayName: "好友")
        let ok = await store.publish(text: "新动态", recipient: recipient)
        XCTAssertTrue(ok)
        XCTAssertEqual(store.posts.map(\.id), ["1504"], "回显必须被真实动态替换")
        XCTAssertFalse(store.posts.contains { $0.id.hasPrefix("local-") })
    }

    // MARK: 并发 / 生命周期回归

    /// 停止后立刻重启自动同步：旧任务的收尾 `defer` 只能清理自己，不能把新任务引用清空，
    /// 否则新轮询仍在跑但 `stopAutoSync()` 再也取消不到它（离开页面后持续请求 bridge）。
    func testAutoSyncTaskSurvivesRapidStopStart() async {
        var settings = makeSettings()
        settings.autoSync = true
        let store = makeStore(client: MockSnsClient(), settings: settings)

        store.startAutoSync()
        XCTAssertTrue(store.isAutoSyncRunning)
        store.stopAutoSync()
        XCTAssertFalse(store.isAutoSyncRunning)
        store.startAutoSync()
        XCTAssertTrue(store.isAutoSyncRunning)

        // 旧任务已被取消，下一次调度就会执行收尾；此时不能清掉新任务引用。
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(store.isAutoSyncRunning, "旧轮询任务的收尾不能清空新任务引用")

        store.stopAutoSync()
        XCTAssertFalse(store.isAutoSyncRunning)
    }

    /// 机器人停止后不再轮询 `/sns/sync`（bridge 已退出）；重新启动后自动恢复。
    func testAutoSyncSkipsPollingWhileRuntimeInactive() async {
        var settings = makeSettings()
        settings.autoSync = true
        let client = MockSnsClient()
        let store = makeStore(client: client, settings: settings)

        let inactivePolled = await store.autoSyncTickIfPossible()
        XCTAssertFalse(inactivePolled)
        XCTAssertEqual(client.syncCalls, 0, "机器人未运行时不应发 /sns/sync")

        store.setRuntimeActive(true)
        let activePolled = await store.autoSyncTickIfPossible()
        XCTAssertTrue(activePolled)
        XCTAssertEqual(client.syncCalls, 1)
    }

    /// 就绪轻量检测的停止/重启同样不能让旧任务的收尾清空新任务引用。
    func testPrimingWatchSurvivesRapidStopStart() async {
        let client = MockSnsClient()
        client.statusResult = .success(SnsStatus(ready: false, seedReady: false))
        let store = makeStore(client: client)
        await store.loadInitialIfNeeded()
        XCTAssertTrue(store.primingRequired)

        store.startPrimingWatch()
        XCTAssertTrue(store.isPrimingWatchRunning)
        store.stopPrimingWatch()
        XCTAssertFalse(store.isPrimingWatchRunning)
        store.startPrimingWatch()
        XCTAssertTrue(store.isPrimingWatchRunning)

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(store.isPrimingWatchRunning, "旧就绪检测任务的收尾不能清空新任务引用")

        store.stopPrimingWatch()
        XCTAssertFalse(store.isPrimingWatchRunning)
    }

    /// 切号/关闭功能会复位加载态；旧页面请求随后返回时不能把新请求的加载态提前结束，
    /// 否则 spinner 提前消失，且重复点击会并发发起第二次加载。
    func testStalePageResponseDoesNotEndNewLoadingState() async {
        let client = MockSnsClient()
        client.pages = [
            makePage([makePost("1", createTime: 100)]),
            makePage([makePost("2", createTime: 200)])
        ]
        let gateA = SnsTestLatch()
        let gateB = SnsTestLatch()
        client.pageHoldLatches = [gateA, gateB]
        let store = makeStore(client: client)

        let first = Task { await store.loadInitialIfNeeded() }
        await waitUntil { gateA.isHeld }
        store.resetFeed()
        let second = Task { await store.loadInitialIfNeeded() }
        await waitUntil { gateB.isHeld }

        gateA.release()
        await first.value
        XCTAssertTrue(store.isLoading, "旧请求返回后，新请求的加载态不能被结束")

        gateB.release()
        await second.value
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.posts.map(\.id), ["2"])
    }

    /// 刷新时间线（评论可能是截断摘要）不能覆盖已通过详情补齐的全量评论。
    func testRefreshKeepsFullDetailComments() async {
        let client = MockSnsClient()
        var c1 = SnsComment()
        c1.commentID = "c-1"; c1.userID = "wxid_friend"; c1.text = "一"; c1.createTime = 110
        var c2 = SnsComment()
        c2.commentID = "c-2"; c2.userID = "wxid_friend2"; c2.text = "二"; c2.createTime = 120
        var c3 = SnsComment()
        c3.commentID = "c-3"; c3.userID = "wxid_friend3"; c3.text = "三"; c3.createTime = 130

        var timeline = makePost("50", createTime: 100)
        timeline.comments = [c1]
        timeline.commentCount = 3
        timeline.commentsTruncated = true
        client.pages = [makePage([timeline]), makePage([timeline])]

        var full = timeline
        full.comments = [c1, c2, c3]
        full.commentsTruncated = false
        client.detailResult = .success(full)

        let store = makeStore(client: client)
        await store.loadInitialIfNeeded()
        await store.loadDetail(postID: "50")
        XCTAssertEqual(store.detail?.comments.count, 3)
        XCTAssertFalse(store.detailIsPartial)

        await store.loadInitialIfNeeded(force: true)
        XCTAssertEqual(store.detail?.comments.count, 3, "刷新后不能丢掉详情已补齐的评论")
        XCTAssertEqual(store.detail?.commentCount, 3)
        XCTAssertFalse(store.detail?.commentsTruncated ?? true)
    }

    /// cmd46 Type=11 轻量通知：只更新「有新回复」状态，不改动态/评论计数，也不进「N 条更新」。
    func testCommentHintOnlyUpdatesHintState() async {
        let client = MockSnsClient()
        let post = makePost("10", createTime: 100)
        client.pages = [makePage([post]), makePage([post])]
        let store = makeStore(client: client)
        await store.loadInitialIfNeeded()
        let before = store.posts

        let hint = makeCommentHint(postID: "10", fromUser: "wxid_friend", fromName: "好友")
        store.ingest(event: hint)
        XCTAssertEqual(store.replyHintRevision, 1)
        XCTAssertNotNil(store.replyHintAt)
        XCTAssertEqual(store.replyHintFromName, "好友")
        XCTAssertEqual(store.replyHintPostID, "10")
        XCTAssertEqual(store.posts, before, "hint 不能修改动态/评论")
        XCTAssertTrue(store.syncEvents.isEmpty, "hint 不是内容更新事件，不进「N 条更新」")

        // 重复投递同一条 hint（sync 重放）不重复计数/提示。
        store.ingest(event: hint)
        XCTAssertEqual(store.replyHintRevision, 1)
    }

    /// hint 到达且页面已有数据时触发一次 timeline 刷新（把 bridge 缓存的真实评论带回）。
    func testCommentHintTriggersTimelineRefresh() async {
        let client = MockSnsClient()
        let post = makePost("10", createTime: 100)
        client.pages = [makePage([post]), makePage([post])]
        let store = makeStore(client: client)
        await store.loadInitialIfNeeded()
        let callsBefore = client.timelineCalls.count

        store.ingest(event: makeCommentHint(postID: "10"))
        await waitUntil { client.timelineCalls.count > callsBefore }
        XCTAssertEqual(store.replyHintRevision, 1)
    }

    /// 轮询测试条件（由 mock 闩锁控制），避免固定 sleep 导致偶发失败。
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("等待测试条件超时")
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// 自动互动成功后把服务端评论合并进列表/详情，并保持计数正确（不污染手动评论状态）。
    func testIngestAutoCommentMergesIntoFeedAndDetail() async {
        let client = MockSnsClient()
        client.statusResult = .success(
            SnsStatus(ready: true, seedReady: true, commentReady: true,
                      account: "wxid_example")
        )
        var parent = SnsComment()
        parent.commentID = "c-1"
        parent.userID = "wxid_friend"
        parent.userName = "好友"
        parent.text = "原评论"
        parent.createTime = 200
        var post = makePost("40", createTime: 100)
        post.comments = [parent]
        post.commentCount = 1
        client.pages = [makePage([post], maxID: "40", hasMore: false)]
        client.detailResult = .success(post)
        let store = makeStore(client: client, settings: makeSettings(writeEnabled: true))
        await store.loadInitialIfNeeded()
        await store.loadDetail(postID: "40")

        store.ingestAutoComment(
            postID: "40",
            commentID: "c-auto",
            text: "真不错",
            replyTo: parent,
            createTime: 300
        )
        let merged = try? XCTUnwrap(store.posts.first)
        XCTAssertEqual(merged?.comments.count, 2)
        XCTAssertEqual(merged?.comments.last?.commentID, "c-auto")
        XCTAssertEqual(merged?.comments.last?.replyTo, "c-1")
        XCTAssertEqual(merged?.comments.last?.replyToName, "好友")
        XCTAssertEqual(merged?.commentCount, 2)
        XCTAssertEqual(store.detail?.comments.count, 2)
        XCTAssertFalse(store.isCommenting, "自动互动不能占用/复用手动评论的发送状态")
        XCTAssertNil(store.commentError)

        // 同一评论 ID 重复合并不会重复计数。
        store.ingestAutoComment(
            postID: "40",
            commentID: "c-auto",
            text: "真不错",
            replyTo: parent,
            createTime: 300
        )
        XCTAssertEqual(store.posts.first?.comments.count, 2)
    }
}

// MARK: - 自动发布调度（P6）

final class SnsPublishSchedulerTests: XCTestCase {
    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(hour: Int, minute: Int) -> Date {
        let calendar = calendar()
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        return calendar.date(byAdding: .minute, value: hour * 60 + minute, to: start)!
    }

    func testNextFireDateTimesMode() {
        var settings = SnsPublishSettings()
        settings.mode = .times
        settings.times = [
            SnsPublishTime(id: "am", minute: 10 * 60),
            SnsPublishTime(id: "pm", minute: 20 * 60)
        ]
        let nextMorning = settings.nextFireDate(after: date(hour: 9, minute: 0), calendar: calendar())
        XCTAssertEqual(calendar().component(.hour, from: nextMorning!), 10)
        XCTAssertEqual(calendar().component(.minute, from: nextMorning!), 0)
        let evening = date(hour: 21, minute: 0)
        let nextEvening = settings.nextFireDate(after: evening, calendar: calendar())
        XCTAssertGreaterThan(nextEvening!.timeIntervalSince(evening), 12 * 3600)
        XCTAssertEqual(calendar().component(.hour, from: nextEvening!), 10)
    }

    func testNextFireDateWindowsModeIsRandomButStable() throws {
        var settings = SnsPublishSettings()
        settings.mode = .windows
        settings.windows = [SnsPublishWindow(id: "w", startMinute: 9 * 60, endMinute: 22 * 60)]
        settings.maxPerDay = 2
        settings.minIntervalMinutes = 60
        let after = date(hour: 8, minute: 30)
        let next = try XCTUnwrap(settings.nextFireDate(after: after, calendar: calendar()))
        XCTAssertGreaterThan(next, after)
        XCTAssertLessThan(next, after.addingTimeInterval(86_400))
        let minute = calendar().component(.hour, from: next) * 60
            + calendar().component(.minute, from: next)
        XCTAssertTrue((9 * 60..<22 * 60).contains(minute))
        // 同一天内稳定：设置页展示的「下一次」就是调度器实际使用的时刻。
        XCTAssertEqual(
            settings.nextFireDate(after: after, calendar: calendar())?.timeIntervalSince1970,
            next.timeIntervalSince1970
        )
        XCTAssertTrue(settings.isDue(at: next, calendar: calendar()))
        XCTAssertFalse(settings.isDue(at: next.addingTimeInterval(1800), calendar: calendar()))
    }

    func testLedgerCountsPerDayAndResets() async {
        let suite = "SnsPublishSchedulerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = SnsPublishLedger(accountID: "wxid_test", defaults: defaults)
        let today = Date()
        var state = await ledger.state(for: "wxid_friend", on: today, calendar: calendar())
        XCTAssertEqual(state.count, 0)
        await ledger.record(targetID: "wxid_friend", at: today, calendar: calendar())
        state = await ledger.state(for: "wxid_friend", on: today, calendar: calendar())
        XCTAssertEqual(state.count, 1)
        let yesterday = today.addingTimeInterval(-86_400)
        state = await ledger.state(for: "wxid_friend", on: yesterday, calendar: calendar())
        XCTAssertEqual(state.count, 0)
    }
}


// MARK: - 自动发布调度：一轮执行

@MainActor
final class SnsPublishRunTests: XCTestCase {
    private func suiteDefaults() -> (UserDefaults, String) {
        let suite = "SnsPublishRunTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func makeSettings(targetIDs: [String]) -> SnsSettings {
        var settings = SnsSettings()
        settings.enabled = true
        settings.writeEnabled = true
        settings.publish.enabled = true
        settings.publish.mode = .times
        // 两个时间点 → 每日容量 2，两个目标都能通过 eligibility。
        settings.publish.times = [
            SnsPublishTime(id: "am", minute: 10 * 60),
            SnsPublishTime(id: "pm", minute: 20 * 60)
        ]
        settings.publish.targetUserIDs = targetIDs
        return settings
    }

    private func target(_ id: String) -> SnsPublishTarget {
        SnsPublishTarget(userID: id, displayName: id, conversationID: id)
    }

    /// 文案生成失败（如 AI 空回包）要写进「上次结果」的原因，且算跳过而不是发布失败。
    /// 否则设置页只能看到「跳过 1 / 失败 0」，原因只躺在运行日志里（2026-11-10 实况）。
    func testDraftFailureReasonSurfacesInRunSummary() async {
        let (defaults, suite) = suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = SnsPublishLedger(accountID: "wxid_test", defaults: defaults)
        let settings = makeSettings(targetIDs: ["wxid_a"])
        var published = false
        var summary: SnsPublishRunSummary?
        let scheduler = SnsPublishScheduler(
            settingsProvider: { settings },
            targetsProvider: { [self.target("wxid_a")] },
            draftProvider: { _ in .skipped("AI 返回了空内容（流式，finish_reason=length）") },
            publishHandler: { _, _ in
                published = true
                return true
            },
            ledger: ledger,
            targetSpacingSeconds: 0,
            onRunCompleted: { summary = $0 }
        )
        await scheduler.fire(settings: settings, scheduledAt: Date())
        XCTAssertFalse(published, "文案没生成出来就不得发布")
        XCTAssertEqual(summary?.skippedCount, 1)
        XCTAssertEqual(summary?.failedCount, 0, "生成失败按跳过计数，不是发布失败")
        XCTAssertEqual(
            summary?.firstError,
            "文案生成失败（wxid_a）：AI 返回了空内容（流式，finish_reason=length）"
        )
        XCTAssertNotNil(summary?.nextFireAt)
        XCTAssertEqual(scheduler.lastError, summary?.firstError, "失败原因也要留在调度器状态里")
    }

    /// 生成失败不写 ledger、不占用当日配额（下一轮仍可尝试）。
    func testDraftFailureDoesNotConsumeQuota() async {
        let (defaults, suite) = suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = SnsPublishLedger(accountID: "wxid_test", defaults: defaults)
        let settings = makeSettings(targetIDs: ["wxid_a"])
        let scheduler = SnsPublishScheduler(
            settingsProvider: { settings },
            targetsProvider: { [self.target("wxid_a")] },
            draftProvider: { _ in .skipped("没有可用记忆卡内容") },
            publishHandler: { _, _ in true },
            ledger: ledger,
            targetSpacingSeconds: 0
        )
        await scheduler.fire(settings: settings, scheduledAt: Date())
        let state = await ledger.state(for: "wxid_a", on: Date())
        XCTAssertEqual(state.count, 0)
    }

    func testEmptyTargetsStillReportsSummary() async {
        let (defaults, suite) = suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = SnsPublishLedger(accountID: "wxid_test", defaults: defaults)
        let settings = makeSettings(targetIDs: [])
        var captured: SnsPublishRunSummary?
        let scheduler = SnsPublishScheduler(
            settingsProvider: { settings },
            targetsProvider: { [] },
            draftProvider: { _ in .success("文案") },
            publishHandler: { _, _ in true },
            ledger: ledger,
            targetSpacingSeconds: 0,
            onRunCompleted: { captured = $0 }
        )
        await scheduler.fire(settings: settings, scheduledAt: Date())
        XCTAssertEqual(captured?.sentCount, 0)
        XCTAssertEqual(captured?.failedCount, 0)
        XCTAssertNotNil(captured?.nextFireAt)
    }

    /// 生成文案期间停止调度：不能在停止后仍然外发。
    func testStopDuringDraftPreventsPublish() async {
        let (defaults, suite) = suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = SnsPublishLedger(accountID: "wxid_test", defaults: defaults)
        let settings = makeSettings(targetIDs: ["wxid_a"])
        var schedulerBox: SnsPublishScheduler?
        var published = false
        let scheduler = SnsPublishScheduler(
            settingsProvider: { settings },
            targetsProvider: { [self.target("wxid_a")] },
            draftProvider: { _ in
                schedulerBox?.stop()
                return .success("文案")
            },
            publishHandler: { _, _ in
                published = true
                return true
            },
            ledger: ledger,
            targetSpacingSeconds: 0
        )
        schedulerBox = scheduler
        await scheduler.fire(settings: settings, scheduledAt: Date())
        XCTAssertFalse(published, "停止后不得再外发")
    }

    /// 目标间隔按「尝试」计数：第一个目标失败，第二个目标也要等间隔（bridge 失败也记账）。
    func testTargetSpacingAppliesAfterFailedAttempt() async {
        let (defaults, suite) = suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = SnsPublishLedger(accountID: "wxid_test", defaults: defaults)
        let settings = makeSettings(targetIDs: ["wxid_a", "wxid_b"])
        var stamps: [Date] = []
        var summary: SnsPublishRunSummary?
        let scheduler = SnsPublishScheduler(
            settingsProvider: { settings },
            targetsProvider: { [self.target("wxid_a"), self.target("wxid_b")] },
            draftProvider: { _ in .success("文案") },
            publishHandler: { _, _ in
                stamps.append(Date())
                return false
            },
            ledger: ledger,
            targetSpacingSeconds: 0.2,
            onRunCompleted: { summary = $0 }
        )
        await scheduler.fire(settings: settings, scheduledAt: Date())
        XCTAssertEqual(stamps.count, 2)
        if stamps.count == 2 {
            XCTAssertGreaterThanOrEqual(stamps[1].timeIntervalSince(stamps[0]), 0.18)
        }
        // 失败不写 ledger（不影响当日上限）。
        let state = await ledger.state(for: "wxid_a", on: Date())
        XCTAssertEqual(state.count, 0)
        XCTAssertEqual(summary?.failedCount, 2)
    }

    /// 演练模式：只生成草稿并标记 dryRun，不发布。
    func testDryRunEnqueuesDraftMarkedDryRun() async {
        let (defaults, suite) = suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = SnsPublishLedger(accountID: "wxid_test", defaults: defaults)
        let settings = makeSettings(targetIDs: ["wxid_a"])
        var drafted = 0
        var published = false
        let scheduler = SnsPublishScheduler(
            settingsProvider: { settings },
            targetsProvider: { [self.target("wxid_a")] },
            draftProvider: { _ in .success("文案") },
            publishHandler: { _, _ in
                published = true
                return true
            },
            ledger: ledger,
            targetSpacingSeconds: 0,
            dryRunProvider: { true },
            onDraft: { _, _ in drafted += 1 }
        )
        await scheduler.fire(settings: settings, scheduledAt: Date())
        XCTAssertFalse(published)
        XCTAssertEqual(drafted, 1)
    }

    /// 演练预览不受当天真实发布配额限制，也不改写真实 ledger。
    func testDryRunIgnoresPublishQuotaAndDoesNotWriteLedger() async {
        let (defaults, suite) = suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = SnsPublishLedger(accountID: "wxid_test", defaults: defaults)
        await ledger.record(targetID: "wxid_a")
        await ledger.record(targetID: "wxid_a")
        var settings = makeSettings(targetIDs: ["wxid_a"])
        settings.publish.mode = .windows
        settings.publish.maxPerDay = 1
        var drafted = 0
        var published = false
        let scheduler = SnsPublishScheduler(
            settingsProvider: { settings },
            targetsProvider: { [self.target("wxid_a")] },
            draftProvider: { _ in .success("文案") },
            publishHandler: { _, _ in
                published = true
                return true
            },
            ledger: ledger,
            targetSpacingSeconds: 0,
            dryRunProvider: { true },
            onDraft: { _, _ in drafted += 1 }
        )
        await scheduler.fire(settings: settings, scheduledAt: Date())
        XCTAssertFalse(published)
        XCTAssertEqual(drafted, 1, "演练预览不受真实当日配额限制")
        let state = await ledger.state(for: "wxid_a", on: Date())
        XCTAssertEqual(state.count, 2, "演练不得改写真实发布账本")
    }

    /// 2026-11-10 实况：当天额度已用完时到点会静默跳过（只记「跳过 1」）。
    /// 现在必须把原因写进「上次结果」，并把下一次顺延到次日第一个时刻。
    func testDailyLimitSkipReasonSurfacesAndNextFireSkipsToTomorrow() async {
        let (defaults, suite) = suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let ledger = SnsPublishLedger(accountID: "wxid_test", defaults: defaults)
        var settings = makeSettings(targetIDs: ["wxid_a"])
        settings.publish.mode = .times
        settings.publish.times = [
            SnsPublishTime(id: "am", minute: 10 * 60),
            SnsPublishTime(id: "pm", minute: 20 * 60)
        ]
        // 今天容量 2，已经发满 2 次 → 10:00 到点必然被跳过。
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 10))!
        await ledger.record(targetID: "wxid_a", at: now.addingTimeInterval(-3600), calendar: cal)
        await ledger.record(targetID: "wxid_a", at: now.addingTimeInterval(-1800), calendar: cal)
        var published = false
        var summary: SnsPublishRunSummary?
        let scheduler = SnsPublishScheduler(
            settingsProvider: { settings },
            targetsProvider: { [self.target("wxid_a")] },
            draftProvider: { _ in .success("文案") },
            publishHandler: { _, _ in
                published = true
                return true
            },
            ledger: ledger,
            targetSpacingSeconds: 0,
            onRunCompleted: { summary = $0 },
            calendar: cal
        )
        await scheduler.fire(settings: settings, scheduledAt: now, now: now)
        XCTAssertFalse(published, "当日额度用尽后不得继续提交发布请求")
        XCTAssertEqual(summary?.sentCount, 0)
        XCTAssertEqual(summary?.skippedCount, 1)
        XCTAssertEqual(
            summary?.skipNote,
            Lf("今天已发 %d 次，达到每人每天 %d 次的上限，本轮未发送", 2, 2)
        )
        // 今天 20:00 虽然还有一个时刻，但额度已满：下一次应直接是明天 10:00。
        let tomorrow = cal.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 10))!
        XCTAssertEqual(summary?.nextFireAt, tomorrow)
    }

    /// 「重置今日计数」只清今天、只清指定对象，其它日期/对象保留。
    func testLedgerClearTodayOnlyAffectsRequestedTargetAndDay() async {
        let (defaults, suite) = suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let ledger = SnsPublishLedger(accountID: "wxid_test", defaults: defaults)
        let today = cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
        let yesterday = cal.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12))!
        await ledger.record(targetID: "wxid_a", at: today, calendar: cal)
        await ledger.record(targetID: "wxid_b", at: today, calendar: cal)
        await ledger.record(targetID: "wxid_a", at: yesterday, calendar: cal)

        await ledger.clearToday(targetIDs: ["wxid_a"], on: today, calendar: cal)
        var a = await ledger.state(for: "wxid_a", on: today, calendar: cal)
        let b = await ledger.state(for: "wxid_b", on: today, calendar: cal)
        let old = await ledger.state(for: "wxid_a", on: yesterday, calendar: cal)
        XCTAssertEqual(a.count, 0, "指定对象今天计数要清空")
        XCTAssertEqual(b.count, 1, "未指定的对象不能被清")
        XCTAssertEqual(old.count, 1, "其它日期不能被清")

        await ledger.record(targetID: "wxid_a", at: today, calendar: cal)
        a = await ledger.state(for: "wxid_a", on: today, calendar: cal)
        XCTAssertEqual(a.count, 1, "清空后仍可正常记账")
    }

    /// 今日配额快照聚合：跨对象求和、无上限不计剩余、超额计数仍显示实际发送数。
    func testTodayUsageAggregate() {
        let exhausted = SnsPublishTodayUsage.aggregate(
            capacityPerTarget: 1, isUnlimited: false, sentPerTarget: [2]
        )
        XCTAssertEqual(exhausted.sentCount, 2)
        XCTAssertEqual(exhausted.remainingCount, 0)
        XCTAssertTrue(exhausted.isExhausted, "已发 2 次 / 上限 1 次应标记发满")

        let partial = SnsPublishTodayUsage.aggregate(
            capacityPerTarget: 2, isUnlimited: false, sentPerTarget: [1, 2]
        )
        XCTAssertEqual(partial.targetCount, 2)
        XCTAssertEqual(partial.sentCount, 3)
        XCTAssertEqual(partial.remainingCount, 1, "一个对象还剩 1 次")
        XCTAssertFalse(partial.isExhausted)

        let unlimited = SnsPublishTodayUsage.aggregate(
            capacityPerTarget: 50, isUnlimited: true, sentPerTarget: [3, 4]
        )
        XCTAssertTrue(unlimited.isUnlimited)
        XCTAssertEqual(unlimited.sentCount, 7)
        XCTAssertEqual(unlimited.remainingCount, 93, "无上限按 bridge 50 条/人兜底计算剩余")
        XCTAssertFalse(unlimited.isExhausted)

        let unlimitedFull = SnsPublishTodayUsage.aggregate(
            capacityPerTarget: 50, isUnlimited: true, sentPerTarget: [50, 50]
        )
        XCTAssertTrue(unlimitedFull.isExhausted, "无上限也要承认 bridge 每日 50 条兜底已到")
    }

    /// 有目标成功时不能把整轮说成「上次未发送」：skipNote 只描述整轮 0 发送/0 草稿。
    func testSkipNoteClearedWhenAnyTargetSucceeds() async {
        let (defaults, suite) = suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let ledger = SnsPublishLedger(accountID: "wxid_test", defaults: defaults)
        let settings = makeSettings(targetIDs: ["wxid_a", "wxid_b"])
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 9))!
        // a 的当日额度已满（times 容量 2），b 仍可发。
        await ledger.record(targetID: "wxid_a", at: now, calendar: cal)
        await ledger.record(targetID: "wxid_a", at: now, calendar: cal)
        var summary: SnsPublishRunSummary?
        let scheduler = SnsPublishScheduler(
            settingsProvider: { settings },
            targetsProvider: { [self.target("wxid_a"), self.target("wxid_b")] },
            draftProvider: { _ in .success("文案") },
            publishHandler: { _, _ in true },
            ledger: ledger,
            targetSpacingSeconds: 0,
            onRunCompleted: { summary = $0 },
            calendar: cal
        )
        await scheduler.fire(settings: settings, scheduledAt: now, now: now)
        XCTAssertEqual(summary?.sentCount, 1, "b 应成功")
        XCTAssertEqual(summary?.skippedCount, 1, "a 因额度跳过")
        XCTAssertNil(summary?.skipNote, "有成功目标时 skipNote 必须清空")
    }

    /// 「无上限」仍受 bridge 每日 50 条兜底限制；演练模式不占配额、不应顺延。
    func testDailyQuotaExhaustedHandlesUnlimitedAndDryRun() async {
        let (defaults, suite) = suiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = SnsPublishLedger(accountID: "wxid_test", defaults: defaults)
        var settings = makeSettings(targetIDs: ["wxid_a"])
        settings.publish.mode = .windows
        settings.publish.maxPerDay = 0
        settings.publish.windows = [SnsPublishWindow(id: "all", startMinute: 9 * 60, endMinute: 22 * 60)]
        var dryRun = false
        let scheduler = SnsPublishScheduler(
            settingsProvider: { settings },
            targetsProvider: { [self.target("wxid_a")] },
            draftProvider: { _ in .success("文案") },
            publishHandler: { _, _ in true },
            ledger: ledger,
            targetSpacingSeconds: 0,
            dryRunProvider: { dryRun }
        )
        let now = Date()
        for _ in 0..<49 {
            await ledger.record(targetID: "wxid_a", at: now)
        }
        var exhausted = await scheduler.dailyQuotaExhausted(
            publish: settings.publish,
            targets: [target("wxid_a")],
            on: now
        )
        XCTAssertFalse(exhausted, "49/50 仍有兜底额度")
        await ledger.record(targetID: "wxid_a", at: now)
        exhausted = await scheduler.dailyQuotaExhausted(
            publish: settings.publish,
            targets: [target("wxid_a")],
            on: now
        )
        XCTAssertTrue(exhausted, "无上限也受 bridge 每日 50 条兜底限制")

        dryRun = true
        await ledger.record(targetID: "wxid_a", at: now)
        exhausted = await scheduler.dailyQuotaExhausted(
            publish: settings.publish,
            targets: [target("wxid_a")],
            on: now
        )
        XCTAssertFalse(exhausted, "演练模式不占真实配额，不应顺延到明天")
    }
}


// MARK: - 待确认草稿存储

@MainActor
final class SnsOutboxStoreTests: XCTestCase {
    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sns-outbox-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testAddPersistsAndReloads() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SnsOutboxStore(directoryProvider: { dir })
        store.load(accountID: "wxid_a")
        XCTAssertTrue(store.drafts.isEmpty)

        let draft = SnsPendingDraft(
            text: "  今天天气不错  ",
            targetUserID: "wxid_friend",
            targetName: "示例昵称"
        )
        store.add(draft)
        XCTAssertEqual(store.drafts.count, 1)

        let reloaded = SnsOutboxStore(directoryProvider: { dir })
        reloaded.load(accountID: "wxid_a")
        XCTAssertEqual(reloaded.drafts.count, 1)
        XCTAssertEqual(reloaded.drafts.first?.text, "  今天天气不错  ")
        XCTAssertEqual(reloaded.drafts.first?.displayTarget, "示例昵称")

        reloaded.remove(id: draft.id)
        XCTAssertTrue(reloaded.drafts.isEmpty)
        let afterRemove = SnsOutboxStore(directoryProvider: { dir })
        afterRemove.load(accountID: "wxid_a")
        XCTAssertTrue(afterRemove.drafts.isEmpty)
    }

    func testMaxCountDropsOldest() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SnsOutboxStore(directoryProvider: { dir })
        store.load(accountID: "wxid_a")
        for index in 0..<(SnsOutboxStore.maxCount + 5) {
            store.add(SnsPendingDraft(
                id: "d\(index)",
                text: "文案 \(index)",
                targetUserID: "wxid_friend"
            ))
        }
        XCTAssertEqual(store.drafts.count, SnsOutboxStore.maxCount)
        XCTAssertEqual(store.drafts.first?.id, "d5", "超出上限时丢弃最旧草稿")
        XCTAssertEqual(store.drafts.last?.id, "d\(SnsOutboxStore.maxCount + 4)")
    }

    func testCorruptFileFallsBackToEmpty() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("not json".utf8).write(to: dir.appendingPathComponent("sns-outbox.json"))
        let store = SnsOutboxStore(directoryProvider: { dir })
        store.load(accountID: "wxid_a")
        XCTAssertTrue(store.drafts.isEmpty)
    }

    /// 旧文件/手工编辑可能超过上限：加载时收敛到 maxCount，保留最新的草稿。
    func testLoadClampsFileToMaxCount() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let drafts = (0..<(SnsOutboxStore.maxCount + 6)).map { index in
            SnsPendingDraft(id: "d\(index)", text: "文案 \(index)", targetUserID: "wxid_friend")
        }
        try encoder.encode(drafts).write(to: dir.appendingPathComponent("sns-outbox.json"))

        let store = SnsOutboxStore(directoryProvider: { dir })
        store.load(accountID: "wxid_a")
        XCTAssertEqual(store.drafts.count, SnsOutboxStore.maxCount)
        XCTAssertEqual(store.drafts.first?.id, "d6", "保留最新草稿")
        XCTAssertEqual(store.drafts.last?.id, "d\(SnsOutboxStore.maxCount + 5)")
    }
}

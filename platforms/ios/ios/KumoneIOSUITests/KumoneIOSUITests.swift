import UIKit
import XCTest

final class KumoneIOSUITests: XCTestCase {
    @MainActor
    private func assertEventually(
        _ query: XCUIElementQuery,
        count expectedCount: Int,
        timeout: TimeInterval,
        message: String
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in query.count == expectedCount },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed,
            message
        )
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The deck slides in when revealed; wait for the row to settle instead
    /// of sampling the first animation frame.
    @MainActor
    private func assertSettles(
        _ element: XCUIElement,
        atMidY expected: CGFloat,
        timeout: TimeInterval = 3,
        message: String
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                // A snapshot, not `frame`: reading `frame` of an element that
                // vanished between checks is a fatal test error.
                guard let snapshot = try? element.snapshot() else { return false }
                return abs(snapshot.frame.midY - expected) <= 1
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, message)
    }

    /// The player's dark artwork backdrop must reach the very top and bottom
    /// of the screen. A clip on the safe-area frame once left the status-bar
    /// band and the bottom edge showing the light app behind the player.
    @MainActor
    private func assertPlayerCoversScreenEdges(
        _ app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Give the zoom-in presentation time to settle on its final frame.
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "presentation settles")], timeout: 1.5)
        let screenshot = XCUIScreen.main.screenshot().image
        guard let cgImage = screenshot.cgImage else {
            XCTFail("Could not read the player screenshot", file: file, line: line)
            return
        }
        let scale = CGFloat(cgImage.width) / screenshot.size.width
        // Left edge, clear of the clock text, the Dynamic Island and the
        // white home indicator in the bottom centre.
        let samples: [(String, CGPoint)] = [
            ("top", CGPoint(x: 24, y: 4)),
            ("bottom", CGPoint(x: 24, y: screenshot.size.height - 4))
        ]
        for (edge, point) in samples {
            let luminance = Self.luminance(of: cgImage, x: Int(point.x * scale), y: Int(point.y * scale))
            XCTAssertLessThan(luminance, 0.6,
                              "The player backdrop must cover the \(edge) edge (luminance \(luminance))",
                              file: file, line: line)
        }
    }

    private static func luminance(of image: CGImage, x: Int, y: Int) -> CGFloat {
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // Core Graphics is bottom-up: shift the image so pixel (x, y),
            // counted from the top, lands on the context's single pixel.
            context.draw(image, in: CGRect(
                x: -x, y: y - image.height + 1,
                width: image.width, height: image.height
            ))
            return true
        }
        guard drawn else { return 1 }
        let r = CGFloat(pixel[0]) / 255, g = CGFloat(pixel[1]) / 255, b = CGFloat(pixel[2]) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// Let a lyric flick finish decelerating so the next tap is a tap, not
    /// a scroll-stop the scroll view swallows.
    @MainActor
    private func waitForScrollToSettle() {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "scroll settles")], timeout: 1.5)
    }

    @MainActor
    func testMainTabsNavigateAndCaptureScreens() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-imusic-ui-testing"]
        app.launch()

        let tabs = app.tabBars.buttons
        let destinations = [
            (tab: "主页", title: "主页"),
            (tab: "新发现", title: "新发现"),
            (tab: "电台", title: "电台"),
            (tab: "资料库", title: "资料库"),
            (tab: "搜索", title: "搜索"),
        ]

        for destination in destinations {
            let button = tabs[destination.tab]
            XCTAssertTrue(button.waitForExistence(timeout: 15), "Missing tab: \(destination.tab)")
            XCTAssertTrue(button.isHittable, "Tab is not tappable: \(destination.tab)")
            if !button.isSelected {
                button.tap()
            }
            XCTAssertTrue(button.isSelected, "Tab \(destination.tab) should be selected")

            let navigationTitle = app.navigationBars[destination.title]
            XCTAssertTrue(
                navigationTitle.waitForExistence(timeout: 20),
                "Tab \(destination.tab) did not show its root navigation title"
            )
            if destination.tab == "搜索" {
                XCTAssertTrue(app.staticTexts["热门搜索"].waitForExistence(timeout: 5),
                              "Search landing shows trending searches")
                XCTAssertFalse(app.staticTexts["快速浏览"].exists,
                               "Search landing no longer shows category tiles")
            }
            if destination.tab == "资料库" {
                XCTAssertTrue(
                    app.staticTexts["我的播放列表"].waitForExistence(timeout: 5),
                    "The library should keep its playlists section visible even when it is empty"
                )
            }
            if destination.tab == "新发现" {
                let topAttachment = XCTAttachment(screenshot: app.screenshot())
                topAttachment.name = "iMusic-新发现-顶部"
                topAttachment.lifetime = .keepAlways
                add(topAttachment)

                XCTAssertTrue(
                    app.staticTexts["按类型浏览"].waitForExistence(timeout: 5),
                    "New Discovery should expose its local genre browser without requiring network content"
                )
                XCTAssertTrue(
                    app.scrollViews["exploreContentScrollView"].waitForExistence(timeout: 5),
                    "New Discovery should expose a stable, accessible content scroll view"
                )
                let mandarinGenre = app.buttons["浏览华语音乐"]
                XCTAssertTrue(mandarinGenre.waitForExistence(timeout: 5))
                XCTAssertTrue(mandarinGenre.isHittable, "The local genre card should be visible at the top")
                mandarinGenre.tap()
                XCTAssertTrue(mandarinGenre.isSelected, "Selecting a genre should update its selected state")
                let genreAttachment = XCTAttachment(screenshot: app.screenshot())
                genreAttachment.name = "iMusic-新发现-类型"
                genreAttachment.lifetime = .keepAlways
                add(genreAttachment)
                continue
            }

            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "iMusic-\(destination.tab)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    func testLibrarySyncEntryNavigatesFromLibrary() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-imusic-ui-testing"]
        app.launch()

        let libraryTab = app.tabBars.buttons["资料库"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 15))
        libraryTab.tap()
        XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 10))

        let syncEntry = app.buttons["librarySyncEntry"]
        XCTAssertTrue(syncEntry.waitForExistence(timeout: 5), "The library should expose its LX sync entry")
        for _ in 0..<2 where !syncEntry.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(syncEntry.isHittable, "The LX sync entry should be reachable with at most two swipes")
        syncEntry.tap()

        XCTAssertTrue(
            app.navigationBars["LX 多设备同步"].waitForExistence(timeout: 10),
            "The library sync entry should open the LX multi-device sync settings page"
        )

        let backButton = app.navigationBars["LX 多设备同步"].buttons["资料库"]
        XCTAssertTrue(backButton.waitForExistence(timeout: 5), "The sync page should provide navigation back to the library")
        backButton.tap()
        XCTAssertTrue(
            app.navigationBars["资料库"].waitForExistence(timeout: 10),
            "Returning from LX sync settings should leave the user on the library tab"
        )
    }

    @MainActor
    func testAccountSyncShowsOnlySelectedChannel() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-imusic-ui-testing"]
        app.launch()
        let library = app.tabBars.buttons["资料库"]
        XCTAssertTrue(library.waitForExistence(timeout: 15))
        library.tap()
        app.buttons["更多资料库选项"].tap()
        app.buttons["设置"].tap()
        let accountLink = app.buttons["账号同步"]
        if !accountLink.isHittable { app.swipeUp() }
        XCTAssertTrue(accountLink.waitForExistence(timeout: 5))
        accountLink.tap()
        let picker = app.segmentedControls["accountSyncChannelPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["accountLogin-netease"].exists)
        XCTAssertFalse(app.buttons["accountLogin-qq"].exists)
        picker.buttons["QQ 音乐"].tap()
        XCTAssertTrue(app.buttons["accountLogin-qq"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["accountLogin-netease"].exists)
        picker.buttons["网易云"].tap()
        XCTAssertTrue(app.buttons["accountLogin-netease"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["accountLogin-qq"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "iMusic-账号同步-渠道切换"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testAppleMusicPlayerSongAndLyricsPages() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-imusic-ui-testing",
            "-imusic-ui-player-fixture",
            "-imusic-ui-extended-lyrics-controls",
            // Light app behind the player, so a backdrop that stops short of
            // the screen edges shows up as bright pixels.
            "-settings.appearance", "light"
        ]
        app.launch()

        let miniPlayer = app.buttons["miniPlayerOpenNowPlaying"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
        miniPlayer.tap()

        let songPage = app.descendants(matching: .any)["appleMusicSongPage"]
        XCTAssertTrue(songPage.waitForExistence(timeout: 10))
        let artwork = app.descendants(matching: .any)["nowPlayingArtworkImage"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 5))
        let bottomControls = app.descendants(matching: .any)["nowPlayingBottomControls"]
        XCTAssertTrue(bottomControls.waitForExistence(timeout: 5), "The bottom playback deck must be available for reveal taps")
        let accessoryControls = app.buttons["showSynchronizedLyrics"]
        XCTAssertTrue(accessoryControls.exists)
        let songAccessoryMidY = accessoryControls.frame.midY
        XCTAssertTrue(app.descendants(matching: .any)["nowPlayingTransportControls"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["nowPlayingVolumeControl"].exists)
        assertPlayerCoversScreenEdges(app)

        let songAttachment = XCTAttachment(screenshot: app.screenshot())
        songAttachment.name = "iMusic-AppleMusic-歌曲页"
        songAttachment.lifetime = .keepAlways
        add(songAttachment)

        // The add-to-playlist sheet is a full navigation sheet: title bar,
        // Done and a New Playlist row; it no longer repeats the song.
        app.buttons["更多操作"].firstMatch.tap()
        let addToPlaylist = app.buttons["加入歌单…"]
        XCTAssertTrue(addToPlaylist.waitForExistence(timeout: 5))
        addToPlaylist.tap()
        let sheetBar = app.navigationBars["收藏到歌单"]
        XCTAssertTrue(sheetBar.waitForExistence(timeout: 5), "Add to playlist must open as a titled sheet")
        XCTAssertTrue(app.buttons["addToPlaylistNewPlaylist"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["addToPlaylistSelection"].exists,
                       "The sheet must not repeat the song being saved")
        let sheetAttachment = XCTAttachment(screenshot: app.screenshot())
        sheetAttachment.name = "iMusic-收藏到歌单"
        sheetAttachment.lifetime = .keepAlways
        add(sheetAttachment)
        app.buttons["addToPlaylistDone"].tap()
        XCTAssertTrue(sheetBar.waitForNonExistence(timeout: 5))
        XCTAssertTrue(songPage.waitForExistence(timeout: 5))

        app.buttons["showSynchronizedLyrics"].tap()
        let lyricsPage = app.descendants(matching: .any)["appleMusicLyricsPage"]
        XCTAssertTrue(lyricsPage.waitForExistence(timeout: 10))
        let lyricsScroll = app.scrollViews["synchronizedLyricsScrollView"]
        XCTAssertTrue(lyricsScroll.waitForExistence(timeout: 10))
        let transportControls = app.descendants(matching: .any)["lyricsTransportControls"]
        let volumeControl = app.descendants(matching: .any)["lyricsVolumeControl"]
        let initialVisibleControls = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier IN %@", ["lyricsTransportControls", "lyricsVolumeControl"])
        )
        let songTransportControls = app.descendants(matching: .any)["nowPlayingTransportControls"]
        // Full-screen lyrics: after the initial auto-hide the whole deck,
        // accessory row included, leaves the screen like the system player.
        XCTAssertTrue(transportControls.waitForNonExistence(timeout: 20),
                      "Lyrics transport controls must initially auto-hide")
        XCTAssertTrue(volumeControl.waitForNonExistence(timeout: 20),
                      "Lyrics volume control must initially auto-hide")
        XCTAssertTrue(accessoryControls.waitForNonExistence(timeout: 5),
                      "Full-screen lyrics must hide the bottom accessory row too")
        // Tapping the lower part of the lyrics page brings the deck back.
        lyricsPage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        assertEventually(
            initialVisibleControls,
            count: 2,
            timeout: 5,
            message: "Lyrics transport and volume controls must be visible together after reveal"
        )
        XCTAssertTrue(accessoryControls.waitForExistence(timeout: 5),
                      "Revealing controls must bring the accessory row back")
        assertSettles(accessoryControls, atMidY: songAccessoryMidY,
                      message: "The accessory row must reappear at the song page's position")
        XCTAssertTrue(transportControls.waitForNonExistence(timeout: 20),
                      "Lyrics transport controls must be removed from the accessibility tree when hidden")
        XCTAssertTrue(volumeControl.waitForNonExistence(timeout: 20),
                      "Lyrics volume control must be removed from the accessibility tree when hidden")
        XCTAssertTrue(accessoryControls.waitForNonExistence(timeout: 5),
                      "The accessory row must hide again with the controls")

        // Swiping toward the song page's side is the only horizontal swipe
        // that changes page; the opposite direction stays on lyrics.
        lyricsScroll.swipeLeft()
        XCTAssertTrue(lyricsPage.exists, "A left swipe on lyrics must not leave the lyrics page")
        XCTAssertFalse(songTransportControls.exists)
        XCTAssertFalse(transportControls.exists, "Transport controls must remain hidden during lyric browsing")

        lyricsScroll.swipeUp()
        XCTAssertTrue(lyricsPage.exists, "Vertical lyric scrolling must not navigate away from lyrics")
        XCTAssertFalse(transportControls.exists, "Browsing lyrics must not reveal the playback deck")
        waitForScrollToSettle()
        lyricsPage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        let revealedPlaybackState = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier IN %@ OR (elementType == %@ AND label == %@) OR (elementType == %@ AND label == %@)",
                ["lyricsTransportControls", "lyricsVolumeControl"],
                NSNumber(value: XCUIElement.ElementType.staticText.rawValue), "0:14",
                NSNumber(value: XCUIElement.ElementType.button.rawValue), "选择播放音质，当前为请求 320 kbps"
            )
        )
        assertEventually(
            revealedPlaybackState,
            count: 4,
            timeout: 2,
            message: "Revealed playback state must simultaneously contain transport, volume, 0:14, and the current quality button"
        )
        XCTAssertTrue(app.buttons["showSynchronizedLyrics"].exists, "Revealed lyrics need the same bottom toolbar")
        app.buttons["showSynchronizedLyrics"].tap()
        XCTAssertTrue(songTransportControls.waitForExistence(timeout: 5))
        XCTAssertTrue(songPage.waitForExistence(timeout: 5))
        XCTAssertTrue(lyricsPage.waitForNonExistence(timeout: 5))
        // Besides the button, a left swipe on the song page opens lyrics and
        // a right swipe on lyrics returns to the song page.
        artwork.swipeLeft()
        XCTAssertTrue(lyricsPage.waitForExistence(timeout: 5), "A left swipe on the song page must open lyrics")
        XCTAssertTrue(songPage.waitForNonExistence(timeout: 5))
        lyricsScroll.swipeRight()
        XCTAssertTrue(songPage.waitForExistence(timeout: 5), "A right swipe on lyrics must return to the song page")
        XCTAssertTrue(lyricsPage.waitForNonExistence(timeout: 5))
        app.buttons["showSynchronizedLyrics"].tap()
        XCTAssertTrue(lyricsPage.waitForExistence(timeout: 5))
        XCTAssertTrue(transportControls.waitForNonExistence(timeout: 20),
                      "Lyrics transport controls must auto-hide after returning from the song page")

        let lyricsAttachment = XCTAttachment(screenshot: app.screenshot())
        lyricsAttachment.name = "iMusic-AppleMusic-歌词页"
        lyricsAttachment.lifetime = .keepAlways
        add(lyricsAttachment)

        XCUIDevice.shared.orientation = .landscapeLeft
        let window = app.windows.firstMatch
        let landscapeExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let frame = window.frame
                return CGFloat(frame.size.width) > CGFloat(frame.size.height)
            },
            object: window
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [landscapeExpectation], timeout: 5),
            .completed,
            "The app window must become wider than it is tall after rotating to landscape"
        )
        XCTAssertTrue(accessoryControls.waitForExistence(timeout: 5))
        let landscapeAccessoryMidY = accessoryControls.frame.midY
        accessoryControls.tap()
        XCTAssertTrue(songPage.waitForExistence(timeout: 5))
        XCTAssertEqual(accessoryControls.frame.midY, landscapeAccessoryMidY, accuracy: 1.0,
                       "The accessory row must keep its position in landscape")
        accessoryControls.tap()
        XCTAssertTrue(lyricsPage.waitForExistence(timeout: 5))
        XCTAssertEqual(accessoryControls.frame.midY, landscapeAccessoryMidY, accuracy: 1.0,
                       "The accessory row must remain fixed on landscape lyrics")
        XCUIDevice.shared.orientation = .portrait
    }

    /// Diagnostic for a light rim reported on device for ~2s after the player
    /// opens. The player opens by itself (no tap, so XCUITest never waits for
    /// idle) while the screen is sampled continuously in light appearance.
    /// Each frame logs corner and edge luminance as `EDGE-TIMELINE` lines;
    /// frames around the opening are attached. Log-only for now.
    @MainActor
    func testPlayerOpeningEdgeTimeline() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-imusic-ui-testing",
            "-imusic-ui-player-fixture",
            "-imusic-ui-auto-open-player",
            "-settings.appearance", "light"
        ]
        app.launch()

        let first = XCUIScreen.main.screenshot().image
        let size = first.size
        print("EDGE-TIMELINE screen \(Int(size.width))x\(Int(size.height))pt scale \(first.scale)")
        let points: [(String, CGPoint)] = [
            ("cornerTL", CGPoint(x: 6, y: 6)),
            ("cornerTR", CGPoint(x: size.width - 6, y: 6)),
            ("cornerBL", CGPoint(x: 6, y: size.height - 6)),
            ("cornerBR", CGPoint(x: size.width - 6, y: size.height - 6)),
            ("top", CGPoint(x: size.width * 0.25, y: 3)),
            ("left", CGPoint(x: 2, y: size.height * 0.5)),
            ("right", CGPoint(x: size.width - 2, y: size.height * 0.5)),
            ("bottom", CGPoint(x: size.width * 0.25, y: size.height - 2)),
            ("center", CGPoint(x: size.width * 0.5, y: size.height * 0.62))
        ]

        let start = Date()
        var openedAt: TimeInterval?
        var attachedMarks = Set<Int>()
        while Date().timeIntervalSince(start) < 16 {
            let shot = XCUIScreen.main.screenshot()
            let elapsed = Date().timeIntervalSince(start)
            guard let image = shot.image.cgImage else { continue }
            let scale = CGFloat(image.width) / shot.image.size.width
            let values = points.map { name, point -> (String, CGFloat) in
                (name, Self.luminance(of: image, x: Int(point.x * scale), y: Int(point.y * scale)))
            }
            let line = values.map { "\($0.0)=\(String(format: "%.2f", $0.1))" }.joined(separator: " ")
            let center = values.last?.1 ?? 1
            if openedAt == nil && center < 0.5 { openedAt = elapsed }
            let sinceOpen = openedAt.map { elapsed - $0 }
            print("EDGE-TIMELINE t=\(String(format: "%.2f", elapsed)) open=\(sinceOpen.map { String(format: "%.2f", $0) } ?? "-") \(line)")

            // Attach the opening frame and roughly every 0.5s for 3s after.
            if let sinceOpen {
                let mark = Int((sinceOpen / 0.5).rounded(.down))
                if mark <= 6 && attachedMarks.insert(mark).inserted {
                    let attachment = XCTAttachment(screenshot: shot)
                    attachment.name = "player-open+\(String(format: "%.1f", sinceOpen))s"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                if sinceOpen > 5 { break }
            }
        }
        print("EDGE-TIMELINE openedAt=\(openedAt.map { String(format: "%.2f", $0) } ?? "never")")
    }

    @MainActor
    func testLyricsControlsAutoHideWithDefaultTiming() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-imusic-ui-testing", "-imusic-ui-player-fixture"]
        app.launch()

        let miniPlayer = app.buttons["miniPlayerOpenNowPlaying"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
        miniPlayer.tap()

        let songPage = app.descendants(matching: .any)["appleMusicSongPage"]
        XCTAssertTrue(songPage.waitForExistence(timeout: 10))
        let accessoryControls = app.buttons["showSynchronizedLyrics"]
        XCTAssertTrue(accessoryControls.waitForExistence(timeout: 5))

        accessoryControls.tap()
        let lyricsPage = app.descendants(matching: .any)["appleMusicLyricsPage"]
        XCTAssertTrue(lyricsPage.waitForExistence(timeout: 10))
        let lyricsScroll = app.scrollViews["synchronizedLyricsScrollView"]
        XCTAssertTrue(lyricsScroll.waitForExistence(timeout: 10))

        let transportControls = app.descendants(matching: .any)["lyricsTransportControls"]
        let volumeControl = app.descendants(matching: .any)["lyricsVolumeControl"]
        // The real three-second window can finish during XCTest navigation
        // waits. The long interaction test separately verifies visible controls;
        // this default-policy smoke verifies eventual full-screen hiding,
        // that a tap in the lower area restores the row, and pull-to-close.
        XCTAssertTrue(transportControls.waitForNonExistence(timeout: 7),
                      "Default lyrics transport controls must eventually auto-hide")
        XCTAssertTrue(volumeControl.waitForNonExistence(timeout: 7),
                      "Default lyrics volume control must eventually auto-hide")
        XCTAssertTrue(accessoryControls.waitForNonExistence(timeout: 5),
                      "Full-screen lyrics must hide the accessory row")
        lyricsPage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        // Only presence here: the default 3s auto-hide races a position
        // check. The extended-controls test asserts the fixed position.
        XCTAssertTrue(accessoryControls.waitForExistence(timeout: 5),
                      "A tap in the lower area must bring the controls back")

        // Pulling the grabber down must close the player. On iPhone this is
        // the system zoom dismissal (the same shrink as a pull on the cover),
        // so the pull is a quick fling like a real one.
        let grabber = app.descendants(matching: .any)["nowPlayingDismissIndicator"]
        XCTAssertTrue(grabber.waitForExistence(timeout: 5))
        let start = grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(
            forDuration: 0.05,
            thenDragTo: start.withOffset(CGVector(dx: 0, dy: 520)),
            withVelocity: .fast,
            thenHoldForDuration: 0
        )
        XCTAssertTrue(lyricsPage.waitForNonExistence(timeout: 8),
                      "Dragging the grabber down must dismiss the player")
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5),
                      "The mini player must be back after dismissing")
    }
}

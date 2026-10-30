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
                XCTAssertTrue(app.staticTexts["快速浏览"].waitForExistence(timeout: 5))
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
            "-imusic-ui-extended-lyrics-controls"
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

        let songAttachment = XCTAttachment(screenshot: app.screenshot())
        songAttachment.name = "iMusic-AppleMusic-歌曲页"
        songAttachment.lifetime = .keepAlways
        add(songAttachment)

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
        // Wait for the initial auto-hide before tapping the reveal footprint.
        // Otherwise a fast simulator could tap the still-visible play button.
        XCTAssertTrue(transportControls.waitForNonExistence(timeout: 20),
                      "Lyrics transport controls must initially auto-hide")
        XCTAssertTrue(volumeControl.waitForNonExistence(timeout: 20),
                      "Lyrics volume control must initially auto-hide")
        XCTAssertTrue(accessoryControls.exists, "Auto-hide must preserve the accessory row")
        XCTAssertEqual(accessoryControls.frame.midY, songAccessoryMidY, accuracy: 1.0,
                       "The accessory row must remain fixed after initial auto-hide")
        bottomControls.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
        // The lyrics page animates its control reveal after the navigation
        // transition. Assert eventual visibility rather than sampling the
        // first frame after the tap, which is flaky on slower CI simulators.
        assertEventually(
            initialVisibleControls,
            count: 2,
            timeout: 5,
            message: "Lyrics transport and volume controls must be visible together after reveal"
        )
        XCTAssertTrue(accessoryControls.exists, "The accessory row must stay visible on both player pages")
        XCTAssertEqual(accessoryControls.frame.midY, songAccessoryMidY, accuracy: 1.0,
                       "The accessory row must not jump when switching to lyrics")
        XCTAssertTrue(transportControls.waitForNonExistence(timeout: 20),
                      "Lyrics transport controls must be removed from the accessibility tree when hidden")
        XCTAssertTrue(volumeControl.waitForNonExistence(timeout: 20),
                      "Lyrics volume control must be removed from the accessibility tree when hidden")
        XCTAssertTrue(accessoryControls.exists, "Hiding playback controls must not hide the accessory row")
        XCTAssertEqual(accessoryControls.frame.midY, songAccessoryMidY, accuracy: 1.0,
                       "The accessory row must remain at the same height after controls hide")

        lyricsScroll.swipeRight()
        XCTAssertTrue(lyricsPage.exists, "Horizontal swipes must stay on lyrics")
        XCTAssertFalse(songTransportControls.exists)
        XCTAssertFalse(transportControls.exists, "Transport controls must remain hidden during lyric browsing")

        lyricsScroll.swipeUp()
        XCTAssertTrue(lyricsPage.exists, "Vertical lyric scrolling must not navigate away from lyrics")
        XCTAssertFalse(transportControls.exists, "Transport controls must remain hidden until the playback deck is tapped")
        let returnToPlayback = app.buttons["resumeCurrentLyrics"]
        XCTAssertTrue(returnToPlayback.waitForExistence(timeout: 5), "Browsing lyrics should offer a clear return-to-current-line action")
        returnToPlayback.tap()
        XCTAssertTrue(returnToPlayback.waitForNonExistence(timeout: 5), "Returning to the current line should leave lyric browse mode")
        bottomControls.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
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
        XCTAssertTrue(app.buttons["showSynchronizedLyrics"].exists, "Lyrics need the same bottom toolbar")
        // Time and quality were checked in the same snapshot above; querying
        // them again serially could run past even the extended test window.
        app.buttons["showSynchronizedLyrics"].tap()
        XCTAssertTrue(songTransportControls.waitForExistence(timeout: 5))
        XCTAssertTrue(songPage.exists)
        artwork.swipeLeft()
        XCTAssertTrue(songPage.exists, "Switch pages only with the lyrics button")
        app.buttons["showSynchronizedLyrics"].tap()
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
        let songAccessoryMidY = accessoryControls.frame.midY

        accessoryControls.tap()
        let lyricsPage = app.descendants(matching: .any)["appleMusicLyricsPage"]
        XCTAssertTrue(lyricsPage.waitForExistence(timeout: 10))
        let lyricsScroll = app.scrollViews["synchronizedLyricsScrollView"]
        XCTAssertTrue(lyricsScroll.waitForExistence(timeout: 10))

        let transportControls = app.descendants(matching: .any)["lyricsTransportControls"]
        let volumeControl = app.descendants(matching: .any)["lyricsVolumeControl"]
        // The real three-second window can finish during XCTest navigation
        // waits. The long interaction test separately verifies visible controls;
        // this default-policy smoke verifies eventual hiding and a fixed toolbar.
        XCTAssertTrue(transportControls.waitForNonExistence(timeout: 7),
                      "Default lyrics transport controls must eventually auto-hide")
        XCTAssertTrue(volumeControl.waitForNonExistence(timeout: 7),
                      "Default lyrics volume control must eventually auto-hide")
        XCTAssertTrue(accessoryControls.exists, "Auto-hide must preserve the accessory row")
        XCTAssertEqual(accessoryControls.frame.midY, songAccessoryMidY, accuracy: 1.0,
                       "The accessory row must remain fixed after auto-hide")
    }
}

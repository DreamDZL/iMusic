import XCTest

final class KumoneIOSUITests: XCTestCase {
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
            (tab: "广播", title: "漫游"),
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
                XCTAssertTrue(
                    app.staticTexts["搜索歌曲、歌手、专辑或歌单"].waitForExistence(timeout: 5),
                    "Search should show its offline empty-state prompt before the user enters a query"
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
        app.launchArguments = ["-imusic-ui-testing", "-imusic-ui-player-fixture"]
        app.launch()

        let miniPlayer = app.buttons["miniPlayerOpenNowPlaying"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 15))
        miniPlayer.tap()

        let songPage = app.descendants(matching: .any)["appleMusicSongPage"]
        XCTAssertTrue(songPage.waitForExistence(timeout: 10))
        let artwork = app.descendants(matching: .any)["nowPlayingArtworkImage"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 5))
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
        let songTransportControls = app.descendants(matching: .any)["nowPlayingTransportControls"]
        XCTAssertTrue(transportControls.exists)
        XCTAssertTrue(volumeControl.exists)
        XCTAssertTrue(accessoryControls.exists, "The accessory row must stay visible on both player pages")
        XCTAssertEqual(accessoryControls.frame.midY, songAccessoryMidY, accuracy: 1.0,
                       "The accessory row must not jump when switching to lyrics")
        XCTAssertTrue(transportControls.waitForNonExistence(timeout: 7))
        XCTAssertTrue(volumeControl.waitForNonExistence(timeout: 7))
        XCTAssertTrue(accessoryControls.exists, "Hiding playback controls must not hide the accessory row")
        XCTAssertEqual(accessoryControls.frame.midY, songAccessoryMidY, accuracy: 1.0,
                       "The accessory row must remain at the same height after controls hide")

        lyricsScroll.swipeRight()
        XCTAssertTrue(lyricsPage.exists, "Horizontal swipes must stay on lyrics")
        XCTAssertFalse(songTransportControls.exists)
        XCTAssertFalse(transportControls.exists)

        lyricsScroll.swipeUp()
        XCTAssertTrue(lyricsPage.exists)
        XCTAssertFalse(transportControls.exists)
        lyricsPage.coordinate(withNormalizedOffset: CGVector(dx: 0.82, dy: 0.94)).tap()
        XCTAssertTrue(transportControls.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["showSynchronizedLyrics"].exists, "Lyrics need the same bottom toolbar")
        XCTAssertTrue(app.staticTexts["0:14"].exists, "Scrolling and revealing controls must not seek")
        XCTAssertTrue(app.buttons["选择播放音质，当前为请求 320 kbps"].exists)
        app.buttons["showSynchronizedLyrics"].tap()
        XCTAssertTrue(songTransportControls.waitForExistence(timeout: 5))
        XCTAssertTrue(songPage.exists)
        artwork.swipeLeft()
        XCTAssertTrue(songPage.exists, "Switch pages only with the lyrics button")
        app.buttons["showSynchronizedLyrics"].tap()
        XCTAssertTrue(transportControls.waitForNonExistence(timeout: 7))

        let lyricsAttachment = XCTAttachment(screenshot: app.screenshot())
        lyricsAttachment.name = "iMusic-AppleMusic-歌词页"
        lyricsAttachment.lifetime = .keepAlways
        add(lyricsAttachment)

        XCUIDevice.shared.orientation = .landscapeLeft
        let window = app.windows.firstMatch
        let landscapeExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "frame.size.width > frame.size.height"),
            object: window
        )
        XCTAssertEqual(XCTWaiter.wait(for: [landscapeExpectation], timeout: 5), .completed)
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
}

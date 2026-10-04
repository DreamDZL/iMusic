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
        XCTAssertTrue(app.descendants(matching: .any)["nowPlayingArtworkImage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["showSynchronizedLyrics"].exists)
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
        let transportControls = app.descendants(matching: .any)["nowPlayingTransportControls"]
        let volumeControl = app.descendants(matching: .any)["nowPlayingVolumeControl"]
        XCTAssertTrue(transportControls.waitForNonExistence(timeout: 5))
        XCTAssertTrue(volumeControl.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["showSynchronizedLyrics"].waitForNonExistence(timeout: 5))

        lyricsScroll.swipeRight()
        XCTAssertTrue(transportControls.waitForExistence(timeout: 5))
        songPage.swipeLeft()
        XCTAssertTrue(transportControls.waitForNonExistence(timeout: 5))

        lyricsScroll.swipeUp()
        XCTAssertTrue(lyricsPage.exists)
        XCTAssertFalse(transportControls.exists)

        let lyricsAttachment = XCTAttachment(screenshot: app.screenshot())
        lyricsAttachment.name = "iMusic-AppleMusic-歌词页"
        lyricsAttachment.lifetime = .keepAlways
        add(lyricsAttachment)
    }
}

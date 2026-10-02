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
            (tab: "新内容", title: "新内容"),
            (tab: "搜索", title: "搜索"),
            (tab: "资料库", title: "资料库"),
        ]

        for destination in destinations {
            let button = tabs[destination.tab]
            XCTAssertTrue(button.waitForExistence(timeout: 45), "Missing tab: \(destination.tab)")
            if !button.isSelected {
                button.tap()
            }
            XCTAssertTrue(button.isSelected, "Tab \(destination.tab) should be selected")

            let navigationTitle = app.navigationBars[destination.title]
            XCTAssertTrue(
                navigationTitle.waitForExistence(timeout: 20),
                "Tab \(destination.tab) did not show its root navigation title"
            )
            let titleVisible = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hittable == true"),
                object: navigationTitle
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [titleVisible], timeout: 5),
                .completed,
                "Tab \(destination.tab) root title should be hittable"
            )
            if destination.tab == "新内容" {
                let topAttachment = XCTAttachment(screenshot: app.screenshot())
                topAttachment.name = "iMusic-新内容-顶部"
                topAttachment.lifetime = .keepAlways
                add(topAttachment)

                let genreCard = app.buttons["浏览华语音乐"]
                let contentScrollView = app.scrollViews.firstMatch
                XCTAssertTrue(contentScrollView.waitForExistence(timeout: 10))
                var swipeCount = 0
                while !genreCard.isHittable && swipeCount < 16 {
                    let start = contentScrollView.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.5, dy: 0.80)
                    )
                    let end = contentScrollView.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48)
                    )
                    start.press(forDuration: 0.05, thenDragTo: end)
                    swipeCount += 1
                }
                let genreCardHittable = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "hittable == true"),
                    object: genreCard
                )
                XCTAssertEqual(
                    XCTWaiter.wait(for: [genreCardHittable], timeout: 5),
                    .completed,
                    "New should expose a tappable genre card"
                )
                XCTAssertTrue(
                    app.staticTexts["按类型浏览"].exists,
                    "New should expose its genre browser before the paginated results"
                )
                let genreAttachment = XCTAttachment(screenshot: app.screenshot())
                genreAttachment.name = "iMusic-新内容-类型"
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
}

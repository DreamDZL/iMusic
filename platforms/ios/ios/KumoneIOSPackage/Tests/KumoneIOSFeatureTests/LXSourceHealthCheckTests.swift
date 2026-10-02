import XCTest
@testable import KumoneCore

@MainActor
final class LXSourceHealthCheckTests: XCTestCase {
    func testSyntheticHealthTrackIsOnlyUsedForNetease() {
        XCTAssertEqual(LXUserAPIService.sourceCheckTrack(for: "wy")?.source, "wy")
        XCTAssertNil(LXUserAPIService.sourceCheckTrack(for: "tx"))
        XCTAssertNil(LXUserAPIService.sourceCheckTrack(for: "kg"))
        XCTAssertNil(LXUserAPIService.sourceCheckTrack(for: "kw"))
        XCTAssertNil(LXUserAPIService.sourceCheckTrack(for: "mg"))
    }

    func testCheckingImportedSourceDoesNotChangePlaybackSelection() async {
        let store = LXSourceStore.shared
        let selectedBefore = store.selectedID
        let enabledBefore = store.enabledIDs
        let source = LXSourceStore.Source(
            id: "health-check-fixture",
            name: "Health check fixture",
            description: "In-memory test source",
            version: "1.0.0",
            author: "iMusic tests",
            homepage: "https://example.invalid",
            script: #"""
                lx.on(lx.EVENT_NAMES.request, async ({ action }) => {
                    if (action === "musicUrl") return "https://example.invalid/test.mp3"
                    throw new Error("Unexpected request: " + action)
                })
                lx.send(lx.EVENT_NAMES.inited, {
                    status: true,
                    sources: {
                        wy: { type: "music", actions: ["musicUrl"], qualitys: ["128k"] }
                    }
                })
                """#,
            sourceURL: nil
        )

        let result = await LXUserAPIService.shared.checkSource(source)

        XCTAssertTrue(result.isAvailable, result.detail ?? result.message)
        XCTAssertEqual(store.selectedID, selectedBefore)
        XCTAssertEqual(store.enabledIDs, enabledBefore)
    }

    func testCancellingHealthCheckStopsAnUnresolvedSourceRequest() async {
        let source = LXSourceStore.Source(
            id: "health-check-hanging-fixture",
            name: "Hanging health check fixture",
            description: "In-memory test source",
            version: "1.0.0",
            author: "iMusic tests",
            homepage: "https://example.invalid",
            script: #"""
                lx.on(lx.EVENT_NAMES.request, async () => new Promise(() => {}))
                lx.send(lx.EVENT_NAMES.inited, {
                    status: true,
                    sources: {
                        wy: { type: "music", actions: ["musicUrl"], qualitys: ["128k"] }
                    }
                })
                """#,
            sourceURL: nil
        )
        let task = Task { @MainActor in
            await LXUserAPIService.shared.checkSource(source)
        }

        try? await Task.sleep(for: .milliseconds(250))
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.message, "检测已取消")
    }

    func testSourceScriptRequestsCanUseTheNativeRequestBridge() async {
        let source = LXSourceStore.Source(
            id: "health-check-native-request-fixture",
            name: "Native request health check fixture",
            description: "Uses an unsupported local URL to exercise the callback without network access",
            version: "1.0.0",
            author: "iMusic tests",
            homepage: "https://example.invalid",
            script: #"""
                lx.on(lx.EVENT_NAMES.request, ({ action }) => {
                    if (action !== "musicUrl") throw new Error("Unexpected request: " + action)
                    return new Promise((resolve, reject) => {
                        lx.request("file:///health-check-local-only", {}, error => {
                            if (error) resolve("https://example.invalid/test.mp3")
                            else reject(new Error("The local fixture unexpectedly succeeded"))
                        })
                    })
                })
                lx.send(lx.EVENT_NAMES.inited, {
                    status: true,
                    sources: {
                        wy: { type: "music", actions: ["musicUrl"], qualitys: ["128k"] }
                    }
                })
                """#,
            sourceURL: nil
        )

        let result = await LXUserAPIService.shared.checkSource(source)

        XCTAssertTrue(result.isAvailable, result.detail ?? result.message)
    }
}

import XCTest
@testable import KumoneCore

@MainActor
final class LXSourceSelectionStateTests: XCTestCase {
    func testExplicitlyEmptyEnabledListStaysEmptyAfterRestore() {
        let state = LXSourceStore.restoredSelectionState(
            storedEnabledIDs: [],
            sourceIDs: ["source-a", "source-b"],
            storedSelectedID: nil
        )

        XCTAssertTrue(state.enabledIDs.isEmpty)
        XCTAssertNil(state.selectedID)
    }

    func testMissingLegacyEnabledListRestoresSelectedSource() {
        let state = LXSourceStore.restoredSelectionState(
            storedEnabledIDs: nil,
            sourceIDs: ["source-a", "source-b"],
            storedSelectedID: "source-b"
        )

        XCTAssertEqual(state.enabledIDs, ["source-b"])
        XCTAssertEqual(state.selectedID, "source-b")
    }

    func testDisabledStoredSelectionFallsBackToFirstEnabledSource() {
        let state = LXSourceStore.restoredSelectionState(
            storedEnabledIDs: ["source-b"],
            sourceIDs: ["source-a", "source-b"],
            storedSelectedID: "source-a"
        )

        XCTAssertEqual(state.enabledIDs, ["source-b"])
        XCTAssertEqual(state.selectedID, "source-b")
    }
}

import XCTest
@testable import KumoneCore

@MainActor
final class LXSourceExportTests: XCTestCase {
    func testExportEncodesCompleteReimportableSourceDescriptor() throws {
        let source = LXSourceStore.Source(
            id: "source-export-test",
            name: "测试音源",
            description: "Source description",
            version: "1.2",
            author: "iMusic",
            homepage: "https://example.com",
            script: "module.exports = { async musicUrl() {} }",
            sourceURL: "https://example.com/source.js"
        )

        let data = try LXSourceStore.shared.exportData(source)
        let decoded = try LXSourceStore.shared.decodeSourceData(
            data,
            suggestedName: "Fallback name"
        )

        XCTAssertEqual(decoded, source)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["script"] as? String, source.script)
        XCTAssertEqual(object["sourceURL"] as? String, source.sourceURL)
    }
}

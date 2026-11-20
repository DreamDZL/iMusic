import XCTest
@testable import KumoneCore

final class LXCatalogPlatformTests: XCTestCase {
    func testSearchAndDiscoveryUseExactlyFourProviders() {
        let providers: [LXCatalogPlatform] = [.kw, .kg, .tx, .wy]
        XCTAssertEqual(LXCatalogPlatform.catalogueCases, [.aggregate] + providers)
        XCTAssertEqual(LXCatalogPlatform.providerCases, providers)
        XCTAssertEqual(LXCatalogPlatform.discoveryCases, providers)
        XCTAssertNil(LXCatalogPlatform.aggregate.sourceID)
        XCTAssertEqual(providers.compactMap(\.sourceID), ["kw", "kg", "tx", "wy"])
        for retired in ["sd", "qs", "mg", "git"] {
            XCTAssertNil(LXCatalogPlatform(rawValue: retired))
        }
    }
}

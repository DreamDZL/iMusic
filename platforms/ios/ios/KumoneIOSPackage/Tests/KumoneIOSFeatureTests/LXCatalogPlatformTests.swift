import Testing
@testable import KumoneCore

struct LXCatalogPlatformTests {
    @Test func searchAndDiscoveryUseExactlyFourProviders() {
        let providers: [LXCatalogPlatform] = [.kw, .kg, .tx, .wy]
        #expect(LXCatalogPlatform.catalogueCases == [.aggregate] + providers)
        #expect(LXCatalogPlatform.providerCases == providers)
        #expect(LXCatalogPlatform.discoveryCases == providers)
        #expect(LXCatalogPlatform.aggregate.sourceID == nil)
        #expect(providers.compactMap(\.sourceID) == ["kw", "kg", "tx", "wy"])
        for retired in ["sd", "qs", "mg", "git"] {
            #expect(LXCatalogPlatform(rawValue: retired) == nil)
        }
    }
}

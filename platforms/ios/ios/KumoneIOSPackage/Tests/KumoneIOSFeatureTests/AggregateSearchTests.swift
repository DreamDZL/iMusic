import Foundation
import Testing
@testable import KumoneCore

private actor CatalogueFixture {
    private var attempts: [LXCatalogPlatform: Int] = [:]
    private var gate: CheckedContinuation<Void, Never>?
    private var gateOpened = false

    func releaseSlowProvider() {
        gateOpened = true
        gate?.resume()
        gate = nil
    }

    func calls() -> [LXCatalogPlatform: Int] { attempts }

    func search(_ provider: LXCatalogPlatform) async throws -> [Track] {
        attempts[provider, default: 0] += 1
        if provider == .kg, !gateOpened {
            await withCheckedContinuation { gate = $0 }
        }
        if provider == .wy, attempts[provider] == 1 {
            throw URLError(.notConnectedToInternet)
        }
        guard provider != .kw else { return [] }
        let id = provider == .tx ? 1 : (provider == .kg ? 2 : 3)
        return [Track(id: id, name: "Song \(id)", artists: [ArtistRef(id: 1, name: "Artist")],
                      album: AlbumRef(id: 1, name: "Album", picUrl: nil),
                      durationMS: 180_000, source: provider.rawValue)]
    }
}

@Test @MainActor func aggregatePublishesFastResultsAndRetriesOnlyFailures() async throws {
    let fixture = CatalogueFixture()
    let model = SearchViewModel(query: "Song", searchSongs: { _, provider, _ in
        try await fixture.search(provider)
    })
    model.tab = .songs
    let initialLoad = Task { await model.load(tab: .songs) }
    let deadline = ContinuousClock.now + .seconds(2)
    while model.songs.isEmpty, ContinuousClock.now < deadline, !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.songs.map(\.id) == [1])
    #expect(model.isLoading)
    await fixture.releaseSlowProvider()
    await initialLoad.value

    #expect(model.songs.map(\.id) == [1, 2])
    #expect(model.failedProviderCount == 1)

    await model.load(tab: .songs, force: true)
    let calls = await fixture.calls()
    #expect(calls == [.tx: 1, .wy: 2, .kw: 1, .kg: 1])
    #expect(model.songs.map(\.id) == [1, 2, 3])
    #expect(model.failedProviderCount == 0)
}

@Test @MainActor func aggregateIgnoresResultsAfterQueryChanges() async {
    let fixture = CatalogueFixture()
    let model = SearchViewModel(query: "old", searchSongs: { query, provider, _ in
        guard query == "old" else { return [] }
        return try await fixture.search(provider)
    })
    model.tab = .songs
    let oldSearch = Task { await model.load(tab: .songs) }
    let deadline = ContinuousClock.now + .seconds(2)
    while model.songs.isEmpty, ContinuousClock.now < deadline, !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.songs.map(\.id) == [1])

    model.setQuery("new")
    await model.load(tab: .songs)
    await fixture.releaseSlowProvider()
    await oldSearch.value

    #expect(model.songs.isEmpty)
    #expect(!model.isLoading)
    #expect(model.failedProviderCount == 0)
}

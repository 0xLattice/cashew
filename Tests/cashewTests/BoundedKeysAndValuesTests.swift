import Testing
import Foundation
@testable import cashew

/// `boundedKeysAndValues(after:limit:fetcher:)` is a fetcher-backed paginated page:
/// it must return the same window as `sortedKeysAndValues(limit:after:)`, but resolve
/// ONLY the nodes it descends into — pruning pre-cursor branches without fetching them
/// and stopping at `limit`. These tests pin correctness AND the bound across keys spread
/// over multiple first-character branches (so pagination crosses branch boundaries).
@Suite("Bounded paginated keys/values (fetcher-backed)")
struct BoundedKeysAndValuesTests {

    // 50 keys across 5 first-character branches: a0..a9, b0..b9, c0..c9, d0..d9, e0..e9.
    private let keys: [String] = (0..<5).flatMap { b in
        (0..<10).map { "\(Character(UnicodeScalar(97 + b)!))\($0)" }
    }.sorted()

    private func buildStored() async throws -> (cid: String, store: CountingStoreFetcher) {
        let store = CountingStoreFetcher()
        var dict = MerkleDictionaryImpl<String>()
        for k in keys { dict = try dict.inserting(key: k, value: "v_\(k)") }
        let vol = try VolumeImpl(node: dict)
        try await vol.storeRecursively(storer: store)
        return (vol.rawCID, store)
    }

    // Resolve ONLY the root node (children remain lazy headers fetched on demand).
    private func lazyRoot(_ cid: String, _ store: CountingStoreFetcher) async throws -> MerkleDictionaryImpl<String> {
        let resolved = try await VolumeImpl<MerkleDictionaryImpl<String>>(rawCID: cid).resolve(fetcher: store)
        return try #require(resolved.node)
    }

    private func oracle(limit: Int, after: String?) throws -> [(key: String, value: String)] {
        var dict = MerkleDictionaryImpl<String>()
        for k in keys { dict = try dict.inserting(key: k, value: "v_\(k)") }
        return try dict.sortedKeysAndValues(limit: limit, after: after)
    }

    @Test("matches the sortedKeysAndValues oracle (mid-branch cursor)")
    func matchesOracleMidBranch() async throws {
        let (cid, store) = try await buildStored()
        let root = try await lazyRoot(cid, store)
        let page = try await root.boundedKeysAndValues(after: "c5", limit: 3, fetcher: store)
        let want = try oracle(limit: 3, after: "c5")
        #expect(page.map(\.key) == want.map(\.key))
        #expect(page.map(\.value) == want.map(\.value))
        #expect(page.map(\.key) == ["c6", "c7", "c8"])
    }

    @Test("first page (no cursor) returns the smallest keys")
    func firstPage() async throws {
        let (cid, store) = try await buildStored()
        let root = try await lazyRoot(cid, store)
        let page = try await root.boundedKeysAndValues(after: nil, limit: 4, fetcher: store)
        #expect(page.map(\.key) == ["a0", "a1", "a2", "a3"])
    }

    @Test("cursor at a branch boundary crosses into the next branch")
    func crossesBranchBoundary() async throws {
        let (cid, store) = try await buildStored()
        let root = try await lazyRoot(cid, store)
        // after the last 'a' key → must continue into the 'b' branch.
        let page = try await root.boundedKeysAndValues(after: "a9", limit: 3, fetcher: store)
        #expect(page.map(\.key) == ["b0", "b1", "b2"])
    }

    @Test("does NOT fetch pre-cursor branches (bounded, not O(all keys))")
    func prunesPreCursorBranches() async throws {
        let (cid, store) = try await buildStored()
        let root = try await lazyRoot(cid, store)
        store.resetFetchCount()
        let page = try await root.boundedKeysAndValues(after: "c5", limit: 3, fetcher: store)
        #expect(page.map(\.key) == ["c6", "c7", "c8"])
        // Only the 'c' branch (+ at most the cursor leaf) is fetched — never the 'a'/'b'
        // pre-cursor branches nor the whole 50-key trie. A full resolve would fetch dozens.
        #expect(store.fetchCount < 12, "bounded page fetched \(store.fetchCount) nodes; it must prune pre-cursor branches, not walk the trie")
    }

    @Test("full pagination across all branches covers everything in order")
    func fullPaginationInOrder() async throws {
        let (cid, store) = try await buildStored()
        let root = try await lazyRoot(cid, store)
        var collected = [String]()
        var cursor: String? = nil
        while true {
            let page = try await root.boundedKeysAndValues(after: cursor, limit: 7, fetcher: store)
            if page.isEmpty { break }
            collected.append(contentsOf: page.map(\.key))
            cursor = page.last?.key
        }
        #expect(collected == keys)
    }

    @Test("cursor past the end returns empty")
    func pastEnd() async throws {
        let (cid, store) = try await buildStored()
        let root = try await lazyRoot(cid, store)
        let page = try await root.boundedKeysAndValues(after: "zzz", limit: 5, fetcher: store)
        #expect(page.isEmpty)
    }
}

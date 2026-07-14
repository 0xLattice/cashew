import Testing
import Foundation
import ArrayTrie
@testable import cashew

/// A map-backed store that counts how it's accessed, so we can compare the
/// per-CID fetch path against the batched ContentSource path.
final class CountingStore: Fetcher, ContentSource, TestVolumeStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private(set) var perCidCalls = 0     // Fetcher: one network trip per node
    private(set) var batchCalls = 0      // ContentSource: one trip per wave/level
    private(set) var totalCidsBatched = 0

    func storeRaw(rawCid: String, data: Data) {
        lock.withLock { storage[rawCid] = data }
    }

    // Per-CID path (today's model)
    func fetch(rawCid: String) async throws -> Data {
        lock.withLock { perCidCalls += 1 }
        guard let data = lock.withLock({ storage[rawCid] }) else {
            throw FetcherError.notFound(rawCid)
        }
        return data
    }

    // Batched path (the new model)
    func fetch(_ cids: Set<String>) async -> [String: Data] {
        lock.withLock {
            batchCalls += 1
            totalCidsBatched += cids.count
            var out: [String: Data] = [:]
            for cid in cids { if let d = storage[cid] { out[cid] = d } }
            return out
        }
    }
}

@Suite("Batched resolution over ContentSource")
struct BatchedResolveTests {

    private func buildStoredDictionary(keyCount: Int) async throws -> (cid: String, store: CountingStore) {
        let store = CountingStore()
        var dict = MerkleDictionaryImpl<String>()
        for i in 0..<keyCount {
            dict = try dict.inserting(key: "key-\(i)", value: "value-\(i)")
        }
        let vol = try VolumeImpl(node: dict)
        try await vol.storeRecursively(storer: store)
        return (vol.rawCID, store)
    }

    @Test("Batched resolve yields the identical structure as per-CID resolve")
    func batchedMatchesPerCid() async throws {
        let (cid, store) = try await buildStoredDictionary(keyCount: 40)

        let viaFetcher = try await VolumeImpl<MerkleDictionaryImpl<String>>(rawCID: cid)
            .resolveRecursive(fetcher: store)
        let viaSource = try await VolumeImpl<MerkleDictionaryImpl<String>>(rawCID: cid)
            .resolveRecursive(source: store)

        #expect(viaFetcher.node != nil)
        #expect(viaSource.node != nil)
        // Same content resolved either way → byte-identical re-serialization.
        #expect(viaFetcher.node?.toData() == viaSource.node?.toData())
        // And both equal the original committed CID.
        #expect(viaSource.rawCID == cid)
    }

    @Test("Batched resolve collapses per-node trips into per-level batches")
    func batchedDoesFewerRoundTrips() async throws {
        let (cid, perCidStore) = try await buildStoredDictionary(keyCount: 40)
        _ = try await VolumeImpl<MerkleDictionaryImpl<String>>(rawCID: cid)
            .resolveRecursive(fetcher: perCidStore)
        let perCidTrips = perCidStore.perCidCalls

        let (cid2, batchedStore) = try await buildStoredDictionary(keyCount: 40)
        _ = try await VolumeImpl<MerkleDictionaryImpl<String>>(rawCID: cid2)
            .resolveRecursive(source: batchedStore)
        let batchedTrips = batchedStore.batchCalls

        // The per-CID path makes one network round-trip per node; the batched
        // path makes one per concurrent wave (≈ tree depth). The batched trip
        // count must be a small fraction of the node count, and never more.
        #expect(batchedTrips < perCidTrips)
        #expect(batchedTrips * 3 < perCidTrips)
        // Every node still fetched — no content dropped.
        #expect(batchedStore.totalCidsBatched == perCidTrips)
    }
}

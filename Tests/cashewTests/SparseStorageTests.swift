import ArrayTrie
import Crypto
import Foundation
import XCTest
@testable import cashew

final class SparseStorageTests: XCTestCase {
    private struct Leaf: Scalar, Equatable {
        let value: String
    }

    private struct PairNode: Node {
        let left: HeaderImpl<Leaf>
        let right: HeaderImpl<Leaf>

        func get(property: PathSegment) -> (any Header)? {
            switch property {
            case "left": left
            case "right": right
            default: nil
            }
        }

        func properties() -> Set<PathSegment> { ["left", "right"] }

        func set(properties: [PathSegment: any Header]) -> Self {
            Self(
                left: properties["left"] as? HeaderImpl<Leaf> ?? left,
                right: properties["right"] as? HeaderImpl<Leaf> ?? right
            )
        }
    }

    private final class MemoryBlockStore: Storer, Fetcher, ContentSource, KeyProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var storedEntries: [String: Data] = [:]
        private var keys: [String: SymmetricKey] = [:]

        func store(entries: [String: Data]) async {
            lock.withLock {
                storedEntries.merge(entries) { _, new in new }
            }
        }

        func fetch(rawCid: String) async throws -> Data {
            guard let data = lock.withLock({ storedEntries[rawCid] }) else {
                throw FetcherError.notFound(rawCid)
            }
            return data
        }

        func fetch(_ cids: Set<String>) async -> [String: Data] {
            lock.withLock {
                storedEntries.filter { cids.contains($0.key) }
            }
        }

        func key(for keyHash: String) -> SymmetricKey? {
            lock.withLock { keys[keyHash] }
        }

        func register(_ key: SymmetricKey) {
            let keyData = key.withUnsafeBytes { Data($0) }
            let keyHash = Data(SHA256.hash(data: keyData)).base64EncodedString()
            lock.withLock { keys[keyHash] = key }
        }

        var entries: [String: Data] {
            lock.withLock { storedEntries }
        }
    }

    private final class RecordingFetcher: Fetcher, @unchecked Sendable {
        private let backing: any Fetcher
        private let lock = NSLock()
        private var fetchedCIDs = Set<String>()

        init(_ backing: any Fetcher) {
            self.backing = backing
        }

        func fetch(rawCid: String) async throws -> Data {
            lock.withLock { _ = fetchedCIDs.insert(rawCid) }
            return try await backing.fetch(rawCid: rawCid)
        }

        var fetched: Set<String> {
            lock.withLock { fetchedCIDs }
        }
    }

    private struct InvalidFetcher: Fetcher {
        func fetch(rawCid: String) async throws -> Data {
            Data("not the requested block".utf8)
        }
    }

    private final class DualStore: Storer, VolumeStorer, @unchecked Sendable {
        private let lock = NSLock()
        private var sparseWrites = 0
        private var volumeWrites = 0

        func store(entries: [String: Data]) async {
            lock.withLock { sparseWrites += 1 }
        }

        func store(volume: SerializedVolume) async {
            lock.withLock { volumeWrites += 1 }
        }

        var counts: (sparse: Int, volume: Int) {
            lock.withLock { (sparseWrites, volumeWrites) }
        }
    }

    func testVolumeStorePrefersCompleteBoundaryForDualStore() async throws {
        let volume = try VolumeImpl(node: Leaf(value: "complete"))
        let store = DualStore()

        try await volume.store(storer: store)
        try await volume.storeRecursively(storer: store)
        try await volume.store(paths: [[""]: .targeted], storer: store)

        XCTAssertEqual(store.counts.sparse, 0)
        XCTAssertEqual(store.counts.volume, 3)
    }

    func testTargetedStoreAllowsAnUnresolvedOffPathBlock() async throws {
        let left = try HeaderImpl(node: Leaf(value: "left"))
        let resolvedRight = try HeaderImpl(node: Leaf(value: "right"))
        let right = HeaderImpl<Leaf>(rawCID: resolvedRight.rawCID)
        let root = try HeaderImpl(node: PairNode(left: left, right: right))
        let store = MemoryBlockStore()

        try await root.store(paths: [["left"]: .targeted], storer: store)

        XCTAssertEqual(Set(store.entries.keys), [root.rawCID, left.rawCID])
    }

    func testEmptyPlanStoresAndResolvesNothing() async throws {
        let root = try HeaderImpl(node: Leaf(value: "root"))
        let backing = MemoryBlockStore()
        try await root.store(storer: backing)
        let fetcher = RecordingFetcher(backing)
        let emptyPaths = ArrayTrie<ResolutionStrategy>()

        let resolved = try await root.removingNode().resolve(
            paths: emptyPaths,
            fetcher: fetcher
        )
        let stored = MemoryBlockStore()
        try await root.store(paths: emptyPaths, storer: stored)

        XCTAssertNil(resolved.node)
        XCTAssertTrue(fetcher.fetched.isEmpty)
        XCTAssertTrue(stored.entries.isEmpty)
    }

    func testSelectedUnresolvedBlockFailsBeforeEmission() async throws {
        let left = try HeaderImpl(node: Leaf(value: "left"))
        let resolvedRight = try HeaderImpl(node: Leaf(value: "right"))
        let right = HeaderImpl<Leaf>(rawCID: resolvedRight.rawCID)
        let root = try HeaderImpl(node: PairNode(left: left, right: right))
        let store = MemoryBlockStore()

        do {
            try await root.store(paths: [["right"]: .targeted], storer: store)
            XCTFail("Expected unresolved selected block to fail")
        } catch {
            XCTAssertEqual(error as? DataErrors, .nodeNotAvailable)
        }
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testSparseStrategiesStoreExactlyWhatResolveFetches() async throws {
        typealias Dictionary = MerkleDictionaryImpl<HeaderImpl<Leaf>>
        let dictionary = try Dictionary()
            .inserting(key: "alice", value: try HeaderImpl(node: Leaf(value: "one")))
            .inserting(key: "alicia", value: try HeaderImpl(node: Leaf(value: "two")))
            .inserting(key: "bob", value: try HeaderImpl(node: Leaf(value: "three")))
        let root = try HeaderImpl(node: dictionary)
        let backing = MemoryBlockStore()
        try await root.storeRecursively(storer: backing)

        var targeted = ArrayTrie<ResolutionStrategy>()
        targeted.set(["alice"], value: .targeted)
        try await assertStoredBlocksMatchResolvedBlocks(root, paths: targeted, backing: backing)

        var list = ArrayTrie<ResolutionStrategy>()
        list.set([""], value: .list)
        try await assertStoredBlocksMatchResolvedBlocks(root, paths: list, backing: backing)

        var range = ArrayTrie<ResolutionStrategy>()
        range.set([""], value: .range(after: "alice", limit: 1))
        try await assertStoredBlocksMatchResolvedBlocks(root, paths: range, backing: backing)

        var recursive = ArrayTrie<ResolutionStrategy>()
        recursive.set([""], value: .recursive)
        try await assertStoredBlocksMatchResolvedBlocks(root, paths: recursive, backing: backing)
    }

    func testEncryptedSparseStoreUsesStorerKeyProvider() async throws {
        let key = SymmetricKey(size: .bits256)
        let header = try HeaderImpl(node: Leaf(value: "secret"), key: key)
        let store = MemoryBlockStore()
        store.register(key)

        try await header.store(storer: store)

        XCTAssertNotEqual(store.entries[header.rawCID], header.node?.toData())
        let resolved = try await header.removingNode().resolve(fetcher: store)
        XCTAssertEqual(resolved.node, Leaf(value: "secret"))
    }

    func testResolveCachesOnlyVerifiedFetchedBlocks() async throws {
        let left = try HeaderImpl(node: Leaf(value: "left"))
        let right = try HeaderImpl(node: Leaf(value: "right"))
        let root = try HeaderImpl(node: PairNode(left: left, right: right))
        let backing = MemoryBlockStore()
        try await root.storeRecursively(storer: backing)

        let recording = RecordingFetcher(backing)
        let cache = MemoryBlockStore()
        let unresolved = HeaderImpl<PairNode>(rawCID: root.rawCID)
        _ = try await unresolved.resolve(
            paths: [["left"]: .targeted],
            fetcher: recording,
            cache: cache
        )

        XCTAssertEqual(Set(cache.entries.keys), recording.fetched)
        let cached = try await unresolved.resolve(
            paths: [["left"]: .targeted],
            fetcher: cache
        )
        XCTAssertEqual(cached.node?.left.node, Leaf(value: "left"))
    }

    func testResolveDoesNotCacheCIDMismatch() async throws {
        let header = try HeaderImpl(node: Leaf(value: "expected"))
        let cache = MemoryBlockStore()

        do {
            _ = try await header.removingNode().resolve(
                fetcher: InvalidFetcher(),
                cache: cache
            )
            XCTFail("Expected CID mismatch")
        } catch {
            XCTAssertEqual(error as? DataErrors, .cidMismatch)
        }
        XCTAssertTrue(cache.entries.isEmpty)
    }

    func testBatchedResolveCachesVerifiedBlocks() async throws {
        let left = try HeaderImpl(node: Leaf(value: "left"))
        let right = try HeaderImpl(node: Leaf(value: "right"))
        let root = try HeaderImpl(node: PairNode(left: left, right: right))
        let backing = MemoryBlockStore()
        try await root.storeRecursively(storer: backing)
        let cache = MemoryBlockStore()
        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["left"], value: .targeted)

        let resolved = try await root.removingNode().resolve(
            paths: paths,
            source: backing,
            cache: cache
        )

        XCTAssertEqual(resolved.node?.left.node, Leaf(value: "left"))
        XCTAssertEqual(Set(cache.entries.keys), [root.rawCID, left.rawCID])
    }

    func testResolveCacheForwardsFetcherKeys() async throws {
        let key = SymmetricKey(size: .bits256)
        let header = try HeaderImpl(node: Leaf(value: "secret"), key: key)
        let backing = MemoryBlockStore()
        backing.register(key)
        try await header.store(storer: backing)
        let cache = MemoryBlockStore()

        let resolved = try await header.removingNode().resolve(
            fetcher: backing,
            cache: cache
        )

        XCTAssertEqual(resolved.node, Leaf(value: "secret"))
        XCTAssertNotNil(cache.entries[header.rawCID])
    }

    private func assertStoredBlocksMatchResolvedBlocks<NodeType: Node>(
        _ root: HeaderImpl<NodeType>,
        paths: ArrayTrie<ResolutionStrategy>,
        backing: MemoryBlockStore
    ) async throws {
        let fetcher = RecordingFetcher(backing)
        _ = try await root.removingNode().resolve(paths: paths, fetcher: fetcher)

        let store = MemoryBlockStore()
        try await root.store(paths: paths, storer: store)

        XCTAssertEqual(Set(store.entries.keys), fetcher.fetched)
    }
}

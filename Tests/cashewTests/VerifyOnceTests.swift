import ArrayTrie
import Foundation
import XCTest
@testable import cashew

/// Bytes are hashed against their CID once, where they enter. These pin the
/// rejections that single check still makes: tampered bytes from any fetcher
/// or source, through every resolve wrapper, and a node stored under a CID it
/// does not serialize to.
final class VerifyOnceTests: XCTestCase {
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

    /// Serves stored blocks, with `tampered` CIDs answered by other bytes.
    private final class TamperingStore: Storer, Fetcher, ContentSource, @unchecked Sendable {
        private let lock = NSLock()
        private var blocks: [String: Data] = [:]
        let tampered: Set<String>

        init(blocks: [String: Data] = [:], tampered: Set<String> = []) {
            self.blocks = blocks
            self.tampered = tampered
        }

        func store(entries: [String: Data]) async {
            lock.withLock { blocks.merge(entries) { _, new in new } }
        }

        private func serve(_ cid: String) -> Data? {
            guard let data = lock.withLock({ blocks[cid] }) else { return nil }
            return tampered.contains(cid) ? data + Data([0]) : data
        }

        func fetch(rawCid: String) async throws -> Data {
            guard let data = serve(rawCid) else { throw FetcherError.notFound(rawCid) }
            return data
        }

        func fetch(_ cids: Set<String>) async -> [String: Data] {
            var out: [String: Data] = [:]
            for cid in cids { out[cid] = serve(cid) }
            return out
        }

        var entries: [String: Data] { lock.withLock { blocks } }
    }

    private func pair() throws -> (root: HeaderImpl<PairNode>, store: [String: Data]) {
        let root = try HeaderImpl(node: PairNode(
            left: try HeaderImpl(node: Leaf(value: "left")),
            right: try HeaderImpl(node: Leaf(value: "right"))
        ))
        var entries: [String: Data] = [:]
        for header in [root.rawCID: root.node!.toData()!,
                       root.node!.left.rawCID: root.node!.left.node!.toData()!,
                       root.node!.right.rawCID: root.node!.right.node!.toData()!] {
            entries[header.key] = header.value
        }
        return (root, entries)
    }

    private func changeLeft() -> ArrayTrie<Transform> {
        var transforms = ArrayTrie<Transform>()
        transforms.set(["left"], value: .update(Leaf(value: "changed").description))
        return transforms
    }

    private func assertMismatch(
        _ body: () async throws -> some Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await body()
            XCTFail("Expected CID mismatch", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? DataErrors, .cidMismatch, file: file, line: line)
        }
    }

    func testTamperedChildRejectedThroughEveryResolvePath() async throws {
        let (root, blocks) = try pair()
        let tamperedCID = root.node!.right.rawCID
        let lazy = root.removingNode()

        let plain = TamperingStore(blocks: blocks, tampered: [tamperedCID])
        await assertMismatch { try await lazy.resolveRecursive(fetcher: plain) }
        await assertMismatch { try await lazy.resolveRecursive(source: plain) }
        await assertMismatch { try await lazy.resolve(paths: [["right"]: .targeted], fetcher: plain) }

        let cache = TamperingStore()
        await assertMismatch { try await lazy.resolveRecursive(fetcher: plain, cache: cache) }
        await assertMismatch { try await lazy.resolveRecursive(source: plain, cache: cache) }
        var pathTrie = ArrayTrie<ResolutionStrategy>()
        pathTrie.set(["right"], value: .targeted)
        await assertMismatch { try await lazy.resolve(paths: pathTrie, source: plain, cache: cache) }
        XCTAssertNil(cache.entries[tamperedCID], "tampered bytes must not be cached")
        for (cid, data) in cache.entries {
            XCTAssertNoThrow(try verifyContentAddress(data, matches: cid))
        }
    }

    func testTamperedRootRejectedThroughCachingFetcher() async throws {
        let (root, blocks) = try pair()
        let source = TamperingStore(blocks: blocks, tampered: [root.rawCID])
        let cache = TamperingStore()
        await assertMismatch { try await root.removingNode().resolve(fetcher: source, cache: cache) }
        await assertMismatch { try await root.removingNode().resolve(source: source, cache: cache) }
        XCTAssertTrue(cache.entries.isEmpty)
    }

    func testCachingFetcherStoresAndReturnsOnlyVerifiedBytes() async throws {
        let (root, blocks) = try pair()
        let cache = TamperingStore()
        let resolved = try await root.removingNode().resolveRecursive(
            fetcher: TamperingStore(blocks: blocks),
            cache: cache
        )
        XCTAssertEqual(resolved.node?.right.node, Leaf(value: "right"))
        XCTAssertEqual(cache.entries, blocks)
    }

    func testMismatchedPairsStillRejectedOnStore() async throws {
        let expected = try HeaderImpl(node: Leaf(value: "expected"))
        let mismatched = HeaderImpl<Leaf>(rawCID: expected.rawCID, node: Leaf(value: "other"), encryptionInfo: nil)
        let root = try HeaderImpl(node: PairNode(left: mismatched, right: try HeaderImpl(node: Leaf(value: "right"))))

        let sparse = TamperingStore()
        await assertMismatch { try await mismatched.store(storer: sparse) }
        await assertMismatch { try await root.storeRecursively(storer: sparse) }
        await assertMismatch { try await root.store(paths: [["left"]: .targeted], storer: sparse) }
        XCTAssertNil(sparse.entries[expected.rawCID])
    }

    func testStoredBlocksOfResolvedAndBuiltHeadersHashToTheirCIDs() async throws {
        let (root, blocks) = try pair()
        let resolved = try await root.removingNode().resolveRecursive(fetcher: TamperingStore(blocks: blocks))
        let transformed = try XCTUnwrap(try resolved.transform(transforms: changeLeft()))

        for header in [resolved, transformed] {
            let store = TamperingStore()
            try await header.storeRecursively(storer: store)
            XCTAssertEqual(store.entries.count, 3)
            for (cid, data) in store.entries {
                XCTAssertNoThrow(try verifyContentAddress(data, matches: cid))
            }
        }
    }
}

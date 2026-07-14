import Crypto
import Foundation
import XCTest
@testable import cashew

final class StoragePlanTests: XCTestCase {
    private struct Leaf: Scalar, Equatable {
        let value: String
    }

    private struct SameBoundaryNode: Node {
        let child: HeaderImpl<Leaf>

        func get(property: PathSegment) -> (any Header)? {
            property == "child" ? child : nil
        }

        func properties() -> Set<PathSegment> { ["child"] }

        func set(properties: [PathSegment: any Header]) -> Self {
            guard let child = properties["child"] as? HeaderImpl<Leaf> else { return self }
            return Self(child: child)
        }
    }

    private struct VolumeChildNode: Node {
        let child: VolumeImpl<Leaf>

        func get(property: PathSegment) -> (any Header)? {
            property == "child" ? child : nil
        }

        func properties() -> Set<PathSegment> { ["child"] }

        func set(properties: [PathSegment: any Header]) -> Self {
            guard let child = properties["child"] as? VolumeImpl<Leaf> else { return self }
            return Self(child: child)
        }
    }

    private struct BranchNode: Node {
        let grandchild: VolumeImpl<Leaf>

        func get(property: PathSegment) -> (any Header)? {
            property == "grandchild" ? grandchild : nil
        }

        func properties() -> Set<PathSegment> { ["grandchild"] }

        func set(properties: [PathSegment: any Header]) -> Self {
            guard let grandchild = properties["grandchild"] as? VolumeImpl<Leaf> else { return self }
            return Self(grandchild: grandchild)
        }
    }

    private struct TreeNode: Node {
        let child: VolumeImpl<BranchNode>
        let sibling: VolumeImpl<Leaf>

        func get(property: PathSegment) -> (any Header)? {
            switch property {
            case "child": child
            case "sibling": sibling
            default: nil
            }
        }

        func properties() -> Set<PathSegment> { ["child", "sibling"] }

        func set(properties: [PathSegment: any Header]) -> Self {
            Self(
                child: properties["child"] as? VolumeImpl<BranchNode> ?? child,
                sibling: properties["sibling"] as? VolumeImpl<Leaf> ?? sibling
            )
        }
    }

    private struct PairNode: Node {
        let first: VolumeImpl<Leaf>
        let second: VolumeImpl<Leaf>

        func get(property: PathSegment) -> (any Header)? {
            switch property {
            case "first": first
            case "second": second
            default: nil
            }
        }

        func properties() -> Set<PathSegment> { ["first", "second"] }

        func set(properties: [PathSegment: any Header]) -> Self {
            Self(
                first: properties["first"] as? VolumeImpl<Leaf> ?? first,
                second: properties["second"] as? VolumeImpl<Leaf> ?? second
            )
        }
    }

    private struct SharedVolumeNode: Node {
        let left: VolumeImpl<PairNode>
        let right: VolumeImpl<PairNode>

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
                left: properties["left"] as? VolumeImpl<PairNode> ?? left,
                right: properties["right"] as? VolumeImpl<PairNode> ?? right
            )
        }
    }

    private struct WrapperNode: Node {
        let wrapper: HeaderImpl<BranchNode>

        func get(property: PathSegment) -> (any Header)? {
            property == "wrapper" ? wrapper : nil
        }

        func properties() -> Set<PathSegment> { ["wrapper"] }

        func set(properties: [PathSegment: any Header]) -> Self {
            guard let wrapper = properties["wrapper"] as? HeaderImpl<BranchNode> else { return self }
            return Self(wrapper: wrapper)
        }
    }

    private struct MissingDeclaredChildNode: Node {
        func get(property: PathSegment) -> (any Header)? { nil }
        func properties() -> Set<PathSegment> { ["missing"] }
        func set(properties: [PathSegment: any Header]) -> Self { self }
    }

    private struct MissingOffPathChildNode: Node {
        let selected: VolumeImpl<Leaf>

        func get(property: PathSegment) -> (any Header)? {
            property == "selected" ? selected : nil
        }

        func properties() -> Set<PathSegment> { ["missing", "selected"] }

        func set(properties: [PathSegment: any Header]) -> Self {
            guard let selected = properties["selected"] as? VolumeImpl<Leaf> else { return self }
            return Self(selected: selected)
        }
    }

    private enum EncodingFailure: Error {
        case injected
    }

    private struct FailingLeaf: Scalar {
        init() {}
        init(from decoder: Decoder) throws { self.init() }
        func encode(to encoder: Encoder) throws { throw EncodingFailure.injected }
    }

    private struct FailingChildNode: Node {
        let child: HeaderImpl<FailingLeaf>

        func get(property: PathSegment) -> (any Header)? {
            property == "child" ? child : nil
        }

        func properties() -> Set<PathSegment> { ["child"] }

        func set(properties: [PathSegment: any Header]) -> Self {
            guard let child = properties["child"] as? HeaderImpl<FailingLeaf> else { return self }
            return Self(child: child)
        }
    }

    private enum InjectedFailure: Error, Equatable {
        case store(String)
    }

    private final class RecordingStorer: VolumeStorer, Fetcher, KeyProvider, @unchecked Sendable {
        var failOnRoot: String?
        var keys: [String: SymmetricKey] = [:]
        private(set) var roots: [String] = []
        private(set) var volumes: [String: [String: Data]] = [:]

        func store(volume: SerializedVolume) async throws {
            if failOnRoot == volume.root { throw InjectedFailure.store(volume.root) }
            roots.append(volume.root)
            volumes[volume.root] = volume.entries
        }

        func key(for keyHash: String) -> SymmetricKey? { keys[keyHash] }

        func fetch(rawCid: String) async throws -> Data {
            for entries in volumes.values {
                if let data = entries[rawCid] { return data }
            }
            throw FetchError.notFound
        }
    }

    private actor BlockingFailingStorer: VolumeStorer {
        private var calls = 0
        private var started = false
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []
        private var release: CheckedContinuation<Void, Never>?

        func store(volume: SerializedVolume) async throws {
            calls += 1
            guard calls == 1 else { return }

            started = true
            startedWaiters.forEach { $0.resume() }
            startedWaiters.removeAll()
            await withCheckedContinuation { release = $0 }
            throw InjectedFailure.store(volume.root)
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { startedWaiters.append($0) }
        }

        func releaseFirstStore() {
            release?.resume()
            release = nil
        }

        func callCount() -> Int { calls }
    }

    private actor CompletionFlag {
        private var completed = false

        func markCompleted() { completed = true }
        func isCompleted() -> Bool { completed }
    }

    private final class RecordingFetcher: Fetcher, @unchecked Sendable {
        private let backing: RecordingStorer
        private let lock = NSLock()
        private var fetchedCIDs = Set<String>()

        init(backing: RecordingStorer) {
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

    func testStoreWithoutPathsEmitsOnlyTheRootVolume() async throws {
        let child = try VolumeImpl(node: Leaf(value: "child"))
        let outer = try VolumeImpl(node: VolumeChildNode(child: child))
        let storer = RecordingStorer()

        try await outer.store(storer: storer)

        XCTAssertEqual(storer.roots, [outer.rawCID])
        XCTAssertNil(storer.volumes[outer.rawCID]?[child.rawCID])
    }

    func testSameBoundaryHeadersAreIncludedInOneCompleteVolume() async throws {
        let child = try HeaderImpl(node: Leaf(value: "same-boundary"))
        let outer = try VolumeImpl(node: SameBoundaryNode(child: child))
        let storer = RecordingStorer()

        try await outer.store(storer: storer)

        XCTAssertEqual(storer.roots, [outer.rawCID])
        XCTAssertNotNil(storer.volumes[outer.rawCID]?[outer.rawCID])
        XCTAssertNotNil(storer.volumes[outer.rawCID]?[child.rawCID])
    }

    func testTargetedAndRecursivePlansCrossOnlySelectedBoundaries() async throws {
        let grandchild = try VolumeImpl(node: Leaf(value: "grandchild"))
        let child = try VolumeImpl(node: BranchNode(grandchild: grandchild))
        let sibling = try VolumeImpl(node: Leaf(value: "sibling"))
        let outer = try VolumeImpl(node: TreeNode(child: child, sibling: sibling))

        let targeted = RecordingStorer()
        try await outer.store(paths: [["child"]: .targeted], storer: targeted)
        XCTAssertEqual(targeted.roots, [outer.rawCID, child.rawCID])

        let deepTargeted = RecordingStorer()
        try await outer.store(
            paths: [["child", "grandchild"]: .targeted],
            storer: deepTargeted
        )
        XCTAssertEqual(
            deepTargeted.roots,
            [outer.rawCID, child.rawCID, grandchild.rawCID]
        )

        let recursive = RecordingStorer()
        try await outer.store(paths: [["child"]: .recursive], storer: recursive)
        XCTAssertEqual(recursive.roots, [outer.rawCID, child.rawCID, grandchild.rawCID])
        XCTAssertFalse(recursive.roots.contains(sibling.rawCID))
    }

    func testPlanTraversesOrdinaryHeadersToReachSelectedVolume() async throws {
        let grandchild = try VolumeImpl(node: Leaf(value: "selected"))
        let wrapper = try HeaderImpl(node: BranchNode(grandchild: grandchild))
        let outer = try VolumeImpl(node: WrapperNode(wrapper: wrapper))
        let storer = RecordingStorer()

        try await outer.store(
            paths: [["wrapper", "grandchild"]: .targeted],
            storer: storer
        )

        XCTAssertEqual(storer.roots, [outer.rawCID, grandchild.rawCID])
        XCTAssertNotNil(storer.volumes[outer.rawCID]?[wrapper.rawCID])
    }

    func testUnselectedUnresolvedVolumeIsAllowedButSelectedOneFails() async throws {
        let resolvedChild = try VolumeImpl(node: Leaf(value: "remote"))
        let unresolvedChild = VolumeImpl<Leaf>(rawCID: resolvedChild.rawCID)
        let outer = try VolumeImpl(node: VolumeChildNode(child: unresolvedChild))

        let rootOnly = RecordingStorer()
        try await outer.store(storer: rootOnly)
        XCTAssertEqual(rootOnly.roots, [outer.rawCID])

        let selected = RecordingStorer()
        await XCTAssertThrowsErrorAsync(
            try await outer.store(paths: [["child"]: .targeted], storer: selected)
        ) { error in
            XCTAssertEqual(error as? DataErrors, .nodeNotAvailable)
        }
        XCTAssertEqual(selected.roots, [outer.rawCID])
    }

    func testCompletedParentRemainsStoredWhenSelectedChildFails() async throws {
        let child = try VolumeImpl(node: Leaf(value: "child"))
        let outer = try VolumeImpl(node: VolumeChildNode(child: child))
        let storer = RecordingStorer()
        storer.failOnRoot = child.rawCID

        await XCTAssertThrowsErrorAsync(
            try await outer.store(paths: [["child"]: .targeted], storer: storer)
        ) { error in
            XCTAssertEqual(error as? InjectedFailure, .store(child.rawCID))
        }
        XCTAssertEqual(storer.roots, [outer.rawCID])
    }

    func testRecursiveFailureKeepsEveryCompletedAncestor() async throws {
        let grandchild = try VolumeImpl(node: Leaf(value: "grandchild"))
        let child = try VolumeImpl(node: BranchNode(grandchild: grandchild))
        let sibling = try VolumeImpl(node: Leaf(value: "sibling"))
        let outer = try VolumeImpl(node: TreeNode(child: child, sibling: sibling))
        let storer = RecordingStorer()
        storer.failOnRoot = grandchild.rawCID

        await XCTAssertThrowsErrorAsync(
            try await outer.storeRecursively(storer: storer)
        ) { error in
            XCTAssertEqual(error as? InjectedFailure, .store(grandchild.rawCID))
        }
        XCTAssertEqual(storer.roots, [outer.rawCID, child.rawCID])
    }

    func testSharedVolumesAreEmittedOnceWithoutDroppingDistinctTargetedPaths() async throws {
        let first = try VolumeImpl(node: Leaf(value: "first"))
        let second = try VolumeImpl(node: Leaf(value: "second"))
        let shared = try VolumeImpl(node: PairNode(first: first, second: second))
        let outer = try VolumeImpl(node: SharedVolumeNode(left: shared, right: shared))

        let recursive = RecordingStorer()
        try await outer.storeRecursively(storer: recursive)
        XCTAssertEqual(recursive.roots, [outer.rawCID, shared.rawCID, first.rawCID, second.rawCID])

        let targeted = RecordingStorer()
        try await outer.store(
            paths: [
                ["left", "first"]: .targeted,
                ["right", "second"]: .targeted,
            ],
            storer: targeted
        )
        XCTAssertEqual(targeted.roots, [outer.rawCID, shared.rawCID, first.rawCID, second.rawCID])
    }

    func testMismatchedContentAddressPreventsBoundaryEmission() async throws {
        let expectedRoot = try VolumeImpl(node: Leaf(value: "expected-root"))
        let mismatchedRoot = VolumeImpl<Leaf>(
            rawCID: expectedRoot.rawCID,
            node: Leaf(value: "other-root"),
            encryptionInfo: nil
        )
        let rootStore = RecordingStorer()

        await XCTAssertThrowsErrorAsync(try await mismatchedRoot.store(storer: rootStore)) { error in
            XCTAssertEqual(error as? DataErrors, .cidMismatch)
        }
        XCTAssertTrue(rootStore.roots.isEmpty)

        let expectedChild = try HeaderImpl(node: Leaf(value: "expected-child"))
        let mismatchedChild = HeaderImpl<Leaf>(
            rawCID: expectedChild.rawCID,
            node: Leaf(value: "other-child"),
            encryptionInfo: nil
        )
        let outer = try VolumeImpl(node: SameBoundaryNode(child: mismatchedChild))
        let childStore = RecordingStorer()

        await XCTAssertThrowsErrorAsync(try await outer.store(storer: childStore)) { error in
            XCTAssertEqual(error as? DataErrors, .cidMismatch)
        }
        XCTAssertTrue(childStore.roots.isEmpty)
    }

    func testConcurrentDuplicateStoreAwaitsFailureAndRemainsRetryable() async throws {
        let root = "shared-root"
        let volume = SerializedVolume(root: root, entries: [:])
        let backing = BlockingFailingStorer()
        let session = VolumeStorageSession(storer: backing)
        let secondCompletion = CompletionFlag()

        let first = Task {
            try await session.store(volume: volume)
        }
        await backing.waitUntilStarted()

        let second = Task {
            do {
                try await session.store(volume: volume)
                await secondCompletion.markCompleted()
            } catch {
                await secondCompletion.markCompleted()
                throw error
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        let completedBeforePersistence = await secondCompletion.isCompleted()
        XCTAssertFalse(completedBeforePersistence)

        await backing.releaseFirstStore()
        await XCTAssertThrowsErrorAsync(try await first.value)
        await XCTAssertThrowsErrorAsync(try await second.value)

        try await session.store(volume: volume)
        let callCount = await backing.callCount()
        XCTAssertEqual(callCount, 2)
    }

    func testIncompleteBoundaryIsNeverEmitted() async throws {
        let missing = try VolumeImpl(node: MissingDeclaredChildNode())
        let missingStore = RecordingStorer()
        await XCTAssertThrowsErrorAsync(try await missing.store(storer: missingStore))
        XCTAssertTrue(missingStore.roots.isEmpty)

        let placeholder = try HeaderImpl(node: Leaf(value: "placeholder"))
        let failingChild = HeaderImpl<FailingLeaf>(
            rawCID: placeholder.rawCID,
            node: FailingLeaf(),
            encryptionInfo: nil
        )
        let failing = try VolumeImpl(node: FailingChildNode(child: failingChild))
        let failingStore = RecordingStorer()
        await XCTAssertThrowsErrorAsync(try await failing.store(storer: failingStore))
        XCTAssertTrue(failingStore.roots.isEmpty)
    }

    func testTargetedStoreRequiresOffPathStructuralConsistency() async throws {
        let selected = try VolumeImpl(node: Leaf(value: "selected"))
        let outer = try VolumeImpl(node: MissingOffPathChildNode(selected: selected))
        let storer = RecordingStorer()

        await XCTAssertThrowsErrorAsync(
            try await outer.store(paths: [["selected"]: .targeted], storer: storer)
        ) { error in
            XCTAssertEqual(error as? DataErrors, .missingDeclaredChild("missing"))
        }
        XCTAssertTrue(storer.roots.isEmpty)
    }

    func testEncryptedVolumeUsesStorerKeyProvider() async throws {
        let key = SymmetricKey(size: .bits256)
        let volume = try VolumeImpl<Leaf>(node: Leaf(value: "encrypted"), key: key)
        let info = try XCTUnwrap(volume.encryptionInfo)
        let storer = RecordingStorer()
        storer.keys[info.keyHash] = key

        try await volume.store(storer: storer)

        let stored = try XCTUnwrap(storer.volumes[volume.rawCID]?[volume.rawCID])
        XCTAssertNotEqual(stored, volume.node?.toData())
        let decoded = try await volume.fetchAndDecodeNode(fetcher: storer)
        XCTAssertEqual(decoded, Leaf(value: "encrypted"))
    }

    func testStoragePathsMatchCompressedRadixResolutionPaths() async throws {
        typealias Dictionary = VolumeMerkleDictionaryImpl<String>
        let dictionary = try Dictionary()
            .inserting(key: "alice", value: "one")
            .inserting(key: "alicia", value: "two")
            .inserting(key: "bob", value: "three")
        let outer = try VolumeImpl(node: dictionary)
        let aRoot = try XCTUnwrap(dictionary.children["a"]?.rawCID)
        let bRoot = try XCTUnwrap(dictionary.children["b"]?.rawCID)
        let storer = RecordingStorer()

        try await outer.store(paths: [["alice"]: .targeted], storer: storer)

        XCTAssertTrue(storer.roots.contains(aRoot))
        XCTAssertFalse(storer.roots.contains(bRoot))

        let unresolved = VolumeImpl<Dictionary>(rawCID: outer.rawCID)
        let resolved = try await unresolved.resolve(
            paths: [["alice"]: .targeted],
            fetcher: storer
        )
        XCTAssertEqual(try resolved.node?.get(key: "alice"), "one")
        await XCTAssertThrowsErrorAsync(
            try await unresolved.resolve(paths: [["bob"]: .targeted], fetcher: storer)
        )
    }

    func testStorageAndResolutionSelectTheSameRadixVolumes() async throws {
        typealias Dictionary = VolumeMerkleDictionaryImpl<VolumeImpl<Leaf>>
        let dictionary = try Dictionary()
            .inserting(key: "alice", value: try VolumeImpl(node: Leaf(value: "one")))
            .inserting(key: "alicia", value: try VolumeImpl(node: Leaf(value: "two")))
            .inserting(key: "bob", value: try VolumeImpl(node: Leaf(value: "three")))
        let outer = try VolumeImpl(node: dictionary)
        let backing = RecordingStorer()
        try await outer.storeRecursively(storer: backing)

        for key in ["alice", "alicia", "bob", "carol"] {
            let stored = RecordingStorer()
            try await outer.store(paths: [[key]: .targeted], storer: stored)

            let fetcher = RecordingFetcher(backing: backing)
            let unresolved = VolumeImpl<Dictionary>(rawCID: outer.rawCID)
            _ = try await unresolved.resolve(
                paths: [[key]: .targeted],
                fetcher: fetcher
            )

            XCTAssertEqual(Set(stored.roots), fetcher.fetched, "path: \(key)")
        }
    }

    func testTargetedRadixValueVolumeUsesTheSameLogicalKeyAsResolve() async throws {
        typealias Dictionary = VolumeMerkleDictionaryImpl<VolumeImpl<Leaf>>
        let value = try VolumeImpl(node: Leaf(value: "payload"))
        let dictionary = try Dictionary().inserting(key: "item", value: value)
        let outer = try VolumeImpl(node: dictionary)
        let storer = RecordingStorer()

        try await outer.store(paths: [["item"]: .targeted], storer: storer)

        XCTAssertTrue(storer.roots.contains(value.rawCID))
        let unresolved = VolumeImpl<Dictionary>(rawCID: outer.rawCID)
        let resolved = try await unresolved.resolve(
            paths: [["item"]: .targeted],
            fetcher: storer
        )
        let resolvedValue = try resolved.node?.get(key: "item")
        XCTAssertEqual(resolvedValue?.node, Leaf(value: "payload"))
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (any Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

import Testing
import Foundation
import ArrayTrie
@testable import cashew

@Suite("Store and Resolve Lifecycle")
struct StoreResolveLifecycleTests {

    typealias InnerDict = MerkleDictionaryImpl<HeaderImpl<TestScalar>>

    @Test("Store and resolve round-trip preserves all data in nested structure")
    func testStoreResolveRoundTripNested() async throws {
        let s1 = TestScalar(val: 42)
        let s2 = TestScalar(val: 99)
        let s3 = TestScalar(val: 7)

        let inner = try InnerDict(children: [:], count: 0)
            .inserting(key: "alpha", value: try HeaderImpl(node: s1))
            .inserting(key: "beta", value: try HeaderImpl(node: s2))
            .inserting(key: "gamma", value: try HeaderImpl(node: s3))

        let outerDict = try MerkleDictionaryImpl<HeaderImpl<InnerDict>>(children: [:], count: 0)
            .inserting(key: "group1", value: try HeaderImpl(node: inner))

        let header = try HeaderImpl(node: outerDict)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let unresolved = HeaderImpl<MerkleDictionaryImpl<HeaderImpl<InnerDict>>>(rawCID: header.rawCID)
        let resolved = try await unresolved.resolveRecursive(fetcher: fetcher)

        #expect(resolved.rawCID == header.rawCID)
        let g1 = try resolved.node!.get(key: "group1")!
        #expect(g1.node!.count == 3)
        #expect(try g1.node!.get(key: "alpha")!.node!.val == 42)
        #expect(try g1.node!.get(key: "beta")!.node!.val == 99)
        #expect(try g1.node!.get(key: "gamma")!.node!.val == 7)
    }

    @Test("100-key dictionary: allKeysAndValues round-trip through store/resolve")
    func test100KeyStoreResolveAllKeysAndValues() async throws {
        var dict = MerkleDictionaryImpl<String>(children: [:], count: 0)
        for i in 0..<100 {
            dict = try dict.inserting(key: "k\(i)", value: "v\(i)")
        }

        let header = try HeaderImpl(node: dict)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let unresolved = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: header.rawCID)
        let resolved = try await unresolved.resolveRecursive(fetcher: fetcher)

        #expect(resolved.rawCID == header.rawCID)
        let kvPairs = try resolved.node!.allKeysAndValues()
        #expect(kvPairs.count == 100)
        for i in 0..<100 {
            #expect(kvPairs["k\(i)"] == "v\(i)")
        }
    }

    @Test("Empty dictionary round-trip through store/resolve")
    func testEmptyDictRoundTrip() async throws {
        let dict = MerkleDictionaryImpl<String>(children: [:], count: 0)
        let header = try HeaderImpl(node: dict)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let resolved = try await HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: header.rawCID)
            .resolveRecursive(fetcher: fetcher)
        #expect(resolved.node!.count == 0)
        #expect(resolved.rawCID == header.rawCID)
    }

    @Test("Single-entry dictionary survives full lifecycle")
    func testSingleEntryFullLifecycle() async throws {
        let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "only", value: "one")
        let header = try HeaderImpl(node: dict)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let resolved = try await HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: header.rawCID)
            .resolveRecursive(fetcher: fetcher)
        #expect(try resolved.node!.get(key: "only") == "one")

        var transforms = ArrayTrie<Transform>()
        transforms.set(["only"], value: .update("updated"))
        let transformed = try resolved.node!.transform(transforms: transforms)!

        #expect(try transformed.get(key: "only") == "updated")
        #expect(transformed.count == 1)

        let tHeader = try HeaderImpl(node: transformed)
        #expect(tHeader.rawCID != header.rawCID)

        try await tHeader.storeAsVolume(storer: fetcher)
        let reresolved = try await HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: tHeader.rawCID)
            .resolveRecursive(fetcher: fetcher)
        #expect(try reresolved.node!.get(key: "only") == "updated")
    }
}

@Suite("Structural Sharing")
struct StructuralSharingTests {

    @Test("Two dictionaries sharing a subtree have same CID for shared part")
    func testStructuralSharingCIDs() throws {
        typealias Inner = MerkleDictionaryImpl<String>
        typealias Outer = MerkleDictionaryImpl<HeaderImpl<Inner>>

        let shared = try Inner(children: [:], count: 0)
            .inserting(key: "shared1", value: "s1")
            .inserting(key: "shared2", value: "s2")
        let sharedHeader = try HeaderImpl(node: shared)

        let unique1 = try Inner(children: [:], count: 0)
            .inserting(key: "unique", value: "u1")
        let unique2 = try Inner(children: [:], count: 0)
            .inserting(key: "unique", value: "u2")

        let outer1 = try Outer(children: [:], count: 0)
            .inserting(key: "common", value: sharedHeader)
            .inserting(key: "specific", value: try HeaderImpl(node: unique1))
        let outer2 = try Outer(children: [:], count: 0)
            .inserting(key: "common", value: sharedHeader)
            .inserting(key: "specific", value: try HeaderImpl(node: unique2))

        let h1 = try HeaderImpl(node: outer1)
        let h2 = try HeaderImpl(node: outer2)

        #expect(h1.rawCID != h2.rawCID)

        let common1 = try outer1.get(key: "common")!
        let common2 = try outer2.get(key: "common")!
        #expect(common1.rawCID == common2.rawCID)
        #expect(common1.rawCID == sharedHeader.rawCID)
    }

    @Test("Store shared subtree once, resolve from two parents")
    func testSharedSubtreeStoreOnceResolveTwice() async throws {
        typealias Inner = MerkleDictionaryImpl<String>
        typealias Outer = MerkleDictionaryImpl<HeaderImpl<Inner>>

        let shared = try Inner(children: [:], count: 0)
            .inserting(key: "data", value: "shared_data")
        let sharedH = try HeaderImpl(node: shared)

        let parent1 = try Outer(children: [:], count: 0)
            .inserting(key: "ref", value: sharedH)
        let parent2 = try Outer(children: [:], count: 0)
            .inserting(key: "ref", value: sharedH)

        let fetcher = TestStoreFetcher()
        let p1h = try HeaderImpl(node: parent1)
        let p2h = try HeaderImpl(node: parent2)
        try await p1h.storeAsVolume(storer: fetcher)

        let r1 = try await HeaderImpl<Outer>(rawCID: p1h.rawCID).resolveRecursive(fetcher: fetcher)
        let r2 = try await HeaderImpl<Outer>(rawCID: p2h.rawCID).resolveRecursive(fetcher: fetcher)

        let val1 = try r1.node!.get(key: "ref")!.node!.get(key: "data")
        let val2 = try r2.node!.get(key: "ref")!.node!.get(key: "data")
        #expect(val1 == "shared_data")
        #expect(val2 == "shared_data")
    }
}

@Suite("Full Lifecycle")
struct FullLifecycleTests {

    @Test("Resolve, transform, re-store, re-resolve cycle")
    func testResolveTransformReStoreReResolveCycle() async throws {
        let dict = try MerkleDictionaryImpl<String>(children: [:], count: 0)
            .inserting(key: "version", value: "1")
            .inserting(key: "data", value: "initial")

        let header = try HeaderImpl(node: dict)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let unresolved1 = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: header.rawCID)
        let resolved1 = try await unresolved1.resolveRecursive(fetcher: fetcher)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["version"], value: .update("2"))
        transforms.set(["data"], value: .update("modified"))
        transforms.set(["newField"], value: .insert("added"))

        let transformed = try resolved1.node!.transform(transforms: transforms)!
        let transformedHeader = try HeaderImpl(node: transformed)
        try await transformedHeader.storeAsVolume(storer: fetcher)

        let unresolved2 = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: transformedHeader.rawCID)
        let resolved2 = try await unresolved2.resolveRecursive(fetcher: fetcher)

        #expect(resolved2.rawCID == transformedHeader.rawCID)
        #expect(resolved2.rawCID != header.rawCID)
        #expect(try resolved2.node!.get(key: "version") == "2")
        #expect(try resolved2.node!.get(key: "data") == "modified")
        #expect(try resolved2.node!.get(key: "newField") == "added")
        #expect(resolved2.node!.count == 3)
    }

    @Test("Scalar values in nested dict: full lifecycle with store/resolve/transform")
    func testScalarNestedLifecycle() async throws {
        typealias ScalarDict = MerkleDictionaryImpl<HeaderImpl<TestScalar>>

        var dict = ScalarDict(children: [:], count: 0)
        for i in 1...20 {
            dict = try dict.inserting(
                key: "item_\(String(format: "%02d", i))",
                value: try HeaderImpl(node: TestScalar(val: i * 10))
            )
        }
        #expect(dict.count == 20)

        let header = try HeaderImpl(node: dict)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let resolved = try await HeaderImpl<ScalarDict>(rawCID: header.rawCID)
            .resolveRecursive(fetcher: fetcher)

        for i in 1...20 {
            let key = "item_\(String(format: "%02d", i))"
            let val = try resolved.node!.get(key: key)
            #expect(val?.node?.val == i * 10)
        }

        let newScalar = TestScalar(val: 999)
        let newHeader = try HeaderImpl(node: newScalar)

        var transforms = ArrayTrie<Transform>()
        transforms.set(["item_05"], value: .update(newHeader.description))
        transforms.set(["item_10"], value: .delete)
        transforms.set(["item_21"], value: .insert(try HeaderImpl(node: TestScalar(val: 210)).description))

        let transformed = try resolved.node!.transform(transforms: transforms)!
        #expect(transformed.count == 20)

        let item05 = try transformed.get(key: "item_05")
        #expect(item05 != nil)

        #expect(try transformed.get(key: "item_10") == nil)

        let item15 = try transformed.get(key: "item_15")
        #expect(item15?.node?.val == 150)
    }
}

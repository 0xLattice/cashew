import Testing
import Foundation
import ArrayTrie
import CID
import Crypto
@preconcurrency import Multicodec
import Multihash
@testable import cashew

// MARK: - Test-specific helper types

struct SimpleNode: Node {
    let id: String
    let isLeaf: Bool

    init(id: String, isLeaf: Bool = false) {
        self.id = id
        self.isLeaf = isLeaf
    }

    func get(property: PathSegment) -> (any Header)? {
        if isLeaf { return nil }
        return HeaderImpl<SimpleNode>(rawCID: "\(id)-\(property)")
    }

    func properties() -> Set<PathSegment> {
        if isLeaf { return [] }
        return ["child1", "child2"]
    }

    func set(properties: [PathSegment: any Header]) -> Self {
        return self
    }
}

final class SimpleFetcher: Fetcher, Sendable {
    private let responses: [String: Data]

    init(responses: [String: SimpleNode] = [:]) {
        var data: [String: Data] = [:]
        for (key, node) in responses {
            if let d = node.toData() { data[key] = d }
        }
        self.responses = data
    }

    func fetch(rawCid: String) async throws -> Data {
        if let data = responses[rawCid] { return data }
        let leafNode = SimpleNode(id: "fetched-\(rawCid)", isLeaf: true)
        return leafNode.toData() ?? Data()
    }
}

struct UserScalar: Scalar {
    let id: String
    let name: String
    let email: String
}

struct DocumentScalar: Scalar {
    let id: String
    let title: String
    let content: String
}

struct DictionaryNode: Node {
    let id: String
    let entries: [String: String]

    init(id: String, entries: [String: String] = [:]) {
        self.id = id
        self.entries = entries
    }

    func get(property: PathSegment) -> (any Header)? {
        if let cid = entries[property] {
            return VolumeImpl<DictionaryNode>(rawCID: cid)
        }
        return VolumeImpl<DictionaryNode>(rawCID: "missing-entry-\(property)")
    }

    func properties() -> Set<PathSegment> {
        return Set(entries.keys)
    }

    func set(properties: [PathSegment: any Header]) -> Self {
        var newEntries = entries
        for (property, address) in properties {
            newEntries[property] = address.rawCID
        }
        return DictionaryNode(id: id, entries: newEntries)
    }
}

struct TestBaseStructure: Scalar {
    let val: Int
}

// MARK: - Basic Resolution

@Suite("Basic Resolution")
struct BasicResolutionTests {

    @Test("Header resolve fetches and reconstructs node from CID")
    func testBasicHeaderResolve() async throws {
        let storedHeader = try HeaderImpl(node: SimpleNode(id: "fetched-node", isLeaf: true))
        let cid = storedHeader.rawCID
        let header = HeaderImpl<SimpleNode>(rawCID: cid)

        let fetcher = SimpleFetcher(responses: [cid: storedHeader.node!])

        let resolvedHeader = try await header.resolve(fetcher: fetcher)

        #expect(resolvedHeader.rawCID == cid)
        #expect(resolvedHeader.node?.id == "fetched-node")
    }

    @Test("Header resolveRecursive fetches and processes node")
    func testHeaderResolveRecursive() async throws {
        let storedHeader = try HeaderImpl(node: SimpleNode(id: "recursive-node", isLeaf: true))
        let cid = storedHeader.rawCID
        let header = HeaderImpl<SimpleNode>(rawCID: cid)

        let fetcher = SimpleFetcher(responses: [cid: storedHeader.node!])

        let resolvedHeader = try await header.resolveRecursive(fetcher: fetcher)

        #expect(resolvedHeader.rawCID == cid)
        #expect(resolvedHeader.node?.id == "recursive-node")
    }

    @Test("Header resolve with existing node doesn't fetch")
    func testHeaderResolveWithExistingNode() async throws {
        let node = SimpleNode(id: "existing")
        let header = try HeaderImpl(node: node)
        let fetcher = SimpleFetcher()

        let resolvedHeader = try await header.resolve(fetcher: fetcher)

        #expect(resolvedHeader.node?.id == "existing")
    }

    @Test("Content addressability verification")
    func testContentAddressability() async throws {
        let originalNode = SimpleNode(id: "content-test")
        let originalHeader = try await HeaderImpl.create(node: originalNode)
        let originalCID = originalHeader.rawCID

        print(originalHeader)
        print(originalNode)

        let fetcher = SimpleFetcher(responses: [originalCID: originalNode])

        let cidOnlyHeader = HeaderImpl<SimpleNode>(rawCID: originalCID)
        let resolvedHeader = try await cidOnlyHeader.resolve(fetcher: fetcher)

        #expect(resolvedHeader.rawCID == originalCID)
        #expect(resolvedHeader.node!.id == "content-test")

        print(resolvedHeader)
        print(resolvedHeader.node)

        let recreatedCID = try await resolvedHeader.recreateCID()
        #expect(recreatedCID == originalCID)
    }

    @Test("Multiple resolve operations produce consistent results")
    func testResolveConsistency() async throws {
        let node = SimpleNode(id: "consistent")
        let header = try await HeaderImpl.create(node: node)
        let cid = header.rawCID

        let fetcher = SimpleFetcher(responses: [cid: node])

        let cidHeader1 = HeaderImpl<SimpleNode>(rawCID: cid)
        let cidHeader2 = HeaderImpl<SimpleNode>(rawCID: cid)

        let resolved1 = try await cidHeader1.resolve(fetcher: fetcher)
        let resolved2 = try await cidHeader2.resolve(fetcher: fetcher)

        #expect(resolved1.rawCID == resolved2.rawCID)
        #expect(resolved1.node?.id == resolved2.node?.id)

        let recreated1 = try await resolved1.recreateCID()
        let recreated2 = try await resolved2.recreateCID()
        #expect(recreated1 == recreated2)
        #expect(recreated1 == cid)
    }

    @Test("Node resolve processing")
    func testNodeResolve() async throws {
        let child = DictionaryNode(id: "leaf1")
        let childHeader = try HeaderImpl(node: child)
        let node = DictionaryNode(id: "node-resolve-test", entries: ["child1": childHeader.rawCID])
        let fetcher = TestStoreFetcher()
        try await childHeader.storeAsVolume(storer: fetcher)

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["child1"], value: .targeted)

        let resolvedNode = try await node.resolve(paths: paths, fetcher: fetcher)

        #expect(resolvedNode.id == "node-resolve-test")
        #expect(resolvedNode.properties().contains("child1"))
    }

    @Test("Node resolveRecursive processing")
    func testNodeResolveRecursive() async throws {
        let child1 = DictionaryNode(id: "leaf1")
        let child2 = DictionaryNode(id: "leaf2")
        let childHeader1 = try HeaderImpl(node: child1)
        let childHeader2 = try HeaderImpl(node: child2)
        let node = DictionaryNode(
            id: "recursive-node-test",
            entries: ["child1": childHeader1.rawCID, "child2": childHeader2.rawCID]
        )
        let fetcher = TestStoreFetcher()
        try await childHeader1.storeAsVolume(storer: fetcher)
        try await childHeader2.storeAsVolume(storer: fetcher)

        let resolvedNode = try await node.resolveRecursive(fetcher: fetcher)

        #expect(resolvedNode.id == "recursive-node-test")
    }
}

// MARK: - Resolution Strategies

@Suite("Resolution Strategies")
struct ResolutionStrategiesTests {

    // MARK: - Header Resolve Tests (from ResolveTests)

    @Test("Header resolve with existing node - no fetching required")
    func testHeaderResolveWithExistingNode() async throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "key1", value: "value1")
        let header = try HeaderImpl(node: dictionary)
        let fetcher = TestStoreFetcher()

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["key1"], value: .targeted)

        let resolvedHeader = try await header.resolve(paths: paths, fetcher: fetcher)

        #expect(resolvedHeader.rawCID == header.rawCID)
        #expect(try resolvedHeader.node?.get(key: "key1") == "value1")
    }

    @Test("Header resolve without node - fetches from CID")
    func testHeaderResolveWithoutNode() async throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "fetched", value: "true")
        let headerWithNode = try HeaderImpl(node: dictionary)

        let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: headerWithNode.rawCID)
        let fetcher = TestStoreFetcher()
        try await headerWithNode.storeAsVolume(storer: fetcher)

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["fetched"], value: .targeted)

        let resolvedHeader = try await header.resolve(paths: paths, fetcher: fetcher)

        #expect(resolvedHeader.rawCID == headerWithNode.rawCID)
        #expect(try resolvedHeader.node?.get(key: "fetched") == "true")
    }

    @Test("Header resolveRecursive with existing node")
    func testHeaderResolveRecursiveWithExistingNode() async throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "key1", value: "value1")
        dictionary = try dictionary.inserting(key: "child1", value: "data1")
        dictionary = try dictionary.inserting(key: "child2", value: "data2")
        let header = try HeaderImpl(node: dictionary)
        let fetcher = TestStoreFetcher()

        let resolvedHeader = try await header.resolveRecursive(fetcher: fetcher)

        #expect(resolvedHeader.rawCID == header.rawCID)
        #expect(try resolvedHeader.node?.get(key: "key1") == "value1")
        #expect(try resolvedHeader.node?.get(key: "child1") == "data1")
    }

    @Test("Header resolveRecursive without node - fetches from CID")
    func testHeaderResolveRecursiveWithoutNode() async throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "recursive", value: "true")
        let headerWithNode = try HeaderImpl(node: dictionary)

        let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: headerWithNode.rawCID)
        let fetcher = TestStoreFetcher()
        try await headerWithNode.storeAsVolume(storer: fetcher)

        let resolvedHeader = try await header.resolveRecursive(fetcher: fetcher)

        #expect(resolvedHeader.rawCID == headerWithNode.rawCID)
        #expect(try resolvedHeader.node?.get(key: "recursive") == "true")
    }

    @Test("Header resolve basic - fetches node when missing")
    func testHeaderResolveBasic() async throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "basic", value: "true")
        let headerWithNode = try HeaderImpl(node: dictionary)

        let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: headerWithNode.rawCID)
        let fetcher = TestStoreFetcher()
        try await headerWithNode.storeAsVolume(storer: fetcher)

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["basic"], value: .targeted)

        let resolvedHeader = try await header.resolve(paths: paths, fetcher: fetcher)

        #expect(resolvedHeader.rawCID == headerWithNode.rawCID)
        #expect(try resolvedHeader.node?.get(key: "basic") == "true")
    }

    @Test("Header resolve basic - returns self when node exists")
    func testHeaderResolveBasicWithExistingNode() async throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "exists", value: "true")
        let header = try HeaderImpl(node: dictionary)
        let fetcher = TestStoreFetcher()

        let resolvedHeader = try await header.resolve(fetcher: fetcher)

        #expect(resolvedHeader.rawCID == header.rawCID)
        #expect(try resolvedHeader.node?.get(key: "exists") == "true")
        #expect(resolvedHeader.rawCID == header.rawCID)
        #expect(resolvedHeader.node?.count == header.node?.count)
    }

    @Test("Header resolve with dictionary paths")
    func testHeaderResolveWithDictionaryPaths() async throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "path1", value: "value1")
        dictionary = try dictionary.inserting(key: "path2", value: "value2")
        let header = try HeaderImpl(node: dictionary)
        let fetcher = TestStoreFetcher()

        let paths = [["path1"]: ResolutionStrategy.targeted, ["path2"]: ResolutionStrategy.recursive]

        let resolvedHeader = try await header.resolve(paths: paths, fetcher: fetcher)

        #expect(resolvedHeader.rawCID == header.rawCID)
        #expect(try resolvedHeader.node?.get(key: "path1") == "value1")
        #expect(try resolvedHeader.node?.get(key: "path2") == "value2")
    }

    @Test("Header resolve with empty paths returns self")
    func testHeaderResolveWithEmptyPaths() async throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "key", value: "value")
        let header = try HeaderImpl(node: dictionary)
        let fetcher = TestStoreFetcher()

        let emptyPaths = ArrayTrie<ResolutionStrategy>()

        let resolvedHeader = try await header.resolve(paths: emptyPaths, fetcher: fetcher)

        #expect(resolvedHeader.rawCID == header.rawCID)
        #expect(try resolvedHeader.node?.get(key: "key") == "value")
    }

    @Test("Resolve maintains content addressability")
    func testResolveContentAddressability() async throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "content", value: "addressable")
        let originalHeader = try HeaderImpl(node: dictionary)
        let originalCID = originalHeader.rawCID

        let fetcher = TestStoreFetcher()
        try await originalHeader.storeAsVolume(storer: fetcher)

        let cidOnlyHeader = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: originalCID)

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["content"], value: .targeted)

        let resolvedHeader = try await cidOnlyHeader.resolve(paths: paths, fetcher: fetcher)

        #expect(resolvedHeader.rawCID == originalCID)
        #expect(try resolvedHeader.node?.get(key: "content") == "addressable")

        let recreatedCID = try await resolvedHeader.recreateCID()
        #expect(recreatedCID == originalCID)
    }

    @Test("Resolve rejects bytes stored under the wrong CID")
    func testResolveDataIntegrityVerification() async throws {
        var originalDict = MerkleDictionaryImpl<String>(children: [:], count: 0)
        originalDict = try originalDict.inserting(key: "hash", value: "verification")
        let originalHeader = try HeaderImpl(node: originalDict)
        let originalCID = originalHeader.rawCID

        var tamperedDict = MerkleDictionaryImpl<String>(children: [:], count: 0)
        tamperedDict = try tamperedDict.inserting(key: "hash", value: "corrupted")
        let tamperedHeader = try HeaderImpl(node: tamperedDict)
        let tamperedCID = tamperedHeader.rawCID

        let fetcher = TestStoreFetcher()
        guard let tamperedData = tamperedDict.toData() else {
            Issue.record("failed to serialize tampered dictionary")
            return
        }
        fetcher.storeRaw(rawCid: originalCID, data: tamperedData)

        let cidOnlyHeader = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: originalCID)

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["hash"], value: .targeted)

        #expect(tamperedCID != originalCID)
        await #expect(throws: DataErrors.self) {
            _ = try await cidOnlyHeader.resolve(paths: paths, fetcher: fetcher)
        }
    }

    @Test("Multiple resolve operations with same CID produce consistent results")
    func testMultipleResolveConsistency() async throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "test", value: "consistency")
        let header = try HeaderImpl(node: dictionary)
        let cid = header.rawCID

        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let cidHeader1 = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: cid)
        let cidHeader2 = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: cid)

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["test"], value: .targeted)

        let resolved1 = try await cidHeader1.resolve(paths: paths, fetcher: fetcher)
        let resolved2 = try await cidHeader2.resolve(paths: paths, fetcher: fetcher)

        #expect(resolved1.rawCID == resolved2.rawCID)
        #expect(try resolved1.node?.get(key: "test") == "consistency")
        #expect(try resolved2.node?.get(key: "test") == "consistency")

        let recreated1 = try await resolved1.recreateCID()
        let recreated2 = try await resolved2.recreateCID()
        #expect(recreated1 == recreated2)
        #expect(recreated1 == cid)
    }

    @Test("Resolve handles fetcher errors gracefully")
    func testResolveHandlesFetcherErrors() async throws {
        let cid = "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"
        let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: cid)

        final class ErrorFetcher: Fetcher, Sendable {
            func fetch(rawCid: String) async throws -> Data {
                throw NSError(domain: "TestError", code: 404, userInfo: [NSLocalizedDescriptionKey: "CID not found"])
            }
        }

        let errorFetcher = ErrorFetcher()

        await #expect(throws: NSError.self) {
            try await header.resolve(fetcher: errorFetcher)
        }
    }

    @Test("Resolve handles invalid node data gracefully")
    func testResolveHandlesInvalidNodeData() async throws {
        let cid = "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"
        let header = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: cid)

        let fetcher = TestStoreFetcher()
        let invalidData = "invalid json".data(using: .utf8)!
        fetcher.storeRaw(rawCid: cid, data: invalidData)

        await #expect(throws: (any Error).self) {
            try await header.resolve(fetcher: fetcher)
        }
    }

    @Test("Node resolveRecursive resolves all properties")
    func testNodeResolveRecursive() async throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "child1", value: "value1")
        dictionary = try dictionary.inserting(key: "child2", value: "value2")

        let fetcher = TestStoreFetcher()
        let resolvedNode = try await dictionary.resolveRecursive(fetcher: fetcher)

        #expect(try resolvedNode.get(key: "child1") == "value1")
        #expect(try resolvedNode.get(key: "child2") == "value2")
    }

    @Test("Node resolve with targeted strategy")
    func testNodeResolveTargeted() async throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "target", value: "value")
        dictionary = try dictionary.inserting(key: "other", value: "ignored")

        let fetcher = TestStoreFetcher()

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["target"], value: .targeted)

        let resolvedNode = try await dictionary.resolve(paths: paths, fetcher: fetcher)

        #expect(try resolvedNode.get(key: "target") == "value")
        #expect(try resolvedNode.get(key: "other") == "ignored")
    }

    @Test("Node resolve with recursive strategy")
    func testNodeResolveRecursiveStrategy() async throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "recursive-prop", value: "value")

        let fetcher = TestStoreFetcher()

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["recursive-prop"], value: .recursive)

        let resolvedNode = try await dictionary.resolve(paths: paths, fetcher: fetcher)

        #expect(try resolvedNode.get(key: "recursive-prop") == "value")
    }

    @Test("Node resolve with nested paths")
    func testNodeResolveNestedPaths() async throws {
        let childNode = RadixNodeImpl<String>(prefix: "nested", value: "value", children: [:])
        let childHeader = try RadixHeaderImpl(node: childNode)

        let children: [Character: RadixHeaderImpl<String>] = ["n": childHeader]
        let parentNode = RadixNodeImpl<String>(prefix: "child", value: nil, children: children)

        let fetcher = TestStoreFetcher()

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["n", "nested"], value: .targeted)

        let resolvedNode = try await parentNode.resolve(paths: paths, fetcher: fetcher)

        #expect(resolvedNode.prefix == "child")
        #expect(resolvedNode.properties().contains("n"))
    }

    @Test("Node resolve handles empty paths gracefully")
    func testNodeResolveEmptyPaths() async throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "key", value: "value")

        let fetcher = TestStoreFetcher()

        let emptyPaths = ArrayTrie<ResolutionStrategy>()
        let resolvedNode = try await dictionary.resolve(paths: emptyPaths, fetcher: fetcher)

        #expect(try resolvedNode.get(key: "key") == "value")
    }

    @Test("Node resolve with mixed strategies")
    func testNodeResolveMixedStrategies() async throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "target-prop", value: "target-value")
        dictionary = try dictionary.inserting(key: "recursive-prop", value: "recursive-value")
        dictionary = try dictionary.inserting(key: "ignored-prop", value: "ignored-value")

        let fetcher = TestStoreFetcher()

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["target-prop"], value: .targeted)
        paths.set(["recursive-prop"], value: .recursive)

        let resolvedNode = try await dictionary.resolve(paths: paths, fetcher: fetcher)

        #expect(try resolvedNode.get(key: "target-prop") == "target-value")
        #expect(try resolvedNode.get(key: "recursive-prop") == "recursive-value")
        #expect(try resolvedNode.get(key: "ignored-prop") == "ignored-value")
    }

    // MARK: - RadixNode Tests (from ResolveTests)

    @Test("RadixNode structure integrity")
    func testRadixNodeStructure() async throws {
        let childNode = RadixNodeImpl<String>(prefix: "child", value: "child-value", children: [:])
        let childHeader = try RadixHeaderImpl(node: childNode)

        let children: [Character: RadixHeaderImpl<String>] = ["a": childHeader]
        let node = RadixNodeImpl(prefix: "test", value: "test-value", children: children)

        #expect(node.prefix == "test")
        #expect(node.value == "test-value")
        #expect(node.children.count == 1)
        #expect(node.children["a"]?.rawCID == childHeader.rawCID)
        #expect(node.properties().contains("a"))
    }

    @Test("RadixNode property access")
    func testRadixNodePropertyAccess() async throws {
        let childNode1 = RadixNodeImpl<String>(prefix: "child1", value: "accessible-value", children: [:])
        let childHeader1 = try RadixHeaderImpl(node: childNode1)

        let childNode2 = RadixNodeImpl<String>(prefix: "child2", value: "another-value", children: [:])
        let childHeader2 = try RadixHeaderImpl(node: childNode2)

        let children: [Character: RadixHeaderImpl<String>] = ["x": childHeader1, "y": childHeader2]
        let node = RadixNodeImpl<String>(prefix: "access", value: nil, children: children)

        let retrievedChild = node.get(property: "x")
        if let childHeader = retrievedChild as? RadixHeaderImpl<String> {
            #expect(childHeader.rawCID == childHeader1.rawCID)
        }

        #expect(node.properties().count == 2)
        #expect(node.properties().contains("x"))
        #expect(node.properties().contains("y"))
    }

    @Test("RadixNode property modification")
    func testRadixNodePropertyModification() async throws {
        let originalNode = RadixNodeImpl<String>(prefix: "original", value: "original-value", children: [:])
        let originalChild = try RadixHeaderImpl(node: originalNode)

        let children: [Character: RadixHeaderImpl<String>] = ["m": originalChild]
        let node = RadixNodeImpl<String>(prefix: "modify", value: nil, children: children)

        let newNode = RadixNodeImpl<String>(prefix: "new", value: "new-value", children: [:])
        let newHeader = try RadixHeaderImpl(node: newNode)
        let modifiedNode = node.set(property: "m", to: newHeader)

        #expect(modifiedNode.prefix == "modify")
        #expect(modifiedNode.children.count == 1)
        #expect(modifiedNode.children["m"] != nil)
        #expect(modifiedNode.properties().contains("m"))
    }

    @Test("End-to-end resolve test with Header and RadixNode")
    func testEndToEndResolveIntegration() async throws {
        let leafChildNode = RadixNodeImpl<String>(prefix: "leaf-key", value: "leaf-value", children: [:])
        let leafChild = try RadixHeaderImpl(node: leafChildNode)

        let leafChildren: [Character: RadixHeaderImpl<String>] = ["z": leafChild]
        let leafNode = RadixNodeImpl<String>(prefix: "leaf", value: nil, children: leafChildren)

        let header = try HeaderImpl(node: leafNode)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let cidOnlyHeader = HeaderImpl<RadixNodeImpl<String>>(rawCID: header.rawCID)

        let resolvedHeader = try await cidOnlyHeader.resolve(fetcher: fetcher)

        #expect(resolvedHeader.rawCID == header.rawCID)
        #expect(resolvedHeader.node?.prefix == "leaf")
        #expect(resolvedHeader.node?.children.count == 1)

        let recreatedCID = try await resolvedHeader.recreateCID()
        #expect(recreatedCID == header.rawCID)
    }

    @Test("Resolve maintains data structure integrity through hash verification")
    func testResolveDataStructureIntegrity() async throws {
        let childNodeA = RadixNodeImpl<String>(prefix: "child-a", value: "value-a", children: [:])
        let childHeaderA = try RadixHeaderImpl(node: childNodeA)

        let childNodeB = RadixNodeImpl<String>(prefix: "child-b", value: "value-b", children: [:])
        let childHeaderB = try RadixHeaderImpl(node: childNodeB)

        let simpleChildren: [Character: RadixHeaderImpl<String>] = [
            "a": childHeaderA,
            "b": childHeaderB
        ]
        let simpleNode = RadixNodeImpl<String>(prefix: "simple", value: "test-value", children: simpleChildren)

        let originalHeader = try HeaderImpl(node: simpleNode)
        let fetcher = TestStoreFetcher()
        try await originalHeader.storeAsVolume(storer: fetcher)

        let cidOnlyHeader = HeaderImpl<RadixNodeImpl<String>>(rawCID: originalHeader.rawCID)
        let resolvedHeader = try await cidOnlyHeader.resolve(fetcher: fetcher)

        #expect(resolvedHeader.rawCID == originalHeader.rawCID)
        #expect(resolvedHeader.node?.prefix == "simple")
        #expect(resolvedHeader.node?.value == "test-value")
        #expect(resolvedHeader.node?.children.count == 2)

        let finalCID = try await resolvedHeader.recreateCID()
        #expect(finalCID == originalHeader.rawCID)
    }

    // MARK: - Complex Data Structure Resolution (from ComplexResolveTests)

    typealias UserHeader = HeaderImpl<UserScalar>
    typealias DocumentHeader = HeaderImpl<DocumentScalar>
    private func createSimpleDataStructure() async throws -> (HeaderImpl<DictionaryNode>, TestStoreFetcher) {
        let testStoreFetcher = TestStoreFetcher()

        let aliceUser = UserScalar(id: "alice", name: "Alice", email: "alice@example.com")
        let bobUser = UserScalar(id: "bob", name: "Bob", email: "bob@example.com")
        let charlieUser = UserScalar(id: "charlie", name: "Charlie", email: "charlie@example.com")

        let doc1 = DocumentScalar(id: "doc1", title: "Introduction", content: "Welcome to our system")
        let doc2 = DocumentScalar(id: "doc2", title: "Tutorial", content: "How to use the system")
        let doc3 = DocumentScalar(id: "doc3", title: "Advanced", content: "Advanced features")

        let aliceHeader = try HeaderImpl(node: aliceUser)
        let bobHeader = try HeaderImpl(node: bobUser)
        let charlieHeader = try HeaderImpl(node: charlieUser)
        let doc1Header = try HeaderImpl(node: doc1)
        let doc2Header = try HeaderImpl(node: doc2)
        let doc3Header = try HeaderImpl(node: doc3)

        try await aliceHeader.storeAsVolume(storer: testStoreFetcher)
        try await bobHeader.storeAsVolume(storer: testStoreFetcher)
        try await charlieHeader.storeAsVolume(storer: testStoreFetcher)
        try await doc1Header.storeAsVolume(storer: testStoreFetcher)
        try await doc2Header.storeAsVolume(storer: testStoreFetcher)
        try await doc3Header.storeAsVolume(storer: testStoreFetcher)

        let documentDict = DictionaryNode(id: "alice-docs", entries: [
            "intro": doc1Header.rawCID,
            "tutorial": doc2Header.rawCID,
            "advanced": doc3Header.rawCID
        ])

        let friendsDict = DictionaryNode(id: "alice-friends", entries: [
            "bob": bobHeader.rawCID,
            "charlie": charlieHeader.rawCID
        ])

        let documentDictHeader = try HeaderImpl(node: documentDict)
        let friendsDictHeader = try HeaderImpl(node: friendsDict)
        try await documentDictHeader.storeAsVolume(storer: testStoreFetcher)
        try await friendsDictHeader.storeAsVolume(storer: testStoreFetcher)

        let rootDict = DictionaryNode(id: "root", entries: [
            "user": aliceHeader.rawCID,
            "documents": documentDictHeader.rawCID,
            "friends": friendsDictHeader.rawCID
        ])

        let rootHeader = try HeaderImpl(node: rootDict)
        try await rootHeader.storeAsVolume(storer: testStoreFetcher)

        return (rootHeader, testStoreFetcher)
    }

    @Test("Target resolution - resolve to dictionary nodes")
    func testTargetResolution() async throws {
        let (rootHeader, fetcher) = try await createSimpleDataStructure()

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["documents"], value: .targeted)

        let resolvedHeader = try await rootHeader.resolve(paths: paths, fetcher: fetcher)

        #expect(resolvedHeader.rawCID == rootHeader.rawCID)
        #expect(resolvedHeader.node?.id == "root")

        #expect(resolvedHeader.node?.entries["documents"] != nil)
    }

    @Test("Scalar resolution - resolve individual scalar endpoints")
    func testScalarResolution() async throws {
        let testStoreFetcher = TestStoreFetcher()

        let userScalar = UserScalar(id: "test-user", name: "Test User", email: "test@example.com")
        let userHeader = try HeaderImpl(node: userScalar)
        try await userHeader.storeAsVolume(storer: testStoreFetcher)

        let resolvedUserHeader = try await userHeader.resolve(fetcher: testStoreFetcher)

        #expect(resolvedUserHeader.rawCID == userHeader.rawCID)
        #expect(resolvedUserHeader.node?.id == "test-user")
        #expect(resolvedUserHeader.node?.name == "Test User")
        #expect(resolvedUserHeader.node?.email == "test@example.com")

        let emptyPaths = ArrayTrie<ResolutionStrategy>()
        let resolvedWithEmptyPaths = try await userHeader.resolve(paths: emptyPaths, fetcher: testStoreFetcher)
        #expect(resolvedWithEmptyPaths.rawCID == userHeader.rawCID)
        #expect(resolvedWithEmptyPaths.node?.id == "test-user")
    }

    @Test("Dictionary and Scalar as separate concerns")
    func testDictionaryScalarSeparation() async throws {
        let testStoreFetcher = TestStoreFetcher()

        let user1 = UserScalar(id: "user1", name: "Alice", email: "alice@example.com")
        let user2 = UserScalar(id: "user2", name: "Bob", email: "bob@example.com")

        let user1Header = try HeaderImpl(node: user1)
        let user2Header = try HeaderImpl(node: user2)
        try await user1Header.storeAsVolume(storer: testStoreFetcher)
        try await user2Header.storeAsVolume(storer: testStoreFetcher)

        let metadataDict = DictionaryNode(id: "metadata", entries: [
            "created": "2024-01-01",
            "version": "1.0"
        ])

        let rootDict = DictionaryNode(id: "root", entries: [
            "metadata": try HeaderImpl(node: metadataDict).rawCID
        ])

        let metadataHeader = try HeaderImpl(node: metadataDict)
        let rootHeader = try HeaderImpl(node: rootDict)

        try await metadataHeader.storeAsVolume(storer: testStoreFetcher)
        try await rootHeader.storeAsVolume(storer: testStoreFetcher)

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["metadata"], value: .targeted)

        let resolvedHeader = try await rootHeader.resolve(paths: paths, fetcher: testStoreFetcher)
        #expect(resolvedHeader.rawCID == rootHeader.rawCID)
        #expect(resolvedHeader.node?.entries["metadata"] != nil)

        let aliceResolved = try await user1Header.resolve(fetcher: testStoreFetcher)
        #expect(aliceResolved.node?.name == "Alice")
    }

    @Test("List resolution - get all dictionary entries with path prefix")
    func testListResolution() async throws {
        let (rootHeader, fetcher) = try await createSimpleDataStructure()

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["documents"], value: .list)

        let resolvedHeader = try await rootHeader.resolve(paths: paths, fetcher: fetcher)

        #expect(resolvedHeader.rawCID == rootHeader.rawCID)
        #expect(resolvedHeader.node?.id == "root")

        #expect(resolvedHeader.node?.entries["documents"] != nil)
    }

    @Test("Targeted resolution for dictionary structures")
    func testTargetedResolutionDictionaries() async throws {
        let (rootHeader, fetcher) = try await createSimpleDataStructure()

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["friends"], value: .targeted)

        let resolvedHeader = try await rootHeader.resolve(paths: paths, fetcher: fetcher)

        #expect(resolvedHeader.rawCID == rootHeader.rawCID)
        #expect(resolvedHeader.node?.id == "root")

        #expect(resolvedHeader.node?.entries["friends"] != nil)
    }

    @Test("Multiple path resolution - resolve different strategies in one call")
    func testMultiplePathResolution() async throws {
        let (rootHeader, fetcher) = try await createSimpleDataStructure()

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["documents"], value: .targeted)
        paths.set(["friends"], value: .list)

        let resolvedHeader = try await rootHeader.resolve(paths: paths, fetcher: fetcher)

        #expect(resolvedHeader.rawCID == rootHeader.rawCID)
        #expect(resolvedHeader.node?.id == "root")

        #expect(resolvedHeader.node?.entries["documents"] != nil)
        #expect(resolvedHeader.node?.entries["friends"] != nil)
    }

    @Test("Dictionary path resolution")
    func testDictionaryPathResolution() async throws {
        let (rootHeader, fetcher) = try await createSimpleDataStructure()

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["documents"], value: .targeted)
        paths.set(["friends"], value: .targeted)

        let resolvedHeader = try await rootHeader.resolve(paths: paths, fetcher: fetcher)

        #expect(resolvedHeader.rawCID == rootHeader.rawCID)
        #expect(resolvedHeader.node?.id == "root")

        #expect(resolvedHeader.node?.entries["documents"] != nil)
        #expect(resolvedHeader.node?.entries["friends"] != nil)
    }

    @Test("Mixed resolution strategies with path prefixes")
    func testMixedResolutionStrategies() async throws {
        let (rootHeader, fetcher) = try await createSimpleDataStructure()

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["documents"], value: .list)
        paths.set(["friends"], value: .targeted)

        let resolvedHeader = try await rootHeader.resolve(paths: paths, fetcher: fetcher)

        #expect(resolvedHeader.rawCID == rootHeader.rawCID)
        #expect(resolvedHeader.node?.id == "root")

        #expect(resolvedHeader.node?.entries["documents"] != nil)
        #expect(resolvedHeader.node?.entries["friends"] != nil)
    }

    @Test("Resolution with path patterns matching")
    func testResolutionWithPathPatterns() async throws {
        let (rootHeader, fetcher) = try await createSimpleDataStructure()

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["documents"], value: .list)

        let resolvedHeader = try await rootHeader.resolve(paths: paths, fetcher: fetcher)

        #expect(resolvedHeader.rawCID == rootHeader.rawCID)

        #expect(resolvedHeader.node?.entries["documents"] != nil)
    }

    @Test("Empty path resolution returns original")
    func testEmptyPathResolution() async throws {
        let (rootHeader, fetcher) = try await createSimpleDataStructure()

        let emptyPaths = ArrayTrie<ResolutionStrategy>()

        let resolvedHeader = try await rootHeader.resolve(paths: emptyPaths, fetcher: fetcher)

        #expect(resolvedHeader.rawCID == rootHeader.rawCID)
        #expect(resolvedHeader.node?.id == rootHeader.node?.id)
    }

    @Test("Dictionary resolution at multiple levels")
    func testDictionaryResolutionMultipleLevels() async throws {
        let (rootHeader, fetcher) = try await createSimpleDataStructure()

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["documents"], value: .targeted)
        paths.set(["friends"], value: .list)

        let resolvedHeader = try await rootHeader.resolve(paths: paths, fetcher: fetcher)

        #expect(resolvedHeader.rawCID == rootHeader.rawCID)
        #expect(resolvedHeader.node?.id == "root")

        #expect(resolvedHeader.node?.entries["documents"] != nil)
        #expect(resolvedHeader.node?.entries["friends"] != nil)
    }

    @Test("Content addressability with simple structures")
    func testContentAddressabilitySimpleStructures() async throws {
        let (rootHeader, fetcher) = try await createSimpleDataStructure()
        let originalCID = rootHeader.rawCID

        let cidOnlyHeader = HeaderImpl<DictionaryNode>(rawCID: originalCID)

        var paths = ArrayTrie<ResolutionStrategy>()
        paths.set(["documents"], value: .targeted)

        let resolvedHeader = try await cidOnlyHeader.resolve(paths: paths, fetcher: fetcher)

        #expect(resolvedHeader.rawCID == originalCID)
        #expect(resolvedHeader.node?.id == "root")

        let recreatedCID = try await rootHeader.recreateCID()
        #expect(recreatedCID == originalCID)
    }

    // MARK: - Targeted Resolution Selectivity (from ComplexEdgeCaseTests)

    @Test("Store/resolve round-trip with targeted resolution only resolves requested paths")
    func testTargetedResolutionSelectivity() async throws {
        typealias DictType = MerkleDictionaryImpl<HeaderImpl<TestScalar>>

        let dict = try DictType(children: [:], count: 0)
            .inserting(key: "Foo", value: try HeaderImpl(node: TestScalar(val: 1)))
            .inserting(key: "Bar", value: try HeaderImpl(node: TestScalar(val: 2)))
            .inserting(key: "Baz", value: try HeaderImpl(node: TestScalar(val: 3)))

        let header = try HeaderImpl(node: dict)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let unresolved = HeaderImpl<DictType>(rawCID: header.rawCID)
        let resolved = try await unresolved.resolve(
            paths: [["F"]: .targeted],
            fetcher: fetcher
        )

        let foo = try resolved.node!.get(key: "Foo")
        #expect(foo != nil)
        #expect(foo!.rawCID == (try HeaderImpl(node: TestScalar(val: 1)).rawCID))

        #expect(throws: TransformErrors.self) {
            _ = try resolved.node!.get(key: "Bar")
        }
    }

    @Test("List resolution resolves dictionary structure but not nested addresses")
    func testListResolutionDepth() async throws {
        typealias InnerDict = MerkleDictionaryImpl<HeaderImpl<TestScalar>>
        typealias OuterDict = MerkleDictionaryImpl<HeaderImpl<InnerDict>>

        let inner = try InnerDict(children: [:], count: 0)
            .inserting(key: "x", value: try HeaderImpl(node: TestScalar(val: 10)))
            .inserting(key: "y", value: try HeaderImpl(node: TestScalar(val: 20)))
        let innerH = try HeaderImpl(node: inner)

        let outer = try OuterDict(children: [:], count: 0)
            .inserting(key: "Group", value: innerH)

        let outerH = try HeaderImpl(node: outer)
        let fetcher = TestStoreFetcher()
        try await outerH.storeAsVolume(storer: fetcher)

        let unresolved = HeaderImpl<OuterDict>(rawCID: outerH.rawCID)
        let resolved = try await unresolved.resolve(
            paths: [["G"]: .list],
            fetcher: fetcher
        )

        #expect(resolved.node != nil)
        #expect(resolved.node!.count == 1)
        let group = try resolved.node!.get(key: "Group")
        #expect(group != nil)
        #expect(group!.node == nil)
    }
}

// MARK: - Dictionary Resolution

@Suite("Dictionary Resolution")
struct DictionaryResolutionTests {

    @Test("MerkleDictionary basic resolve recursive")
    func testMerkleDictionaryBasicResolveRecursive() async throws {
        typealias BaseDictionaryType = MerkleDictionaryImpl<HeaderImpl<TestBaseStructure>>

        let baseStructure1 = TestBaseStructure(val: 1)
        let baseStructure2 = TestBaseStructure(val: 2)
        let baseHeader1 = try HeaderImpl(node: baseStructure1)
        let baseHeader2 = try HeaderImpl(node: baseStructure2)

        let emptyDictionary = BaseDictionaryType(children: [:], count: 0)
        let dictionary = try emptyDictionary
            .inserting(key: "Foo", value: baseHeader1)
            .inserting(key: "Bar", value: baseHeader2)
        let dictionaryHeader = try HeaderImpl(node: dictionary)
        let testStoreFetcher = TestStoreFetcher()
        try await dictionaryHeader.storeAsVolume(storer: testStoreFetcher)
        let newDictionaryHeader = HeaderImpl<BaseDictionaryType>(rawCID: dictionaryHeader.rawCID)
        let resolvedDictionary = try await newDictionaryHeader.resolveRecursive(fetcher: testStoreFetcher)
        #expect(resolvedDictionary.node != nil)
        #expect(resolvedDictionary.node!.count == 2)

        let fooValue = try resolvedDictionary.node!.get(key: "Foo")
        let barValue = try resolvedDictionary.node!.get(key: "Bar")

        #expect(fooValue != nil)
        #expect(fooValue?.node?.val == 1)
        #expect(barValue != nil)
        #expect(barValue?.node?.val == 2)
    }

    @Test("MerkleDictionary basic resolve")
    func testMerkleDictionaryBasicResolve() async throws {
        typealias BaseDictionaryType = MerkleDictionaryImpl<HeaderImpl<TestBaseStructure>>

        let baseStructure1 = TestBaseStructure(val: 1)
        let baseStructure2 = TestBaseStructure(val: 2)
        let baseHeader1 = try HeaderImpl(node: baseStructure1)
        let baseHeader2 = try HeaderImpl(node: baseStructure2)

        let emptyDictionary = BaseDictionaryType(children: [:], count: 0)
        let dictionary = try emptyDictionary
            .inserting(key: "Foo", value: baseHeader1)
            .inserting(key: "Bar", value: baseHeader2)
        let dictionaryHeader = try HeaderImpl(node: dictionary)
        let testStoreFetcher = TestStoreFetcher()
        try await dictionaryHeader.storeAsVolume(storer: testStoreFetcher)
        let newDictionaryHeader = HeaderImpl<BaseDictionaryType>(rawCID: dictionaryHeader.rawCID)
        let resolvedDictionary = try await newDictionaryHeader.resolve(paths: [["Foo"]: .targeted], fetcher: testStoreFetcher)
        #expect(resolvedDictionary.node != nil)
        #expect(resolvedDictionary.node!.count == 2)

        #expect(resolvedDictionary.node!.children["F"] != nil)
        #expect(resolvedDictionary.node!.children["B"] != nil)

        let fooValue = try dictionary.get(key: "Foo")
        let barValue = try dictionary.get(key: "Bar")

        #expect(fooValue != nil)
        #expect(fooValue?.node?.val == 1)
        #expect(barValue != nil)
        #expect(barValue?.node?.val == 2)
    }

    @Test("MerkleDictionary basic resolve list")
    func testMerkleDictionaryResolveList() async throws {
        typealias BaseDictionaryType = MerkleDictionaryImpl<HeaderImpl<TestBaseStructure>>

        let baseStructure1 = TestBaseStructure(val: 1)
        let baseStructure2 = TestBaseStructure(val: 2)
        let baseHeader1 = try HeaderImpl(node: baseStructure1)
        let baseHeader2 = try HeaderImpl(node: baseStructure2)

        let emptyDictionary = BaseDictionaryType(children: [:], count: 0)
        let dictionary = try emptyDictionary
            .inserting(key: "Foo", value: baseHeader1)
            .inserting(key: "Far", value: baseHeader2)
            .inserting(key: "G", value: baseHeader1)
        let dictionaryHeader = try HeaderImpl(node: dictionary)
        let testStoreFetcher = TestStoreFetcher()
        try await dictionaryHeader.storeAsVolume(storer: testStoreFetcher)
        let newDictionaryHeader = HeaderImpl<BaseDictionaryType>(rawCID: dictionaryHeader.rawCID)
        let resolvedDictionary = try await newDictionaryHeader.resolve(paths: [["F"]: .list], fetcher: testStoreFetcher)
        #expect(resolvedDictionary.node != nil)
        #expect(resolvedDictionary.node!.count == 3)

        let fooValue = try resolvedDictionary.node!.get(key: "Foo")
        let farValue = try resolvedDictionary.node!.get(key: "Far")
        let gValue = try? resolvedDictionary.node!.get(key: "G")
        #expect(gValue == nil)

        #expect(fooValue != nil)
        #expect(fooValue!.node == nil)
        #expect(farValue != nil)
        #expect(farValue!.node == nil)

        let originalFooValue = try dictionary.get(key: "Foo")
        let originalFarValue = try dictionary.get(key: "Far")
        let originalGValue = try dictionary.get(key: "G")

        #expect(originalFooValue?.node?.val == 1)
        #expect(originalFarValue?.node?.val == 2)
        #expect(originalGValue?.node?.val == 1)
    }

    @Test("MerkleDictionary nested dictionary resolve")
    func testMerkleDictionaryNestedDictionaryResolve() async throws {
        typealias BaseDictionaryType = MerkleDictionaryImpl<HeaderImpl<TestBaseStructure>>
        typealias NestedDictionaryType = MerkleDictionaryImpl<HeaderImpl<BaseDictionaryType>>

        let baseStructure1 = TestBaseStructure(val: 10)
        let baseStructure2 = TestBaseStructure(val: 20)
        let baseHeader1 = try HeaderImpl(node: baseStructure1)
        let baseHeader2 = try HeaderImpl(node: baseStructure2)

        let emptyBaseDictionary = BaseDictionaryType(children: [:], count: 0)
        let innerDictionary1 = try emptyBaseDictionary.inserting(key: "item1", value: baseHeader1)
        let innerDictionary2 = try emptyBaseDictionary.inserting(key: "item2", value: baseHeader2)

        let innerDictionaryHeader1 = try HeaderImpl(node: innerDictionary1)
        let innerDictionaryHeader2 = try HeaderImpl(node: innerDictionary2)

        let emptyNestedDictionary = NestedDictionaryType(children: [:], count: 0)
        let outerDictionary = try emptyNestedDictionary
            .inserting(key: "level1", value: innerDictionaryHeader1)
            .inserting(key: "level2", value: innerDictionaryHeader2)
        let outerDictionaryHeader = try HeaderImpl(node: outerDictionary)

        let testStoreFetcher = TestStoreFetcher()
        try await outerDictionaryHeader.storeAsVolume(storer: testStoreFetcher)

        let newOuterDictionaryHeader = HeaderImpl<NestedDictionaryType>(rawCID: outerDictionaryHeader.rawCID)
        let resolvedDictionary = try await newOuterDictionaryHeader.resolve(paths: [["level1", "item1"]: .targeted], fetcher: testStoreFetcher)

        #expect(resolvedDictionary.node != nil)
        #expect(resolvedDictionary.node!.count == 2)

        let level1Value = try outerDictionary.get(key: "level1")
        #expect(level1Value != nil)

        let nestedItem = try level1Value!.node!.get(key: "item1")
        #expect(nestedItem != nil)
        #expect(nestedItem!.node!.val == 10)

        let level2Value = try outerDictionary.get(key: "level2")
        #expect(level2Value != nil)

        let nestedItem2 = try level2Value!.node!.get(key: "item2")
        #expect(nestedItem2 != nil)
        #expect(nestedItem2!.node!.val == 20)
    }

    @Test("MerkleDictionary multiple path resolve")
    func testMerkleDictionaryMultiplePathResolve() async throws {
        typealias BaseDictionaryType = MerkleDictionaryImpl<HeaderImpl<TestBaseStructure>>

        let baseStructure1 = TestBaseStructure(val: 100)
        let baseStructure2 = TestBaseStructure(val: 200)
        let baseStructure3 = TestBaseStructure(val: 300)
        let baseStructure4 = TestBaseStructure(val: 400)

        let baseHeader1 = try HeaderImpl(node: baseStructure1)
        let baseHeader2 = try HeaderImpl(node: baseStructure2)
        let baseHeader3 = try HeaderImpl(node: baseStructure3)
        let baseHeader4 = try HeaderImpl(node: baseStructure4)

        let emptyDictionary = BaseDictionaryType(children: [:], count: 0)
        let dictionary = try emptyDictionary
            .inserting(key: "Alpha", value: baseHeader1)
            .inserting(key: "Beta", value: baseHeader2)
            .inserting(key: "Charlie", value: baseHeader3)
            .inserting(key: "Delta", value: baseHeader4)
        let dictionaryHeader = try HeaderImpl(node: dictionary)

        let testStoreFetcher = TestStoreFetcher()
        try await dictionaryHeader.storeAsVolume(storer: testStoreFetcher)

        let newDictionaryHeader = HeaderImpl<BaseDictionaryType>(rawCID: dictionaryHeader.rawCID)
        let resolvedDictionary = try await newDictionaryHeader.resolve(paths: [
            ["Alpha"]: .targeted,
            ["Beta"]: .targeted
        ], fetcher: testStoreFetcher)

        #expect(resolvedDictionary.node != nil)
        #expect(resolvedDictionary.node!.count == 4)

        let alphaValueResolved = try resolvedDictionary.node!.get(key: "Alpha")
        let betaValueResolved = try resolvedDictionary.node!.get(key: "Beta")

        #expect(alphaValueResolved != nil)
        #expect(alphaValueResolved?.node?.val == 100)
        #expect(betaValueResolved != nil)
        #expect(betaValueResolved?.node?.val == 200)

        let alphaValue = try dictionary.get(key: "Alpha")
        let betaValue = try dictionary.get(key: "Beta")
        let charlieValue = try dictionary.get(key: "Charlie")
        let deltaValue = try dictionary.get(key: "Delta")

        #expect(alphaValue?.node?.val == 100)
        #expect(betaValue?.node?.val == 200)
        #expect(charlieValue?.node?.val == 300)
        #expect(deltaValue?.node?.val == 400)
    }

    @Test("MerkleDictionary recursive resolve")
    func testMerkleDictionaryRecursiveResolve() async throws {
        typealias BaseDictionaryType = MerkleDictionaryImpl<HeaderImpl<TestBaseStructure>>

        let baseStructure1 = TestBaseStructure(val: 1)
        let baseStructure2 = TestBaseStructure(val: 2)
        let baseHeader1 = try HeaderImpl(node: baseStructure1)
        let baseHeader2 = try HeaderImpl(node: baseStructure2)

        let emptyDictionary = BaseDictionaryType(children: [:], count: 0)
        let dictionary = try emptyDictionary
            .inserting(key: "Test1", value: baseHeader1)
            .inserting(key: "User2", value: baseHeader2)
        let dictionaryHeader = try HeaderImpl(node: dictionary)

        let testStoreFetcher = TestStoreFetcher()
        try await dictionaryHeader.storeAsVolume(storer: testStoreFetcher)

        let newDictionaryHeader = HeaderImpl<BaseDictionaryType>(rawCID: dictionaryHeader.rawCID)
        let resolvedDictionary = try await newDictionaryHeader.resolveRecursive(fetcher: testStoreFetcher)

        #expect(resolvedDictionary.node != nil)
        #expect(resolvedDictionary.node!.count == 2)

        let test1Value = try resolvedDictionary.node!.get(key: "Test1")
        let user2Value = try resolvedDictionary.node!.get(key: "User2")

        #expect(test1Value != nil)
        #expect(test1Value?.node?.val == 1)
        #expect(user2Value != nil)
        #expect(user2Value?.node?.val == 2)
    }

    @Test("MerkleDictionary deep nesting resolve")
    func testMerkleDictionaryDeepNestingResolve() async throws {
        typealias Level1Type = MerkleDictionaryImpl<HeaderImpl<TestBaseStructure>>
        typealias Level2Type = MerkleDictionaryImpl<HeaderImpl<Level1Type>>
        typealias Level3Type = MerkleDictionaryImpl<HeaderImpl<Level2Type>>
        typealias Level4Type = MerkleDictionaryImpl<HeaderImpl<Level3Type>>

        let baseStructure = TestBaseStructure(val: 999)
        let baseHeader = try HeaderImpl(node: baseStructure)
        let emptyLevel1 = Level1Type(children: [:], count: 0)
        let level1Dict = try emptyLevel1.inserting(key: "deep", value: baseHeader)
        let level1Header = try HeaderImpl(node: level1Dict)

        let emptyLevel2 = Level2Type(children: [:], count: 0)
        let level2Dict = try emptyLevel2.inserting(key: "level2", value: level1Header)
        let level2Header = try HeaderImpl(node: level2Dict)

        let emptyLevel3 = Level3Type(children: [:], count: 0)
        let level3Dict = try emptyLevel3.inserting(key: "level3", value: level2Header)
        let level3Header = try HeaderImpl(node: level3Dict)

        let emptyLevel4 = Level4Type(children: [:], count: 0)
        let level4Dict = try emptyLevel4.inserting(key: "root", value: level3Header)
        let level4Header = try HeaderImpl(node: level4Dict)

        let testStoreFetcher = TestStoreFetcher()
        try await level4Header.storeAsVolume(storer: testStoreFetcher)

        let newLevel4Header = HeaderImpl<Level4Type>(rawCID: level4Header.rawCID)
        let resolvedDictionary = try await newLevel4Header.resolve(paths: [["root", "level3", "level2", "deep"]: .targeted], fetcher: testStoreFetcher)

        #expect(resolvedDictionary.node != nil)

        let rootValue = try resolvedDictionary.node!.get(key: "root")
        #expect(rootValue != nil)

        let nestedLevel3 = try rootValue!.node!.get(key: "level3")
        #expect(nestedLevel3 != nil)

        let nestedLevel2 = try nestedLevel3!.node!.get(key: "level2")
        #expect(nestedLevel2 != nil)

        let deepValue = try nestedLevel2!.node!.get(key: "deep")
        #expect(deepValue != nil)
        #expect(deepValue?.node?.val == 999)
    }

    @Test("MerkleDictionary large scale resolve")
    func testMerkleDictionaryLargeScaleResolve() async throws {
        typealias BaseDictionaryType = MerkleDictionaryImpl<HeaderImpl<TestBaseStructure>>

        let totalNodes = 10
        let characters = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]

        var dictionary = BaseDictionaryType(children: [:], count: 0)
        for i in 0..<totalNodes {
            let baseStructure = TestBaseStructure(val: i * 10)
            let baseHeader = try HeaderImpl(node: baseStructure)
            dictionary = try dictionary.inserting(key: "\(characters[i])node\(i)", value: baseHeader)
        }

        let dictionaryHeader = try HeaderImpl(node: dictionary)

        let testStoreFetcher = TestStoreFetcher()
        try await dictionaryHeader.storeAsVolume(storer: testStoreFetcher)

        let newDictionaryHeader = HeaderImpl<BaseDictionaryType>(rawCID: dictionaryHeader.rawCID)
        let resolvedDictionary = try await newDictionaryHeader.resolve(paths: [
            ["5node5"]: .targeted,
            ["7node7"]: .targeted
        ], fetcher: testStoreFetcher)

        #expect(resolvedDictionary.node != nil)
        #expect(resolvedDictionary.node!.count == totalNodes)

        let resolvedValue5 = try resolvedDictionary.node!.get(key: "5node5")
        let resolvedValue7 = try resolvedDictionary.node!.get(key: "7node7")

        #expect(resolvedValue5 != nil)
        #expect(resolvedValue5?.node?.val == 50)
        #expect(resolvedValue7 != nil)
        #expect(resolvedValue7?.node?.val == 70)

        let unresolvedValue1 = try? resolvedDictionary.node!.get(key: "1node1")
        let unresolvedValue3 = try? resolvedDictionary.node!.get(key: "3node3")

        #expect(unresolvedValue1 == nil || unresolvedValue1?.node?.val == 10)
        #expect(unresolvedValue3 == nil || unresolvedValue3?.node?.val == 30)

        #expect(resolvedDictionary.node!.children["1"] != nil)
        #expect(resolvedDictionary.node!.children["3"] != nil)
    }

    @Test("MerkleDictionary list resolve")
    func testMerkleDictionaryListResolve() async throws {
        typealias HigherDictionaryType = MerkleDictionaryImpl<HeaderImpl<BaseDictionaryType>>
        typealias BaseDictionaryType = MerkleDictionaryImpl<HeaderImpl<TestBaseStructure>>

        let baseStructure1 = TestBaseStructure(val: 1)
        let baseStructure2 = TestBaseStructure(val: 2)
        let baseHeader1 = try HeaderImpl(node: baseStructure1)
        let baseHeader2 = try HeaderImpl(node: baseStructure2)

        let emptyBaseDictionary = BaseDictionaryType(children: [:], count: 0)
        let dictionary = try emptyBaseDictionary
            .inserting(key: "Foo", value: baseHeader1)
            .inserting(key: "Bar", value: baseHeader2)
        let dictionaryHeader = try HeaderImpl(node: dictionary)

        let emptyHigherDictionary = HigherDictionaryType(children: [:], count: 0)
        let higherDictionary = try emptyHigherDictionary
            .inserting(key: "Foo", value: dictionaryHeader)
            .inserting(key: "Bar", value: dictionaryHeader)
        let higherDictionaryHeader = try HeaderImpl(node: higherDictionary)

        let testStoreFetcher = TestStoreFetcher()
        try await higherDictionaryHeader.storeAsVolume(storer: testStoreFetcher)
        let newDictionaryHeader = HeaderImpl<HigherDictionaryType>(rawCID: higherDictionaryHeader.rawCID)
        var resolutionPaths = ArrayTrie<ResolutionStrategy>()
        resolutionPaths.set(["Fo"], value: ResolutionStrategy.list)
        let resolvedDictionary = try await newDictionaryHeader.resolve(paths: resolutionPaths, fetcher: testStoreFetcher)
        #expect(resolvedDictionary.node != nil)
        #expect(resolvedDictionary.node!.count == 2)
        let resultingValue = try resolvedDictionary.node!.get(key: "Foo")
        #expect(resultingValue != nil)
        #expect(resultingValue!.node == nil)
    }

    @Test("MerkleDictionary deep list resolve")
    func testMerkleDictionaryDeepListResolve() async throws {
        typealias HigherDictionaryType = MerkleDictionaryImpl<HeaderImpl<BaseDictionaryType>>
        typealias BaseDictionaryType = MerkleDictionaryImpl<HeaderImpl<TestBaseStructure>>

        let baseStructure1 = TestBaseStructure(val: 1)
        let baseStructure2 = TestBaseStructure(val: 2)
        let baseHeader1 = try HeaderImpl(node: baseStructure1)
        let baseHeader2 = try HeaderImpl(node: baseStructure2)

        let emptyBaseDictionary = BaseDictionaryType(children: [:], count: 0)
        let dictionary = try emptyBaseDictionary
            .inserting(key: "Foo", value: baseHeader1)
            .inserting(key: "Bar", value: baseHeader2)
            .inserting(key: "Baz", value: baseHeader2)
        let dictionaryHeader = try HeaderImpl(node: dictionary)

        let emptyHigherDictionary = HigherDictionaryType(children: [:], count: 0)
        let higherDictionary = try emptyHigherDictionary
            .inserting(key: "Foo", value: dictionaryHeader)
            .inserting(key: "Bar", value: dictionaryHeader)
        let higherDictionaryHeader = try HeaderImpl(node: higherDictionary)

        let testStoreFetcher = TestStoreFetcher()
        try await higherDictionaryHeader.storeAsVolume(storer: testStoreFetcher)
        let newDictionaryHeader = HeaderImpl<HigherDictionaryType>(rawCID: higherDictionaryHeader.rawCID)
        var resolutionPaths = ArrayTrie<ResolutionStrategy>()
        resolutionPaths.set(["Foo", "Foo"], value: ResolutionStrategy.targeted)
        resolutionPaths.set(["Fo", "Baz"], value: ResolutionStrategy.targeted)
        resolutionPaths.set(["Fo"], value: ResolutionStrategy.list)
        let resolvedDictionary = try await newDictionaryHeader.resolve(paths: resolutionPaths, fetcher: testStoreFetcher)
        #expect(resolvedDictionary.node != nil)
        #expect(resolvedDictionary.node!.count == 2)

        let fooValue = try resolvedDictionary.node!.get(key: "Foo")
        let barValue = try? resolvedDictionary.node!.get(key: "Bar")

        #expect(fooValue != nil)
        #expect(fooValue!.node != nil)
        #expect(barValue == nil)

        let innerFoo = try fooValue!.node?.get(key: "Foo")
        let innerBaz = try fooValue!.node?.get(key: "Baz")

        #expect(innerFoo != nil)
        #expect(innerBaz != nil)
        let innerBar = try? fooValue!.node?.get(key: "Bar")
        #expect(innerBar == nil)

        let originalFooValue = try higherDictionary.get(key: "Foo")
        let originalBarValue = try higherDictionary.get(key: "Bar")

        #expect(originalFooValue != nil)
        #expect(originalBarValue != nil)

        let innerFooValue = try originalFooValue!.node!.get(key: "Foo")
        let innerBarValue = try originalFooValue!.node!.get(key: "Bar")

        #expect(innerFooValue?.node?.val == 1)
        #expect(innerBarValue?.node?.val == 2)
    }

    @Test("MerkleDictionary insert single item")
    func testMerkleDictionaryInsertSingle() throws {
        typealias BaseDictionaryType = MerkleDictionaryImpl<HeaderImpl<TestBaseStructure>>

        let baseStructure = TestBaseStructure(val: 42)
        let baseHeader = try HeaderImpl(node: baseStructure)
        let emptyDictionary = BaseDictionaryType(children: [:], count: 0)

        let dictionary = try emptyDictionary.inserting(key: "key1", value: baseHeader)

        #expect(dictionary.count == 1)
        #expect(dictionary.children.count == 1)
        #expect(dictionary.children["k"] != nil)
        #expect(dictionary.get(property: "k") != nil)
        #expect(dictionary.properties() == Set(["k"]))

        let retrievedValue = try dictionary.get(key: "key1")
        #expect(retrievedValue != nil)
        #expect(retrievedValue?.node?.val == 42)
    }

    @Test("MerkleDictionary insert multiple items")
    func testMerkleDictionaryInsertMultiple() throws {
        typealias BaseDictionaryType = MerkleDictionaryImpl<HeaderImpl<TestBaseStructure>>

        let baseStructure1 = TestBaseStructure(val: 1)
        let baseStructure2 = TestBaseStructure(val: 2)
        let baseStructure3 = TestBaseStructure(val: 3)

        let baseHeader1 = try HeaderImpl(node: baseStructure1)
        let baseHeader2 = try HeaderImpl(node: baseStructure2)
        let baseHeader3 = try HeaderImpl(node: baseStructure3)

        let emptyDictionary = BaseDictionaryType(children: [:], count: 0)
        let dictionary = try emptyDictionary
            .inserting(key: "alpha", value: baseHeader1)
            .inserting(key: "beta", value: baseHeader2)
            .inserting(key: "gamma", value: baseHeader3)

        #expect(dictionary.count == 3)
        #expect(dictionary.children.count == 3)
        #expect(dictionary.get(property: "a") != nil)
        #expect(dictionary.get(property: "b") != nil)
        #expect(dictionary.get(property: "g") != nil)
        #expect(dictionary.properties() == Set(["a", "b", "g"]))

        let retrievedValue1 = try dictionary.get(key: "alpha")
        let retrievedValue2 = try dictionary.get(key: "beta")
        let retrievedValue3 = try dictionary.get(key: "gamma")

        #expect(retrievedValue1?.node?.val == 1)
        #expect(retrievedValue2?.node?.val == 2)
        #expect(retrievedValue3?.node?.val == 3)
    }

    @Test("MerkleDictionary get operations")
    func testMerkleDictionaryGetOperations() throws {
        typealias BaseDictionaryType = MerkleDictionaryImpl<HeaderImpl<TestBaseStructure>>

        let baseStructure1 = TestBaseStructure(val: 100)
        let baseStructure2 = TestBaseStructure(val: 200)
        let baseHeader1 = try HeaderImpl(node: baseStructure1)
        let baseHeader2 = try HeaderImpl(node: baseStructure2)

        let emptyDictionary = BaseDictionaryType(children: [:], count: 0)
        let dictionary = try emptyDictionary
            .inserting(key: "first", value: baseHeader1)
            .inserting(key: "second", value: baseHeader2)

        let firstValue = try dictionary.get(key: "first")
        let secondValue = try dictionary.get(key: "second")
        let nonExistentValue = try dictionary.get(key: "nonexistent")

        #expect(firstValue != nil)
        #expect(firstValue?.node?.val == 100)
        #expect(secondValue != nil)
        #expect(secondValue?.node?.val == 200)
        #expect(nonExistentValue == nil)

        #expect(dictionary.get(property: "f") != nil)
        #expect(dictionary.get(property: "s") != nil)
        #expect(dictionary.get(property: "x") == nil)

        #expect(dictionary.properties().contains("f"))
        #expect(dictionary.properties().contains("s"))
        #expect(!dictionary.properties().contains("x"))
    }

    @Test("MerkleDictionary mutate existing items")
    func testMerkleDictionaryMutateItems() throws {
        typealias BaseDictionaryType = MerkleDictionaryImpl<HeaderImpl<TestBaseStructure>>

        let originalStructure = TestBaseStructure(val: 10)
        let originalHeader = try HeaderImpl(node: originalStructure)

        let emptyDictionary = BaseDictionaryType(children: [:], count: 0)
        let originalDictionary = try emptyDictionary.inserting(key: "item", value: originalHeader)

        let updatedStructure = TestBaseStructure(val: 20)
        let updatedHeader = try HeaderImpl(node: updatedStructure)
        let mutatedDictionary = try originalDictionary.mutating(key: ArraySlice("item"), value: updatedHeader)

        #expect(mutatedDictionary.count == 1)
        #expect(originalDictionary.count == 1)

        let originalValue = try originalDictionary.get(key: "item")
        let mutatedValue = try mutatedDictionary.get(key: "item")

        #expect(originalValue?.node?.val == 10)
        #expect(mutatedValue?.node?.val == 20)
    }

    @Test("MerkleDictionary set multiple properties")
    func testMerkleDictionarySetMultipleProperties() throws {
        typealias BaseDictionaryType = MerkleDictionaryImpl<HeaderImpl<TestBaseStructure>>

        let structure1 = TestBaseStructure(val: 1)
        let structure2 = TestBaseStructure(val: 2)
        let header1 = try HeaderImpl(node: structure1)
        let header2 = try HeaderImpl(node: structure2)

        let emptyDictionary = BaseDictionaryType(children: [:], count: 0)
        let originalDictionary = try emptyDictionary
            .inserting(key: "old1", value: header1)
            .inserting(key: "old2", value: header2)

        let newStructure1 = TestBaseStructure(val: 10)
        let newStructure2 = TestBaseStructure(val: 20)
        let newHeader1 = try HeaderImpl(node: newStructure1)
        let newHeader2 = try HeaderImpl(node: newStructure2)

        let updatedDictionary = try originalDictionary
            .mutating(key: ArraySlice("old1"), value: newHeader1)
            .mutating(key: ArraySlice("old2"), value: newHeader2)

        #expect(updatedDictionary.count == 2)
        #expect(originalDictionary.count == 2)

        let originalValue1 = try originalDictionary.get(key: "old1")
        let originalValue2 = try originalDictionary.get(key: "old2")

        #expect(originalValue1?.node?.val == 1)
        #expect(originalValue2?.node?.val == 2)

        let updatedValue1 = try updatedDictionary.get(key: "old1")
        let updatedValue2 = try updatedDictionary.get(key: "old2")

        #expect(updatedValue1?.node?.val == 10)
        #expect(updatedValue2?.node?.val == 20)
    }

    @Test("MerkleDictionary remove items")
    func testMerkleDictionaryRemoveItems() throws {
        typealias BaseDictionaryType = MerkleDictionaryImpl<HeaderImpl<TestBaseStructure>>

        let structure1 = TestBaseStructure(val: 1)
        let structure2 = TestBaseStructure(val: 2)
        let structure3 = TestBaseStructure(val: 3)

        let header1 = try HeaderImpl(node: structure1)
        let header2 = try HeaderImpl(node: structure2)
        let header3 = try HeaderImpl(node: structure3)

        let emptyDictionary = BaseDictionaryType(children: [:], count: 0)
        let originalDictionary = try emptyDictionary
            .inserting(key: "keep", value: header1)
            .inserting(key: "remove", value: header2)
            .inserting(key: "stuff", value: header3)

        let reducedDictionary = try originalDictionary
            .deleting(key: "remove")
            .deleting(key: "stuff")

        #expect(originalDictionary.count == 3)
        #expect(originalDictionary.properties() == Set(["k", "r", "s"]))

        #expect(reducedDictionary.count == 1)
        #expect(reducedDictionary.properties() == Set(["k"]))
        #expect(reducedDictionary.get(property: "k") != nil)
        #expect(reducedDictionary.get(property: "r") == nil)
        #expect(reducedDictionary.get(property: "s") == nil)

        let keptValue = try reducedDictionary.get(key: "keep")
        #expect(keptValue?.node?.val == 1)

        let deletedValue1 = try reducedDictionary.get(key: "remove")
        let deletedValue2 = try reducedDictionary.get(key: "stuff")
        #expect(deletedValue1 == nil)
        #expect(deletedValue2 == nil)
    }

    @Test("MerkleDictionary empty dictionary")
    func testMerkleDictionaryEmpty() throws {
        typealias BaseDictionaryType = MerkleDictionaryImpl<HeaderImpl<TestBaseStructure>>

        let emptyDictionary = BaseDictionaryType(children: [:], count: 0)

        #expect(emptyDictionary.count == 0)
        #expect(emptyDictionary.children.isEmpty)
        #expect(emptyDictionary.properties().isEmpty)
        #expect(emptyDictionary.get(property: "x") == nil)
    }

    @Test("MerkleDictionary complex mutations")
    func testMerkleDictionaryComplexMutations() throws {
        typealias BaseDictionaryType = MerkleDictionaryImpl<HeaderImpl<TestBaseStructure>>

        let emptyDictionary = BaseDictionaryType(children: [:], count: 0)

        let structure1 = TestBaseStructure(val: 100)
        let structure2 = TestBaseStructure(val: 200)
        let structure3 = TestBaseStructure(val: 300)
        let header1 = try HeaderImpl(node: structure1)
        let header2 = try HeaderImpl(node: structure2)
        let header3 = try HeaderImpl(node: structure3)

        let dictionaryWithOne = try emptyDictionary.inserting(key: "first", value: header1)

        let dictionaryWithTwo = try dictionaryWithOne.inserting(key: "second", value: header2)

        let finalDictionary = try dictionaryWithTwo.mutating(key: ArraySlice("first"), value: header3)

        #expect(emptyDictionary.count == 0)
        #expect(dictionaryWithOne.count == 1)
        #expect(dictionaryWithTwo.count == 2)
        #expect(finalDictionary.count == 2)

        #expect(emptyDictionary.properties().isEmpty)
        #expect(dictionaryWithOne.properties() == Set(["f"]))
        #expect(dictionaryWithTwo.properties() == Set(["f", "s"]))
        #expect(finalDictionary.properties() == Set(["f", "s"]))

        let firstValue = try finalDictionary.get(key: "first")
        let secondValue = try finalDictionary.get(key: "second")

        #expect(firstValue?.node?.val == 300)
        #expect(secondValue?.node?.val == 200)

        let originalFirstValue = try dictionaryWithOne.get(key: "first")
        #expect(originalFirstValue?.node?.val == 100)
    }

    @Test("MerkleDictionary partial path matching")
    func testMerkleDictionaryPartialPathMatching() async throws {
        typealias BaseDictionaryType = MerkleDictionaryImpl<HeaderImpl<TestBaseStructure>>

        let baseStructure1 = TestBaseStructure(val: 111)
        let baseStructure2 = TestBaseStructure(val: 222)
        let baseStructure3 = TestBaseStructure(val: 333)
        let baseStructure4 = TestBaseStructure(val: 444)

        let baseHeader1 = try HeaderImpl(node: baseStructure1)
        let baseHeader2 = try HeaderImpl(node: baseStructure2)
        let baseHeader3 = try HeaderImpl(node: baseStructure3)
        let baseHeader4 = try HeaderImpl(node: baseStructure4)

        let emptyDictionary = BaseDictionaryType(children: [:], count: 0)
        let dictionary = try emptyDictionary
            .inserting(key: "apple", value: baseHeader1)
            .inserting(key: "application", value: baseHeader2)
            .inserting(key: "banana", value: baseHeader3)
            .inserting(key: "cherry", value: baseHeader4)
        let dictionaryHeader = try HeaderImpl(node: dictionary)

        let testStoreFetcher = TestStoreFetcher()
        try await dictionaryHeader.storeAsVolume(storer: testStoreFetcher)

        let newDictionaryHeader1 = HeaderImpl<BaseDictionaryType>(rawCID: dictionaryHeader.rawCID)
        let resolvedDictionary1 = try await newDictionaryHeader1.resolve(paths: [["apple"]: .targeted], fetcher: testStoreFetcher)

        #expect(resolvedDictionary1.node != nil)
        #expect(resolvedDictionary1.node!.count == 4)

        let appleValue = try dictionary.get(key: "apple")
        #expect(appleValue?.node?.val == 111)

        let newDictionaryHeader2 = HeaderImpl<BaseDictionaryType>(rawCID: dictionaryHeader.rawCID)
        let resolvedDictionary2 = try await newDictionaryHeader2.resolve(paths: [["a"]: .list], fetcher: testStoreFetcher)

        #expect(resolvedDictionary2.node != nil)
        #expect(resolvedDictionary2.node!.count == 4)

        let appleValue2 = try dictionary.get(key: "apple")
        let applicationValue = try dictionary.get(key: "application")
        let bananaValue = try dictionary.get(key: "banana")
        let cherryValue = try dictionary.get(key: "cherry")

        #expect(appleValue2?.node?.val == 111)
        #expect(applicationValue?.node?.val == 222)
        #expect(bananaValue?.node?.val == 333)
        #expect(cherryValue?.node?.val == 444)

        let newDictionaryHeader3 = HeaderImpl<BaseDictionaryType>(rawCID: dictionaryHeader.rawCID)
        let resolvedDictionary3 = try await newDictionaryHeader3.resolve(paths: [
            ["a"]: .list,
            ["banana"]: .targeted
        ], fetcher: testStoreFetcher)

        #expect(resolvedDictionary3.node != nil)
        #expect(resolvedDictionary3.node!.count == 4)

        let resolvedApple3 = try resolvedDictionary3.node!.get(key: "apple")
        let resolvedBanana3 = try resolvedDictionary3.node!.get(key: "banana")

        #expect(resolvedApple3 != nil)
        #expect(resolvedApple3!.node == nil)
        #expect(resolvedBanana3 != nil)
        #expect(resolvedBanana3?.node?.val == 333)

        let newDictionaryHeader4 = HeaderImpl<BaseDictionaryType>(rawCID: dictionaryHeader.rawCID)
        let resolvedDictionary4 = try await newDictionaryHeader4.resolve(paths: [["xyz"]: .targeted], fetcher: testStoreFetcher)

        #expect(resolvedDictionary4.node != nil)
        #expect(resolvedDictionary4.node!.count == 4)

        let nonExistentValue = try dictionary.get(key: "xyz")
        #expect(nonExistentValue == nil)

        #expect(try dictionary.get(key: "apple")?.node?.val == 111)
        #expect(try dictionary.get(key: "application")?.node?.val == 222)
        #expect(try dictionary.get(key: "banana")?.node?.val == 333)
        #expect(try dictionary.get(key: "cherry")?.node?.val == 444)
    }

    @Test("MerkleDictionary resolveList method")
    func testMerkleDictionaryResolveListMethod() async throws {
        typealias BaseDictionaryType = MerkleDictionaryImpl<HeaderImpl<TestBaseStructure>>

        let baseStructure1 = TestBaseStructure(val: 1)
        let baseStructure2 = TestBaseStructure(val: 2)
        let baseStructure3 = TestBaseStructure(val: 3)
        let baseHeader1 = try HeaderImpl(node: baseStructure1)
        let baseHeader2 = try HeaderImpl(node: baseStructure2)
        let baseHeader3 = try HeaderImpl(node: baseStructure3)

        let emptyDictionary = BaseDictionaryType(children: [:], count: 0)
        let dictionary = try emptyDictionary
            .inserting(key: "Alpha", value: baseHeader1)
            .inserting(key: "Beta", value: baseHeader2)
            .inserting(key: "Gamma", value: baseHeader3)
        let dictionaryHeader = try HeaderImpl(node: dictionary)

        let testStoreFetcher = TestStoreFetcher()
        try await dictionaryHeader.storeAsVolume(storer: testStoreFetcher)

        let newDictionaryHeader = HeaderImpl<BaseDictionaryType>(rawCID: dictionaryHeader.rawCID)
        let resolvedDictionaryNode = try await newDictionaryHeader.resolve(fetcher: testStoreFetcher).node!.resolveList(fetcher: testStoreFetcher)
        let resolvedDictionary = try HeaderImpl<BaseDictionaryType>(node: resolvedDictionaryNode)

        #expect(resolvedDictionary.node != nil)
        #expect(resolvedDictionary.node!.count == 3)

        let alphaValue = try resolvedDictionary.node!.get(key: "Alpha")
        let betaValue = try resolvedDictionary.node!.get(key: "Beta")
        let gammaValue = try resolvedDictionary.node!.get(key: "Gamma")

        #expect(alphaValue != nil)
        #expect(alphaValue!.node == nil)
        #expect(betaValue != nil)
        #expect(betaValue!.node == nil)
        #expect(gammaValue != nil)
        #expect(gammaValue!.node == nil)

        let originalAlphaValue = try dictionary.get(key: "Alpha")
        let originalBetaValue = try dictionary.get(key: "Beta")
        let originalGammaValue = try dictionary.get(key: "Gamma")

        #expect(originalAlphaValue?.node?.val == 1)
        #expect(originalBetaValue?.node?.val == 2)
        #expect(originalGammaValue?.node?.val == 3)
    }

    // MARK: - BugFix: resolveList tests

    @Test("resolveList with string values does not crash")
    func testResolveListWithStringValuesDoesNotCrash() async throws {
        typealias DictType = MerkleDictionaryImpl<String>

        let dict = try DictType(children: [:], count: 0)
            .inserting(key: "Foo", value: "bar")
            .inserting(key: "Far", value: "baz")

        let header = try HeaderImpl(node: dict)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let unresolved = HeaderImpl<DictType>(rawCID: header.rawCID)
        let resolved = try await unresolved.resolve(paths: [["F"]: .list], fetcher: fetcher)
        #expect(resolved.node != nil)
        #expect(resolved.node!.count == 2)
    }

    @Test("resolveList with Address values resolves correctly")
    func testResolveListWithAddressValues() async throws {
        typealias BaseDictionaryType = MerkleDictionaryImpl<HeaderImpl<TestScalar>>

        let scalar1 = TestScalar(val: 1)
        let scalar2 = TestScalar(val: 2)
        let header1 = try HeaderImpl(node: scalar1)
        let header2 = try HeaderImpl(node: scalar2)

        let emptyDict = BaseDictionaryType(children: [:], count: 0)
        let dict = try emptyDict
            .inserting(key: "Foo", value: header1)
            .inserting(key: "Far", value: header2)

        let dictHeader = try HeaderImpl(node: dict)
        let fetcher = TestStoreFetcher()
        try await dictHeader.storeAsVolume(storer: fetcher)

        let unresolved = HeaderImpl<BaseDictionaryType>(rawCID: dictHeader.rawCID)
        let resolved = try await unresolved.resolve(paths: [["F"]: .list], fetcher: fetcher)
        #expect(resolved.node != nil)
        #expect(resolved.node!.count == 2)

        let fooValue = try resolved.node!.get(key: "Foo")
        #expect(fooValue != nil)
        #expect(fooValue!.node == nil)
    }

    // MARK: - Resolve operations regression

    @Test("Resolve operations still work after fixes")
    func testResolveOperationsRegression() async throws {
        typealias BaseDictionaryType = MerkleDictionaryImpl<HeaderImpl<TestScalar>>

        let scalar1 = TestScalar(val: 1)
        let header1 = try HeaderImpl(node: scalar1)

        let dict = try BaseDictionaryType(children: [:], count: 0)
            .inserting(key: "Foo", value: header1)
        let dictHeader = try HeaderImpl(node: dict)
        let fetcher = TestStoreFetcher()
        try await dictHeader.storeAsVolume(storer: fetcher)

        let unresolved = HeaderImpl<BaseDictionaryType>(rawCID: dictHeader.rawCID)
        let resolved = try await unresolved.resolveRecursive(fetcher: fetcher)
        #expect(resolved.node != nil)
        let fooValue = try resolved.node!.get(key: "Foo")
        #expect(fooValue?.node?.val == 1)
    }
}

// MARK: - Concurrent Resolution

@Suite("Concurrent Resolution")
struct ConcurrentResolutionTests {

    @Test("Resolve operations are thread-safe")
    func testResolveThreadSafety() async throws {
        var dictionary = MerkleDictionaryImpl<String>(children: [:], count: 0)
        dictionary = try dictionary.inserting(key: "shared", value: "value")

        let fetcher = TestStoreFetcher()

        var results: [MerkleDictionaryImpl<String>] = []
        for _ in 1...5 {
            var paths = ArrayTrie<ResolutionStrategy>()
            paths.set(["shared"], value: .targeted)
            let result = try await dictionary.resolve(paths: paths, fetcher: fetcher)
            results.append(result)
        }

        for result in results {
            #expect(try result.get(key: "shared") == "value")
        }
    }

    @Test("Concurrent resolution of many independent paths")
    func testConcurrentResolutionManyPaths() async throws {
        typealias DictType = MerkleDictionaryImpl<HeaderImpl<TestScalar>>

        var dict = DictType(children: [:], count: 0)
        for i in 0..<26 {
            let letter = String(Character(UnicodeScalar(65 + i)!))
            let key = "\(letter)item\(i)"
            dict = try dict.inserting(key: key, value: try HeaderImpl(node: TestScalar(val: i)))
        }
        #expect(dict.count == 26)

        let header = try HeaderImpl(node: dict)
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)

        let unresolved = HeaderImpl<DictType>(rawCID: header.rawCID)
        let resolved = try await unresolved.resolveRecursive(fetcher: fetcher)

        #expect(resolved.rawCID == header.rawCID)
        #expect(resolved.node!.count == 26)

        for i in 0..<26 {
            let letter = String(Character(UnicodeScalar(65 + i)!))
            let key = "\(letter)item\(i)"
            let val = try resolved.node!.get(key: key)
            #expect(val?.node?.val == i)
        }
    }
}

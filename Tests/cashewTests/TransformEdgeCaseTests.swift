import Testing
import Foundation
import ArrayTrie
@testable import cashew

/// Batches that once succeeded wrongly, or failed depending on what was
/// cached: each must be refused, or must give the from-scratch result whatever
/// the proof resolved.
@Suite("Transform Edge Cases")
struct TransformEdgeCaseTests {
    typealias Dict = MerkleDictionaryImpl<String>
    typealias LeafDict = MerkleDictionaryImpl<String>
    typealias OuterDict = MerkleDictionaryImpl<HeaderImpl<LeafDict>>

    private func dict(_ keys: [String]) throws -> Dict {
        try keys.reduce(Dict(children: [:], count: 0)) { try $0.inserting(key: $1, value: "v-\($1)") }
    }

    private func transforms(_ writes: [([String], Transform)]) -> ArrayTrie<Transform> {
        var trie = ArrayTrie<Transform>()
        for (path, transform) in writes { trie.set(path, value: transform) }
        return trie
    }

    @Test("Update of a value-less branch point is refused", arguments: [
        (["aba", "abba"], "ab"),
        (["baaa", "bbb"], "b"),
        (["b//b", "ba"], "b"),
    ])
    func testUpdateAtValuelessBranchPointIsRefused(keys: [String], key: String) throws {
        #expect(throws: TransformErrors.self) {
            _ = try dict(keys).transform(transforms: transforms([([key], .update("x"))]))
        }
    }

    @Test("Writes to the empty key are refused")
    func testEmptyKeyWritesAreRefused() throws {
        for write in [Transform.insert("x"), .update("x"), .delete] {
            #expect(throws: TransformErrors.self) {
                _ = try dict(["a"]).transform(transforms: transforms([([""], write)]))
            }
        }
    }

    @Test("A proof on the empty key is refused")
    func testEmptyKeyProofIsRefused() async throws {
        let header = try HeaderImpl(node: dict(["a"]))
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)
        var paths = ArrayTrie<SparseMerkleProof>()
        paths.set([""], value: .insertion)
        await #expect(throws: ProofErrors.self) {
            _ = try await HeaderImpl<Dict>(rawCID: header.rawCID).proof(paths: paths, fetcher: fetcher)
        }
    }

    // An existence proof beside a delete used to suppress the collapse
    // witness, so the transform failed on proof-only data but not on a fully
    // resolved trie.
    @Test("Existence beside a delete gives the same result from proof-only data", arguments: [
        (["ba", "bb"], "bb", "b"),
        (["abba", "abbb"], "abbb", "abbba"),
    ])
    func testExistenceBesideDeleteIsCacheIndependent(keys: [String], deleted: String, witnessed: String) async throws {
        let header = try HeaderImpl(node: dict(keys))
        let fetcher = TestStoreFetcher()
        try await header.storeAsVolume(storer: fetcher)
        var paths = ArrayTrie<SparseMerkleProof>()
        paths.set([deleted], value: .deletion)
        paths.set([witnessed], value: .existence)

        let proven = try await HeaderImpl<Dict>(rawCID: header.rawCID).proof(paths: paths, fetcher: fetcher)
        let result = try proven.transform(transforms: transforms([([deleted], .delete)]))!
        let expected = try HeaderImpl(node: dict(keys.filter { $0 != deleted }))
        #expect(result.rawCID == expected.rawCID)
    }

    private func leaf(_ value: String) throws -> HeaderImpl<LeafDict> {
        try HeaderImpl(node: LeafDict(children: [:], count: 0).inserting(key: "k", value: value))
    }

    @Test("A nested write beneath a missing key is refused")
    func testNestedWriteBeneathMissingKeyIsRefused() throws {
        let empty = OuterDict(children: [:], count: 0)
        #expect(throws: TransformErrors.self) {
            _ = try empty.transform(transforms: transforms([(["b", "x"], .insert("1"))]))
        }
        // "b" is a value-less branch point over "ba" and "bb".
        let branched = try empty.inserting(key: "ba", value: leaf("1")).inserting(key: "bb", value: leaf("2"))
        #expect(throws: TransformErrors.self) {
            _ = try branched.transform(transforms: transforms([(["b", "x"], .insert("1"))]))
        }
        // "b" would be a new split point above "bc".
        let single = try empty.inserting(key: "bc", value: leaf("1"))
        #expect(throws: TransformErrors.self) {
            _ = try single.transform(transforms: transforms([(["b", "x"], .insert("1"))]))
        }
    }

    @Test("A value write and a nested write at one key are refused as ambiguous")
    func testValueAndNestedWriteAtOneKeyAreRefused() throws {
        let outer = try OuterDict(children: [:], count: 0).inserting(key: "a", value: leaf("1"))
        #expect(throws: TransformErrors.self) {
            _ = try outer.transform(transforms: transforms([
                (["a"], .update(try leaf("2").description)),
                (["a", "y"], .insert("1")),
            ]))
        }
    }

    @Test("A nested write into an existing value still applies")
    func testNestedWriteIntoExistingValueApplies() throws {
        let outer = try OuterDict(children: [:], count: 0)
            .inserting(key: "a", value: leaf("1"))
            .inserting(key: "ab", value: leaf("2"))
        let result = try outer.transform(transforms: transforms([(["a", "y"], .insert("3"))]))!
        #expect(try result.get(key: "a")?.node?.get(key: "y") == "3")
        #expect(try result.get(key: "ab")?.node?.get(key: "k") == "2")
        #expect(result.count == 2)
    }
}

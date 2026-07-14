import Testing
import Foundation
@testable import cashew

@Suite("Owned-subtree walk")
struct OwnedSubtreeWalkTests {
    private struct Leaf: Scalar, Equatable {
        let value: String
    }

    private func resolvedDict(keyCount: Int) async throws -> VolumeImpl<MerkleDictionaryImpl<String>> {
        let store = CountingStore()
        var dict = MerkleDictionaryImpl<String>()
        for i in 0..<keyCount {
            dict = try dict.inserting(key: "key-\(i)", value: "value-\(i)")
        }
        let vol = try VolumeImpl(node: dict)
        try await vol.storeRecursively(storer: store)
        return try await VolumeImpl<MerkleDictionaryImpl<String>>(rawCID: vol.rawCID)
            .resolveRecursive(fetcher: store)
    }

    @Test("walk visits each node once and every edge child is itself visited")
    func walkInvariants() async throws {
        let resolved = try await resolvedDict(keyCount: 40)

        var visited = Set<String>()
        var visitCount = 0
        var edges: [String: [String: Int]] = [:]
        resolved.walkOwnedSubtree(visited: &visited) { node, childEdges in
            visitCount += 1
            if !childEdges.isEmpty { edges[node] = childEdges }
        }

        #expect(!visited.isEmpty, "a non-trivial dictionary has nodes to walk")
        #expect(visitCount == visited.count, "each node is visited exactly once (no double-visit)")
        #expect(visited.contains(resolved.rawCID), "the root is part of its own owned subtree")

        // Every edge endpoint is itself a visited node (the walk is a closed subgraph).
        for (parent, childEdges) in edges {
            #expect(visited.contains(parent))
            for child in childEdges.keys {
                #expect(visited.contains(child), "edge child \(child) must be a walked node")
            }
        }
    }

    @Test("a pre-seeded visited set short-circuits the walk")
    func dedupAcrossSeed() async throws {
        let resolved = try await resolvedDict(keyCount: 20)

        var first = Set<String>()
        resolved.walkOwnedSubtree(visited: &first) { _, _ in }

        // Seeding with the full set means nothing new is visited on a second walk.
        var seeded = first
        var secondVisits = 0
        resolved.walkOwnedSubtree(visited: &seeded) { _, _ in secondVisits += 1 }
        #expect(secondVisits == 0, "an already-walked frontier is not revisited")
        #expect(seeded == first, "visited set is unchanged when nothing new is reachable")
    }

    @Test("an unresolved (node-less) header walks nothing")
    func unresolvedWalksNothing() async throws {
        let header = VolumeImpl<MerkleDictionaryImpl<String>>(rawCID: "bafyreiabc")
        var visited = Set<String>()
        var visits = 0
        header.walkOwnedSubtree(visited: &visited) { _, _ in visits += 1 }
        #expect(visits == 0)
        #expect(visited.isEmpty)
    }

    @Test("walk includes Header-valued radix values")
    func walksHeaderValuedRadixValues() throws {
        typealias Dictionary = MerkleDictionaryImpl<VolumeImpl<Leaf>>
        let value = try VolumeImpl(node: Leaf(value: "payload"))
        let dictionary = try Dictionary().inserting(key: "item", value: value)
        let root = try VolumeImpl(node: dictionary)
        var visited = Set<String>()
        var edges = [String: [String: Int]]()

        root.walkOwnedSubtree(visited: &visited) { node, childEdges in
            edges[node] = childEdges
        }

        #expect(visited.contains(value.rawCID))
        #expect(edges.values.contains { $0[value.rawCID] == 1 })
    }
}

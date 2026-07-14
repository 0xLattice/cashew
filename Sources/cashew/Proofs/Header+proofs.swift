import ArrayTrie

public extension Header {
    func proof(paths: [[String]: SparseMerkleProof], fetcher: Fetcher) async throws -> Self {
        var pathTrie = ArrayTrie<SparseMerkleProof>()
        for (path, proof) in paths {
            pathTrie.set(path, value: proof)
        }
        return try await proof(paths: pathTrie, fetcher: fetcher)
    }

    func proof(paths: ArrayTrie<SparseMerkleProof>, fetcher: Fetcher) async throws -> Self {
        try await proofPaths(paths, fetcher: fetcher)
    }

    func proofPaths(_ paths: ArrayTrie<SparseMerkleProof>, fetcher: Fetcher) async throws -> Self {
        if paths.isEmpty && paths.get([]) == nil { return self }
        if let node = node {
            let resolvedNode = try await node.proof(paths: paths, fetcher: fetcher)
            return Self(rawCID: rawCID, node: resolvedNode, encryptionInfo: encryptionInfo)
        }
        else {
            let newNode = try await fetchAndDecodeNode(fetcher: fetcher)
            let resolvedNode = try await newNode.proof(paths: paths, fetcher: fetcher)
            return Self(rawCID: rawCID, node: resolvedNode, encryptionInfo: encryptionInfo)
        }
    }
}

// A Volume proves exactly like any other Header (`Header.proof` above), so no
// Volume-specific proof override is needed.

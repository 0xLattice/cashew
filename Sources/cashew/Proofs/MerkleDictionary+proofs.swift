import ArrayTrie

public extension MerkleDictionary {
    func proof(paths: ArrayTrie<SparseMerkleProof>, fetcher: Fetcher) async throws -> Self {
        if paths.traverse([""]) != nil { throw ProofErrors.invalidProofType("proof on the empty key") }
        return try await proofForChildren(paths: paths, fetcher: fetcher)
    }

    func proofForChildren(paths: ArrayTrie<SparseMerkleProof>, fetcher: Fetcher) async throws -> Self {
        let allChildCharacters = Set(children.keys).union(paths.childCharacters())
        let box = SendableBox(paths)
        let newChildren = try await withThrowingTaskGroup(of: (Character, ChildType)?.self) { group in
            for childKey in allChildCharacters {
                group.addTask {
                    let paths = box.value
                    guard let child = children[childKey] else {
                        guard let childPath = paths.traverseChild(childKey) else { return nil }
                        let allChildValues = Set(childPath.allValues())
                        if allChildValues.contains(.deletion) || allChildValues.contains(.mutation) { throw ProofErrors.invalidProofType("deletion/mutation proof on non-existent child '\(childKey)'") }
                        return nil
                    }
                    guard let childTraversal = paths.traverseChild(childKey) else {
                        return (childKey, child)
                    }
                    if childTraversal.isEmpty {
                        return (childKey, child)
                    }
                    return (childKey, try await child.proof(paths: childTraversal, fetcher: fetcher))
                }
            }
            var result = [Character: ChildType]()
            for try await pair in group {
                if let (key, value) = pair {
                    result[key] = value
                }
            }
            return result
        }
        return Self(children: newChildren, count: count)
    }
}

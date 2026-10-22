import ArrayTrie

public extension RadixNode {
    func proof(paths: ArrayTrie<SparseMerkleProof>, fetcher: Fetcher) async throws -> Self {
        guard let traversedPrefix = paths.traverse(path: prefix) else {
            let values = paths.allValues()
            if values.contains(.deletion) || values.contains(.mutation) { throw ProofErrors.invalidProofType("deletion/mutation proof on non-existent prefix '\(prefix)'") }
            return self
        }
        let values = Set(paths.valuesExcludingPrefix(prefix))
        if values.contains(.deletion) || values.contains(.mutation) { throw ProofErrors.invalidProofType("deletion/mutation proof outside prefix '\(prefix)'") }
        // An existence proof leaves this node's value as it is, so the node can
        // collapse under a batched delete exactly as an unproven one can.
        let proofAtNode = traversedPrefix.get([""])
        guard let proofAtNode, proofAtNode != .existence else {
            // Batched deletes only need collapse witnesses at levels where the
            // batch could remove all but one child branch. Avoid resolving
            // child subtrees just to prove they disappear; this cheap local
            // check prunes obvious non-collapse ancestors.
            let base = shouldExpandForBatchedDeletion(paths: traversedPrefix)
                ? try await resolveGrandchildren(fetcher: fetcher)
                : self
            return try await base.proofForChildren(paths: traversedPrefix, fetcher: fetcher)
        }
        switch proofAtNode {
        case .mutation:
            if value == nil { throw ProofErrors.invalidProofType("mutation proof on nil value at prefix '\(prefix)'") }
        case .existence:
            break
        case .insertion:
            if value != nil { throw ProofErrors.invalidProofType("insertion proof on existing value at prefix '\(prefix)'") }
        case .deletion:
            let base = shouldExpandForBatchedDeletion(paths: traversedPrefix)
                ? try await resolveGrandchildren(fetcher: fetcher)
                : self
            if traversedPrefix.childKeys().count == 0 { return base }
            return try await base.proofForChildren(paths: traversedPrefix, fetcher: fetcher)
        }
        return try await proofForChildren(paths: traversedPrefix, fetcher: fetcher)
    }

    func shouldExpandForBatchedDeletion(paths: ArrayTrie<SparseMerkleProof>) -> Bool {
        let deletesValue = paths.get([""]) == .deletion
        if value != nil && !deletesValue { return false }
        var fullyDeletedChildren = 0
        var survivingChildren = 0
        for childKey in children.keys {
            guard let childPath = paths.traverseChild(childKey) else {
                survivingChildren += 1
                continue
            }
            // An existence proof changes nothing, so it cannot keep a child alive.
            let childValues = childPath.allValues().filter { $0 != .existence }
            let hasDeletion = childValues.contains(.deletion)
            let fullyDeletesChild = hasDeletion && childValues.allSatisfy { $0 == .deletion }
            if fullyDeletesChild {
                fullyDeletedChildren += 1
            } else {
                survivingChildren += 1
            }
        }
        return (deletesValue || fullyDeletedChildren > 0) && survivingChildren <= 1
    }

    func proofForChildren(paths: ArrayTrie<SparseMerkleProof>, fetcher: Fetcher) async throws -> Self {
        let allChildCharacters = Set(children.keys).union(paths.childCharacters())
        let box = SendableBox(paths)
        let newChildren = try await withThrowingTaskGroup(of: (Character, ChildType)?.self) { group in
            for childKey in allChildCharacters {
                group.addTask {
                    let paths = box.value
                    guard let child = children[childKey] else {
                        guard let childPath = paths.childPaths(childKey) else { return nil }
                        let allChildValues = Set(childPath.allValues())
                        if allChildValues.contains(.deletion) || allChildValues.contains(.mutation) { throw ProofErrors.invalidProofType("deletion/mutation proof on non-existent child '\(childKey)'") }
                        return nil
                    }
                    guard let childTraversal = paths.childPaths(childKey) else {
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
        return Self(prefix: prefix, value: value, children: newChildren)
    }

    func resolveGrandchildren(fetcher: Fetcher) async throws -> Self {
        let newChildren = try await withThrowingTaskGroup(of: (Character, ChildType).self) { group in
            for (childKey, child) in children {
                group.addTask {
                    return (childKey, try await child.resolveChildren(fetcher: fetcher))
                }
            }
            var result = [Character: ChildType]()
            for try await (key, value) in group {
                result[key] = value
            }
            return result
        }
        return Self(prefix: prefix, value: value, children: newChildren)
    }

    func resolveChildren(fetcher: Fetcher) async throws -> Self {
        let newChildren = try await withThrowingTaskGroup(of: (Character, ChildType).self) { group in
            for (childKey, child) in children {
                group.addTask {
                    return (childKey, try await child.resolve(fetcher: fetcher))
                }
            }
            var result = [Character: ChildType]()
            for try await (key, value) in group {
                result[key] = value
            }
            return result
        }
        return Self(prefix: prefix, value: value, children: newChildren)
    }
}

private extension ArrayTrie<SparseMerkleProof> {
    /// `traverseChild` keeps this node's own proof in the trie it returns; a
    /// child must be proven against only the paths beneath it.
    func childPaths(_ char: Character) -> Self? {
        traverseChild(char)?.deleting(path: []).deleting(path: [""])
    }
}

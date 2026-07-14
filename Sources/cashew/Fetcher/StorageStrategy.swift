import ArrayTrie

/// Controls how a storage plan crosses a Volume boundary.
public enum StorageStrategy: Equatable, Sendable {
    /// Store the Volume at this path, but no nested Volumes below it.
    case targeted

    /// Store the Volume at this path and every materialized nested Volume.
    case recursive
}

extension ArrayTrie where Value == StorageStrategy {
    /// Compressed-radix traversal may represent the current node with an empty
    /// path segment, while structural traversal uses the trie root directly.
    var isRecursiveHere: Bool {
        self.get([]) == .recursive || self.get([""]) == .recursive
    }
}

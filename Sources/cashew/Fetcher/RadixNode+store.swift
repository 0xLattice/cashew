import ArrayTrie

public extension RadixNode {
    func storeVolumes(
        paths: ArrayTrie<StorageStrategy>,
        storer: any VolumeStorer
    ) async throws {
        let storer = volumeStorageSession(storer)
        let pathValuesAndTries = paths.valuesAlongPath(prefix)
        if pathValuesAndTries.contains(where: { $0.1 == .recursive }) {
            try await storeVolumesRecursively(storer: storer)
            return
        }

        guard let traversalPaths = paths.traverse(path: prefix) else { return }
        for char in children.keys.sorted() {
            guard let childPaths = traversalPaths.traverseChild(char),
                  let child = children[char] else { continue }
            try await child.storeSelectedVolumes(paths: childPaths, storer: storer)
        }

        if let value,
           let header = value as? any Header {
            if let downstreamPaths = paths.traverse([prefix]) {
                try await header.storeSelectedVolumes(paths: downstreamPaths, storer: storer)
            } else if paths.get([prefix]) == .targeted,
                      let volume = header as? any Volume {
                try await volume.store(storer: storer)
            }
        }
    }
}

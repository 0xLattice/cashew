import ArrayTrie

public extension MerkleDictionary {
    func storeVolumes(
        paths: ArrayTrie<StorageStrategy>,
        storer: any VolumeStorer
    ) async throws {
        let storer = volumeStorageSession(storer)
        if paths.isRecursiveHere {
            try await storeVolumesRecursively(storer: storer)
            return
        }

        for char in children.keys.sorted() {
            guard let childPaths = paths.traverseChild(char),
                  let child = children[char] else { continue }
            try await child.storeSelectedVolumes(paths: childPaths, storer: storer)
        }
    }
}

import ArrayTrie

extension Volume {
    func storeCurrentVolume(storer: VolumeStorageSession) async throws -> NodeType {
        guard let node else { throw DataErrors.nodeNotAvailable }
        if try await storer.waitForStored(root: rawCID) { return node }

        var entries = [rawCID: try verifiedSerializedDataForStorage(keyProvider: storer)]
        var visited = Set([rawCID])
        try node.collectVolumeEntries(
            into: &entries,
            visited: &visited,
            keyProvider: storer
        )

        try await storer.store(volume: SerializedVolume(root: rawCID, entries: entries))
        return node
    }
}

public extension Volume {
    /// Store this Volume and only the nested Volumes selected by `paths`.
    ///
    /// Paths use the same structural and compressed-radix traversal rules as
    /// resolution paths. The root Volume is always selected.
    func store(
        paths: [[String]: StorageStrategy],
        storer: any VolumeStorer
    ) async throws {
        var pathTrie = ArrayTrie<StorageStrategy>()
        for (path, strategy) in paths {
            pathTrie.set(path, value: strategy)
        }
        try await store(paths: pathTrie, storer: storer)
    }

    /// Store this Volume and only the nested Volumes selected by `paths`.
    func store(
        paths: ArrayTrie<StorageStrategy>,
        storer: any VolumeStorer
    ) async throws {
        let session = volumeStorageSession(storer)
        if paths.isRecursiveHere {
            try await storeRecursively(storer: session)
            return
        }

        let node = try await storeCurrentVolume(storer: session)
        try await node.storeVolumes(paths: paths, storer: session)
    }

    /// Store only this complete Volume boundary.
    func store(storer: any VolumeStorer) async throws {
        _ = try await storeCurrentVolume(storer: volumeStorageSession(storer))
    }

    /// Store this Volume and every materialized nested Volume independently.
    /// Completed boundaries are not rolled back if a later boundary fails.
    func storeRecursively(storer: any VolumeStorer) async throws {
        let session = volumeStorageSession(storer)
        let node = try await storeCurrentVolume(storer: session)
        guard await session.claimRecursiveExpansion(root: rawCID) else { return }
        try await node.storeVolumesRecursively(storer: session)
    }
}

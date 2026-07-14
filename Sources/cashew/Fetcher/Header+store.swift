import ArrayTrie
import Foundation
import Crypto

private final class MaterializedHeaderFetcher: Fetcher, KeyProvider, @unchecked Sendable {
    private let keyProvider: (any KeyProvider)?
    private let lock = NSLock()
    private var headers: [String: any Header]
    private var fetchedEntries: [String: Data] = [:]

    init(root: any Header, keyProvider: (any KeyProvider)?) {
        self.headers = [root.rawCID: root]
        self.keyProvider = keyProvider
    }

    func fetch(rawCid: String) async throws -> Data {
        guard let header = lock.withLock({ headers[rawCid] }) else {
            throw DataErrors.nodeNotAvailable
        }
        let data = try header.verifiedSerializedDataForStorage(keyProvider: keyProvider)
        let children = header.materializedChildren()
        lock.withLock {
            fetchedEntries[rawCid] = data
            for child in children where child.node != nil {
                headers[child.rawCID] = child
            }
        }
        return data
    }

    func key(for keyHash: String) -> SymmetricKey? {
        keyProvider?.key(for: keyHash)
    }

    var entries: [String: Data] {
        lock.withLock { fetchedEntries }
    }
}

extension Header {
    /// Serialize this materialized Header exactly as its CID was computed.
    func serializedDataForStorage(keyProvider: (any KeyProvider)?) throws -> Data {
        guard let node else { throw DataErrors.nodeNotAvailable }

        let data: Data
        if let info = encryptionInfo {
            guard let keyProvider else { throw DataErrors.keyNotFound }
            guard let key = keyProvider.key(for: info.keyHash) else { throw DataErrors.keyNotFound }
            guard let ivData = info.ivData else { throw DataErrors.invalidIV }
            let nonce = try AES.GCM.Nonce(data: ivData)
            let plaintext = try Self.serializeNode(node, codec: Self.defaultCodec)
            data = try EncryptionHelper.encrypt(data: plaintext, key: key, nonce: nonce)
        } else {
            guard let nodeData = node.toData() else { throw DataErrors.serializationFailed }
            data = nodeData
        }

        return data
    }

    func verifiedSerializedDataForStorage(keyProvider: (any KeyProvider)?) throws -> Data {
        let data = try serializedDataForStorage(keyProvider: keyProvider)
        try verifyData(data, matches: rawCID)
        return data
    }

    func collectVolumeEntries(
        into entries: inout [String: Data],
        visited: inout Set<String>,
        keyProvider: (any KeyProvider)?
    ) throws {
        guard !(self is any Volume) else { return }
        guard visited.insert(rawCID).inserted else { return }
        guard let node else { throw DataErrors.nodeNotAvailable }
        entries[rawCID] = try verifiedSerializedDataForStorage(keyProvider: keyProvider)
        try node.collectVolumeEntries(
            into: &entries,
            visited: &visited,
            keyProvider: keyProvider
        )
    }

    func storeSelectedVolumes(
        paths: ArrayTrie<StorageStrategy>,
        storer: any VolumeStorer
    ) async throws {
        if let volume = self as? any Volume {
            try await volume.store(paths: paths, storer: storer)
            return
        }

        guard let node else { throw DataErrors.nodeNotAvailable }
        if paths.isRecursiveHere {
            try await node.storeVolumesRecursively(storer: storer)
        } else {
            try await node.storeVolumes(paths: paths, storer: storer)
        }
    }

    func storeNestedVolumesRecursively(storer: any VolumeStorer) async throws {
        if let volume = self as? any Volume {
            try await volume.storeRecursively(storer: storer)
            return
        }

        guard let node else { throw DataErrors.nodeNotAvailable }
        try await node.storeVolumesRecursively(storer: storer)
    }

    func materializedChildren() -> [any Header] {
        node?.materializedChildren() ?? []
    }

    fileprivate func materializedFetcher(storer: any Storer) throws -> MaterializedHeaderFetcher {
        guard node != nil else { throw DataErrors.nodeNotAvailable }
        return MaterializedHeaderFetcher(
            root: self,
            keyProvider: storer as? any KeyProvider
        )
    }
}

public extension Header {
    /// Store the same sparse set of blocks that resolving `paths` would fetch.
    func store(
        paths: [[String]: ResolutionStrategy],
        storer: any Storer
    ) async throws {
        guard !paths.isEmpty else { return }
        var pathTrie = ArrayTrie<ResolutionStrategy>()
        for (path, strategy) in paths {
            pathTrie.set(path, value: strategy)
        }
        try await store(paths: pathTrie, storer: storer)
    }

    /// Store the same sparse set of blocks that resolving `paths` would fetch.
    func store(
        paths: ArrayTrie<ResolutionStrategy>,
        storer: any Storer
    ) async throws {
        guard !paths.isEmpty || paths.get([]) != nil else { return }
        let fetcher = try materializedFetcher(storer: storer)
        _ = try await removingNode().resolve(paths: paths, fetcher: fetcher)
        try await storer.store(entries: fetcher.entries)
    }

    /// Store only this materialized Header block.
    func store(storer: any Storer) async throws {
        let data = try verifiedSerializedDataForStorage(
            keyProvider: storer as? any KeyProvider
        )
        try await storer.store(entries: [rawCID: data])
    }

    /// Store every reachable block. Any unresolved reference fails the batch.
    func storeRecursively(storer: any Storer) async throws {
        let fetcher = try materializedFetcher(storer: storer)
        _ = try await removingNode().resolveRecursive(fetcher: fetcher)
        try await storer.store(entries: fetcher.entries)
    }
}

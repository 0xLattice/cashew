import ArrayTrie
import Foundation

extension Node {
    func materializedChildren() -> [any Header] {
        var headers: [any Header] = []
        for property in properties().sorted() {
            if let header = get(property: property) {
                headers.append(header)
            }
        }

        if let radixNode = self as? any RadixNode,
           let header = radixNode.value as? any Header {
            headers.append(header)
        }
        return headers
    }

    func collectVolumeEntries(
        into entries: inout [String: Data],
        visited: inout Set<String>,
        keyProvider: (any KeyProvider)?
    ) throws {
        for property in properties().sorted() {
            guard let header = get(property: property) else {
                throw DataErrors.missingDeclaredChild(property)
            }
            try header.collectVolumeEntries(
                into: &entries,
                visited: &visited,
                keyProvider: keyProvider
            )
        }

        if let radixNode = self as? any RadixNode,
           let value = radixNode.value,
           let header = value as? any Header {
            try header.collectVolumeEntries(
                into: &entries,
                visited: &visited,
                keyProvider: keyProvider
            )
        }
    }

    func storeVolumesRecursively(storer: any VolumeStorer) async throws {
        for property in properties().sorted() {
            guard let header = get(property: property) else {
                throw DataErrors.missingDeclaredChild(property)
            }
            try await header.storeNestedVolumesRecursively(storer: storer)
        }

        if let radixNode = self as? any RadixNode,
           let value = radixNode.value,
           let header = value as? any Header {
            try await header.storeNestedVolumesRecursively(storer: storer)
        }
    }
}

public extension Node {
    func storeVolumes(
        paths: ArrayTrie<StorageStrategy>,
        storer: any VolumeStorer
    ) async throws {
        let storer = volumeStorageSession(storer)
        for property in properties().sorted() {
            guard let header = get(property: property) else {
                throw DataErrors.missingDeclaredChild(property)
            }

            if paths.get([property]) == .recursive {
                try await header.storeNestedVolumesRecursively(storer: storer)
            } else if let nextPaths = paths.traverse([property]) {
                try await header.storeSelectedVolumes(paths: nextPaths, storer: storer)
            } else if paths.get([property]) == .targeted,
                      let volume = header as? any Volume {
                try await volume.store(storer: storer)
            }
        }
    }
}

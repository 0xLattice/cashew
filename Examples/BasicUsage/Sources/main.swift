import cashew
import ArrayTrie
import Foundation

// A simple in-memory store for sparse blocks, complete Volumes, and reads.
final class MemoryStore: Storer, VolumeStorer, Fetcher, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    func store(entries: [String: Data]) async {
        storage.merge(entries) { _, new in new }
    }
    func store(volume: SerializedVolume) async {
        storage.merge(volume.entries) { _, new in new }
    }
    func fetch(rawCid: String) async throws -> Data {
        guard let data = storage[rawCid] else {
            fatalError("CID not found: \(rawCid)")
        }
        return data
    }
}

// A leaf value type. Scalars are Codable + LosslessStringConvertible.
struct UserScore: Scalar {
    let score: Int
    init(score: Int) { self.score = score }
}

@main
struct Example {
    static func main() async throws {
        let store = MemoryStore()

        // 1. Build a dictionary
        typealias ScoreDict = MerkleDictionaryImpl<HeaderImpl<UserScore>>

        var dict = ScoreDict(children: [:], count: 0)
        dict = try dict.inserting(key: "alice", value: HeaderImpl(node: UserScore(score: 100)))
        dict = try dict.inserting(key: "bob", value: HeaderImpl(node: UserScore(score: 85)))
        dict = try dict.inserting(key: "charlie", value: HeaderImpl(node: UserScore(score: 92)))

        let volume = try VolumeImpl(node: dict)
        print("Root CID: \(volume.rawCID)")
        print("Count: \(dict.count)")

        // 2. Store everything
        try await volume.store(storer: store)
        print("Stored to memory.")

        // 3. Resolve from just the CID (simulates loading from remote storage)
        let cidOnly = VolumeImpl<ScoreDict>(rawCID: volume.rawCID)
        let resolved = try await cidOnly.resolveRecursive(fetcher: store)
        let alice = try resolved.node!.get(key: "alice")!
        print("Alice's score: \(alice.node!.score)")

        // 4. Transform: update alice, delete bob, insert dave
        var transforms = ArrayTrie<Transform>()
        transforms.set(["alice"], value: .update(try HeaderImpl(node: UserScore(score: 110)).description))
        transforms.set(["bob"], value: .delete)
        transforms.set(["dave"], value: .insert(try HeaderImpl(node: UserScore(score: 77)).description))

        let transformed = try resolved.node!.transform(transforms: transforms)!
        let newHeader = try HeaderImpl(node: transformed)
        print("\nAfter transform:")
        print("New root CID: \(newHeader.rawCID)")
        print("CID changed: \(newHeader.rawCID != volume.rawCID)")
        print("Count: \(transformed.count)")

        // 5. Verify content addressability: same data = same CID
        var rebuilt = ScoreDict(children: [:], count: 0)
        rebuilt = try rebuilt.inserting(key: "alice", value: HeaderImpl(node: UserScore(score: 110)))
        rebuilt = try rebuilt.inserting(key: "charlie", value: HeaderImpl(node: UserScore(score: 92)))
        rebuilt = try rebuilt.inserting(key: "dave", value: HeaderImpl(node: UserScore(score: 77)))
        let rebuiltHeader = try HeaderImpl(node: rebuilt)
        print("Rebuilt from scratch CID matches: \(rebuiltHeader.rawCID == newHeader.rawCID)")
    }
}

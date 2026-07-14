import Foundation
import Crypto

/// One complete Volume boundary ready for persistence.
///
/// `entries` contains the root and every ordinary Header reachable before the
/// next nested Volume boundary. Cashew materializes the complete dictionary
/// before calling the storer, so temporary memory scales with boundary size.
public struct SerializedVolume: Sendable {
    public let root: String
    public let entries: [String: Data]

    public init(root: String, entries: [String: Data]) {
        self.root = root
        self.entries = entries
    }
}

/// Persists complete Volume boundaries emitted by Cashew's storage planner.
///
/// Cashew calls this once per selected Volume, after the full boundary has been
/// serialized. Multi-Volume plans are not transactional: completed boundaries
/// remain stored if a later boundary fails. Conformers must therefore make an
/// identical repeated store idempotent so callers can safely retry the plan.
public protocol VolumeStorer: Sendable {
    func store(volume: SerializedVolume) async throws
}

actor VolumeStorageSession: VolumeStorer, KeyProvider {
    private enum StoreState {
        case inFlight(Task<Void, any Error>)
        case stored
    }

    nonisolated private let storer: any VolumeStorer
    private var stores = [String: StoreState]()
    private var recursivelyExpandedRoots = Set<String>()

    init(storer: any VolumeStorer) {
        self.storer = storer
    }

    func claimRecursiveExpansion(root: String) -> Bool {
        recursivelyExpandedRoots.insert(root).inserted
    }

    func waitForStored(root: String) async throws -> Bool {
        switch stores[root] {
        case .stored:
            return true
        case .inFlight(let task):
            try await task.value
            return true
        case nil:
            return false
        }
    }

    func store(volume: SerializedVolume) async throws {
        switch stores[volume.root] {
        case .stored:
            return
        case .inFlight(let task):
            try await task.value
            return
        case nil:
            break
        }

        let storer = self.storer
        let task = Task {
            try await storer.store(volume: volume)
        }
        stores[volume.root] = .inFlight(task)

        do {
            try await task.value
            stores[volume.root] = .stored
        } catch {
            stores[volume.root] = nil
            throw error
        }
    }

    nonisolated func key(for keyHash: String) -> SymmetricKey? {
        (storer as? any KeyProvider)?.key(for: keyHash)
    }
}

func volumeStorageSession(_ storer: any VolumeStorer) -> VolumeStorageSession {
    storer as? VolumeStorageSession ?? VolumeStorageSession(storer: storer)
}

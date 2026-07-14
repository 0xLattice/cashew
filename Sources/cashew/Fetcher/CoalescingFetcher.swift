import Foundation
import Crypto

/// Turns a batched ``ContentSource`` into a per-CID ``Fetcher`` by *coalescing*
/// the many simultaneous `fetch` calls that resolution makes at each level into
/// a single batched request — the DataLoader pattern.
///
/// Why this exists: resolution already fans out across a node's children
/// concurrently (`resolveChildrenConcurrently` / the `withThrowingTaskGroup` in
/// `Node.resolve`). Each of those concurrent tasks calls `fetch(rawCid)` at
/// nearly the same instant — one "wave". Sending each on its own network trip is
/// the per-node round-trip problem. Instead we buffer a wave's CIDs and flush them as one
/// `ContentSource.fetch(Set)`: same proven resolution walk, one round-trip per
/// level, and no Header-vs-Volume special-casing.
///
/// Correctness never depends on batch completeness: a request is always served;
/// batching is purely an optimization. If a wave's requests don't all land in
/// the same batch, the worst case is a smaller batch (more round-trips), never a
/// wrong or missing fetch.
public actor CoalescingFetcher: Fetcher, KeyProvider {
    private let source: any ContentSource
    private var pending: [String: [CheckedContinuation<Data, Error>]] = [:]
    private var flushScheduled = false

    public init(_ source: any ContentSource) {
        self.source = source
    }

    // Forward decryption-key lookups to the wrapped source so encrypted nodes
    // resolve over a ContentSource exactly as they do over a KeyProvidingFetcher.
    // `source` is an immutable Sendable `let`, so it is nonisolated-accessible.
    // If the source provides no keys this returns nil — identical to resolving
    // an encrypted node with a non-key-providing fetcher (DataErrors.keyNotFound).
    public nonisolated func key(for keyHash: String) -> SymmetricKey? {
        (source as? KeyProvider)?.key(for: keyHash)
    }

    public func fetch(rawCid: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            pending[rawCid, default: []].append(continuation)
            if !flushScheduled {
                flushScheduled = true
                Task { await self.flush() }
            }
        }
    }

    private func flush() async {
        // Yield once so the rest of the current concurrent wave registers its
        // CIDs before we snapshot — this is what makes a level batch into one
        // request rather than dribble in.
        await Task.yield()

        let waiters = pending
        pending = [:]
        flushScheduled = false
        guard !waiters.isEmpty else { return }

        let cids = Set(waiters.keys)
        let results = await source.fetch(cids)

        for (cid, continuations) in waiters {
            if let data = results[cid] {
                for c in continuations { c.resume(returning: data) }
            } else {
                for c in continuations { c.resume(throwing: FetcherError.notFound(cid)) }
            }
        }

        // Requests that arrived during the await above accumulated a new wave;
        // drain it too.
        if !pending.isEmpty && !flushScheduled {
            flushScheduled = true
            Task { await self.flush() }
        }
    }
}

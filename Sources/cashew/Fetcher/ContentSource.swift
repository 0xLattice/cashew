import Foundation

/// A batched content source: fetch many CIDs in one call.
///
/// This complements the per-CID ``Fetcher`` without a Volume-specific side
/// channel. Resolution computes the
/// frontier of CIDs it needs next (see the closure walk) and asks for the whole
/// frontier at once, so a networked backend does one round-trip per BFS level
/// instead of one per node — and there is no Header-vs-Volume fetch divergence.
///
/// Backends return whatever subset they have; missing CIDs are simply absent
/// from the result (the resolver decides whether an absence is fatal). A backend
/// MUST NOT return bytes under a CID they do not hash to — integrity is verified
/// by the resolver, but well-behaved sources never serve mismatched data.
public protocol ContentSource: Sendable {
    func fetch(_ cids: Set<String>) async -> [String: Data]
}

/// Serves from an in-memory map. Used to run the (unchanged) per-node resolve
/// walk against a closure that was already batch-loaded by `ContentSource`.
public struct InMemoryContentSource: ContentSource, Fetcher {
    private let entries: [String: Data]
    public init(_ entries: [String: Data]) { self.entries = entries }

    public func fetch(_ cids: Set<String>) async -> [String: Data] {
        var out: [String: Data] = [:]
        out.reserveCapacity(cids.count)
        for cid in cids where !cid.isEmpty {
            if let data = entries[cid] { out[cid] = data }
        }
        return out
    }

    // Fetcher conformance so existing resolve methods can run against the
    // already-loaded closure with no network hop.
    public func fetch(rawCid: String) async throws -> Data {
        guard let data = entries[rawCid] else { throw FetcherError.notFound(rawCid) }
        return data
    }
}

/// Bridges a per-CID ``Fetcher`` to the batched ``ContentSource`` (sequential
/// fan-out). Lets the new batched resolver run over legacy fetchers during the
/// migration; networked backends should implement ``ContentSource`` directly to
/// get real batching.
public struct FetcherContentSource: ContentSource {
    private let fetcher: any Fetcher
    public init(_ fetcher: any Fetcher) { self.fetcher = fetcher }

    public func fetch(_ cids: Set<String>) async -> [String: Data] {
        var out: [String: Data] = [:]
        for cid in cids where !cid.isEmpty {
            if let data = try? await fetcher.fetch(rawCid: cid) { out[cid] = data }
        }
        return out
    }
}

/// In-memory overlay consulted first; misses delegate to `fallback` in one
/// batched call. The wave-grain "check a local map, then fall through" overlay
/// (e.g. mempool tx bodies or staged proof entries layered over a network source).
public struct OverlayContentSource: ContentSource {
    private let entries: [String: Data]
    private let fallback: any ContentSource

    public init(entries: [String: Data], fallback: any ContentSource) {
        self.entries = entries
        self.fallback = fallback
    }

    public func fetch(_ cids: Set<String>) async -> [String: Data] {
        var out: [String: Data] = [:]
        var missing: Set<String> = []
        for cid in cids {
            if let data = entries[cid] {
                out[cid] = data
            } else {
                missing.insert(cid)
            }
        }
        if !missing.isEmpty {
            out.merge(await fallback.fetch(missing)) { a, _ in a }
        }
        return out
    }
}

/// Try sources in order; each later source sees only the previous misses.
/// The wave-grain "try each tier in precedence order" composition.
public struct CompositeContentSource: ContentSource {
    private let sources: [any ContentSource]

    public init(_ sources: [any ContentSource]) {
        self.sources = sources
    }

    public func fetch(_ cids: Set<String>) async -> [String: Data] {
        var out: [String: Data] = [:]
        var missing = cids
        for source in sources {
            guard !missing.isEmpty else { break }
            let found = await source.fetch(missing)
            out.merge(found) { a, _ in a }
            missing.subtract(found.keys)
        }
        return out
    }
}

public enum FetcherError: Error, Sendable {
    case notFound(String)
}

import Foundation

/// Persists an arbitrary set of verified content-addressed blocks.
///
/// Unlike ``VolumeStorer``, this port makes no completeness or retention
/// guarantee. It is suitable for sparse DAGs, replication, and read-through
/// caches. Read-through caching may call `store(entries:)` once per fetched
/// block, so networked and database-backed conformers should coalesce writes
/// internally when needed. Cashew does not preflight block existence; conformers
/// must deduplicate by CID and make identical repeated writes idempotent.
public protocol Storer: Sendable {
    func store(entries: [String: Data]) async throws
}

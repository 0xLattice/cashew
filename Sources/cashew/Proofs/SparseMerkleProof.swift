/// The type of proof requested for a key in a ``MerkleDictionary``.
///
/// Used with `proof(paths:fetcher:)` to specify what evidence to collect
/// for each targeted key path. `insertion` requires the key to be absent, and
/// `mutation` and `deletion` require it to be present. `existence` is a read
/// witness and requires neither: it collects the nodes that show the key's
/// current value, or that it has none.
public enum SparseMerkleProof: Int, Codable, Sendable {
    case insertion = 1, mutation, deletion, existence
}


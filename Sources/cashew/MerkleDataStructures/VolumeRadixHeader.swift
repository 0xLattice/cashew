/// A ``RadixHeader`` that is also a ``Volume`` — every trie-internal link is a
/// Volume boundary. Used to build Merkle tries where the liveness unit is the
/// individual trie node, not the outer root.
///
/// Pairing this with ``VolumeMerkleDictionary`` produces a structure in which
/// *every* header — root and all descendants — is independently addressable as
/// a Volume boundary, enabling targeted storage and per-subtree retention.
public protocol VolumeRadixHeader: RadixHeader, Volume
where NodeType.ChildType == Self { }

# cashew

cashew is a Swift library for content-addressed data: immutable Merkle radix
tries in which every node is addressed by the hash of its bytes (a CID),
loads on demand, and shares unchanged branches with earlier versions. Lattice
keeps chain state, each block's transaction set and the child-chain map as
cashew `MerkleDictionary` trees, and embeds their roots in blocks as CIDs.

## Quick example

```swift
import cashew

var dict = MerkleDictionaryImpl<String>()
dict = try dict.inserting(key: "alice", value: "engineer")
dict = try dict.inserting(key: "bob", value: "designer")

let volume = try VolumeImpl(node: dict)
print(volume.rawCID) // "bafyrei...": the fingerprint of this exact data

// Persist one complete storage boundary
try await volume.store(storer: myStore)
```

Every version of the data has its own CID. Insert one more key and the root
CID changes, but the branches you did not touch keep their CIDs and are
shared with the previous version.

## Key concepts

| Term | Meaning |
| --- | --- |
| CID | The identifier of a node: the SHA2-256 hash of its deterministic DAG-CBOR serialization. Identity comes from content, not location. |
| Node | One piece of data in the tree. It refers to its children by CID. |
| Header | A reference to a node: a CID and, optionally, the loaded node. `node == nil` means the hash is known and the data is not loaded. |
| Resolution | Loading the nodes behind Headers from a store, only along the paths asked for. |
| Merkle structures | `MerkleDictionary` (key-value map), `MerkleArray` (append-only list) and `MerkleSet` (membership), all built on one radix trie. |
| Transform | An insert, update or delete. It returns a new tree with new CIDs for the changed nodes only. |
| Proof | The smallest subtree that proves a key exists, is absent, or can be changed. Unrelated branches stay as CIDs. |
| Volume | A Header that marks a storage boundary. See [Volume](#volume). |

### Content addressing

Equal plaintext content always has the same CID, and any change to the
content changes the CID. A reader can therefore fetch a node from anywhere
and check it against the CID it asked for, without trusting the source.

An encrypted node's CID is the hash of its ciphertext, and each encryption
uses a fresh random nonce. Encrypting the same content twice gives two
different CIDs. [cashew encryption](docs/encryption.md) explains this.

### Volume

A `Volume` is a `Header` that marks a boundary in the tree. The Volume's root
and every node below it, down to the next Volume, form one unit that is
stored and retained on its own.

- Storing a Volume emits that unit as one complete `SerializedVolume`: the
  root CID and the `(CID, bytes)` entry of every node in the boundary.
- Volumes nest. A nested Volume is a separate unit and is never part of its
  parent's entries. `StorageStrategy.targeted` and `.recursive` paths select
  which nested Volumes a store call also emits.
- Marking a Header as a Volume changes no CID. Resolution treats a Volume
  like any other Header.
- Relationships between Volumes exist only in the content-addressed nodes.

[cashew architecture](docs/architecture.md#volumes) describes how Volumes are
stored.

### When to use it

| Good fit | Not a fit |
| --- | --- |
| Content-addressable storage backends (IPFS, CAS databases) | High-throughput mutable key-value stores: cashew is immutable and every write allocates |
| Versioned state where every mutation must be auditable | Data that does not need content addressing or integrity guarantees |
| Distributed systems exchanging tamper-evident data | In-memory caches where a `Dictionary` suffices |
| Selective encryption: some fields public, some private, one structure | |
| Proofs about specific keys without the full dataset | |

## Boundary

| cashew owns | The caller owns |
| --- | --- |
| Serializing nodes and computing CIDs | The storage engine, behind the `Fetcher`, `ContentSource`, `Storer` and `VolumeStorer` protocols |
| Walking the tree to resolve, store, transform and prove | Which paths to resolve, store or prove |
| Checking every fetched or emitted block against its CID | Retention, peer selection and workflow completeness |
| Emitting each selected Volume complete | Validity and canonicity of the data |
| Encrypting and decrypting nodes with the keys it is given | Keys and key management, behind `KeyProvider` |

## Documentation

Published at [lattice.build/docs](https://lattice.build/docs/protocol/cashew/)
from the files below.

| Page | What it covers |
| --- | --- |
| [cashew architecture](docs/architecture.md) | How the library is built: content addressing and CID computation, the `Node` and `Header` types, lazy resolution and its strategies, Volumes, and the storage protocols. |
| [cashew data structures](docs/data-structures.md) | The radix trie, `MerkleDictionary`, `MerkleArray` and `MerkleSet`, sparse Merkle proofs, diffing, transforms, and the query language with its execution model. |
| [cashew encryption](docs/encryption.md) | How to encrypt parts of a tree, the three strategies, key management, and how encryption interacts with CIDs and transforms. |
| [cashew invariants](docs/correctness-invariants.md) | The rules a change to cashew's storage must keep, each with its ID and the tests that enforce it. |

## Install

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/0xLattice/cashew.git", from: "5.2.0")
]
```

Requires Swift 6.0+ (macOS 12+, iOS 15+, watchOS 8+, tvOS 15+).

```bash
swift test
```

### Dependencies

| Package | Purpose |
| --- | --- |
| [ArrayTrie](https://github.com/0xLattice/ArrayTrie) | Path-based traversal of resolution, transform and proof specs |
| [DagCBORKit](https://github.com/0xLattice/DagCBORKit) | DAG-CBOR encoding |
| [swift-crypto](https://github.com/apple/swift-crypto) | SHA2-256 hashing and AES-GCM encryption |
| [swift-cid](https://github.com/swift-libp2p/swift-cid) | IPFS CIDv1 content identifiers |
| [swift-multicodec](https://github.com/swift-libp2p/swift-multicodec) | Codec identifiers (dag-json, dag-cbor) |
| [swift-multihash](https://github.com/swift-libp2p/swift-multihash) | Self-describing hash format |
| [swift-collections](https://github.com/apple/swift-collections) | Standard collections |

## License

MIT

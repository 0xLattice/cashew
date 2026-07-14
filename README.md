# Cashew

A Swift library for **content-addressed storage** — versioned, tamper-evident key-value stores where data can live anywhere and load on demand. Every value is an immutable Merkle radix trie addressed by the hash of its content (a CID); every "write" produces a new root, while unchanged branches share structure with prior versions.

## What problem it solves

Most key-value stores treat data as a mutable blob. Cashew treats data as an immutable, content-addressed Merkle radix trie. This gives you three things traditional stores don't:

- **Verifiable integrity** — the CID is a SHA2-256 hash of the data's deterministic serialization. Same content always produces the same CID; change anything and the CID changes.
- **Lazy loading** — a node can exist as a CID-only reference and resolve its data on demand from any content-addressable backend (IPFS, a database, a filesystem, a peer).
- **Efficient proofs** — prove a key exists or doesn't without revealing the whole dataset.

### Good fit

- Content-addressable storage backends (IPFS, CAS databases)
- Versioned state where every mutation must be auditable
- Distributed systems exchanging tamper-evident data with locality hints
- Selective encryption — some fields public, some private, same structure
- Sparse proofs over specific keys without the full dataset

### Not a fit

- High-throughput mutable key-value stores (Cashew is immutable; every write allocates)
- Data that doesn't need content addressing or integrity guarantees
- Simple in-memory caches where a `Dictionary` suffices

## Quick example

```swift
import cashew

var dict = MerkleDictionaryImpl<String>()
dict = try dict.inserting(key: "alice", value: "engineer")
dict = try dict.inserting(key: "bob", value: "designer")

let volume = try VolumeImpl(node: dict)
print(volume.rawCID) // "baguqeera..." — unique fingerprint of this exact data

// Persist one complete storage boundary
try await volume.store(storer: myStore)
```

Every version of the data gets a unique CID. Insert one more key and the CID changes, but the branches you didn't touch keep their CIDs and are shared with the previous version.

## Key concepts

- **Content addressing** — every node is identified by a CID, a hash of its deterministic DAG-CBOR serialization. Identity is derived from content, not location, so the same data can be stored and fetched anywhere and verified without trusting the source.
- **Headers and sparse DAGs** — a `Header` is a smart pointer holding a CID and, optionally, the node it refers to. `node == nil` means "unresolved": you know the hash but haven't loaded the data. `resolve(paths:fetcher:)` pulls only the branches you ask for, while `store(paths:storer:)` persists exactly the blocks the same resolution plan would fetch. Batched reads use `ContentSource`, and `resolve(..., cache:)` can retain verified fetched blocks explicitly.
- **Merkle data structures** — `MerkleDictionary` is the top-level key-value map, dispatching by first character into a compressed radix trie. `MerkleArray` is an append-only ordered collection backed by a dictionary with 256-bit binary keys; `MerkleSet` is a membership-only set. All share the same content-addressing, resolution, transform, and proof machinery.
- **Transforms** — mutations (`insert` / `update` / `delete`) applied via `transform(transforms:)` or the per-key `inserting`/`mutating`/`deleting` helpers. Each returns a new tree with recomputed CIDs for the changed nodes only.
- **Proofs** — sparse Merkle proofs materialize the minimal subtree needed to verify that a key exists, doesn't exist, or can be modified, leaving unrelated branches as CID stubs.
- **Volumes** — a `Volume` is a `Header` subtype marking an independently fetchable and retainable boundary in the DAG. Cashew emits each selected boundary as one complete `SerializedVolume`; nested Volumes are selected with `StorageStrategy.targeted` or `.recursive` paths that follow the same traversal rules as resolution. Relationships remain encoded only in the content-addressed nodes.

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/adalinxx/cashew.git", from: "1.0.0")
]
```

Requires Swift 6.0+ (macOS 12+, iOS 15+, watchOS 8+, tvOS 15+).

## Usage

### Creating and mutating a dictionary

```swift
import cashew

var dict = MerkleDictionaryImpl<String>()
dict = try dict.inserting(key: "alice", value: "engineer")
dict = try dict.inserting(key: "bob", value: "designer")

let value = try dict.get(key: "alice")        // Optional("engineer")

dict = try dict.mutating(key: "bob", value: "lead designer")
dict = try dict.deleting(key: "alice")

let keys: Set<String> = try dict.allKeys()
let pairs: [String: String] = try dict.allKeysAndValues()
```

### Content addressability and lazy loading

A `Header` can hold just a CID and resolve its data later from any backend:

```swift
struct IPFSFetcher: Fetcher {
    func fetch(rawCid: String) async throws -> Data {
        // fetch from IPFS, a database, or any content-addressable store
    }
}

var paths = ArrayTrie<ResolutionStrategy>()
paths.set(["users", "a"], value: .targeted)  // fetch just this node
paths.set(["config"], value: .recursive)     // fetch the entire subtree
paths.set(["posts"], value: .list)           // fetch structure only, values stay CID-only

let root = HeaderImpl<MerkleDictionaryImpl<String>>(rawCID: rootCID)
let resolved = try await root.resolve(paths: paths, fetcher: IPFSFetcher())

// Persist exactly the materialized blocks selected by the same path language.
try await resolved.store(paths: paths, storer: blockStore)

// Or populate a verified read-through cache while resolving.
let cached = try await root.resolve(
    paths: paths,
    fetcher: IPFSFetcher(),
    cache: blockStore
)
```

Same content always yields the same CID, so equal trees are interchangeable references:

```swift
let h1 = try HeaderImpl(node: dict)
let h2 = try HeaderImpl(node: dict)
assert(h1.rawCID == h2.rawCID)               // same content → same CID
```

### Sparse Merkle proofs

Generate the minimal subtree that proves specific properties about keys:

```swift
var proofPaths = ArrayTrie<SparseMerkleProof>()
proofPaths.set(["alice"], value: .existence)   // prove key exists
proofPaths.set(["dave"],  value: .insertion)   // prove key absent (safe to insert)
proofPaths.set(["bob"],   value: .mutation)    // prove key exists (can be updated)
proofPaths.set(["carol"], value: .deletion)    // prove key + neighbors (can be deleted)

let proof = try await dictionary.proof(paths: proofPaths, fetcher: myFetcher)
// proof contains only the nodes needed to verify these properties
```

The library also supports batch transforms, `MerkleArray` range queries, `MerkleSet` operations, AES-GCM encryption with per-path strategies, structural diffing, and a string query language. See the documentation below.

## Documentation

- [Architecture](docs/architecture.md) — how cashew is built: the `Node`/`Header` model, content-addressing and CID generation, resolution and the fetcher/storer boundary, volumes, encryption, and the query execution model.
- [Data structures](docs/data-structures.md) — the data-structure, proof, and query specification: the radix trie, `MerkleDictionary`/`MerkleArray`/`MerkleSet`, resolution strategies, sparse Merkle proofs, transforms, and diffing.

## Dependencies

All content-addressing primitives come from the [swift-libp2p](https://github.com/swift-libp2p) and Apple toolchains:

| Package | Purpose |
|---------|---------|
| [ArrayTrie](https://github.com/adalinxx/ArrayTrie) | Path-based traversal of resolution/transform/proof specs |
| [swift-crypto](https://github.com/apple/swift-crypto) | SHA2-256 hashing and AES-GCM encryption |
| [swift-cid](https://github.com/swift-libp2p/swift-cid) | IPFS CIDv1 content identifiers |
| [swift-multicodec](https://github.com/swift-libp2p/swift-multicodec) | Codec identifiers (dag-json, dag-cbor) |
| [swift-multihash](https://github.com/swift-libp2p/swift-multihash) | Self-describing hash format |
| [swift-collections](https://github.com/apple/swift-collections) | Standard collections |

## Running tests

```bash
swift test
```

## License

MIT

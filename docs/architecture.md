# cashew architecture

How cashew is built: how nodes get their identifiers, how the types fit
together, how data is loaded and stored, and where cashew stops and the
caller's storage begins. For the terms used here, see
[Key concepts](../README.md#key-concepts) in the README.

cashew is a content-addressed storage (CAS) library for building persistent,
immutable Merkle data structures in Swift. It is the persistence substrate
beneath the Lattice blockchain: chain state, block transaction sets, and the
child-chain map are all cashew `MerkleDictionary` trees whose roots are
embedded in blocks as CIDs.

## Principles

1. **Content addressing.** Every node is identified by the CID (Content
   Identifier) of its serialized bytes. A node referencing a child stores
   only the child's CID, so the data model is a Merkle DAG.
2. **Lazy resolution.** A reference (`Header`) can carry just a CID with no
   loaded node. Resolution fetches and decodes nodes from a backing store on
   demand, so a caller only materializes the subtree it needs.
3. **Immutable, structurally shared updates.** Every mutation returns a new
   root. Unchanged subtrees are shared by CID with the original
   (copy-on-write), so a single byte change rewrites only the path from the
   changed leaf to the root.

The data structures and algorithms themselves (radix trie, dictionary, array,
set, proofs, diff, transforms, query language) are specified in
[cashew data structures](data-structures.md).

## Package layout

The library is a single Swift target, `cashew`, organized into subsystem
directories under `Sources/cashew/`:

```
Sources/cashew/
├── Core/                  Node, Scalar, Header/HeaderImpl, Volume,
│                          DagCBOR, Multicodec, encryption metadata
├── MerkleDataStructures/  RadixNode/Impl, RadixHeader/Impl, SortedEntry,
│                          MerkleDictionary/Array/Set + Impls, Volume* variants
├── Resolver/              lazy resolution: ResolutionStrategy, *+resolve.swift
├── Transform/             batch mutation: Transform, *+transform.swift
├── Proofs/                SparseMerkleProof, *+proofs.swift
├── Fetcher/               persistence boundary: Fetcher, ContentSource,
│                          Storer, VolumeStorer,
│                          StorageStrategy, *+store.swift
├── Diff/                  CashewDiff, *+diff.swift
├── Query/                 CashewParser, Expression, Plan, Executor, Queryable
├── Encryption/            EncryptionStrategy, *+encrypt.swift
└── *.swift                shared error types (DataErrors, DecodingErrors, ...)
```

Each behavior (resolve, transform, proof, store, diff, encrypt) is
implemented once as a protocol extension on `Node`/`Header` and refined where
a concrete structure needs structure-aware logic (most often `RadixNode` and
`MerkleDictionary`). A file named `Type+behavior.swift` adds `behavior` to
`Type`.

| Directory | Responsibility |
|-----------|----------------|
| `Core` | The `Node`/`Header` protocols, the generic `HeaderImpl`/`VolumeImpl` wrappers, DAG-CBOR codec, and AES-GCM encryption helpers. |
| `MerkleDataStructures` | The radix trie and the dictionary/array/set built on it, plus their `Volume`-boundary variants. |
| `Resolver` | On-demand loading of nodes from a `Fetcher`, governed by `ResolutionStrategy`. |
| `Transform` | Batch insert/update/delete applied to a trie, producing a new structurally-shared root. |
| `Proofs` | Sparse Merkle proof construction (pruning a tree down to the witnesses for a set of keys). |
| `Fetcher` | The `Fetcher`/`ContentSource` read ports, sparse `Storer` and complete `VolumeStorer` write ports, `KeyProvider`, and storage planning. |
| `Diff` | Structural difference between two dictionary roots. |
| `Query` | A small pipe-delimited query language compiled to transform/evaluate steps. |
| `Encryption` | Per-node AES-GCM encryption applied selectively across a subtree. |

## Content addressing

A node's CID is computed in `Header.computeCID(for:codec:)`
(`Sources/cashew/Core/Header.swift`):

```
data       = DagCBOR.encode(node)            // canonical IPLD DAG-CBOR bytes
multihash  = Multihash(raw: data, .sha2_256) // SHA-256 of the bytes
cid        = CID(version: .v1, codec: .dag_cbor, multihash: multihash)
rawCID     = cid.toBaseEncodedString          // the stored string identifier
```

### Canonical serialization

DAG-CBOR encoding (`Sources/cashew/Core/DagCBOR.swift`) is a native CBOR
encoder that serializes map entries with deterministically sorted keys (by
byte length, then lexicographically). The serialization is therefore
canonical: the same logical node always produces the same bytes, and so the
same CID, on every platform.

The radix and dictionary structures reinforce this by encoding their child
maps as a `children` array of `SortedEntry { key, value }` sorted by key
(`Sources/cashew/MerkleDataStructures/SortedEntry.swift`), which avoids
unordered-dictionary nondeterminism.

### Codecs

`Codecs` is the multicodec enum from `swift-multicodec`. cashew defaults to
`.dag_cbor` (`Header.defaultCodec`) and exposes a small `ipldCodecs`
convenience list in `Sources/cashew/Core/MulticodecExtensions.swift`. Nodes
can also serialize to JSON via `toJSON()` / `description`, and decode from
either DAG-CBOR or JSON (`Node.init(data:)`).

### Consequences

Because a child is referenced purely by CID, the whole structure is a Merkle
DAG: identity is the hash and mutation is impossible.

- **Integrity on read.** When a `Header` fetches its bytes, it recomputes the
  CID and compares (`Header.verifyData(_:matches:)`); a mismatch
  throws `DataErrors.cidMismatch`. The store cannot serve corrupted or wrong
  data undetected.
- **Deduplication.** Identical subtrees collapse to one CID, so structural
  sharing across versions (and across keys) is automatic.

```swift
let h1 = try HeaderImpl(node: dict)
let h2 = try HeaderImpl(node: dict)
assert(h1.rawCID == h2.rawCID)               // same content, same CID
```

An encrypted node is the exception to "equal content, equal CID": its CID is
computed over the ciphertext, which depends on the key and a random nonce.
See [cashew encryption](encryption.md#cids-of-encrypted-nodes).

## Protocols and implementations

cashew separates *abstract structure* (protocols, with default behavior in
extensions) from *concrete representation* (`*Impl` structs that supply
storage and `Codable`). This lets the Lattice node define its own header and
value types while reusing all traversal, resolution, proof, and transform
logic.

```
Node  (protocol, Core/Node.swift)
│  get(property:) / properties() / set(properties:)  — the only required members
│  default: resolve, transform, proof, store, encrypt, query
├── Scalar           leaf node, no children (Core/Scalar.swift)
├── MerkleDictionary string → value map      (MerkleDataStructures/)
│   ├── MerkleArray  append-only ordered list, 256-bit binary keys
│   └── MerkleSet    members as keys, "" values; set algebra
├── RadixNode        compressed radix-trie node: prefix, value?, children
└── VolumeMerkleDictionary   dictionary whose links are Volume boundaries

Header  (protocol, Core/Header.swift)
│  rawCID + optional loaded node + optional encryptionInfo
│  a lazy, content-addressed reference to a Node
├── RadixHeader        Header whose NodeType is a RadixNode
├── Volume             Header marking a data-locality boundary (Core/Volume.swift)
└── VolumeRadixHeader  RadixHeader that is also a Volume

Concrete Impls (generic over the value/node type):
  HeaderImpl<NodeType>            general Header
  VolumeImpl<NodeType>            general Volume
  RadixNodeImpl<Value>           ── ChildType = RadixHeaderImpl<Value>
  RadixHeaderImpl<Value>         ── NodeType  = RadixNodeImpl<Value>
  MerkleDictionaryImpl<Value>    ── ChildType = RadixHeaderImpl<Value>
  MerkleArrayImpl<Value>
  MerkleSetImpl                  (Value == String)
  VolumeRadixNodeImpl / VolumeRadixHeaderImpl / VolumeMerkleDictionaryImpl
```

| Type | Role |
| --- | --- |
| `Node` | Requires only `get(property:)`, `properties()`, and `set(properties:)`. Everything else (`resolve`, `transform`, `proof`, `storeVolumes`, `encrypt`, and the whole query interface) is a default protocol-extension implementation. `Codable` and `LosslessStringConvertible` are derived from DAG-CBOR/JSON serialization. |
| `Header` | Pairs a `rawCID` with an optional in-memory `node`. When `node` is `nil` the header is an unresolved reference; when present, the data is in memory. `encryptionInfo` is non-nil iff the referenced bytes are encrypted. |
| `HeaderImpl<NodeType>` | The ready-made concrete header. It stores the node in a heap-allocated `Box<NodeType>` so the value-type struct stays `Sendable` while sharing a potentially large node by reference. |

`HeaderImpl`'s `Codable` conformance encodes only `rawCID` and
`encryptionInfo`, never the node. Serializing a header serializes a
*reference*, not the subtree.

The radix family is mutually recursive at the type level:
`RadixHeader.NodeType.ChildType == Self`, i.e. a header's node's children are
headers of the same type. This is what makes a single
`RadixHeaderImpl<Value>` the entry point to an arbitrarily deep,
uniformly-typed trie.

## Lazy resolution

A freshly decoded `Header` holds only `rawCID` (`node == nil`). Resolution
turns references into loaded nodes on demand.

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

### Resolution strategies

The driver is `ResolutionStrategy`
(`Sources/cashew/Resolver/ResolutionStrategy.swift`):

| Strategy | Effect |
|----------|--------|
| `.targeted` | Fetch exactly this header (CID → node), no descent. |
| `.recursive` | Transitively resolve every reachable header in the subtree. |
| `.list` | Resolve the trie *structure* so keys are enumerable, but leaf header values stay `node == nil`. |
| `.range(after:limit:)` | Like `.list`, but only materialize up to `limit` keys after the `after` cursor. |

Resolution paths are carried as an `ArrayTrie<ResolutionStrategy>` (from the
`ArrayTrie` package): each path of property keys maps to the strategy to
apply there.

### How a resolve runs

1. `Header.resolve(paths:fetcher:)`
   (`Sources/cashew/Resolver/Header+resolve.swift`) loads its own node if
   needed.
2. It delegates to `Node.resolve(paths:fetcher:)`
   (`Sources/cashew/Resolver/Node+resolve.swift`), which fans out over the
   node's properties in a `withThrowingTaskGroup`, so sibling subtrees
   resolve concurrently.
3. For each property it either recurses (`.recursive`), descends into the
   remaining sub-paths, fetches a single header (`.targeted` at a leaf path),
   or leaves the reference unresolved.

Resolution is purely additive and immutable: it returns a new node/header
with the same `rawCID` but a populated `node`, via
`Self(rawCID: rawCID, node: resolvedNode, encryptionInfo: encryptionInfo)`. A
resolved node never has a different CID than its unresolved form.

Convenience entry points (`Header+resolve.swift`):

- `resolve(fetcher:)`: load just this node (`.targeted`).
- `resolveRecursive(fetcher:)`: load the whole subtree.
- `resolve(paths:fetcher:)` with a `[[String]: ResolutionStrategy]`
  dictionary, internally built into an `ArrayTrie`.

### Batched resolution over a `ContentSource`

Because `Node.resolve` fans out across a node's children concurrently, every
level of the walk issues a *wave* of near-simultaneous `fetch` calls. The
`source:` variants (`resolve(paths:source:)`, `resolveRecursive(source:)`,
`resolve(source:)` in `Header+resolve.swift`) exploit this:

- They wrap a batched `ContentSource` (`fetch(_ cids: Set<String>)`) in a
  single `CoalescingFetcher`
  (`Sources/cashew/Fetcher/CoalescingFetcher.swift`) for the whole walk.
- The `CoalescingFetcher` buffers each wave's CIDs and flushes them as
  **one** `ContentSource.fetch`: one round trip per level instead of per
  node.

The per-node resolution logic is unchanged (it still flows through
`fetchAndDecodeNode`, so CID integrity and decryption are identical).
Batching only affects how many round trips occur, never what is fetched.
`CoalescingFetcher` forwards `KeyProvider` to the source, so encrypted
resolution works the same as with a `KeyProvidingFetcher`.

## Volumes

A Volume (`Sources/cashew/Core/Volume.swift`) is defined in the
[README](../README.md#volume): a `Header` that marks a boundary where the
nodes beneath it are treated as a co-located group, an independently
fetchable and retainable unit finer (or coarser) than "the whole tree".

A Volume is a boundary marker. It does not change CIDs, and resolution treats
it exactly like any other `Header`: batching (see
[Batched resolution](#batched-resolution-over-a-contentsource)) handles
locality uniformly, and there is no Volume-specific fetch path. Its role is
on the storage and retention side.

### Storing a Volume

- cashew serializes the complete current boundary and sends one
  `SerializedVolume` to a `VolumeStorer`.
- `SerializedVolume.entries` contains the root, ordinary Header descendants,
  and Header-valued radix values up to the next Volume boundary.
- Empty, targeted, and recursive storage plans choose which nested Volume
  boundaries to cross. The planner uses the same structural and
  compressed-radix paths as resolution
  (`Sources/cashew/Fetcher/Volume+store.swift`).
- Buffering a complete boundary uses temporary memory proportional to that
  boundary's serialized size. Choose smaller Volume boundaries when that
  matters.

Relationships between Volume roots remain encoded in the content-addressed
nodes. Storage does not duplicate them as retention metadata; applications
that retain several related Volumes pin each root explicitly.

The rules a store call keeps are listed in
[cashew invariants](correctness-invariants.md).

### Nested Volumes

Volumes nest, so a tree can carry boundaries at multiple levels.

The `Volume*` data-structure variants push this to its limit. A
`VolumeRadixHeader` (`MerkleDataStructures/VolumeRadixHeader.swift`) is a
`RadixHeader` that is *also* a `Volume`, so **every internal trie link is a
Volume boundary**. A `VolumeMerkleDictionary` is a dictionary whose children
are `VolumeRadixHeader`s, which makes each trie node an independently
pinnable and groupable storage unit, rather than only the outer root.

## The persistence boundary

cashew defines no storage engine. It defines four narrow ports
(`Sources/cashew/Fetcher/`):

```swift
protocol Fetcher: Sendable {           // per-CID read
    func fetch(rawCid: String) async throws -> Data
}

protocol ContentSource: Sendable {     // batched read (the preferred port)
    func fetch(_ cids: Set<String>) async -> [String: Data]
}

protocol Storer: Sendable {           // arbitrary sparse write
    func store(entries: [String: Data]) async throws
}

protocol VolumeStorer: Sendable {     // complete-boundary write
    func store(volume: SerializedVolume) async throws
}
```

| Port | Contract |
| --- | --- |
| `Fetcher` | Maps one CID to bytes. |
| `ContentSource` | Maps a *set* of CIDs to bytes in one call. A networked backend turns each call into a single round trip. |
| `Storer` | Persists an arbitrary verified block set. |
| `VolumeStorer` | Persists one complete storage boundary. |

A backend may implement either or both write contracts. `CoalescingFetcher`
adapts a `ContentSource` to the per-CID `Fetcher` the resolver walks, so
resolution can run over either port. New backends should implement
`ContentSource` to get batching.

cashew's job is the DAG walk and the integrity checks around these calls:

| Operation | Entry point | What cashew does |
| --- | --- | --- |
| Read | `Header.fetchAndDecodeNode(fetcher:)` | Calls `fetcher.fetch`, verifies the returned bytes hash back to the expected CID, decrypts if needed, and decodes the node. `resolve(..., cache:)` writes each fetched block to a `Storer` only after that verification succeeds. |
| Sparse write | `Header.store(paths:storer:)` | Emits exactly the blocks the same `ResolutionStrategy` plan would fetch. Unselected unresolved references are allowed; a selected unresolved Header fails before the batch is emitted. |
| Complete write | `Volume.store(paths:storer:)` or `Volume.storeRecursively(storer:)` | Builds each `SerializedVolume` in memory and verifies every entry before the async sink call, then walks only the selected nested boundaries. |

`Header.storeRecursively(storer:)` stores every reachable block and fails
closed: every reachable Header must be materialized before the batch is
emitted. For a pruned DAG or a sparse Merkle proof, use
`Header.store(paths:storer:)` with the same `ResolutionStrategy` paths that
describe the witnessed or materialized branches.

### Keys

`KeyProvider` (`Sources/cashew/Fetcher/KeyProvider.swift`) maps a key-hash to
a `SymmetricKey`:

```swift
protocol KeyProvider {
    func key(for keyHash: String) -> SymmetricKey?
}
```

A `Fetcher`, `Storer`, or `VolumeStorer` that also conforms to `KeyProvider`
enables transparent decrypt-on-read and encrypt-on-write for encrypted nodes;
the `encryptionInfo.keyHash` selects the key.
[cashew encryption](encryption.md) covers encryption in full.

## End-to-end data flow

### Read

```
caller has a root Header (rawCID only, node == nil)
  → header.resolve(paths: ArrayTrie<ResolutionStrategy>, fetcher:)
      → load this node if absent: fetchAndDecodeNode(fetcher:)
          → fetcher.fetch(rawCid:)                 // CID → bytes
          → verifyData(_:matches:)                 // recompute CID, compare
          → decryptIfNeeded(...)                   // if encryptionInfo present
          → NodeType(data:)                        // DAG-CBOR/JSON decode
      → Node.resolve(paths:fetcher:)               // fan out over properties
          → per property: recurse / targeted-fetch / leave unresolved
  → returns a new Header with the requested subtree's nodes populated,
    same rawCID throughout

Optional: resolve(..., cache: blockStore)
  → verify each fetched block against its CID
  → blockStore.store(entries:)                  // verified read-through cache
```

### Write

```
caller mutates an in-memory Header or Volume root (see data-structures.md, Transforms)
  → newRoot = root.transform(transforms: ArrayTrie<Transform>)
      → only the path from each changed leaf to the root is rebuilt;
        untouched subtrees keep their existing Header (and CID)

Sparse DAG:
  → newRoot.store(paths: resolutionPaths, storer: blockStore)
      → run the same selection walk as resolve(paths:)
      → serialize and verify only selected materialized blocks
      → blockStore.store(entries:)

Complete Volume boundary:
  → newVolume.store(paths: storagePaths, storer: volumeStore)
      → serialize the root and ordinary descendants up to each Volume boundary
      → verify every serialized entry against its CID
      → volumeStore.store(SerializedVolume(...))
      → repeat only for selected nested Volumes
  → the new root CID is the durable handle to the new version
```

Because CIDs are content hashes, the "commit" is implicit: once the bytes for
the new root and its changed path are stored, the new `rawCID`
deterministically addresses the new version, and the old version remains
fully intact and addressable by its own root CID.

## Concurrency and immutability

- All node/header types are value types and `Sendable`; large nodes are
  shared by reference through `Box<T: Sendable>` without breaking value
  semantics.
- Resolution and proof construction fan out with `withThrowingTaskGroup`, so
  independent subtrees are processed concurrently; `SendableBox` carries the
  shared path trie into child tasks.
- Every operation that "changes" a structure returns a new root; nothing is
  mutated in place. This is what makes structural sharing, content
  addressing, and crash-safe versioning compose cleanly.

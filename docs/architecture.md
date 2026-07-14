# cashew Architecture

## 1. Overview

cashew is a content-addressed storage (CAS) library for building persistent,
immutable, Merkle data structures in Swift. It is the persistence substrate
beneath the Lattice blockchain: chain state, block transaction sets, and the
child-chain map are all cashew `MerkleDictionary` trees whose roots are embedded
in blocks as CIDs.

The library is built on three principles:

1. **Content addressing.** Every node is identified by the CID (Content
   Identifier) of its serialized bytes — IPLD DAG-CBOR encoding hashed with
   SHA-256. A node referencing a child stores only the child's CID, so the data
   model is a Merkle DAG: identity is the hash, mutation is impossible, and
   equal content always shares identity.
2. **Lazy resolution.** A reference (`Header`) can carry just a CID with no
   loaded node. Resolution fetches and decodes nodes from a backing store
   on demand, driven by an explicit per-path `ResolutionStrategy`, so a caller
   only materializes the subtree it needs.
3. **Immutable, structurally-shared updates.** Every mutation returns a new root.
   Unchanged subtrees are shared by CID with the original (copy-on-write), so a
   single byte change rewrites only the path from the changed leaf to the root.

For the data structures and algorithms themselves (radix trie, dictionary,
array, set, proofs, diff, transforms, query language), see
[data-structures.md](data-structures.md).

## 2. Package Layout

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

Each behavior (resolve, transform, proof, store, diff, encrypt) is implemented
once as a protocol extension on `Node`/`Header` and refined where a concrete
structure needs structure-aware logic (most often `RadixNode` and
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

## 3. Content-Addressing Model

A node's CID is computed in `Header.computeCID(for:codec:)`
(`Sources/cashew/Core/Header.swift`):

```
data       = DagCBOR.encode(node)            // canonical IPLD DAG-CBOR bytes
multihash  = Multihash(raw: data, .sha2_256) // SHA-256 of the bytes
cid        = CID(version: .v1, codec: .dag_cbor, multihash: multihash)
rawCID     = cid.toBaseEncodedString          // the stored string identifier
```

DAG-CBOR encoding (`Sources/cashew/Core/DagCBOR.swift`) is a native CBOR encoder
that serializes map entries with deterministically sorted keys (by byte length,
then lexicographically), so the serialization is canonical: the same logical node
always produces the same bytes and therefore the same CID on every platform. The
radix/dictionary structures reinforce this by encoding their child maps as a
`children` array of `SortedEntry { key, value }` sorted by key
(`Sources/cashew/MerkleDataStructures/SortedEntry.swift`), avoiding
unordered-dictionary nondeterminism.

`Codecs` is the multicodec enum from `swift-multicodec`; cashew defaults to
`.dag_cbor` (`Header.defaultCodec`) and exposes a small `ipldCodecs` convenience
list in `Sources/cashew/Core/MulticodecExtensions.swift`. Nodes can also serialize
to JSON via `toJSON()` / `description`, and decode from either DAG-CBOR or JSON
(`Node.init(data:)`).

Because a child is referenced purely by CID, the whole structure is a Merkle DAG.
Two important consequences:

- **Integrity on read.** When a `Header` fetches its bytes, it recomputes the
  CID and compares (`Header.verifyFetchedData(_:matches:)`); a mismatch throws
  `DataErrors.cidMismatch`. The store cannot serve corrupted or wrong data
  undetected.
- **Deduplication.** Identical subtrees collapse to one CID, so structural
  sharing across versions (and across keys) is automatic.

## 4. Protocol / Impl Hierarchy

cashew separates *abstract structure* (protocols, with default behavior in
extensions) from *concrete representation* (`*Impl` structs that supply storage
and `Codable`). This lets the Lattice node define its own header/value types
while reusing all traversal, resolution, proof, and transform logic.

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

- **`Node`** requires only `get(property:)`, `properties()`, and
  `set(properties:)`. Everything else — `resolve`, `transform`, `proof`,
  `storeVolumes`, `encrypt`, and the whole query interface — is a default
  protocol-extension implementation. `Codable` and `LosslessStringConvertible`
  are derived from DAG-CBOR/JSON serialization.
- **`Header`** pairs a `rawCID` with an optional in-memory `node`. When `node`
  is `nil` the header is an unresolved reference; when present, the data is in
  memory. `encryptionInfo` is non-nil iff the referenced bytes are encrypted.
- **`HeaderImpl<NodeType>`** is the ready-made concrete header. It stores the
  node in a heap-allocated `Box<NodeType>` so the value-type struct stays
  `Sendable` while sharing a potentially large node by reference. Its `Codable`
  conformance encodes only `rawCID` and `encryptionInfo` — never the node —
  so serializing a header serializes a *reference*, not the subtree.

The radix family is mutually recursive at the type level:
`RadixHeader.NodeType.ChildType == Self`, i.e. a header's node's children are
headers of the same type. This is what makes a single `RadixHeaderImpl<Value>`
the entry point to an arbitrarily deep, uniformly-typed trie.

## 5. Lazy Resolution

A freshly decoded `Header` holds only `rawCID` (`node == nil`). Resolution turns
references into loaded nodes on demand. The driver is `ResolutionStrategy`
(`Sources/cashew/Resolver/ResolutionStrategy.swift`):

| Strategy | Effect |
|----------|--------|
| `.targeted` | Fetch exactly this header (CID → node), no descent. |
| `.recursive` | Transitively resolve every reachable header in the subtree. |
| `.list` | Resolve the trie *structure* so keys are enumerable, but leaf header values stay `node == nil`. |
| `.range(after:limit:)` | Like `.list`, but only materialize up to `limit` keys after the `after` cursor. |

Resolution paths are carried as an `ArrayTrie<ResolutionStrategy>` (from the
`ArrayTrie` package): each path of property keys maps to the strategy to apply
there. `Header.resolve(paths:fetcher:)`
(`Sources/cashew/Resolver/Header+resolve.swift`) loads its own node if needed,
then delegates to `Node.resolve(paths:fetcher:)`
(`Sources/cashew/Resolver/Node+resolve.swift`), which fans out over the node's
properties in a `withThrowingTaskGroup` — sibling subtrees resolve concurrently.
For each property it either recurses (`.recursive`), descends into the remaining
sub-paths, fetches a single header (`.targeted` at a leaf path), or leaves the
reference unresolved.

Resolution is purely additive and immutable: it returns a new node/header with
the same `rawCID` but a populated `node`, via
`Self(rawCID: rawCID, node: resolvedNode, encryptionInfo: encryptionInfo)`. A
resolved node never has a different CID than its unresolved form.

Convenience entry points (`Header+resolve.swift`):

- `resolve(fetcher:)` — load just this node (`.targeted`).
- `resolveRecursive(fetcher:)` — load the whole subtree.
- `resolve(paths:fetcher:)` with a `[[String]: ResolutionStrategy]` dictionary,
  internally built into an `ArrayTrie`.

### Batched resolution over a `ContentSource`

Because `Node.resolve` fans out across a node's children concurrently, every
level of the walk issues a *wave* of near-simultaneous `fetch` calls. The
`source:` variants — `resolve(paths:source:)`, `resolveRecursive(source:)`,
`resolve(source:)` (`Header+resolve.swift`) — exploit this: they wrap a batched
`ContentSource` (`fetch(_ cids: Set<String>)`) in a single `CoalescingFetcher`
(`Sources/cashew/Fetcher/CoalescingFetcher.swift`) for the whole walk, which
buffers each wave's CIDs and flushes them as **one** `ContentSource.fetch` — one
round trip per level instead of per node. The per-node resolution logic is
unchanged (it still flows through `fetchAndDecodeNode`, so CID integrity and
decryption are identical); batching only affects how many round trips occur,
never what is fetched. `CoalescingFetcher` forwards `KeyProvider` to the source,
so encrypted resolution works the same as with a `KeyProvidingFetcher`.

## 6. Volumes and Data Locality

A **Volume** (`Sources/cashew/Core/Volume.swift`) is a `Header` that marks a
semantically important boundary in the DAG where the nodes beneath it should be
treated as a co-located group — an independently fetchable/retainable unit
finer (or coarser) than "the whole tree". A Volume is a **boundary marker**: it
does not change CIDs, and resolution treats it exactly like any other `Header`
(batching, see §5, handles locality uniformly — there is no Volume-specific
fetch path). Its behavioral role is on the **storage/retention** side:

- On storage, Cashew serializes the complete current boundary and sends one
  `SerializedVolume` to a `VolumeStorer`. Empty, targeted, and recursive storage
  plans choose which nested Volume boundaries to cross. The planner uses the same
  structural and compressed-radix paths as resolution
  (`Sources/cashew/Fetcher/Volume+store.swift`).

- Relationships between Volume roots remain encoded in the content-addressed
  nodes. Storage does not duplicate them as retention metadata;
  applications that retain several related Volumes pin each root explicitly.

Volumes nest, so a tree can carry boundaries at multiple levels.

The `Volume*` data-structure variants push this to its limit. A
`VolumeRadixHeader` (`MerkleDataStructures/VolumeRadixHeader.swift`) is a
`RadixHeader` that is *also* a `Volume`, so **every internal trie link is a
Volume boundary**. A `VolumeMerkleDictionary` is a dictionary whose children are
`VolumeRadixHeader`s — making each trie node an independently
pinnable/groupable storage unit, rather than only the outer root.

## 7. The Persistence Boundary

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

A `Fetcher` maps one CID → bytes; a `ContentSource` maps a *set* of CIDs →
bytes in one call (a networked backend turns each into a single round trip);
`Storer` persists an arbitrary verified block set; and `VolumeStorer` persists
one complete storage boundary. A backend may implement either or both write
contracts. `CoalescingFetcher` adapts a
`ContentSource` to the per-CID `Fetcher` the resolver walks (see §5), so
resolution can run over either port; new backends should implement
`ContentSource` to get batching.
cashew's job is the DAG walk and the integrity checks around these calls:

- **Read.** `Header.fetchAndDecodeNode(fetcher:)` calls `fetcher.fetch`,
  verifies the returned bytes hash back to the expected CID, decrypts if needed,
  and decodes the node. `resolve(..., cache:)` writes each fetched block to a
  `Storer` only after that verification succeeds.
- **Sparse write.** `Header.store(paths:storer:)` emits exactly the blocks the
  same `ResolutionStrategy` plan would fetch. Unselected unresolved references
  are allowed; a selected unresolved Header fails before the batch is emitted.
- **Complete write.** `Volume.store(paths:storer:)` or
  `Volume.storeRecursively(storer:)`. It builds each `SerializedVolume` in memory
  and verifies every entry before the async sink call, then walks only the
  selected nested boundaries.

`KeyProvider` (`Sources/cashew/Fetcher/KeyProvider.swift`) maps a key-hash to a
`SymmetricKey`. A `Fetcher`, `Storer`, or `VolumeStorer` that also conforms to `KeyProvider`
enables transparent decrypt-on-read / encrypt-on-write for encrypted nodes; the
`encryptionInfo.keyHash` selects the key.

```swift
protocol KeyProvider {
    func key(for keyHash: String) -> SymmetricKey?
}
```

## 8. End-to-End Data Flow

### 8.1 Read

```
caller has a root Header (rawCID only, node == nil)
  → header.resolve(paths: ArrayTrie<ResolutionStrategy>, fetcher:)
      → load this node if absent: fetchAndDecodeNode(fetcher:)
          → fetcher.fetch(rawCid:)                 // CID → bytes
          → verifyFetchedData(_:matches:)          // recompute CID, compare
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

### 8.2 Write

```
caller mutates an in-memory Header or Volume root (see data-structures.md §Transforms)
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

Because CIDs are content hashes, the "commit" is implicit: once the bytes for the
new root and its changed path are stored, the new `rawCID` deterministically
addresses the new version, and the old version remains fully intact and
addressable by its own root CID.

## 9. Concurrency and Immutability

- All node/header types are value types and `Sendable`; large nodes are shared
  by reference through `Box<T: Sendable>` without breaking value semantics.
- Resolution and proof construction fan out with `withThrowingTaskGroup`, so
  independent subtrees are processed concurrently; `SendableBox` carries the
  shared path trie into child tasks.
- Every operation that "changes" a structure returns a new root; nothing is
  mutated in place. This is what makes structural sharing, content addressing,
  and crash-safe versioning compose cleanly.

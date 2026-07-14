# cashew Data Structures

This document specifies the data structures cashew provides and the algorithms
that operate on them. For how the library is assembled, the content-addressing
model, lazy resolution, Volumes, and the persistence boundary, see
[architecture.md](architecture.md).

Throughout, *protocol* means an abstract type with default behavior in
extensions, and *Impl* means a concrete `struct` that supplies storage and
`Codable`. The relationships are summarized in
[architecture.md §4](architecture.md#4-protocol--impl-hierarchy).

## 1. The Radix Trie

Every collection in cashew is built on a compressed (path-compressed) radix
trie. The trie node is `RadixNode`
(`Sources/cashew/MerkleDataStructures/RadixNode.swift`); the CID-bearing
reference to a node is `RadixHeader`
(`Sources/cashew/MerkleDataStructures/RadixHeader.swift`).

```swift
protocol RadixNode: Node {
    associatedtype ChildType: RadixHeader where ChildType.NodeType == Self
    associatedtype ValueType: LosslessStringConvertible
    var prefix: String { get }                    // compressed edge label
    var value: ValueType? { get }                 // value if a key ends here
    var children: [Character: ChildType] { get }   // keyed by next character
    init(prefix:value:children:)
}

protocol RadixHeader: Header
    where NodeType: RadixNode, NodeType.ChildType == Self {}
```

The concrete pair is `RadixNodeImpl<Value>` / `RadixHeaderImpl<Value>`, mutually
bound so a header's node's children are headers of the same type.

**Key layout.** A key is a string. Each node carries a `prefix` — the shared
edge label for the subtree — and a `children` map keyed by the *next* character
after that prefix. A node holds a `value` iff some key terminates exactly at that
node. Path compression means a chain of single-child nodes is collapsed into one
node with a longer `prefix`; conversely, inserting a key that diverges mid-prefix
*splits* a node into a common-prefix parent plus two children.

The four structural cases are computed by `compareSlices` (in `Core/Node.swift`)
between a key remainder and a node's `prefix`: equal (0), key extends prefix (1),
prefix extends key (2), or divergent (3). The insert/delete/lookup logic in
`Sources/cashew/Transform/RadixNode+transform.swift` branches on these:

- **Lookup** (`get(key:)`): walk down, stripping each matched prefix, following
  `children[nextChar]`, until the key is exhausted or a branch is missing.
- **Insert** (`inserting(key:value:)`):
  - case 0 — set the value at this node (error if one already exists);
  - case 1 — recurse into / create the child for the next character;
  - case 2 — split: the existing node becomes a child under the new shorter
    key, which now carries the inserted value;
  - case 3 — split on the common prefix into a value-less branch node with two
    children (the existing subtree and the new leaf).
- **Delete** (`deleting(key:)`): remove the value/branch and `collapsed(...)` the
  node — a node with one child and no value is merged back into that child
  (the inverse of a split), keeping the trie canonical.

`collapsed(prefix:children:)` is the canonicalization invariant: no value-less
single-child interior nodes are allowed to persist, so a given key set always
produces exactly one trie shape — and therefore one root CID.

**Deterministic serialization.** `RadixNodeImpl` encodes its `children` as a
`[SortedEntry<ChildType>]` sorted by key character
(`Sources/cashew/MerkleDataStructures/SortedEntry.swift`), not as an unordered
map, so encoding is reproducible across platforms (see
[architecture.md §3](architecture.md#3-content-addressing-model)).

## 2. MerkleDictionary

`MerkleDictionary` (`Sources/cashew/MerkleDataStructures/MerkleDictionary.swift`)
is the string→value map that fronts the radix trie. The root is *not* itself a
`RadixNode`; it is a thin node holding the top-level `children: [Character: ChildType]`
and an explicit element `count`.

```swift
protocol MerkleDictionary: Node {
    associatedtype ValueType
    associatedtype ChildType: RadixHeader where ChildType.NodeType.ValueType == ValueType
    var children: [Character: ChildType] { get }
    var count: Int { get }
    init(children:count:)
}
```

Concrete: `MerkleDictionaryImpl<Value>` where
`Value: Codable & Sendable & LosslessStringConvertible`, with
`ChildType = RadixHeaderImpl<Value>`.

Operations (all returning a new structurally-shared root):

- `get(key:) -> ValueType?` — dispatch on the first character into the trie.
- `inserting(key:value:)` — `count + 1`; throws on empty key.
- `deleting(key:)` — `count - 1`; throws if the key is absent.
- `mutating(key:value:)` — replace an existing value; `count` unchanged.
- `allKeys()` / `allKeysAndValues()` — full enumeration; require the subtree to
  be resolved (throw `DataErrors.nodeNotAvailable` on an unresolved child).
- `sortedKeys(limit:after:)` / `sortedKeysAndValues(limit:after:)` — ordered,
  paginated enumeration walking `children.keys.sorted()` and reconstructing each
  full key as `currentPath + node.prefix`.

The `count` is maintained incrementally by the insert/delete operations rather
than recomputed.

## 3. MerkleArray

`MerkleArray` (`Sources/cashew/MerkleDataStructures/MerkleArray.swift`) is an
append-only ordered collection that *is* a `MerkleDictionary`
(`protocol MerkleArray: MerkleDictionary`). Concrete: `MerkleArrayImpl<Value>`.

It stores element *i* under a fixed 256-bit binary string key produced by
`binaryKey(_ index: Int)` — a 256-character string of `'0'`/`'1'` with the index
in the low bits. Because these keys are fixed-width, lexicographic order in the
underlying trie equals numeric index order, which is what makes ordered
enumeration and range scans correct.

- `append(_:)` — insert at `binaryKey(count)`.
- `get(at:)` — bounds-check against `count`, then `get(key: binaryKey(index))`.
- `first()` / `last()` — `get(at: 0)` / `get(at: count - 1)`.
- `append(contentsOf:)` — appends each element of another array in index order.

## 4. MerkleSet

`MerkleSet` (`Sources/cashew/MerkleDataStructures/MerkleSet.swift`) is a
`MerkleDictionary` specialized to `ValueType == String` that stores each member
as a key with the empty string `""` as its value. Concrete: `MerkleSetImpl`.

- `insert(_:)` → `inserting(key: member, value: "")`
- `remove(_:)` → `deleting(key: member)`
- `contains(_:)` → `get(key:) != nil`
- `members()` → `allKeys()`
- Set algebra: `union`, `intersection`, `subtracting`, `symmetricDifference`,
  each implemented in terms of the membership operations above and returning a
  new set.

## 5. Sparse Merkle Proofs

A proof is a *pruned tree*: the same `Header`/`Node` types, resolved only along
the witness paths needed to verify a claim about a set of keys, with everything
else left as bare CIDs. Verification is therefore recomputing the root CID from
the pruned tree and comparing it to the trusted root.

The requested proof kind per key is `SparseMerkleProof`
(`Sources/cashew/Proofs/SparseMerkleProof.swift`):

```swift
enum SparseMerkleProof: Int, Codable, Sendable {
    case insertion = 1, mutation, deletion, existence
}
```

Proofs are requested as an `ArrayTrie<SparseMerkleProof>` and built by
`proof(paths:fetcher:)`:

- **Entry** — `Header.proof(paths:fetcher:)`
  (`Sources/cashew/Proofs/Header+proofs.swift`) loads its node if needed and
  delegates to the node's `proof`.
- **Dictionary / trie** — `MerkleDictionary.proofForChildren`
  (`Sources/cashew/Proofs/MerkleDictionary+proofs.swift`) and
  `RadixNode.proof` (`Sources/cashew/Proofs/RadixNode+proofs.swift`) descend the
  requested paths, resolving children that lie on a witness path and *keeping
  the rest unresolved* (as CIDs). Sibling descent runs concurrently in a task
  group.

The proof kind constrains what the tree must look like, and the builder
validates it as it descends:

| Kind | Meaning | Validity checked during build |
|------|---------|-------------------------------|
| `existence` | The key is present with its value. | always allowed. |
| `mutation` | The key exists and may be updated. | the node at the prefix must have a non-nil `value`. |
| `insertion` | The key is absent and may be inserted. | the node at the prefix must have a `nil` value. |
| `deletion` | The key exists and may be deleted. | additionally resolves the node's grandchildren so the post-delete `collapsed(...)` shape can be reconstructed and re-hashed. |

Requesting a `deletion`/`mutation` proof for a key that is not on a real path
throws `ProofErrors.invalidProofType` — you cannot forge a proof of a
non-existent edit. At the dictionary level a proof type may only be `.mutation`
or `.existence` directly at a node boundary; per-property checks in
`Node.proof` (`Sources/cashew/Proofs/Node+proofs.swift`) enforce this.

Because a proof is just a partially-resolved tree of the ordinary types, a
verifier resolves nothing further: it re-serializes the pruned nodes, recomputes
each CID bottom-up, and accepts the proof iff the computed root CID equals the
expected one. The `deletion` case additionally pulls in grandchildren so the
verifier can apply the deletion locally and confirm the resulting root.

## 6. Diffing

`CashewDiff` (`Sources/cashew/Diff/CashewDiff.swift`) is the structural
difference between two `MerkleDictionary` roots:

```swift
struct CashewDiff {
    var inserted: [String: String]              // key → new value
    var deleted:  [String: String]              // key → old value
    var modified: [String: ModifiedEntry]        // key → { old, new, children }
}
```

`MerkleDictionary.diff(from old:)`
(`Sources/cashew/Diff/MerkleDictionary+diff.swift`) enumerates both sides with
`allKeysAndValues()` and compares:

- keys only in the new tree → `inserted`;
- keys only in the old tree → `deleted`;
- keys in both whose stringified values differ → `modified`. When the values are
  themselves `Header`s (a nested structure), the entry records the old/new child
  CIDs and recurses into a child `CashewDiff` (`ModifiedEntry.children`), so a
  diff of nested dictionaries is itself nested.

`changeCount` counts leaf changes (descending into nested `modified` children),
and `description` renders a human-readable `+`/`-`/`~` tree. Diffing is a derived
read over resolved trees; it performs no fetching itself.

## 7. Transforms (Batch Mutation)

A `Transform` (`Sources/cashew/Transform/Transform.swift`) is one of:

```swift
enum Transform: Equatable { case insert(String), update(String), delete }
```

The payload string is the value's `LosslessStringConvertible` description; it is
parsed back into `ValueType` during application. A *batch* of transforms is an
`ArrayTrie<Transform>` keyed by target key, applied in one pass over the trie by
`transform(transforms:keyProvider:)`:

- **Dictionary level** (`Sources/cashew/Transform/MerkleDictionary+transform.swift`):
  computes the net `count` delta (`+1` per insert, `-1` per delete), then visits
  the union of existing child characters and transform child characters,
  recursing into existing children, creating new subtrees for new characters via
  `RadixNode.insertAll`, and dropping children that transform away to empty.
- **Trie level** (`Sources/cashew/Transform/RadixNode+transform.swift`): the same
  four `compareSlices` cases as single-key insert/delete, generalized to apply a
  *subtree* of transforms at once — `transformExactMatch`, `transformChildLonger`,
  `transformPrefixLonger`, `transformDivergent` — each preserving the
  `collapsed(...)` canonicalization so the result is the unique trie for the
  resulting key set.

A `delete` errors if there is no value to remove; an `insert` errors if a value
already exists; `update` requires an existing value. There is also a specialized
overload for the case where `ValueType` is itself a `Header` wrapping a nested
`MerkleDictionary`, which lets a batch reach *through* a value into a nested
dictionary (creating an empty nested dictionary on demand).

Transforms are the bridge from a high-level edit to a new structurally-shared
root: only the paths from changed leaves to the root are rebuilt; untouched
subtrees keep their existing headers and CIDs. The optional `keyProvider`
re-encrypts rewritten nodes whose originals were encrypted (see §9).

## 8. Per-Node Encryption

Encryption is applied selectively across a subtree via an
`ArrayTrie<EncryptionStrategy>`. `EncryptionStrategy`
(`Sources/cashew/Encryption/EncryptionStrategy.swift`):

```swift
enum EncryptionStrategy {
    case targeted(SymmetricKey)    // explicitly marked leaf values
    case list(SymmetricKey)        // direct children, one level
    case recursive(SymmetricKey)   // the entire subtree
}
```

`Node.encrypt(encryption:)` (`Sources/cashew/Encryption/Node+encrypt.swift`)
walks the structure and re-wraps the selected headers as encrypted headers.
Encrypting a node serializes it (DAG-CBOR), AES-256-GCM-seals the bytes with the
strategy's key (`EncryptionHelper`, `Sources/cashew/Core/EncryptionHelper.swift`),
and computes the CID over the *ciphertext*. The header records an
`EncryptionInfo { keyHash, iv }` (`Sources/cashew/Core/EncryptionInfo.swift`) —
the SHA-256 hash of the key (for key lookup) and the GCM nonce.

On read, `Header.decryptIfNeeded` uses the `Fetcher`-as-`KeyProvider` to look up
the key by `keyHash` and decrypt before decoding. On write,
`Header.store` and `Volume.store` re-seal from `encryptionInfo` using the same
nonce so the stored ciphertext (and thus the CID) is stable. Encrypted and plaintext
nodes coexist in the same tree; only headers with non-nil `encryptionInfo` are
encrypted, and a header's textual form is `enc:<keyHash>:<iv>:<cid>`.

## 9. The Query Language

cashew ships a small pipe-delimited query language over any `Node`. The pipeline
is **parse → compile → execute**:

```
input string  ──CashewParser.parse──▶  [CashewExpression]
              ──CashewPlan.compile──▶  CashewPlan (steps)
              ──Node.execute(plan:)──▶  (newNode, CashewResult)
```

### 9.1 Grammar

`CashewParser` (`Sources/cashew/Query/CashewParser.swift`) tokenizes into words,
quoted strings (`"..."`/`'...'`, with `\` escapes), integers, `=`, and `|`, then
parses each `|`-separated segment into a `CashewExpression`
(`Sources/cashew/Query/CashewExpression.swift`). Command words are
case-insensitive (lowercased during tokenization). Supported commands:

| Syntax | Expression | Notes |
|--------|-----------|-------|
| `get "key"` | `.get(key)` | quoted key required |
| `get at <n>` | `.getAt(n)` | array index |
| `keys` / `members` | `.keys` | |
| `keys sorted [limit <n>] [after "cur"]` | `.sortedKeys(limit:after:)` | |
| `values` | `.values` | |
| `values sorted [limit <n>] [after "cur"]` | `.sortedValues(limit:after:)` | |
| `count` / `size` | `.count` | |
| `contains "k"` / `has "k"` | `.contains(k)` | |
| `first` / `last` | `.first` / `.last` | |
| `insert "k" = "v"` / `add ...` | `.insert(key:value:)` | |
| `update "k" = "v"` | `.update(key:value:)` | |
| `set "k" = "v"` / `put ...` | `.set(key:value:)` | insert-or-update |
| `delete "k"` / `remove "k"` | `.delete(k)` | |
| `append "v"` | `.append(v)` | array |

### 9.2 Compilation

`CashewPlan.compile` (`Sources/cashew/Query/CashewPlan.swift`) folds the
expression list into a sequence of `CashewStep`s:

```swift
enum CashewStep { case transform(ArrayTrie<Transform>); case evaluate(CashewExpression) }
```

`insert`/`update`/`delete` are accumulated into a single
`ArrayTrie<Transform>` and flushed as one `.transform` step — so adjacent writes
collapse into one batched trie pass (a new write to an already-touched key forces
a flush first, preserving order). Every other expression becomes an `.evaluate`
step. `CashewPlan.resolutionPaths()` additionally derives the
`ArrayTrie<ResolutionStrategy>` needed to run the plan against a remote store
(e.g. `get`/`contains`/`set` → `.targeted` at that key; `keys`/`values` →
`.recursive`; `count` → `.list`).

### 9.3 Execution

`Node.execute(plan:)` (`Sources/cashew/Query/CashewExecutor.swift`) threads a
`current` node through the steps. A `.transform` step replaces `current` with the
transformed root. An `.evaluate` step calls `evaluate(_:)`, which returns a
`(newNode, CashewResult)`:

```swift
enum CashewResult { case value(String?), bool(Bool), count(Int),
                    list([String]), entries([(key,value)]), node(AnyQueryable), ok }
```

When evaluation yields `.node(child)` (a nested header/value), execution
*descends*: it runs the remaining steps against the child and returns that
result — this is how `get "outer" | get "inner"` traverses nested structures.
`MerkleDictionary` and `MerkleArray` override `evaluate` to use their key-based
operations (`evaluateExpression` in the executor) rather than the generic
property-based defaults; `MerkleDictionary.execute(plan:fetcher:)` first resolves
the plan's `resolutionPaths()` against the `Fetcher`, then runs the plan
in-memory.

### 9.4 Example

```swift
let dict = MerkleDictionaryImpl<String>()       // string → string
let (updated, _)   = try dict.query("insert \"alice\" = \"100\" | insert \"bob\" = \"50\"")
let (_, balance)   = try updated.query("get \"alice\"")        // .value("100")
let (_, size)      = try updated.query("count")               // .count(2)
let (_, sorted)    = try updated.query("keys sorted limit 10") // .list(["alice","bob"])
```

The first query compiles both inserts into one batched `.transform` step,
producing a new root that shares the unchanged subtree with the original. The
later queries are pure reads. (`get` on a `MerkleDictionaryImpl<String>` returns
`.value`; if the value type were a `Header`, `get` would instead return
`.node(...)` and a subsequent piped command would descend into it.)

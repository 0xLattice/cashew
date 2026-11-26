# cashew encryption

How to encrypt parts of a cashew tree and keep the rest public. Encryption is
optional and chosen per path: each selected node is sealed with AES-GCM, and
its CID becomes the hash of the ciphertext.

## When to use it

Anyone with access to a content-addressed store can read every value in it.
Encryption lets you hide parts of a tree from them.

- **Shared storage, private data.** Several parties share one store, and each
  party's data is readable only by holders of that party's key.
- **Selective disclosure.** Some fields in a record are public (a username),
  others are private (an email). Encrypt only the private fields.
- **A key per subtree.** Different branches of a tree can use different keys,
  for per-user or per-tenant encryption within one data structure.
- **Auditability without readability.** An auditor can verify that the tree
  is intact (CIDs still chain correctly) without being able to decrypt the
  values.

## How it works

### CIDs of encrypted nodes

Without encryption:

```
CID = SHA-256(serialize(node))
```

With encryption:

```
CID = SHA-256(AES-GCM(serialize(node), key, iv))
```

The CID is a hash of the *ciphertext*, so the content-addressing guarantee
still holds: fetched bytes are checked against the CID. You cannot read the
content without the key.

Each encryption generates a random initialization vector (IV) with
`AES.GCM.Nonce()`. Two rules follow:

| Case | CID |
| --- | --- |
| The same plaintext encrypted twice, even with the same key | Two different ciphertexts, so two different CIDs. |
| One encrypted header serialized again, with its recorded key and IV | The same ciphertext, so the same CID. |

The first rule is intentional. It prevents an observer from detecting that
two encrypted headers contain the same plaintext, and re-encrypting produces
a new CID that cannot be linked to the earlier one. The trade-off is that you
cannot compare CIDs to check whether two encrypted headers contain the same
data.

### Encryption metadata

An encrypted header carries `EncryptionInfo { keyHash, iv }`
(`Sources/cashew/Core/EncryptionInfo.swift`):

| Field | Value |
| --- | --- |
| `keyHash` | `base64(SHA256(raw_key_bytes))`, used to look up the key. |
| `iv` | The base64 AES-GCM nonce. |

This is enough to find the correct key and decrypt later. The key itself is
never stored in the header. The hash is a one-way derivation, so it is safe
to store alongside encrypted data.

Encrypted and plaintext nodes coexist in the same tree: only headers with
non-nil `encryptionInfo` are encrypted.

### Encrypt, store, resolve

```
              encrypt                   store                      resolve
  plaintext  -------->  encrypted   ---------->  store      <---------  encrypted
  Volume      (key)     Volume       (VolumeStorer (Volumes)  (fetcher +  Volume
                        + EncryptionInfo + KeyProvider)          KeyProvider)
                                                                  |
                                                                  v
                                                             plaintext
                                                             Volume
```

1. **Encrypt.** Apply an `ArrayTrie<EncryptionStrategy>` to a header tree
   with `encrypt(encryption:)` (`Sources/cashew/Encryption/`). Each selected
   header's node is serialized (DAG-CBOR) and sealed with AES-GCM under the
   strategy's key and a random IV (`EncryptionHelper`,
   `Sources/cashew/Core/EncryptionHelper.swift`). The CID changes to the hash
   of the ciphertext.
2. **Store.** Call `Volume.store(storer:)` or `storeRecursively(storer:)`.
   The `VolumeStorer` must also conform to `KeyProvider` so it can look up
   the key by hash. The header does not cache its encrypted bytes: storing
   re-encrypts the node with the IV in `encryptionInfo`. AES-GCM is
   deterministic for one (key, nonce, plaintext) triple, so this reproduces
   the same ciphertext and its hash matches the header's CID.
3. **Resolve.** Fetch data by CID. The fetcher (conforming to
   `KeyProvidingFetcher`) provides the decryption key, and `decryptIfNeeded`
   decrypts before deserialization.

## Encrypt a single header

```swift
import Crypto

let key = SymmetricKey(size: .bits256)
let scalar = MyScalar(value: 42)

// Plaintext header: CID is hash of serialized scalar
let plainHeader = try HeaderImpl(node: scalar)

// Encrypted header: CID is hash of encrypted serialized scalar
let encHeader = try HeaderImpl(node: scalar, key: key)

// The encrypted header carries metadata for decryption
encHeader.encryptionInfo?.keyHash  // base64(SHA256(key))
encHeader.encryptionInfo?.iv       // base64(random nonce)
```

### Text form

An encrypted header serializes to a string that preserves the encryption
metadata, `enc:<keyHash>:<iv>:<cid>`:

```swift
let enc = try HeaderImpl(node: scalar, key: key)
enc.description
// "enc:abc123...==:def456...==:bafyrei..."
//       keyHash       iv        rawCID

// Round-trips through LosslessStringConvertible
let restored = HeaderImpl<MyScalar>(enc.description)!
restored.rawCID == enc.rawCID            // true
restored.encryptionInfo == enc.encryptionInfo  // true
```

A plaintext header serializes as the bare CID string.

## Store and resolve encrypted data

Sparse and Volume stores must be able to look up keys by their hash when
serializing encrypted materialized nodes. Implement `KeyProvider` on the
`Storer` or `VolumeStorer`, or `KeyProvidingFetcher` for reads:

```swift
class MyStoreFetcher: Storer, VolumeStorer, Fetcher, KeyProvider {
    private var storage: [String: Data] = [:]
    private var keys: [String: SymmetricKey] = [:]

    func registerKey(_ key: SymmetricKey) {
        let keyData = key.withUnsafeBytes { Data($0) }
        let hash = Data(SHA256.hash(data: keyData)).base64EncodedString()
        keys[hash] = key
    }

    func key(for keyHash: String) -> SymmetricKey? { keys[keyHash] }
    func store(entries: [String: Data]) async {
        storage.merge(entries) { _, new in new }
    }
    func store(volume: SerializedVolume) async {
        storage.merge(volume.entries) { _, new in new }
    }
    func fetch(rawCid: String) async throws -> Data {
        guard let data = storage[rawCid] else { throw MyError.notFound }
        return data
    }
}
```

Store and resolve:

```swift
let fetcher = MyStoreFetcher()
fetcher.registerKey(key)

// Store an encrypted Volume boundary
let encVolume = try VolumeImpl(node: scalar, key: key)
try await encVolume.store(storer: fetcher)

// Resolve from just the CID + encryption metadata
let cidOnly = VolumeImpl<MyScalar>(
    rawCID: encVolume.rawCID,
    node: nil,
    encryptionInfo: encVolume.encryptionInfo
)
let resolved = try await cidOnly.resolve(fetcher: fetcher)
resolved.node!  // decrypted scalar
```

The examples below reuse this `fetcher`.

## Encrypt selected paths

Instead of encrypting the entire tree, encrypt specific paths:

```swift
var dict = MerkleDictionaryImpl<HeaderImpl<MyScalar>>()
dict = try dict.inserting(key: "public-field", value: HeaderImpl(node: MyScalar(value: 1)))
dict = try dict.inserting(key: "secret-field", value: HeaderImpl(node: MyScalar(value: 2)))
let volume = try VolumeImpl(node: dict)

// Only encrypt the value at "secret-field"
var encryption = ArrayTrie<EncryptionStrategy>()
encryption.set(["secret-field"], value: .targeted(key))
let encrypted = try volume.encrypt(encryption: encryption)

// "public-field" is still readable without any key
let publicVal = try encrypted.node!.get(key: "public-field")!
publicVal.encryptionInfo  // nil: plaintext

// "secret-field" requires the key to read
let secretVal = try encrypted.node!.get(key: "secret-field")!
secretVal.encryptionInfo  // non-nil: encrypted
```

## Encryption strategies

Strategies are given as an `ArrayTrie<EncryptionStrategy>`, where paths in
the trie map to parts of the Merkle dictionary's key space. The path `[""]`
is the root.

| Strategy | Trie structure (RadixHeaders) | Values |
| --- | --- | --- |
| `.targeted(key)` at the root | Encrypted | Encrypted only where a sub-path targets them |
| `.targeted(key)` at a key's path | Plaintext on the way to that key | Only the value at that path is encrypted |
| `.list(key)` | Encrypted | Plaintext |
| `.recursive(key)` | Encrypted | All encrypted |

When the trie structure is encrypted, you cannot enumerate keys or navigate
the trie without the key.

### targeted(key)

Encrypts the **trie structure** (RadixHeaders) and the **values** at
specifically targeted sub-paths. When applied at the root (`[""]`), the
entire trie is encrypted: you cannot enumerate keys without the key. Values
are only encrypted if a sub-path override targets them.

When applied at a specific path (e.g., `["alice"]`), only the value at that
path is encrypted; the trie structure leading to it stays plaintext.

```swift
// Root targeted: encrypts trie structure, values stay plaintext
var encryption = ArrayTrie<EncryptionStrategy>()
encryption.set([""], value: .targeted(key))
let encrypted = try volume.encrypt(encryption: encryption)

// You CANNOT see what keys exist without the key
// After decrypting the trie, values are plaintext CIDs

// Path-specific targeted: encrypts only the value at that path
var encryption2 = ArrayTrie<EncryptionStrategy>()
encryption2.set(["alice"], value: .targeted(key))
let encrypted2 = try volume.encrypt(encryption: encryption2)

// You CAN see that "alice" exists as a key
// You CANNOT read the value at "alice" without the key
// "bob" (if it exists) is completely unaffected
```

**Use case**: Encrypt the trie structure while selectively encrypting
specific values. Like encrypting a database's row index while also encrypting
the "ssn" column but leaving "name" readable.

### list(key)

Encrypts the **trie structure** (RadixHeaders). You cannot enumerate keys or
navigate the trie without decrypting first. Values at each key remain as
plaintext CIDs.

```swift
var encryption = ArrayTrie<EncryptionStrategy>()
encryption.set([""], value: .list(key))
let encrypted = try volume.encrypt(encryption: encryption)

// You CANNOT see what keys exist without the key
// After decrypting the trie structure, values are plaintext CIDs
```

**Use case**: Hide the set of keys in a dictionary. An observer can't tell
what entries exist, but once they have the key, the values themselves don't
need further decryption.

### recursive(key)

Encrypts **everything**, both the trie structure and all values, with the
same key. This is the most private option. Nothing is readable without the
key.

```swift
var encryption = ArrayTrie<EncryptionStrategy>()
encryption.set([""], value: .recursive(key))
let encrypted = try volume.encrypt(encryption: encryption)

// Nothing is readable without the key
// Every header in the tree has encryptionInfo set
```

**Use case**: Full privacy for an entire subtree.

## Mixing keys and strategies

### Recursive with overrides

Recursive encryption propagates a key to all descendants, but longer-path
entries override shorter ones. This lets you use different keys for different
branches of the same tree:

```swift
let teamKey = SymmetricKey(size: .bits256)
let aliceKey = SymmetricKey(size: .bits256)

var encryption = ArrayTrie<EncryptionStrategy>()
encryption.set([""], value: .recursive(teamKey))        // default: everything
encryption.set(["alice"], value: .recursive(aliceKey))   // override: alice's subtree

let encrypted = try volume.encrypt(encryption: encryption)

// "bob" and all other keys use teamKey
// "alice" and all her descendants use aliceKey
```

You can also mix strategies at different levels:

```swift
encryption.set([""], value: .recursive(teamKey))
encryption.set(["public-index"], value: .targeted(teamKey))
// "public-index" keeps its trie structure visible but encrypts its value
// Everything else is fully encrypted with teamKey
```

### Sibling paths with different keys

Different keys can protect different paths at the same level:

```swift
let aliceKey = SymmetricKey(size: .bits256)
let bobKey = SymmetricKey(size: .bits256)

var encryption = ArrayTrie<EncryptionStrategy>()
encryption.set(["alice"], value: .targeted(aliceKey))
encryption.set(["bob"], value: .targeted(bobKey))
let encrypted = try volume.encrypt(encryption: encryption)

// A holder of aliceKey can read alice but not bob
// A holder of bobKey can read bob but not alice
// A holder of neither key can still see that alice and bob exist (targeted)
```

## Transforms on encrypted trees

When you transform an encrypted tree (insert, delete, update keys),
encryption is preserved if you supply a `KeyProvider`:

```swift
// Start with an encrypted tree
var encryption = ArrayTrie<EncryptionStrategy>()
encryption.set([""], value: .recursive(key))
let encrypted = try volume.encrypt(encryption: encryption)

// Delete a key: remaining headers stay encrypted
var transforms = ArrayTrie<Transform>()
transforms.set(["alice"], value: .delete)
let result = try encrypted.transform(transforms: transforms, keyProvider: fetcher)

// result is still encrypted with the same key (new IV, new CID)
result!.encryptionInfo!.keyHash == encrypted.encryptionInfo!.keyHash  // true
result!.rawCID != encrypted.rawCID  // true: content changed
```

| Transform | Encryption behavior |
|-----------|-------------------|
| **Delete** (value removed) | Header is gone; nothing to preserve |
| **Delete** (trie restructured) | Surviving headers keep their encryption |
| **Update** | Header re-encrypted with same key, new IV |
| **Insert** | New header is **not** auto-encrypted |
| **No keyProvider** | Encryption is stripped |

### Inserts are not encrypted automatically

When a new value is inserted into an encrypted dictionary (via an `.insert`
transform or `inserting(key:value:)`), the new header is not encrypted:

1. The framework doesn't know which key to use for new entries.
2. The inserted value may already carry its own encryption from its
   serialized description.
3. Automatic encryption could cause surprising behavior with key management.

To encrypt newly inserted content, use the combined transform and encrypt
overload:

```swift
let result = try volume.transform(
    transforms: transforms,
    encryption: encryption,
    keyProvider: fetcher
)
// Transforms are applied first (preserving existing encryption),
// then the encryption trie is applied to encrypt new content
```

### Direct dictionary operations

The direct `mutating` and `deleting` methods on `MerkleDictionary` also
accept a `keyProvider` to preserve encryption on affected RadixHeaders:

```swift
let mutated = try encryptedDict.mutating(
    key: "alice",
    value: HeaderImpl(node: MyScalar(value: 99)),
    keyProvider: fetcher
)
// RadixHeaders that were encrypted remain encrypted

let deleted = try encryptedDict.deleting(key: "alice", keyProvider: fetcher)
// Remaining RadixHeaders preserve their encryption
```

### Full round trip

```swift
// 1. Build and encrypt
var dict = MerkleDictionaryImpl<HeaderImpl<MyScalar>>()
dict = try dict.inserting(key: "alice", value: HeaderImpl(node: MyScalar(value: 1)))
dict = try dict.inserting(key: "bob", value: HeaderImpl(node: MyScalar(value: 2)))
let volume = try VolumeImpl(node: dict)

var encryption = ArrayTrie<EncryptionStrategy>()
encryption.set([""], value: .recursive(key))
let encrypted = try volume.encrypt(encryption: encryption)

// 2. Transform (delete alice, encryption preserved on bob)
var transforms = ArrayTrie<Transform>()
transforms.set(["alice"], value: .delete)
let transformed = try encrypted.transform(transforms: transforms, keyProvider: fetcher)!

// 3. Store
try await transformed.store(storer: fetcher)

// 4. Resolve
let resolved = try await transformed.removingNode().resolveRecursive(fetcher: fetcher)
let bob = try await resolved.node!.get(key: "bob")!.resolve(fetcher: fetcher)
bob.node!  // MyScalar(value: 2)
```

## Key management

### KeyProvider

All encryption operations that need to look up a key use the `KeyProvider`
protocol:

```swift
public protocol KeyProvider {
    func key(for keyHash: String) -> SymmetricKey?
}
```

### KeyProvidingFetcher

For resolve operations, the fetcher must also provide keys:

```swift
public protocol KeyProvidingFetcher: Fetcher, KeyProvider {}
```

A single type can conform to `Storer`, `VolumeStorer`, and
`KeyProvidingFetcher` to handle sparse writes, complete boundaries, and
reads.

### When keys are needed

| Operation | Requires KeyProvider? | Which protocol? |
|-----------|----------------------|-----------------|
| `encrypt(encryption:)` | No: keys are in the strategy | N/A |
| `Header.store(paths:storer:)` | Yes, if a selected Header is encrypted | `storer as? KeyProvider` |
| `Volume.store(storer:)` | Yes, if the Volume is encrypted | `storer as? KeyProvider` |
| `resolve(fetcher:)` | Yes, if header is encrypted | `fetcher as? KeyProvider` |
| `transform(transforms:keyProvider:)` | Yes, to preserve encryption | `KeyProvider` parameter |
| `init(node:key:)` | No: key is passed directly | N/A |

## Errors

Encryption operations surface errors through `DataErrors`:

| Error | When |
|-------|------|
| `encryptionFailed` | AES-GCM seal produced no combined output |
| `keyNotFound` | `KeyProvider` returned nil, or the volume store/fetcher doesn't conform to `KeyProvider` |
| `invalidIV` | `EncryptionInfo.iv` is not valid base64 |
| `nodeNotAvailable` | Tried to encrypt/transform a header with no loaded node |

## API reference

### Types

| Type | Purpose |
|------|---------|
| `EncryptionInfo` | Metadata on an encrypted header (keyHash + iv) |
| `EncryptionStrategy` | Enum: `.targeted(key)`, `.list(key)`, `.recursive(key)` |
| `EncryptionHelper` | Low-level AES-GCM encrypt/decrypt |
| `KeyProvider` | Protocol for key lookup by hash |
| `KeyProvidingFetcher` | Combined `Fetcher` + `KeyProvider` |

### Header methods

| Method | Purpose |
|--------|---------|
| `init(node:key:)` | Create an encrypted header |
| `encrypt(encryption:)` | Apply path-based encryption strategies |
| `encryptSelf(key:)` | Encrypt this header with a specific key |
| `reEncryptIfNeeded(node:keyProvider:)` | Re-encrypt after transform if originally encrypted |
| `decryptIfNeeded(data:fetcher:)` | Decrypt fetched data if header is encrypted |
| `transform(transforms:keyProvider:)` | Transform with encryption preservation |
| `transform(transforms:encryption:keyProvider:)` | Transform, preserve encryption, then apply new encryption |

### Properties

| Property | Type | Purpose |
|----------|------|---------|
| `encryptionInfo` | `EncryptionInfo?` | Nil for plaintext, populated for encrypted headers |

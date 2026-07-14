# Correctness invariants

## CASHEW-SPARSE-001 — storage selection matches resolution

`Header.store(paths:storer:)` emits exactly the blocks that resolving the same
`ResolutionStrategy` paths would fetch from a CID-only root. This includes
targeted, recursive, list, range, and compressed-radix traversal. An empty plan
selects no blocks for either operation; use `store(storer:)` for the root alone.

## CASHEW-SPARSE-002 — sparse writes are verified, not complete

Every emitted block hashes to its declared CID. Unresolved references outside the
selected paths are allowed, while selected unresolved references fail before the
single `Storer.store(entries:)` call. Sparse writes make no retention guarantee.

## CASHEW-SPARSE-003 — read-through writes follow verification

`resolve(..., cache:)` stores fetched bytes only after their CID has been verified.
The cache remains unchanged when a source returns mismatched bytes.

## CASHEW-VOLUME-001 — only complete boundaries are emitted

Cashew serializes a Volume root and every same-boundary Header before making the
single `VolumeStorer.store(volume:)` call. Structural, serialization, and encryption
failures emit nothing for that boundary.

## CASHEW-VOLUME-002 — declared structure is consistent

Every property returned by `Node.properties()` must return a Header from
`get(property:)`. This applies to every declared edge of a selected boundary,
including off-path siblings, because the boundary itself is always emitted whole.
Otherwise storage fails with `DataErrors.missingDeclaredChild`.

## CASHEW-VOLUME-003 — Volume relationships stay in content

A parent payload contains the nested Volume CID only through the serialized parent
node. Storage does not duplicate parent/child relationships as metadata.

## CASHEW-VOLUME-004 — Volumes are independent

Nested Volume bytes are never members of the parent payload. The parent is stored
before a selected child, and a child failure does not undo the parent. Multi-Volume
storage is non-transactional and must be safely re-drivable after partial success.

## CASHEW-VOLUME-005 — plans control traversal

The root is always stored. Empty paths stop there. `.targeted` stores the boundary
at a path, while `.recursive` also stores all materialized nested boundaries. The
path interpretation matches resolution, including compressed radix keys.

## CASHEW-VOLUME-006 — selection controls materialization requirements

An unresolved same-boundary Header always makes the current Volume incomplete. An
unresolved nested Volume is allowed when unselected and fails when selected.

## CASHEW-VOLUME-007 — stored bytes preserve content identity

Every emitted entry hashes to its declared CID. Encrypted entries also decrypt to
the original node when the `VolumeStorer` conforms to `KeyProvider`.

## CASHEW-VOLUME-008 — shared Volumes are emitted once

A selected Volume reachable through multiple DAG paths is emitted once per storage
operation. Distinct targeted subplans through that Volume are still traversed.

## CASHEW-VOLUME-009 — policy remains outside Cashew

Cashew enforces boundary completeness and follows caller-provided paths. It does not
infer application retention, workflow completeness, validity, or canonicity.

Established by `SparseStorageTests`, `StoragePlanTests`, and
`VolumeMerkleDictionaryTests`.

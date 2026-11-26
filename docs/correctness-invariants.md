# cashew invariants

The rules every change to cashew's storage must keep. `CASHEW-SPARSE` rules
cover sparse writes through `Storer`; `CASHEW-VOLUME` rules cover complete
Volume writes through `VolumeStorer`.
[cashew architecture](architecture.md#the-persistence-boundary) explains both
write paths.

| ID | Invariant | Enforced by |
| --- | --- | --- |
| CASHEW-SPARSE-001 | Storage selection matches resolution: `Header.store(paths:storer:)` emits exactly the blocks that resolving the same `ResolutionStrategy` paths would fetch from a CID-only root. | `Header+store.swift`; `SparseStorageTests` |
| CASHEW-SPARSE-002 | Sparse writes are verified, not complete: every emitted block hashes to its declared CID. | `Header+store.swift`; `SparseStorageTests` |
| CASHEW-SPARSE-003 | Read-through writes follow verification: `resolve(..., cache:)` stores fetched bytes only after their CID has been verified. | `Header+resolve.swift`; `SparseStorageTests` |
| CASHEW-VOLUME-001 | Only complete boundaries are emitted: Cashew serializes a Volume root and every same-boundary Header before making the single `VolumeStorer.store(volume:)` call. | `Volume+store.swift`; `StoragePlanTests`, `VolumeMerkleDictionaryTests` |
| CASHEW-VOLUME-002 | Declared structure is consistent: every property returned by `Node.properties()` must return a Header from `get(property:)`. | `Volume+store.swift`; `StoragePlanTests` |
| CASHEW-VOLUME-003 | Volume relationships stay in content: a parent payload contains the nested Volume CID only through the serialized parent node. | `Volume+store.swift`; `StoragePlanTests` |
| CASHEW-VOLUME-004 | Volumes are independent: nested Volume bytes are never members of the parent payload. | `Volume+store.swift`; `StoragePlanTests` |
| CASHEW-VOLUME-005 | Plans control traversal: the root is always stored, and empty paths stop there. | `Volume+store.swift`; `StoragePlanTests` |
| CASHEW-VOLUME-006 | Selection controls materialization requirements: an unresolved same-boundary Header always makes the current Volume incomplete. | `Volume+store.swift`; `StoragePlanTests` |
| CASHEW-VOLUME-007 | Stored bytes preserve content identity: every emitted entry hashes to its declared CID. | `Volume+store.swift`; `StoragePlanTests` |
| CASHEW-VOLUME-008 | Shared Volumes are emitted once: a selected Volume reachable through multiple DAG paths is emitted once per storage operation. | `Volume+store.swift`; `StoragePlanTests` |
| CASHEW-VOLUME-009 | Policy remains outside Cashew: Cashew enforces boundary completeness and follows caller-provided paths. | Public API surface |

## Notes

**CASHEW-SPARSE-001.** This includes targeted, recursive, list, range, and
compressed-radix traversal. An empty plan selects no blocks for either
operation; use `store(storer:)` for the root alone.

**CASHEW-SPARSE-002.** Unresolved references outside the selected paths are
allowed, while selected unresolved references fail before the single
`Storer.store(entries:)` call. Sparse writes make no completeness or
retention guarantee.

**CASHEW-SPARSE-003.** The cache remains unchanged when a source returns
mismatched bytes. Read-through cache writes are incremental and are not
rolled back if a later fetch in the same resolution fails.

**CASHEW-VOLUME-001.** Structural, serialization, and encryption failures
emit nothing for that boundary.

**CASHEW-VOLUME-002.** This applies to every declared edge of a selected
boundary, including off-path siblings, because the boundary itself is always
emitted whole. Otherwise storage fails with `DataErrors.missingDeclaredChild`.

**CASHEW-VOLUME-003.** Storage does not duplicate parent/child relationships
as metadata.

**CASHEW-VOLUME-004.** The parent is stored before a selected child, and a
child failure does not undo the parent. Multi-Volume storage is
non-transactional and must be safely re-drivable after partial success:
completed ancestors remain stored after a descendant failure, and identical
retries must be idempotent.

**CASHEW-VOLUME-005.** `.targeted` stores the boundary at a path, while
`.recursive` also stores all materialized nested boundaries. The path
interpretation matches resolution, including compressed radix keys. A deep
target selects the intervening Volume boundaries needed to reach it.

**CASHEW-VOLUME-006.** An unresolved nested Volume is allowed when unselected
and fails when selected.

**CASHEW-VOLUME-007.** Encrypted entries also decrypt to the original node
when the `VolumeStorer` conforms to `KeyProvider`. Header and Volume roots
share one canonical serialization and encryption path.

**CASHEW-VOLUME-008.** Distinct targeted subplans through that Volume are
still traversed.

**CASHEW-VOLUME-009.** It does not infer application retention, workflow
completeness, peer selection, validity, or canonicity. Applications choose
storage and retention plans explicitly.

# Dormant account-owned capture store

This source-only milestone adds an owner-required SQLite profile above PR6
`d48c32eb4f4e52ae8ff8426fc7e59ff80d7f1ccb`. It does not select a shipping
store, construct a recorder, change app startup, or open an existing archive.
PR10 `efdbc16` is an identity/composition reference only, not this branch's base.

## Boundary and identity

`AccountCaptureStore.createNew(for:in:seams:)` and
`AccountCaptureStore.openExisting(for:in:seams:)` are separate synchronous
construction operations. A successful value has immutable `accountUUID` and
`persistence: RouteStore`; `close()` awaits that actor's resource closure. The
actor remains the only SQLite owner; no forwarding persistence implementation,
Auth dependency, account model, or second runtime is introduced.

The UUID and Application Support URL are injection seams for synthetic tests
and later composition, not evidence of authentication. The eventual caller must
take the UUID from the existing `AccountContext.accountID.rawValue`, verify that
context is still current before publishing a result, and supply the trusted,
canonical app Application Support directory. Do not accept a URL or UUID from
group input, email, a deep link, or user text. This layer does not resolve Auth,
create Application Support, or implement a generation fence.

The derived layout is fixed:

```
<Application Support>/Keepsake/Accounts/<lowercase UUID>/LocalCapture-v3/
    route.sqlite
    manifest.json
    .route-store.lock
```

Only the immutable UUID varies. There is no group ID, generation, email, route,
or arbitrary child-path argument. Existing path checks reject aliases,
symlinks, noncanonical components, wrong filesystem ownership, and permissive
directories/files. New directories are private; existing namespace directories
are verified, not repaired or relabeled. Creation reserves a new UUID directory
exclusively, even if an existing one appears empty. Partial creation stays
quarantined; a later create does not adopt it.

## Persisted proof and access ordering

Profile 3 reuses the foundation schema, control epochs, bounded pages, receipts,
and transaction machinery. Profiles 1 and 2 keep their existing schemas and
factories. The manifest has `schemaVersion: 3` and `ownerAccountUUID`; SQLite
has `user_version = 3` and exactly the `migration_authorization = none` and
canonical `owner_account_uuid` metadata rows. The bound UUID cannot be changed
through the store API. These are local consistency proofs, not cryptographic
authentication or protection against arbitrary code inside the app sandbox.

Creation protects the new root, lock, and empty database before schema bytes.
Schema, owner metadata, and initial stopped control are committed in one
exclusive SQLite transaction using DELETE journaling and synchronous FULL.
The database and directory are synchronized before the protected, read-only
manifest is staged and exclusively published with the existing file/directory
barriers. Both owner proofs and current protection are checked again before
returning the handle. Nothing starts location services.

Account open first verifies the directories and exact three-file inventory.
It verifies protection/backup exclusion and the manifest before taking an
existing-only lock. A bounded descriptor read first rejects a WAL/invalid header
before SQLite could create WAL sidecars, even on a read-only open. A read-only
SQLite connection with in-memory temporary storage checks schema, integrity,
owner, and capture control before the writable handle is opened. Owner and
protection are rechecked before that handle escapes. No account-open path has
`O_CREAT`, a create fallback, migration, snapshot import, or protection repair.

Account transactions validate namespace/file identities, both owner sources,
protection class, and backup exclusion before work, inside the transaction,
and before returning results. Mutations also recheck before COMMIT and after
the existing file/directory barriers. Failed environment checks close the
handle; after-COMMIT failures remain outcome-uncertain, never definite rollback.
Existing epoch/revision/receipt semantics are unchanged. Legacy load/append/
clear/export APIs reject this profile rather than bypassing its fenced APIs.

## Failure and recovery limits

- Missing open never creates parent directories or a replacement lock/database.
  Foreign, missing, malformed, or disagreeing ownership never relabels or deletes
  files. Unowned profiles, legacy snapshots, and unsupported manifests reject.
- An interrupted pre-publication create retains its bytes and blocks both open
  and create. A fully synchronized publication followed by a returned error can
  be reconciled only by an explicit open that independently verifies all proof.
- Any journal/WAL/SHM, pending manifest, extra file, or missing required file on
  open fails closed. This deliberately does not perform SQLite hot-journal
  recovery, even if SQLite could ordinarily recover it. Recovery of uncertain
  account stores is future work, not a reason to delete them or create elsewhere.
- Existing descriptor/inode and canonical-path checks plus the advisory store
  lock prevent cooperative competing owners. They do not provide an adversarial
  filesystem sandbox against another writer deliberately bypassing that lock.
  Current metadata is rechecked; there is no encryption/key-management addition.
- New SQLite sidecars retain the inherited foundation mechanism: the SQLite
  file-protection flag/protected directory, then explicit sidecar protection
  before COMMIT. First-byte sidecar protection, backup metadata, lock/first-unlock
  behavior, and power-loss durability still need real-device evidence. Source
  ordering and modeled metadata do not prove hardware protection.

## Authored versus actual evidence

`AccountCaptureStoreTests` authors 18 declarations / 34 expanded invocations,
with isolated synthetic roots, fixed sample times, no sleeps, and a one-minute
suite trait. They cover A/B history/intent isolation, own reopen, foreign and
missing owners, disagreeing metadata, missing files, interrupted creation,
uncertain sidecars, protection before exposure/schema bytes, post-COMMIT
uncertainty, already-open owner/protection drift, symlinks, and legacy rejection.
Simulator fixtures model the protection read seam; hardware branches keep the
real read. Temporary corruption/deletion is restricted to each test's own root.

Actual checks passed: exact five-file scope and whitespace; byte continuity for
all 47 other baseline files; and Python SQLite 3.54.0 models using the extracted
schema/owner queries (profiles 1/2/3 integrity, own/foreign/missing proof,
schema+metadata rollback, and DELETE/WAL header bytes). These are source/data
checks, not execution of the Swift implementation. One focused read-only
`openai/gpt-6-astra` Medium review returned no findings; it did not run code.

No Swift compiler, Xcode, simulator, device, app, permission prompt, backend,
route capture, or native test ran for this checkpoint. Data/source checks are
not Swift behavior. The new files are not registered in the checked-in Xcode
projects or the explicit StorageValidation YAML; project/target registration
belongs to the composition owner under the Wave 1 contract. Root `project.yml`
uses directory sources, but regeneration has not run. An existing-target run
without deliberate registration would not execute the new suite.

All previous evidence stays at its original head: the historical `f92b36c` full
run had 95 passing declarations and one failed fixture; `d48c32e` passed only the
focused six-test experiment suite. Neither is this milestone's test evidence.
No retained artifacts, fixtures, registries, signing hosts, or accepted pointers
were changed.

## Next recorder-owned handoff

1. Extend the existing runtime lifetime with immediate admission/resource closure
   plus an awaited collector/service-task join. Durable Stop must drain admitted
   writes, verify its receipt, and join collectors before quiescence is reported.
   Avoid a collector awaiting the controller that is itself joining that task.
2. Add the protected, backup-excluded crash-surviving intent/ownership journal
   described in the Wave 2 packet. Persist the bound account UUID, stable exact
   operation identity/disposition, and intent epoch before Begin/hardware start
   or transition dispatch. Never regenerate an uncertain command after relaunch.
3. Bind that lifetime to the existing AccountContext generation. Close admission
   and fence old completions before the first await on account transition; retain
   the old immutable store until Stop, admitted writes, task join, and store
   closure are proven. Authentication of B may complete while capture remains
   blocked on A. No old handle may be rebound or released by a late completion.
4. Author gated Stop/join/crash-boundary tests, then have the composition owner
   register the new sources and arrange coordinated native verification through
   the Captain. Do not instantiate this store from Auth or app startup yet.

The inherited PR6 default still instantiates legacy `RecorderModel()` in the
inactive-experiment branch of `KeepsakeApp`; its initializer can load/prune the
unowned JSONL archive. That is a preserved baseline fact, not an activation made
here, and must not become the account composition. PR10's separate recorder-off
composition is not imported or changed. Locked/background reliability and a
week without opening remain field goals, not guarantees. No force-quit bypass,
sharing, uploads, new permissions, entitlements, or signing changes are included.

# Local capture foundation

This is an unactivated synthetic foundation, not a migration or a new app default. The app still uses JSONL and in-memory recording intent. Its runtime Stop is not a durable acknowledgement.

## Separate schema and durable fences

`RouteStore.createFoundation` and `openFoundation` select schema v2 explicitly. Legacy v1 openers reject that profile, and v2 rejects unfenced legacy load/append/clear/export operations. There is no implicit schema upgrade, legacy import, recovery activation or backend connection.

Begin commits a logical recording UUID and a positive store-local epoch revision before a runtime may start. A new runtime incarnation gets a new epoch even when it resumes the same logical recording. Stop commits a new stopped control revision, so old-epoch writers cannot append after that fence. A stale Stop cannot stop a newer epoch.

Commands carry stable operation UUIDs and content digests. A retained same-command replay returns its original receipt without changing current state; reusing an operation UUID for different content fails. Ordered batches commit accepted samples, dispositions and their receipt atomically. Invalid, expired, duplicate and nonincreasing-time results preserve the existing admission policy; duplicate sample UUIDs never overwrite stored payloads. Reconciliation distinguishes exact stored payloads, conflicts and absent-or-expired history.

An uncertain COMMIT or required post-COMMIT check closes the writer and requires verified reopen/reconciliation. An unavailable receipt is not proof that a command never committed and never triggers automatic replay. The latest control receipt remains with the control snapshot when the recent ledger retires older receipts.

## Coordinator boundaries

`LocalCaptureCoordinator` is separate from the app's existing model and has no automatic restoration path. Its single command queue commits Begin before creating an injected runtime handle. Stop closes local admission and stops that handle immediately, then waits behind earlier admitted writes. Stop during a suspended Begin fences the epoch that actually commits rather than dropping its late completion.

Failed or uncertain durable Stop remains unacknowledged and blocks Start. Explicit retry requires verified reopen; unresolved state never restarts capture. Reconciliation of a historical receipt preserves the latest control snapshot instead of presenting the old receipt as the current state. Permission/capability policy and a real runtime adapter are not activated by this foundation.

## Bounded history and clear

`readPage` returns unchanged sample payloads with admitting epochs and insertion sequences. A half-open observation interval and supplied query time stay fixed for a cursor session, with exact 90-day visibility relative to that time. Cursors bind the verified store-open identity, insertion high-water, deletion revision and last keyset tuple. Later appends stay outside the snapshot; clear or physical deletion invalidates existing cursors. Changed queries, foreign/reopened stores and malformed cursors are rejected. No transaction spans page returns.

Pages contain at most 256 rows and 256 KiB encoded sample payload. Bounded SQL metadata/lookahead and payload projections check lengths before Swift copying/decoding; an individually oversized record returns an explicit error rather than an empty nonadvancing page. A v2-only derived history-generation index separates logically cleared rows from current history. This draft profile rejects older/different v2 layouts rather than upgrading them; v1 remains unchanged.

`clearHistory` requires stopped intent and its expected control revision. It atomically records a logical visibility floor and clear receipt, preserving the stopped fence, recording-control revision and latest Begin/Stop receipt. The latest clear receipt also survives recent-ledger eviction. Clear does not enumerate/delete all rows or reclaim disk space synchronously. Subsequent visible queries respect the floor; a nonexpired old payload conflicts if a new visible row has reused its ID. Expired-input reconciliation retains its existing absent-or-expired meaning.

`pruneHistory` explicitly removes at most 256 eligible rows and 256 KiB encoded sample payload per transaction, with conservative space checks and continuation. Deletes, deletion revision and prune receipt commit atomically; replay returns the original receipt without deleting the next chunk. Encoded payload lengths are not reclaimed physical bytes. There is no automatic maintenance loop, full-file rewrite, VACUUM or immutable-snapshot disposal. Clear/prune use the existing commit-uncertainty and verified-reopen rules.

Pages use read-only identity/protection/backup checks, including a strict-by-default protection reader; simulator metadata modeling belongs only in test fixtures. History-only metadata changes do not replace recording intent or stop an unchanged runtime owner. Coordinator clear/Start ordering and history UI integration remain deferred and unactivated, so these APIs do not establish bounded-history rendering in the running app.

## Implementation bounds and costs

One coordinator admits at most 64 pending samples and 256 KiB of encoded payload across its lane, including the in-flight request. Batches have the same limits and preserve supplied order. Overflow is an explicit error rather than a silent oldest-sample discard. No deliberate time-based unsaved buffer is added.

Recent receipts are capped at 4,096 entries and 8 MiB encoded metadata, with seven-day aging during maintenance. Control payloads are capped at 4 KiB and individual receipts at 16 KiB before Swift copying/decoding; SQL projections reject oversized payloads as well. Bounded reconciliation queries only the supplied sample identities. Open does not decode sample history, but the existing full SQLite integrity check still incurs archive I/O. FULL synchronization, DELETE journaling and protection/backup verification are retained. Additional control reads and synchronization barriers have not been benchmarked.

These are implementation limits, not measured memory, CPU, battery, disk or latency improvements. Index traversal, integrity-check I/O, synchronization cost and actual heap/latency behavior require executed measurement. No bounded-history UI claim follows from the source APIs. V2 legacy export remains rejected rather than silently merging epoch boundaries into a format that cannot represent them.

## Validation

Synthetic tests are authored for stale epochs, replay/content conflicts, uncertainty/reopen, receipt retirement, batch/page/prune bounds, exact retention, epoch envelopes, cursor consistency/invalidation, logical clear versus physical rows, ID reuse, read-protection failures and coordinator suspension interleavings. Both checked-in projects and the isolated host source manifest include the new files. Static source review, plist parsing, membership/settings preservation, privacy checks and whitespace checks are distinct from executable validation. **There is no successful combined Wave 2 build or executed-test result.**

The first combined dependent build at PR3 commit `86722b0` failed Swift 6 checking in the inherited generic continuation fan-out: a main-actor-isolated unconstrained value could not be sent repeatedly. The source correction constrains returned values to compiler-checked `Sendable` types and explicitly marks the immutable result values accordingly; actor isolation, queue ordering and delivery logic are unchanged. A later combined build at `dd9409b` did not report that diagnostic but failed in a storage-helper type inference. Neither attempt booted the simulator or executed tests; no successful Wave 2 build is established.

The next admitted build at `dd9409b` did not report the continuation diagnostic, but failed at the insertion high-water helper: its local generic SQL closure inferred `Int` from the empty-store zero and also returned SQLite's `Int64`. The source now explicitly types that local result as `Int64`, without a narrowing cast or SQL/control-flow change. Neighboring Boolean, optional, tuple and scalar-return closures were reviewed together. This correction is unbuilt/unrun; neither failed attempt booted the simulator or executed tests.

Original Wave 1 staging compiled and later completed 56 selected tests: 53 passed, one failed and two hardware-only checks were skipped. The parent PR corrects the failed regression's independent-JSON-encoding assumption without changing production storage. A separate unsigned portable isolated-host build at parent commit `49a6c1f`, using SDK 27.1, then passed all nine `RouteRepositoryTests` on iOS 26.5, including that corrected regression. This did not rerun the other three suites, compile the main app target or validate these Wave 2 files. There is no hardware-protection, field reliability, recovery or app-resource-performance result for this foundation. Default-store activation, real-data migration and backend/sync stay out of scope.

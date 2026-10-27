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

## Implementation bounds and costs

One coordinator admits at most 64 pending samples and 256 KiB of encoded payload across its lane, including the in-flight request. Batches have the same limits and preserve supplied order. Overflow is an explicit error rather than a silent oldest-sample discard. No deliberate time-based unsaved buffer is added.

Recent receipts are capped at 4,096 entries and 8 MiB encoded metadata, with seven-day aging during maintenance. Control payloads are capped at 4 KiB and individual receipts at 16 KiB before Swift copying/decoding; SQL projections reject oversized payloads as well. Bounded reconciliation queries only the supplied sample identities. Open does not decode sample history, but the existing full SQLite integrity check still incurs archive I/O. FULL synchronization, DELETE journaling and protection/backup verification are retained. Additional control reads and synchronization barriers have not been benchmarked.

These are implementation limits, not measured memory, CPU, battery, disk or latency improvements. Bounded pages, deletion-aware cursors, stopped-only clear receipts and chunked physical pruning remain a later slice; no bounded-history UI claim follows from this change. V2 legacy export remains rejected rather than silently merging epoch boundaries into a format that cannot represent them.

## Validation

Synthetic tests are authored for stale epochs, replay/content conflicts, uncertainty/reopen, receipt retirement, batch order/caps, oversized payloads and coordinator suspension interleavings. Both checked-in projects and the isolated host source manifest include the new files. Static source review, plist parsing, membership/settings preservation, privacy checks and whitespace checks were performed. **There is no overall passing combined Wave 2 test result.**

The first combined dependent build at PR3 commit `86722b0` failed Swift 6 checking in the inherited generic continuation fan-out. A `Sendable` constraint and explicit immutable result conformances preserved actor isolation and delivery logic. The next build at `dd9409b` reached an `Int`/SQLite `Int64` inference error; neither attempt booted the simulator or executed tests.

The combined portable isolated host at PR3 commit `628b0d3` then built unsigned with SDK 27.1 and executed 80 tests across five suites on iOS 26.5: 77 passed, one parameterized declaration failed across four cases, and two hardware-only checks skipped. The failed metadata-fault test recorded a zero injection counter; it did not exercise its intended error boundary. The fixture's directory-form URL differed from the store's normalized root URL. The source correction selects that same normalized root and retains all fault/closure assertions, adding an exact threshold check; it has not been rerun. This is not an overall test pass, a bare-PR2/main-app build, hardware protection, field reliability or resource-performance proof.

Original Wave 1 staging compiled and later completed 56 selected tests: 53 passed, one failed and two hardware-only checks were skipped. The parent PR corrects the failed regression's independent-JSON-encoding assumption without changing production storage. A separate unsigned portable isolated-host build at parent commit `49a6c1f`, using SDK 27.1, then passed all nine `RouteRepositoryTests` on iOS 26.5, including that corrected regression. This did not rerun the other three suites, compile the main app target or validate these Wave 2 files. There is no hardware-protection, field reliability, recovery or app-resource-performance result for this foundation. Default-store activation, real-data migration and backend/sync stay out of scope.

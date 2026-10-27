# Local recorder boundaries

## Capture and history

The app starts a modern Core Location live-update stream only after explicit recording intent and eligible permission. When-in-Use and Always access are distinct; an authorization goal or background session is not a guarantee of uninterrupted execution. Stationary suspension is managed by iOS, not by an app polling timer.

Samples retain stable UUIDs, their logical recording identifier, observation time, coordinates, uncertainty and optional motion measurements. The local repository rejects invalid, duplicate, nonincreasing-time, expired and excessively future-dated samples. This strict ordering policy does not preserve every possible delayed observation.

The map groups observations using the current Gregorian calendar/time zone. It omits fixes worse than 100 metres from route geometry, splits gaps over five minutes, and splits at logical recording boundaries. Low-accuracy samples remain in local storage. These display rules are not a measurement of actual movement coverage.

## Storage selection

The running prototype selects `RouteRepository` and JSONL. `RouteStore` is a separate, explicitly created/opened SQLite actor for synthetic preparation. It uses protected, backup-excluded owned files, an exclusive writer lock, explicit manifest cutover, DELETE journaling and FULL synchronization. Its existence does not give the default JSONL path all of those guarantees.

Synthetic stopped-file import preserves an immutable input snapshot and refuses ambiguous or corrupt state. It does not authorize migration of actual route history. Clear/export operations have explicit selected-store boundaries; immutable source snapshots are not silently deleted. No cloud service is used.

## Hardened runtime and write outcomes

The logical recording UUID is distinct from a runtime generation. Old errors, diagnostics and completions cannot intentionally act as the current owner. A normally ended stream releases its owner and reports interruption. Permission interruption requires an explicit restart rather than activating automatic recovery. Startup/clear/write readiness gates Start, and a runtime Stop remains available during storage faults.

JSONL verifies protection and backup exclusion before appending bytes or publishing a rewritten archive. A failure after a write or replacement is reported as an uncertain outcome. The SQLite writer likewise closes after an uncertain COMMIT/post-COMMIT result; callers must reopen and reconcile stable identities rather than blindly retry or claim rollback. These source paths still require executed validation.

## Unverified boundaries

Recording intent and runtime state are not yet a durable control protocol. Cancellation is not an acknowledged durable Stop. Automatic process/reboot restoration, force-quit recovery, bounded all-history memory and calibrated battery/CPU/disk/UI performance are not established.

An explicit, unactivated schema-v2 store and coordinator now implement a separate [durable capture foundation](local-capture-foundation.md). They do not change the running app's JSONL selection or activate recovery; their new source and tests remain uncompiled and unrun.

Unit tests use synthetic data and temporary files. Some simulator fixtures substitute only unavailable protection metadata readback, while strict physical protection tests are hardware-only. No simulator result can prove first-unlock behavior or all-day background delivery. The published source checkpoint is uncompiled and unrun; hardware and field validation remain separate work.

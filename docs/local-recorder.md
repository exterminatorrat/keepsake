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

JSONL verifies protection and backup exclusion before appending bytes or publishing a rewritten archive. A failure after a write or replacement is reported as an uncertain outcome. The SQLite writer likewise closes after an uncertain COMMIT/post-COMMIT result; callers must reopen and reconcile stable identities rather than blindly retry or claim rollback. The nine JSONL repository regressions passed in the portable isolated host; that does not extend the result to every storage path or actual physical protection behavior.

## Unverified boundaries

Recording intent and runtime state are not yet a durable control protocol. Cancellation is not an acknowledged durable Stop. Automatic process/reboot restoration, force-quit recovery, bounded all-history memory and calibrated battery/CPU/disk/UI performance are not established.

Unit tests use synthetic data and temporary files. Some simulator fixtures substitute only unavailable protection metadata readback, while strict physical protection tests are hardware-only. At commit `49a6c1f`, the portable isolated host built unsigned with SDK 27.1 and all nine `RouteRepositoryTests` passed on the owned iOS 26.5 destination. This includes the corrected post-rename regression; its earlier independent-encoding comparison failed in the original local staging run (53 passed, one failed, two hardware-only skips among 56 tests). The newer narrow run did not rerun the other three suites or compile the main app target. No simulator result proves first-unlock behavior, all-day background delivery, Wave 2 correctness or field/resource performance.

# Local recorder boundaries

## Capture and history

The app starts a modern Core Location live-update stream only after explicit recording intent and eligible permission. When-in-Use and Always access are distinct; an authorization goal or background session is not a guarantee of uninterrupted execution. Stationary suspension is managed by iOS, not by an app polling timer.

Samples retain stable UUIDs, their logical recording identifier, observation time, coordinates, uncertainty and optional motion measurements. The local repository rejects invalid, duplicate, nonincreasing-time, expired and excessively future-dated samples. This strict ordering policy does not preserve every possible delayed observation.

The map groups observations using the current Gregorian calendar/time zone. It omits fixes worse than 100 metres from route geometry, splits gaps over five minutes, and splits at logical recording boundaries. Low-accuracy samples remain in local storage. These display rules are not a measurement of actual movement coverage.

## Storage selection

The running prototype selects `RouteRepository` and JSONL. `RouteStore` is a separate, explicitly created/opened SQLite actor for synthetic preparation. It uses protected, backup-excluded owned files, an exclusive writer lock, explicit manifest cutover, DELETE journaling and FULL synchronization. Its existence does not give the default JSONL path all of those guarantees.

Synthetic stopped-file import preserves an immutable input snapshot and refuses ambiguous or corrupt state. It does not authorize migration of actual route history. Clear/export operations have explicit selected-store boundaries; immutable source snapshots are not silently deleted. No cloud service is used.

## Unverified boundaries

Recording intent and runtime state are not yet a durable control protocol. Cancellation is not an acknowledged durable Stop. Automatic process/reboot restoration, force-quit recovery, bounded all-history memory and calibrated battery/CPU/disk/UI performance are not established.

Unit tests use synthetic data and temporary files. Some simulator fixtures substitute only unavailable protection metadata readback, while strict physical protection tests are hardware-only. No simulator result can prove first-unlock behavior or all-day background delivery. The published source checkpoint is uncompiled and unrun; hardware and field validation remain separate work.

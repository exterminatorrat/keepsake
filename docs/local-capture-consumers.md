# Disabled local-capture consumers

This is an implementation checkpoint, not activation or a validated app. The default entry still creates `RecorderModel`, uses JSONL and has runtime-only Stop. No project setting defines `KEEPSAKE_EXPERIMENTAL_LOCAL_CAPTURE`. Defining that condition selects an experimental entry instead; it does not create a store or start recording automatically.

## Explicit isolated ownership

The experimental entry asks the person to create an empty store or open an existing one in the separate `Keepsake-Isolated-Capture-v2` child of Application Support. Creation rejects an existing destination, and opening rejects a missing store. Neither path reads, imports or deletes legacy history. The shared actor wrapper owns the current capture/history handle; verified reopen closes the previous handle, rejects overlapping reopens and cannot revive an explicitly closed session.

Opening verifies persisted control without location handles or permission prompts. Start, persisted-intent resume, Stop, Stop retry and uncertain-outcome reconciliation remain explicit. The consumer delegates to the existing lifecycle/coordinator rather than creating another recording queue. Observable state also reflects background runtime interruption. Stop does not wait for a UI busy flag and remains admissible during pending Begin or append.

## Bounded, deletion-aware history

History reads occur only after selecting a day or requesting Refresh/Next. The day picker offers a bounded 90-day range, not a full-history scan. Each query fixes its time and uses one 128-row page by default, clamped to the existing storage maximum. Next passes the exact cursor and replaces the displayed page; earlier pages are not cached or joined into a whole-day route. The view labels this partial coverage even at the end of a query.

Changing a query, refreshing, clearing, maintenance or disposal invalidates the read generation and cancels the retained task. Late results cannot repopulate an invalidated page. Cursor/deletion/store errors hide the page and require explicit refresh rather than silently retrying. Foreground transitions do not refresh automatically.

Logical clear uses the existing expected-revision/operation-ID coordinator command. It hides history before the write; pending/uncertain clear vetoes Start and keeps stale pages hidden until explicit reconciliation and refresh. A physical prune runs one explicit 64-row chunk only while stopped. The consumer blocks competing Start/resume/clear during that chunk but never blocks Stop. A maintenance failure freezes further history/capture admission in that session without replay; the person must close it and explicitly open the existing store to verify intent. A new verified open does not claim that a previously uncertain prune definitely committed or rolled back.

## Experimental downstream write admission

The lifecycle defaults to `allUpdates`, preserving prior behavior. Only the experimental host explicitly chooses `boundedMovementStationary`; the existing OS-managed `liveUpdates(.default)` source is unchanged.

Each runtime epoch gets a fresh admission state. The policy preserves the first observation, recording changes and stationary/reliability transitions. Otherwise it admits sample-driven heartbeats at 15 seconds while moving or 60 seconds while stationary, or displacement of at least the maximum of 25 metres and the prior/current horizontal-accuracy radii. The reliable threshold is the same 100-metre boundary used for route rendering. Invalid or nonmonotone samples pass through to the existing persistence validator without replacing admission anchors. This is not a timer, GPS duty-cycling algorithm or proven accuracy/energy optimization.

## Verification boundary

New one-minute Swift Testing fixtures cover passive opening/permission, explicit resume, observed background interruption, pending Begin/append with immediate Stop, explicit Stop retry, stale/pending/uncertain clear, receipt/revision propagation, bounded page replacement/exact cursors, cancelled late reads, maintenance admission/failure, policy transitions/counts and isolated-store create/open/reopen/close boundaries. Both checked-in projects include the required sources; the inert host excludes the real app entry and experimental SwiftUI host. It now includes the inherited viewport test suite as well.

Only source/static checks have run for this checkpoint. The Swift tests have been authored but not compiled or executed, and the UI has not rendered or been visually inspected. Historical native passes do not validate this code or the inherited merge-review corrections. Fresh admitted isolated compilation/tests and a separate app-build/visual gate are required before readiness. Hardware protection, supported run-attributable phone-host exit, field accuracy, energy and measured CPU/memory/disk/write amplification/query/Stop/UI latency remain unverified; see [the measurement plan](local-capture-resource-validation.md).

No backend, migration, default-store switch, automatic recovery, phone deployment, merge or field acceptance is enabled by this checkpoint.

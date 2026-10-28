# Opt-in durable lifecycle preparation

This layer is not called by KeepsakeApp, RecorderModel or the default store factory. The running app still uses JSONL and its Stop is runtime-only. These adapters do not migrate data, activate automatic recovery, request backend access or establish field reliability.

`LocalCaptureLifecycle.open` accepts an explicitly supplied persistence implementation, verified reopener, authorization observer, location-update source and runtime platform. It reads verified control without creating a location stream, runtime handle or permission prompt. Persisted recording intent is exposed as resume-required rather than automatically restarting.

An explicit new Start or Resume delegates durable Begin to LocalCaptureCoordinator before runtime creation. Resume keeps the persisted recording ID and commits a new epoch. The bridge uses the existing location/session seams, awaits bounded coordinator appends and rejects stopped or superseded callbacks. It does not introduce a second command queue, operation ledger or uncertainty reconciler.

The per-generation runtime handle is inert while the existing off-main services-status source is queried. Cancellation and current authorization are checked again before any background/service handle or location stream is created. A permission change during Begin or Stop during the services query therefore cannot create a late runtime. Dropping the facade schedules token-guarded runtime closure without discarding admitted writes or changing durable intent.

Stop closes runtime admission and resources through the coordinator before waiting for the durable fence behind earlier admitted writes. Only the returned durable result confirms Stop. Uncertain outcomes remain visible and veto further Start; retry/reconciliation delegates to the existing receipt/content-identity machinery, not automatic replay.

A non-user permission or stream interruption closes runtime ownership but preserves durable recording intent. The token-guarded coordinator handoff accepts only the current epoch/generation and matching verified control, and cannot replace a pending Stop or uncertainty. Restored permission alone does not restart capture; an explicit Resume is required.

Deterministic fake/barrier tests are authored for startup, explicit resume, permission changes, stream termination, stale callbacks, admitted writes, Stop resource closure and interruption/Stop ordering. The source is included in both checked-in projects and the isolated-host source configuration. The first main-app build-for-testing attempt at `a7cb438` failed while emitting the test module: an internal parameterized test method accepted a private fixture type. The method is now `fileprivate`, preserving the fixture's intended visibility, all three argument cases and every assertion. This source correction has not been recompiled, and no tests ran. No successful app build is claimed; the earlier passing synthetic snapshot predates this layer and is not a result for it.

Default/UI integration, history-clear coordination, real-data migration, automatic recovery activation, hardware deployment and backend/sync remain separately gated. No battery, CPU, memory, disk/write-amplification, responsiveness or field improvement is claimed by adding an adapter.

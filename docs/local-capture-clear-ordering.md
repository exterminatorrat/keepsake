# Ordered coordinator history clear

This is a source-only extension of the opt-in foundation coordinator, not consumer wiring. KeepsakeApp, RecorderModel, default-store factories and history UI remain unchanged. The running app still uses its legacy repository clear and runtime-only Stop. No migration, automatic recovery, physical deployment or backend/sync is activated.

`LocalCaptureCoordinator.clearHistory(expectedControlRevision:operationID:)` uses the existing ordered command worker and receipt/uncertainty path. It does not introduce a second queue or imply Stop. A current recording or admitted Begin rejects a later clear. A clear may follow an already admitted Stop and its earlier append; the dispatch-time snapshot must be valid and stopped at the caller's expected revision. A failed or unconfirmed Stop cannot be bypassed.

Start is explicitly vetoed with `historyClearPending` while clear is queued or running, rather than saved for automatic activation after an uncertain outcome. The caller must issue a fresh Start after successful clear or reconciliation. Duplicate pending clear requests coalesce only for the same operation ID and expected revision; conflicting content is rejected. Another pending clear receives the same busy error.

Clear preserves the durable control revision, stopped intent and latest control receipt. Its deletion revision, cleared-through floor and last-clear receipt are read back from verified persistence. Invalid receipts or unknown write outcomes retain uncertainty and veto Start. Explicit reconciliation reuses the existing verified reopen and receipt lookup; it never starts runtime or replaces newer verified control with an older request snapshot.

Clear does not advance the recording control revision. An unavailable receipt and unchanged recording intent therefore do not prove noncommit: without affirmative matching clear evidence, uncertainty remains unresolved and no automatic clear retry or Start is allowed. A matching historical receipt can establish commit while preserving newer verified intent and receipts; newer active intent stays resume-required.

## Validation boundary

Fifteen new deterministic fake/barrier tests are authored for ordering, revision/receipt preservation and uncertainty, including unavailable lookup with affirmative durable evidence and conflicting clear-history receipts. They are not compiled or executed in this checkpoint; native verification needs a fresh scoped admission. The intended full coordinator/lifecycle selection has 40 declarations and 42 expanded invocations, including the unchanged three-row lifecycle case. These are source counts, not results. The earlier `a20e515` result (25 declarations / 27 invocations across those suites) predates this extension and is not a test result for it. No existing assertion or persistence error contract is weakened.

Before connecting a consumer, verify admitted append -> Stop -> clear ordering, Start veto during clear, Start-before-clear rejection, stale revisions, definite noncommit versus uncertainty, unavailable/mismatched receipts, latest intent/receipt preservation on reconciliation, and duplicate request identity. Full lifecycle/coordinator regression selection is needed because the fake and persistence interface are shared. Logical clear still does not mean physical pruning or measured history responsiveness.

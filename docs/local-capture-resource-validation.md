# Local-capture resource validation

This is a preparation plan, not a measurement report. No native build or test, process or resource probe, GUI operation, tool-help query, device query, or phone interaction was performed for this work. The fixtures and limits below define future test inputs; they are not performance targets, capacity results, or proof of field reliability.

## Scope and gates

- Run only against a fresh, isolated, explicitly opted-in local-capture store with deterministic synthetic samples. Do not switch the default store, import legacy routes, connect Supabase, or enable automatic recovery.
- Obtain a fresh, exact resource admission before any native run. Use one owner and one resource slot; do not overlap the measurement with cleanup, another build or test, or another device operation. A former grant or a connected XR does not renew authority.
- Resource admission comes first. Only after it is available may the Captain request a separate, finite phone scope. No phone scope is requested here.
- Keep XCTest-host attribution and exit unresolved until the separate help-only prerequisite documents a supported method. Device identity, test host/target, signing and provisioning also require fresh verification and applicable authority. A passing XCTest result, process name, path, or PID alone does not prove the exact test host exited.
- Keep route-bearing values out of logs, attachments, screenshots, and handbacks. `source-snapshot.jsonl` is potentially route data: never copy or print its rows. Report counts, byte totals, timings, and hashes only; keep any permitted raw result private and access-restricted.

## Current storage facts that constrain the plan

`RouteStore` stores data in `route.sqlite` with `manifest.json`; the source snapshot is named `source-snapshot.jsonl`. The current SQLite configuration sets `journal_mode=DELETE` and `synchronous=FULL`. The store also checks `route.sqlite-journal`, `route.sqlite-wal`, and `route.sqlite-shm` sidecars, so record which files actually exist rather than assuming WAL is active or changing the journal mode for a test.

The storage page limit is 256 rows and the encoded page payload limit is 256 KiB. The consumer plan uses a 128-row default and enforces the store limits. Measure one page at a time with the fixed query time and exact continuation cursor; do not materialize or retain the whole history.

## Bounded, baseline-first fixtures

Use each profile against its own fresh isolated store, serially. Fixture cadence and path shape are synthetic test inputs, not a proposed Core Location sampling policy. Do not proceed to the next scale until the preceding stage completes within its admission and no unresolved outcome remains.

| Stage | Synthetic input | Bounded check |
| --- | --- | --- |
| B0 tiny baseline | One 10-minute session with 60 deterministic points at 10-second intervals. | Append, read one 128-row page, issue Stop, close and reopen, then verify exact count, order, control state, and receipt. Record the initial per-run baseline before increasing the workload. |
| Stationary | 60 points over 10 minutes around a synthetic fixed point with a predeclared, deterministic jitter pattern. | Compare stored points to the fixture’s known stationary reference; report drift, duplicates, missing or out-of-order points, and writes. This tests deterministic handling, not GPS accuracy or energy. |
| Walking | 60 points over 10 minutes on a synthetic 600-metre polyline with two turns and a pause. | Compare against the exact fixture polyline and report error distribution, gaps, order, query cost, and Stop outcome. This does not establish real-world walking accuracy. |
| Driving | 60 points over 10 minutes on a synthetic 5-kilometre polyline with two stops. | Compare against the exact fixture polyline and report error distribution, gaps, order, query cost, and Stop outcome. This does not establish real-world driving accuracy. |
| H1 one-day history | 1,440 synthetic rows at one per minute across one day. | Query the day with the 128-row default and exact cursors; expect at most 12 pages. Verify page replacement and bounded memory, not a whole-day array. |
| H2 seven-day history | 10,080 synthetic rows at one per minute across seven days. | Only after B0 and H1 are reviewed and a fresh step-up is admitted. Query each day independently; at most 12 pages per day, 84 total. This is the upper bound in this plan, not a product capacity claim. |

The stationary, walking, and driving fixtures can check preservation of known synthetic coordinates and exercise consumers with different route shapes. They cannot measure sensor accuracy or battery use because they do not exercise the physical location hardware. A physical accuracy run needs an independently known reference and a separately approved finite field scope; without both, report accuracy as unmeasured.

## Measurement oracle

Record the exact build, device and OS when applicable, test target/process being measured, fixture and row counts, page size, run count, measurement tool/version, and any relevant thermal, charging, brightness, or network conditions. Keep runs serial and record each result before summarizing it. Report median, p95, and maximum only when the number of observations supports them; otherwise give the individual observations and state the sample count. Do not set a pass threshold from this preparation alone.

| Dimension | Measurement | Oracle and limits |
| --- | --- | --- |
| CPU | Use a focused XCTest `XCTCPUMetric` measurement where supported; use Time Profiler to attribute a material result. | Record CPU time per workload and the selected process. Do not attribute XCTest-runner CPU to the app-under-test without verifying which process the instrument measured. |
| Memory | Use XCTest `XCTMemoryMetric` or Instruments Allocations/Memory information for the selected process, with an idle baseline and a peak during the workload. | Report physical memory and delta from baseline. A simulator memory result is not a physical-device memory-safety result. |
| Physical disk and file growth | At entry, peak, after Stop/close, and after reopen, record the exact volume’s supported available-byte reading plus logical and allocated sizes for `route.sqlite`, `manifest.json`, any `source-snapshot.jsonl`, and any journal/WAL/SHM sidecars. | Keep volume free bytes distinct from file size and allocated blocks. If the authorized device-side capacity reading is unavailable, report that fact; do not substitute host free space, `du`, purgeable estimates, or database size for device free space. |
| WAL and write amplification | Record the actual journal mode and sidecars; use `XCTStorageMetric` for XCTest’s logical writes and Instruments File Activity plus Disk Usage/Disk I/O data for attributable filesystem and physical writes. | Report payload bytes, logical file-write bytes, physical bytes, and file growth separately. Calculate ratios only when the numerator and denominator are attributable to the same workload window; otherwise mark them unavailable. A `-wal` sidecar’s absence or presence is an observation, not a reason to change storage mode. |
| Page query | Time each `readPage` request from invocation to returned page, including cursor continuation, with the fixed query time and requested row limit. | Verify returned rows and cursor against the fixture; report duration, rows returned, and page count. Never infer complete history from one page. |
| Stop and UI response | Measure separately: Stop request to runtime closure; Stop request to durable outcome/receipt; and Stop action to the updated UI state. Use focused clock/signpost measurements where available and a supported UI-hitch instrument for rendering. | A fast button response does not prove persistence; a durable outcome does not prove a responsive UI. Record each interval and any hitches without a threshold invented here. |
| Accuracy | For synthetic fixtures, compare every persisted coordinate to its known synthetic reference and report distance-error distribution, missing/duplicate/out-of-order counts, and `horizontalAccuracy` values separately. | Apple describes `horizontalAccuracy` as an uncertainty radius, not observed error against ground truth. Synthetic accuracy is not field accuracy; do not report a physical accuracy result without independent reference data and finite consent. |
| Energy | For a later authorized physical run, use Instruments Power Profiler on a supported device and compare stationary, walking, and driving traces on the same device, OS, build, and controlled conditions. | Apple lists Power Profiler for iPhone with iOS 26 or later and says power-impact values vary by device model. If unavailable for the approved device/OS, mark energy unmeasured; battery-percentage deltas and synthetic replay are not substitutes. |

Apple’s XCTest metrics distinguish CPU, clock, physical memory, hitches, and logical storage writes. Apple’s disk-write guidance also distinguishes logical filesystem activity from physical disk activity, so one counter must not be presented as the other. Use only a focused XCTest measurement and the smallest relevant Instruments trace; no benchmark framework is proposed.

## Stop, reopen, and failure outcomes

For each admitted scale, verify the normal Stop path, close/reopen, and page through the expected synthetic history. Exercise existing deterministic fault seams for write, clear, and reconciliation outcomes; an unknown commit remains uncertain until explicit verified reconciliation, with no automatic clear retry or Start. Do not induce an out-of-space condition, send a process signal, terminate an XCTest host, or claim recovery from a `Passed` result. A real process-interruption run remains gated on the separate, run-attributable host-identity/exit prerequisite and fresh device authorization.

## Privacy and reporting

Generate coordinates and timestamps deterministically in test code; do not read legacy route files or use personal routes. Do not attach raw JSONL, database files, process dumps, location screenshots, or unsanitized `.xcresult` contents. Keep any later authorized native artifacts in a private local result root with restrictive directory/file permissions; publish only sanitized aggregate measurements and artifact hashes. Preserve input manifests and accepted native evidence unchanged.

## References

- [Apple: Performance Tests](https://developer.apple.com/documentation/xctest/performance-tests.md) and [XCTOSSignpostMetric](https://developer.apple.com/documentation/xctest/xctossignpostmetric.md)
- [Apple: Reducing disk writes](https://developer.apple.com/documentation/xcode/reducing-disk-writes.md)
- [Apple: Measuring your app’s power use with Power Profiler](https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler.md)
- [Apple: Gathering information about memory use](https://developer.apple.com/documentation/xcode/gathering-information-about-memory-use.md)
- [Apple: Simulating location in tests](https://developer.apple.com/documentation/xcode/simulating-location-in-tests.md)
- [Apple: Running your app on simulated or physical devices](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices.md)
- Internal source facts: `Keepsake/Storage/RouteStore.swift`, `Keepsake/Storage/RouteStoreFiles.swift`, and `Keepsake/Storage/LocalCapturePersistence.swift`.

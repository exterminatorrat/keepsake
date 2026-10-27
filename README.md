# Keepsake

Keepsake is a native iOS prototype for recording and revisiting daily routes.

## Local recorder foundation

The app uses SwiftUI, Core Location and MapKit on iOS 18 or later. Recording is explicitly started and stopped by the person using the app. The default store is local JSONL with a 90-day retention cutoff; a separate SQLite implementation is prepared for synthetic compatibility testing but is not selected by the app.

There is no backend connection, upload, account system or automatic recording restoration. Recording intent is currently in memory. iOS can delay or interrupt location delivery, and a drawn route is not evidence of uninterrupted capture.

## Development

Open `Keepsake.xcodeproj` for the app or `StorageValidation/KeepsakeStorageValidation.xcodeproj` for the isolated synthetic test host. The matching `project.yml` files describe the projects for XcodeGen users; generating projects is not required to read the checked-in source.

Personal signing configuration and bundle identifiers are not checked in. Supply your own values as Xcode build settings:

| Setting | Used by |
| --- | --- |
| `KEEPSAKE_APP_BUNDLE_IDENTIFIER` | App target |
| `KEEPSAKE_VALIDATION_BUNDLE_IDENTIFIER` | Isolated validation host |
| `KEEPSAKE_VALIDATION_TEST_BUNDLE_IDENTIFIER` | Isolated validation test bundle |

For unsigned simulator validation, set `CODE_SIGNING_ALLOWED=NO` and provide the two validation identifiers, for example `com.example.keepsake.validation` and `com.example.keepsake.validation.tests`. Physical-device signing and installation require separate local configuration and consent; no profiles, certificates or signing account values are included.

Tests construct synthetic routes in owned temporary directories. Simulator fixtures explicitly model unavailable protection readback; they cannot establish physical-device encryption or background reliability. See [local recorder boundaries](docs/local-recorder.md).

## Lifecycle and storage hardening

Runtime generations now fence old stream/session completions. Start waits for storage readiness, clear/write operations serialize, permission refreshes coalesce, and storage faults do not disable an active Stop control. JSONL verifies protection before writing location bytes; SQLite post-COMMIT failures are reported as uncertain rather than falsely rolled back. Fake platform handles and deterministic barriers cover the intended interleavings in tests.

These changes do not make Stop durable or activate automatic recovery. The SQLite store remains separate from the app's default JSONL path.

## Synthetic durable capture foundation

An explicitly created schema-v2 store now provides durable capture epochs, Begin/Stop fences, bounded ordered batches and retained operation receipts. A separate, unactivated coordinator serializes those commands, closes runtime admission immediately on Stop and keeps uncertainty vetoed until explicit reconciliation. Neither is selected by the app; its Stop remains runtime-only. See [the local capture foundation](docs/local-capture-foundation.md) for limits and validation boundaries.

The synthetic store also has bounded history pages, deletion-aware cursors, stopped-only logical clear receipts and chunked physical pruning. These source APIs are not connected to the app's history UI or coordinator clear flow and have no successful build or executed-test result.

## Validation status

This is a curated source checkpoint, not a release. The portable isolated host at commit `49a6c1f` built unsigned with the iOS Simulator 27.1 SDK, and all nine `RouteRepositoryTests` passed on iOS 26.5, including the corrected post-rename regression. The test now checks exact prepared-to-published bytes and bit-exact decoded sample values without assuming a stable key order across independent JSON encodings.

The earlier original local staging result remains part of the provenance: 53 passed, one failed and two hardware-only checks were skipped among 56 selected tests. The new narrow run did not rerun the other three suites, compile the main app target or validate Wave 2, hardware protection, field coverage or app resource performance.

## Scope boundary

Default-store/UI integration and measured resource use remain planned local foundations. Backend sync, group sharing, saved-place alerts, memories and chat are not enabled by this prototype.

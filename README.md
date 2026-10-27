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

## Validation status

This is a curated source checkpoint, not a release. The published snapshot has not been compiled or test-executed. Static source/project review does not establish runtime correctness, field coverage, battery use or hardware protection.

## Scope boundary

Durable recording intent, bounded history queries and measured resource use are planned local foundations. Backend sync, group sharing, saved-place alerts, memories and chat are not enabled by this prototype.

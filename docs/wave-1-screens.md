# Early Wave 1 screen slice

This child of the local-recorder foundation implements the native screen and state boundary only. The production entry constructs `AppSession(services: .production)`, not `RecorderModel`. Production services explicitly report that real sign-in is not configured. Entering an email must not synthesize an account or a group. No SDK, key, backend migration, Auth request or demo sign-in has been added.

The source includes minimal Email/Code presentation, restoring/configuration/error states, a private solo-group name form and the five-tab Groups shell. The reference surfaces are G01/G02/G03, self-only M01/M02 and S00/minimal Account. Features outside this slice explain that they are unavailable. There are no fake live dots, other members, activities, route geometry, location/camera/contact requests or production fixture fallbacks.

`AppSession` owns account generations and async request revisions; stale results cannot replace current identity/group state. Auth effects are joined before completing sign-out. Group creation retains one in-memory operation identity through uncertainty and checks status before retrying it. These are testable state seams, **not** complete Auth integration, Keychain restoration, durable pending-create storage, database membership/RLS enforcement or device-grade account isolation. Those require the planned real adapters and authorized backend acceptance. No route archive is opened, assigned to an account, migrated or deleted.

## Source ownership and preserved baseline

Shared domain types, AppSession/AppServices/root composition and native project membership belong to the Wave 1 integration owner. Auth and Groups views accept injected state/actions. The previous recorder/domain/storage source and all existing recorder tests remain intact. SQLite/coordinator/experimental entry activation is outside this change.

The approved reference inputs are in project Drive `plans/reference-crops/`. Auth screens use their restrained typography, pale surfaces, rounded controls and purple accent; the PDF does not contain an exact Email/Code screen. Production account/group content uses known values only. Preview and test fixtures are separately injected and named as fixtures.

## Validation status

The original `1cb9147` checkpoint passed one authorized focused compile/test run (28 declarations, 58 expanded invocations). A separately authorized manual render run passed one XCTest and exported all 15 intended 402×874-point images, but visual inspection found incomplete map backgrounds, content-driven sheet anchors and selector truncation. Those original results/images are preserved; neither establishes acceptance of this corrective source revision.

The corrective revision has only source/data structural checks. No compiler/frontend, SDK typecheck, Vision, Xcode, Simulator or native render has run against it. The earlier leaves' subset compiler/Vision output is separate provenance, not admitted integrated verification. PR9 stays draft; no new visual-fidelity or accessibility pass is claimed.

## Reference correction and capture contract

| Before | Corrective source | Why |
| --- | --- | --- |
| Sheet height followed the number of truthful rows. | `GroupSheetLayout` uses reference heights 328/548/198 in the 720-point reference content viewport, with available-height/header clamps and scrolling. | G01/G02 envelopes no longer depend on fake activity or people; selector-open G03 uses a compact one-member strip. Runtime safe-area alignment remains to be checked. |
| A 182-point menu spent most of its row width on monogram/padding/spacers. | Pill/menu share one bounded width; the selected row has a smaller monogram, caption-sized normal name, wrapping and measured scroll height. AX headers stack and give the name more width. | Normal names gain space; long names can wrap/scroll without inventing groups or widening only the menu. Native typography/AX interaction remains unverified. |
| Root hosting controllers were replaced between single-yield draws. | One test-only container pairs child appearance transitions; readiness requires actual parent/child appearance, nonzero stable geometry across display frames, and a positive map-render callback where a map is visible. | The logged appearance/zero-size Metal diagnostics are leads, not proof of a network or production-map defect. No production MapKit replacement or arbitrary sleep is introduced. |

For the six map-visible poses, the test finds the owned hierarchy's public `MKMapView` and temporarily forwards its delegate through a test-only observer. The original delegate is pinned, unrelated optional selectors are forwarded, and teardown restores it only if the test still owns that delegate slot. A delegate change, missing/ambiguous public map, loading error or 12-second deadline cannot pass readiness. A loading-complete callback or elapsed frames alone is not tile readiness: the required signal is `mapViewDidFinishRenderingMap(... fullyRendered: true)`, followed by stable geometry frames. This SDK-specific observation path and Swift concurrency/Objective-C bridge remain uncompiled/unrun risks.

The observer's sole `nonisolated(unsafe)` field is an immutable, strongly pinned downstream delegate, read only by NSObject selector-query/forwarding overrides. UI mutation, callback processing and teardown stay on MainActor; MapKit documents delegate delivery on the main thread. No mutable capture state crosses that bridge. Remove the escape hatch when SDK selector isolation permits a checked equivalent; it must not spread to production or suppress other diagnostics. First authorized compilation must validate this boundary rather than treating the source review as a concurrency pass.

The original draw assertion is retained and a stricter readiness assertion added. Every attempted pose still attaches its actual image and a `READINESS-<label>` JSON state even when readiness fails, so partial/unavailable/timeout evidence is not erased. Readiness records contain appearance/layout/map/deadline state and sanitized error domain/code, not arbitrary network error details. A successful callback/draw still needs human inspection of map content, attribution and overlay fidelity.

The manual `KeepsakeScreenReference` scheme now selects GroupsNavigationTests, GroupSheetLayoutTests, ReferenceReadinessTests and the original render method. Source coverage is 20 declarations / 30 expected expanded invocations: 10 navigation, four layout declarations (11 invocations), five readiness declarations (eight invocations), and one XCTest capture. These are expectations from source, not passed results. All 15 fixture labels and test-only activation remain unchanged; the proposed export includes 15 images plus 15 JSON readiness records.

Smallest next verification proposal, not an executable grant:

1. Bind the exact final child-head SHA, one permitted retained iOS Simulator destination, a new task-owned DerivedData/xcresult directory and one finite shared-Mac nonoverlap window. Apply the retained physical-space/memory/timeout/handback contract; old run grants are consumed. Use standard Xcode tools, not a custom runner/guard.
2. One unsigned `xcodebuild test` against `Keepsake.xcodeproj` / `KeepsakeScreenReference`, selecting only the three suites and one capture class listed above. This compiles the real app/test target and groups the necessary focused unit and visual evidence in one run; no recorder construction or real backend is expected. Include ordinary MapKit tile/basemap/attribution traffic. Retain raw output and the original result bundle, and reconcile source declarations/argument rows/issues/skips rather than merely exit status.
3. The test-only environment gate stays in that manual scheme, not a production launch mode; without it the capture skips. Export all attachments using the standard result tool, reconcile 15 images and 15 readiness records, and inspect actual content against the approved crops. Record actual point/pixel dimensions; do not resize the Simulator or stretch a different size into baseline. Accessibility/keyboard/gesture/alternate-size acceptance is still separate; this scope does not add those campaigns. Attachment creation or delegate completion alone is not visual acceptance.
4. Perform only the explicitly named standard simulator shutdown/state/resource handback. Do not infer global machine idleness or historical custody repair from a test exit. Timeout/unknown outcomes retain the relevant exclusion until disposition.

No backend wake/resume/configuration/SQL, real email send, phone install/capture, permission change, merge, release, packaging, benchmark, accepted-pointer movement or storage activation is covered by this proposal.

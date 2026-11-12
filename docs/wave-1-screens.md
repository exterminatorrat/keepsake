# Early Wave 1 screen slice

This child of the local-recorder foundation implements the native screen and state boundary only. The production entry constructs `AppSession(services: .production)`, not `RecorderModel`. Production services explicitly report that real sign-in is not configured. Entering an email must not synthesize an account or a group. No SDK, key, backend migration, Auth request or demo sign-in has been added.

The source includes minimal Email/Code presentation, restoring/configuration/error states, a private solo-group name form and the five-tab Groups shell. The reference surfaces are G01/G02/G03, self-only M01/M02 and S00/minimal Account. Features outside this slice explain that they are unavailable. There are no fake live dots, other members, activities, route geometry, location/camera/contact requests or production fixture fallbacks.

`AppSession` owns account generations and async request revisions; stale results cannot replace current identity/group state. Auth effects are joined before completing sign-out. Group creation retains one in-memory operation identity through uncertainty and checks status before retrying it. These are testable state seams, **not** complete Auth integration, Keychain restoration, durable pending-create storage, database membership/RLS enforcement or device-grade account isolation. Those require the planned real adapters and authorized backend acceptance. No route archive is opened, assigned to an account, migrated or deleted.

## Source ownership and preserved baseline

Shared domain types, AppSession/AppServices/root composition and native project membership belong to the Wave 1 integration owner. Auth and Groups views accept injected state/actions. The previous recorder/domain/storage source and all existing recorder tests remain intact. SQLite/coordinator/experimental entry activation is outside this change.

The approved reference inputs are in project Drive `plans/reference-crops/`. Auth screens use their restrained typography, pale surfaces, rounded controls and purple accent; the PDF does not contain an exact Email/Code screen. Production account/group content uses known values only. Preview and test fixtures are separately injected and named as fixtures.

## Validation status

The integrated source checkpoint has not had an Xcode build, app launch, iOS test run or render. The isolated leaves additionally reported compiler syntax checks and an SDK typecheck of their subsets under their interpretation of static validation; those were not a fresh admitted native verification scope and do not validate the integrated head. Static membership/plist/source-continuity/whitespace checks are distinct from native acceptance. No screenshot or visual-fidelity pass is claimed. The pull request remains draft until a fresh bounded native scope permits checking it.

Smallest next verification proposal, not an executable grant:

1. Bind the exact final child-head SHA, one permitted retained iOS Simulator destination, a new task-owned DerivedData/xcresult directory and one finite shared-Mac nonoverlap window. Apply the retained physical-space/memory/timeout/handback contract; old run grants are consumed. Use standard Xcode tools, not a custom runner/guard.
2. One unsigned `xcodebuild test` against `Keepsake.xcodeproj` / `Keepsake`, selecting only `KeepsakeTests/AppSessionTests`, `KeepsakeTests/AuthInputTests` and `KeepsakeTests/GroupsNavigationTests`. This compiles the real app/test target; no recorder construction or real backend is expected. Retain raw output and the original result bundle, and report exact declarations/issues/skips rather than merely exit status.
3. Separately authorize `KeepsakeScreenReference` / `WaveOneReferenceRenderTests.testScreenReferenceAttachments` and its MapKit tile-network behavior when needed. The test-only environment gate is set by that manual scheme, not a production launch mode; without it the render test skips rather than silently rendering MapKit in ordinary unit runs. It emits 15 named synthetic-state image attachments at the actual native window size. Capture at the 402×874-point baseline where the permitted destination supports it, compare app-owned regions against deterministic reference crops, and inspect accessibility and small/large text layouts. Attachment creation alone is not a visual pass. Preview source is not visual evidence.
4. Perform only the explicitly named standard simulator shutdown/state/resource handback. Do not infer global machine idleness or historical custody repair from a test exit. Timeout/unknown outcomes retain the relevant exclusion until disposition.

No backend wake/resume/configuration/SQL, real email send, phone install/capture, permission change, merge, release, packaging, benchmark, accepted-pointer movement or storage activation is covered by this proposal.

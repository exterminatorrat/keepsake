# Auth and member-card reference refresh — source only

This revision implements Harry's November 12 UI feedback on PR9. It is **uncompiled, unrendered and untested**. The admitted 49fdf16 checkpoint (20 declarations/30 invocations/15 image pairs) remains older-head evidence. All native grants are consumed; this document proposes no new command or reservation.

## References and asset gaps

`Footprint_Authentication_Workflow_Board.png` (1536×1024, SHA256 `fe965eea4c50d29464b54dd39528dbbe1db6c6e00b05fa529e2167b0960e494a`) supersedes the assistant-designed auth appearance. All seven primary screens and six supporting states were inspected, including enlarged reference-only crops. Its roughly 200-pixel-wide phone drawings are not clean native-size artwork exports.

The separate Life360 reference is only a 112×472 edge crop (SHA256 `aa32ad07140c0285d4373bb3defe8e5d43f4390424212db0ac3385fb5dbc2bac`). It establishes smaller-gutter direction, not an unseen full layout or exact pager specification.

No clean scenic, avatar or location-illustration asset exists in this repository. Welcome/completion use an explicitly labeled neutral scenic placeholder; avatar/location use system-symbol placeholders. No board crop containing phone chrome/text is used as product artwork. No fonts, stock images or services were downloaded. Photography/illustration and exact native visual matching remain gaps, not a claimed new direction.

## Auth presentation

The new composition follows the board's scenic welcome/completion framing, rounded bottom provider/button panels, pale form backgrounds, back rows, spaced headings, six OTP cells, centered profile/permission explanations and bottom actions. It is branded Keepsake, uses system Dynamic Type and scrolling content, and keeps form actions above the native keyboard safe area.

| Reference | Presentation and safety boundary |
| --- | --- |
| AUTH01 Welcome | Apple/phone options are disabled and visibly unconfigured. Email opens entry, not an authenticated account. Missing Terms/Privacy URLs produce an explanatory notice, not fake links. |
| AUTH02 Phone/email | Email OTP is the only planned supported real mechanism. Production configuration errors disable submission. The separate phone fixture is visibly unavailable and offers email instead; no SMS/Apple implementation. |
| AUTH03 Verification | One accessible native TextField owns six visual cells, oneTimeCode AutoFill, paste and deletion. Editing retains at most six ASCII digits; strict existing service-boundary validation is unchanged. Six digits submit through the existing guarded callback, with a keyboard-toolbar fallback. Actual keyboard/AutoFill behavior is unverified. |
| AUTH04 Profile | Name draft and avatar/photo affordance are preview/test presentation only. Nothing persists to an account; the photo button explains that no picker is enabled. |
| AUTH05 Location | Explanation/capability rows, Continue and Not Now. No authorization request, location service or live/background-sharing promise. |
| AUTH06 Notifications | Explanation, visibly unavailable Allow Notifications and Not Now. No OS prompt or notification registration. |
| AUTH07 Complete | Preview/test only; explicitly states that no account/group was created. The Groups action shows a preview notice rather than entering a fake group. |
| Wrong code / expiry / loading | Inline red error below cells, expiry resend and centered progress. These are injected poses, not asserted server observations. Live errors remain the existing external state. |
| Location off / notifications off | Injected known states, unavailable Settings controls and Not Now. No device authorization was queried or Settings URL opened. |
| Invitation completion | Clearly labeled sample invitation; explicitly says no group was joined. No membership or invitations backend. |

The live AuthPresentationNavigation has only welcome, entry and verification destinations. Production root constructs no preview workflow or local advance-to-profile/completion bypass. Only AppSession's existing externally verified identity transition can enter signed-in Groups. AppSession, production service factory and domain identities are unchanged/configuration-blocked. Post-verification screens are authored views consumed by the DEBUG preview/test host, not implemented profile persistence/onboarding backend work.

The DEBUG host has no service dependency and uses fixed fixture strings and a fixed display date for its 0:42 countdown. It is not a launch flag, provider adapter or demo login. Unsupported providers cannot advance the live presentation router. Existing request/account-generation fencing remains unchanged.

## Higher controls and finite member pager

Both Groups header sites use a 2-point top inset instead of 10, raising settings, group pill and notification controls together toward the inherited safe-area edge. There is no negative offset or system-chrome overlay. Their 48/44-point targets, shared pill/menu width, selector anchor/spacing and accessibility-size stacked row remain. This is source intent, not a measured new render.

The member card uses 12-point even gutters, 24-point continuous radius and a quieter local shadow. Production constructs exactly the real self presentation from the supplied account identity. With one member there is no swipe affordance, page count, invented neighbor or wrapping.

The finite multi-member presentation uses native horizontal ScrollView, scrollTargetLayout, view-aligned snapping and scrollPosition keyed by stable AccountID. Four-point gaps within 12-point outer margins allow narrow adjacent-card peeks in fixtures. No cloned end cards, looping timer or manual swipe recognizer. Previous/next controls and an accessible adjustable count stop at both ends; programmatic movement respects Reduce Motion. Actual peeks/swipes/focus/AX layouts are unrendered.

GroupsNavigation owns production selection. Rows select the self ID; scrolling and card actions update that same ID before detail opens. Detail reads the selected presentation. Account ID/generation changes reset selection/local surface state; the root's generation identity fence remains. Three clearly labeled DEBUG sample-member fixtures cover first/middle/last selection and row/card/detail synchronization without adding real membership.

The previously verified GroupMapBackdrop is byte-identical: its public bottom safeAreaInset still owns actual footer content, the outer tab reservation remains, and blanket legal hit-test/AX suppression or whole-map painting does not return. New member content lives inside that reservation. Detent constants/function/tests are unchanged. New-head attribution visibility needs separate native evidence; the older visible attribution is not a new-head pass.

## Authored checks — not executed tests

AuthPresentationTests adds eight declarations/15 expanded invocations for route/provider policy, external verification/back navigation, OTP paste/deletion/ASCII bounds and presentation ordering. GroupMemberSelectionTests adds seven declarations/11 invocations for self identity, bounded selection, stable-ID reorder/removal, shared detail selection, same-account generation reset and gutter/top-inset math. These formatter/model checks cannot prove native keyboard, gesture or accessibility behavior.

Existing tests/assertions are preserved. The original 15 fixture labels remain; the same manual capture mechanism appends 15 DEBUG auth poses (seven primary, six supporting, configuration and unavailable phone) and three sample-pager poses. Intended expanded selection: **35 declarations/56 invocations and 33 PNG/readiness pairs**. Those are source inventory expectations, not results or a native proposal. The six real-map readiness requirements and fail-closed observer are unchanged.

Source/data checks cover 40 app/15 test source membership, scheme XML and mirrored selections/environment, whitespace, reference hashes, old assertion/label retention and unchanged factory/services/domain/recorder/storage/map-reservation bytes. No Swift parser/compiler/frontend, SDK typecheck/execution, Vision, Xcode/Simulator/runtime, picker, OS authorization, backend call or native reservation ran. There are no screenshots of this new source.

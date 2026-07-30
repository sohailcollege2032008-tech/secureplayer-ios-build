# SecurePlayer iOS Build — Project Context for AI Agents

## What This Repo Is

A **standalone, iOS-only extraction** of the SecurePlayer Flutter student app. It exists because iOS builds require a Mac (or a cloud-Mac CI runner), which the primary development machine doesn't have — this repo is the thing that actually gets built via Codemagic.

**Critical fact: this repo has its own, completely separate git history from the main `secure` repo** (`D:\Projects\Antigravity\secure`). It was created via `Initial iOS build handoff — SecurePlayer Flutter app` as a fresh `git init`, not a subtree/filter-branch extraction. There is **no shared commit ancestry** between the two repos.

**Consequence — read before assuming anything about syncing:**
- `git merge` / `git cherry-pick` between `secure` and `secure-ios-build` **will not work** (unrelated histories).
- Any Dart-level UI or logic change that needs to exist in both repos must be **manually ported**: read the change in one repo, re-apply the same edit by hand in the other, commit separately in each. This has been the working pattern all along (see commit messages referencing "ported to iOS" — that always means a manual re-implementation, not a git operation).
- `secure`'s own repo also still contains an `ios/` folder (leftover from before this extraction) — **that folder is stale and must not be used to build iOS.** It's missing Xcode project registration for the security Swift files (they're on disk but never wired into `project.pbxproj`'s build phases) and several fixes that only ever landed here (false-positive jailbreak block on legitimate App Store/TestFlight installs, privacy usage strings, encryption export compliance declaration). This repo (`secure-ios-build`) is the only correct source for iOS builds.

## Branch Model

This repo follows the same base → brand-fork pattern used for the whole SecurePlayer system:

| Branch | Role | Bundle ID | Notes |
|---|---|---|---|
| `main` | **Base, unbranded SecurePlayer** | `com.secureplayer.securePlayer` | Display name "Secure Player". Any new brand forks from here. |
| `whitelabel-full` | Mashrou3 Dactoor — **production** | `com.mashrou3dactoor.player` | Full feature set: account deletion, privacy consent, App Info. No test bypasses. This is what gets handed off for a real App Store Connect build. |
| `whitelabel-visual` | Mashrou3 Dactoor — **cloud-testing/demo only** | `com.mashrou3dactoor.player` | Lighter branch (no account deletion/consent code). Has `SKIP_DEVICE_CHECK` / `AUTO_IMPORT_DEMO` dart-define flags baked into some Codemagic build commands — **never use this branch's build output for anything except Appetize/BrowserStack/Codemagic App Preview cloud testing.** |

A change that's brand-agnostic (a real bug fix, a security fix, a base feature) belongs on `main` first, then gets manually ported to the brand branches. A change that's brand-specific (bundle ID, contact info, demo account) only ever goes on the brand branches.

## Security Layer (iOS-specific)

Native Swift files (`ios/Runner/SecurityChannel.swift`, `ios/Runner/ScreenProtectionPlugin.swift`) implement the iOS side of jailbreak/Frida/tamper detection and screen-recording blackout, mirroring Android's existing `MainActivity.kt` implementation. Wired into `AppDelegate.swift` via two channels: `secureplayer/security` (MethodChannel, one-shot checks) and `secureplayer/security_events` (EventChannel, continuous stream — `recording_started/stopped`, `hdmi_connected/disconnected`, `focus_lost/gained`). The Dart side (`root_detection_service.dart`, `screen_protection_service.dart`) is fully shared/generic — no iOS-specific Dart branching beyond routing through the same EventChannel Android already uses.

**Do not forget the Xcode registration step** if either Swift file is ever re-added or replaced: both need `PBXBuildFile`/`PBXFileReference`/Sources-phase entries in `project.pbxproj`, added via Xcode's "Add Files to Runner…" UI on an actual Mac. Dropping a file into the folder and committing it via git does **not** get it compiled — this exact mistake is why `secure`'s own stale `ios/` folder doesn't actually run its security checks despite having the source files present.

**⚠️ CRITICAL, currently true on every branch of this repo (`main`, `whitelabel-full`, `whitelabel-visual`) as of 2026-07-23:** `RootDetectionService._iosDetectionTemporarilyDisabled = true` in `lib/security_layer/root_detection/root_detection_service.dart` — `_detectCauseIOS()` short-circuits to `RootDetectionCause.none` unconditionally, so **all iOS jailbreak/Frida/tamper detection is currently inert**, regardless of what's built above. This was a deliberate stopgap the user explicitly instructed (a borrowed test device was false-positive blocked; see memory `project_ios_detection_disabled.md` / `feedback_ios_security_override.md` for the full story and revert steps) — **do not silently flip it back without the user's explicit sign-off**, but **do not let a real App Store submission go out with this still `true`** either. Always `git grep _iosDetectionTemporarilyDisabled` before telling anyone this repo's iOS build has "full security" or "no bypass" — a previous session made that exact claim about `whitelabel-full` without checking this flag.

## Codemagic CI (`codemagic.yaml`)

Team workspace app: `secureplayer-ios-build`, app ID `6a603b35714cb06697d16f6f`, `settingsSource: "file"` (reads `codemagic.yaml` directly, workflow IDs match the yaml keys). Trigger builds via the Codemagic REST API (`POST /apps` to create, `POST /builds` to trigger with `{"appId", "workflowId", "branch"}`) using the API token the user has previously shared for this project — ask for it again if you don't have it; do not guess or reuse one from elsewhere.

Three workflows:

1. **`ios-unsigned-build`** — unsigned real-device build for Sideloadly. No Apple Developer account needed at all (`CODE_SIGNING_ALLOWED=NO`). Produces `secure_player_unsigned.ipa`. **Confirmed working** on `whitelabel-full` (build succeeded end-to-end in ~6.5 min, all steps green).
2. **`ios-simulator-build`** — Simulator build for Appetize.io/BrowserStack (zipped `.app`) **and** Codemagic's own App Preview / Quick Launch (needs the raw unzipped `Runner.app` declared directly in `artifacts:` — Codemagic doesn't unzip artifacts itself). **Confirmed working** on `whitelabel-full`. Note: Codemagic App Preview itself is a separate feature that must be manually enabled from a dedicated page in the Team workspace sidebar (paid/trial-minutes gated) — that's the user's own billing decision, not something to enable on their behalf.
3. **`ios-app-store-release`** (only on `whitelabel-full`) — signed archive build via Codemagic's `app_store_connect` integration, publishes straight to TestFlight + submits for App Store review (`release_type: MANUAL`, so it doesn't auto-publish to the live store the moment Apple approves it). **Not yet testable** — blocked on external prerequisites only the account owner can supply:
   - An active Apple Developer Program membership ($99/yr)
   - An App Store Connect API key (Issuer ID + Key ID + `.p8`) registered as a Codemagic Team integration named `mashrou3_asc` (or rename the yaml reference to match)
   - A real App Store Connect app record for `com.mashrou3dactoor.player`, and its numeric Apple ID pasted into `APP_STORE_APPLE_ID` in the yaml (currently a `0000000000` placeholder)

**Every time you touch `codemagic.yaml` on a build-affecting change, actually trigger the relevant workflow and poll it to completion before telling the user it works** — `flutter analyze` passing does not prove a real Xcode/CocoaPods build succeeds. Use the REST API polling pattern (`GET /builds/{id}`, loop while `status` is `queued|building|fetching|preparing`, `sleep 45` between checks) — **use a `while` loop that continues on those statuses, not an `until` loop with those same statuses as the exit condition** (an earlier session inverted this and got a false "done" reading after a single check).

## App Store Reviewer Demo Account (Apple Guideline requirement)

Apple App Review needs sign-in credentials, and their environment has no Telegram account / teacher relationship to receive a real `.sec` file through. Solved with a **runtime-gated** auto-import (NOT a build flag):

- Account: `screenshot.demo@mashrou3dactoor.test` / `Screenshot2026!` — a real Firebase Auth account, genuinely enrolled in a real demo course/lecture in Firestore.
- `lib/features/courses/course_list_screen.dart`: on login, if `FirebaseAuth.instance.currentUser?.email == 'screenshot.demo@mashrou3dactoor.test'` (only on `whitelabel-full`), auto-imports the bundled `assets/demo/demo_course.sec` (lecture_id `demo_screenshot_lecture_001`) if not already imported.
- **Why this is safe to ship in the exact binary submitted to Apple**: it's gated on account identity, not a compile flag — real customers' sessions are completely untouched, and this account's device still binds normally on first login (no `SKIP_DEVICE_CHECK`, no other bypass). Apple approves and releases the literal binary you submit — there is no separate "reviewer-only" build — so anything that weakens security for everyone (like `SKIP_DEVICE_CHECK`) must never be in this branch's build commands. `whitelabel-visual` has that flag baked in deliberately for cloud-testing only; **never carry that pattern into `whitelabel-full`.**

## Branding polish (Mashrou3 Dactoor)

- `lib/features/auth/login_screen.dart` — the big title text must read the actual brand name, not the literal string `'SecurePlayer'`. Fixed on `whitelabel-full`/`whitelabel-visual`, likely to recur on any future brand branch forked from `main` (which correctly still says "SecurePlayer" since that's the base/unbranded name).
- `lib/shared/widgets/app_drawer.dart`'s App Info dialog (distinct from the "About" dialog) intentionally does **not** explicitly solicit "want an app like this built for you" — just states the platform is developed by Dr. Sohail Ahmed and gives contact cards (Telegram + email). Don't re-add an explicit pitch line here unless asked.

## Theme Centralization — DONE 2026-07-23 (`whitelabel-full` + `whitelabel-visual` only, not `main`)

`lib/app/theme.dart`'s `AppTheme` class already had a real `ThemeData` wired into `MaterialApp`, but its color constants were private (`_primary`/`_background`/`_surface`) and no screen actually consumed them — every screen hardcoded its own `Color(0xFFxxxxxx)` literal instead. Made them public, added a 4th (`secondaryAccent`, canonicalizing an existing `0xFF9C95FF`/`0xFF9C94FF` typo split), then mechanically swapped every hardcoded literal across ~33 files for the matching `AppTheme.*` reference (scripted replace + import insertion, `flutter analyze` confirmed clean on both branches). Pure refactor, zero visual change. **Re-theming this brand (e.g. to match the Mashrou3 Dactoor logo) is now a 4-constant edit in `lib/app/theme.dart`** — no color value has actually been changed yet, only the plumbing. Deliberately not applied to `main` — user chose shipping speed over "every future brand inherits it" architecture.

## iOS FairPlay DRM (added 2026-07-30, `main` branch only)

Built to fix the actual reason Apple rejected this app: `ScreenProtectionPlugin.swift`'s screen-recording blackout ran with no real DRM behind it. See `secure` repo's own `CLAUDE.md` ("iOS FairPlay DRM System" section) for the full backend architecture (KSM, Cloud Functions, packaging pipeline) — this section covers only what lives in *this* repo.

### What changed here
- **`vendor/better_player_plus/`** — a local fork of the `better_player_plus` pub package (pubspec.yaml now points at `path: vendor/better_player_plus` instead of the pub.dev version). Upstream's FairPlay support (`BetterPlayerEzDrmAssetsLoaderDelegate.swift`) is streaming-only; this fork adds `FairplayContentKeyManager.swift` / `FairplayContentKeyDelegate.swift` — a real `AVContentKeySession` + persistable-offline-key implementation adapted directly from **Apple's own official sample** (`Development/Client/HLS Catalog With FPS/` inside the FairPlay Streaming Server SDK, not written from scratch). A new `offlineFairplayConfig` field (JSON string: `ksmProxyUrl`, `idToken`, `lectureId`, `videoId`, `courseId`, `deviceId`) was threaded through the *entire* Dart→native chain (`BetterPlayerDrmConfiguration` → `BetterPlayerDataSource` → `DataSource` → `method_channel_video_player.dart` → `SwiftBetterPlayerPlugin.swift` → `BetterPlayer.swift`) to trigger the new path instead of the legacy one. Android side of the fork is untouched.
- **`lib/security_layer/fairplay/fairplay_service.dart`** — builds that `offlineFairplayConfig` JSON, resolves the bundled FPS application certificate (`assets/fairplay/fps_certificate.bin` — Osama's real production cert; safe to bundle, it's public data, the private key never leaves the KSM) to a real file path, checks whether a video has already been imported locally.
- **`lib/features/courses/fairplay_importer.dart`** — imports a `.secfp` bundle (native `flutter_archive` extraction, same as `SecImporter`, never the pure-Dart `archive` package for the actual extraction — only for the small `peekMetadata` JSON read).
- **`lib/features/video_player/video_player_screen.dart`** — one small, isolated branch inside `_initPlayer`: if iOS **and** a FairPlay package already exists locally for this lecture/video, play via the new `_initFairplayPlayer()` path (local `file://` HLS, no shelf-server involvement for the video itself — FairPlay content is served as-is, decrypted entirely by the OS). Every other case (Android, Windows, or an iOS lecture with no FairPlay package) falls through to the existing, completely unmodified `_initAndroidPlayer` path.
- **`lib/features/courses/course_list_screen.dart`** — auto-import mechanism ported from the `whitelabel-full`-only reviewer-demo pattern, generalized: if the signed-in user's email is `kFairplayDemoAccountEmail`, silently import the bundled `assets/demo/demo_lecture.secfp` on login. Fails soft (no crash, no visible error) if the asset or import fails for any reason.

### The demo/test account
```
Email:    screenshot.demo@secureplayer.test
Password: Bgyh8nh8s8FZ7DGi
```
A real Firebase Auth account (uid `ofN8y2OeUKg1Vu4q024jhzudM5j1`), genuinely enrolled (`enrollments/ofN8y2OeUKg1Vu4q024jhzudM5j1_fairplay_demo_001`, `is_active: true`) in a real course/lecture (`courses/fairplay_demo_001`, `lectures/fairplay_demo_001`). No security bypass of any kind — same device-binding, same enrollment check as any real student account, exactly like the existing Mashrou3 Dactoor reviewer account's own design principle. The lecture's video is this repo's own `Anatomy Identify.mp4` test video, genuinely packaged with FairPlay (Shaka Packager, real production credentials) and genuinely uploaded to `course_keys/fairplay_demo_001.fairplay_videos.video_01` in Firestore.

On first login with this account on iOS, the app should silently import `assets/demo/demo_lecture.secfp` and show one course with one lecture, ready to tap and play — no manual `.sec`-file-tap step needed.

### ⚠️ What is and isn't verified

Everything **except real on-device playback** was independently verified this session: the self-hosted KSM answered real Apple test SPCs correctly (including the offline/non-expiring case), both Cloud Functions are live and deployed, the `.secfp` bundle was built from a real video and its manifest matches Apple's HLS+FairPlay spec exactly (`METHOD=SAMPLE-AES`, `KEYFORMAT="com.apple.streamingkeydelivery"`), every Dart file in this repo (including the vendored fork) passes `flutter analyze` clean project-wide, **and a real Codemagic build (`ios-unsigned-build`, `main` branch) successfully compiled the whole thing with a real Xcode 26.4 toolchain against a real-device target, producing an unsigned .ipa.**

That last point matters: this was not assumed, it was tested. The first build attempt genuinely failed — `AVContentKeyRequestRetryReason has been renamed to AVContentKeyRequest.RetryReason` (Apple's own 2017 sample this was adapted from used the old top-level enum name; newer SDKs nest it) — caught by triggering the build, fixed, pushed, and confirmed green on the second attempt. That's the only compile-level bug that existed; everything else compiled clean the first time.

**What remains is exactly one thing: nobody has pressed play.** No Mac was available to run the simulator or install on a physical device, so while the code is now proven to *build* correctly, actual FairPlay key exchange and playback behavior has zero real-world confirmation. Before this can be trusted:

1. Osama builds `main` via his own signed Codemagic workflow (or the `ios-unsigned-build` artifact above, if Sideloadly is enough for his test) and installs it on a real device — Simulator cannot test FairPlay at all, it requires the OS's hardware-backed secure decode path.
2. Log in as the demo account above, confirm the lecture auto-imports (downloads ~215 MB in the background on first login, then never again) and actually plays.
3. Force-quit and reopen with the device offline — confirms the persisted-key "import once, play forever offline" claim, not just that day-one playback works.
4. Confirm screen recording actually blacks out during playback — that's the entire reason this whole system exists.
5. Report back specifically on each of those four, not just "did it work."

### Real bugs found via actual test runs, all fixed (2026-07-30)
The first real Simulator test (via Codemagic App Preview) showed the demo lecture permanently locked. Root-caused by tracing, not guessing — this took three rounds, each surfaced only after the previous fix was retested:

1. **`lecture.isImported` never went true for a FairPlay import.** Every "is this imported" check across the app (`enrolled_courses_provider.dart`, ~4 call sites — lock icon, tap-gating, `video_player_screen.dart`'s courseId lookup) is keyed off one thing: whether `getApplicationSupportDirectory()/courses/{lectureId}/metadata.json` exists — the `.sec` format's own marker. A pure FairPlay import never touched that path by design (FairPlay content lives in its own `fairplay_lectures/` tree). Fixed by having `FairplayImporter` write a minimal, compatible marker there too (non-destructive — never overwrites a real `.sec` import's richer metadata for the same lectureId, if one exists) instead of patching every call site.
2. **More severe sibling bug, found by tracing what happens *after* fixing #1:** `video_player_screen.dart`'s `build()` unconditionally watches `videoServerProvider` for every video regardless of platform. Its `_startup()` required a `flutter_secure_storage` key for the lecture unconditionally — but FairPlay never stores one there (AVContentKeySession owns key material entirely). Result: the provider entered an error state and the screen showed a permanent "no decryption key" error — `_initFairplayPlayer()` was never even reachable, since it's only called from that provider's success path. Fixed with a placeholder key specifically for the confirmed-FairPlay-package case in `server_provider.dart` — safe because the shelf server this provider starts is never actually used for FairPlay video (served from local `file://` HLS instead).
3. **The demo/QA account (`screenshot.demo@secureplayer.test`) got locked out by normal device binding.** It's reused across many separate Simulator/Codemagic runs, each of which can legitimately report a different `device_id` — exactly the scenario the one-device-per-student rule exists to block for real students. Exempted this one hardcoded uid (`ofN8y2OeUKg1Vu4q024jhzudM5j1`) from device binding entirely, both client-side (`device_binding_service.dart`) and in both Cloud Functions that separately enforce it (`getCourseKey`, `getFairplayLicense`). Real student accounts are untouched.
4. **The compatibility marker from fix #1 omitted the video list, so the lecture showed as imported but had nothing to tap.** `CourseMetadata.isFileOnly` is `segmentCount==0 && videoId.isEmpty`; the marker never included a `videos` list, so every video parsed with `videoId=""` and got classified file-only — `CourseDetailScreen` rendered only an empty "Files & Materials" section. Fixed by writing a genuine `format_version: "2.1"` marker with a real `videos` list (parsed through the same path as real multi-video `.sec` lectures), plus a self-heal (`FairplayImporter.ensureCompatibilityMarker`) that repairs an already-extracted package's marker without re-downloading — necessary because the auto-import flow skips re-import entirely once a package is already on disk, so a device that hit the old broken marker would otherwise never get the fix without a full reinstall.

None of these four were visible to `flutter analyze` or code review alone — every one only surfaced from an actual run, which is exactly why "it compiles" and "it works" are tracked as separate claims throughout this document. Each fix was pushed; #1 and #2 were reverified with a fresh green Codemagic build before being considered done, #3 and #4 are pushed and awaiting the next real test pass.

### Pre-handoff security check (2026-07-30)
Scanned this repo for anything that shouldn't ship to a third party before handing source to Osama: no `.p12`/`.pem`/service-account/`.key`/`.p8` files committed, no private keys of any kind. `firebase_options.dart`'s API keys and `cert_pinning_service.dart`'s embedded certificate are both intentionally public (Firebase client API keys and TLS certs are not secrets by design — access control is enforced by Firestore/Storage rules, not by hiding these). Clean — safe to hand over as-is.

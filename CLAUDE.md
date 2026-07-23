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

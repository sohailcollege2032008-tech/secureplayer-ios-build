# Parallel Audio + FairPlay Stall — Full Journey

**Status (2026-08-04):** parallel-audio architecture is implemented and built on
both platforms. Windows playback+sync is proven. iOS build is green (build
**270**, commit `7b7e0fa`). **Blocked on device:** Osama reports
`parallel_audio_test.secfp` imports with a green toast but the lecture card
stays locked. Import-path code between the last working build (267) and 270 is
byte-identical on the marker/isImported path — diagnosis needs one on-device
screenshot of the in-app FairPlay log, not more code.

**Repos:**
- `secure` (Android/Windows packaging + proven sync): `whitelabel-build`
- `secure-ios-build` (iOS player): `main`
- Earlier investigation (superseded by this doc for everything after A/B/C/D):
  [`IOS_PLAYBACK_INVESTIGATION.md`](./IOS_PLAYBACK_INVESTIGATION.md)
- Architecture (KSM, Cloud Functions, packaging): `secure/CLAUDE.md` §iOS FairPlay DRM
- Ops (builds, Codemagic, keystores): `secure/docs/BUILD_AND_DEPLOY_PLAYBOOK.md`

---

## 0. What the product is supposed to do

Student gets a lecture package (`.sec` on Android/Windows, `.secfp` on iOS).
Imports it once. Plays offline forever. Video is DRM-protected (Widevine /
FairPlay). Audio must play with the video. Screen recording must not capture
content (FairPlay does this in hardware on iOS; app-level blackout on Android).

The work in this chat is **only** about iOS FairPlay packages that had no
audio, then froze when audio was added, then got redesigned so audio lives
outside FairPlay entirely.

---

## 1. Starting point — silent video (pre-chat baseline)

### What worked
- FairPlay video decrypts and plays on a real iPhone.
- Offline replay works (persisted content key survives force-quit).
- iOS itself refuses to screen-record FairPlay frames.
- Demo account auto-imports a bundled `.secfp` on login.

### What was broken
- **No audio.** Old packages marked the audio HLS rendition `DEFAULT=NO`, so
  AVPlayer never selected it. Video played fully, silently.

### Why the "audio fix" broke everything
Two packaging changes landed in `secure/encryptor/fairplay_packager.py`:

| Change | Commit (approx) | Effect |
|---|---|---|
| `--clear_lead 0` | ~`b4fbb1e` | Opening segments no longer unencrypted |
| Audio `lang=` + `--default_language` | ~`6dd9983` | Shaka emits `DEFAULT=YES` on audio |

After that, **any new export freezes at 0:00** on Osama's device. Old exports
still play (silently). Scope confirmed 2026-08-03: not demo-specific, not
stale-key-specific — packaging variables only.

Full write-up of the early wrong theories (pending-key race, stale key, clear
lead masking) lives in
[`IOS_PLAYBACK_INVESTIGATION.md`](./IOS_PLAYBACK_INVESTIGATION.md). Keep that
file as the historical record; do not re-investigate items it marks dead.

---

## 2. A/B/C/D packaging experiment (isolation, not a fix)

**Goal:** prove which packaging variable freezes playback, with zero iOS code
changes and zero Firestore writes.

### Code
- `secure/encryptor/fairplay_packager.py` — added `clear_lead`,
  `mark_audio_default` parameters (defaults byte-identical to production).
- `secure/scripts/fairplay_ab_experiment.py` — builds four variants of the
  demo lecture with the **already-published** Firestore key.

### Variants

| ID | clear_lead | audio DEFAULT | Expected role |
|---|---|---|---|
| A | 0 | YES | Current freeze repro |
| B | 5 | YES | clear_lead restores opening? |
| C | 0 | NO | audio rendition is the trigger? |
| D | 5 | NO | Positive control (= old export) |

Outputs (local):
`C:\Users\ASUS\AppData\Local\Temp\opencode\fp_ab_experiment\experiment_{A,B,C,D}.secfp`

### Result (Osama, real device)
- **D / C (DEFAULT=NO)** → play, silent (matches old behavior).
- **A / B (DEFAULT=YES)** → freeze at 0:00.
- Conclusion: **the selectable audio rendition is the freeze trigger.**
  `clear_lead` is irrelevant once audio is DEFAULT=YES.

That killed every "fix the key exchange" path. FairPlay + a second audio
track that AVPlayer actually selects is hostile on this stack
(`AVContentKeySession` intercepts more than FairPlay keys; dual-track startup
is fragile). Next architecture had to get audio **out** of the FairPlay HLS.

---

## 3. Dead end — mixed encryption (FairPlay video + AES-128 audio in HLS)

### Idea
Keep one HLS master. Video rendition = FairPlay (`skd://`, SAMPLE-AES).
Audio rendition = plain AES-128 TS, key served by the local shelf server
(`/key`), so `AVContentKeySession` never sees an audio FairPlay key request.

### What landed (then abandoned)
- iOS: `secure-ios-build` commit `67bbe27` and follow-ups
  (`a29e669` answer non-FairPlay AES-128 key requests with raw key bytes;
  `1fd0205` watch audio track continuously; debug bumps 263+).
- Packaging: Shaka/ffmpeg path producing AES-128 audio playlist beside
  FairPlay video.
- Local key route already existed for `.sec`; reused for mixed audio.

### Why it was abandoned (user decision)
- Still coupled to AVPlayer's multi-rendition startup.
- Compile/init issues around `initializationVector` / key response paths.
- Watchdog false alarms made logs look like KSM stalls when they weren't.
- User rejected the complexity: **"separate audio file + parallel player,
  not audio-inside-HLS."**

Do not resurrect mixed-HLS without an explicit new decision. The
`_fetchAudioKeyIfMixedPackage` helper on the debug branch is historical;
main replaced it with the parallel-audio key fetch (see §5).

---

## 4. Chosen architecture — parallel audio

### Design (one sentence)
**Video** = FairPlay HLS with **no audio track at all** (the packaging mode
that already played on device — experiment C/D / "step2").
**Audio** = sibling AES-128-CBC file next to the video, decrypted locally,
played on a second clock, resynced to the video player.

### Why this matches the evidence
- Step2 / DEFAULT=NO / video-only already played end-to-end on Osama's phone.
- Audio never enters `AVContentKeySession`, so the freeze class cannot recur.
- Same AES course key the Android `.sec` path already uses
  (`getCourseKey` → flutter_secure_storage).
- Sync engine is platform-agnostic Dart; only the audio sink is native.

### Package layout (`.secfp`, parallel-audio mode)

```
metadata.json          # videos[].separate_audio = "audio.m4a", flags
videos/
  {videoId}/
    master.m3u8        # VIDEO ONLY (audio_mode="none")
    video.m3u8
    *.m4s / init.mp4
    audio.m4a          # AES-128-CBC encrypted sibling (optional)
```

`.sec` (Android/Windows) gets the same sibling under the existing archive
layout via `VideoEntry.separate_audio_path`.

### Sync contract
- Master clock = video position.
- Slave = audio player.
- On play / pause / seek / rate change → drive audio to match.
- Drift correction when |video_pos - audio_pos| exceeds threshold (~50ms
  proven on Windows E2E).
- Pause must observe the **async** playing flag (Windows bug: audio kept
  playing because sync sampled state before `state.playing` flipped — fixed
  in `secure` `f3e1bef`).

---

## 5. What was implemented (by repo)

### 5.1 `secure` repo — packaging + Windows player
**Branch:** `whitelabel-build`

| Commit | What |
|---|---|
| `3d777a6` | Parallel audio player side (sync + loader + wire-up) |
| `6e897bd` | Packager side: `VideoEntry.separate_audio_path`, M4A normalise, archive entry, metadata flag |
| `adeac0a` | Windows login fix — `checkEmailExists` must not require idToken |
| `f3e1bef` | Pause fix — listen to async `stream.playing` |
| `560833d` | FairPlay packaging: `audio_mode="none"` + encrypted audio sibling in `.secfp` |

**Key files (secure):**

| Path | Role |
|---|---|
| `encryptor/fairplay_packager.py` | `audio_mode`: `"track"` (legacy HLS audio) \| `"none"` (parallel) |
| `encryptor/fairplay_bundle_builder.py` | Writes `videos/{id}/audio.m4a`, sets `separate_audio` in metadata |
| `encryptor/models.py` | `VideoEntry.separate_audio_path` |
| `encryptor/sec_builder.py` | `.sec` archive path for the sibling + IV map |
| `encryptor/ffmpeg_wrapper.py` | `convert_to_m4a` for the sibling |
| `lib/features/video_player/parallel_audio_sync.dart` | Master/slave sync engine |
| `lib/features/video_player/parallel_audio_loader.dart` | Decrypt sibling → temp path → sink |
| `test/parallel_audio_sync_test.dart` | Unit tests |
| `integration_test/parallel_audio_e2e_test.dart` | Windows E2E (~50ms drift) |
| `scripts/build_parallel_audio_test_ios.py` | Builds the Osama test `.secfp` |
| `scripts/fairplay_ab_experiment.py` | A/B/C/D (historical) |
| `scripts/build_audio_sync_test.py` | Windows `.sec` test package helper |
| `dist/parallel_audio_test.secfp` | **Current iOS test package** (22.9 MB) |
| `dist/audio_sync_test_lecture_001.sec` | Windows test package |

**Windows audio sink:** `media_kit` (already the Windows video stack).

**Windows login landmine (fixed, do not reintroduce):**
`checkEmailExists` runs pre-login. The pinned HTTP client was requiring an
idToken → every account failed login. Fix: `requireAuth: false` on that call
only (`adeac0a`).

### 5.2 `secure-ios-build` repo — iOS player
**Branch:** `main`

| Commit | What |
|---|---|
| `3afab81` | Parallel audio feature: video-only FairPlay + AVAudioPlayer sink |
| `f250409` | Register `AudioSyncChannel.swift` in `project.pbxproj` (classic dropped-file trap) |
| `af9ea80` | Strip UTF-8 BOM from `project.pbxproj` (CocoaPods `0xEF` parse fail) |
| `e6bccdd` | Bump **268** (must exceed Osama's installed **267**) |
| `495b3c0` | Diagnostics: log marker path/write + per-lecture `isImported` on list load → **269** |
| `7b7e0fa` | FairPlay log viewer in the **app drawer** (no need to open a lecture) → **270** |

Related earlier (stall era, still on history):
`3319343` pending-key set (did not fix freeze), `607562b` stall log surface,
`67bbe27` mixed-encryption (abandoned), debug branch
`debug-fairplay-logviewer` (build 267 — last known "plays, possibly silent /
mixed" install on Osama's phone).

**Key files (secure-ios-build):**

| Path | Role |
|---|---|
| `ios/Runner/AudioSyncChannel.swift` | AVAudioPlayer MethodChannel (`play/pause/seek/rate/position/load`) |
| `ios/Runner/AppDelegate.swift` | Registers the channel |
| `ios/Runner.xcodeproj/project.pbxproj` | **Must** list AudioSyncChannel (PBXBuildFile + Sources) |
| `lib/features/video_player/ios_audio_sink.dart` | Dart ↔ AudioSyncChannel |
| `lib/features/video_player/parallel_audio_sync.dart` | Port of Windows sync engine |
| `lib/features/video_player/parallel_audio_loader.dart` | Decrypt `audio.m4a` with course AES key |
| `lib/features/video_player/video_player_screen.dart` | Wires FairPlay video + parallel audio on iOS |
| `lib/features/courses/fairplay_importer.dart` | `.secfp` import, compatibility marker, course-key fetch, diagnostics |
| `lib/features/courses/sec_importer.dart` | Dispatches `.sec` / `.secfp` / `.secquiz` by extension |
| `lib/features/courses/enrolled_courses_provider.dart` | `isImported` = support-dir marker exists |
| `lib/features/courses/course_lectures_screen.dart` | Lock UI + list diagnostics |
| `lib/shared/widgets/app_drawer.dart` | **"FairPlay Log (DEBUG)"** entry (build 270) |
| `lib/security_layer/fairplay/fairplay_service.dart` | `logDiagnostics` / `readDiagnostics` → `Documents/fairplay_diagnostics.log` |
| `lib/local_server/handlers/fairplay_static_handler.dart` | Serves FairPlay HLS over `http://127.0.0.1` (AVPlayer cannot use `file://` HLS) |
| `vendor/better_player_plus/ios/Classes/FairplayContentKey*.swift` | AVContentKeySession (video only in parallel-audio mode) |
| `test/parallel_audio_sync_test.dart` | Unit tests (ported) |

### 5.3 How import unlocks a lecture (this is the lock icon)

Every lock/tap gate in the app keys off **one file**:

```
{getApplicationSupportDirectory()}/courses/{lectureId}/metadata.json
```

- `.sec` import writes a full marker there as part of normal extract.
- `.secfp` import extracts into
  `{Documents}/fairplay_lectures/{lectureId}/` and **also** writes a minimal
  compatibility marker at the support-dir path above
  (`FairplayImporter._writeCompatibilityMarker`). Without that marker the
  card stays locked forever even if the package is on disk.
- `enrolled_courses_provider.dart` sets `isImported = metaFile.exists()`.
- Toast "Lecture imported!" fires after `importFromPath` returns success —
  it does **not** re-check the marker. So a green toast + locked card means
  either (a) marker write failed/wrong path/wrong lectureId, or (b) the UI
  is showing a **different** lecture than the one just imported.

Self-heal: `FairplayImporter.ensureCompatibilityMarker` repairs markers for
already-extracted packages (used by demo auto-import).

### 5.4 Course-key fetch at FairPlay import (new, parallel-audio only)

Video FairPlay keys stay lazy (`getFairplayLicense` on first play).
Parallel audio needs the **plain AES course key** at play time to decrypt
`audio.m4a`. So `FairplayImporter` now calls `getCourseKey` during import
(same Cloud Function the `.sec` path uses) and stores it under the standard
secure-storage slot. **Fails soft** — missing key only breaks audio, never
video, never the marker.

This replaced the debug-branch helper `_fetchAudioKeyIfMixedPackage` (which
scanned for AES-128 audio playlists). Diff of marker/isImported code between
debug `267` and main `270`: **empty**. Only the key-fetch body + diagnostic
log lines differ.

---

## 6. Test package currently in Osama's hands

| Field | Value |
|---|---|
| File | `secure/dist/parallel_audio_test.secfp` (22.9 MB) |
| Built by | `scripts/build_parallel_audio_test_ios.py` |
| Telegram Saved Messages id | **68480** |
| lecture_id | `1b6822cf_80fd_4213_97be_9cb9a7b6d171` |
| video_id | `vid_2c1291bd` |
| course_id | `1a7db0fe_4b08_4bb3_bdac_b635838509cb` |
| FairPlay key (Firestore, reused) | `915f3a169d67be59ea7cb765f1b91c28` |
| FairPlay IV | `a202e38938c60fed5f1acb0732084a7c` |
| AES course key | `a6f7d73b0c3c7c68f475b0a3a377b53c` |
| Packaging | `audio_mode="none"` + encrypted `audio.m4a` sibling |

### Same course has THREE lectures (lock-card confusion risk)

| lecture_id prefix | Title (Firestore) | Notes |
|---|---|---|
| `19d11670…` | gg | never packaged in this test |
| `1b6822cf…` | test final | **this package** (`video_ids: []` in course doc is OK — package carries its own video list) |
| `4d0c033f…` | test 2 | never packaged in this test |

If Osama stares at "gg" or "test 2", those cards stay locked forever no
matter how many times he imports `parallel_audio_test.secfp`. The toast is
still green because import of `1b6822cf…` succeeded.

---

## 7. Build / CI facts that bit us

| Fact | Detail |
|---|---|
| Two Codemagic apps | Team: `6a603b35714cb06697d16f6f`. Personal (works for unsigned): `6a6d0e5e503b93c6d69e25cf` |
| Workflows that work on personal | `ios-unsigned-build`, `ios-simulator-build` |
| Who signs for device | **Osama** (his Apple team / Sideloadly). We produce unsigned or he rebuilds `main` |
| iOS refuses downgrade | Build number must be **> last installed**. Osama had **267** → shipped **268+**. Current tip **270** |
| `project.pbxproj` traps | (1) new Swift file not in Sources phase → compiles without it; (2) UTF-8 BOM → CocoaPods `Invalid character 0xEF` |
| AVAudioPlayer probe | GitHub Actions iOS SDK typecheck passed before wiring the real channel |
| Repos do not share git history | `secure` ↔ `secure-ios-build` = manual port only, never cherry-pick across |

Version stamp on iOS: edit `pubspec.yaml` `version: 1.0.0+N` (the `+N` is
`CFBundleVersion`).

---

## 8-RESOLVED (2026-08-04) — it was the wrong lecture card, not a bug

**No code defect. The import, the toast and the lock were all correct.**

Osama imported `parallel_audio_test.secfp` (lecture `1b6822cf…`, whose card
was titled *"test final"*) and then went looking in a lecture called
**"Audio Sync Test (parallel audio)"** — a different lecture, in a different
course, that is the **Windows** `.sec` test package. It has no iOS version, so
it can never unlock on a phone.

Proof, no device needed:

```
audio_sync_test_lecture_001   aes_key_hex=True   fairplay_videos=None
1b6822cf_80fd_4213…           aes_key_hex=True   fairplay_videos=['vid_2c1291bd']
```

No FairPlay key was ever published for `audio_sync_test_lecture_001`, so no
iOS import could unlock it. Meanwhile the packaged lecture was fine all along.

The demo account is enrolled in three courses, two of which read like the
parallel-audio test — and the file is *named* `parallel_audio_test.secfp`
while the lecture that accepts it was called *"test final"*. The naming did
the damage.

Also verified server-side at the same time (do not re-check):
package `lecture_id`/`course_id`/`video_id` all correct; package is genuinely
video-only FairPlay (zero `EXT-X-MEDIA`, `avc1` only, one `skd://`);
`audio.m4a` sibling present with its `file_iv_map` entry; `course_keys` holds
**both** `fairplay_videos.vid_2c1291bd` and `aes_key_hex`; enrolment active.
Two harmless oddities: the course is `is_published:false` and its
`teacher_uid` differs from the package's — neither is filtered on a generic
iOS build.

**Fix applied:** the test lectures/courses were renamed in Firestore so the
right card is unmistakable (titles are display-only; every lookup is by
document id, so nothing functional changed):

| Doc | New title |
|---|---|
| `courses/1a7db0fe…` | `iOS TEST — Parallel Audio` |
| `lectures/1b6822cf…` | `1) OPEN THIS — Parallel Audio Test (iOS)` |
| `lectures/19d11670…`, `lectures/4d0c033f…` | `(ignore — not packaged)` |
| `courses/audio_sync_test_course_001` | `Windows test — do not use on iPhone` |
| `lectures/audio_sync_test_lecture_001` | `(WINDOWS ONLY — no iOS version, will stay locked)` |

**Lesson worth keeping:** when a test package and a test lecture are named
after the same *feature* rather than the same *platform*, this will happen
again. Name test artifacts after the platform they run on.

Build 270's diagnostics are still valuable and should stay — they would have
answered this in one screenshot.

## 8-OLD. Former blocker analysis (superseded by 8-RESOLVED)

### Report
Osama on a post-268 build: import `parallel_audio_test.secfp` → toast
"Lecture imported!" → lecture still shows lock → restart / re-import does
not help.

### What we already proved from code (no device needed)

```
git diff debug-fairplay-logviewer HEAD -- \
  lib/features/courses/fairplay_importer.dart \
  lib/features/courses/sec_importer.dart \
  lib/features/courses/enrolled_courses_provider.dart
```

- Marker write path: **unchanged** vs last working install (267).
- `isImported` read path: **unchanged**.
- `.secfp` dispatch in `importSecFile`: **unchanged**.
- Only deltas: key-fetch function body (mixed → parallel) + diagnostic
  `logDiagnostics` lines + drawer log viewer.

So this is **not** "the parallel-audio feature broke import." The unlock
mechanism is the same code that unlocked step1–4 / mixed packages on 267.

### Plausible causes still alive (ordered)

1. **Wrong card.** Course has 3 lectures; only `1b6822cf…` ("test final")
   is in the package. Titles are generic.
2. **Reinstall wiped container.** Sideloadly replace with a different
   provisioning profile can reset the app sandbox → all old markers gone.
   A successful new import should recreate the marker; if it doesn't, see 3.
3. **Marker write/read mismatch on device.** Wrong `lectureId` in package
   metadata, support-dir path divergence, or import early-returning after
   toast. **Only the on-device log settles this.**
4. **Import never actually ran the FairPlay path.** (e.g. file lost its
   `.secfp` extension after Telegram download and fell through a different
   branch.) Toast text would still say imported if some path succeeded.

### Why one log line is required (and why that is still "simple")

Reading the repo cannot distinguish (1)–(4). Build **270** already adds the
minimum instrumentation — no new feature work:

- On import finish:
  `IMPORT done: marker=<path> exists=true|false`
- On lecture list load (per row):
  `LECTURE LIST: id=<id> imported=true|false …`

Viewer: app drawer → **"FairPlay Log (DEBUG)"** (no need to open a locked
lecture). One screenshot answers which hypothesis is true. Then the fix is
whatever that screenshot names — usually a one-liner, not a redesign.

### What is NOT the next step
- More import refactors.
- Rebuilding mixed-HLS.
- Changing `isImported` to a second source of truth.
- Studio production export wiring (blocked on green device play).

---

## 9. Accounts / IDs used in this work

| Who | Email | uid | Notes |
|---|---|---|---|
| Demo (iOS FairPlay) | `screenshot.demo@secureplayer.test` | `ofN8y2OeUKg1Vu4q024jhzudM5j1` | Password `Bgyh8nh8s8FZ7DGi`; device-bind exempt in CF + client |
| Windows test | `see2032008@gmail.com` | `S8aCuXSgS6PBigFBljG5sLDZcY82` | |
| Brand teacher (Mashrou3) | — | `WnRXfbMdVMRDbXWEKFFxYsJc9y43` | whitelabel-build Studio side |
| Reviewer (whitelabel-full only) | `screenshot.demo@mashrou3dactoor.test` | — | Different account; auto-imports `.sec` not `.secfp` |

Telegram send helper: Telethon session in
`C:\Users\ASUS\telegram-mcp\.env` (API_ID `25270204`) — used to drop test
packages into Saved Messages for Osama.

---

## 10. Decision log (do not relitigate without new evidence)

| Decision | Why |
|---|---|
| Kill "pending key set fixes the freeze" | Osama rebuilt with `3319343`; stall unchanged |
| Kill "stale persisted key" | Brand-new lecture / fresh skd:// still freezes |
| Kill "clear_lead is the cause" | A/B/C/D: DEFAULT=YES freezes with or without clear lead |
| Accept "DEFAULT=YES audio rendition is the freeze" | A/B freeze, C/D play |
| Abandon mixed-HLS | User: too complex; still inside AVPlayer multi-rendition |
| Adopt parallel audio | Video path = already-proven step2; audio outside FairPlay |
| Don't refactor `importSecFile` multi-format dispatch while bug is open | YAGNI / ponytail — seam is real but not the current failure |
| Diagnostics over speculation for the lock bug | Marker code identical to working build; device state is the variable |

---

## 11. Next actions (ordered)

1. **Osama installs build 270** (`main` @ `7b7e0fa`).
2. Re-import `parallel_audio_test.secfp`.
3. Drawer → **FairPlay Log (DEBUG)** → screenshot.
4. Screenshot the lecture list with visible titles.
5. From log lines `IMPORT done: … exists=…` and
   `LECTURE LIST: id=… imported=…`:
   - `exists=true` + `imported=false` on the matching id → read-path bug
     (path/dir API mismatch) — fix the read.
   - `exists=false` → write failed or wrong lectureId in metadata — fix write
     / package.
   - `exists=true` + `imported=true` on `1b6822cf…` but he was looking at
     another title → no code bug; tell him which card.
6. Once the card unlocks and video+audio play: wire Studio sidecar export
   (`studio/python/server.py` + studio_flutter) for production parallel-audio
   packages. **Not before.**
7. Optional cleanup after green play: make `_fetchAndStoreCourseKey` log
   failures into the FairPlay diagnostics (currently `catch (_) {}` with a
   doc comment — acceptable but silent).

---

## 12. File index (quick grep targets)

```
# Packaging
secure/encryptor/fairplay_packager.py
secure/encryptor/fairplay_bundle_builder.py
secure/encryptor/sec_builder.py
secure/encryptor/models.py
secure/encryptor/ffmpeg_wrapper.py
secure/scripts/build_parallel_audio_test_ios.py
secure/scripts/fairplay_ab_experiment.py

# Windows player
secure/lib/features/video_player/parallel_audio_*.dart
secure/test/parallel_audio_sync_test.dart
secure/integration_test/parallel_audio_e2e_test.dart

# iOS player
secure-ios-build/lib/features/video_player/parallel_audio_*.dart
secure-ios-build/lib/features/video_player/ios_audio_sink.dart
secure-ios-build/ios/Runner/AudioSyncChannel.swift
secure-ios-build/ios/Runner/AppDelegate.swift

# Import / lock
secure-ios-build/lib/features/courses/fairplay_importer.dart
secure-ios-build/lib/features/courses/sec_importer.dart
secure-ios-build/lib/features/courses/enrolled_courses_provider.dart
secure-ios-build/lib/features/courses/course_lectures_screen.dart
secure-ios-build/lib/shared/widgets/app_drawer.dart
secure-ios-build/lib/security_layer/fairplay/fairplay_service.dart

# Docs
secure-ios-build/docs/IOS_PLAYBACK_INVESTIGATION.md   # early stall era
secure-ios-build/docs/PARALLEL_AUDIO_JOURNEY.md       # this file
secure/docs/BUILD_AND_DEPLOY_PLAYBOOK.md
secure/CLAUDE.md                                      # FairPlay system design
secure-ios-build/CLAUDE.md                            # iOS repo rules / FairPlay section
```

---

## 13. One-screen summary for a new agent

> iOS FairPlay video plays. Adding a DEFAULT=YES audio track inside the same
> HLS freezes at 0:00 (proven by A/B/C/D). Mixed-HLS was tried and rejected.
> Final design: package video-only FairPlay (`audio_mode="none"`) + encrypted
> `audio.m4a` sibling; play audio on AVAudioPlayer (iOS) / media_kit
> (Windows) synced in Dart. Windows is proven. iOS is built (270) and
> waiting on Osama: import succeeds (toast) but card stays locked. Marker
> code is unchanged from the last working build — get the drawer FairPlay
> log screenshot before writing any more import code. Test file:
> `secure/dist/parallel_audio_test.secfp`, lecture `1b6822cf_80fd_4213_97be_9cb9a7b6d171`
> ("test final") inside a 3-lecture course.

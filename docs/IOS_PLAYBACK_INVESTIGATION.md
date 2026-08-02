# iOS FairPlay stall after the audio fix — investigation

**Status: root cause identified, fix not yet written or verified.**
Started 2026-08-02.

## The report

Osama, real iPhone:

- **Old `.secfp`** (exported before 2026-08-01) → plays, but **no audio**.
- **New `.secfp`** (exported after) → opens the video and **freezes at 0:00**,
  never starts. Described as "crashed or froze". Happens with and without
  screen recording.

The same lecture exported as `.msec` plays correctly on Android. That is not a
contradiction: Android never plays `.secfp` at all — different format, entirely
different pipeline. It tells us nothing about the FairPlay path.

## UPDATE 2026-08-03 — the fix below did NOT resolve it

Osama rebuilt with `3319343` (verified: his `d1c4907` sits on top of it) and
the stall is unchanged. The duplicate-key-request race described below is
therefore **not the cause**, or not the whole cause. The section is kept
because the missing pending-set was a real defect worth fixing on its own.

Two further hypotheses are also dead, both killed by direct evidence:

- **"The licence never worked; the old file only played its 5s clear lead."**
  Wrong — the old export plays *in full*, not five seconds. Licence
  acquisition works on that device.
- **"The audio playlist URI isn't rewritten with the auth token."**
  Wrong — `fairplay_static_handler.dart:66-69` rewrites quoted `URI="…m3u8"`
  and `URI="…mp4"` references, so `#EXT-X-MEDIA`'s `audio.m3u8` does get
  `?t=`. (Note the existing serve test only asserted this for `video.m3u8` —
  worth extending.)

**Four diagnoses, all from inference, all wrong.** Stop proposing causes. The
next commit adds a stall watchdog that surfaces the native FairPlay log on
screen; the failing stage must be *read*, not guessed. Do not write another
fix before that log exists.

What is still known for certain, and any real explanation must fit all of it:

1. Old export (audio `DEFAULT=NO`) plays fully, silently.
2. New export (audio `DEFAULT=YES`, `clear_lead 0`) freezes at 0:00.
3. The same lecture exported as `.msec` plays on Android — irrelevant, that is
   a different pipeline entirely.
4. Video decryption and licence acquisition demonstrably work on that device.
5. The only variable is the audio rendition becoming selectable.

## Original root-cause analysis (superseded — kept for the record)

Two changes landed in `encryptor/fairplay_packager.py` between those exports:

1. `--clear_lead 0` (commit `b4fbb1e`, 2026-07-31) — the opening segments are
   no longer shipped unencrypted.
2. The audio fix (commit `6dd9983`, 2026-08-01) — `lang=` plus
   `--default_language`, which makes Shaka emit `DEFAULT=YES` on the audio
   rendition.

Change 2 is what breaks playback, and change 1 removed the thing that would
have hidden it.

**Before the audio fix** the audio rendition was `DEFAULT=NO`, so AVPlayer never
selected it. Exactly **one** track was loaded and exactly **one** content key
was requested. The file played, silently — the reported symptom.

**After the fix** AVPlayer loads both renditions. Verified directly in a real
package (`demo_lecture_v2.secfp`): `audio.m3u8` and `video.m3u8` carry the
*identical* `#EXT-X-KEY` line with the *same* identifier
(`skd://fairplay_demo_001_video_01`). So **two** `AVContentKeyRequest`s now
arrive for the **same** content key identifier, effectively concurrently.

`FairplayContentKeyDelegate.handlePersistableContentKeyRequest` has no
protection against that. On a first play neither request finds a persisted key
on disk, so **both** proceed to fetch a licence from `getFairplayLicense`, both
call `persistableContentKey(fromKeyVendorResponse:)`, and both write the same
file (`urlForPersistableContentKey`). The result is a race with no winner
guaranteed, and the player stalls with no frames.

On a second play the key already exists on disk, both requests take the early
return at the `persistableContentKeyExistsOnDisk` check, and playback works —
which is why an already-played lecture behaves differently from a fresh one.

**Apple's own HLS Catalog sample, which this delegate was adapted from, tracks
`pendingPersistableContentKeyIdentifiers: Set<String>` for precisely this
case.** That set was not carried across in the port. Confirmed absent: no
`pending`, no `Set<` anywhere in the file.

`--clear_lead 0` matters only as an aggravator: previously the first ~5s were
unencrypted and would play while the key was still pending, masking a slow or
failed key exchange. Now nothing plays until the key resolves.

## The fix (not yet applied)

Add pending-identifier tracking to `FairplayContentKeyDelegate`:

- Keep a `Set<String>` of identifiers with a licence fetch in flight.
- On entry to `handlePersistableContentKeyRequest`, after the
  `persistableContentKeyExistsOnDisk` fast path, if the identifier is already
  pending, do **not** start a second network fetch.
- Clear the identifier from the set on success and on every failure path.

Match Apple's sample rather than inventing a scheme.

## Why no diagnostic build is needed first

`FairplayDiagnostics` already logs every stage of the key exchange to
`Documents/fairplay_diagnostics.log`, surfaced on the player's error screen. If
this diagnosis is right, that log from Osama's failing run will show **two**
`key request received for assetID=…` lines for the same assetID. That single
observation confirms or kills the theory at zero cost.

**Ask for that log before writing code.**

## Ruled out (do not re-investigate)

- **New metadata fields.** `WatermarkConfig.fromJson` parses `apply_to`
  (including `none`) and `video_style` with string comparisons and fallbacks;
  every new quiz field is `as String? ?? default`. No throwing enum lookups.
- **A missed manual port.** Full file-inventory and content diff of `lib/`
  between `secure` (`whitelabel-build`) and `secure-ios-build` (`main`) shows
  no functional divergence — only theme constants, Android-only brand
  filtering, and the Android-only integrity service.
- **Screen recording.** It does cause a blackout on non-FairPlay content (see
  below) but is not this bug; the stall happens with recording off.
- **HTTP header propagation to HLS sub-requests.** A real iOS limitation
  (AVPlayer does not forward `Authorization` to segment/key requests, unlike
  ExoPlayer) and a real latent bug in the **`.sec`** path — but irrelevant
  here, because `.secfp` playback authenticates via `?t=` query parameters,
  which `fairplay_static_handler` already applies to every rewritten URL.

## Separate issues found along the way

**1. `.sec` playback on iOS is probably broken (latent, untested).**
`_initAndroidPlayer` — the name is the giveaway — authenticates with
`headers: {'Authorization': ...}`. AVPlayer applies custom headers only to the
initial asset request, never to variant playlists, segments, or AES-128 key
requests. `_playlistHandlerV2` rewrites segment URLs with no `?t=`, and
`/segment`, `/playlist` and `/key` use `_isValidToken` (header only) rather
than `_isValidTokenOrParam`. On iOS those requests would arrive
unauthenticated and be rejected. Never observed, because every iOS test has
used `.secfp`. Fix: add `?t=` to the rewritten URLs and accept it on those
three routes.

**2. Screen recording blacks out `.sec` content on iOS — an App Store risk.**
`suppressTransientHold: Platform.isIOS && _fairplayPackageAvailable` is `false`
for non-FairPlay content, so `recording_started` renders
`SecurityTransientBlackout`. That is app-enforced blocking of a system
capability with no DRM behind it — the exact reason v1 was rejected. FairPlay
content is fine because iOS enforces it. Consider suppressing the hold for all
iOS video.

## Related

- `secure/docs/BUILD_AND_DEPLOY_PLAYBOOK.md` — build/deploy operations
- `secure/CLAUDE.md` §iOS FairPlay DRM — architecture and prior fixes

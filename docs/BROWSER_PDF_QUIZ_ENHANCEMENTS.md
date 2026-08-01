# Browser Memory, PDF Memory, and Quiz Manual Navigation — Design & Implementation

**Date:** 2026-08-01
**Scope:** Whole system — Android, Windows, iOS (porting target: `secure-ios-build`).

Three feature areas, one goal: the student's in-app experience should behave
like a real desktop/mobile browser + reader, with memory that survives
navigation and app restarts, and a quiz flow that lets the student read the
explanation before moving on.

---

## 1. Browser memory (ذاكرة المتصفح) — Chrome-like persistence in the WebView

### 1.1 The problem (root cause)

Interactive HTML files (e.g. quiz HTML that stores the student's attempts in
`localStorage`/cookies) lose their memory today. There are two independent
causes:

1. **The shelf server binds a RANDOM port every session.**
   `VideoServerNotifier._startup()` calls
   `HttpServer.bind(InternetAddress.loopbackIPv4, 0)` → the OS assigns a
   fresh port each time any viewer opens. The HTML is served from
   `http://127.0.0.1:<random-port>/html/...`, and browser storage
   (`localStorage`, `sessionStorage`, cookies) is keyed by **origin**
   (scheme + host + **port**). Every open = a new origin = all stored
   attempts orphaned. Even a WebView that never closes cannot persist data
   across two opens when the origin changes.

2. **The WebView itself is destroyed on every screen close.**
   `HtmlFileViewer.dispose()` disposes the `WebViewController` (and calls
   `clearCache()` on Android). In-page JS state, `sessionStorage`, and the
   HTTP cache die with it — nothing survives leaving the viewer, let alone
   an app restart.

3. **iOS has no HTML viewer at all.** `HtmlFileViewer` only branches on
   `Platform.isWindows` / `Platform.isAndroid`; on iOS it renders "HTML
   preview not supported on this platform".

### 1.2 The design

Three coordinated changes:

#### A. Deterministic per-lecture port (origin stability)

`ServerConstants.portFor(lectureId)` derives a stable port from the lecture
id (FNV-1a 32-bit hash → `11000 + hash % 12000`, range 11000–22999 —
deliberately below the Windows/Android ephemeral ranges 49152+ / 32768+ so
collisions with unrelated OS sockets are unlikely). Every shelf server tries
to bind that port first; if it is taken (two servers for the same lecture
alive at once), it falls back to the old random binding.

Result: the WebView origin for a given lecture is **byte-identical across
screen opens and across app restarts**. Native WebView storage is
disk-persisted per origin on all three platforms (Android WebView DOM
storage, iOS `WKWebsiteDataStore`, Windows WebView2 profile under
`%LOCALAPPDATA%`) — so `localStorage`/cookies now genuinely survive the app
being killed, exactly like Chrome.

Collision analysis (why fallback rarely triggers and never loses real work):

| Scenario | Winner keeps port | Loser falls back |
|---|---|---|
| Standalone file viewer for lecture L | Viewer (no competitor) | — |
| Video player (L) + quiz popup (L) | Video server (serves the HTML panel) | Quiz image server (no WebView) |
| Video player (L) still alive + file viewer (L) | Player | Viewer, this session only |

The losers never serve WebView content, so browser memory is preserved in
every real user flow.

#### B. Keep-alive WebView session (`lib/shared/webview_session.dart`, new)

One app-wide controller per platform, created lazily on first use, **reused**
by every `HtmlFileViewer` instance, and **never destroyed when a screen
closes**:

- Android/iOS: one `WebViewController` (webview_flutter).
- Windows: one `WebviewController` (webview_windows, WebView2 profile
  persists under `%LOCALAPPDATA%` automatically).

Browsing the session = browsing one Chrome tab: `sessionStorage`, JS state,
scroll positions and the HTTP cache survive leaving and re-entering any HTML
file in the same app run. Navigating to a new file just calls
`loadRequest(url, headers)` on the live controller (same-origin when the
lecture is the same, so `sessionStorage` even survives file switches).

**Clear policy — when memory is wiped:**
- **Logout** (any `FirebaseAuth.signOut()`): `WebviewSession.clearAll()`
  wipes cache + cookies + navigates to `about:blank`, so a second student on
  the same device starts clean. Wired via an `authStateChanges` listener
  attached from `main()`.
- **App restart**: nothing to do — storage is on disk (feature A) and
  in-memory state (sessionStorage/JS) is gone, which is exactly Chrome's
  contract.
- **Screen close**: nothing is wiped — this is the whole point.

#### C. HTTP cache policy (security trade-off, deliberate)

`/html` and `/file` responses keep `Cache-Control: no-store, no-cache,
max-age=0`. Decrypted file bytes must not linger in the on-disk HTTP cache.
Browser **storage** (localStorage/cookies — where quiz attempts actually
live) is unaffected by `no-store` and persists via the stable origin. This is
the correct Chrome-like split: *memory* persists, *decrypted payload* does
not. (Every cached/copied page carries the injected watermark + student
identity anyway, so even a leak is attributable.)

#### D. iOS HTML viewer (new capability)

`HtmlFileViewer` gains a `Platform.isIOS` branch using webview_flutter
(WKWebView). Navigation guard mirrors Android (block non-127.0.0.1,
launch external schemes with `url_launcher`). This is the first time HTML
files are viewable on iOS — a side-benefit of the memory work. The URL
`?t=` query param is already accepted by the server auth
(`_isValidTokenOrParam`), and iOS cannot send custom headers via
webview_flutter, so the token travels in the query string (Windows already
worked this way).

### 1.3 Files touched

| File | Change |
|---|---|
| `lib/core/constants/server_constants.dart` | `portFor(lectureId)` (FNV-1a → stable port) |
| `lib/local_server/server_provider.dart` | Bind preferred port, fall back to random |
| `lib/shared/webview_session.dart` | **NEW** — keep-alive session + logout wipe |
| `lib/shared/html_file_viewer.dart` | Use session, add iOS branch, drop dispose-time clearCache |
| `lib/main.dart` | Attach auth-state listener → `WebviewSession.clearAll()` on logout |

---

## 2. PDF memory, page navigator, scrollbar

### 2.1 Page resume (already implemented — now reliable)

`PdfPageCache` (`lib/core/services/pdf_page_cache.dart`) writes one small
JSON per (lectureId, fileId) on every page change and restores it as
`initialPage` when the PDF reopens. It already covers both entry points:
the standalone `FileViewerScreen` and the video player's inline file panel
(`video_player_screen.dart`). Exiting and re-entering a PDF resumes on the
exact page. **No code change needed for resume itself** — the browser-memory
work above makes the rest of the flow consistent with it.

### 2.2 Page navigator (new)

A small floating bar overlaid at the bottom of `SecurePdfViewPinch`
(so both the standalone viewer and the video-player panel get it for free):

```
┌───────────────────────────────┐
│  ◀  [ 12 / 200 ]  ▶          │
└───────────────────────────────┘
```

- `◀` / `▶` animate to the previous/next page; disabled at the bounds.
- Tapping the page label opens a jump-to-page dialog (number field, clamped
  to 1..pagesCount).
- Live from `SecurePdfControllerPinch.pageListenable`; hidden until the
  document loads; only rendered when `pagesCount > 1`.

### 2.3 Scrollbar (new)

`InteractiveViewer` is not a `Scrollable`, so a stock `Scrollbar` cannot
attach to it. Instead a lightweight custom overlay on the right edge:

- Thumb position driven by `SecurePdfControllerPinch.documentProgress`
  (0..1, already computed during layout) — live while panning/zooming.
- Thumb size proportional to viewport/document height ratio.
- Dragging the thumb (or tapping the track) animates to the corresponding
  page: `page = round(progress × pagesCount)`.
- New controller getters expose the layout sizes (`docSize`, `viewSize`).

Both overlays are transparent to gestures outside their own bounds
(panning/zooming the document is untouched), and they sit above the page
textures with the watermark unaffected.

### 2.4 Files touched

| File | Change |
|---|---|
| `lib/security_layer/watermark/secure_pdf_view.dart` | `SecurePdfViewPinch`: optional `showPageNavigator` / `showScrollbar` (defaults on); overlay widgets; controller: `docSize`/`viewSize` getters |
| `lib/core/services/pdf_page_cache.dart` | Unchanged (resume already works) |

---

## 3. Quiz — no auto-advance, explicit Next + Previous

### 3.1 The problem

In per-page quiz mode (`quiz_screen.dart`), submitting an answer kicks off a
hard-coded `Future.delayed(1500ms)` then **auto-advances** to the next
question. The explanation box is on the same page, but the student is
yanked forward before reading it — and going back to re-read is awkward
when you only know about swiping.

### 3.2 The design (before → after)

| Moment | Before | After |
|---|---|---|
| Option selected | "Submit" enabled | unchanged |
| Submit tapped | Answer recorded → 1.5s wait → **auto-advance** | Answer recorded → **stays on the question, explanation readable** |
| After submit | Button disabled, shows "Next..." spinner | Button becomes **"Next Question"** (enabled, tap at leisure); last question → **"View Results"** |
| Go back to a solved question | Swipe-right only | Swipe-right **and** a visible **"Previous"** button |
| Reviewing an old answer | "Already answered — swipe to continue" (disabled) | unchanged |

Implementation details:

- `_advancing` state, the `Future.delayed` in `_submit()`, and the swipe-to-
  skip path are removed entirely.
- The one-shot `_proceeded` guard stays (double-tap protection on Next).
- The `_submitScrollQuestion`/scroll-layout path is untouched (all questions
  visible at once — nothing to auto-advance).
- `QuizModal` (video popup quiz) already used manual "Next Question" — no
  change needed there.
- Timing (`_timeMsByIndex`) is still recorded at submit, unchanged. Resume
  (`QuizDbService`) restores `currentIndex` on the submitted question, so a
  student who leaves mid-quiz returns exactly where they stopped.

### 3.3 Files touched

| File | Change |
|---|---|
| `lib/features/quiz/quiz_screen.dart` | Remove auto-advance; rework submit button (Next/View Results); add Previous button row |

---

## 4. Platform matrix & porting

| Feature | Android | Windows | iOS |
|---|---|---|---|
| Browser storage persistence (localStorage/cookies) | ✅ stable origin + disk | ✅ stable origin + WebView2 profile | ✅ stable origin + WKWebsiteDataStore |
| Keep-alive browsing session | ✅ | ✅ | ✅ |
| HTML viewing | ✅ (unchanged) | ✅ (unchanged) | ✅ **NEW** |
| PDF page resume | ✅ (existing) | ✅ (existing) | ✅ (existing) |
| PDF navigator + scrollbar | ✅ | ✅ | ✅ |
| Quiz manual Next/Previous | ✅ | ✅ | ✅ |

`secure-ios-build` is a separate repo with its own history — changes must be
**manually ported** (no cherry-picks possible). Ported branch:
`whitelabel-full` (production iOS). Base branch `main` needs the same port
when it next diverges.

---

## 5. Test checklist (manual QA)

**Browser memory**
1. Open an interactive HTML quiz → answer questions → close the viewer.
2. Reopen the same file: previous attempts must still be there.
3. Force-kill the app → reopen: attempts still there (localStorage on disk).
4. Open a different file, then back: sessionStorage/in-page state intact.
5. Log out → log in: everything wiped (clean slate).
6. Windows: WebView2 present/absent paths unchanged.

**PDF**
7. Open a long PDF → jump to page 40 → back out → reopen: page 40.
8. Use ◀ ▶ and tap-page jump; bounds disabled at page 1 / last page.
9. Drag the right-edge scrollbar → lands on the expected page.
10. Same checks from the video player's inline file panel.

**Quiz**
11. Answer a question → stays on page, explanation visible.
12. "Next Question" appears; tap it → next question.
13. "Previous" returns to the solved question (read-only answer shown).
14. Last question shows "View Results" → result screen.
15. Leave mid-quiz → resume lands on the answered question.

---

## 6. Rollback

Each feature is a self-contained Dart change. To revert browser memory:
`git revert` of the server-port + webview-session commits (returning to
random ports + destroy-on-dispose restores old behavior byte-for-byte).
PDF overlays are additive (new params default to on; set them off to
disable). Quiz changes are contained in `quiz_screen.dart`.

---

## Addendum — iOS verification and one fix (2026-08-01)

Verified on this repo's `main` (the branch Osama builds for App Store /
TestFlight), against the FairPlay work that shares the same local server.

### Verified, no changes needed

- **The deterministic port does not affect FairPlay.** `ServerConstants.portFor()`
  is attempted first and falls back to a random port on `SocketException`, but
  everything downstream consumes `actualPort` (the port actually bound), which
  is what the FairPlay manifest rewriter uses to build absolute segment URLs.
  Re-ran the end-to-end server test (`test/fairplay_serve_check_test.dart`)
  against a real `.secfp` with these changes in place: all 20 checks pass —
  manifest rewriting, `skd://` key URI left untouched, token auth, path
  traversal refusal, `Content-Length`, and 206/`Content-Range` including the
  suffix form.
- **The port range is safe on iOS.** 11000–22999 is unprivileged (>1024) and
  below the ephemeral ranges, so binding needs no entitlement.
- **The keep-alive controller is shared with iOS.** `androidController()`
  backs both Android and iOS (`html_file_viewer.dart` routes
  `Platform.isAndroid || Platform.isIOS` to `_buildMobile()`), so the logout
  wipe reaches iOS through the same object despite the field name.

### One real bug found and fixed

`clearAll()` called `clearCache()` but not `clearLocalStorage()`. Verified
against the installed `webview_flutter_wkwebview` 3.25.1 source:
`clearCache()` removes only `memoryCache`, `diskCache`, and
`offlineWebApplicationCache`; `localStorage` is a distinct `WebsiteDataType`
reachable only via `clearLocalStorage()`.

Since `localStorage` is precisely what this feature persists (quiz answers),
logout left it intact — so on a shared device the next student would inherit
the previous student's stored state. `clearLocalStorage()` is now called
alongside `clearCache()` on logout. Affects Android identically; it is not an
iOS-only defect, just found during iOS review.

### Still worth knowing

- Two lectures whose ids hash to the same port fall back to a random port for
  whichever binds second, so that session loses browser-memory continuity. It
  degrades rather than fails, and the collision odds are ~1/12000 per pair.
- There is a narrower race on reopening the *same* lecture quickly: the
  previous server may not have released the port yet, producing the same
  one-session fallback.

# SecurePlayer — iOS Build

This is a Flutter application, ready to build for iOS. This folder contains
everything needed to build, archive, and submit it — no other project
access is required.

## Prerequisites

| Tool | Notes |
|------|-------|
| macOS | Required — Xcode does not run on Windows/Linux |
| Xcode | 15+, from the Mac App Store |
| CocoaPods | `sudo gem install cocoapods` |
| Flutter SDK | 3.22+ (`flutter --version` to check) |
| Apple Developer account | Needed for signing, TestFlight, and App Store submission |

## One-time setup

```bash
flutter pub get
cd ios && pod install && cd ..
flutter doctor -v
```

## Run on a connected device or Simulator (debug)

```bash
flutter run -d "iPhone 15"          # Simulator
flutter run -d <device_udid>        # physical device, must be registered
                                      # in your Apple Developer account first
```

## Build for TestFlight / App Store (release)

```bash
flutter build ipa --release
# Output: build/ios/ipa/secure_player.ipa
```

Or open `ios/Runner.xcworkspace` in Xcode (**not** `Runner.xcodeproj`) and
use Product → Archive.

## What to test before shipping

The most important thing to verify on a **real physical device** (not the
Simulator — this specific behavior cannot be validated in the Simulator):

1. Open a course video and start screen recording from Control Center.
2. The screen should go solid black within about a second, with the text
   "Content paused for security."
3. Stop recording — the video should resume automatically.

Everything else (login, course list, quiz flow, PDF viewing) behaves like
a standard Flutter app and can be tested normally.

## Notes

- Signing certificates and provisioning profiles are not included — set
  these up under your own Apple Developer account in Xcode's Signing &
  Capabilities tab for the `Runner` target.
- `ios/Flutter/` is intentionally not included — it contains machine-specific
  paths and is regenerated automatically by `flutter pub get`.

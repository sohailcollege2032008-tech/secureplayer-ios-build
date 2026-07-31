//
// FairplayDiagnostics.swift
//
// Appends FairPlay key-exchange events to a plain log file the Dart side
// reads back and shows on the player's error screen.
//
// Exists because every failure signal in the FairPlay path was being
// discarded: AVContentKeySessionDelegate's didFailWithError ignored its
// NSError entirely, the persistable-key request swallowed its throw and
// silently fell back to an online key, and provideOnlineKey returned bare
// on failure. AVFoundation surfaces all of that to the user as the single
// word "Cannot Open", which is not enough to diagnose anything — four
// separate fixes were attempted against that message without knowing which
// stage actually failed.
//
// A file rather than a MethodChannel deliberately: this code lives in a
// vendored plugin, the log has to survive the failure that produced it, and
// the device under test is a third party's phone we cannot pull logs from —
// it has to be readable and screenshotable inside the app.

import Foundation

enum FairplayDiagnostics {

    private static let queue = DispatchQueue(label: "com.secureplayer.fairplay.diagnostics")
    private static let maxBytes = 64 * 1024

    static var logFileURL: URL? {
        guard let documents = NSSearchPathForDirectoriesInDomains(
            .documentDirectory, .userDomainMask, true
        ).first else { return nil }
        return URL(fileURLWithPath: documents)
            .appendingPathComponent("fairplay_diagnostics.log")
    }

    /// Starts a fresh log. Called when a new playback attempt begins so the
    /// on-screen dump reflects that attempt, not every attempt ever made.
    static func reset() {
        queue.async {
            guard let url = logFileURL else { return }
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func log(_ message: String) {
        queue.async {
            guard let url = logFileURL else { return }
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(stamp)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                // Bounded so a retry loop can't fill the user's storage.
                if handle.offsetInFile < maxBytes {
                    handle.write(data)
                }
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Unwraps an NSError far enough to be useful — the real cause of a
    /// FairPlay failure is routinely in NSUnderlyingError, not the top level.
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        var parts = ["domain=\(nsError.domain)", "code=\(nsError.code)"]
        if !nsError.localizedDescription.isEmpty {
            parts.append("desc=\(nsError.localizedDescription)")
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append(
                "underlying=(domain=\(underlying.domain) code=\(underlying.code) "
                + "desc=\(underlying.localizedDescription))"
            )
        }
        return parts.joined(separator: " ")
    }
}

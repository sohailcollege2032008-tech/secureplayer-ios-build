// fairplay_harness.swift
//
// macOS AVPlayer + AVContentKeySession harness that replays a .secfp package
// EXACTLY like the iOS app does, printing every stage and — crucially — the
// raw AVFoundation error (domain + code) that iOS hides behind
// "failed to load video : resource un available".
//
// Built/run on a GitHub Actions macOS runner via .github/workflows/fairplay-harness.yml
//
// Usage: fairplay_harness <path-to.secfp> <idToken>

import AVFoundation
import Foundation

// MARK: - Command line

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: fairplay_harness <package.secfp> <firebaseIdToken>")
    exit(2)
}
let packagePath = args[1]
let idToken = args[2]

// MARK: - FPS certificate (bundled in this repo, public data)

let certURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("assets/fairplay/fps_certificate.bin")
guard let certData = try? Data(contentsOf: certURL) else {
    print("HARNESS FATAL: cannot read FPS certificate at \(certURL.path)")
    exit(2)
}
print("HARNESS: loaded FPS certificate (\(certData.count) bytes)")

// MARK: - FairPlay delegate (mirror of FairplayContentKeyDelegate.swift)

final class FPDelegate: NSObject, AVContentKeySessionDelegate {
    let cert: Data
    let token: String
    var onKeyDelivered: (() -> Void)?

    init(cert: Data, token: String) {
        self.cert = cert
        self.token = token
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        didProvide keyRequest: AVContentKeyRequest
    ) {
        print("HARNESS: key request received for \(String(describing: keyRequest.identifier))")
        // macOS AVContentKeyRequest has no
        // respondByRequestingPersistableContentKeyRequestAndReturnError (iOS-only);
        // persistable requests arrive via the AVPersistableContentKeyRequest
        // delegate method below. For this harness an online key is sufficient —
        // the symptom under test (media load failure AFTER key delivery) is
        // independent of persistable vs online.
        provideOnline(keyRequest)
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest
    ) {
        provideOnline(keyRequest)
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        contentKeyRequest keyRequest: AVContentKeyRequest,
        didFailWithError err: Error
    ) {
        print("HARNESS KEY REQUEST FAILED: \(describe(err))")
    }

    private func provideOnline(_ keyRequest: AVContentKeyRequest) {
        guard let identifier = keyRequest.identifier as? String,
              let idData = identifier.data(using: .utf8) else {
            print("HARNESS: bad identifier")
            return
        }
        keyRequest.makeStreamingContentKeyRequestData(
            forApp: cert,
            contentIdentifier: idData,
            options: [AVContentKeyRequestProtocolVersionsKey: [1]]
        ) { [weak self] spc, error in
            guard let self = self else { return }
            if let error = error {
                print("HARNESS: SPC generation FAILED: \(self.describe(error))")
                keyRequest.processContentKeyResponseError(error)
                return
            }
            guard let spc = spc else { return }
            print("HARNESS: SPC built (\(spc.count) bytes), calling getFairplayLicense")
            self.exchange(spc: spc) { ckc in
                guard let ckc = ckc else {
                    keyRequest.processContentKeyResponseError(
                        NSError(domain: "harness", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "no CKC"]))
                    return
                }
                keyRequest.processContentKeyResponse(
                    AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckc))
                print("HARNESS: delivered CKC to AVFoundation (\(ckc.count) bytes)")
                self.onKeyDelivered?()
            }
        }
    }

    // MARK: persistable path (mirror of handlePersistableContentKeyRequest)

    func contentKeySession(
        _ session: AVContentKeySession,
        didProvide keyRequest: AVPersistableContentKeyRequest
    ) {
        guard let identifier = keyRequest.identifier as? String,
              let idData = identifier.data(using: .utf8) else {
            print("HARNESS: persistable request bad identifier")
            return
        }
        print("HARNESS: PERSISTABLE request for \(identifier)")
        keyRequest.makeStreamingContentKeyRequestData(
            forApp: cert,
            contentIdentifier: idData,
            options: [AVContentKeyRequestProtocolVersionsKey: [1]]
        ) { [weak self] spc, error in
            guard let self = self else { return }
            if let error = error {
                print("HARNESS: SPC generation FAILED: \(self.describe(error))")
                keyRequest.processContentKeyResponseError(error)
                return
            }
            guard let spc = spc else { return }
            print("HARNESS: SPC built (\(spc.count) bytes), calling getFairplayLicense")
            self.exchange(spc: spc) { ckc in
                guard let ckc = ckc else {
                    keyRequest.processContentKeyResponseError(
                        NSError(domain: "harness", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "no CKC"]))
                    return
                }
                do {
                    let persistent = try keyRequest.persistableContentKey(
                        fromKeyVendorResponse: ckc, options: nil)
                    print("HARNESS: converted CKC to persistable key (\(persistent.count) bytes)")
                    keyRequest.processContentKeyResponse(
                        AVContentKeyResponse(fairPlayStreamingKeyResponseData: persistent))
                    print("HARNESS: delivered PERSISTABLE key to AVFoundation")
                    self.onKeyDelivered?()
                } catch {
                    print("HARNESS: persistable conversion FAILED: \(self.describe(error))")
                    keyRequest.processContentKeyResponseError(error)
                }
            }
        }
    }

    // MARK: SPC -> CKC via the real Cloud Function

    func exchange(spc: Data, completion: @escaping (Data?) -> Void) {
        let url = URL(string: "https://us-central1-stud-future-platform-db.cloudfunctions.net/getFairplayLicense")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 25

        // The harness needs lectureId/videoId/deviceId — derive from the package
        // metadata we loaded before; passed via env in the workflow.
        let body: [String: Any] = [
            "data": [
                "lectureId": ProcessInfo.processInfo.environment["HARNESS_LECTURE"] ?? "",
                "videoId": ProcessInfo.processInfo.environment["HARNESS_VIDEO"] ?? "",
                "courseId": ProcessInfo.processInfo.environment["HARNESS_COURSE"] ?? "",
                "deviceId": "harness-macos",
                "spc": spc.base64EncodedString(),
            ]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if let error = error {
                print("HARNESS: getFairplayLicense transport error: \(error)")
                completion(nil)
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = json["result"] as? [String: Any],
                  let ckcB64 = result["ckc"] as? String,
                  let ckc = Data(base64Encoded: ckcB64) else {
                let raw = String(data: data ?? Data(), encoding: .utf8) ?? "<none>"
                print("HARNESS: getFairplayLicense bad response (HTTP \(status)): \(raw.prefix(400))")
                completion(nil)
                return
            }
            print("HARNESS: getFairplayLicense OK (HTTP \(status), CKC \(ckc.count) bytes)")
            completion(ckc)
        }.resume()
    }

    func describe(_ error: Error) -> String {
        let ns = error as NSError
        var parts = ["domain=\(ns.domain) code=\(ns.code)"]
        if !ns.localizedDescription.isEmpty { parts.append("desc=\(ns.localizedDescription)") }
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=domain=\(u.domain) code=\(u.code) desc=\(u.localizedDescription)")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Main

func main() {
    // Extract the .secfp into a temp dir
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("fp_harness_\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    print("HARNESS: package = \(packagePath)")

    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    unzip.arguments = ["-x", "-k", packagePath, tmp.path]
    try? unzip.run()
    unzip.waitUntilExit()
    print("HARNESS: unzip exit = \(unzip.terminationStatus)")

    let fm = FileManager.default
    let files = (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? []
    print("HARNESS: extracted: \(files)")

    // Find the videos/<id>/ dir
    let videosRoot = tmp.appendingPathComponent("videos")
    guard let videoId = (try? fm.contentsOfDirectory(atPath: videosRoot.path))?.first else {
        print("HARNESS FATAL: no videos/ dir")
        exit(2)
    }
    let videoDir = videosRoot.appendingPathComponent(videoId)
    let masterURL = videoDir.appendingPathComponent("master.m3u8")
    print("HARNESS: videoDir = \(videoDir.path)")
    print("HARNESS: master exists = \(fm.fileExists(atPath: masterURL.path))")

    // Start a trivial HTTP server on a fixed port serving videoDir (no auth —
    // the harness is local, no token needed; mirrors what the shelf server
    // produces after absolutization, minus the ?t= which macOS doesn't need).
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["-m", "http.server", "18345", "--directory", videoDir.path]
    try? server.run()
    print("HARNESS: python http.server started on :18345")
    Thread.sleep(forTimeInterval: 1)

    let assetURL = URL(string: "http://127.0.0.1:18345/master.m3u8")!
    let asset = AVURLAsset(url: assetURL)
    let delegate = FPDelegate(cert: certData, token: idToken)
    let session = AVContentKeySession(keySystem: .fairPlayStreaming)
    session.setDelegate(delegate, queue: DispatchQueue(label: "fpdelegate"))
    session.addContentKeyRecipient(asset)

    let item = AVPlayerItem(asset: asset)
    let player = AVPlayer(playerItem: item)

    var statusSeen = false
    var errorSeen = false

    let statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
        if !statusSeen {
            statusSeen = true
            print("HARNESS: item.status = \(item.status.rawValue) "
                  + "(0=unknown 1=ready 2=failed)")
            if let e = item.error {
                errorSeen = true
                print("HARNESS ITEM ERROR >>> \(delegate.describe(e))")
            }
            if item.status == .readyToPlay {
                player.play()
                print("HARNESS: readyToPlay — calling play()")
            }
        } else if item.status == .failed, !errorSeen {
            errorSeen = true
            if let e = item.error {
                print("HARNESS ITEM ERROR >>> \(delegate.describe(e))")
            }
        }
    }
    RunLoop.current.add(statusTimer, forMode: .common)

    let start = Date()
    var lastPos: Double = -1
    let progressTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
        let pos = CMTimeGetSeconds(player.currentTime())
        let dur = CMTimeGetSeconds(item.duration)
        print(String(format: "HARNESS: pos=%.2f dur=%.2f rate=%.2f status=%d",
                     pos, dur.isNaN ? -1 : dur, player.rate, item.status.rawValue))
        if pos > 0.5 && abs(pos - lastPos) > 0.4 {
            lastPos = pos
            print(String(format: "HARNESS: *** PLAYHEAD MOVING — pos=%.2f ***", pos))
        }
        if item.status == .failed {
            print("HARNESS: *** ITEM FAILED ***")
            if let e = item.error {
                print("HARNESS ITEM ERROR >>> \(delegate.describe(e))")
            }
            exit(3)
        }
        if item.status == .readyToPlay, pos > 1.0 {
            print("HARNESS: *** PLAYBACK CONFIRMED — pos=\(pos) ***")
            exit(0)
        }
        if Date().timeIntervalSince(start) > 60 {
            print("HARNESS: *** TIMEOUT after 60s — no playback, last status=\(item.status.rawValue) ***")
            if let e = item.error {
                print("HARNESS ITEM ERROR >>> \(delegate.describe(e))")
            }
            exit(4)
        }
    }
    RunLoop.current.add(progressTimer, forMode: .common)

    player.play()
    print("HARNESS: player.play() called — running run loop (60s cap)")
    RunLoop.current.run(until: Date().addingTimeInterval(70))
    print("HARNESS: run loop ended without decisive result")
    exit(5)
}

main()

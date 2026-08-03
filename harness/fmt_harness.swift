// fmt_harness.swift — NO-DRM format test.
//
// Plays a master playlist with plain AVPlayer (no AVContentKeySession, no
// FairPlay) to answer ONE question: does AVPlayer handle a mixed-container
// HLS master — fMP4 video + MPEG-TS AES-128 audio — with sound and sync?
//
// If this plays with an active audio track, the container mix is proven, and
// the only remaining piece (FairPlay video) is already proven by step2 on
// Osama's device.

import AVFoundation
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: fmt_harness <master.m3u8-or-dir>")
    exit(2)
}

let path = args[1]
let fm = FileManager.default

// If given a dir, serve it over http (python) and point at master.m3u8
var url: URL
if fm.fileExists(atPath: path + "/master.m3u8") {
    let dir = URL(fileURLWithPath: path)
    let server = Process()
    server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    server.arguments = ["-m", "http.server", "18345", "--directory", dir.path]
    try? server.run()
    print("FMT: serving \(dir.path) on :18345")
    // Wait until the server actually accepts connections (AVPlayer fails
    // with NSURLError -1004 if it starts before the listener is up).
    var up = false
    for _ in 0..<20 {
        let probe = URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:18345/master.m3u8")!)
        // synchronous-ish probe: use a semaphore
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        let task = URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:18345/master.m3u8")!) { _, resp, _ in
            ok = (resp as? HTTPURLResponse)?.statusCode == 200
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 3)
        if ok { up = true; break }
        Thread.sleep(forTimeInterval: 0.5)
    }
    print("FMT: server up = \(up)")
    Thread.sleep(forTimeInterval: 0.5)
    url = URL(string: "http://127.0.0.1:18345/master.m3u8")!
} else {
    url = URL(fileURLWithPath: path)
}

let asset = AVURLAsset(url: url)
let item = AVPlayerItem(asset: asset)
let player = AVPlayer(playerItem: item)

var seenTracks = false
let start = Date()
var lastPos: Double = -1
var audioTrackSeen = false
var keyRequestSeen = false

// AVPlayerItem has no delegate; watch tracks via KVO-ish polling
let statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    if !seenTracks {
        seenTracks = true
        print("FMT: item.status = \(item.status.rawValue) (0 unknown, 1 ready, 2 failed)")
        if let e = item.error {
            print("FMT ITEM ERROR >>> domain=\((e as NSError).domain) code=\((e as NSError).code) desc=\(e.localizedDescription)")
        }
        if item.status == .readyToPlay {
            player.play()
            print("FMT: readyToPlay — play() called")
            // Enumerate tracks: is there an audio track?
            for t in item.tracks {
                let assetTrack = t.assetTrack
                let mediaType = assetTrack?.mediaType.rawValue ?? "?"
                print("FMT: track type=\(mediaType) enabled=\(t.isEnabled) name=\(t.assetTrack?.languageCode ?? "?")")
                if mediaType == AVMediaType.audio.rawValue, t.isEnabled {
                    audioTrackSeen = true
                }
            }
        }
    } else if item.status == .failed {
        if let e = item.error {
            print("FMT ITEM ERROR >>> domain=\((e as NSError).domain) code=\((e as NSError).code) desc=\(e.localizedDescription)")
        }
        exit(3)
    }
}
RunLoop.current.add(statusTimer, forMode: .common)

let progressTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
    // Watch tracks continuously — audio track may appear after readyToPlay
    for t in item.tracks {
        let mt = t.assetTrack?.mediaType.rawValue ?? "?"
        if mt == AVMediaType.audio.rawValue, t.isEnabled {
            audioTrackSeen = true
        }
    }
    let pos = CMTimeGetSeconds(player.currentTime())
    let dur = CMTimeGetSeconds(item.duration)
    print(String(format: "FMT: pos=%.2f dur=%.2f rate=%.2f status=%d audioTrack=%d",
                 pos, dur.isNaN ? -1 : dur, player.rate, item.status.rawValue, audioTrackSeen ? 1 : 0))
    if pos > 0.5 && abs(pos - lastPos) > 0.4 {
        lastPos = pos
        print(String(format: "FMT: *** PLAYHEAD MOVING — pos=%.2f audioTrack=%d ***", pos, audioTrackSeen ? 1 : 0))
    }
    if item.status == .readyToPlay, pos > 3.0 {
        print("FMT: *** PLAYBACK CONFIRMED past 3s — pos=\(pos) audioTrack=\(audioTrackSeen ? 1 : 0) ***")
        print("FMT: RESULT=\(audioTrackSeen ? "PLAYS_WITH_AUDIO" : "PLAYS_SILENT_OR_NO_AUDIO_TRACK")")
        exit(0)
    }
    if Date().timeIntervalSince(start) > 45 {
        print("FMT: *** TIMEOUT after 45s — status=\(item.status.rawValue) lastPos=\(pos) audioTrack=\(audioTrackSeen ? 1 : 0) ***")
        if let e = item.error {
            print("FMT ITEM ERROR >>> domain=\((e as NSError).domain) code=\((e as NSError).code) desc=\(e.localizedDescription)")
        }
        exit(4)
    }
}
RunLoop.current.add(progressTimer, forMode: .common)

player.play()
print("FMT: player.play() — running (45s cap)")
RunLoop.current.run(until: Date().addingTimeInterval(50))
print("FMT: run loop ended without decisive result")
exit(5)

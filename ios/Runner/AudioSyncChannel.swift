//
// AudioSyncChannel.swift
//
// AVAudioPlayer-backed sink for the parallel-audio feature: the FairPlay
// video plays SILENT (step2-style, no audio track in the HLS) and the
// lecture's audio ships as a separate encrypted file in the .secfp package.
// The Dart side decrypts it to a temp file, then drives this player in
// lock-step with AVPlayer's playhead (play/pause/seek/rate mirrored, drift
// corrected by the Dart sync engine — see parallel_audio_sync.dart).
//
// AVAudioPlayer is deliberately trivial: currentTime/rate/play/pause, no
// DRM involvement, no FairPlay interaction of any kind. The channel mirrors
// the SecurityChannel registration pattern in AppDelegate.swift.
//
// NOT independently verified on hardware while writing (no Mac) — same
// status as the original FairPlay channel before its first device build;
// every call is a plain AVAudioPlayer API.
//

import AVFoundation
import Flutter
import Foundation

enum AudioSyncChannel {

  private static var players: [String: AVAudioPlayer] = [:]
  private static let queue = DispatchQueue(label: "com.secureplayer.audio_sync")

  static func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let id = args["id"] as? String ?? "default"

    switch call.method {
    case "init":
      guard let path = args["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "path required", details: nil))
        return
      }
      queue.async {
        do {
          try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
          try AVAudioSession.sharedInstance().setActive(true)
          let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
          player.enableRate = true
          player.prepareToPlay()
          players[id] = player
          DispatchQueue.main.async {
            result(player.duration * 1000.0)
          }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "init_failed", message: "\(error)", details: nil))
          }
        }
      }

    case "play":
      queue.async {
        players[id]?.play()
        DispatchQueue.main.async { result(nil) }
      }

    case "pause":
      queue.async {
        players[id]?.pause()
        DispatchQueue.main.async { result(nil) }
      }

    case "seek":
      guard let ms = args["position"] as? Double else {
        result(FlutterError(code: "bad_args", message: "position required", details: nil))
        return
      }
      queue.async {
        players[id]?.currentTime = ms / 1000.0
        DispatchQueue.main.async { result(nil) }
      }

    case "setRate":
      guard let rate = args["rate"] as? Double else {
        result(FlutterError(code: "bad_args", message: "rate required", details: nil))
        return
      }
      queue.async {
        let p = players[id]
        p?.rate = Float(rate)
        DispatchQueue.main.async { result(nil) }
      }

    case "state":
      queue.async {
        let p = players[id]
        let ms = (p?.currentTime ?? 0) * 1000.0
        let playing = p?.isPlaying ?? false
        DispatchQueue.main.async { result([ms, playing]) }
      }

    case "position":
      queue.async {
        let ms = (players[id]?.currentTime ?? 0) * 1000.0
        DispatchQueue.main.async { result(ms) }
      }

    case "playing":
      queue.async {
        let playing = players[id]?.isPlaying ?? false
        DispatchQueue.main.async { result(playing) }
      }

    case "dispose":
      queue.async {
        players[id]?.stop()
        players.removeValue(forKey: id)
        DispatchQueue.main.async { result(nil) }
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

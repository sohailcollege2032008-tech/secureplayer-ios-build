import AVFoundation
import Foundation

// Probes every AVAudioPlayer/AVAudioSession API AudioSyncChannel.swift uses.
// Typechecks against the iOS SDK so API-availability mistakes surface here
// instead of in a Codemagic build.
func probe(_ path: String) throws -> Double {
    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    try AVAudioSession.sharedInstance().setActive(true)
    let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
    player.enableRate = true
    player.prepareToPlay()
    let durationMs = player.duration * 1000.0
    player.play()
    player.pause()
    player.currentTime = 1.0
    player.rate = 2.0
    let posMs = player.currentTime * 1000.0
    let playing = player.isPlaying
    player.stop()
    _ = playing
    return durationMs + posMs
}

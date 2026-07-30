//
// FairplayContentKeyManager.swift
//
// Adapted from Apple's own "HLS Catalog With FPS" sample (FairPlay Streaming
// Server SDK 26.0.4, Development/Client/HLS Catalog With FPS/Shared/Managers/
// ContentKeyManager.swift) — the reference pattern for AVContentKeySession +
// offline persistable keys, which better_player_plus's own upstream FairPlay
// path (BetterPlayerEzDrmAssetsLoaderDelegate, AVAssetResourceLoaderDelegate-
// based) does not support.
//
// Configures the single AVContentKeySession used for every FairPlay asset
// played through this app.

import AVFoundation

public class FairplayContentKeyManager {
    public static let shared: FairplayContentKeyManager = FairplayContentKeyManager()

    public let contentKeySession: AVContentKeySession
    public let contentKeyDelegate: FairplayContentKeyDelegate

    private let contentKeyDelegateQueue = DispatchQueue(label: "com.secureplayer.fairplay.contentKeyDelegateQueue")

    private init() {
        contentKeySession = AVContentKeySession(keySystem: .fairPlayStreaming)
        contentKeyDelegate = FairplayContentKeyDelegate()
        contentKeySession.setDelegate(contentKeyDelegate, queue: contentKeyDelegateQueue)
    }
}

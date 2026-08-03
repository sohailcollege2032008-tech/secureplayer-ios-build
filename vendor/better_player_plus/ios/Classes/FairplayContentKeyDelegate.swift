//
// FairplayContentKeyDelegate.swift
//
// Adapted from Apple's own "HLS Catalog With FPS" sample (FairPlay Streaming
// Server SDK 26.0.4, Development/Client/HLS Catalog With FPS/Shared/Managers/
// ContentKeyDelegate.swift + HLSCatalog/Manager/ContentKeyDelegate+Persistable.swift)
// — the two "MARK: ADAPT" hooks Apple leaves for integrators
// (requestApplicationCertificate / requestContentKeyFromKeySecurityModule)
// are filled in here with our bundled FPS certificate and a direct HTTPS
// call to the getFairplayLicense Cloud Function (same REST-callable protocol
// Studio's own encryptor/firebase_uploader.py already uses:
// POST {url} body {"data": {...}} header Authorization: Bearer <idToken>,
// response {"result": {...}}).
//
// Unlike Apple's sample (which supports both online-only and persistable
// keys per-asset), every asset here always requests a persistable key —
// SecurePlayer's whole model is "import once, play forever offline", there
// is no online-streaming-only use case on iOS.
//
// NOT independently verified — no Mac/Xcode/device available while writing
// this. Structurally follows Apple's own tested reference exactly; needs a
// real device build + playback test before being trusted.

import AVFoundation

/// Per-asset config needed to answer its key requests — set once before
/// playback starts (see BetterPlayer.swift's setDataSourceURL), read later
/// when AVFoundation actually issues the key request (which can happen at
/// an unpredictable time relative to configure(), so this must be cached,
/// not passed inline).
struct FairplayRequestConfig {
    let ksmProxyUrl: String
    let idToken: String
    let lectureId: String
    let videoId: String
    let courseId: String
    let deviceId: String
}

public class FairplayContentKeyDelegate: NSObject, AVContentKeySessionDelegate {

    enum FairplayError: Error {
        case missingApplicationCertificate
        case noCkcReturnedByKsm(String)
        case invalidRequestConfig
    }

    /// Keyed by assetID (the skd:// URI's host — "{lectureId}_{videoId}",
    /// matching fairplay_packager.py's content_id convention), so
    /// configuring one video doesn't clobber another's in-flight request.
    private var requestConfigs = [String: FairplayRequestConfig]()
    private var applicationCertificateURL: URL?
    private let configLock = NSLock()

    /// The directory persistable content keys are saved to. Mirrors Apple's
    /// sample exactly — a dot-prefixed folder under Documents.
    lazy var contentKeyDirectory: URL = {
        guard let documentPath =
            NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first else {
                fatalError("Unable to determine document directory URL")
        }
        let documentURL = URL(fileURLWithPath: documentPath)
        let dir = documentURL.appendingPathComponent(".fairplay_keys", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path, isDirectory: nil) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
        return dir
    }()

    /// Content key identifiers with a licence fetch already in flight.
    ///
    /// An HLS package with a separate audio rendition produces TWO tracks that
    /// carry the SAME `#EXT-X-KEY` (same `skd://` identifier), so AVFoundation
    /// issues two key requests for one identifier, effectively at once. On a
    /// first play neither finds a persisted key on disk, so without this guard
    /// both would fetch a licence, both would call
    /// `persistableContentKey(fromKeyVendorResponse:)`, and both would write
    /// the same file — a race that leaves the player stalled with no frames.
    ///
    /// This is why Apple's own HLS Catalog sample keeps
    /// `pendingPersistableContentKeyIdentifiers`. It was missed when this
    /// delegate was adapted from that sample, and stayed invisible for as long
    /// as the audio rendition was tagged DEFAULT=NO — AVPlayer never selected
    /// it, so only one key was ever requested (which is also why those builds
    /// played silently). Tagging audio as default surfaced it immediately.
    ///
    /// Guarded by `pendingLock`: the requests arrive on AVFoundation's queue,
    /// not necessarily serialised.
    private var pendingPersistableContentKeyIdentifiers = Set<String>()
    private let pendingLock = NSLock()

    /// Returns true if this call claimed the identifier (caller proceeds), or
    /// false if a fetch was already in flight (caller must not start another).
    private func claimPendingKeyRequest(_ identifier: String) -> Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return pendingPersistableContentKeyIdentifiers.insert(identifier).inserted
    }

    private func releasePendingKeyRequest(_ identifier: String) {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        pendingPersistableContentKeyIdentifiers.remove(identifier)
    }

    /// Called from BetterPlayer.swift before the asset is registered with
    /// the content key session. certURL is a bundled local asset (the FPS
    /// application certificate — public data, safe to ship in the app; the
    /// actual private key never leaves the KSM).
    func configure(applicationCertificateURL certURL: URL, requestConfig: [String: String]) {
        guard let ksmProxyUrl = requestConfig["ksmProxyUrl"],
              let idToken = requestConfig["idToken"],
              let lectureId = requestConfig["lectureId"],
              let videoId = requestConfig["videoId"],
              let courseId = requestConfig["courseId"],
              let deviceId = requestConfig["deviceId"] else {
            return
        }
        let assetID = "\(lectureId)_\(videoId)"
        let config = FairplayRequestConfig(
            ksmProxyUrl: ksmProxyUrl, idToken: idToken, lectureId: lectureId,
            videoId: videoId, courseId: courseId, deviceId: deviceId
        )
        configLock.lock()
        applicationCertificateURL = certURL
        requestConfigs[assetID] = config
        configLock.unlock()
    }

    private func requestApplicationCertificate() throws -> Data {
        configLock.lock()
        let url = applicationCertificateURL
        configLock.unlock()
        guard let url = url, let data = try? Data(contentsOf: url) else {
            throw FairplayError.missingApplicationCertificate
        }
        return data
    }

    /// Sends the SPC to getFairplayLicense and returns the CKC — mirrors
    /// firebase_uploader.py's _call_cloud_function exactly (same "callable"
    /// wire format), just from Swift via URLSession instead of Python's
    /// requests. Synchronous from the caller's point of view via a
    /// semaphore, matching how BetterPlayerEzDrmAssetsLoaderDelegate.swift
    /// (the plugin's own EZDRM path, right next to this file) already talks
    /// to a KSM — same tradeoff already accepted elsewhere in this codebase.
    private func requestContentKeyFromKeySecurityModule(spcData: Data, assetID: String) throws -> Data {
        configLock.lock()
        let config = requestConfigs[assetID]
        configLock.unlock()
        guard let config = config, let url = URL(string: config.ksmProxyUrl) else {
            throw FairplayError.invalidRequestConfig
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.idToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let body: [String: Any] = [
            "data": [
                "lectureId": config.lectureId,
                "videoId": config.videoId,
                "courseId": config.courseId,
                "deviceId": config.deviceId,
                "spc": spcData.base64EncodedString(),
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultError: Error?

        var httpStatus = -1
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
            if let error = error {
                resultError = error
            } else {
                resultData = data
            }
            semaphore.signal()
        }
        task.resume()
        let waitResult = semaphore.wait(timeout: .now() + 25)
        if waitResult == .timedOut {
            FairplayDiagnostics.log("KSM request TIMED OUT after 25s for \(assetID)")
            FairplayDiagnostics.uploadStallLog(config: config, reason: "KSM request timed out")
        }

        if let resultError = resultError {
            FairplayDiagnostics.log(
                "KSM request errored for \(assetID): "
                + FairplayDiagnostics.describe(resultError)
            )
            FairplayDiagnostics.uploadStallLog(config: config, reason: "KSM request errored")
            throw resultError
        }
        guard let resultData = resultData,
              let json = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let ckcBase64 = result["ckc"] as? String,
              let ckcData = Data(base64Encoded: ckcBase64) else {
            let raw = String(data: resultData ?? Data(), encoding: .utf8) ?? "<no body>"
            FairplayDiagnostics.log(
                "KSM returned no usable CKC for \(assetID) (HTTP \(httpStatus)): "
                + raw.prefix(300)
            )
            FairplayDiagnostics.uploadStallLog(config: config, reason: "KSM returned no usable CKC")
            throw FairplayError.noCkcReturnedByKsm(raw)
        }
        FairplayDiagnostics.log(
            "KSM returned CKC for \(assetID) (HTTP \(httpStatus), \(ckcData.count) bytes)"
        )
        return ckcData
    }

    // MARK: AVContentKeySessionDelegate

    public func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        handleStreamingContentKeyRequest(keyRequest: keyRequest)
    }

    public func contentKeySession(_ session: AVContentKeySession, didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) {
        handleStreamingContentKeyRequest(keyRequest: keyRequest)
    }

    public func contentKeySession(_ session: AVContentKeySession, shouldRetry keyRequest: AVContentKeyRequest,
                                   reason retryReason: AVContentKeyRequest.RetryReason) -> Bool {
        switch retryReason {
        case .timedOut, .receivedResponseWithExpiredLease, .receivedObsoleteContentKey:
            return true
        default:
            return false
        }
    }

    public func contentKeySession(_ session: AVContentKeySession, contentKeyRequest keyRequest: AVContentKeyRequest, didFailWithError err: Error) {
        // This is AVFoundation's own verdict on the key request and the single
        // most useful signal in the whole flow — it was previously discarded,
        // leaving "Cannot Open" as the only visible symptom.
        FairplayDiagnostics.log("KEY REQUEST FAILED: \(FairplayDiagnostics.describe(err))")
    }

    func handleStreamingContentKeyRequest(keyRequest: AVContentKeyRequest) {
        guard let contentKeyIdentifierString = keyRequest.identifier as? String,
              let contentKeyIdentifierURL = URL(string: contentKeyIdentifierString) else {
            FairplayDiagnostics.log(
                "ABORT: could not parse identifier "
                + "\(String(describing: keyRequest.identifier))"
            )
            keyRequest.processContentKeyResponseError(FairplayError.invalidRequestConfig)
            return
        }

        // Legacy (non-FairPlay) content key — e.g. the AES-128 key of a
        // mixed-encryption package (FairPlay video + AES-128 TS audio).
        // Once an asset is a contentKeySession recipient, AVFoundation
        // routes EVERY key request for it through this delegate — including
        // plain AES-128 ones whose EXT-X-KEY URI is an http:// URL. The
        // identifier IS that full URL (with ?t= already appended by the
        // manifest rewrite); fetch it and hand back the raw 16 key bytes.
        // This is the branch Apple's HLS Catalog sample carries for non-skd
        // identifiers and that was never ported here because everything was
        // FairPlay-only until the audio rendition fix.
        if contentKeyIdentifierURL.scheme?.lowercased() != "skd" {
            provideLegacyKey(keyRequest: keyRequest, url: contentKeyIdentifierURL)
            return
        }

        guard let assetIDString = contentKeyIdentifierURL.host else {
            FairplayDiagnostics.log(
                "ABORT: could not parse assetID from identifier "
                + "\(String(describing: keyRequest.identifier)) — a skd:// host that "
                + "URL(string:) rejects (underscores/case) would land here"
            )
            keyRequest.processContentKeyResponseError(FairplayError.invalidRequestConfig)
            return
        }

        FairplayDiagnostics.log("key request received for assetID=\(assetIDString)")

        // Every asset in this app is offline-persistable — always request the
        // persistable variant. Falls back to a plain (online) key only if the
        // platform refuses (e.g. an AirPlay session, per Apple's own sample).
        do {
            try keyRequest.respondByRequestingPersistableContentKeyRequestAndReturnError()
            FairplayDiagnostics.log("requested PERSISTABLE key for \(assetIDString)")
        } catch {
            FairplayDiagnostics.log(
                "persistable key request REFUSED, falling back to online key: "
                + FairplayDiagnostics.describe(error)
            )
            provideOnlineKey(keyRequest: keyRequest, assetID: assetIDString)
        }
    }

    /// Fetches a non-FairPlay content key (AES-128 etc.) from its URL — which
    /// is our local shelf server's /key route, already carrying ?t=. The raw
    /// response bytes ARE the key; hand them to AVFoundation via
    /// AVContentKeyResponse(clearKeyData:initializationVector:) so AVPlayer
    /// can decrypt the audio segments. initializationVector is nil because
    /// the IV comes from the HLS playlist itself (IV=0x000...0 in our m3u8).
    private func provideLegacyKey(keyRequest: AVContentKeyRequest, url: URL) {
        FairplayDiagnostics.log(
            "legacy (non-FairPlay) key request: \(url.absoluteString)"
        )
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                FairplayDiagnostics.log(
                    "legacy key fetch ERROR: \(FairplayDiagnostics.describe(error))"
                )
                keyRequest.processContentKeyResponseError(error)
                return
            }
            guard let data = data, data.count == 16 else {
                let raw = String(data: data ?? Data(), encoding: .utf8) ?? "<no body>"
                FairplayDiagnostics.log(
                    "legacy key fetch bad payload: "
                    + "\(data?.count ?? 0) bytes, \(raw.prefix(200))"
                )
                keyRequest.processContentKeyResponseError(FairplayError.noCkcReturnedByKsm(raw))
                return
            }
            keyRequest.processContentKeyResponse(
                AVContentKeyResponse(clearKeyData: data, initializationVector: nil)
            )
            FairplayDiagnostics.log("legacy key delivered (\(data.count) bytes)")
        }.resume()
    }

    private func provideOnlineKey(keyRequest: AVContentKeyRequest, assetID: String) {
        guard let assetIDData = assetID.data(using: .utf8) else {
            FairplayDiagnostics.log("ABORT: assetID not UTF-8 encodable: \(assetID)")
            return
        }
        do {
            let applicationCertificate = try requestApplicationCertificate()
            keyRequest.makeStreamingContentKeyRequestData(
                forApp: applicationCertificate,
                contentIdentifier: assetIDData,
                options: [AVContentKeyRequestProtocolVersionsKey: [1]]
            ) { [weak self] spcData, error in
                guard let self = self else { return }
                if let error = error {
                    keyRequest.processContentKeyResponseError(error)
                    return
                }
                guard let spcData = spcData else { return }
                do {
                    let ckcData = try self.requestContentKeyFromKeySecurityModule(spcData: spcData, assetID: assetID)
                    let response = AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckcData)
                    keyRequest.processContentKeyResponse(response)
                } catch {
                    keyRequest.processContentKeyResponseError(error)
                }
            }
        } catch {
            keyRequest.processContentKeyResponseError(error)
        }
    }
}

// MARK: - Persistable key handling (offline)
// Adapted from ContentKeyDelegate+Persistable.swift in Apple's sample.

extension FairplayContentKeyDelegate {

    public func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVPersistableContentKeyRequest) {
        handlePersistableContentKeyRequest(keyRequest: keyRequest)
    }

    func handlePersistableContentKeyRequest(keyRequest: AVPersistableContentKeyRequest, attempt: Int = 0) {
        guard let contentKeyIdentifierString = keyRequest.identifier as? String,
              let contentKeyIdentifierURL = URL(string: contentKeyIdentifierString),
              let assetIDString = contentKeyIdentifierURL.host,
              let assetIDData = assetIDString.data(using: .utf8) else {
            keyRequest.processContentKeyResponseError(FairplayError.invalidRequestConfig)
            return
        }

        // Same legacy-key guard as the streaming path: a non-skd identifier
        // (http://... AES-128 key URI) must be answered with the raw key
        // bytes, never sent down the FairPlay SPC/CKC flow.
        if contentKeyIdentifierURL.scheme?.lowercased() != "skd" {
            provideLegacyKey(keyRequest: keyRequest, url: contentKeyIdentifierURL)
            return
        }

        // Already downloaded and persisted — fully offline path, zero network.
        if persistableContentKeyExistsOnDisk(withContentKeyIdentifier: assetIDString) {
            let url = urlForPersistableContentKey(withContentKeyIdentifier: assetIDString)
            if let contentKey = FileManager.default.contents(atPath: url.path) {
                FairplayDiagnostics.log(
                    "reusing PERSISTED key on disk for \(assetIDString) "
                    + "(\(contentKey.count) bytes) — no network"
                )
                let response = AVContentKeyResponse(fairPlayStreamingKeyResponseData: contentKey)
                keyRequest.processContentKeyResponse(response)
                return
            }
            FairplayDiagnostics.log("persisted key file unreadable, re-requesting")
        }

        // No key on disk yet. Only ONE licence fetch may run per identifier —
        // see pendingPersistableContentKeyIdentifiers. A second track (audio)
        // asking for the same key waits for the first to land rather than
        // starting a competing fetch.
        guard claimPendingKeyRequest(assetIDString) else {
            // Bounded wait: ~10s in 250ms steps. Re-entering re-runs the
            // on-disk fast path above, so this resolves as soon as the
            // in-flight fetch writes the key. If that fetch instead fails and
            // releases its claim, this call takes over and fetches itself.
            guard attempt < 40 else {
                FairplayDiagnostics.log(
                    "gave up waiting for in-flight key fetch for \(assetIDString)"
                )
                keyRequest.processContentKeyResponseError(FairplayError.invalidRequestConfig)
                return
            }
            if attempt == 0 {
                FairplayDiagnostics.log(
                    "key fetch already in flight for \(assetIDString) "
                    + "(second track — audio rendition); waiting"
                )
            }
            DispatchQueue.global(qos: .userInitiated)
                .asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.handlePersistableContentKeyRequest(
                        keyRequest: keyRequest, attempt: attempt + 1)
                }
            return
        }

        do {
            let applicationCertificate = try requestApplicationCertificate()
            FairplayDiagnostics.log(
                "loaded FPS certificate (\(applicationCertificate.count) bytes), building SPC"
            )
            keyRequest.makeStreamingContentKeyRequestData(
                forApp: applicationCertificate,
                contentIdentifier: assetIDData,
                options: [AVContentKeyRequestProtocolVersionsKey: [1]]
            ) { [weak self] spcData, error in
                guard let self = self else { return }
                if let error = error {
                    FairplayDiagnostics.log(
                        "SPC generation FAILED: " + FairplayDiagnostics.describe(error)
                    )
                    self.releasePendingKeyRequest(assetIDString)
                    keyRequest.processContentKeyResponseError(error)
                    return
                }
                guard let spcData = spcData else {
                    FairplayDiagnostics.log("SPC generation returned no data and no error")
                    self.releasePendingKeyRequest(assetIDString)
                    return
                }
                FairplayDiagnostics.log("SPC built (\(spcData.count) bytes), calling KSM")
                do {
                    let ckcData = try self.requestContentKeyFromKeySecurityModule(spcData: spcData, assetID: assetIDString)
                    let persistentKey = try keyRequest.persistableContentKey(fromKeyVendorResponse: ckcData, options: nil)
                    FairplayDiagnostics.log(
                        "converted CKC to persistable key (\(persistentKey.count) bytes)"
                    )
                    try self.writePersistableContentKey(contentKey: persistentKey, withContentKeyIdentifier: assetIDString)
                    FairplayDiagnostics.log("persisted key written to disk, responding to AVFoundation")

                    // Released only AFTER the key is on disk, so a waiting
                    // second track re-checks and finds it rather than starting
                    // its own fetch.
                    self.releasePendingKeyRequest(assetIDString)
                    let response = AVContentKeyResponse(fairPlayStreamingKeyResponseData: persistentKey)
                    keyRequest.processContentKeyResponse(response)
                } catch {
                    self.releasePendingKeyRequest(assetIDString)
                    // Covers the KSM call, the CKC->persistable conversion (which
                    // fails if the CKC was not issued for offline use), and the
                    // disk write — previously indistinguishable from each other.
                    FairplayDiagnostics.log(
                        "persistable key flow FAILED: " + FairplayDiagnostics.describe(error)
                    )
                    // Debug-only: push the log to the backend even if the UI is
                    // frozen, so the stall investigation has the failing stage.
                    self.uploadStallLogForAsset(assetID: assetIDString, reason: "persistable key flow failed")
                    keyRequest.processContentKeyResponseError(error)
                }
            }
        } catch {
            // requestApplicationCertificate() threw — the claim above is still
            // held and must not leak, or the audio track waits out its full
            // retry budget for a fetch that never started.
            releasePendingKeyRequest(assetIDString)
            keyRequest.processContentKeyResponseError(error)
        }
    }

    func persistableContentKeyExistsOnDisk(withContentKeyIdentifier contentKeyIdentifier: String) -> Bool {
        FileManager.default.fileExists(atPath: urlForPersistableContentKey(withContentKeyIdentifier: contentKeyIdentifier).path)
    }

    func urlForPersistableContentKey(withContentKeyIdentifier contentKeyIdentifier: String) -> URL {
        contentKeyDirectory.appendingPathComponent("\(contentKeyIdentifier)-Key")
    }

    func writePersistableContentKey(contentKey: Data, withContentKeyIdentifier contentKeyIdentifier: String) throws {
        let fileURL = urlForPersistableContentKey(withContentKeyIdentifier: contentKeyIdentifier)
        try contentKey.write(to: fileURL, options: Data.WritingOptions.atomicWrite)
    }

    /// Debug-only (branch `debug-fairplay-logviewer`): uploads the current
    /// diagnostics log to the backend the moment a key-exchange stage fails,
    /// independent of the Dart UI (which may be frozen). Reads the request
    /// config by assetID to obtain the idToken.
    func uploadStallLogForAsset(assetID: String, reason: String) {
        configLock.lock()
        let config = requestConfigs[assetID]
        configLock.unlock()
        guard let config = config else { return }
        FairplayDiagnostics.uploadStallLog(config: config, reason: reason)
    }
}

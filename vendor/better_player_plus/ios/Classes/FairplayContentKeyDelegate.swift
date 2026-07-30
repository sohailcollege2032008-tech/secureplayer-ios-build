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

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                resultError = error
            } else {
                resultData = data
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 25)

        if let resultError = resultError {
            throw resultError
        }
        guard let resultData = resultData,
              let json = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let ckcBase64 = result["ckc"] as? String,
              let ckcData = Data(base64Encoded: ckcBase64) else {
            let raw = String(data: resultData ?? Data(), encoding: .utf8) ?? "<no body>"
            throw FairplayError.noCkcReturnedByKsm(raw)
        }
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
        // Nothing to clean up here — the completion/error path in
        // handlePersistableContentKeyRequest already handles per-request state.
    }

    func handleStreamingContentKeyRequest(keyRequest: AVContentKeyRequest) {
        guard let contentKeyIdentifierString = keyRequest.identifier as? String,
              let contentKeyIdentifierURL = URL(string: contentKeyIdentifierString),
              let assetIDString = contentKeyIdentifierURL.host else {
            keyRequest.processContentKeyResponseError(FairplayError.invalidRequestConfig)
            return
        }

        // Every asset in this app is offline-persistable — always request the
        // persistable variant. Falls back to a plain (online) key only if the
        // platform refuses (e.g. an AirPlay session, per Apple's own sample).
        do {
            try keyRequest.respondByRequestingPersistableContentKeyRequestAndReturnError()
        } catch {
            provideOnlineKey(keyRequest: keyRequest, assetID: assetIDString)
        }
    }

    private func provideOnlineKey(keyRequest: AVContentKeyRequest, assetID: String) {
        guard let assetIDData = assetID.data(using: .utf8) else { return }
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

    func handlePersistableContentKeyRequest(keyRequest: AVPersistableContentKeyRequest) {
        guard let contentKeyIdentifierString = keyRequest.identifier as? String,
              let contentKeyIdentifierURL = URL(string: contentKeyIdentifierString),
              let assetIDString = contentKeyIdentifierURL.host,
              let assetIDData = assetIDString.data(using: .utf8) else {
            keyRequest.processContentKeyResponseError(FairplayError.invalidRequestConfig)
            return
        }

        // Already downloaded and persisted — fully offline path, zero network.
        if persistableContentKeyExistsOnDisk(withContentKeyIdentifier: assetIDString) {
            let url = urlForPersistableContentKey(withContentKeyIdentifier: assetIDString)
            if let contentKey = FileManager.default.contents(atPath: url.path) {
                let response = AVContentKeyResponse(fairPlayStreamingKeyResponseData: contentKey)
                keyRequest.processContentKeyResponse(response)
                return
            }
            // Persisted file went missing/corrupt — fall through and re-request.
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
                    let ckcData = try self.requestContentKeyFromKeySecurityModule(spcData: spcData, assetID: assetIDString)
                    let persistentKey = try keyRequest.persistableContentKey(fromKeyVendorResponse: ckcData, options: nil)
                    try self.writePersistableContentKey(contentKey: persistentKey, withContentKeyIdentifier: assetIDString)

                    let response = AVContentKeyResponse(fairPlayStreamingKeyResponseData: persistentKey)
                    keyRequest.processContentKeyResponse(response)
                } catch {
                    keyRequest.processContentKeyResponseError(error)
                }
            }
        } catch {
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
}

import Foundation
import MachO // _dyld_image_count / _dyld_get_image_name
import Network

enum SecurityChannel {

  static func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isRooted", "isFridaDetected", "isXposedDetected", "isMagiskHidden", "isSignatureValid":
      let method = call.method
      DispatchQueue.global(qos: .userInitiated).async {
        let value = runCheck(method)
        DispatchQueue.main.async { result(value) }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func runCheck(_ method: String) -> Bool {
    switch method {
    case "isRooted": return isRooted()
    case "isFridaDetected": return isFridaDetected()
    case "isXposedDetected": return isTweakInjectionFrameworkDetected()
    case "isMagiskHidden": return isJailbreakConcealmentDetected()
    case "isSignatureValid": return isSignatureValid()
    default: return false
    }
  }

  // Same Base64-obfuscation convention as Android's MainActivity.kt b64()
  // helper — decode-only, defeats trivial strings/decompiler grep, not
  // real crypto.
  private static func b64(_ s: String) -> String {
    guard let data = Data(base64Encoded: s),
          let decoded = String(data: data, encoding: .utf8) else { return "" }
    return decoded
  }

  private static let jailbreakPaths: [String] = [
    "L0FwcGxpY2F0aW9ucy9DeWRpYS5hcHA=",   // /Applications/Cydia.app
    "L0FwcGxpY2F0aW9ucy9TaWxlby5hcHA=",   // /Applications/Sileo.app
    "L0FwcGxpY2F0aW9ucy9aZWJyYS5hcHA=",   // /Applications/Zebra.app
    "L0FwcGxpY2F0aW9ucy9JbnN0YWxsZXIuYXBw", // /Applications/Installer.app
    "L0xpYnJhcnkvTW9iaWxlU3Vic3RyYXRlL01vYmlsZVN1YnN0cmF0ZS5keWxpYg==", // /Library/MobileSubstrate/MobileSubstrate.dylib
    "L2Jpbi9iYXNo",                       // /bin/bash
    "L3Vzci9zYmluL3NzaGQ=",               // /usr/sbin/sshd
    "L2V0Yy9hcHQ=",                       // /etc/apt
    "L3ByaXZhdGUvdmFyL2xpYi9hcHQ=",       // /private/var/lib/apt
    "L3ByaXZhdGUvdmFyL2xpYi9jeWRpYQ==",   // /private/var/lib/cydia
    "L3ByaXZhdGUvdmFyL3N0YXNo",           // /private/var/stash
    "L3Zhci9iaW5wYWNr",                   // /var/binpack (rootless jailbreak marker)
    "L3Zhci9qYg==",                       // /var/jb (Dopamine/palera1n rootless root)
  ].map { b64($0) }

  // Jailbreak concepts don't apply to the Simulator (it runs on the host
  // Mac's own kernel, not a real iOS device) — these checks short-circuit
  // to a fixed, honest "clean" result on Simulator rather than running
  // meaningless file/process probes against the host machine. Mirrors the
  // spirit of Android's isEmulator signal, though unlike Android this has
  // no separate surfaced reason — acceptable since kDebugMode already
  // short-circuits detectCause() before any release-mode Simulator run
  // would reach these checks in practice.
  private static func isRooted() -> Bool {
    #if targetEnvironment(simulator)
    return false
    #else
    for path in jailbreakPaths {
      if FileManager.default.fileExists(atPath: path) { return true }
    }
    return sandboxEscapeWriteSucceeds()
    #endif
  }

  // Rootful jailbreaks patch/disable the sandbox, so writing outside the
  // app's container (blocked on stock iOS) succeeds. Complements the path
  // checks above rather than replacing them: rootless jailbreaks
  // (var/jb-style) often still sandbox the process normally, so the write
  // test alone under-detects rootless, and the path list alone
  // under-detects rootful jailbreaks using nonstandard paths.
  private static func sandboxEscapeWriteSucceeds() -> Bool {
    let testPath = "/private/\(UUID().uuidString).txt"
    do {
      try "t".write(toFile: testPath, atomically: true, encoding: .utf8)
      try? FileManager.default.removeItem(atPath: testPath)
      return true
    } catch {
      return false
    }
  }

  private static let fridaMarkers: [String] = [
    "RnJpZGFHYWRnZXQ=", // FridaGadget
    "ZnJpZGE=",         // frida
    "Z3VtLWpzLWxvb3A=", // gum-js-loop
    "ZnJpZGEtYWdlbnQ=", // frida-agent
    "Y3luamVjdA==",     // cynject
  ].map { b64($0) }

  private static func isFridaDetected() -> Bool {
    #if targetEnvironment(simulator)
    return false
    #else
    if ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"] != nil { return true }
    for image in loadedImageNames() {
      for marker in fridaMarkers where image.localizedCaseInsensitiveContains(marker) {
        return true
      }
    }
    return isLoopbackPortOpen(port: 27042, timeoutMs: 200) // frida-server's default port
    #endif
  }

  private static func loadedImageNames() -> [String] {
    var names: [String] = []
    let count = _dyld_image_count()
    for i in 0..<count {
      if let cName = _dyld_get_image_name(i) {
        names.append(String(cString: cName))
      }
    }
    return names
  }

  // Network.framework + semaphore instead of hand-rolled BSD sockets —
  // Swift's fd_set bridging is a well-known footgun; NWConnection is the
  // modern, documented-correct pattern for a bounded port probe.
  private static func isLoopbackPortOpen(port: UInt16, timeoutMs: Int) -> Bool {
    guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
    let semaphore = DispatchSemaphore(value: 0)
    var isOpen = false
    let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
    connection.stateUpdateHandler = { state in
      switch state {
      case .ready: isOpen = true; semaphore.signal()
      case .failed, .cancelled: semaphore.signal()
      default: break
      }
    }
    connection.start(queue: DispatchQueue.global(qos: .utility))
    _ = semaphore.wait(timeout: .now() + .milliseconds(timeoutMs))
    connection.cancel()
    return isOpen
  }

  // "Xposed" wire contract -> Substrate/tweak-injection frameworks.
  // Xposed/LSPosed have no literal iOS equivalent; Cydia Substrate /
  // Substitute / libhooker play the same system-wide-hooking role on iOS
  // that Xposed plays on Android — consistent with Android's own
  // XPOSED_STACK_MARKERS list already treating "com.saurik.substrate" as
  // an Xposed-family marker.
  private static let substrateMarkers: [String] = [
    "TW9iaWxlU3Vic3RyYXRl",           // MobileSubstrate
    "Q3lkaWFTdWJzdHJhdGU=",           // CydiaSubstrate
    "U3Vic3RyYXRlTG9hZGVyLmR5bGli",   // SubstrateLoader.dylib
    "bGliaG9va2VyLmR5bGli",           // libhooker.dylib
  ].map { b64($0) }

  // /Library/MobileSubstrate/DynamicLibraries — shared by both the tweak-
  // injection check and the concealment check below, decoded once.
  private static let dynamicLibrariesDir =
    b64("L0xpYnJhcnkvTW9iaWxlU3Vic3RyYXRlL0R5bmFtaWNMaWJyYXJpZXM=")

  private static func isTweakInjectionFrameworkDetected() -> Bool {
    #if targetEnvironment(simulator)
    return false
    #else
    for image in loadedImageNames() {
      for marker in substrateMarkers where image.localizedCaseInsensitiveContains(marker) {
        return true
      }
    }
    if let contents = try? FileManager.default.contentsOfDirectory(atPath: dynamicLibrariesDir), !contents.isEmpty {
      return true // non-empty tweak-registration dir ~ Xposed's module list
    }
    return false
    #endif
  }

  // "MagiskHidden" wire contract -> jailbreak-concealment tooling.
  // Magisk-hidden's purpose on Android is catching evasion, not just root;
  // the iOS analog is bypass tools (Shadow, A-Bypass) that specifically
  // try to hide jailbreak markers from naive checks like isRooted() above.
  private static let concealmentToolMarkers: [String] = [
    "U2hhZG93LnBsaXN0",     // Shadow.plist
    "QS1CeXBhc3MuZHlsaWI=", // A-Bypass.dylib
  ].map { b64($0) }

  private static func isJailbreakConcealmentDetected() -> Bool {
    #if targetEnvironment(simulator)
    return false
    #else
    for marker in concealmentToolMarkers {
      if FileManager.default.fileExists(atPath: (dynamicLibrariesDir as NSString).appendingPathComponent(marker)) {
        return true
      }
    }
    // A concealment tool that hooks only the high-level FileManager API
    // (the common approach) leaves the raw POSIX syscall telling the
    // truth — a mismatch between the two is itself a signal.
    let probe = b64("L0FwcGxpY2F0aW9ucy9DeWRpYS5hcHA=") // /Applications/Cydia.app
    let viaFoundation = FileManager.default.fileExists(atPath: probe)
    let viaPOSIX = access(probe, F_OK) == 0
    return viaFoundation != viaPOSIX
    #endif
  }

  // Deliberately NOT a pinned-hash check like Android's isSignatureValid.
  // Sideloadly + a free personal-team Apple ID produces a fresh, unstable
  // ad-hoc signing identity each time (re-signed every 7 days) — there is
  // nothing meaningful to pin yet, and we don't know the eventual
  // production distribution method (App Store strips embedded
  // .mobileprovision entirely; Enterprise/ad-hoc don't). This checks
  // structural consistency instead: profile exists, and its authorized
  // bundle ID matches the running bundle ID.
  private static func isSignatureValid() -> Bool {
    #if targetEnvironment(simulator)
    return true
    #else
    guard let profilePath = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
          let profileData = FileManager.default.contents(atPath: profilePath),
          let profileString = String(data: profileData, encoding: .isoLatin1) else {
      return false // fail closed: no embedded profile at all is suspicious for this distribution channel
    }
    // The plist payload sits as plaintext XML inside the outer CMS/PKCS#7
    // signature blob — slice it out by bracket-matching rather than a full
    // CMS parse. isoLatin1 (not utf8) is a byte-preserving decode that
    // never fails on the surrounding binary signature bytes.
    guard let start = profileString.range(of: "<?xml"),
          let end = profileString.range(of: "</plist>") else { return false }
    let plistSlice = String(profileString[start.lowerBound..<end.upperBound])
    guard let plistData = plistSlice.data(using: .isoLatin1),
          let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
          let entitlements = plist["Entitlements"] as? [String: Any],
          let appIdentifier = entitlements["application-identifier"] as? String,
          let bundleId = Bundle.main.bundleIdentifier else {
      return false
    }
    // application-identifier is "<TEAMID>.<bundle-id>" — confirms the
    // running binary matches what this profile actually authorizes.
    return appIdentifier.hasSuffix(".\(bundleId)")
    #endif
  }
}

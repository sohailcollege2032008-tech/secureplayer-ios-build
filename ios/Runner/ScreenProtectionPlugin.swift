import Flutter
import UIKit

/// FlutterStreamHandler for EventChannel("secureplayer/security_events") —
/// the same channel Android/Windows already use. Emits the same event
/// vocabulary Android does (recording_started/stopped,
/// hdmi_connected/disconnected, focus_lost/gained) so the entire
/// downstream Dart pipeline needs zero new state.
final class ScreenProtectionPlugin: NSObject, FlutterStreamHandler {

  private var eventSink: FlutterEventSink?
  private var observerTokens: [NSObjectProtocol] = []

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    registerObservers()

    // Immediate initial checks at listener-attach time — mirrors Android's
    // immediate hdmi_connected check in setupDisplayListener().
    if UIScreen.main.isCaptured { events("recording_started") }
    if UIScreen.screens.count > 1 { events("hdmi_connected") }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    let center = NotificationCenter.default
    observerTokens.forEach { center.removeObserver($0) }
    observerTokens.removeAll()
    eventSink = nil
    return nil
  }

  private func registerObservers() {
    let center = NotificationCenter.default

    observerTokens.append(center.addObserver(
      forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.eventSink?(UIScreen.main.isCaptured ? "recording_started" : "recording_stopped")
    })

    // willResignActive fires synchronously before the OS takes its
    // App-Switcher thumbnail — routing this into the same focus_lost/
    // focus_gained plumbing Android already has gives real protection
    // against switcher-preview snapshots "for free."
    observerTokens.append(center.addObserver(
      forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.eventSink?("focus_lost") })

    observerTokens.append(center.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.eventSink?("focus_gained") })

    observerTokens.append(center.addObserver(
      forName: UIScreen.didConnectNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.eventSink?("hdmi_connected") })

    observerTokens.append(center.addObserver(
      forName: UIScreen.didDisconnectNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.eventSink?("hdmi_disconnected") })
  }
}

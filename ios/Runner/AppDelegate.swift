import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {

  private var screenProtectionPlugin: ScreenProtectionPlugin?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let securityChannel = FlutterMethodChannel(
        name: "secureplayer/security", binaryMessenger: controller.binaryMessenger)
      securityChannel.setMethodCallHandler { call, result in
        SecurityChannel.handle(call: call, result: result)
      }

      let plugin = ScreenProtectionPlugin()
      screenProtectionPlugin = plugin
      let securityEventChannel = FlutterEventChannel(
        name: "secureplayer/security_events", binaryMessenger: controller.binaryMessenger)
      securityEventChannel.setStreamHandler(plugin)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

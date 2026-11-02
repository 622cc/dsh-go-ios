import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let ok = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    if let controller = window?.rootViewController as? FlutterViewController {
      setupDshChannels(controller: controller)
    }

    return ok
  }

  private func setupDshChannels(controller: FlutterViewController) {
    let messenger = controller.binaryMessenger

    // 1. dsh/app
    let appChannel = FlutterMethodChannel(name: "dsh/app", binaryMessenger: messenger)
    appChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
      switch call.method {
      case "getTimeZoneId":
        result(TimeZone.current.identifier)
      case "bringToFront":
        result(nil)
      case "getRefreshRate":
        result(Float(UIScreen.main.maximumFramesPerSecond))
      default:
        result(nil)
      }
    }

    // 2. dsh/runtime
    let runtimeChannel = FlutterMethodChannel(name: "dsh/runtime", binaryMessenger: messenger)
    runtimeChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
      switch call.method {
      case "getStatus":
        result([
          "status": "stopped",
          "installed": true,
          "running": false,
          "platform": "ios_trollstore"
        ])
      case "install":
        result(["success": true])
      case "installManagedSkill":
        result([
          "result": "success",
          "current": true,
          "reason": nil
        ])
      case "cancelManagedSkill":
        result(nil)
      default:
        result(nil)
      }
    }

    // 3. dsh/launch
    let launchChannel = FlutterMethodChannel(name: "dsh/launch", binaryMessenger: messenger)
    launchChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
      switch call.method {
      case "begin":
        result(nil)
      case "reveal":
        result(true)
      case "mark", "done":
        result(nil)
      case "snapshot":
        result(nil)
      default:
        result(nil)
      }
    }

    // 4. dsh/diagnostics
    let diagChannel = FlutterMethodChannel(name: "dsh/diagnostics", binaryMessenger: messenger)
    diagChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
      switch call.method {
      case "getDiagnostics":
        result([
          "os": "iOS",
          "version": UIDevice.current.systemVersion,
          "model": UIDevice.current.model,
          "trollstore": true
        ])
      default:
        result(nil)
      }
    }

    // 5. 通用 fallback channel 列表，避免 MissingPluginException 引起 Dart 报错
    let fallbackChannels = [
      "dsh/pet_overlay",
      "dsh/shortcuts",
      "dsh/share",
      "dsh/notify",
      "dsh/media",
      "dsh/performance",
      "dsh/native-files",
      "dsh/native-media",
      "dsh/voice",
      "dsh/launcher_icon",
      "dsh/dynamic_color",
      "dsh/files",
      "dsh/picture_shortcut",
      "dsh/islands",
      "dsh/web-files",
      "dsh/update",
      "dsh/usage",
      "dsh/launch_clip",
      "dsh/phone"
    ]

    for channelName in fallbackChannels {
      let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
      channel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
        result(nil)
      }
    }
  }
}

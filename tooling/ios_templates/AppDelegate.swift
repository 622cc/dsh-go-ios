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

    // 2. dsh/runtime & dsh/runtime/events
    let runtimeChannel = FlutterMethodChannel(name: "dsh/runtime", binaryMessenger: messenger)
    runtimeChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
      let service = DshEngineService.shared
      switch call.method {
      case "getStatus":
        result(service.status())
      case "install":
        let dropKept = (call.arguments as? [String: Any])?["dropKept"] as? Bool ?? false
        service.install(dropKept: dropKept) { error in
          if let error = error {
            result(FlutterError(code: "install_failed", message: error.localizedDescription, details: nil))
          } else {
            result(nil)
          }
        }
      case "start":
        let args = call.arguments as? [String: Any] ?? [:]
        let env = (args["env"] as? [String: Any] ?? [:]).reduce(into: [String: String]()) { acc, pair in
          acc[pair.key] = "\(pair.value)"
        }
        service.start(env: env)
        result(nil)
      case "stop":
        service.stop()
        result(nil)
      case "reset":
        service.reset { error in
          if let error = error {
            result(FlutterError(code: "reset_failed", message: error.localizedDescription, details: nil))
          } else {
            result(nil)
          }
        }
      case "getLogs":
        let lines = (call.arguments as? [String: Any])?["lines"] as? Int ?? 500
        result(service.recentLogs(lines: lines))
      case "getLogSnapshot":
        let lines = (call.arguments as? [String: Any])?["lines"] as? Int ?? 300
        result(service.logSnapshot(lines: lines))
      case "installManagedSkill":
        result([
          "result": "success",
          "current": true,
          "reason": nil
        ])
      case "cancelManagedSkill":
        result(nil)
      case "safePreflight":
        result([])
      case "moveAside":
        result([])
      case "clearFailure":
        result(nil)
      case "setAutoSafe":
        result(nil)
      case "setDirectEngine":
        result(nil)
      case "failureLog":
        result([])
      case "storageStatus", "requestStorage":
        result([
          "granted": true,
          "permission": true,
          "legacy": true,
          "guestPath": "/sdcard"
        ])
      case "batteryExempt", "requestBatteryExempt":
        result(true)
      default:
        result(nil)
      }
    }

    let runtimeEventsChannel = FlutterEventChannel(name: "dsh/runtime/events", binaryMessenger: messenger)
    runtimeEventsChannel.setStreamHandler(DshRuntimeStreamHandler())

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

class DshRuntimeStreamHandler: NSObject, FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    DshEngineService.shared.eventSink = events
    // 刚订阅时主动推送一次当前最新状态
    events([
      "type": "status",
      "status": DshEngineService.shared.status()
    ])
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    DshEngineService.shared.eventSink = nil
    return nil
  }
}

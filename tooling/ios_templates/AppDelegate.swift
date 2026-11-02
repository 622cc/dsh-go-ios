import UIKit
import Flutter

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var linksChannel: FlutterMethodChannel?
  private var linksReady = false
  private var pendingLinks: [String] = []
  private var bgTask: UIBackgroundTaskIdentifier = .invalid

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let ok = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    if let controller = window?.rootViewController as? FlutterViewController {
      setupDshChannels(controller: controller)
    }

    if let url = launchOptions?[.url] as? URL {
      deliverLink(url)
    }

    return ok
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey : Any] = [:]
  ) -> Bool {
    deliverLink(url)
    dismissPresentedBrowser()
    return true
  }

  override func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
       let url = userActivity.webpageURL {
      deliverLink(url)
      dismissPresentedBrowser()
      return true
    }
    return super.application(application, continue: userActivity, restorationHandler: restorationHandler)
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    super.applicationDidEnterBackground(application)
    // 保持后台网络与 SSH 隧道存活，防止切去浏览器授权或切应用时 SSH 断联及本地回调端口冻结
    if bgTask != .invalid {
      application.endBackgroundTask(bgTask)
      bgTask = .invalid
    }
    bgTask = application.beginBackgroundTask(withName: "DshSshKeepAlive") { [weak self] in
      guard let self = self else { return }
      if self.bgTask != .invalid {
        application.endBackgroundTask(self.bgTask)
        self.bgTask = .invalid
      }
    }
  }

  override func applicationWillEnterForeground(_ application: UIApplication) {
    super.applicationWillEnterForeground(application)
    if bgTask != .invalid {
      application.endBackgroundTask(bgTask)
      bgTask = .invalid
    }
  }

  private func dismissPresentedBrowser() {
    DispatchQueue.main.async { [weak self] in
      if let presented = self?.window?.rootViewController?.presentedViewController {
        presented.dismiss(animated: true, completion: nil)
      }
    }
  }

  private func deliverLink(_ url: URL) {
    let uri = url.absoluteString
    guard !uri.isEmpty else { return }
    if linksReady, let channel = linksChannel {
      channel.invokeMethod("link", arguments: ["uri": uri])
    } else {
      pendingLinks.append(uri)
    }
  }

  private func setupDshChannels(controller: FlutterViewController) {
    let messenger = controller.binaryMessenger

    // 0. dsh/links (处理 dshgo:// 授权回调与分享深链)
    let links = FlutterMethodChannel(name: "dsh/links", binaryMessenger: messenger)
    self.linksChannel = links
    links.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self = self else {
        result(nil)
        return
      }
      if call.method == "ready" {
        self.linksReady = true
        let queued = self.pendingLinks
        self.pendingLinks.removeAll()
        for uri in queued {
          links.invokeMethod("link", arguments: ["uri": uri])
        }
        result(true)
      } else {
        result(nil)
      }
    }

    // 1. dsh/app
    let appChannel = FlutterMethodChannel(name: "dsh/app", binaryMessenger: messenger)
    appChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      switch call.method {
      case "getTimeZoneId":
        result(TimeZone.current.identifier)
      case "bringToFront":
        self?.dismissPresentedBrowser()
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

    // 5. 接管 flutter_secure_storage，解决 TrollStore Ad-Hoc 签名无 Keychain Access Group (-34018) 导致远程主机“没能保存”的问题
    let secureStorageChannel = FlutterMethodChannel(
      name: "plugins.it_nomads.com/flutter_secure_storage",
      binaryMessenger: messenger
    )
    let secPrefix = "trollstore.keychain."
    secureStorageChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
      let args = call.arguments as? [String: Any] ?? [:]
      let key = args["key"] as? String ?? ""
      let defaults = UserDefaults.standard

      switch call.method {
      case "write":
        if !key.isEmpty {
          if let value = args["value"] as? String {
            defaults.set(value, forKey: secPrefix + key)
          } else {
            defaults.removeObject(forKey: secPrefix + key)
          }
          defaults.synchronize()
        }
        result(nil)
      case "read":
        if key.isEmpty {
          result(nil)
        } else {
          result(defaults.string(forKey: secPrefix + key))
        }
      case "delete":
        if !key.isEmpty {
          defaults.removeObject(forKey: secPrefix + key)
          defaults.synchronize()
        }
        result(nil)
      case "deleteAll":
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(secPrefix) {
          defaults.removeObject(forKey: k)
        }
        defaults.synchronize()
        result(nil)
      case "readAll":
        var map: [String: String] = [:]
        for (k, v) in defaults.dictionaryRepresentation() where k.hasPrefix(secPrefix) {
          if let str = v as? String {
            let rawKey = String(k.dropFirst(secPrefix.count))
            map[rawKey] = str
          }
        }
        result(map)
      case "containsKey":
        if key.isEmpty {
          result(false)
        } else {
          result(defaults.object(forKey: secPrefix + key) != nil)
        }
      default:
        result(nil)
      }
    }

    // 6. 通用 fallback channel 列表，避免 MissingPluginException 引起 Dart 报错
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

/// iOS TrollStore 纯远程模式 (Remote-Only) 状态服务
public class DshEngineService: NSObject {
    public static let shared = DshEngineService()

    public var eventSink: FlutterEventSink? = nil

    private override init() {
        super.init()
    }

    public func status() -> [String: Any?] {
        // phase = notInstalled 且 bundledVersion != nil 会触发 Flutter 端 runtimeMissing = true，进入纯远程模式
        return [
            "phase": "notInstalled",
            "baseUrl": nil,
            "token": nil,
            "abi": "arm64",
            "bundledVersion": "1.0.0",
            "installedVersion": nil,
            "dshVersion": nil,
            "nodeVersion": nil,
            "error": nil,
            "mode": "normal",
            "safeState": "off",
            "strikes": 0,
            "autoSafe": false,
            "directEngineEnabled": false,
            "directEngineAvailable": false,
            "directEngineActive": false
        ]
    }

    public func install(dropKept: Bool = false, completion: @escaping (Error?) -> Void) {
        completion(nil)
    }

    public func start(env: [String: String] = [:], port: Int = 3080) {
        // 纯远程模式无需启动本地进程
    }

    public func stop() {
        // 纯远程模式无需停止本地进程
    }

    public func reset(completion: @escaping (Error?) -> Void) {
        completion(nil)
    }

    public func recentLogs(lines: Int) -> [String] {
        return ["[dsh-app] Running in iOS Remote-Only mode"]
    }

    public func logSnapshot(lines: Int) -> [String: Any] {
        return [
            "entries": [
                ["seq": 1, "line": "[dsh-app] Running in iOS Remote-Only mode", "stream": "system"]
            ],
            "throughSeq": 1
        ]
    }
}

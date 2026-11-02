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

/// iOS TrollStore 环境下管理本地 Node.js 驱动的 DeepSeek Harness (DSH) 原生引擎服务
public class DshEngineService: NSObject {
    public static let shared = DshEngineService()

    public enum Phase: String {
        case notInstalled
        case installing
        case installed
        case starting
        case running
        case stopping
        case error
    }

    public struct LogEntry {
        let seq: Int
        let line: String
        let stream: String

        func toMap() -> [String: Any] {
            return ["seq": seq, "line": line, "stream": stream]
        }
    }

    private var currentPhase: Phase = .notInstalled
    private var baseUrl: String? = nil
    private var token: String? = nil
    private var lastError: String? = nil
    private var processPid: pid_t = 0
    private var runningPort: Int = 3080

    private var logEntries: [LogEntry] = []
    private var seqCounter: Int = 0
    private let logQueue = DispatchQueue(label: "io.github.ccch1mneyyy.dsh.logs")
    private let stateQueue = DispatchQueue(label: "io.github.ccch1mneyyy.dsh.state")

    public var eventSink: FlutterEventSink? = nil

    private override init() {
        super.init()
        checkInitialStatus()
    }

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var engineDirectory: URL {
        documentsDirectory.appendingPathComponent("engine")
    }

    private var nodeBinaryPath: String {
        engineDirectory.appendingPathComponent("bin/node").path
    }

    private var dshEntryPath: String {
        engineDirectory.appendingPathComponent("dsh/node_modules/@deepseek-ai/dsh/lib/bin.js").path
    }

    private var dshPatchPath: String {
        engineDirectory.appendingPathComponent("dsh/dsh-web.patch.yml").path
    }

    private func checkInitialStatus() {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: nodeBinaryPath) && fm.fileExists(atPath: dshEntryPath) {
            currentPhase = .installed
        } else {
            currentPhase = .notInstalled
        }
    }

    public func status() -> [String: Any?] {
        return stateQueue.sync {
            return [
                "phase": currentPhase.rawValue,
                "baseUrl": baseUrl,
                "token": token,
                "abi": "arm64",
                "bundledVersion": "1.0.0",
                "installedVersion": currentPhase == .notInstalled ? nil : "1.0.0",
                "dshVersion": "0.2.1-rc.4",
                "nodeVersion": "v22.19.0",
                "error": lastError,
                "mode": "normal",
                "safeState": "off",
                "strikes": 0,
                "autoSafe": false,
                "directEngineEnabled": true,
                "directEngineAvailable": true,
                "directEngineActive": true
            ]
        }
    }

    public func install(dropKept: Bool = false, completion: @escaping (Error?) -> Void) {
        stateQueue.sync {
            currentPhase = .installing
            emitStatus()
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let fm = FileManager.default
                let bundleEngine = Bundle.main.bundleURL.appendingPathComponent("engine")

                // 发送安装进度
                self.emitProgress(step: "prepare", done: 10, total: 100)

                if fm.fileExists(atPath: self.engineDirectory.path) {
                    try? fm.removeItem(at: self.engineDirectory)
                }

                self.emitProgress(step: "copy_engine", done: 40, total: 100)

                // 从 App Bundle 完整复制 engine
                if fm.fileExists(atPath: bundleEngine.path) {
                    try fm.copyItem(at: bundleEngine, to: self.engineDirectory)
                } else {
                    let archive = Bundle.main.bundleURL.appendingPathComponent("engine.tar.gz")
                    if fm.fileExists(atPath: archive.path) {
                        try fm.createDirectory(at: self.engineDirectory, withIntermediateDirectories: true)
                        let tarCmd = "/usr/bin/tar"
                        if fm.fileExists(atPath: tarCmd) {
                            let task = Process()
                            task.executableURL = URL(fileURLWithPath: tarCmd)
                            task.arguments = ["-xzf", archive.path, "-C", self.engineDirectory.path]
                            try task.run()
                            task.waitUntilExit()
                        }
                    }
                }

                self.emitProgress(step: "set_permissions", done: 80, total: 100)

                // 确保 node 二进制可执行
                if fm.fileExists(atPath: self.nodeBinaryPath) {
                    chmod(self.nodeBinaryPath, 0o755)
                }

                // 创建 DSH 主目录和临时目录
                let dshHome = self.documentsDirectory.appendingPathComponent(".dsh")
                try fm.createDirectory(at: dshHome, withIntermediateDirectories: true)

                let tmpDir = self.documentsDirectory.appendingPathComponent("tmp")
                try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)

                self.emitProgress(step: "done", done: 100, total: 100)

                self.stateQueue.sync {
                    self.currentPhase = .installed
                    self.lastError = nil
                    self.emitStatus()
                }

                completion(nil)

                // 安装完成后自动拉起
                self.start()

            } catch {
                self.stateQueue.sync {
                    self.currentPhase = .error
                    self.lastError = "install failed: \(error.localizedDescription)"
                    self.emitStatus()
                }
                completion(error)
            }
        }
    }

    public func start(env: [String: String] = [:], port: Int = 3080) {
        stateQueue.sync {
            if currentPhase == .running || currentPhase == .starting {
                return
            }
            currentPhase = .starting
            baseUrl = nil
            token = nil
            lastError = nil
            runningPort = port
            emitStatus()
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.spawnDshProcess(customEnv: env, port: port)
        }
    }

    private func spawnDshProcess(customEnv: [String: String], port: Int) {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: nodeBinaryPath) else {
            stateQueue.sync {
                self.currentPhase = .error
                self.lastError = "node binary not executable at \(self.nodeBinaryPath)"
                self.emitStatus()
            }
            return
        }

        // 管道设置
        var pipeOut = [Int32](repeating: 0, count: 2)
        var pipeErr = [Int32](repeating: 0, count: 2)
        pipe(&pipeOut)
        pipe(&pipeErr)

        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, pipeOut[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, pipeErr[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, pipeOut[0])
        posix_spawn_file_actions_addclose(&fileActions, pipeErr[0])

        // 构造命令行参数
        // node <bin.js> web --patch <patch.yml> --host 127.0.0.1 --port <port> --no-open
        var argv: [String] = [
            "node",
            dshEntryPath,
            "web",
            "--host", "127.0.0.1",
            "--port", "\(port)",
            "--no-open"
        ]

        if fm.fileExists(atPath: dshPatchPath) {
            argv.append(contentsOf: ["--patch", dshPatchPath])
        }

        let cArgs = argv.map { strdup($0) } + [nil]

        // 构造环境变量
        let homePath = documentsDirectory.path
        let dshHome = documentsDirectory.appendingPathComponent(".dsh").path
        let tmpDir = documentsDirectory.appendingPathComponent("tmp").path

        var envMap: [String: String] = [
            "HOME": homePath,
            "DSH_HOME": dshHome,
            "TMPDIR": tmpDir,
            "PATH": "\(engineDirectory.path)/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "NODE_ENV": "production",
            "PORT": "\(port)",
            "UV_USE_IO_URING": "0",
            "NARB_DISABLE_NATIVE_CACHE": "1",
            "NODE_OPTIONS": "--dns-result-order=ipv4first"
        ]

        for (k, v) in customEnv {
            envMap[k] = v
        }

        let cEnv = envMap.map { strdup("\($0)=\($1)") } + [nil]

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, nodeBinaryPath, &fileActions, nil, cArgs, cEnv)

        // 释放 C 字符串
        for p in cArgs where p != nil { free(p) }
        for p in cEnv where p != nil { free(p) }
        posix_spawn_file_actions_destroy(&fileActions)

        close(pipeOut[1])
        close(pipeErr[1])

        if spawnResult != 0 {
            close(pipeOut[0])
            close(pipeErr[0])
            stateQueue.sync {
                self.currentPhase = .error
                self.lastError = "posix_spawn failed with error: \(spawnResult)"
                self.emitStatus()
            }
            return
        }

        stateQueue.sync {
            self.processPid = pid
            self.appendLog("[dsh-app] DSH spawned with pid \(pid)", stream: "system")
        }

        // 异步读取 stdout
        readPipe(fd: pipeOut[0], stream: "stdout", port: port)
        // 异步读取 stderr
        readPipe(fd: pipeErr[0], stream: "stderr", port: port)

        // 监听进程退出
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            self.stateQueue.sync {
                if self.processPid == pid {
                    self.processPid = 0
                    self.baseUrl = nil
                    self.token = nil
                    self.currentPhase = .installed
                    self.appendLog("[dsh-app] DSH exited with code \(status)", stream: "system")
                    self.emitStatus()
                }
            }
        }
    }

    private func readPipe(fd: Int32, stream: String, port: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var buffer = Data()

            while true {
                let data = file.availableData
                if data.isEmpty { break }
                buffer.append(data)

                while let range = buffer.range(of: Data([0x0A])) { // \n
                    let lineData = buffer.subdata(in: 0..<range.lowerBound)
                    buffer.removeSubrange(0..<range.upperBound)
                    if let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                        self.handleLogLine(line, stream: stream, port: port)
                    }
                }
            }
        }
    }

    private func handleLogLine(_ line: String, stream: String, port: Int) {
        appendLog(line, stream: stream)

        // 检测 token URL: http://127.0.0.1:port/?token=...
        let pattern = #"https?://[^\s'"]*[?&#]token=([A-Za-z0-9._~%-]+)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
            if let tokenRange = Range(match.range(at: 1), in: line) {
                let extractedToken = String(line[tokenRange])
                verifyAndMarkReady(token: extractedToken, port: port)
            }
        }
    }

    private func verifyAndMarkReady(token: String, port: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let deadline = Date().addingTimeInterval(30)
            var connected = false

            while Date() < deadline && !connected {
                if self.canConnect(port: port) {
                    connected = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.25)
            }

            if connected {
                self.stateQueue.sync {
                    self.baseUrl = "http://127.0.0.1:\(port)"
                    self.token = token
                    self.currentPhase = .running
                    self.appendLog("[dsh-app] DSH ready at \(self.baseUrl!)", stream: "system")
                    self.emitStatus()
                }
            } else {
                self.stateQueue.sync {
                    self.currentPhase = .error
                    self.lastError = "Port \(port) failed to accept connections"
                    self.emitStatus()
                }
            }
        }
    }

    private func canConnect(port: Int) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let sock = socket(AF_INET, SOCK_STREAM, 0)
        if sock < 0 { return false }
        defer { close(sock) }

        var flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if result == 0 { return true }
        if errno == EINPROGRESS {
            var fds = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
            if poll(&fds, 1, 200) > 0 {
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &len)
                return err == 0
            }
        }
        return false
    }

    public func stop() {
        stateQueue.sync {
            guard processPid > 0 else { return }
            currentPhase = .stopping
            emitStatus()
            kill(processPid, SIGTERM)
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            self.stateQueue.sync {
                if self.processPid > 0 {
                    kill(self.processPid, SIGKILL)
                    self.processPid = 0
                    self.currentPhase = .installed
                    self.baseUrl = nil
                    self.token = nil
                    self.emitStatus()
                }
            }
        }
    }

    public func reset(completion: @escaping (Error?) -> Void) {
        stop()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            try? fm.removeItem(at: self.engineDirectory)
            try? fm.removeItem(at: self.documentsDirectory.appendingPathComponent(".dsh"))
            self.stateQueue.sync {
                self.currentPhase = .notInstalled
                self.baseUrl = nil
                self.token = nil
                self.lastError = nil
                self.emitStatus()
            }
            completion(nil)
        }
    }

    private func appendLog(_ line: String, stream: String) {
        logQueue.async { [weak self] in
            guard let self = self else { return }
            self.seqCounter += 1
            let entry = LogEntry(seq: self.seqCounter, line: line, stream: stream)
            self.logEntries.append(entry)
            if self.logEntries.count > 2000 {
                self.logEntries.removeFirst(self.logEntries.count - 2000)
            }
            self.emitLog(entry)
        }
    }

    public func recentLogs(lines: Int) -> [String] {
        return logQueue.sync {
            let count = max(0, min(lines, logEntries.count))
            return logEntries.suffix(count).map { $0.line }
        }
    }

    public func logSnapshot(lines: Int) -> [String: Any] {
        return logQueue.sync {
            let count = max(0, min(lines, logEntries.count))
            let slice = logEntries.suffix(count)
            return [
                "entries": slice.map { $0.toMap() },
                "throughSeq": seqCounter
            ]
        }
    }

    // 事件流广播
    private func emitStatus() {
        let currentStatus = self.status()
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?([
                "type": "status",
                "status": currentStatus
            ])
        }
    }

    private func emitProgress(step: String, done: Int, total: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?([
                "type": "progress",
                "step": step,
                "done": done,
                "total": total
            ])
        }
    }

    private func emitLog(_ entry: LogEntry) {
        DispatchQueue.main.async { [weak self] in
            self?.eventSink?([
                "type": "logs",
                "entries": [entry.toMap()]
            ])
        }
    }
}

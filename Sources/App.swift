import AppKit
import CoreGraphics
import SystemConfiguration
import IOKit
import IOKit.pwr_mgt
import Darwin

enum AgentControl {
    static let check = Notification.Name("local.hbut.autologin.check")
    static let reload = Notification.Name("local.hbut.autologin.reload")
    static func isRunning() -> Bool {
        let task = Process(), output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["print", "gui/\(getuid())/" + Paths.label]
        task.standardOutput = output; task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return false }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()
        return task.terminationStatus == 0 && text.contains("state = running")
    }
    @discardableResult static func launchctl(_ arguments: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try task.run(); task.waitUntilExit(); return task.terminationStatus
    }
    static func isLoaded() -> Bool {
        (try? launchctl(["print", "gui/\(getuid())/" + Paths.label])) == 0
    }
    static func enable() throws {
        try Paths.prepare()
        try FileManager.default.createDirectory(at: Paths.agent.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": Paths.label, "ProgramArguments": [Paths.executable.path, "--agent"],
            "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 30,
            "LimitLoadToSessionType": "Aqua", "ProcessType": "Background", "LowPriorityIO": true,
            "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: Paths.agent, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.agent.path)
        let domain = "gui/\(getuid())"
        guard try launchctl(["enable", domain + "/" + Paths.label]) == 0 else {
            throw CampusError.message("设置已保存，但系统未允许启用后台任务。")
        }
        // Saving settings must not tear down a healthy listener. A bootout followed
        // immediately by bootstrap can race launchd's asynchronous removal.
        if !isLoaded() {
            let result = try launchctl(["bootstrap", domain, Paths.agent.path])
            guard result == 0 || isLoaded() else {
                throw CampusError.message("设置已保存，但系统未能注册后台任务；请稍后重新启用。")
            }
        }
        if !isRunning() { _ = try launchctl(["kickstart", domain + "/" + Paths.label]) }
        for _ in 0..<20 {
            if isRunning() {
                DistributedNotificationCenter.default().postNotificationName(reload, object: nil, userInfo: nil, deliverImmediately: true)
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw CampusError.message("设置已保存，但后台尚未启动；请稍后重新启用。")
    }
    static func disable() {
        let domain = "gui/\(getuid())"
        _ = try? launchctl(["disable", domain + "/" + Paths.label])
        _ = try? launchctl(["bootout", domain + "/" + Paths.label])
    }
}

final class EventAgent {
    let observeOnly: Bool
    private var store: SCDynamicStore?
    private var observers: [NSObjectProtocol] = []
    private var distributed: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?
    private var active: Cancellation?
    private var generation = 0
    private var sleeping = false
    private var powerConnection: io_connect_t = 0
    private var powerNotificationPort: IONotificationPortRef?
    private var powerNotifier: io_object_t = 0
    private var pendingTrigger = "程序启动"
    private var lastIdentity: String?
    private var lastStarted: TimeInterval = -.infinity
    private var lastNetwork = NetworkSnapshot.current()?.identity

    init(observeOnly: Bool) { self.observeOnly = observeOnly }
    deinit {
        if powerConnection != 0 {
            IODeregisterForSystemPower(&powerNotifier)
            if let powerNotificationPort { IONotificationPortDestroy(powerNotificationPort) }
            IOServiceClose(powerConnection)
        }
    }
    private func displaySleepStates() -> [Bool] {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map { CGDisplayIsAsleep($0) != 0 }
    }
    private func systemWillSleep() {
        sleeping = true
        lastStarted = -.infinity
        cancel()
    }
    private func systemDidWake() {
        sleeping = false
        schedule(trigger: "系统唤醒", recheckDisplay: true)
    }
    func start() {
        powerConnection = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &powerNotificationPort, { info, _, message, argument in
            guard let info else { return }
            let agent = Unmanaged<EventAgent>.fromOpaque(info).takeUnretainedValue()
            switch message {
            // IOMessage.h's nested C macros are not imported into Swift.
            case 0xe0000270: // kIOMessageCanSystemSleep
                IOAllowPowerChange(agent.powerConnection, Int(bitPattern: argument))
            case 0xe0000280: // kIOMessageSystemWillSleep
                // Acknowledge immediately; never hold up sleep for our network work.
                IOAllowPowerChange(agent.powerConnection, Int(bitPattern: argument))
                agent.systemWillSleep()
            case 0xe0000300: // kIOMessageSystemHasPoweredOn
                agent.systemDidWake()
            default: break
            }
        }, &powerNotifier)
        if let powerNotificationPort { IONotificationPortSetDispatchQueue(powerNotificationPort, .main) }
        try? Paths.write(["pid": Int(getpid()), "powerNotificationsRegistered": powerConnection != 0 ? 1 : 0],
                         to: Paths.directory.appendingPathComponent("listener.json"))
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notice in
                guard let self else { return }
                if notice.name == NSWorkspace.willSleepNotification {
                    if self.powerConnection == 0 { self.systemWillSleep() }
                } else {
                    self.cancel()
                }
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemDidWake()
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = false
            self?.schedule(trigger: "屏幕点亮", recheckDisplay: true)
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.schedule(trigger: "用户会话恢复", recheckDisplay: true)
        })
        let distributedCenter = DistributedNotificationCenter.default()
        distributed.append(distributedCenter.addObserver(forName: AgentControl.check, object: nil, queue: .main) { [weak self] _ in self?.schedule(manual: true, trigger: "手动检查") })
        distributed.append(distributedCenter.addObserver(forName: AgentControl.reload, object: nil, queue: .main) { [weak self] _ in
            self?.cancel(); self?.lastStarted = -.infinity; self?.schedule(trigger: "设置更新")
        })
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        store = SCDynamicStoreCreate(nil, "HBUT event listener" as CFString, { _, _, info in
            guard let info else { return }
            Unmanaged<EventAgent>.fromOpaque(info).takeUnretainedValue().networkChanged()
        }, &context)
        if let store {
            let keys = ["State:/Network/Global/IPv4"] as CFArray
            let patterns = ["State:/Network/Interface/[^/]+/AirPort", "State:/Network/Interface/[^/]+/IPv4"] as CFArray
            SCDynamicStoreSetNotificationKeys(store, keys, patterns)
            SCDynamicStoreSetDispatchQueue(store, .main)
        }
        schedule(trigger: "程序启动")
    }
    private func networkChanged() {
        let identity = NetworkSnapshot.current()?.identity
        guard identity != lastNetwork else { return }
        lastNetwork = identity
        cancel()
        schedule(trigger: "Wi-Fi 连接变化")
    }
    private func cancel() {
        generation += 1
        pending?.cancel(); pending = nil
        active?.cancel(); active = nil
    }
    func schedule(manual: Bool = false, trigger: String, recheckDisplay: Bool = false) {
        guard !observeOnly, !sleeping, active == nil else { return }
        // A full wake may arrive before the external display becomes ready.
        // Re-evaluate the real displays after the one-shot delay, not a cached flag.
        if !recheckDisplay && !WakePolicy.mayRun(systemSleeping: sleeping, displaySleepStates: displaySleepStates()) { return }
        if pending == nil || trigger == "系统唤醒" || trigger == "手动检查" || pendingTrigger != "系统唤醒" {
            pendingTrigger = trigger
        }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.begin(manual: manual, trigger: self.pendingTrigger)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (manual ? 0 : 3), execute: work)
    }
    private func begin(manual: Bool, trigger: String) {
        pending = nil
        guard WakePolicy.mayRun(systemSleeping: sleeping, displaySleepStates: displaySleepStates()), active == nil,
              let configuration = Configuration.load(), configuration.enabled,
              let network = NetworkSnapshot.current(), network.matches(configuration) else { return }
        if !manual && Status.load()?.blockedRevision == configuration.revision { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard manual || lastIdentity != network.identity || now - lastStarted >= 45 else { return }
        lastIdentity = network.identity; lastStarted = now
        let cancellation = Cancellation()
        active = cancellation
        generation += 1
        let currentGeneration = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let status = autoreleasepool {
                var value = Authenticator(configuration: configuration, network: network, cancellation: cancellation).run()
                value.trigger = trigger
                return value
            }
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration else { return }
                self.active = nil
                if status.code != "cancelled" && status.code != "busy" { status.save() }
                if status.code == "rejected" {
                    let options = NSWorkspace.OpenConfiguration()
                    options.activates = false
                    NSWorkspace.shared.openApplication(at: Paths.application, configuration: options, completionHandler: nil)
                }
                // No periodic work is scheduled here. Await a new OS event.
            }
        }
    }
}

final class SettingsController: NSObject, NSWindowDelegate {
    private var window: NSWindow!
    private let username = NSTextField()
    private let password = NSSecureTextField()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let runningLabel = NSTextField(labelWithString: "")
    private let lastCheckLabel = NSTextField(labelWithString: "")
    private let lastResultLabel = NSTextField(wrappingLabelWithString: "")
    private var statusObserver: NSObjectProtocol?
    private let saveButton = NSButton(title: "保存并启用", target: nil, action: nil)
    private var busy = false

    func show() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "校园网自动登录"
        window.delegate = self
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        window.contentView = content
        func label(_ text: String, _ y: CGFloat, size: CGFloat = 13, height: CGFloat = 24) {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = .systemFont(ofSize: size)
            field.frame = NSRect(x: 28, y: y, width: 544, height: height)
            content.addSubview(field)
        }
        label("湖北工业大学 · 校园网自动登录", 445, size: 20, height: 30)
        label("唤醒或 Wi-Fi 连接变化后检查，平时不定时联网。", 410)
        runningLabel.frame = NSRect(x: 28, y: 380, width: 544, height: 24)
        runningLabel.font = .systemFont(ofSize: 13, weight: .medium)
        lastCheckLabel.frame = NSRect(x: 28, y: 350, width: 544, height: 24)
        lastCheckLabel.font = .systemFont(ofSize: 12)
        lastResultLabel.frame = NSRect(x: 28, y: 310, width: 544, height: 36)
        lastResultLabel.font = .systemFont(ofSize: 13)
        for field in [runningLabel, lastCheckLabel, lastResultLabel] { content.addSubview(field) }
        label("校园网账号（学号）", 278)
        username.frame = NSRect(x: 28, y: 246, width: 544, height: 28)
        username.placeholderString = "输入你平时登录校园网的账号"
        content.addSubview(username)
        label("校园网密码", 210)
        password.frame = NSRect(x: 28, y: 178, width: 544, height: 28)
        password.placeholderString = "仅保存在本机钥匙串，不写入配置或日志"
        content.addSubview(password)
        label("服务：校园网（default）", 140)
        statusLabel.frame = NSRect(x: 28, y: 74, width: 544, height: 60)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = Configuration.load() == nil ? "请在已连接校园 Wi-Fi 时保存设置。" : "账号密码已保存在本机钥匙串；无需修改时可留空。可关闭窗口继续后台监听。"
        content.addSubview(statusLabel)
        let buttons: [(NSButton, Selector, CGFloat, CGFloat)] = [
            (saveButton, #selector(save), 28, 125),
            (NSButton(title: "立即检查", target: nil, action: nil), #selector(check), 163, 100),
            (NSButton(title: "刷新状态", target: nil, action: nil), #selector(refresh), 273, 100),
            (NSButton(title: "停用", target: nil, action: nil), #selector(disable), 383, 70),
            (NSButton(title: "卸载…", target: nil, action: nil), #selector(uninstall), 463, 100)
        ]
        for (button, action, x, width) in buttons {
            button.frame = NSRect(x: x, y: 24, width: width, height: 34)
            button.bezelStyle = .rounded; button.target = self; button.action = action
            content.addSubview(button)
        }
        saveButton.keyEquivalent = "\r"
        refresh()
        statusObserver = DistributedNotificationCenter.default().addObserver(forName: Status.changed, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
    private func showMessage(_ text: String) { statusLabel.stringValue = text }
    @objc private func refresh() {
        let enabled = Configuration.load()?.enabled == true
        let running = AgentControl.isRunning()
        let paused = Status.load()?.blockedRevision == Configuration.load()?.revision && Status.load()?.blockedRevision != nil
        runningLabel.stringValue = !enabled ? "自动登录：已停用" : (running ? "自动登录：已启用 · 后台运行中" : "自动登录：已启用 · 后台未运行，请重新保存启用")
        if enabled && running && paused { runningLabel.stringValue += " · 认证已暂停" }
        runningLabel.textColor = enabled && running ? (paused ? .systemOrange : .systemGreen) : .secondaryLabelColor
        if let status = Status.load() {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let time = ISO8601DateFormatter().date(from: status.updated).map(formatter.string(from:)) ?? status.updated
            lastCheckLabel.stringValue = "最近检查：" + time + (status.trigger.map { " · " + $0 } ?? "")
            lastResultLabel.stringValue = "最近结果：" + status.text
        } else {
            lastCheckLabel.stringValue = "最近检查：暂无记录"
            lastResultLabel.stringValue = "首次启用后会进行一次检查。"
        }
    }

    @objc private func save() {
        guard !busy else { return }
        let account = username.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = password.stringValue
        let useExisting = account.isEmpty && secret.isEmpty && Configuration.load() != nil
        guard useExisting || (!account.isEmpty && !secret.isEmpty) else { showMessage("请填写账号和密码；保留两项为空可继续使用已保存的凭据。"); return }
        guard let network = NetworkSnapshot.current(), !network.profile.isEmpty else {
            showMessage("尚未获取 Wi-Fi 标识。请连接校园 Wi-Fi 后重试。"); return
        }
        // Verify the portal on this Wi-Fi before registering its network profile.
        busy = true; saveButton.isEnabled = false
        showMessage("正在确认校园认证服务器…")
        DispatchQueue.global(qos: .utility).async {
            let result: Result<Void, Error> = Result {
                let http = DirectHTTP(Cancellation(), seconds: 7)
                let infoURL = URL(string: Portal.origin + "/eportal/InterFace.do?method=pageInfo")!
                let info = try http.request(infoURL, body: "queryString=").json()
                guard info["passwordEncrypt"] != nil, info["publicKeyModulus"] != nil else {
                    throw CampusError.message("未识别到学校认证服务器，请确认当前连接的是校园 Wi-Fi。")
                }
                guard NetworkSnapshot.current()?.identity == network.identity else { throw CampusError.message("Wi-Fi 连接发生变化，请重新保存。") }
                let credentials = useExisting ? try Keychain.load(interactive: true) : Credentials(username: account, password: secret)
                try Keychain.save(credentials)
                try Paths.write(Configuration(networkProfile: network.profile), to: Paths.configuration)
                try AgentControl.enable()
            }
            DispatchQueue.main.async {
                self.busy = false; self.saveButton.isEnabled = true
                switch result {
                case .success:
                    self.password.stringValue = ""
                    self.showMessage("已启用。开盖或重新连接此 Wi-Fi 后自动检查；现在可关闭窗口。")
                    self.refresh()
                case .failure(let error): self.showMessage(error.localizedDescription); self.refresh()
                }
            }
        }
    }
    @objc private func check() {
        guard !busy else { return }
        guard let configuration = Configuration.load(), configuration.enabled else { showMessage("请先保存账号并启用自动登录。"); return }
        guard AgentControl.isRunning() else { refresh(); showMessage("后台未运行，请点击保存并启用；可继续使用已有凭据。"); return }
        DistributedNotificationCenter.default().postNotificationName(AgentControl.check, object: nil, userInfo: nil, deliverImmediately: true)
        showMessage("正在检查，结果返回后上方时间和结果会自动更新。")
    }
    @objc private func disable() {
        AgentControl.disable()
        if var configuration = Configuration.load() { configuration.enabled = false; try? Paths.write(configuration, to: Paths.configuration) }
        showMessage("已停用，监听程序已退出。重新填写账号密码并保存即可启用。")
        refresh()
    }
    @objc private func uninstall() {
        guard !busy else { return }
        let alert = NSAlert()
        alert.messageText = "卸载校园网自动登录？"
        alert.informativeText = "停止监听，移除本工具的配置和钥匙串凭据，并将应用移到废纸篓。"
        alert.addButton(withTitle: "卸载"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        AgentControl.disable()
        Keychain.delete()
        try? FileManager.default.removeItem(at: Paths.agent)
        try? FileManager.default.trashItem(at: Paths.directory, resultingItemURL: nil)
        try? FileManager.default.trashItem(at: Paths.application, resultingItemURL: nil)
        NSApp.terminate(nil)
    }
}

@main struct CampusAutoLogin {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let arguments = CommandLine.arguments
        if arguments.contains("--check-keychain") {
            do {
                _ = try Keychain.load()
                print("本工具可读取已保存的校园网凭据。")
            } catch {
                print("本工具尚未获准读取已有凭据，请打开设置重新保存或允许钥匙串访问。")
                exit(2)
            }
            return
        }
        if arguments.contains("--diagnose") {
            let network = NetworkSnapshot.current()
            let http = DirectHTTP(Cancellation(), seconds: 5)
            let online = (try? http.request(Portal.secureProbe, timeout: 3).appleSuccess) == true
            let report: [String: Any] = ["wifiReady": network != nil, "networkIdentifierAvailable": !(network?.profile.isEmpty ?? true),
                                        "directInternetWorks": online, "configured": Configuration.load() != nil,
                                        "periodicChecks": false, "proxyChanges": false]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            return
        }
        if arguments.contains("--once") {
            guard let configuration = Configuration.load(), configuration.enabled, let network = NetworkSnapshot.current() else {
                print("尚未配置或 Wi-Fi 未就绪。"); exit(2)
            }
            if Status.load()?.blockedRevision == configuration.revision {
                print("账号认证已暂停，请重新保存正确凭据。"); exit(3)
            }
            let status = Authenticator(configuration: configuration, network: network, cancellation: Cancellation()).run()
            status.save(); print(status.text)
            exit(["online", "connected"].contains(status.code) ? 0 : 1)
        }
        if arguments.contains("--agent") {
            let agent = EventAgent(observeOnly: arguments.contains("--observe-only"))
            agent.start()
            withExtendedLifetime(agent) { RunLoop.main.run() }
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let settings = SettingsController()
        settings.show()
        withExtendedLifetime(settings) { app.run() }
    }
}

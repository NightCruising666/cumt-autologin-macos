// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Security
import LocalAuthentication

let bundleID = "local.cumt.autologin.menu"
let launchLabel = "local.cumt.autologin.menu.startup"
let keychainService = "CUMT-AutoLogin-Nanhu-Menu"
let messageName = Notification.Name("local.cumt.autologin.menu.action")

struct Preferences: Codable {
    var username = ""
    var operatorName = "校园网"
    var autoLogin = true
    var interval: Double = 60
}

enum PasswordStore {
    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService, kSecAttrAccount as String: account]
    }
    static func read(_ account: String, interactive: Bool) throws -> String {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive {
            let context = LAContext(); context.interactionNotAllowed = true
            q[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            throw AppError.message("无法读取校园网密码，请在详细设置中保存密码或解锁钥匙串（\(status)）。")
        }
        return secret
    }
    static func save(_ account: String, password: String) throws {
        let q = query(account)
        let data = Data(password.utf8)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "中国矿业大学校园网"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppError.message("保存钥匙串密码失败（\(status)）。") }
    }
    static func remove(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
    static func removeAll() throws {
        for service in [keychainService, "CUMT-AutoLogin-Nanhu"] {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            let status = SecItemDelete(q as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AppError.message("本工具的钥匙串密码删除失败（\(status)），请解锁钥匙串后重试。")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    var preferences = Preferences()
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    let stateItem = NSMenuItem(title: "校园网：尚未检测", action: nil, keyEquivalent: "")
    let detailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let timeItem = NSMenuItem(title: "尚未检测", action: nil, keyEquivalent: "")
    var launchItem: NSMenuItem!
    var automaticItem: NSMenuItem!
    var actionItems = [NSMenuItem]()
    var window: NSWindow?
    var usernameField = NSTextField()
    var secureField = NSSecureTextField()
    var visibleField = NSTextField()
    var revealButton = NSButton()
    var operatorPopup = NSPopUpButton()
    var intervalPopup = NSPopUpButton()
    var autoCheckbox = NSButton()
    var startupCheckbox = NSButton()
    var feedbackLabel = NSTextField(wrappingLabelWithString: "")
    var timer: Timer?
    var busy = false
    var lastState = "unknown"
    var retryAfter = Date.distantPast
    var quitting = false
    let preview = CommandLine.arguments.contains("--preview")
    lazy var stateDirectory: URL = {
        if preview { return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("CUMT-Menu-Preview") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CUMT-AutoLogin")
    }()
    var configurationURL: URL { stateDirectory.appendingPathComponent("menu-config.json") }
    var startupURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(launchLabel).plist") }
    var startupEnabled: Bool { !preview && FileManager.default.fileExists(atPath: startupURL.path) }
    var requestedAction: String {
        for action in ["settings", "check", "login", "status", "startup-on", "startup-off", "uninstall"] {
            if CommandLine.arguments.contains("--" + action) { return action }
        }
        return "activate"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !preview, NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            DistributedNotificationCenter.default().postNotificationName(messageName, object: requestedAction, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        if !preview, let data = try? Data(contentsOf: configurationURL), let loaded = try? JSONDecoder().decode(Preferences.self, from: data) {
            preferences = loaded
            if ![30.0, 60.0, 120.0, 300.0].contains(preferences.interval) { preferences.interval = 60 }
        }
        if preview { preferences.username = "02210000"; preferences.operatorName = "中国移动" }
        createMenu()
        let appMenu = NSMenu()
        let parent = NSMenuItem(); let submenu = NSMenu()
        let quitItem = NSMenuItem(title: "退出校园网助手", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self; submenu.addItem(quitItem); parent.submenu = submenu
        appMenu.addItem(parent); NSApp.mainMenu = appMenu
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(receiveAction(_:)), name: messageName, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        refreshTimer()
        if preferences.username.isEmpty { showSettings(nil) }
        if requestedAction == "activate" { inspect(manual: false) } else { handleAction(requestedAction) }
        if ["settings", "startup-on", "startup-off"].contains(requestedAction) { inspect(manual: false) }
    }

    @objc func receiveAction(_ note: Notification) {
        handleAction(note.object as? String ?? "activate")
    }
    func handleAction(_ action: String) {
        switch action {
        case "settings": showSettings(nil)
        case "login": manualLogin()
        case "check", "status": inspect(manual: true)
        case "startup-on", "startup-off":
            do { try setStartup(action == "startup-on"); syncSwitches() }
            catch { alert((error as? AppError)?.description ?? "开机自启设置失败。") }
        case "uninstall": uninstallApplication()
        default: break
        }
    }
    @objc func uninstallApplication() {
        let dialog = NSAlert(); dialog.messageText = "卸载校园网助手？"
        dialog.informativeText = "将清理已保存的账号密码、设置和日志，关闭开机自启，并将应用移入废纸篓。\n\n账号密码和设置删除后无法恢复。"
        dialog.addButton(withTitle: "取消"); dialog.addButton(withTitle: "卸载")
        NSApp.activate(ignoringOtherApps: true)
        guard dialog.runModal() == .alertSecondButtonReturn else { return }
        guard !preview else { alert("预览模式不会卸载真实应用。"); return }
        if busy { alert("请等待当前检测结束后再卸载。"); return }
        timer?.invalidate(); preferences.autoLogin = false; syncSwitches()
        do {
            try PasswordStore.removeAll()
            let cleanup = AppCleanup()
            // Stop preference caching from rewriting removed preferences later.
            if let keys = CFPreferencesCopyKeyList(bundleID as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] {
                for key in keys { CFPreferencesSetValue(key as CFString, nil, bundleID as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) }
                CFPreferencesSynchronize(bundleID as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            }
            var failures = cleanup.removeData()
            if failures.isEmpty {
                failures += cleanup.trashInstalledApplications(current: Bundle.main.bundleURL) { url in
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
            }
            if failures.isEmpty {
                alert("卸载完成，程序即将退出。")
            } else {
                alert("部分项目未能清理：\n\n" + failures.joined(separator: "\n") + "\n\n请重新打开应用后重试。")
            }
            // Do this last: bootout can terminate this process when launchd
            // started it. All cleanup and feedback must finish first.
            for label in cleanup.launchLabels {
                let stop = Process(); stop.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                stop.arguments = ["bootout", "gui/\(getuid())/\(label)"]
                stop.standardOutput = FileHandle.nullDevice; stop.standardError = FileHandle.nullDevice
                try? stop.run()
            }
            quit()
        } catch { alert((error as? AppError)?.description ?? "卸载未完成，请检查文件权限。") }
    }
    @objc func didWake() { retryAfter = .distantPast; inspect(manual: false) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        secureField.stringValue = ""; visibleField.stringValue = ""
        revealButton.state = .off; secureField.isHidden = false; visibleField.isHidden = true
        return true
    }

    func add(_ title: String, _ action: Selector, tracked: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; menu.addItem(item)
        if tracked { actionItems.append(item) }
        return item
    }
    func createMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "wifi", accessibilityDescription: "校园网")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "中国矿业大学校园网"
        menu.autoenablesItems = false; menu.delegate = self
        for item in [stateItem, detailItem, timeItem] { item.isEnabled = false; menu.addItem(item) }
        menu.addItem(.separator())
        _ = add("打开校园网登录页", #selector(openPortal))
        _ = add("立即检测连接状态", #selector(manualCheck), tracked: true)
        _ = add("立即登录", #selector(manualLogin), tracked: true)
        _ = add("立即注销", #selector(manualLogout), tracked: true)
        menu.addItem(.separator())
        launchItem = add("开机自启", #selector(toggleStartup))
        automaticItem = add("自动登录", #selector(toggleAutomatic))
        _ = add("详细设置…", #selector(showSettings(_:)))
        _ = add("查看日志", #selector(openLogs))
        menu.addItem(.separator())
        _ = add("清理数据并卸载…", #selector(uninstallApplication), tracked: true)
        _ = add("退出校园网助手", #selector(quit))
        statusItem.menu = menu
        syncSwitches()
    }
    func menuWillOpen(_ menu: NSMenu) { syncSwitches() }
    func syncSwitches() {
        launchItem?.state = startupEnabled ? .on : .off
        automaticItem?.state = preferences.autoLogin ? .on : .off
        autoCheckbox.state = preferences.autoLogin ? .on : .off
        startupCheckbox.state = startupEnabled ? .on : .off
    }
    func refreshTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: preferences.interval, repeats: true) { [weak self] _ in self?.inspect(manual: false) }
    }
    func savePreferences() throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(preferences).write(to: configurationURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
    }
    func report(_ text: String) {
        guard !preview else { return }
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = stateDirectory.appendingPathComponent("menu.log")
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber, size.intValue > 524288 {
            let backup = stateDirectory.appendingPathComponent("menu.log.1")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
        }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)\n"
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        if let file = try? FileHandle(forWritingTo: url) { defer { try? file.close() }; _ = try? file.seekToEnd(); try? file.write(contentsOf: Data(line.utf8)) }
    }
    func setBusy(_ value: Bool) {
        busy = value
        for item in actionItems { item.isEnabled = !value }
        if value { stateItem.title = "校园网：正在处理…" }
    }
    func update(_ result: BackendResult) {
        lastState = result.state
        let names = ["online": "已联网", "offline": "未认证 / 未联网", "outside": "未连接校园网", "blocked": "路由被代理接管", "error": "检测失败", "unknown": "状态待确认"]
        stateItem.title = "校园网：" + (names[result.state] ?? "状态待确认")
        detailItem.title = result.message
        let format = DateFormatter(); format.dateFormat = "HH:mm:ss"
        timeItem.title = "最后检查：" + format.string(from: Date())
        statusItem.button?.image = NSImage(systemSymbolName: result.state == "online" ? "wifi" : "wifi.exclamationmark", accessibilityDescription: stateItem.title)
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = stateItem.title + " · " + result.message
        if let delay = result.retry_delay { retryAfter = Date().addingTimeInterval(delay) }
        feedbackLabel.stringValue = result.message
        report(result.message)
    }
    func execute(_ action: String, manual: Bool, completion: @escaping (BackendResult) -> Void) {
        guard !busy else { return }
        if preview {
            let result = BackendResult(state: action == "login" ? "online" : "offline", message: "界面预览：未发送真实校园网请求", retry_delay: nil)
            update(result); completion(result); return
        }
        let username = preferences.username, operatorName = preferences.operatorName
        var password = ""
        if action == "login" {
            do { password = try PasswordStore.read(username, interactive: manual) }
            catch { update(BackendResult(state: "error", message: (error as? AppError)?.description ?? "密码读取失败", retry_delay: 300)); return }
        }
        let secret = password
        setBusy(true)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let transport = NativeHTTP()
            let result = NativeBackend(transport: transport).dispatch(action, username: username, operatorName: operatorName, password: secret)
            transport.close()
            DispatchQueue.main.async { [weak self] in
                guard let self = self, !self.quitting else { return }
                self.setBusy(false); self.update(result); completion(result)
            }
        }
    }
    func inspect(manual: Bool) {
        execute("status", manual: manual) { [weak self] result in
            guard let self = self else { return }
            if !manual, result.state == "offline", self.preferences.autoLogin,
               !self.preferences.username.isEmpty, Date() >= self.retryAfter {
                self.execute("login", manual: false) { _ in }
            }
        }
    }
    @objc func manualCheck() { inspect(manual: true) }
    @objc func manualLogin() {
        if preferences.username.isEmpty { showSettings(nil); return }
        retryAfter = .distantPast
        execute("login", manual: true) { _ in }
    }
    @objc func manualLogout() {
        let previous = preferences.autoLogin
        preferences.autoLogin = false
        do { try savePreferences() } catch { preferences.autoLogin = previous; alert("无法保存自动登录开关，未执行注销。"); return }
        syncSwitches()
        execute("logout", manual: true) { _ in }
    }
    @objc func openPortal() { NSWorkspace.shared.open(URL(string: "http://10.2.5.251/")!) }
    @objc func openLogs() { NSWorkspace.shared.open(stateDirectory) }
    @objc func toggleAutomatic() {
        preferences.autoLogin.toggle()
        do { try savePreferences() } catch { preferences.autoLogin.toggle(); alert("无法保存设置。") }
        syncSwitches(); retryAfter = .distantPast
        if preferences.autoLogin { inspect(manual: false) }
    }

    func setStartup(_ enabled: Bool) throws {
        guard !preview else { throw AppError.message("预览模式不会修改开机自启。") }
        if !enabled {
            do { try FileManager.default.removeItem(at: startupURL) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError { }
            return
        }
        let apps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let installed = apps.appendingPathComponent("CUMT Auto Login.app")
        if Bundle.main.bundleURL.standardizedFileURL != installed.standardizedFileURL {
            let stage = apps.appendingPathComponent("CUMT Auto Login.new.app")
            try? FileManager.default.removeItem(at: stage)
            try FileManager.default.copyItem(at: Bundle.main.bundleURL, to: stage)
            // Only replace the directory owned by our bundle identifier.
            if FileManager.default.fileExists(atPath: installed.path) {
                guard Bundle(url: installed)?.bundleIdentifier == bundleID else { throw AppError.message("安装目录已有同名应用，请先检查 ~/Applications。") }
                try FileManager.default.removeItem(at: installed)
            }
            try FileManager.default.moveItem(at: stage, to: installed)
        }
        let executable = installed.appendingPathComponent("Contents/MacOS/CUMTMenu")
        let plist: [String: Any] = ["Label": launchLabel, "ProgramArguments": [executable.path], "RunAtLoad": true,
                                    "ProcessType": "Interactive", "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"]
        try FileManager.default.createDirectory(at: startupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: startupURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: startupURL.path)
        // launchd reads this at the next desktop login. Do not launch another copy now.
        // Retire the earlier CLI task so the automatic-login switch has one owner.
        let oldPlist = startupURL.deletingLastPathComponent().appendingPathComponent("local.cumt.autologin.plist")
        if FileManager.default.fileExists(atPath: oldPlist.path) {
            let stop = Process(); stop.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            stop.arguments = ["bootout", "gui/\(getuid())", oldPlist.path]
            stop.standardOutput = FileHandle.nullDevice; stop.standardError = FileHandle.nullDevice
            try? stop.run(); stop.waitUntilExit()
            try FileManager.default.removeItem(at: oldPlist)
        }
    }
    @objc func toggleStartup() {
        do { try setStartup(!startupEnabled); syncSwitches() }
        catch { alert((error as? AppError)?.description ?? "开机自启设置失败。") }
    }
    @objc func quit() { quitting = true; timer?.invalidate(); NSApp.terminate(nil) }
    @objc func previewMenu(_ sender: NSButton) {
        if let content = window?.contentView {
            menu.popUp(positioning: nil, at: NSPoint(x: 120, y: content.bounds.height - 100), in: content)
        }
    }
    func alert(_ message: String) {
        let alert = NSAlert(); alert.messageText = "校园网助手"; alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }

    func label(_ text: String, bold: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = bold ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 13)
        return field
    }
    func row(_ title: String, control: NSView) -> NSStackView {
        let caption = label(title); caption.widthAnchor.constraint(equalToConstant: 86).isActive = true
        let row = NSStackView(views: [caption, control]); row.orientation = .horizontal; row.spacing = 16; row.alignment = .centerY
        control.widthAnchor.constraint(equalToConstant: 300).isActive = true
        return row
    }
    func makeSettings() {
        let height: CGFloat = projectURL == nil ? 590 : (preview ? 660 : 620)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: height), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "校园网助手 · 详细设置"; window.isReleasedWhenClosed = false; window.delegate = self
        self.window = window
        let title = label("中国矿业大学校园网", bold: true); title.font = .boldSystemFont(ofSize: 23)
        let subtitle = label("南湖校区  ·  CUMT_Stu"); subtitle.textColor = .secondaryLabelColor
        usernameField.placeholderString = "学号或工号"
        secureField.placeholderString = "输入校园网密码"
        visibleField.placeholderString = "输入校园网密码"; visibleField.isHidden = true
        let passwordContainer = NSView()
        passwordContainer.heightAnchor.constraint(equalToConstant: 26).isActive = true
        for field in [secureField as NSTextField, visibleField] {
            field.translatesAutoresizingMaskIntoConstraints = false; passwordContainer.addSubview(field)
            NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: passwordContainer.leadingAnchor), field.trailingAnchor.constraint(equalTo: passwordContainer.trailingAnchor), field.centerYAnchor.constraint(equalTo: passwordContainer.centerYAnchor)])
        }
        revealButton = NSButton(checkboxWithTitle: "显示密码", target: self, action: #selector(togglePassword))
        operatorPopup.addItems(withTitles: ["校园网", "中国移动", "中国联通", "中国电信"])
        intervalPopup.addItems(withTitles: ["30 秒", "60 秒", "2 分钟", "5 分钟"])
        autoCheckbox = NSButton(checkboxWithTitle: "自动登录：检测到掉线时自动认证", target: nil, action: nil)
        startupCheckbox = NSButton(checkboxWithTitle: "开机自启：登录 Mac 后启动菜单栏助手", target: nil, action: nil)
        let hint = label("密码保存在本机钥匙串。修改设置时，密码留空会保留已保存的密码。")
        hint.textColor = .secondaryLabelColor
        feedbackLabel.textColor = .secondaryLabelColor
        let save = NSButton(title: "保存设置", target: self, action: #selector(saveSettings)); save.bezelStyle = .rounded; save.keyEquivalent = "\r"
        let login = NSButton(title: "保存并登录", target: self, action: #selector(saveAndLogin)); login.bezelStyle = .rounded
        let buttons = NSStackView(views: [save, login]); buttons.orientation = .horizontal; buttons.spacing = 12
        let root = NSStackView(views: [title, subtitle, row("账号", control: usernameField), row("密码", control: passwordContainer), revealButton,
                                     row("运营商", control: operatorPopup), row("检测间隔", control: intervalPopup), autoCheckbox, startupCheckbox, hint, feedbackLabel, buttons])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 17; root.translatesAutoresizingMaskIntoConstraints = false
        if preview {
            let showMenu = NSButton(title: "预览菜单栏菜单", target: self, action: #selector(previewMenu(_:)))
            showMenu.bezelStyle = .rounded; root.addArrangedSubview(showMenu)
        }
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 32), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -32), root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28)])
        hint.widthAnchor.constraint(equalToConstant: 420).isActive = true
        feedbackLabel.widthAnchor.constraint(equalToConstant: 420).isActive = true
        if projectURL != nil {
            let projectLink = NSButton(title: "GitHub 项目 · 查看源码 / Star", target: self, action: #selector(openProject))
            projectLink.isBordered = false
            projectLink.font = .systemFont(ofSize: 13)
            projectLink.contentTintColor = .linkColor
            projectLink.toolTip = "在浏览器中打开 GitHub 项目"
            projectLink.translatesAutoresizingMaskIntoConstraints = false
            window.contentView!.addSubview(projectLink)
            NSLayoutConstraint.activate([
                projectLink.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
                projectLink.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -18),
                root.bottomAnchor.constraint(lessThanOrEqualTo: projectLink.topAnchor, constant: -18)
            ])
        }
        window.center()
    }
    var projectURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CUMTProjectURL") as? String,
              let url = URL(string: raw), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.path.split(separator: "/").count == 2 else { return nil }
        return url
    }
    @objc func openProject() {
        if let url = projectURL { NSWorkspace.shared.open(url) }
    }
    @objc func showSettings(_ sender: Any?) {
        if window == nil { makeSettings() }
        usernameField.stringValue = preferences.username
        secureField.stringValue = ""; visibleField.stringValue = ""
        if preview { secureField.stringValue = "demo-password" }
        revealButton.state = .off; secureField.isHidden = false; visibleField.isHidden = true
        operatorPopup.selectItem(withTitle: preferences.operatorName)
        intervalPopup.selectItem(at: [30.0, 60.0, 120.0, 300.0].firstIndex(of: preferences.interval) ?? 1)
        syncSwitches()
        feedbackLabel.stringValue = preview ? "界面预览 · 不会操作真实账号或网络" : "设置保存后立即生效。"
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func togglePassword() {
        if revealButton.state == .on {
            visibleField.stringValue = secureField.stringValue; secureField.isHidden = true; visibleField.isHidden = false
            window?.makeFirstResponder(visibleField)
        } else {
            secureField.stringValue = visibleField.stringValue; visibleField.isHidden = true; secureField.isHidden = false
            window?.makeFirstResponder(secureField)
        }
    }
    @discardableResult func persistSettings() -> Bool {
        let username = usernameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard username.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else { feedbackLabel.stringValue = "请输入正确的学号或工号（不要添加运营商后缀）。"; return false }
        let password = revealButton.state == .on ? visibleField.stringValue : secureField.stringValue
        if password.isEmpty && (preferences.username.isEmpty || username != preferences.username) { feedbackLabel.stringValue = "首次设置或更换账号时，请填写密码。"; return false }
        let previous = preferences
        do {
            if !preview, !password.isEmpty { try PasswordStore.save(username, password: password) }
            preferences.username = username; preferences.operatorName = operatorPopup.titleOfSelectedItem ?? "校园网"
            preferences.autoLogin = autoCheckbox.state == .on
            preferences.interval = [30.0, 60.0, 120.0, 300.0][max(0, intervalPopup.indexOfSelectedItem)]
            if !preview { try setStartup(startupCheckbox.state == .on) }
            try savePreferences()
            if !preview, !previous.username.isEmpty, previous.username != username { PasswordStore.remove(previous.username) }
            secureField.stringValue = ""; visibleField.stringValue = ""; revealButton.state = .off
            secureField.isHidden = false; visibleField.isHidden = true
            retryAfter = .distantPast; refreshTimer(); syncSwitches()
            feedbackLabel.stringValue = "已保存。密码仅保存在本机钥匙串。"
            return true
        } catch {
            preferences = previous
            feedbackLabel.stringValue = (error as? AppError)?.description ?? "保存设置失败，请检查文件权限。"
            return false
        }
    }
    @objc func saveSettings() { if persistSettings(), preferences.autoLogin { inspect(manual: false) } }
    @objc func saveAndLogin() { if persistSettings() { manualLogin() } }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()

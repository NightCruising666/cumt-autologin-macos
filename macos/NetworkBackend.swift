// SPDX-License-Identifier: AGPL-3.0-only
// Dr.COM flow adapted from the upstream Python implementation; see NOTICE.md.
import Foundation

protocol PortalTransport {
    func get(_ url: URL, timeout: TimeInterval, allowPageRedirects: Bool) -> (Int, Data)?
}

final class NativeHTTP: NSObject, PortalTransport, URLSessionTaskDelegate {
    private var allowsPageRedirects = false
    private var redirects = 0
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
        config.urlCache = nil
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForResource = 8
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    func close() { session.invalidateAndCancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let destination = request.url
        let accepted = allowsPageRedirects && redirects < 3
            && destination?.scheme == "http" && destination?.host == "10.2.5.251"
            && (destination?.port == nil || destination?.port == 80)
            && destination?.user == nil && destination?.password == nil
            && !(task.originalRequest?.url?.query?.contains("user_password") ?? false)
            && !(destination?.query?.contains("user_password") ?? false)
        redirects += 1
        completionHandler(accepted ? request : nil)
    }
    // Called only on the application's serial background operation, never the UI thread.
    func get(_ url: URL, timeout: TimeInterval = 5, allowPageRedirects: Bool = false) -> (Int, Data)? {
        allowsPageRedirects = allowPageRedirects; redirects = 0
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("CUMT-AutoLogin-macOS/0.3", forHTTPHeaderField: "User-Agent")
        if url.host == "10.2.5.251" { request.setValue("http://10.2.5.251/", forHTTPHeaderField: "Referer") }
        let semaphore = DispatchSemaphore(value: 0)
        var result: (Int, Data)?
        let task = session.dataTask(with: request) { data, response, error in
            if error == nil, let response = response as? HTTPURLResponse, let data = data, data.count <= 1024 * 1024 {
                result = (response.statusCode, data)
            }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 2) == .timedOut {
            task.cancel()
            // Wait for the cancellation callback before allowing another request.
            semaphore.wait()
            return nil
        }
        return result
    }
}

struct CampusEnvironment {
    let interface: String
    let ssid: String?
    let ip: String
}

struct NativeBackend {
    let transport: PortalTransport
    var command: ([String]) -> String = NativeBackend.runCommand
    var pause: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }
    static let operators = ["校园网": "", "中国移动": "@cmcc", "中国联通": "@unicom", "中国电信": "@telecom"]
    static let checkURLs = ["http://connect.rom.miui.com/generate_204", "http://204.ustclug.org/"]

    static func runCommand(_ args: [String]) -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: args[0]); process.arguments = Array(args.dropFirst())
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        do {
            try process.run(); DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); timeout.cancel()
            return String(data: data, encoding: .utf8) ?? ""
        } catch { timeout.cancel(); return "" }
    }
    static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
    static func validIP(_ ip: String) -> Bool {
        let components = ip.split(separator: ".", omittingEmptySubsequences: false)
        return components.count == 4 && components.allSatisfy { piece in
            !piece.isEmpty && piece.allSatisfy(\.isNumber) && Int(piece).map { (0...255).contains($0) } == true
        }
    }
    func environment() -> (CampusEnvironment?, BackendResult?) {
        let hardware = command(["/usr/sbin/networksetup", "-listallhardwareports"])
        guard let interface = Self.capture("Hardware Port: (?:Wi-Fi|AirPort)\\nDevice: (\\S+)", in: hardware) else {
            return (nil, BackendResult(state: "outside", message: "未找到 Wi-Fi 网卡", retry_delay: nil))
        }
        let wifi = command(["/usr/sbin/networksetup", "-getairportnetwork", interface])
        var ssid = Self.capture("Current (?:AirPort|Wi-Fi) Network:\\s*(.+)", in: wifi)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if ssid == "<redacted>" || ssid == "<hidden>" { ssid = nil }
        if let ssid = ssid, ssid != "CUMT_Stu" {
            return (nil, BackendResult(state: "outside", message: "当前未连接 CUMT_Stu", retry_delay: nil))
        }
        let route = command(["/sbin/route", "-n", "get", "10.2.5.251"])
        if Self.capture("interface:\\s*(\\S+)", in: route) != interface {
            return (nil, BackendResult(state: "blocked", message: "校园网路由未走 Wi-Fi，请检查 TUN/VPN", retry_delay: nil))
        }
        let ip = command(["/usr/sbin/ipconfig", "getifaddr", interface]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validIP(ip), ip.hasPrefix("10.") else {
            return (nil, BackendResult(state: "outside", message: "尚未获得校园网地址", retry_delay: nil))
        }
        return (CampusEnvironment(interface: interface, ssid: ssid, ip: ip), nil)
    }
    func online() -> Bool {
        Self.checkURLs.contains { value in
            guard let (code, data) = transport.get(URL(string: value)!, timeout: 3, allowPageRedirects: false) else { return false }
            return code == 204 && data.isEmpty
        }
    }
    static func pageText(_ data: Data) -> String { String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "" }
    // The gateway writes v4ip/olmac only once a session exists. While logged out
    // the same values arrive as ss5/ss4 (and v46ip on IPv6-enabled ACs), which is
    // exactly what the portal's own page script reads; see a41.js. Without these
    // names a logged-out Mac could never identify its terminal address and the
    // hidden-SSID check refused every login.
    static let terminalIPFields = ["ss5", "v4ip", "v46ip", "wlan_user_ip", "user_ip"]
    static let terminalMACFields = ["ss4", "olmac", "wlan_user_mac", "user_mac"]
    // "Dr.COM" carries a dot, so a plain "drcom" alternative never matches the
    // portal's own marker; eportal and WebLoginID cover the login page.
    static let campusPortalMarker = "dr\\.?com|eportal|哆点|WebLoginID"

    static func terminalField(_ names: [String], value: String, in html: String) -> String? {
        for name in names {
            if let found = capture("\\b" + name + "\\s*=\\s*['\"](\(value))['\"]", in: html) { return found }
        }
        return nil
    }
    static func parsePortal(_ html: String, environment: CampusEnvironment) throws -> (String, String) {
        let pageIP = terminalField(terminalIPFields, value: "[\\d.]+", in: html)
        let ip = pageIP ?? environment.ip
        guard validIP(ip), ip == environment.ip else { throw AppError.message("认证页终端地址与 Wi-Fi 不一致，请检查 TUN 或虚拟网卡。") }
        if environment.ssid == nil {
            // Modern macOS hides the SSID from apps without Location access, so
            // this is the normal path: require the page to be the campus portal,
            // and to state the terminal address we are about to authorise.
            guard html.range(of: Self.campusPortalMarker, options: [.regularExpression, .caseInsensitive]) != nil else {
                throw AppError.message("SSID 被系统隐藏，且页面不符合校园网认证特征，本次不提交密码。")
            }
            guard pageIP != nil else {
                throw AppError.message("认证页未提供终端地址（ss5/v4ip/v46ip），无法核对本机地址，本次不提交密码。")
            }
        }
        let raw = terminalField(terminalMACFields, value: "[0-9a-fA-F:.\\-]+", in: html) ?? ""
        let mac = raw.replacingOccurrences(of: "[:.-]", with: "", options: .regularExpression).lowercased()
        return (ip, mac.range(of: "^[0-9a-f]{12}$", options: .regularExpression) != nil ? mac : "000000000000")
    }
    static func requestURL(_ params: [String: String]) -> URL {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let query = params.keys.sorted().map { key in
            key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + params[key]!.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&")
        return URL(string: "http://10.2.5.251:801/eportal/?" + query)!
    }
    static func responseData(_ body: Data) -> [String: Any]? {
        var text = pageText(body).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.hasPrefix("{") {
            guard let first = text.firstIndex(of: "("), let last = text.lastIndex(of: ")"), first < last else { return nil }
            text = String(text[text.index(after: first)..<last])
        }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
    static func responseMessage(_ response: (Int, Data)?) -> (String, Bool) {
        guard let (code, body) = response else { return ("认证请求未完成，请检查网络或代理。", false) }
        if (300...399).contains(code) { return ("接口返回跳转，继续验证是否真正联网。", false) }
        guard code == 200 else { return ("认证接口返回 HTTP \(code)。", false) }
        guard let data = responseData(body) else { return ("接口响应格式未知，继续验证联网状态。", false) }
        if String(describing: data["result"] ?? "") == "1" { return ("接口受理成功，正在验证联网状态。", false) }
        var message = String(describing: data["msg"] ?? "")
        if let decoded = Data(base64Encoded: message), let text = String(data: decoded, encoding: .utf8) { message += text }
        if message.contains("userid error1") || message.contains("用户不存在") { return ("账号不存在或运营商选择错误，请重新设置账号。", true) }
        if message.contains("userid error2") || message.contains("密码") { return ("账号或密码错误，请先在浏览器中确认。", true) }
        if message.contains("Limit Users") || message.contains("在线") && message.contains("限制") { return ("在线设备数量已达上限，请在自助服务中下线旧设备。", true) }
        return ("认证尚未成功，请检查账号、运营商或设备数限制。", false)
    }
    func dispatch(_ action: String, username: String, operatorName: String, password: String) -> BackendResult {
        let (possible, error) = environment()
        guard let env = possible else { return error! }
        let wasOnline = online()
        guard let (code, data) = transport.get(URL(string: "http://10.2.5.251/")!, timeout: 5, allowPageRedirects: true), code == 200 else {
            return BackendResult(state: "error", message: "校园网认证页不可达，请确认已连接 CUMT_Stu。", retry_delay: nil)
        }
        let ip: String, mac: String
        do { (ip, mac) = try Self.parsePortal(Self.pageText(data), environment: env) }
        catch { return BackendResult(state: "error", message: (error as? AppError)?.description ?? "无法识别校园门户", retry_delay: nil) }
        if action == "status" { return BackendResult(state: wasOnline ? "online" : "offline", message: wasOnline ? "校园网已联网" : "已连接校园 Wi-Fi，尚未联网", retry_delay: nil) }
        if action == "login" {
            if wasOnline { return BackendResult(state: "online", message: "已联网，无需重复认证", retry_delay: nil) }
            guard username.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil,
                  let suffix = Self.operators[operatorName], !password.isEmpty else {
                return BackendResult(state: "error", message: "请先在详细设置中填写账号、密码和运营商", retry_delay: nil)
            }
            var message = "登录未成功", permanent = false
            for attempt in 0..<3 {
                let (current, changed) = environment()
                guard let now = current, now.interface == env.interface, now.ip == ip else {
                    return changed ?? BackendResult(state: "outside", message: "网络发生变化，已停止认证", retry_delay: nil)
                }
                let ts = String(Int(Date().timeIntervalSince1970 * 1000))
                let params = ["c": "Portal", "a": "login", "callback": "dr" + ts, "login_method": "1",
                              "user_account": username + suffix, "user_password": password, "wlan_user_ip": ip,
                              "wlan_user_ipv6": "", "wlan_user_mac": mac, "wlan_ac_ip": "", "wlan_ac_name": "",
                              "portal_type": "1", "jsVersion": "3.0", "_": ts]
                (message, permanent) = Self.responseMessage(transport.get(Self.requestURL(params), timeout: 5, allowPageRedirects: false))
                for _ in 0..<3 {
                    if online() { return BackendResult(state: "online", message: "认证成功，外网检查通过", retry_delay: nil) }
                    if permanent { break }; pause(1)
                }
                if permanent { break }; if attempt < 2 { pause(2) }
            }
            return BackendResult(state: "offline", message: message, retry_delay: permanent ? 900 : 300)
        }
        if action == "logout" {
            let (current, changed) = environment()
            guard let now = current, now.ip == ip else { return changed ?? BackendResult(state: "outside", message: "网络发生变化，已停止注销", retry_delay: nil) }
            let ts = String(Int(Date().timeIntervalSince1970 * 1000))
            let params = ["c": "Portal", "a": "logout", "callback": "dr" + ts, "login_method": "1",
                          "user_account": "drcom", "user_password": "123", "ac_logout": "0", "wlan_user_ip": ip,
                          "wlan_user_ipv6": "", "wlan_vlan_id": "1", "wlan_user_mac": mac, "wlan_ac_ip": "",
                          "wlan_ac_name": "", "jsVersion": "3.0", "_": ts]
            let response = transport.get(Self.requestURL(params), timeout: 5, allowPageRedirects: false)
            let accepted = response?.0 == 200 && String(describing: Self.responseData(response?.1 ?? Data())?["result"] ?? "") == "1"
            pause(1); let stillOnline = online()
            return BackendResult(state: stillOnline ? "online" : accepted ? "offline" : "unknown",
                                 message: accepted && !stillOnline ? "已注销当前设备，自动登录已暂停" : "暂未确认注销成功；自动登录已暂停，可打开登录页检查", retry_delay: nil)
        }
        return BackendResult(state: "error", message: "未知操作", retry_delay: nil)
    }
}

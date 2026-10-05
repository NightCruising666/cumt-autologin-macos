// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

final class MockPortal: PortalTransport {
    var connected = false
    var authenticate = true
    var rejectPassword = false
    var requests = [URL]()
    var page = "var v4ip='10.4.2.3';var olmac='AA:BB:CC:DD:EE:FF'; /* drcom */"
    func get(_ url: URL, timeout: TimeInterval, allowPageRedirects: Bool) -> (Int, Data)? {
        requests.append(url)
        if url.host != "10.2.5.251" { return connected ? (204, Data()) : (200, Data("portal".utf8)) }
        if url.port != 801 { return (200, Data(page.utf8)) }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let action = items.first { $0.name == "a" }!.value!
        if action == "logout" { connected = false; return (200, Data("dr1({\"result\":1});".utf8)) }
        if rejectPassword { return (200, Data("{\"result\":0,\"msg\":\"userid error2\"}".utf8)) }
        if authenticate { connected = true }
        return (200, Data("{\"result\":1}".utf8))
    }
}

@main struct Tests {
    static var passed = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { print("FAIL: " + name); exit(1) }
        passed += 1; print("PASS: " + name)
    }
    static func backend(_ mock: MockPortal, ssid: String = "CUMT_Stu", route: String = "en0") -> NativeBackend {
        NativeBackend(transport: mock, command: { args in
            if args.contains("-listallhardwareports") { return "Hardware Port: Wi-Fi\nDevice: en0\n" }
            if args.contains("-getairportnetwork") { return "Current AirPort Network: " + ssid }
            if args[0] == "/sbin/route" { return "interface: " + route }
            return "10.4.2.3"
        }, pause: { _ in })
    }
    static func main() throws {
        check(NativeBackend.validIP("10.4.2.3") && !NativeBackend.validIP("10.4.2.999"), "IPv4 validation")
        let password = "a&+?# 中文=\""
        let url = NativeBackend.requestURL(["user_password": password, "user_account": "1234@cmcc"])
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        check(items.first { $0.name == "user_password" }?.value == password, "special-character password round trip")
        check(url.absoluteString.contains("%2B") && url.absoluteString.contains("%26"), "plus and ampersand encoded")
        let env = CampusEnvironment(interface: "en0", ssid: nil, ip: "10.4.2.3")
        let info = try NativeBackend.parsePortal(MockPortal().page, environment: env)
        check(info.0 == env.ip && info.1 == "aabbccddeeff", "portal terminal fields")
        check((try? NativeBackend.parsePortal("router admin", environment: env)) == nil, "hidden SSID needs fingerprint")
        check((try? NativeBackend.parsePortal("var v4ip='10.5.2.3';drcom", environment: env)) == nil, "reject terminal mismatch")
        let unknown = NativeBackend.responseMessage((200, Data("{\"result\":0,\"msg\":\"SECRET\"}".utf8)))
        check(!unknown.0.contains("SECRET"), "do not echo credential-bearing messages")
        check(NativeBackend.responseMessage((200, Data("{\"result\":0,\"msg\":\"userid error2\"}".utf8))).1, "recognize permanent password failure")
        let outside = MockPortal()
        check(backend(outside, ssid: "Home").dispatch("login", username: "1234", operatorName: "中国移动", password: "SECRET").state == "outside" && outside.requests.isEmpty, "other Wi-Fi sends no requests")
        let blocked = MockPortal()
        check(backend(blocked, route: "utun4").dispatch("login", username: "1234", operatorName: "中国移动", password: "SECRET").state == "blocked" && blocked.requests.isEmpty, "TUN never submits credentials")
        let status = MockPortal()
        check(backend(status).dispatch("status", username: "", operatorName: "", password: "").state == "offline", "status requires no account")
        check(status.requests.allSatisfy { $0.port != 801 }, "status never authenticates")
        let login = MockPortal()
        check(backend(login).dispatch("login", username: "1234", operatorName: "中国电信", password: password).state == "online", "login verifies connectivity")
        let submitted = URLComponents(url: login.requests.first { $0.port == 801 }!, resolvingAgainstBaseURL: false)!.queryItems!
        check(submitted.first { $0.name == "user_account" }?.value == "1234@telecom", "selected operator suffix")
        check(submitted.first { $0.name == "user_password" }?.value == password, "submitted password preserved")
        let unverified = MockPortal(); unverified.authenticate = false
        check(backend(unverified).dispatch("login", username: "1234", operatorName: "校园网", password: "SECRET").state == "offline", "server success alone is insufficient")
        check(unverified.requests.filter { $0.port == 801 }.count == 3, "bounded retries")
        let bad = MockPortal(); bad.rejectPassword = true
        check(backend(bad).dispatch("login", username: "1234", operatorName: "校园网", password: "SECRET").retry_delay == 900, "password failure cooldown")
        check(bad.requests.filter { $0.port == 801 }.count == 1, "no repeated permanent failures")
        let logout = MockPortal(); logout.connected = true
        check(backend(logout).dispatch("logout", username: "", operatorName: "", password: "").state == "offline", "logout confirms current terminal offline")
        let logoutItems = URLComponents(url: logout.requests.first { $0.port == 801 }!, resolvingAgainstBaseURL: false)!.queryItems!
        check(logoutItems.first { $0.name == "wlan_user_ip" }?.value == "10.4.2.3", "logout uses current terminal IP")
        check(logoutItems.first { $0.name == "wlan_user_mac" }?.value == "aabbccddeeff", "logout uses current terminal MAC")
        if CommandLine.arguments.count > 1 {
            let base = CommandLine.arguments[1]
            let transport = NativeHTTP(); defer { transport.close() }
            check(transport.get(URL(string: base + "/")!, timeout: 3, allowPageRedirects: false)?.0 == 200, "native HTTP receives portal cookie")
            let cookie = transport.get(URL(string: base + "/cookie")!, timeout: 3, allowPageRedirects: false)
            check(cookie?.1 == Data("cookie-ok".utf8), "native HTTP reuses cookie")
            check(transport.get(URL(string: base + "/redirect")!, timeout: 3, allowPageRedirects: false)?.0 == 302, "native HTTP does not follow login redirect")
            check(transport.get(URL(string: base + "/204")!, timeout: 3, allowPageRedirects: false)?.0 == 204, "native HTTP recognizes 204")
        }
        print("\(passed) native tests passed.")
    }
}

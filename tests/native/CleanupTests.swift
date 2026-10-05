// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

@main struct CleanupTests {
    static var passed = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { print("FAIL: " + name); exit(1) }
        passed += 1; print("PASS: " + name)
    }
    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("CUMT-Cleanup-Tests-" + UUID().uuidString)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let home = temporary.appendingPathComponent("home")
        let applications = temporary.appendingPathComponent("Applications")
        let cleanup = AppCleanup(home: home, applicationDirectories: [applications])
        func write(_ url: URL, _ content: String = "test") throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
        }
        let state = cleanup.stateDirectory
        for name in ["menu-config.json", "menu.log", "menu.log.1", "config.json", "autologin.log"] {
            try write(state.appendingPathComponent(name))
        }
        for label in cleanup.launchLabels { try write(home.appendingPathComponent("Library/LaunchAgents/\(label).plist")) }
        let unrelated = home.appendingPathComponent("Library/LaunchAgents/other.app.plist")
        try write(unrelated)
        let cache = home.appendingPathComponent("Library/Caches/local.cumt.autologin.menu/cache.bin")
        try write(cache)
        check(cleanup.removeData().isEmpty, "known data cleanup succeeds")
        check(!fm.fileExists(atPath: state.path) && !fm.fileExists(atPath: cache.path), "configuration logs empty directory and app cache removed")
        check(cleanup.launchLabels.allSatisfy { !fm.fileExists(atPath: home.appendingPathComponent("Library/LaunchAgents/\($0).plist").path) }, "current and legacy startup files removed")
        check(fm.fileExists(atPath: unrelated.path), "other startup files preserved")
        check(cleanup.removeData().isEmpty, "repeated cleanup is safe")
        let personal = state.appendingPathComponent("my-notes.txt")
        try write(personal)
        try write(state.appendingPathComponent("menu.log"))
        check(!cleanup.removeData().isEmpty && fm.fileExists(atPath: personal.path), "unknown files preserved and reported")
        try fm.removeItem(at: state)
        let outside = temporary.appendingPathComponent("outside")
        let outsideData = outside.appendingPathComponent("menu-config.json")
        try write(outsideData)
        try fm.createSymbolicLink(at: state, withDestinationURL: outside)
        check(!cleanup.removeData().isEmpty && fm.fileExists(atPath: outsideData.path), "substituted state-directory symlink never followed")
        func app(_ url: URL, identifier: String) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": identifier, "CFBundlePackageType": "APPL"], format: .xml, options: 0)
            let plist = url.appendingPathComponent("Contents/Info.plist")
            try fm.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: plist)
        }
        let installed = applications.appendingPathComponent("校园网助手.app")
        let other = applications.appendingPathComponent("CUMT Auto Login.app")
        let development = home.appendingPathComponent("develop/build/CUMT Auto Login.app")
        try app(installed, identifier: cleanup.bundleIdentifier)
        try app(other, identifier: "other.app")
        try app(development, identifier: cleanup.bundleIdentifier)
        check(cleanup.installedApplications(current: development).map { $0.path } == [installed.path], "only matching installed app selected; source and other app preserved")
        var trashed = [URL]()
        check(cleanup.trashInstalledApplications(current: installed) { trashed.append($0) }.isEmpty && trashed.map { $0.path } == [installed.path], "installed running app deduplicated")
        enum FakeError: Error { case denied }
        check(!cleanup.trashInstalledApplications(current: installed, trash: { _ in throw FakeError.denied }).isEmpty, "failed app removal reported")
        print("\(passed) cleanup tests passed; no real home, Keychain, or installed app touched")
    }
}

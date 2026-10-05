// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Every deletion is scoped to this app. The injected home directory lets tests
/// exercise cleanup without touching the user's settings or installed apps.
struct AppCleanup {
    let home: URL
    let applicationDirectories: [URL]
    let bundleIdentifier: String
    let fileManager: FileManager

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         applicationDirectories: [URL]? = nil,
         bundleIdentifier: String = "local.cumt.autologin.menu",
         fileManager: FileManager = .default) {
        self.home = home
        self.applicationDirectories = applicationDirectories ?? [home.appendingPathComponent("Applications"), URL(fileURLWithPath: "/Applications")]
        self.bundleIdentifier = bundleIdentifier
        self.fileManager = fileManager
    }

    var launchLabels: [String] { ["local.cumt.autologin.menu.startup", "local.cumt.autologin"] }
    var stateDirectory: URL { home.appendingPathComponent("Library/Application Support/CUMT-AutoLogin") }

    func removeData() -> [String] {
        var failures = [String]()
        func remove(_ url: URL) {
            do { try fileManager.removeItem(at: url) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { }
            catch { failures.append("无法移除：\(url.path)") }
        }
        for label in launchLabels {
            remove(home.appendingPathComponent("Library/LaunchAgents/\(label).plist"))
        }
        // Do not follow a substituted data-directory symlink, or recursively
        // delete unknown files someone may have put in this directory.
        do {
            let attributes = try fileManager.attributesOfItem(atPath: stateDirectory.path)
            if attributes[.type] as? FileAttributeType == .typeDirectory {
                for name in ["menu-config.json", "menu.log", "menu.log.1", "config.json", "config.json.tmp",
                             "cumt_login.py", "autologin.log", "autologin.log.1", "launchd.out.log", "launchd.err.log",
                             "run.lock", "README.md", "LICENSE", "NOTICE.md"] {
                    remove(stateDirectory.appendingPathComponent(name))
                }
                do {
                    if try fileManager.contentsOfDirectory(atPath: stateDirectory.path).isEmpty { remove(stateDirectory) }
                    else { failures.append("数据目录中有其他文件，已保留：\(stateDirectory.path)") }
                } catch { failures.append("无法检查数据目录：\(stateDirectory.path)") }
            } else { failures.append("数据目录类型异常，未清理：\(stateDirectory.path)") }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { }
        catch { failures.append("无法读取数据目录：\(stateDirectory.path)") }
        for path in ["Library/Caches/\(bundleIdentifier)", "Library/Saved Application State/\(bundleIdentifier).savedState",
                     "Library/Preferences/\(bundleIdentifier).plist"] {
            remove(home.appendingPathComponent(path))
        }
        return failures
    }

    func installedApplications(current: URL) -> [URL] {
        var candidates = applicationDirectories.flatMap { directory in
            ["校园网助手.app", "CUMT Auto Login.app", "CUMT Auto Login.new.app"].map { directory.appendingPathComponent($0) }
        }
        if applicationDirectories.contains(where: { $0.standardizedFileURL.path == current.deletingLastPathComponent().standardizedFileURL.path }) {
            candidates.append(current)
        }
        var seen = Set<String>()
        return candidates.filter {
            seen.insert($0.standardizedFileURL.path).inserted && Bundle(url: $0)?.bundleIdentifier == bundleIdentifier
        }
    }

    func trashInstalledApplications(current: URL, trash: (URL) throws -> Void) -> [String] {
        var failures = [String]()
        for application in installedApplications(current: current) {
            do { try trash(application) }
            catch { failures.append("无法移入废纸篓：\(application.path)") }
        }
        return failures
    }
}

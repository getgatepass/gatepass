import AppKit
import Foundation
import Security
import UserNotifications

/// Keeps GatePass up to date from the GitHub releases.
///
/// Checks `releases/latest` on launch and every 6 hours, downloads the new GatePass.dmg in the
/// background, copies the app out of it and checks it is signed with the same certificate as
/// the running app. The prepared update is installed when the person clicks "Restart to Update",
/// or silently when GatePass quits.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release: Equatable {
        let version: String
        let notes: String
        let dmgURL: URL
        let pageURL: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate(Date)
        case downloading(Release)
        /// Verified and copied out; installs on restart or quit.
        case ready(Release, stagedApp: URL)
        /// A newer version exists but this copy of GatePass can't replace itself
        /// (not writable, running from a translocated location, or a local dev build).
        case manual(Release, reason: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// GATEPASS_UPDATE_URL points the check at another feed of the same shape (for testing).
    /// The certificate check below still applies to whatever it serves.
    static let releasesAPI = ProcessInfo.processInfo.environment["GATEPASS_UPDATE_URL"].flatMap(URL.init(string:))
        ?? URL(string: "https://api.github.com/repos/getgatepass/gatepass/releases/latest")!
    private static let interval: TimeInterval = 6 * 60 * 60
    private static let bundleID = "app.gatepass.sideloader"

    private var loopTask: Task<Void, Never>?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var pendingRelease: Release? {
        switch state {
        case .downloading(let r), .ready(let r, _), .manual(let r, _): return r
        default: return nil
        }
    }

    // MARK: Scheduling

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10 * 1_000_000_000) // let launch settle
            while !Task.isCancelled {
                if Pref.bool(Pref.autoUpdate, default: true) {
                    await self?.check(userInitiated: false)
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
            }
        }
    }

    // MARK: Check + download

    func check(userInitiated: Bool) async {
        switch state {
        case .checking, .downloading, .ready: return
        default: break
        }
        state = .checking
        do {
            guard let release = try await fetchLatest(), Self.isNewer(release.version, than: currentVersion) else {
                state = .upToDate(Date())
                return
            }
            if let reason = cannotSelfUpdateReason() {
                state = .manual(release, reason: reason)
                return
            }
            state = .downloading(release)
            let staged = try await prepare(release)
            state = .ready(release, stagedApp: staged)
            notifyReady(release)
        } catch {
            NSLog("GatePass update check failed: \(error)")
            try? FileManager.default.removeItem(at: Self.workDirectory)
            // Background checks fail quietly (offline, rate limit); only show it when asked.
            state = userInitiated ? .failed(Self.describe(error)) : .idle
        }
    }

    private func fetchLatest() async throws -> Release? {
        var request = URLRequest(url: Self.releasesAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GatePass/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError("GitHub answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = json["assets"] as? [[String: Any]]
        else { throw UpdateError("Unexpected answer from GitHub") }
        if json["draft"] as? Bool == true || json["prerelease"] as? Bool == true { return nil }
        guard let dmg = assets.first(where: { ($0["name"] as? String) == "GatePass.dmg" })?["browser_download_url"] as? String,
              let dmgURL = URL(string: dmg)
        else { return nil } // release without a DMG yet (still uploading)
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, notes: json["body"] as? String ?? "", dmgURL: dmgURL, pageURL: page)
    }

    /// Download the DMG, copy GatePass.app out of it and verify it. Returns the staged app.
    private func prepare(_ release: Release) async throws -> URL {
        let work = Self.workDirectory
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let (tmp, response) = try await URLSession.shared.download(from: release.dmgURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError("Download failed (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        let dmg = work.appendingPathComponent("GatePass.dmg")
        try FileManager.default.moveItem(at: tmp, to: dmg)

        let mount = work.appendingPathComponent("mnt")
        let staged = work.appendingPathComponent("GatePass.app")
        try await Self.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                                "-mountpoint", mount.path, dmg.path])
        do {
            try await Self.run("/usr/bin/ditto", [mount.appendingPathComponent("GatePass.app").path, staged.path])
        } catch {
            _ = try? await Self.run("/usr/bin/hdiutil", ["detach", "-force", mount.path])
            throw error
        }
        _ = try? await Self.run("/usr/bin/hdiutil", ["detach", "-force", mount.path])
        try? FileManager.default.removeItem(at: dmg)

        try verify(staged, expectedVersion: release.version)
        return staged
    }

    /// The new app must be intact, be GatePass, be the advertised version, and be signed with
    /// the same certificate as the running app, so a swapped download can't replace it.
    private func verify(_ app: URL, expectedVersion: String) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Self.bundleID
        else { throw UpdateError("The download isn't GatePass") }
        guard info["CFBundleShortVersionString"] as? String == expectedVersion else {
            throw UpdateError("The download is a different version than the release says")
        }
        guard let mine = Self.signingCertificate(of: Bundle.main.bundleURL) else {
            throw UpdateError("This copy of GatePass isn't signed, so updates can't be checked")
        }
        guard let theirs = Self.signingCertificate(of: app) else {
            throw UpdateError("The download's signature is broken")
        }
        guard mine == theirs else { throw UpdateError("The download is signed by someone else") }
    }

    /// Leaf certificate of a validly signed bundle (nested code included), or nil.
    nonisolated static func signingCertificate(of url: URL) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first
        else { return nil }
        return SecCertificateCopyData(leaf) as Data
    }

    private func cannotSelfUpdateReason() -> String? {
        let app = Bundle.main.bundleURL
        if app.path.contains("/AppTranslocation/") {
            return "Move GatePass to your Applications folder to get updates automatically."
        }
        let fm = FileManager.default
        if !fm.isWritableFile(atPath: app.deletingLastPathComponent().path) || !fm.isWritableFile(atPath: app.path) {
            return "GatePass can't replace itself in this folder."
        }
        if Self.signingCertificate(of: app) == nil {
            return "This copy of GatePass isn't signed, so it can't update itself."
        }
        return nil
    }

    // MARK: Install

    /// Quit, swap the app, open the new one.
    func installAndRelaunch() {
        guard case .ready(_, let staged) = state else { return }
        if launchSwap(staged: staged, relaunch: true) {
            NSApp.terminate(nil)
        }
    }

    /// Called when GatePass quits: a prepared update goes in without relaunching.
    func installOnQuitIfReady() {
        guard case .ready(_, let staged) = state else { return }
        _ = launchSwap(staged: staged, relaunch: false)
    }

    private var swapLaunched = false

    /// Start a detached helper that waits for this process to exit, then replaces the app.
    /// The old app is kept until the new one is in place, and put back if the move fails.
    private func launchSwap(staged: URL, relaunch: Bool) -> Bool {
        guard !swapLaunched, FileManager.default.fileExists(atPath: staged.path) else { return swapLaunched }
        let script = #"""
        PID="$1"; STAGED="$2"; TARGET="$3"; RELAUNCH="$4"
        for _ in $(seq 1 300); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
        BACKUP="${TARGET%.app}.gatepass-old.app"
        rm -rf "$BACKUP"
        mv "$TARGET" "$BACKUP" || exit 1
        if ditto "$STAGED" "$TARGET"; then
          rm -rf "$BACKUP" "$STAGED"
        else
          rm -rf "$TARGET"; mv "$BACKUP" "$TARGET"
        fi
        xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
        [ "$RELAUNCH" = 1 ] && open "$TARGET"
        exit 0
        """#
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script, "gatepass-update",
                       String(ProcessInfo.processInfo.processIdentifier),
                       staged.path, Bundle.main.bundleURL.path, relaunch ? "1" : "0"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            swapLaunched = true
            return true
        } catch {
            state = .failed("Couldn't start the update: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Helpers

    private func notifyReady(_ release: Release) {
        guard Pref.bool(Pref.notifications, default: true) else { return }
        let content = UNMutableNotificationContent()
        content.title = "GatePass \(release.version) is ready"
        content.body = "Click Restart to Update in GatePass, or it installs the next time GatePass quits."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "update-\(release.version)", content: content, trigger: nil))
    }

    static var workDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID).appendingPathComponent("Update")
    }

    /// "0.1.10" > "0.1.9"; missing parts count as 0.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? UpdateError { return e.message }
        if (error as? URLError) != nil { return "Couldn't reach GitHub. Check your internet connection." }
        return error.localizedDescription
    }

    @discardableResult
    private nonisolated static func run(_ tool: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            p.terminationHandler = { proc in
                let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    cont.resume(returning: text)
                } else {
                    cont.resume(throwing: UpdateError("\((tool as NSString).lastPathComponent) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))"))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}

struct UpdateError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

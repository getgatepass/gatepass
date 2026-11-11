import CryptoKit
import Foundation

/// Recent IPAs and a user-chosen folder of IPAs, with cached metadata and icons.
@MainActor
final class Library: ObservableObject {
    @Published private(set) var recent: [IPAFile] = []
    @Published private(set) var folderFiles: [IPAFile] = []
    @Published private(set) var folder: URL?
    /// User-chosen display names, keyed by file path. Only shown inside GatePass; files are never renamed.
    @Published private(set) var aliases: [String: String] = [:]

    private let defaults = UserDefaults.standard
    private let recentKey = "recentIPAs"
    private let folderKey = "ipaFolder"
    private let aliasKey = "ipaAliases"
    private var metaCache: [String: IPAFile] = [:]

    private var cacheDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GatePass/icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        if let path = defaults.string(forKey: folderKey) { folder = URL(fileURLWithPath: path) }
        aliases = defaults.dictionary(forKey: aliasKey) as? [String: String] ?? [:]
        reload()
    }

    // MARK: Aliases

    func displayName(_ file: IPAFile) -> String {
        aliases[file.url.path] ?? file.name
    }

    func hasAlias(_ file: IPAFile) -> Bool { aliases[file.url.path] != nil }

    /// Empty or nil clears the alias.
    func setAlias(_ name: String?, for file: IPAFile) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed == file.name {
            aliases.removeValue(forKey: file.url.path)
        } else {
            aliases[file.url.path] = trimmed
        }
        defaults.set(aliases, forKey: aliasKey)
    }

    /// Alias of any known IPA with this bundle id (used to label tracked apps).
    func alias(forBundleId bundleId: String) -> String? {
        (recent + folderFiles).first { $0.bundleId == bundleId && aliases[$0.url.path] != nil }
            .flatMap { aliases[$0.url.path] }
    }

    func reload() {
        let paths = defaults.stringArray(forKey: recentKey) ?? []
        recent = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(placeholder)
        folderFiles = scanFolder().map(placeholder)
        Task { await loadMetadata() }
    }

    func markRecent(_ url: URL) {
        var paths = defaults.stringArray(forKey: recentKey) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        defaults.set(Array(paths.prefix(12)), forKey: recentKey)
        reload()
    }

    func removeRecent(_ file: IPAFile) {
        var paths = defaults.stringArray(forKey: recentKey) ?? []
        paths.removeAll { $0 == file.url.path }
        defaults.set(paths, forKey: recentKey)
        reload()
    }

    /// Moves the IPA to the Trash (recoverable) and forgets it everywhere in the app.
    func trash(_ file: IPAFile) throws {
        try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
        setAlias(nil, for: file)
        removeRecent(file)
    }

    func setFolder(_ url: URL?) {
        folder = url
        defaults.set(url?.path, forKey: folderKey)
        reload()
    }

    /// Fast placeholder from the filename; real metadata fills in asynchronously.
    func placeholder(_ url: URL) -> IPAFile {
        metaCache[cacheKey(url)] ?? IPAFile(url: url, name: url.deletingPathExtension().lastPathComponent)
    }

    func info(for url: URL) async -> IPAFile {
        let key = cacheKey(url)
        if let cached = metaCache[key] { return cached }
        let iconURL = cacheDir.appendingPathComponent(key + ".png")
        var file = IPAFile(url: url, name: url.deletingPathExtension().lastPathComponent)
        if let r = try? await Engine.run(["ipa-info", "--ipa", url.path, "--icon-out", iconURL.path]) {
            if let n = r["name"] as? String, !n.isEmpty { file.name = n }
            file.bundleId = r["bundleId"] as? String
            file.version = r["version"] as? String
            if FileManager.default.fileExists(atPath: iconURL.path) { file.iconURL = iconURL }
        }
        metaCache[key] = file
        return file
    }

    private func loadMetadata() async {
        for url in (recent + folderFiles).map(\.url) where metaCache[cacheKey(url)] == nil {
            let file = await info(for: url)
            if let i = recent.firstIndex(where: { $0.url == url }) { recent[i] = file }
            if let i = folderFiles.firstIndex(where: { $0.url == url }) { folderFiles[i] = file }
        }
    }

    private func scanFolder() -> [URL] {
        guard let folder,
              let items = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return [] }
        return items
            .filter { ["ipa", "tipa"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func cacheKey(_ url: URL) -> String {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(url.path)|\(mtime)".utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

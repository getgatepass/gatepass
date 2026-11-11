import SwiftUI
import UniformTypeIdentifiers

/// Options passed to `gatepass-engine install`. Defaults = plain install.
struct InstallOptions: Equatable {
    enum Mode: String { case appleID, adhoc, export }

    var name = ""
    var bundleId = ""
    var version = ""
    var minOS = false
    var fileSharing = false
    var iPadFullscreen = false
    var removeExtensions = false
    var removeDeviceLimit = false
    var tweaks: [URL] = []
    var mode: Mode = .appleID
    var exportURL: URL?
    var trackForRefresh = true

    var engineArgs: [String] {
        var a: [String] = []
        if !name.isEmpty { a += ["--name", name] }
        if !bundleId.isEmpty { a += ["--bundle-id", bundleId] }
        if !version.isEmpty { a += ["--app-version", version] }
        if minOS { a.append("--min-os") }
        if fileSharing { a.append("--file-sharing") }
        if iPadFullscreen { a.append("--ipad-fullscreen") }
        if removeExtensions { a.append("--remove-extensions") }
        if removeDeviceLimit { a.append("--remove-device-limit") }
        for t in tweaks { a += ["--tweak", t.path] }
        if mode == .adhoc { a.append("--adhoc") }
        if mode == .export, let exportURL { a += ["--export", exportURL.path] }
        if !trackForRefresh || mode == .adhoc { a.append("--no-refresh") }
        return a
    }
}

/// Developer-mode sheet with Sideloadly-style options, grouped and collapsed by default.
struct AdvancedInstallSheet: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    let file: IPAFile
    @State private var opts = InstallOptions()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AppIcon(url: file.iconURL, name: file.name, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(library.displayName(file)).font(.system(size: 15, weight: .bold))
                    Text([file.bundleId, file.version.map { "v\($0)" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Advanced").font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.accent.opacity(0.15)))
                    .foregroundStyle(Theme.accent)
            }
            .padding(20)

            Form {
                Section("Mode") {
                    Picker("Signing", selection: $opts.mode) {
                        Text("Apple ID (default)").tag(InstallOptions.Mode.appleID)
                        Text("Ad-hoc (jailbreak / TrollStore)").tag(InstallOptions.Mode.adhoc)
                        Text("Only export the signed IPA").tag(InstallOptions.Mode.export)
                    }
                    if opts.mode == .appleID {
                        Toggle("Track for auto-refresh", isOn: $opts.trackForRefresh)
                    }
                }

                Section("App") {
                    TextField("Name", text: $opts.name, prompt: Text(file.name))
                    TextField("Bundle ID", text: $opts.bundleId, prompt: Text("automatic"))
                    TextField("Version", text: $opts.version, prompt: Text(file.version ?? "—"))
                }

                Section("Compatibility") {
                    Toggle("Try to support older iOS versions", isOn: $opts.minOS)
                    Toggle("Remove supported-device limit", isOn: $opts.removeDeviceLimit)
                    Toggle("Enable file sharing (Files app)", isOn: $opts.fileSharing)
                    Toggle("Force iPad fullscreen", isOn: $opts.iPadFullscreen)
                }

                Section {
                    Toggle("Remove extensions (widgets, share sheet…)", isOn: $opts.removeExtensions)
                } header: {
                    Text("Save App IDs")
                } footer: {
                    Text("Each extension uses an extra App ID from your 10 per week.").font(.caption)
                }

                Section("Tweaks") {
                    ForEach(opts.tweaks, id: \.self) { url in
                        HStack {
                            Image(systemName: "puzzlepiece.extension")
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { opts.tweaks.removeAll { $0 == url } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button("Add .dylib, .deb or .framework…", action: addTweak)
                }
            }
            .formStyle(.grouped)
            .frame(height: 400)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderless)
                Spacer()
                if let d = model.selectedDevice, opts.mode != .export {
                    Text("on \(d.name)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Button(opts.mode == .export ? "Export…" : "Install", action: start)
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(opts.mode != .export && model.selectedDevice == nil)
            }
            .padding(20)
        }
        .frame(width: 520)
    }

    private func addTweak() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true // .framework / .bundle are folders
        panel.allowedContentTypes = ["dylib", "deb", "framework", "bundle"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { opts.tweaks += panel.urls.filter { !opts.tweaks.contains($0) } }
    }

    private func start() {
        var o = opts
        if o.mode == .export {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = file.url.deletingPathExtension().lastPathComponent + "-signed.ipa"
            panel.allowedContentTypes = [UTType(filenameExtension: "ipa")].compactMap { $0 }
            guard panel.runModal() == .OK, let url = panel.url else { return }
            o.exportURL = url
        }
        dismiss()
        Task { if await model.install(file, options: o) { model.unstage(file) } }
    }
}

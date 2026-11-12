import SwiftUI

/// An Apple TV advertising the "Remote App and Devices" pairing screen.
struct PairableTV: Identifiable, Equatable {
    let id: String
    let name: String
    let host: String
    let port: Int

    init?(json: JSON) {
        guard let id = json["id"] as? String, let host = json["host"] as? String,
              let port = json["port"] as? Int else { return nil }
        self.id = id
        self.name = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Apple TV"
        self.host = host
        self.port = port
    }
}

/// Guides the user through pairing an Apple TV with the code it shows on screen.
struct PairAppleTVSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var found: [PairableTV] = []
    @State private var pairingWith: PairableTV?
    @State private var scanTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "appletv.fill")
                .font(.system(size: 34))
                .foregroundStyle(Theme.accentGradient)
            Text("Add Apple TV").font(.system(size: 18, weight: .bold))

            if case .pin = model.prompt?.kind, let prompt = model.prompt {
                PinEntry(prompt: prompt, tvName: pairingWith?.name ?? "Apple TV")
            } else if let tv = pairingWith {
                VStack(spacing: 10) {
                    ProgressView(value: (model.activity?.percent ?? 0) / 100)
                        .frame(width: 260)
                    Text(model.activity?.stage ?? "Pairing with \(tv.name)…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                instructions
                deviceList
            }

            if let error = model.pairError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel") {
                    if pairingWith != nil { model.cancelCurrent() }
                    dismiss()
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .disabled(pairingWith != nil && model.activity?.cancellable == false)
                Spacer()
            }
        }
        .padding(28)
        .frame(width: 440)
        .interactiveDismissDisabled()
        .onAppear { model.pairError = nil; startScanning() }
        .onDisappear { scanTask?.cancel() }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Step(number: 1, text: "Make sure the Apple TV is on the same Wi-Fi network as this Mac.")
            Step(number: 2, text: "On the Apple TV open **Settings → Remotes and Devices → Remote App and Devices** and stay on that screen.")
            Step(number: 3, text: "Choose your Apple TV below, then type the code it shows.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var deviceList: some View {
        VStack(spacing: 8) {
            if found.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Looking for Apple TVs…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
            } else {
                ForEach(found) { tv in
                    Button { pair(tv) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "appletv.fill").font(.system(size: 18))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tv.name).font(.system(size: 13, weight: .semibold))
                                Text(tv.host).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Pair").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.accentGradient)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func startScanning() {
        scanTask?.cancel()
        scanTask = Task {
            while !Task.isCancelled {
                if pairingWith == nil,
                   let r = try? await Engine.run(["pair-scan", "--seconds", "3"]),
                   let list = r["devices"] as? [JSON] {
                    let tvs = list.compactMap(PairableTV.init(json:)).sorted { $0.name < $1.name }
                    if !Task.isCancelled, tvs != found { withAnimation(.snappy) { found = tvs } }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func pair(_ tv: PairableTV) {
        model.pairError = nil
        withAnimation(.snappy) { pairingWith = tv }
        Task {
            let ok = await model.pairAppleTV(tv)
            if ok {
                dismiss()
            } else {
                withAnimation(.snappy) { pairingWith = nil }
            }
        }
    }
}

private struct Step: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Theme.accentGradient))
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PinEntry: View {
    let prompt: PendingPrompt
    let tvName: String
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text("Type the code shown on \(tvName).")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("000000", text: $code)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .textFieldStyle(RoundedFieldStyle())
                .frame(width: 200)
                .focused($focused)
                .onChange(of: code) { _, new in
                    let digits = String(new.filter(\.isNumber).prefix(6))
                    if digits != new { code = digits }
                    if digits.count == 6 { prompt.respond(digits) }
                }
                .onSubmit { if !code.isEmpty { prompt.respond(code) } }
        }
        .onAppear { focused = true }
    }
}

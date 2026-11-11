import SwiftUI

struct LoginSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var working = false
    @FocusState private var focus: Field?
    enum Field { case email, password }

    var body: some View {
        Group {
            if case .twoFactor = model.prompt?.kind, let prompt = model.prompt {
                // 2FA step lives inside this sheet — a second sheet can't open on top of it.
                TwoFactorSheet(prompt: prompt)
                    .id(prompt.id)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                credentials
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.prompt?.id)
        .interactiveDismissDisabled(working)
    }

    private var credentials: some View {
        VStack(spacing: 18) {
            Image(systemName: "apple.logo")
                .font(.system(size: 34))
            VStack(spacing: 4) {
                Text("Sign in with Apple ID").font(.system(size: 18, weight: .bold))
                Text("Used only to sign your apps. Your password is never saved — only Apple's session token is kept on this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .focused($focus, equals: .email)
                    .onSubmit { focus = .password }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .onSubmit(submit)
            }
            .textFieldStyle(RoundedFieldStyle())
            .disabled(working)

            if let error = model.loginError, !working {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
            } else if working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.activity?.stage ?? "Connecting to Apple…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Tip: create a separate free Apple ID just for sideloading.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Button("Cancel") {
                    model.loginError = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderless)
                .disabled(working)
                Spacer()
                Button(action: submit) {
                    if working { ProgressView().controlSize(.small).tint(.white) } else { Text("Sign In") }
                }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(email.isEmpty || password.isEmpty || working)
            }
        }
        .padding(28)
        .frame(width: 380)
        .onAppear { focus = .email }
    }

    private func submit() {
        guard !email.isEmpty, !password.isEmpty, !working else { return }
        working = true
        Task {
            _ = await model.login(email: email, password: password)
            password = ""
            working = false
        }
    }
}

struct TwoFactorSheet: View {
    let prompt: PendingPrompt
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 34))
                .foregroundStyle(Theme.accentGradient)
            VStack(spacing: 4) {
                Text("Verification code").font(.system(size: 18, weight: .bold))
                Text(isSMS ? "Enter the 6-digit code from the text message." : "Enter the 6-digit code shown on your iPhone or Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

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

            HStack {
                Button("Cancel") { prompt.respond("") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if !isSMS, !phones.isEmpty {
                    Menu("Send SMS") {
                        ForEach(phones, id: \.id) { phone in
                            Button("Number ending in \(phone.lastTwo)") { prompt.respond("sms:\(phone.id)") }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Button("Confirm") { prompt.respond(code) }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(code.count != 6)
            }
        }
        .padding(28)
        .frame(width: 380)
        .onAppear { focused = true }
        .interactiveDismissDisabled()
    }

    private var isSMS: Bool {
        if case .twoFactor(let method, _) = prompt.kind { return method == "sms" }
        return false
    }

    private var phones: [(id: Int, lastTwo: String)] {
        if case .twoFactor(_, let phones) = prompt.kind { return phones }
        return []
    }
}

struct RoundedFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.secondary.opacity(0.2)))
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let activity = model.activity {
            Text("\(activity.title) — \(Int(activity.percent))%")
            Divider()
        }

        if model.devices.isEmpty {
            Text("No devices connected")
        } else {
            ForEach(model.devices) { d in
                Text("\(d.name) · \(d.isWireless ? "Wi-Fi" : "USB")")
            }
        }

        if !model.trackedApps.isEmpty {
            Divider()
            ForEach(model.trackedApps.prefix(8)) { app in
                Button("\(app.name) — \(app.isExpired ? "expired" : "\(app.daysLeft ?? 0) d")") {
                    Task { await model.refresh(app) }
                }
                .disabled(!model.isConnected(app.deviceUDID) || model.isBusy)
            }
        }

        Divider()
        Button("Open GatePass") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

import SwiftUI

struct AuthFormValues: Equatable {
    var usernameOrEmail = ""
    var username = ""
    var email = ""
    var password = ""

    var trimmedUsernameOrEmail: String {
        usernameOrEmail.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isEmailValid: Bool {
        let parts = trimmedEmail.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
    }

    var isRegistrationPasswordValid: Bool {
        password.count >= 8
    }

    func canSubmit(mode: AuthView.Mode) -> Bool {
        switch mode {
        case .login:
            !trimmedUsernameOrEmail.isEmpty && !password.isEmpty
        case .register:
            !trimmedUsername.isEmpty && isEmailValid && isRegistrationPasswordValid
        }
    }
}

struct AuthView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case login
        case register

        var id: String { rawValue }

        var title: String {
            switch self {
            case .login: "Welcome back"
            case .register: "Create your account"
            }
        }

        var subtitle: String {
            switch self {
            case .login: "Pick up where you left off."
            case .register: "Start tracking everything you watch, read, and play."
            }
        }

        var actionTitle: String {
            switch self {
            case .login: "Sign in"
            case .register: "Create account"
            }
        }

        var alternate: Mode {
            self == .login ? .register : .login
        }

        var alternatePrompt: String {
            switch self {
            case .login: "New to Spine?"
            case .register: "Already have an account?"
            }
        }

        var alternateAction: String {
            switch self {
            case .login: "Create account"
            case .register: "Sign in"
            }
        }
    }

    private enum Field: Hashable {
        case usernameOrEmail
        case username
        case email
        case password
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let session: AppSession

    @State private var mode: Mode
    @State private var form = AuthFormValues()
    @State private var isPasswordVisible = false
    @State private var isSubmitting = false
    @FocusState private var focusedField: Field?
    @AccessibilityFocusState private var isErrorFocused: Bool

    init(session: AppSession, initialMode: Mode = .login) {
        self.session = session
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    SpineWordmark()

                    Spacer(minLength: 42)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(mode.title)
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .tracking(-0.7)

                        Text(mode.subtitle)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.58))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .spineContentTransition(value: "header-\(mode.rawValue)")

                    Spacer(minLength: 30)

                    credentialFields
                        .spineContentTransition(value: "fields-\(mode.rawValue)")

                    registrationGuidance

                    if let error = session.errorMessage {
                        AuthErrorBanner(message: error)
                            .padding(.top, 16)
                            .accessibilityFocused($isErrorFocused)
                    }

                    Spacer(minLength: 24)

                    Button {
                        Task { await submit() }
                    } label: {
                        Group {
                            if isSubmitting {
                                ProgressView()
                                    .tint(.black)
                                    .accessibilityLabel(mode == .login ? "Signing in" : "Creating account")
                            } else {
                                Text(mode.actionTitle)
                            }
                        }
                        .font(.headline)
                        .foregroundStyle(canSubmit && !isSubmitting ? .black : .white.opacity(0.42))
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .spineContentTransition(value: isSubmitting)
                    }
                    .tint(canSubmit && !isSubmitting ? .white : .white.opacity(0.08))
                    .buttonStyle(.glassProminent)
                    .disabled(!canSubmit || isSubmitting)
                    .accessibilityIdentifier("auth.submit")
                    .accessibilityHint(canSubmit ? "" : disabledActionHint)

                    Button(action: switchMode) {
                        HStack(spacing: 5) {
                            Text(mode.alternatePrompt)
                                .foregroundStyle(.white.opacity(0.52))
                            Text(mode.alternateAction)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                        }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                    .accessibilityLabel("\(mode.alternatePrompt) \(mode.alternateAction)")
                    .accessibilityIdentifier("auth.switchMode")
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 28)
                .frame(minHeight: proxy.size.height, alignment: .top)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(OnboardingBackdrop())
        .disabled(isSubmitting)
        .onChange(of: form) {
            session.clearError()
        }
        .onChange(of: session.errorMessage) {
            isErrorFocused = session.errorMessage != nil
        }
        .onAppear {
            isErrorFocused = session.errorMessage != nil
        }
    }

    @ViewBuilder
    private var credentialFields: some View {
        VStack(spacing: 12) {
            if mode == .login {
                AuthField(
                    systemName: "person.fill",
                    isFocused: focusedField == .usernameOrEmail
                ) {
                    TextField("Username or email", text: $form.usernameOrEmail)
                        .focused($focusedField, equals: .usernameOrEmail)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                        .accessibilityIdentifier("auth.usernameOrEmail")
                }
            } else {
                AuthField(
                    systemName: "at",
                    isFocused: focusedField == .username
                ) {
                    TextField("Username", text: $form.username)
                        .focused($focusedField, equals: .username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .onSubmit { focusedField = .email }
                        .accessibilityIdentifier("auth.username")
                }

                AuthField(
                    systemName: "envelope.fill",
                    isFocused: focusedField == .email,
                    showsError: !form.trimmedEmail.isEmpty && !form.isEmailValid
                ) {
                    TextField("Email", text: $form.email)
                        .focused($focusedField, equals: .email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                        .accessibilityIdentifier("auth.email")
                }
            }

            AuthField(
                systemName: "lock.fill",
                isFocused: focusedField == .password
            ) {
                HStack(spacing: 10) {
                    passwordInput

                    Button {
                        isPasswordVisible.toggle()
                        Task { @MainActor in
                            await Task.yield()
                            focusedField = .password
                        }
                    } label: {
                        Image(systemName: isPasswordVisible ? "eye.slash.fill" : "eye.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.48))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isPasswordVisible ? "Hide password" : "Show password")
                    .accessibilityIdentifier("auth.passwordVisibility")
                }
            }
        }
        .disabled(isSubmitting)
    }

    @ViewBuilder
    private var passwordInput: some View {
        Group {
            if isPasswordVisible {
                TextField("Password", text: $form.password)
            } else {
                SecureField("Password", text: $form.password)
            }
        }
        .focused($focusedField, equals: .password)
        .textContentType(mode == .login ? .password : .newPassword)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .submitLabel(.go)
        .onSubmit { Task { await submit() } }
        .accessibilityIdentifier("auth.password")
    }

    @ViewBuilder
    private var registrationGuidance: some View {
        if mode == .register {
            VStack(alignment: .leading, spacing: 7) {
                AuthValidationRow(
                    text: "Use at least 8 characters",
                    isSatisfied: form.isRegistrationPasswordValid
                )

                if !form.trimmedEmail.isEmpty && !form.isEmailValid {
                    Label("Enter a valid email address", systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .transition(.opacity)
                }
            }
            .padding(.top, 12)
            .animation(SpineMotion.animation(reduceMotion: reduceMotion), value: form.isEmailValid)
        }
    }

    private var canSubmit: Bool {
        form.canSubmit(mode: mode)
    }

    private var disabledActionHint: String {
        switch mode {
        case .login:
            "Enter your username or email and password."
        case .register:
            "Enter a username, valid email, and a password with at least 8 characters."
        }
    }

    private func switchMode() {
        focusedField = nil
        session.clearError()
        isPasswordVisible = false
        withAnimation(SpineMotion.animation(reduceMotion: reduceMotion)) {
            mode = mode.alternate
        }
    }

    private func submit() async {
        guard canSubmit, !isSubmitting else { return }
        focusedField = nil
        isSubmitting = true
        defer { isSubmitting = false }

        switch mode {
        case .login:
            await session.login(
                usernameOrEmail: form.trimmedUsernameOrEmail,
                password: form.password
            )
        case .register:
            await session.register(
                username: form.trimmedUsername,
                email: form.trimmedEmail,
                password: form.password
            )
        }
    }
}

private struct AuthField<Content: View>: View {
    let systemName: String
    let isFocused: Bool
    var showsError = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(showsError ? .orange : .white.opacity(0.42))
                .frame(width: 20)
                .accessibilityHidden(true)

            content()
                .font(.body)
                .foregroundStyle(.white)
                .tint(.white)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(borderColor, lineWidth: isFocused || showsError ? 1.25 : 0.75)
        }
    }

    private var borderColor: Color {
        if showsError { return .orange.opacity(0.8) }
        return .white.opacity(isFocused ? 0.34 : 0.10)
    }
}

private struct AuthValidationRow: View {
    let text: String
    let isSatisfied: Bool

    var body: some View {
        Label(text, systemImage: isSatisfied ? "checkmark.circle.fill" : "circle")
            .font(.caption)
            .foregroundStyle(isSatisfied ? .green : .white.opacity(0.44))
            .contentTransition(.symbolEffect(.replace))
            .accessibilityValue(isSatisfied ? "Satisfied" : "Not satisfied")
    }
}

private struct AuthErrorBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.red.opacity(0.9))
                .accessibilityHidden(true)

            Text(message)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.red.opacity(0.24), lineWidth: 0.75)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Authentication error. \(message)")
    }
}

#Preview("Sign in") {
    AuthView(session: AppSession(repositories: .live()))
}

#Preview("Create account") {
    AuthView(session: AppSession(repositories: .live()), initialMode: .register)
}

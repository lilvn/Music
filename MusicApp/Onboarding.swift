import SwiftUI

/// First-launch sign-in: enter a server + username + password. On success the credentials persist and
/// the app switches to the library. Liquid-Glass fields over a soft aura; nothing is baked into the app.
struct LoginView: View {
    @Environment(JellyfinClient.self) private var client
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case server, username, password }

    private var canSubmit: Bool {
        !server.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Sign In")
                        .font(.largeTitle).fontWeight(.bold)
                    Text("Enter your server and account details.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.bottom, 28)

                GlassEffectContainer(spacing: 14) {
                    VStack(spacing: 14) {
                        glassField {
                            TextField("Server address", text: $server)
                                .textContentType(.URL)
                                .keyboardType(.URL)
                                .submitLabel(.next)
                                .focused($focus, equals: .server)
                                .onSubmit { focus = .username }
                        }
                        glassField {
                            TextField("Username", text: $username)
                                .textContentType(.username)
                                .submitLabel(.next)
                                .focused($focus, equals: .username)
                                .onSubmit { focus = .password }
                        }
                        glassField {
                            SecureField("Password", text: $password)
                                .textContentType(.password)
                                .submitLabel(.go)
                                .focused($focus, equals: .password)
                                .onSubmit { if canSubmit { login() } }
                        }
                    }
                }
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.body)

                if let error {
                    Text(error)
                        .font(.footnote).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 16)
                        .transition(.opacity)
                }

                signInButton
                    .padding(.top, 22)

                Spacer()
                Spacer()
            }
            .padding(.horizontal, 28)
        }
    }

    /// A text field floating on a Liquid-Glass rounded rect.
    private func glassField<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .frame(height: 54)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private var signInButton: some View {
        Button(action: login) {
            Group {
                if isLoading { ProgressView().tint(Color(.systemBackground)) }
                else { Text("Continue").fontWeight(.semibold) }
            }
            .frame(maxWidth: .infinity).frame(height: 54)
            .foregroundStyle(canSubmit ? AnyShapeStyle(Color(.systemBackground)) : AnyShapeStyle(.secondary))
            .glassEffect(canSubmit ? .regular.tint(.primary).interactive()
                                   : .regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit || isLoading)
    }

    private func login() {
        isLoading = true
        error = nil
        Task {
            do {
                try await client.authenticate(server: server, username: username, password: password)
            } catch {
                self.error = "Couldn't sign in. Check the server address and your credentials."
            }
            isLoading = false
        }
    }
}

/// Server management — view the connected server and sign out.
struct SettingsView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    LabeledContent("Address", value: client.serverURL)
                    LabeledContent("User", value: client.username)
                }
                Section {
                    Button("Sign Out", role: .destructive) {
                        player.stop()
                        client.signOut()
                        dismiss()
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

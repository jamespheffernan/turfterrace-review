import SwiftUI

struct SettingsView: View {
  let onSave: (APIConfiguration) async -> Bool
  private let configuration: APIConfiguration

  @Environment(\.dismiss) private var dismiss
  @State private var serverURL: String
  @State private var username: String
  @State private var password: String
  @State private var isSaving = false
  @State private var saveError: String?

  init(configuration: APIConfiguration, onSave: @escaping (APIConfiguration) async -> Bool) {
    self.configuration = configuration
    self.onSave = onSave
    _serverURL = State(initialValue: configuration.serverURL.absoluteString)
    _username = State(initialValue: configuration.username)
    _password = State(initialValue: configuration.password)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Server") {
          TextField("https://review.turfterrace.com", text: $serverURL)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .autocorrectionDisabled()
            #endif
            .disabled(isSaving)
          if let urlMessage {
            Text(urlMessage)
              .font(TurfType.meta)
              .foregroundStyle(TurfTheme.destructive)
          }
        }

        Section("Turf Review account") {
          TextField("Username", text: $username)
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
            .disabled(isSaving)
          SecureField("Password", text: $password)
            .disabled(isSaving)
          Text("Credentials are stored securely and used only to renew the signed Turf Review session.")
            .font(.caption)
            .foregroundStyle(TurfTheme.muted)
          if configuration.hasCredentials {
            Button("Sign Out", role: .destructive) {
              Task { await signOut() }
            }
            .foregroundStyle(TurfTheme.destructive)
            .disabled(isSaving)
          }
          if let saveError {
            Text(saveError)
              .font(TurfType.meta)
              .foregroundStyle(TurfTheme.destructive)
          }
        }
      }
      .navigationTitle("Turf Review")
      .turfInlineNavigationTitle()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            Task { await save() }
          } label: {
            if isSaving {
              ProgressView()
            } else {
              Text("Save")
            }
          }
          .disabled(parsedServerURL == nil || isSaving)
        }
      }
    }
  }

  private var parsedServerURL: URL? {
    APIConfiguration.normalizedServerURL(from: serverURL)
  }

  private var urlMessage: String? {
    parsedServerURL == nil ? "Enter an http or https server URL." : nil
  }

  private func save() async {
    guard let url = parsedServerURL else { return }
    await persist(APIConfiguration(
      serverURL: url,
      username: username,
      password: password,
      useDemoOnFailure: false
    ))
  }

  private func signOut() async {
    await persist(APIConfiguration(
      serverURL: configuration.serverURL,
      username: "",
      password: "",
      useDemoOnFailure: false
    ))
  }

  private func persist(_ newConfiguration: APIConfiguration) async {
    guard !isSaving else { return }
    saveError = nil
    isSaving = true
    let didSave = await onSave(newConfiguration)
    isSaving = false

    if didSave {
      dismiss()
    } else {
      saveError = "Couldn’t update secure sign-in storage. Your existing settings are unchanged. Try again."
    }
  }
}

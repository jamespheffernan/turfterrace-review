import SwiftUI

struct SettingsView: View {
  let onSave: (APIConfiguration) async -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var serverURL: String
  @State private var username: String
  @State private var password: String
  @State private var useDemoOnFailure: Bool
  @State private var isSaving = false

  init(configuration: APIConfiguration, onSave: @escaping (APIConfiguration) async -> Void) {
    self.onSave = onSave
    _serverURL = State(initialValue: configuration.serverURL.absoluteString)
    _username = State(initialValue: configuration.username)
    _password = State(initialValue: configuration.password)
    _useDemoOnFailure = State(initialValue: configuration.useDemoOnFailure)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Server") {
          TextField("http://localhost:3457", text: $serverURL)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .autocorrectionDisabled()
            .disabled(isSaving)
          Toggle("Use demo data if server fails", isOn: $useDemoOnFailure)
            .disabled(isSaving)
          if let urlMessage {
            Text(urlMessage)
              .font(.caption)
              .foregroundStyle(TurfTheme.coral)
          }
        }

        Section("Basic auth") {
          TextField("Username", text: $username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .disabled(isSaving)
          SecureField("Password", text: $password)
            .disabled(isSaving)
        }
      }
      .navigationTitle("Turf Review")
      .navigationBarTitleDisplayMode(.inline)
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
    guard let url = parsedServerURL, !isSaving else { return }
    isSaving = true
    await onSave(APIConfiguration(
      serverURL: url,
      username: username,
      password: password,
      useDemoOnFailure: useDemoOnFailure
    ))
    isSaving = false
  }
}

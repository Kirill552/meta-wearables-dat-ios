import Foundation
import Security
import SwiftUI

enum CameraAISettingsStore {
  enum TranslationVoice: String, CaseIterable, Identifiable {
    case gemini
    case ios

    var id: String { rawValue }
    var label: String { self == .gemini ? "Голос Gemini" : "Голос iPhone" }
  }

  static let defaultGatewayURL = "https://rayban-api.outlookpowertools.com"
  private static let urlKey = "cameraAI.gatewayURL"
  private static let translationVoiceKey = "cameraAI.translationVoice"
  private static let keychainService = "CameraAccess.Gateway"
  private static let keychainAccount = "accessToken"

  static var gatewayURLString: String {
    UserDefaults.standard.string(forKey: urlKey) ?? defaultGatewayURL
  }

  static var translationVoice: TranslationVoice {
    get { TranslationVoice(rawValue: UserDefaults.standard.string(forKey: translationVoiceKey) ?? "") ?? .gemini }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: translationVoiceKey) }
  }

  static var gatewayURL: URL? {
    guard let url = URL(string: gatewayURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
          url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
          url.query == nil, url.fragment == nil
    else { return nil }
    return url
  }

  static var accessToken: String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func save(urlString: String, token: String) -> Bool {
    let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmedURL), url.scheme == "https", url.host != nil,
          url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
    else { return false }

    let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedToken.isEmpty {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: keychainAccount,
      ]
      let attributes: [String: Any] = [
        kSecValueData as String: Data(trimmedToken.utf8),
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      ]
      let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
      if status == errSecItemNotFound {
        var newItem = query
        attributes.forEach { newItem[$0.key] = $0.value }
        guard SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess else { return false }
      } else if status != errSecSuccess {
        return false
      }
    }
    UserDefaults.standard.set(url.absoluteString, forKey: urlKey)
    return true
  }
}

struct CameraAISettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var gatewayURL = CameraAISettingsStore.gatewayURLString
  @State private var accessToken = ""
  @State private var translationVoice = CameraAISettingsStore.translationVoice
  @State private var message = ""

  var body: some View {
    NavigationStack {
      Form {
        Section("Gateway") {
          TextField("Gateway URL", text: $gatewayURL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
          SecureField("Gateway access token", text: $accessToken)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          Text("Оставьте поле токена пустым, чтобы сохранить уже введённый токен.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        Section("Переводчик") {
          Picker("Голос", selection: $translationVoice) {
            ForEach(CameraAISettingsStore.TranslationVoice.allCases) { voice in
              Text(voice.label).tag(voice)
            }
          }
          Text("Gemini звучит естественнее; если звук не слышен в очках, выберите голос iPhone.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        if !message.isEmpty {
          Text(message).foregroundStyle(.red)
        }
      }
      .navigationTitle("AI Settings")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Отмена") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Сохранить") {
            if CameraAISettingsStore.save(urlString: gatewayURL, token: accessToken) {
              CameraAISettingsStore.translationVoice = translationVoice
              dismiss()
            } else {
              message = "Проверьте HTTPS URL или доступ к Keychain."
            }
          }
        }
      }
    }
  }
}

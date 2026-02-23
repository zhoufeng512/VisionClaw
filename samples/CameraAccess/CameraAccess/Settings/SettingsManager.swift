import Foundation

final class SettingsManager {
  static let shared = SettingsManager()

  private let defaults = UserDefaults.standard

  private enum Key: String {
    case doubaoAppId
    case doubaoAccessKey
    case doubaoAppKey
    case doubaoResourceId
    case openClawHost
    case openClawPort
    case openClawHookToken
    case openClawGatewayToken
    case geminiSystemPrompt
    case webrtcSignalingURL
  }

  private init() {}

  // MARK: - Doubao Realtime

  var doubaoAppId: String {
    get { defaults.string(forKey: Key.doubaoAppId.rawValue) ?? Secrets.doubaoAppId }
    set { defaults.set(newValue, forKey: Key.doubaoAppId.rawValue) }
  }

  var doubaoAccessKey: String {
    get { defaults.string(forKey: Key.doubaoAccessKey.rawValue) ?? Secrets.doubaoAccessKey }
    set { defaults.set(newValue, forKey: Key.doubaoAccessKey.rawValue) }
  }

  var doubaoAppKey: String {
    get { defaults.string(forKey: Key.doubaoAppKey.rawValue) ?? Secrets.doubaoAppKey }
    set { defaults.set(newValue, forKey: Key.doubaoAppKey.rawValue) }
  }

  var doubaoResourceId: String {
    get { defaults.string(forKey: Key.doubaoResourceId.rawValue) ?? Secrets.doubaoResourceId }
    set { defaults.set(newValue, forKey: Key.doubaoResourceId.rawValue) }
  }

  var geminiSystemPrompt: String {
    get { defaults.string(forKey: Key.geminiSystemPrompt.rawValue) ?? GeminiConfig.defaultSystemInstruction }
    set { defaults.set(newValue, forKey: Key.geminiSystemPrompt.rawValue) }
  }

  // MARK: - OpenClaw

  var openClawHost: String {
    get { defaults.string(forKey: Key.openClawHost.rawValue) ?? Secrets.openClawHost }
    set { defaults.set(newValue, forKey: Key.openClawHost.rawValue) }
  }

  var openClawPort: Int {
    get {
      let stored = defaults.integer(forKey: Key.openClawPort.rawValue)
      return stored != 0 ? stored : Secrets.openClawPort
    }
    set { defaults.set(newValue, forKey: Key.openClawPort.rawValue) }
  }

  var openClawHookToken: String {
    get { defaults.string(forKey: Key.openClawHookToken.rawValue) ?? Secrets.openClawHookToken }
    set { defaults.set(newValue, forKey: Key.openClawHookToken.rawValue) }
  }

  var openClawGatewayToken: String {
    get { defaults.string(forKey: Key.openClawGatewayToken.rawValue) ?? Secrets.openClawGatewayToken }
    set { defaults.set(newValue, forKey: Key.openClawGatewayToken.rawValue) }
  }

  // MARK: - WebRTC

  var webrtcSignalingURL: String {
    get { defaults.string(forKey: Key.webrtcSignalingURL.rawValue) ?? Secrets.webrtcSignalingURL }
    set { defaults.set(newValue, forKey: Key.webrtcSignalingURL.rawValue) }
  }

  // MARK: - Reset

  func resetAll() {
    for key in [Key.doubaoAppId, .doubaoAccessKey, .doubaoAppKey, .doubaoResourceId, .geminiSystemPrompt, .openClawHost, .openClawPort,
                .openClawHookToken, .openClawGatewayToken, .webrtcSignalingURL] {
      defaults.removeObject(forKey: key.rawValue)
    }
  }
}

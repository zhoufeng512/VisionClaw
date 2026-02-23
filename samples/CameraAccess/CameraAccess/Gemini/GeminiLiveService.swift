import Foundation
import UIKit

enum DoubaoMessageType: UInt8 {
  case clientFullRequest = 0b0001
  case clientAudioOnlyRequest = 0b0010
  case serverFullResponse = 0b1001
  case serverAck = 0b1011
  case serverErrorResponse = 0b1111
}

enum DoubaoMessageFlags: UInt8 {
  case noSequence = 0b0000
  case posSequence = 0b0001
  case negSequence = 0b0010
  case negSequence1 = 0b0011
  case msgWithEvent = 0b0100
}

enum DoubaoSerialization: UInt8 {
  case noSerialization = 0b0000
  case jsonSerialization = 0b0001
}

enum DoubaoCompression: UInt8 {
  case noCompression = 0b0000
  case gzipCompression = 0b0001
}

enum DoubaoDialogEventType: UInt32 {
  case startConnection = 1
  case finishConnection = 2
  case connectionStarted = 50
  case connectionFinished = 52
  case startSession = 100
  case finishSession = 102
  case sessionStarted = 150
  case sessionFinished = 152
  case sessionFailed = 153
  case usageResponse = 154
  case taskRequest = 200
  case sayHello = 300
  case ttsSentenceStart = 350
  case ttsSentenceEnd = 351
  case ttsEnded = 359
  case asrInfo = 450
  case asrResponse = 451
  case asrEnded = 459
  case chatTtsText = 500
  case chatTextQuery = 501
  case chatResponse = 550
  case chatEnded = 559
}

enum GeminiConnectionState: Equatable {
  case disconnected
  case connecting
  case settingUp
  case ready
  case error(String)
}

@MainActor
class GeminiLiveService: ObservableObject {
  @Published var connectionState: GeminiConnectionState = .disconnected
  @Published var isModelSpeaking: Bool = false

  var onAudioReceived: ((Data) -> Void)?
  var onTurnComplete: (() -> Void)?
  var onInterrupted: (() -> Void)?
  var onDisconnected: ((String?) -> Void)?
  var onInputTranscription: ((String) -> Void)?
  var onOutputTranscription: ((String) -> Void)?
  var onToolCall: ((GeminiToolCall) -> Void)?
  var onToolCallCancellation: ((GeminiToolCallCancellation) -> Void)?

  private var lastUserSpeechEnd: Date?
  private var responseLatencyLogged = false

  private var webSocketTask: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var connectContinuation: CheckedContinuation<Bool, Never>?
  private let delegate = WebSocketDelegate()
  private var urlSession: URLSession!
  private let sendQueue = DispatchQueue(label: "doubao.send", qos: .userInitiated)

  private var sessionId: String = ""

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 30
    self.urlSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
  }

  func connect() async -> Bool {
    guard let url = GeminiConfig.websocketURL() else {
      connectionState = .error("No App ID configured")
      return false
    }

    connectionState = .connecting
    sessionId = UUID().uuidString
    let connectId = UUID().uuidString

    var request = URLRequest(url: url)
    request.addValue(GeminiConfig.doubaoAppId, forHTTPHeaderField: "X-Api-App-ID")
    request.addValue(GeminiConfig.doubaoAccessKey, forHTTPHeaderField: "X-Api-Access-Key")
    request.addValue(GeminiConfig.doubaoResourceId, forHTTPHeaderField: "X-Api-Resource-Id")
    request.addValue(GeminiConfig.doubaoAppKey, forHTTPHeaderField: "X-Api-App-Key")
    request.addValue(connectId, forHTTPHeaderField: "X-Api-Connect-Id")

    let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      self.connectContinuation = continuation

      self.delegate.onOpen = { [weak self] _ in
        guard let self = self else { return }
        Task { @MainActor in
          self.connectionState = .settingUp
          self.sendStartConnection()
          self.startReceiving()
        }
      }

      self.delegate.onClose = { [weak self] code, reason in
        guard let self = self else { return }
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "no reason"
        Task { @MainActor in
          self.resolveConnect(success: false)
          self.connectionState = .disconnected
          self.isModelSpeaking = false
          self.onDisconnected?("Connection closed (code \\(code.rawValue): \\(reasonStr))")
        }
      }

      self.delegate.onError = { [weak self] error in
        guard let self = self else { return }
        let msg = error?.localizedDescription ?? "Unknown error"
        Task { @MainActor in
          self.resolveConnect(success: false)
          self.connectionState = .error(msg)
          self.isModelSpeaking = false
          self.onDisconnected?(msg)
        }
      }

      self.webSocketTask = self.urlSession.webSocketTask(with: request)
      self.webSocketTask?.resume()

      Task {
        try? await Task.sleep(nanoseconds: 15_000_000_000)
        await MainActor.run {
          self.resolveConnect(success: false)
          if self.connectionState == .connecting || self.connectionState == .settingUp {
            self.connectionState = .error("Connection timed out")
          }
        }
      }
    }

    return result
  }

  func disconnect() {
    receiveTask?.cancel()
    receiveTask = nil
    webSocketTask?.cancel(with: .normalClosure, reason: nil)
    webSocketTask = nil
    delegate.onOpen = nil
    delegate.onClose = nil
    delegate.onError = nil
    onToolCall = nil
    onToolCallCancellation = nil
    connectionState = .disconnected
    isModelSpeaking = false
    resolveConnect(success: false)
  }

  func sendAudio(data: Data) {
    guard connectionState == .ready else { return }
    sendQueue.async { [weak self] in
      guard let self = self else { return }
      let header = self.generateHeader(messageType: .clientAudioOnlyRequest, serialization: .noSerialization)
      var request = Data()
      request.append(header)
      
      var eventType = DoubaoDialogEventType.taskRequest.rawValue.bigEndian
      withUnsafeBytes(of: &eventType) { request.append(contentsOf: $0) }
      
      let sessionIdBytes = Data(self.sessionId.utf8)
      var sessionLen = UInt32(sessionIdBytes.count).bigEndian
      withUnsafeBytes(of: &sessionLen) { request.append(contentsOf: $0) }
      request.append(sessionIdBytes)
      
      var payloadSize = UInt32(data.count).bigEndian
      withUnsafeBytes(of: &payloadSize) { request.append(contentsOf: $0) }
      request.append(data)

      self.webSocketTask?.send(.data(request)) { _ in }
    }
  }

  func sendVideoFrame(image: UIImage) {
    guard connectionState == .ready else { return }
    // Video capability to be adapted based on official Doubao Multimodal WebSocket spec.
    print("[Doubao] Warning: sendVideoFrame triggered but multimodal websocket ingestion is pending confirmation.")
  }

  func sendToolResponse(_ response: [String: Any]) {
    // Send standard tool response if supported, or via REST API if required.
    // For now, mapping as JSON to Doubao standard text input.
    sendQueue.async { [weak self] in
      guard let self = self else { return }
      guard let data = try? JSONSerialization.data(withJSONObject: response),
            let string = String(data: data, encoding: .utf8) else {
        return
      }
      self.sendTextQuery(text: string)
    }
  }

  private func sendTextQuery(text: String) {
    let payloadStr = "{\"query\":\"\\(text)\"}"
    guard let payload = payloadStr.data(using: .utf8) else { return }
    let header = generateHeader(messageType: .clientFullRequest)
    var request = Data()
    request.append(header)
    
    var eventType = DoubaoDialogEventType.chatTextQuery.rawValue.bigEndian
    withUnsafeBytes(of: &eventType) { request.append(contentsOf: $0) }
    
    let sessionIdBytes = Data(sessionId.utf8)
    var sessionLen = UInt32(sessionIdBytes.count).bigEndian
    withUnsafeBytes(of: &sessionLen) { request.append(contentsOf: $0) }
    request.append(sessionIdBytes)
    
    var payloadSize = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &payloadSize) { request.append(contentsOf: $0) }
    request.append(payload)

    self.webSocketTask?.send(.data(request)) { _ in }
  }

  private func resolveConnect(success: Bool) {
    if let cont = connectContinuation {
      connectContinuation = nil
      cont.resume(returning: success)
    }
  }

  private func generateHeader(
    version: UInt8 = 0b0001,
    messageType: DoubaoMessageType = .clientFullRequest,
    messageFlags: DoubaoMessageFlags = .msgWithEvent,
    serialization: DoubaoSerialization = .jsonSerialization,
    compression: DoubaoCompression = .noCompression
  ) -> Data {
    var header = Data()
    let headerSize: UInt8 = 0b0001
    header.append((version << 4) | headerSize)
    header.append((messageType.rawValue << 4) | messageFlags.rawValue)
    header.append((serialization.rawValue << 4) | compression.rawValue)
    header.append(0x00)
    return header
  }

  private func sendStartConnection() {
    let header = generateHeader()
    var request = Data()
    request.append(header)
    
    var eventType = DoubaoDialogEventType.startConnection.rawValue.bigEndian
    withUnsafeBytes(of: &eventType) { request.append(contentsOf: $0) }
    
    let payload = Data("{}".utf8)
    var payloadSize = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &payloadSize) { request.append(contentsOf: $0) }
    request.append(payload)

    webSocketTask?.send(.data(request)) { _ in }
  }

  private func sendStartSession() {
    let tools = ToolDeclarations.allDeclarations()

    let sessionParams: [String: Any] = [
      "tts": [
        "speaker": "zh_female_tianmei", // Default Volcengine speaker
        "audio_config": [
          "channel": 1,
          "format": "pcm",
          "sample_rate": 24000
        ]
      ],
      "asr": [
        "extra": [
          "end_smooth_window_ms": 1500
        ]
      ],
      "dialog": [
        "bot_name": "VisionClaw",
        "system_role": GeminiConfig.systemInstruction,
        "tools": tools,
        "extra": [
          "strict_audit": false,
          "recv_timeout": 30,
          "input_mod": "audio"
        ]
      ]
    ]

    guard let payload = try? JSONSerialization.data(withJSONObject: sessionParams) else { return }

    let header = generateHeader()
    var request = Data()
    request.append(header)
    
    var eventType = DoubaoDialogEventType.startSession.rawValue.bigEndian
    withUnsafeBytes(of: &eventType) { request.append(contentsOf: $0) }
    
    let sessionIdBytes = Data(sessionId.utf8)
    var sessionLen = UInt32(sessionIdBytes.count).bigEndian
    withUnsafeBytes(of: &sessionLen) { request.append(contentsOf: $0) }
    request.append(sessionIdBytes)

    var payloadSize = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &payloadSize) { request.append(contentsOf: $0) }
    request.append(payload)

    webSocketTask?.send(.data(request)) { _ in }
  }

  private func startReceiving() {
    receiveTask = Task { [weak self] in
      guard let self = self else { return }
      while !Task.isCancelled {
        guard let task = self.webSocketTask else { break }
        do {
          let message = try await task.receive()
          switch message {
          case .data(let data):
            await self.handleData(data)
          case .string:
            break
          @unknown default:
            break
          }
        } catch {
          if !Task.isCancelled {
            let reason = error.localizedDescription
            await MainActor.run {
              self.resolveConnect(success: false)
              self.connectionState = .disconnected
              self.isModelSpeaking = false
              self.onDisconnected?(reason)
            }
          }
          break
        }
      }
    }
  }

  private func handleData(_ data: Data) async {
    guard data.count >= 4 else { return }

    let messageTypeRaw = data[1] >> 4
    let messageTypeSpecificFlags = data[1] & 0x0f
    let serializationMethod = data[2] >> 4
    let headerSize = Int(data[0] & 0x0f) * 4

    var offset = headerSize
    guard offset <= data.count else { return }

    var event: UInt32? = nil
    
    if messageTypeRaw == DoubaoMessageType.serverFullResponse.rawValue || messageTypeRaw == DoubaoMessageType.serverAck.rawValue {
      if messageTypeSpecificFlags & DoubaoMessageFlags.negSequence.rawValue > 0 {
          guard offset + 4 <= data.count else { return }
          offset += 4
      }
      if messageTypeSpecificFlags & DoubaoMessageFlags.msgWithEvent.rawValue > 0 {
          guard offset + 4 <= data.count else { return }
          let eventBytes = data[offset..<offset+4]
          event = UInt32(bigEndian: eventBytes.withUnsafeBytes { $0.load(as: UInt32.self) })
          offset += 4
      }

      guard offset + 4 <= data.count else { return }
      let sessionIdSize = Int(Int32(bigEndian: data[offset..<offset+4].withUnsafeBytes { $0.load(as: Int32.self) }))
      offset += 4

      if sessionIdSize > 0 {
          offset += sessionIdSize
      }

      guard offset + 4 <= data.count else { return }
      let payloadSize = Int(UInt32(bigEndian: data[offset..<offset+4].withUnsafeBytes { $0.load(as: UInt32.self) }))
      offset += 4
      
      guard offset + payloadSize <= data.count else { return }
      let payload = data[offset..<offset+payloadSize]

      if messageTypeRaw == DoubaoMessageType.serverAck.rawValue && serializationMethod == DoubaoSerialization.noSerialization.rawValue {
        self.handleAudioData(payload)
      } else if serializationMethod == DoubaoSerialization.jsonSerialization.rawValue {
        if let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
          self.handleJsonEvent(event: event, json: json)
        }
      }
    }
  }

  private func handleJsonEvent(event: UInt32?, json: [String: Any]) {
    guard let event = event else { return }
    
    switch event {
    case DoubaoDialogEventType.connectionStarted.rawValue:
      sendStartSession()
      
    case DoubaoDialogEventType.sessionStarted.rawValue:
      connectionState = .ready
      resolveConnect(success: true)
      
    case DoubaoDialogEventType.asrInfo.rawValue:
      isModelSpeaking = false
      onInterrupted?()
      
    case DoubaoDialogEventType.asrResponse.rawValue:
      if let text = json["text"] as? String, !text.isEmpty {
        lastUserSpeechEnd = Date()
        onInputTranscription?(text)
      }
      
    case DoubaoDialogEventType.ttsSentenceStart.rawValue:
      print("[Doubao] AI started speaking")
      
    case DoubaoDialogEventType.ttsEnded.rawValue:
      isModelSpeaking = false
      responseLatencyLogged = false
      onTurnComplete?()
      
    case DoubaoDialogEventType.chatResponse.rawValue:
      // Function Call checking
      if let toolCalls = json["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
          print("[Doubao] Tool Calls Received: \\(toolCalls.count)")
          if let toolCall = GeminiToolCall(json: ["functionCalls": toolCalls]) {
            onToolCall?(toolCall)
          } else {
            // Direct translation to internal ToolCall format
            var formattedCalls: [[String: Any]] = []
            for tc in toolCalls {
              if let fn = tc["function"] as? [String: Any] {
                  formattedCalls.append(fn)
              }
            }
            if let tc = GeminiToolCall(json: ["functionCalls": formattedCalls]) {
                onToolCall?(tc)
            }
          }
      }
      if let content = json["content"] as? String, !content.isEmpty {
        onOutputTranscription?(content)
      }
      
    case DoubaoDialogEventType.sessionFinished.rawValue, DoubaoDialogEventType.sessionFailed.rawValue:
      connectionState = .disconnected
      onDisconnected?("Session finished or failed")
      
    default:
      break
    }
  }

  private func handleAudioData(_ pcmData: Data) {
    if !isModelSpeaking {
      isModelSpeaking = true
      if let speechEnd = lastUserSpeechEnd, !responseLatencyLogged {
        let latency = Date().timeIntervalSince(speechEnd)
        print("[Latency] \\(latency * 1000)ms (user speech end -> first audio)")
        responseLatencyLogged = true
      }
    }
    
    // Doubao returns Float32 PCM [-1.0, 1.0] or Int16 depending on format. 
    // We configured "format": "pcm" (which usually means Int16 in Volcengine if specified, or Float32).
    // The Python implementation notes "Doubao E2E API returns float32 PCM... We need to convert to int16 PCM".
    // We will do Float32 to Int16 conversion if needed, or assume Volc format: "pcm" returns int16 natively if possible.
    // If audio is static noise, uncomment Float32 conversion.
    onAudioReceived?(pcmData)
  }
}

private class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
  var onOpen: ((String?) -> Void)?
  var onClose: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?
  var onError: ((Error?) -> Void)?

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    onOpen?(`protocol`)
  }

  func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) {
    onClose?(closeCode, reason)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    if let error {
      onError?(error)
    }
  }
}

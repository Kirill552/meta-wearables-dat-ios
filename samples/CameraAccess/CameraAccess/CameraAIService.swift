import AVFoundation
import Foundation
import Observation
import UIKit

// MARK: - Gateway and Live API models

private struct CameraAIEphemeralTokenResponse: Decodable {
  let token: String
  let model: String
  let expireTime: String?
  let newSessionExpireTime: String?
}

private enum CameraAIServiceError: Error {
  case notConfigured
  case invalidGateway
  case gatewayUnauthorized
  case gatewayUnavailable
  case gatewayInvalidResponse
  case liveConnection
  case liveSetup
  case liveResponse
  case noBluetoothInput
  case audioSession
  case audioPlayback
  case timedOut
  case cancelled
}

extension CameraAIServiceError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .notConfigured: return "Gateway not configured"
    case .invalidGateway: return "Gateway URL is invalid"
    case .gatewayUnauthorized: return "Gateway authorization failed"
    case .gatewayUnavailable: return "Gateway is unavailable"
    case .gatewayInvalidResponse: return "Gateway returned an invalid response"
    case .liveConnection: return "Gemini Live connection failed"
    case .liveSetup: return "Gemini Live setup failed"
    case .liveResponse: return "Gemini Live response failed"
    case .noBluetoothInput: return "Bluetooth HFP microphone is unavailable"
    case .audioSession: return "Bluetooth audio route could not be configured"
    case .audioPlayback: return "Gemini audio playback failed"
    case .timedOut: return "Gemini Live response timed out"
    case .cancelled: return "Request cancelled"
    }
  }
}

private enum CameraAILiveEvent {
  case setupComplete
  case outputText(String)
  case inputText(String)
  case audio(Data, mimeType: String)
  case turnComplete
  case interrupted
}

private struct CameraAILiveResponse {
  let transcript: String
}

/// The raw WebSocket client for the constrained Gemini Live endpoint.
///
/// Authentication is intentionally accepted only as an ephemeral token. The token is
/// never included in an error, log message, or public model. The WebSocket endpoint and
/// JSON field names match Google's v1beta BidiGenerateContentConstrained protocol.
@MainActor
private final class CameraAILiveSession {
  private let socketURL: URL
  private let model: String
  private let instruction: String
  private let onEvent: (CameraAILiveEvent) -> Void

  private var socket: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var setupContinuation: CheckedContinuation<Void, Error>?
  private var responseContinuation: CheckedContinuation<CameraAILiveResponse, Error>?
  private var setupTimeoutTask: Task<Void, Never>?
  private var responseTimeoutTask: Task<Void, Never>?
  private var responseTranscript = ""
  private var suppressResponseEvents = false
  private var isClosing = false

  init(
    token: String,
    model: String,
    instruction: String,
    onEvent: @escaping (CameraAILiveEvent) -> Void
  ) throws {
    guard !token.isEmpty else { throw CameraAIServiceError.liveConnection }
    var components = URLComponents()
    components.scheme = "wss"
    components.host = "generativelanguage.googleapis.com"
    components.path = "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained"
    components.queryItems = [URLQueryItem(name: "access_token", value: token)]
    guard let url = components.url else { throw CameraAIServiceError.liveConnection }
    self.socketURL = url
    self.model = model.hasPrefix("models/") ? model : "models/\(model)"
    self.instruction = instruction
    self.onEvent = onEvent
  }

  isolated deinit {
    receiveTask?.cancel()
    socket?.cancel(with: .goingAway, reason: nil)
  }

  func connect() async throws {
    guard socket == nil else { return }
    let task = URLSession.shared.webSocketTask(with: socketURL)
    socket = task
    task.resume()

    receiveTask = Task { @MainActor [weak self] in
      await self?.receiveLoop()
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      setupContinuation = continuation
      setupTimeoutTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(20))
        guard !Task.isCancelled else { return }
        self?.finishSetup(with: .failure(CameraAIServiceError.timedOut))
      }
      Task { @MainActor [weak self] in
        guard let self else { return }
        do {
          try await self.sendSetup()
        } catch {
          self.finishSetup(with: .failure(CameraAIServiceError.liveSetup))
        }
      }
    }
  }

  func sendVisualPrompt(text: String, jpegData: Data) async throws -> CameraAILiveResponse {
    guard socket != nil else { throw CameraAIServiceError.liveConnection }
    responseTranscript = ""

    // Keep the still image and its question in one Content turn. Live API does
    // not guarantee ordering across realtimeInput and clientContent streams.
    let textMessage: [String: Any] = [
      "clientContent": [
        "turns": [[
          "role": "user",
          "parts": [
            ["inlineData": ["mimeType": "image/jpeg", "data": jpegData.base64EncodedString()]],
            ["text": text],
          ],
        ]],
        "turnComplete": true,
      ],
    ]

    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CameraAILiveResponse, Error>) in
      responseContinuation = continuation
      responseTimeoutTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(45))
        guard !Task.isCancelled else { return }
        self?.finishResponse(with: .failure(CameraAIServiceError.timedOut))
      }
      Task { @MainActor [weak self] in
        do {
          guard let self else { throw CameraAIServiceError.liveConnection }
          try await self.sendJSON(textMessage)
        } catch {
          self?.finishResponse(with: .failure(CameraAIServiceError.liveResponse))
        }
      }
    }
  }

  func primeTranslation() async throws {
    responseTranscript = ""
    suppressResponseEvents = true
    let message: [String: Any] = [
      "clientContent": [
        "turns": [[
          "role": "user",
          "parts": [["text": "For every following spoken utterance in English, Sinhala or Tamil, output only its Russian translation. Never answer the speaker or add comments. Example: 'Hello, my name is Kirill' becomes 'Здравствуйте, меня зовут Кирилл'. Confirm this instruction briefly, then translate all subsequent speech."]],
        ]],
        "turnComplete": true,
      ],
    ]
    defer { suppressResponseEvents = false; responseTranscript = "" }
    _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CameraAILiveResponse, Error>) in
      responseContinuation = continuation
      responseTimeoutTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(30))
        guard !Task.isCancelled else { return }
        self?.finishResponse(with: .failure(CameraAIServiceError.timedOut))
      }
      Task { @MainActor [weak self] in
        do { try await self?.sendJSON(message) }
        catch { self?.finishResponse(with: .failure(CameraAIServiceError.liveResponse)) }
      }
    }
  }

  func sendAudio(_ data: Data) {
    guard !data.isEmpty, socket != nil, !isClosing else { return }
    let message: [String: Any] = [
      "realtimeInput": [
        "audio": [
          "data": data.base64EncodedString(),
          "mimeType": "audio/pcm;rate=16000",
        ],
      ],
    ]
    Task { @MainActor [weak self] in
      do {
        try await self?.sendJSON(message)
      } catch {
        // The receive loop reports a generic connection error to its owner. Do not expose
        // URLSession's description because it can contain the access-token URL.
      }
    }
  }

  func close() {
    guard !isClosing else { return }
    isClosing = true
    receiveTask?.cancel()
    receiveTask = nil
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    finishSetup(with: .failure(CameraAIServiceError.cancelled))
    finishResponse(with: .failure(CameraAIServiceError.cancelled))
  }

  private func sendSetup() async throws {
    let setup: [String: Any] = [
      "setup": [
        "model": model,
        // The constrained Live endpoint requires responseModalities inside
        // generationConfig. Native audio models also provide output transcription.
        "generationConfig": ["responseModalities": ["AUDIO"]],
        "systemInstruction": [
          "parts": [["text": instruction]],
        ],
        "outputAudioTranscription": [:],
        "inputAudioTranscription": [:],
      ],
    ]
    try await sendJSON(setup)
  }

  private func sendJSON(_ object: [String: Any]) async throws {
    guard let socket else { throw CameraAIServiceError.liveConnection }
    guard JSONSerialization.isValidJSONObject(object) else { throw CameraAIServiceError.liveResponse }
    let data = try JSONSerialization.data(withJSONObject: object, options: [])
    guard let string = String(data: data, encoding: .utf8) else { throw CameraAIServiceError.liveResponse }
    try await socket.send(.string(string))
  }

  private func receiveLoop() async {
    guard let socket else { return }
    while !Task.isCancelled, !isClosing {
      do {
        let message = try await socket.receive()
        switch message {
        case .string(let string):
          handleServerMessage(Data(string.utf8))
        case .data(let data):
          handleServerMessage(data)
        @unknown default:
          continue
        }
      } catch {
        if !isClosing {
          finishSetup(with: .failure(CameraAIServiceError.liveConnection))
          finishResponse(with: .failure(CameraAIServiceError.liveConnection))
        }
        return
      }
    }
  }

  private func handleServerMessage(_ data: Data) {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return
    }

    if object["setupComplete"] != nil {
      onEvent(.setupComplete)
      finishSetup(with: .success(()))
    }

    guard let serverContent = object["serverContent"] as? [String: Any] else { return }

    if let input = serverContent["inputTranscription"] as? [String: Any],
       let text = input["text"] as? String,
       !text.isEmpty {
      onEvent(.inputText(text))
    }

    if let output = serverContent["outputTranscription"] as? [String: Any],
       let text = output["text"] as? String,
       !text.isEmpty {
      responseTranscript += text
      if !suppressResponseEvents { onEvent(.outputText(text)) }
    }

    if let modelTurn = serverContent["modelTurn"] as? [String: Any],
       let parts = modelTurn["parts"] as? [[String: Any]] {
      for part in parts {
        if let text = part["text"] as? String, !text.isEmpty {
          responseTranscript += text
          if !suppressResponseEvents { onEvent(.outputText(text)) }
        }
        if let inlineData = part["inlineData"] as? [String: Any],
           let encoded = inlineData["data"] as? String,
           let audio = Data(base64Encoded: encoded) {
          if !suppressResponseEvents { onEvent(.audio(audio, mimeType: inlineData["mimeType"] as? String ?? "audio/pcm;rate=24000")) }
        }
      }
    }

    if (serverContent["interrupted"] as? Bool) == true {
      onEvent(.interrupted)
    }

    if (serverContent["turnComplete"] as? Bool) == true {
      if !suppressResponseEvents { onEvent(.turnComplete) }
      finishResponse(with: .success(CameraAILiveResponse(transcript: responseTranscript)))
    }
  }

  private func finishSetup(with result: Result<Void, Error>) {
    guard let continuation = setupContinuation else { return }
    setupContinuation = nil
    setupTimeoutTask?.cancel()
    setupTimeoutTask = nil
    continuation.resume(with: result)
  }

  private func finishResponse(with result: Result<CameraAILiveResponse, Error>) {
    guard let continuation = responseContinuation else { return }
    responseContinuation = nil
    responseTimeoutTask?.cancel()
    responseTimeoutTask = nil
    continuation.resume(with: result)
  }
}

// MARK: - Audio output

@MainActor
private final class CameraAIAudioOutput {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private var isAttached = false
  private var connectedRate: Double?

  func play(data: Data, mimeType: String) throws {
    let sampleRate = Self.sampleRate(from: mimeType)
    let sampleCount = data.count / MemoryLayout<Int16>.size
    guard sampleCount > 0 else { return }
    guard let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: 1,
      interleaved: false
    ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount))
    else { throw CameraAIServiceError.audioPlayback }

    buffer.frameLength = AVAudioFrameCount(sampleCount)
    guard let channel = buffer.floatChannelData?[0] else { throw CameraAIServiceError.audioPlayback }
    data.withUnsafeBytes { rawBuffer in
      let samples = rawBuffer.bindMemory(to: Int16.self)
      for index in 0..<sampleCount {
        channel[index] = Float(Int16(littleEndian: samples[index])) / 32768.0
      }
    }

    try prepare(rate: sampleRate, format: format)
    player.scheduleBuffer(buffer)
    if !player.isPlaying { player.play() }
  }

  func stop() {
    player.stop()
    engine.stop()
    if isAttached {
      engine.disconnectNodeOutput(player)
    }
    connectedRate = nil
  }

  private func prepare(rate: Double, format: AVAudioFormat) throws {
    if connectedRate != rate {
      if engine.isRunning { engine.stop() }
      if !isAttached {
        engine.attach(player)
        isAttached = true
      } else {
        engine.disconnectNodeOutput(player)
      }
      engine.connect(player, to: engine.mainMixerNode, format: format)
      connectedRate = rate
    }
    if !engine.isRunning { try engine.start() }
  }

  static func sampleRate(from mimeType: String) -> Double {
    guard let ratePart = mimeType.split(separator: ";").first(where: { $0.contains("rate=") }),
          let value = ratePart.split(separator: "=").last,
          let rate = Double(value)
    else { return 24_000 }
    return rate > 0 ? rate : 24_000
  }
}

/// Plays a complete Gemini speech turn as a WAV in the active Bluetooth route.
/// AVAudioPlayer uses the app's audio session, independently of the microphone
/// capture engine. Keep the player alive until playback completes.
@MainActor
private final class CameraAIBufferedAudioOutput {
  private var player: AVAudioPlayer?

  var isPlaying: Bool { player?.isPlaying == true }

  func play(pcm: Data, sampleRate: Double) throws {
    guard !pcm.isEmpty, pcm.count.isMultiple(of: 2),
          pcm.count <= Int(UInt32.max) - 36,
          sampleRate >= 8_000, sampleRate <= 48_000
    else { throw CameraAIServiceError.audioPlayback }

    let rate = UInt32(sampleRate.rounded())
    func u16(_ value: UInt16) -> [UInt8] {
      [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]
    }
    func u32(_ value: UInt32) -> [UInt8] {
      [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
       UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)]
    }
    var wav = Data()
    wav.append(contentsOf: "RIFF".utf8)
    wav.append(contentsOf: u32(UInt32(pcm.count + 36)))
    wav.append(contentsOf: "WAVEfmt ".utf8)
    wav.append(contentsOf: u32(16))
    wav.append(contentsOf: u16(1)) // PCM
    wav.append(contentsOf: u16(1)) // mono
    wav.append(contentsOf: u32(rate))
    wav.append(contentsOf: u32(rate * 2))
    wav.append(contentsOf: u16(2)) // frame alignment
    wav.append(contentsOf: u16(16)) // bits per sample
    wav.append(contentsOf: "data".utf8)
    wav.append(contentsOf: u32(UInt32(pcm.count)))
    wav.append(pcm)

    let newPlayer = try AVAudioPlayer(data: wav)
    newPlayer.volume = 1
    guard newPlayer.prepareToPlay(), newPlayer.play() else {
      throw CameraAIServiceError.audioPlayback
    }
    player = newPlayer
  }

  func stop() {
    player?.stop()
    player = nil
  }
}

// MARK: - Public view model

/// Coordinates the Camera Access AI actions without owning or changing the DAT camera
/// stream. The parent view can keep using CameraViewModel.currentVideoFrame as before.
@Observable
@MainActor
final class CameraAIViewModel {
  var status: String
  var transcript: String = ""
  var routeDescription: String = ""
  var isTranslating: Bool = false
  var isBusy: Bool = false

  @ObservationIgnored private let audioInput = AudioInputHandler()
  @ObservationIgnored private let audioOutput = CameraAIAudioOutput()
  @ObservationIgnored private let translatedAudioOutput = CameraAIBufferedAudioOutput()
  @ObservationIgnored private let speechSynthesizer = AVSpeechSynthesizer()
  @ObservationIgnored private var liveSession: CameraAILiveSession?
  @ObservationIgnored private var hasMicrophoneFrames = false
  @ObservationIgnored private var hasReceivedAudio = false
  @ObservationIgnored private var currentTurnTranscript = ""
  @ObservationIgnored private var translatedAudio = Data()
  @ObservationIgnored private var translatedAudioRate = 24_000.0
  @ObservationIgnored private var translatedAudioOverflow = false
  @ObservationIgnored private var isSpeakingTranslation = false
  @ObservationIgnored private var speechTurn = 0

  init() {
    status = Self.hasConfiguration ? "connected" : "gateway not configured"
    routeDescription = Self.audioRouteDescription()
    speechSynthesizer.usesApplicationAudioSession = true
    audioInput.setCallbacks(
      onAudioBuffer: { [weak self] audioData, numSamples, format in
        Task { @MainActor [weak self] in
          guard let self, self.isTranslating, !self.isSpeakingTranslation,
                let session = self.liveSession else { return }
          let pcm = Self.makePCM16k(audioData, sampleRate: format.mSampleRate, sampleCount: numSamples)
          if !pcm.isEmpty && !self.hasMicrophoneFrames {
            self.hasMicrophoneFrames = true
            self.status = "listening"
          }
          session.sendAudio(pcm)
        }
      },
      onInterruptionResume: {},
      onGlassesAudioUnavailable: { [weak self] in
        Task { @MainActor [weak self] in
          guard let self, self.isTranslating else { return }
          self.routeDescription = Self.audioRouteDescription()
          self.stopTranslationResources()
          self.status = "error: Bluetooth HFP microphone is unavailable"
        }
      }
    )
  }

  isolated deinit {
    liveSession?.close()
    audioInput.stopListening()
    audioInput.cleanup()
    audioOutput.stop()
    translatedAudioOutput.stop()
  }

  /// Sends exactly one JPEG frame from the existing DAT preview to Gemini Live.
  func ask(frame: UIImage) async {
    guard !isBusy else { return }
    guard !isTranslating else {
      status = "error: stop the translator first"
      return
    }
    guard let jpegData = Self.makeJPEG(from: frame) else {
      status = "error: frame encoding failed"
      return
    }

    isBusy = true
    transcript = ""
    hasReceivedAudio = false
    currentTurnTranscript = ""
    translatedAudio.removeAll()
    translatedAudioOverflow = false
    isSpeakingTranslation = false
    status = "requesting token"
    do {
      let token = try await requestEphemeralToken()
      let session = try CameraAILiveSession(
        token: token.token,
        model: token.model,
        instruction: "Опиши кратко по-русски, что я сейчас вижу. Если есть текст, прочитай или переведи. Не выдумывай неразборчивое.",
        onEvent: { [weak self] event in
          self?.handle(event)
        }
      )
      liveSession = session
      status = "connected"
      try await session.connect()
      status = "connected"
      _ = try await session.sendVisualPrompt(
        text: "Опиши этот кадр кратко по-русски.",
        jpegData: jpegData
      )
      session.close()
      liveSession = nil
      status = transcript.isEmpty ? "connected" : "speaking"
    } catch is CancellationError {
      status = "error: request cancelled"
    } catch let error as CameraAIServiceError {
      status = "error: \(error.localizedDescription)"
      liveSession?.close()
      liveSession = nil
    } catch {
      status = "error: AI request failed"
      liveSession?.close()
      liveSession = nil
    }
    isBusy = false
  }

  func startTranslation() async {
    guard !isBusy, !isTranslating else { return }
    guard Self.hasConfiguration else {
      status = "gateway not configured"
      return
    }
    guard await AVAudioApplication.requestRecordPermission() else {
      status = "error: microphone permission denied"
      return
    }

    isBusy = true
    transcript = ""
    hasMicrophoneFrames = false
    hasReceivedAudio = false
    currentTurnTranscript = ""
    translatedAudio.removeAll()
    translatedAudioOverflow = false
    isSpeakingTranslation = false
    status = "requesting token"
    do {
      try configureAudioSession()
      guard Self.hasBluetoothHFPInput else { throw CameraAIServiceError.noBluetoothInput }
      let token = try await requestEphemeralToken()
      let session = try CameraAILiveSession(
        token: token.token,
        model: token.model,
        instruction: "Слушай речь на Sinhala, Tamil или English и отвечай только переводом на русский, без комментариев.",
        onEvent: { [weak self] event in
          self?.handle(event)
        }
      )
      liveSession = session
      try await session.connect()
      status = "preparing translator"
      try await session.primeTranslation()
      audioInput.setup()
      audioInput.setupInput()
      audioInput.startListening()
      guard Self.hasActiveBluetoothHFPInput else { throw CameraAIServiceError.noBluetoothInput }
      isTranslating = true
      routeDescription = Self.audioRouteDescription()
      status = "waiting for microphone audio"
    } catch let error as CameraAIServiceError {
      stopTranslationResources()
      status = "error: \(error.localizedDescription)"
    } catch {
      stopTranslationResources()
      status = "error: translation unavailable"
    }
    isBusy = false
  }

  func stopTranslation() async {
    guard isTranslating || liveSession != nil else { return }
    isBusy = true
    stopTranslationResources()
    status = Self.hasConfiguration ? "connected" : "gateway not configured"
    routeDescription = Self.audioRouteDescription()
    isBusy = false
  }

  private func requestEphemeralToken() async throws -> CameraAIEphemeralTokenResponse {
    guard let gatewayURL = CameraAISettingsStore.gatewayURL,
          let accessToken = CameraAISettingsStore.accessToken,
          !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw CameraAIServiceError.notConfigured }

    let endpoint = gatewayURL.appendingPathComponent("api").appendingPathComponent("gemini").appendingPathComponent("live-token")
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.httpBody = Data()

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      throw CameraAIServiceError.gatewayUnavailable
    }
    guard let http = response as? HTTPURLResponse else { throw CameraAIServiceError.gatewayUnavailable }
    guard (200..<300).contains(http.statusCode) else {
      if http.statusCode == 401 || http.statusCode == 403 { throw CameraAIServiceError.gatewayUnauthorized }
      throw CameraAIServiceError.gatewayUnavailable
    }
    guard let decoded = try? JSONDecoder().decode(CameraAIEphemeralTokenResponse.self, from: data),
          !decoded.token.isEmpty,
          !decoded.model.isEmpty
    else { throw CameraAIServiceError.gatewayInvalidResponse }
    return decoded
  }

  private func handle(_ event: CameraAILiveEvent) {
    switch event {
    case .setupComplete:
      status = isTranslating ? "listening" : "connected"
    case .outputText(let text):
      transcript += text
      currentTurnTranscript += text
      status = "speaking"
    case .inputText:
      if isTranslating { status = "listening" }
    case .audio(let data, let mimeType):
      if isTranslating {
        let rate = CameraAIAudioOutput.sampleRate(from: mimeType)
        if translatedAudio.isEmpty { translatedAudioRate = rate }
        if rate != translatedAudioRate || translatedAudio.count + data.count > 4_000_000 {
          translatedAudioOverflow = true
        } else if !translatedAudioOverflow {
          translatedAudio.append(data)
        }
        break
      }
      do {
        routeDescription = Self.audioRouteDescription()
        try audioOutput.play(data: data, mimeType: mimeType)
        hasReceivedAudio = true
        status = "speaking"
      } catch {
        status = "error: Gemini audio playback failed"
      }
    case .turnComplete:
      if isTranslating {
        var voice = ""
        if CameraAISettingsStore.translationVoice == .gemini,
           !translatedAudioOverflow, !translatedAudio.isEmpty {
          do {
            try translatedAudioOutput.play(pcm: translatedAudio, sampleRate: translatedAudioRate)
            voice = "Gemini voice"
          } catch {
            translatedAudioOutput.stop()
          }
        }
        if voice.isEmpty && !currentTurnTranscript.isEmpty {
          let utterance = AVSpeechUtterance(string: currentTurnTranscript)
          utterance.voice = Self.bestRussianVoice()
          speechSynthesizer.speak(utterance)
          voice = "iOS voice"
        }
        if !voice.isEmpty {
          isSpeakingTranslation = true
          speechTurn += 1
          let turn = speechTurn
          status = "speaking (\(voice))"
          Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            while self.isTranslating && self.speechTurn == turn &&
                  (self.speechSynthesizer.isSpeaking || self.translatedAudioOutput.isPlaying) {
              try? await Task.sleep(for: .milliseconds(150))
            }
            if self.isTranslating && self.speechTurn == turn {
              self.isSpeakingTranslation = false
              self.status = "listening"
            }
          }
        } else {
          status = "listening"
        }
        currentTurnTranscript = ""
        translatedAudio.removeAll()
        translatedAudioOverflow = false
        hasReceivedAudio = false
      } else if !hasReceivedAudio, !transcript.isEmpty {
        let utterance = AVSpeechUtterance(string: transcript)
        utterance.voice = Self.bestRussianVoice()
        speechSynthesizer.speak(utterance)
        status = "speaking"
      } else if !isTranslating {
        status = transcript.isEmpty ? "connected" : "speaking"
      }
    case .interrupted:
      audioOutput.stop()
      translatedAudioOutput.stop()
    }
  }

  private func configureAudioSession() throws {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
      try session.setActive(true)
      if let bluetoothInput = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
        try session.setPreferredInput(bluetoothInput)
      }
    } catch {
      throw CameraAIServiceError.audioSession
    }
  }

  private static func bestRussianVoice() -> AVSpeechSynthesisVoice? {
    func quality(_ voice: AVSpeechSynthesisVoice) -> Int {
      switch voice.quality {
      case .premium: return 3
      case .enhanced: return 2
      default: return 1
      }
    }
    return AVSpeechSynthesisVoice.speechVoices()
      .filter { $0.language.hasPrefix("ru") }
      .max { quality($0) < quality($1) }
      ?? AVSpeechSynthesisVoice(language: "ru-RU")
  }

  private func stopTranslationResources() {
    isTranslating = false
    isSpeakingTranslation = false
    speechTurn += 1
    translatedAudio.removeAll()
    translatedAudioOverflow = false
    audioInput.stopListening()
    audioInput.cleanup()
    audioOutput.stop()
    translatedAudioOutput.stop()
    speechSynthesizer.stopSpeaking(at: .immediate)
    liveSession?.close()
    liveSession = nil
  }

  private static var hasConfiguration: Bool {
    guard CameraAISettingsStore.gatewayURL != nil,
          let token = CameraAISettingsStore.accessToken
    else { return false }
    return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private static var hasBluetoothHFPInput: Bool {
    let session = AVAudioSession.sharedInstance()
    return session.currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
      || session.availableInputs?.contains { $0.portType == .bluetoothHFP } == true
  }

  private static var hasActiveBluetoothHFPInput: Bool {
    AVAudioSession.sharedInstance().currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
  }

  private static func audioRouteDescription() -> String {
    let route = AVAudioSession.sharedInstance().currentRoute
    func describe(_ ports: [AVAudioSessionPortDescription]) -> String {
      guard !ports.isEmpty else { return "none" }
      return ports.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
    }
    return "Input: \(describe(route.inputs)); Output: \(describe(route.outputs))"
  }

  private static func makeJPEG(from image: UIImage) -> Data? {
    let maxDimension: CGFloat = 1280
    let scale = min(1, maxDimension / max(image.size.width, image.size.height))
    let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
    let renderer = UIGraphicsImageRenderer(size: size)
    let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    return resized.jpegData(compressionQuality: 0.72)
  }

  private static func makePCM16k(
    _ samples: [Float],
    sampleRate: Double,
    sampleCount: Int
  ) -> Data {
    let inputCount = min(sampleCount, samples.count)
    guard inputCount > 0, sampleRate > 0 else { return Data() }
    let outputCount = max(1, Int((Double(inputCount) * 16_000.0 / sampleRate).rounded()))
    var data = Data(capacity: outputCount * MemoryLayout<Int16>.size)
    for index in 0..<outputCount {
      let sourceIndex = min(inputCount - 1, Int(Double(index) * sampleRate / 16_000.0))
      let sample = max(-1, min(1, samples[sourceIndex]))
      var value = Int16((sample * 32767).rounded()).littleEndian
      withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    return data
  }
}

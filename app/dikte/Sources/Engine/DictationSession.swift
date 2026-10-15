import Foundation
import os

// One instance per dictation (WebSocket /dictate, see app/engine/api.md).

final class DictationSession {
    /// Events in order; finishes after `.closed`.
    let events: AsyncStream<DictationEvent>
    private let continuation: AsyncStream<DictationEvent>.Continuation

    private let port: Int?
    private let token: String
    private let urlSession: URLSession
    private let log = Logger(subsystem: "com.mehmetcaykara.dikte", category: "dictation-session")

    private var socket: URLSessionWebSocketTask?
    private var started = false
    /// Audio sent before `start()`; flushed right after the start message.
    private var pendingAudio: [Data] = []
    /// No more audio once the recording ended (server `end`, or local finish/cancel).
    private var audioStopped = false
    private var cancelRequested = false
    private var endReason: DictationEndReason?
    private var gotTerminal = false   // result or error received
    private var closed = false

    /// Not connected to an engine: `start()` reports `engine_not_running`.
    init() {
        (events, continuation) = AsyncStream.makeStream(of: DictationEvent.self)
        port = nil
        token = ""
        urlSession = .shared
    }

    init(port: Int, token: String, urlSession: URLSession) {
        (events, continuation) = AsyncStream.makeStream(of: DictationEvent.self)
        self.port = port
        self.token = token
        self.urlSession = urlSession
    }

    /// Connect and send `{"type":"start"}`.
    func start() {
        guard !started, !closed else { return }
        started = true
        guard let port, let url = URL(string: "ws://127.0.0.1:\(port)/dictate?token=\(token)") else {
            emit(.error(code: "engine_not_running", message: L("Motor çalışmıyor")))
            close()
            return
        }
        let ws = urlSession.webSocketTask(with: url)
        socket = ws
        ws.resume()
        // URLSessionWebSocketTask queues sends until the handshake completes and keeps their order,
        // so audio captured while connecting is buffered there.
        sendText(#"{"type":"start"}"#)
        for chunk in pendingAudio { transmit(.data(chunk)) }
        pendingAudio.removeAll()
        if cancelRequested { sendText(#"{"type":"cancel"}"#) }
        else if audioStopped { sendText(#"{"type":"finish"}"#) }

        Task { [self] in
            do {
                while true {
                    let message = try await ws.receive()
                    handle(message)
                    if closed { return }
                }
            } catch {
                guard !closed else { return }
                let expectedClose = gotTerminal || cancelRequested
                    || endReason == .noSpeech || endReason == .cancel
                if !expectedClose {
                    log.error("/dictate dropped: \(error.localizedDescription, privacy: .public)")
                    emit(.error(code: "connection_lost", message: L("Motor bağlantısı koptu")))
                }
                close()
            }
        }
    }

    /// 16 kHz mono Float32 samples; sent as binary frames. Ignored after the session ended.
    func send(samples: [Float]) {
        guard !audioStopped, !closed, !samples.isEmpty else { return }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }   // little-endian on Apple silicon
        if socket == nil { pendingAudio.append(data) } else { transmit(.data(data)) }
    }

    /// Enter / ⌥Space during recording.
    func finish() {
        guard !closed, !audioStopped else { return }
        audioStopped = true
        if socket != nil { sendText(#"{"type":"finish"}"#) }
    }

    /// Esc.
    func cancel() {
        guard !closed, !cancelRequested else { return }
        cancelRequested = true
        audioStopped = true
        if socket != nil {
            sendText(#"{"type":"cancel"}"#)
        } else if !started {
            close()
        }
    }

    // MARK: - Private

    private func sendText(_ text: String) {
        transmit(.string(text))
    }

    private func transmit(_ message: URLSessionWebSocketTask.Message) {
        guard let socket, !closed else { return }
        socket.send(message) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.sendFailed(error) }
        }
    }

    private func sendFailed(_ error: Error) {
        guard !closed, !gotTerminal, !cancelRequested else { return }
        log.error("/dictate send failed: \(error.localizedDescription, privacy: .public)")
        emit(.error(code: "connection_lost", message: L("Motor bağlantısı koptu")))
        close()
    }

    private struct Message: Decodable {
        var type: String
        var state: String?
        var reason: String?
        var code: String?
        var message: String?
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let s) = message,
              let m = try? EngineJSON.decoder.decode(Message.self, from: Data(s.utf8)) else { return }
        switch m.type {
        case "model":
            if m.state == "loading" { emit(.modelLoading) } else if m.state == "ready" { emit(.modelReady) }
        case "speech_start":
            emit(.speechStart)
        case "end":
            let reason = m.reason.flatMap(DictationEndReason.init(rawValue:)) ?? .finish
            endReason = reason
            audioStopped = true
            emit(.ended(reason))
        case "transcribing":
            emit(.transcribing)
        case "result":
            gotTerminal = true
            let payload = try? EngineJSON.decoder.decode(DictationResultPayload.self, from: Data(s.utf8))
            emit(.result((payload ?? DictationResultPayload()).result))
            close()
        case "error":
            gotTerminal = true
            audioStopped = true
            emit(.error(code: m.code ?? "error", message: m.message ?? L("Bilinmeyen motor hatası")))
            close()
        default:
            break
        }
    }

    private func emit(_ event: DictationEvent) {
        guard !closed else { return }
        continuation.yield(event)
    }

    /// Emits `.closed` exactly once and finishes the stream.
    private func close() {
        guard !closed else { return }
        closed = true
        audioStopped = true
        pendingAudio.removeAll()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        continuation.yield(.closed)
        continuation.finish()
    }
}

/// `/dictate` `result` message and `POST /retranscribe` response. Fields from api.md v2
/// (`language`, `dictation_id`) are optional so older engines still decode.
struct DictationResultPayload: Decodable {
    var rawText: String?
    var text: String?
    var fixes: [[String]]?
    var audioS: Double?
    var transcribeS: Double?
    var model: String?
    var language: String?
    var dictationId: String?

    var result: DictationResult {
        let fixes = (fixes ?? []).compactMap { pair in
            pair.count == 2 ? (wrong: pair[0], right: pair[1]) : nil
        }
        return DictationResult(rawText: rawText ?? text ?? "",
                               text: text ?? rawText ?? "",
                               fixes: fixes,
                               audioSeconds: audioS ?? 0,
                               transcribeSeconds: transcribeS ?? 0,
                               model: model ?? "",
                               language: language == "en" ? "en" : "tr",
                               dictationId: dictationId.flatMap { $0.isEmpty ? nil : $0 })
    }
}

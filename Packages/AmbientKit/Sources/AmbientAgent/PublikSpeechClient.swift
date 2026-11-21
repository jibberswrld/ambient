import Foundation
import AmbientContracts

public struct PublikSpeechClient: Sendable {
    private let client: PublikAIClient

    public init(credentialSource: any AICredentialSource, urlSession: URLSession = .shared) {
        client = PublikAIClient(credentialSource: credentialSource, urlSession: urlSession)
    }

    /// Returns WAV audio, ready for the app's audio player. This model/voice pair was verified against publik.
    public func synthesize(text: String) async throws -> Data {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 4096 else {
            throw AgentFailure.other(message: "Speech needs between 1 and 4096 characters.")
        }
        let body = try JSONEncoder().encode(JSONValue.object([
            "model": .string("tts-1"), "voice": .string("alloy"), "input": .string(text), "response_format": .string("wav")
        ]))
        let audio = try await client.post(path: "audio/speech", body: body)
        guard audio.count >= 12, audio.prefix(4) == Data("RIFF".utf8), audio.dropFirst(8).prefix(4) == Data("WAVE".utf8) else {
            throw AgentFailure.other(message: "publik did not return playable WAV audio.")
        }
        return audio
    }

    public func transcribe(wavData: Data) async throws -> String {
        guard wavData.count >= 12, wavData.prefix(4) == Data("RIFF".utf8), wavData.dropFirst(8).prefix(4) == Data("WAVE".utf8) else {
            throw AgentFailure.other(message: "Transcription needs recorded WAV audio.")
        }
        guard wavData.count < PublikAIClient.maximumRequestBytes - 1024 else {
            throw AgentFailure.other(message: "This recording is too large. Record a shorter clip.")
        }
        let boundary = "Ambient-\(UUID().uuidString)"
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-4o-mini-transcribe\r\n")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"response_format\"\r\n\r\njson\r\n")
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        append("\r\n--\(boundary)--\r\n")
        let data = try await client.post(path: "audio/transcriptions", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        guard let text = try JSONDecoder().decode(JSONValue.self, from: data)["text"]?.stringValue else {
            throw AgentFailure.other(message: "publik returned no transcription text.")
        }
        return text
    }
}

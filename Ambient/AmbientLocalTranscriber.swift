import Foundation
import Speech

/// Turns a finished recording into text with Apple's on-device recognizer.
enum AmbientLocalTranscriber {
    /// Nil when this Mac cannot recognize the current language on-device, the person has not allowed speech
    /// recognition, nothing was heard, or it took too long. The caller then sends the recording to publik.
    static func transcribe(wavData: Data) async -> String? {
        var authorization = SFSpeechRecognizer.authorizationStatus()
        if authorization == .notDetermined {
            authorization = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard authorization == .authorized, let recognizer = SFSpeechRecognizer(),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { return nil }
        let recordingURL = FileManager.default.temporaryDirectory.appendingPathComponent("ambient-transcribe-\(UUID().uuidString).wav")
        do { try wavData.write(to: recordingURL) } catch { return nil }
        defer { try? FileManager.default.removeItem(at: recordingURL) }
        let request = SFSpeechURLRecognitionRequest(url: recordingURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        let recognition = RecognitionInFlight()
        let text: String? = await withCheckedContinuation { continuation in
            recognition.continuation = continuation
            recognition.task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal { recognition.finish(result.bestTranscription.formattedString) }
                else if error != nil { recognition.finish(nil) }
            }
            // A recognizer that stalls must not hold the turn; publik takes over.
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { recognition.finish(nil) }
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// The recognizer's callback and the timeout race to answer; only the first answer is delivered.
    private final class RecognitionInFlight: @unchecked Sendable {
        private let lock = NSLock()
        var continuation: CheckedContinuation<String?, Never>?
        var task: SFSpeechRecognitionTask?

        func finish(_ text: String?) {
            lock.lock()
            let pendingContinuation = continuation
            continuation = nil
            lock.unlock()
            guard let pendingContinuation else { return }
            if text == nil { task?.cancel() }
            pendingContinuation.resume(returning: text)
        }
    }
}

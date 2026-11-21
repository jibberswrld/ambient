import AppKit
import AVFoundation

/// Records PCM WAV locally; only the released recording goes to publik.
@MainActor
final class AmbientDictationManager {
    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var meterTimer: Timer?
    private var preparationIdentifier = UUID()
    var audioLevelChanged: ((CGFloat) -> Void)?
    var recordingFailed: ((Error) -> Void)?
    var recordingFinished: ((Data) -> Void)?

    func startRecording() async {
        let identifier = UUID()
        preparationIdentifier = identifier
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard preparationIdentifier == identifier, !Task.isCancelled else { return }
        guard granted else {
            recordingFailed?(NSError(domain: "AmbientRecording", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission is not granted to Ambient."]))
            return
        }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ambient-recording-\(UUID().uuidString).wav")
            recordingURL = url
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
            ])
            self.recorder = recorder
            recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: 90) else {
                throw NSError(domain: "AmbientRecording", code: 2, userInfo: [NSLocalizedDescriptionKey: "The microphone recording could not start."])
            }
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let recorder = self.recorder else { return }
                    recorder.updateMeters()
                    self.audioLevelChanged?(CGFloat(pow(10, recorder.averagePower(forChannel: 0) / 20)))
                    // 90 seconds of mono PCM fits within publik's request budget.
                    if !recorder.isRecording { self.finishRecording() }
                }
            }
        } catch { cancelCurrentDictation(); recordingFailed?(error) }
    }

    @discardableResult
    func finishRecording() -> Bool {
        preparationIdentifier = UUID()
        guard let recorder, let recordingURL else { return false }
        recorder.stop()
        do {
            let wav = try Data(contentsOf: recordingURL)
            cancelCurrentDictation()
            recordingFinished?(wav)
            return true
        } catch { cancelCurrentDictation(); recordingFailed?(error); return false }
    }

    func cancelCurrentDictation() {
        preparationIdentifier = UUID()
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        recorder = nil
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
    }
}

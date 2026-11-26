import Foundation

/// Only fixed funnel steps and input kinds cross this boundary; request/account data never does.
@MainActor
final class AmbientAnalytics {
    static let shared = AmbientAnalytics()

    enum Input: String { case voice, text }
    enum Step: String, Codable {
        case signinShown = "signin_shown", signedIn = "signed_in", permissionsShown = "permissions_shown"
        case micGranted = "mic_granted", accessibilityGranted = "accessibility_granted"
        case screenRecordingGranted = "screen_recording_granted", speechRecognitionGranted = "speech_recognition_granted"
        case tourStarted = "tour_started", tourFinished = "tour_finished"
    }

    private struct Install: Codable {
        var distinctID = UUID().uuidString.lowercased()
        var enabled = true
        var firstLaunch = false
        var firstCommand = false
        var steps: Set<Step> = []
    }

    private let fileURL: URL
    private let session: URLSession
    private let allowsSending: Bool
    private var install: Install?
    var isEnabled: Bool { install?.enabled == true }

    nonisolated static var sendingAllowed: Bool {
        if ProcessInfo.processInfo.environment["AMBIENT_ANALYTICS_DEV"] == "1" { return true }
        #if DEBUG
        return false
        #else
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            && ProcessInfo.processInfo.environment["XCTestBundlePath"] == nil
        #endif
    }

    init(dataDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Ambient"), session: URLSession = .shared, allowsSending: Bool = AmbientAnalytics.sendingAllowed) {
        self.fileURL = dataDirectory.appendingPathComponent("analytics.json")
        self.session = session
        self.allowsSending = allowsSending
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                install = try JSONDecoder().decode(Install.self, from: Data(contentsOf: fileURL))
                if let install, UUID(uuidString: install.distinctID) == nil { self.install = nil }
            } else {
                try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
                install = Install()
                try save()
            }
        } catch { install = nil } // Do not replace unreadable state with a new identity or reset an opt-out.
    }

    func setEnabled(_ enabled: Bool) {
        install?.enabled = enabled
        do { try save() } catch { install?.enabled = false }
    }

    func launched() {
        guard allowsSending, isEnabled else { return }
        if install?.firstLaunch == false {
            install?.firstLaunch = true
            guard (try? save()) != nil else { return }
            capture("ambient_first_launch")
        }
        capture("ambient_app_opened")
    }

    func reached(_ step: Step) {
        guard allowsSending, isEnabled, install?.steps.contains(step) == false else { return }
        install?.steps.insert(step)
        guard (try? save()) != nil else { return }
        capture("ambient_onboarding_step", properties: ["step": step.rawValue])
    }

    func commandSubmitted() {
        guard allowsSending, isEnabled, install?.firstCommand == false else { return }
        install?.firstCommand = true
        guard (try? save()) != nil else { return }
        capture("ambient_first_command")
    }

    func commandCompleted(input: Input, ok: Bool) {
        capture("ambient_command", properties: ["input": input.rawValue, "ok": ok])
    }

    private func save() throws {
        guard let install else { return }
        try JSONEncoder().encode(install).write(to: fileURL, options: .atomic)
    }

    private func capture(_ event: String, properties: [String: Any] = [:]) {
        guard allowsSending, let install, install.enabled else { return }
        var properties = properties
        properties["distinct_id"] = install.distinctID
        properties["platform"] = "mac"
        properties["app_version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let version = ProcessInfo.processInfo.operatingSystemVersion
        properties["os_version"] = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        var request = URLRequest(url: URL(string: "https://us.i.posthog.com/i/v0/e/")!, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Public, write-only project capture key; never an account credential.
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "api_key": "phc_" + "uUbhzyktostk57hnvmntXArEXWkrk78HpdvrcQQVbLvH",
            "event": event, "properties": properties, "timestamp": timestamp.string(from: Date())
        ])
        session.dataTask(with: request) { data, response, error in
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--analytics-smoke-test") {
                print("PostHog \(event) HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0): \(data.flatMap { String(data: $0, encoding: .utf8) } ?? error?.localizedDescription ?? "")")
            }
            #endif
        }.resume()
    }
}

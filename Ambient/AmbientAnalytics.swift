import Foundation
import AmbientContracts
import AmbientUI

/// Only counts, durations, enums, booleans and Ambient's own tool and toolkit names cross this boundary. Request,
/// reply, drawing and account text, screenshots, paths, URLs and error messages never do.
@MainActor
final class AmbientAnalytics {
    static let shared = AmbientAnalytics()

    enum Input: String { case voice, text }
    enum Stage: String {
        case turn, transcription, recording, speech, account
        case screenCapture = "screen_capture", signIn = "sign_in", launchAtLogin = "launch_at_login"
    }
    enum Outcome: String {
        case finished, failed, cancelled, empty
        case paymentRequired = "payment_required", notSignedIn = "not_signed_in"
        init(_ failure: AgentFailure) {
            switch failure {
            case .paymentRequired: self = .paymentRequired
            case .notSignedIn: self = .notSignedIn
            case .cancelled: self = .cancelled
            case .other: self = .failed
            }
        }
    }

    /// One submitted turn, filled in as it runs.
    struct Command {
        let input: Input
        var outcome = Outcome.cancelled
        var transcriber: String?
        var transcribeMilliseconds: Int?
        var firstReplyMilliseconds: Int?
        var totalMilliseconds = 0
        var toolCalls = 0
        var toolErrors = 0
        var tools: [String] = []
        var spokenReplies: Bool?
        var requestCharacters: Int?
        var replyCharacters: Int?

        mutating func toolFinished(_ name: String, isError: Bool) {
            toolCalls += 1
            if isError { toolErrors += 1 }
            let name = AmbientAnalytics.identifier(name)
            if !tools.contains(name) { tools.append(name) }
        }

        var properties: [String: Any] {
            var properties: [String: Any] = ["input": input.rawValue, "ok": outcome == .finished, "outcome": outcome.rawValue,
                                             "total_ms": totalMilliseconds, "tool_calls": toolCalls, "tool_errors": toolErrors]
            if !tools.isEmpty { properties["tools"] = tools }
            properties["transcriber"] = transcriber
            properties["transcribe_ms"] = transcribeMilliseconds
            properties["first_reply_ms"] = firstReplyMilliseconds
            properties["spoken_replies"] = spokenReplies
            properties["request_chars"] = requestCharacters
            properties["reply_chars"] = replyCharacters
            return properties
        }
    }
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
    private let sessionID = UUID().uuidString.lowercased()
    private let sessionStarted = Date()
    private var commandCount = 0
    /// Each connector's last known state, so a change seen in any later list is a connect or disconnect.
    private var knownConnectors: [String: Bool] = [:]
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

    func commandCompleted(_ command: Command) {
        commandCount += 1
        capture("ambient_command", properties: command.properties)
    }

    func toolFinished(_ name: String, ok: Bool, since started: Date) {
        capture("ambient_tool", properties: ["tool": Self.identifier(name), "ok": ok, "duration_ms": Self.milliseconds(since: started)])
    }

    func drew(_ annotations: [JSONValue], displayIndex: Int, displayCount: Int, replacedPrevious: Bool) {
        var properties = Self.drawingSummary(annotations)
        properties["display_index"] = displayIndex
        properties["display_count"] = displayCount
        properties["replaced_previous"] = replacedPrevious
        capture("ambient_drawing", properties: properties)
    }

    func drawingCleared(viaMenu: Bool) {
        capture("ambient_drawing_cleared", properties: ["via": viaMenu ? "menu" : "tool"])
    }

    func pointed(displayIndex: Int) {
        capture("ambient_point", properties: ["display_index": displayIndex])
    }

    func lookedAtScreen(displays: Int, since started: Date) {
        capture("ambient_screen_look", properties: ["displays": displays, "ok": displays > 0, "duration_ms": Self.milliseconds(since: started)])
    }

    func approvalAnswered(kind: FlowBarApprovalRequest.Kind, allowed: Bool, cancelled: Bool, since asked: Date) {
        let kindName = switch kind { case .shellCommand: "shell_command"; case .backgroundAgent: "background_agent"; case .other: "other" }
        capture("ambient_approval", properties: ["kind": kindName, "decision": cancelled ? "cancelled" : (allowed ? "allowed" : "denied"),
                                                 "wait_ms": Self.milliseconds(since: asked)])
    }

    func backgroundTaskFinished(_ task: BackgroundTask) {
        var properties: [String: Any] = ["kind": task.kind.rawValue, "status": task.status.rawValue]
        properties["duration_ms"] = task.finishedAt.map { Int(max(0, $0.timeIntervalSince(task.startedAt)) * 1000) }
        capture("ambient_background_task", properties: properties)
    }

    func shortcutReleased(heldFor duration: TimeInterval, recorded: Bool) {
        let outcome = recorded ? "recorded" : (duration < AmbientTourModel.shortestRealHoldDuration ? "too_short" : "cancelled")
        capture("ambient_shortcut", properties: ["hold_ms": Int(duration * 1000), "outcome": outcome])
    }

    func failed(_ stage: Stage, _ failure: AgentFailure) {
        let kind = switch failure { case .paymentRequired: "payment_required"; case .notSignedIn: "not_signed_in"; case .cancelled: "cancelled"; case .other: "other" }
        capture("ambient_error", properties: ["stage": stage.rawValue, "kind": kind])
    }

    func settingsChanged(from old: AmbientGeneralSettings, to new: AmbientGeneralSettings) {
        for (setting, value) in Self.settingChanges(from: old, to: new) {
            capture("ambient_setting_changed", properties: ["setting": setting, "value": value])
        }
    }

    func connectorsListed(_ apps: [ConnectorApp]) {
        for app in apps {
            if let wasConnected = knownConnectors[app.slug], wasConnected != app.isConnected {
                capture(app.isConnected ? "ambient_connector_connected" : "ambient_connector_disconnected", properties: ["toolkit": Self.identifier(app.slug)])
            }
            knownConnectors[app.slug] = app.isConnected
        }
    }

    func tourLessonEnded(_ lesson: AmbientTourLesson, completed: Bool) {
        let name = switch lesson { case .talk: "talk"; case .showScreen: "show_screen"; case .handOff: "hand_off"; case .connectApps: "connect_apps"; case .placeBar: "place_bar" }
        capture("ambient_tour_lesson", properties: ["lesson": name, "result": completed ? "completed" : "skipped"])
    }

    func barMoved(to edge: FlowBarDockEdge) {
        capture("ambient_bar_moved", properties: ["edge": edge.rawValue])
    }

    /// Waits up to a second for the request, because the process exits right after.
    func sessionEnded() {
        let sent = DispatchSemaphore(value: 0)
        guard capture("ambient_session_ended", properties: ["duration_s": Int(Date().timeIntervalSince(sessionStarted)), "commands": commandCount],
                      completion: { sent.signal() }) else { return }
        _ = sent.wait(timeout: .now() + 1)
    }

    // MARK: Property builders

    static func milliseconds(since date: Date) -> Int { Int(max(0, Date().timeIntervalSince(date)) * 1000) }

    /// Tool names come from the model's tool call; anything that is not a plain identifier is reported as "other".
    static func identifier(_ name: String) -> String {
        name.count <= 64 && !name.isEmpty && name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) ? name : "other"
    }

    /// Counts of each mark kind from `draw_on_screen`'s annotations. Captions are counted, never read.
    static func drawingSummary(_ annotations: [JSONValue]) -> [String: Any] {
        let knownKinds: Set<String> = ["arrow", "circle", "box", "line", "path", "underline", "label"]
        var kinds: [String: Int] = [:]
        for annotation in annotations {
            let kind = annotation["type"]?.stringValue.flatMap { knownKinds.contains($0) ? $0 : nil } ?? "other"
            kinds[kind, default: 0] += 1
        }
        let labeled = annotations.filter { $0["text"]?.stringValue?.isEmpty == false }.count
        return ["marks": annotations.count, "kinds": kinds, "labeled_marks": labeled]
    }

    /// The general settings that changed, by stable key. The dock edge is reported as `ambient_bar_moved` instead.
    static func settingChanges(from old: AmbientGeneralSettings, to new: AmbientGeneralSettings) -> [(String, Any)] {
        var changes: [(String, Any)] = []
        if old.pushToTalkShortcut != new.pushToTalkShortcut { changes.append(("push_to_talk_shortcut", new.pushToTalkShortcut.rawValue)) }
        if old.speaksReplies != new.speaksReplies { changes.append(("speaks_replies", new.speaksReplies)) }
        if old.soundEffectsEnabled != new.soundEffectsEnabled { changes.append(("sound_effects", new.soundEffectsEnabled)) }
        if old.runsCommandsWithoutAsking != new.runsCommandsWithoutAsking { changes.append(("runs_commands_without_asking", new.runsCommandsWithoutAsking)) }
        if old.launchesAtLogin != new.launchesAtLogin { changes.append(("launches_at_login", new.launchesAtLogin)) }
        if old.sharesAnonymousUsageStats != new.sharesAnonymousUsageStats { changes.append(("shares_usage_stats", new.sharesAnonymousUsageStats)) }
        return changes
    }

    private func save() throws {
        guard let install else { return }
        try JSONEncoder().encode(install).write(to: fileURL, options: .atomic)
    }

    @discardableResult
    private func capture(_ event: String, properties: [String: Any] = [:], completion: (@Sendable () -> Void)? = nil) -> Bool {
        guard allowsSending, let install, install.enabled else { return false }
        var properties = properties
        properties["distinct_id"] = install.distinctID
        properties["session_id"] = sessionID
        if ProcessInfo.processInfo.environment["AMBIENT_ANALYTICS_DEV"] == "1" { properties["dev"] = true }
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
            completion?()
        }.resume()
        return true
    }
}

/// Connecting finishes in the browser and disconnecting in Settings, so both are seen in the lists loaded afterwards.
struct AnalyticsConnectorService: ConnectorService {
    let base: any ConnectorService
    func apps(matching query: String) async throws -> [ConnectorApp] {
        let apps = try await base.apps(matching: query)
        await AmbientAnalytics.shared.connectorsListed(apps)
        return apps
    }
    func authorizationURL(forAppSlug slug: String) async throws -> URL { try await base.authorizationURL(forAppSlug: slug) }
    func disconnect(appSlug slug: String) async throws { try await base.disconnect(appSlug: slug) }
}

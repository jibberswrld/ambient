import AmbientContracts
import Foundation

// In-memory stand-ins for the services the real app provides, so every screen can be opened and used without the
// rest of Ambient. Each one holds its data behind a lock and broadcasts the whole list on every change, the way
// the contracts describe.

/// Fans a value out to every open `AsyncStream`. Shared by the fake stores.
final class DemoBroadcaster<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]

    func stream(startingWith initialValue: Value) -> AsyncStream<Value> {
        AsyncStream { continuation in
            let streamIdentifier = UUID()
            lock.lock()
            continuations[streamIdentifier] = continuation
            lock.unlock()
            continuation.yield(initialValue)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[streamIdentifier] = nil
                self.lock.unlock()
            }
        }
    }

    func send(_ value: Value) {
        lock.lock()
        let openContinuations = Array(continuations.values)
        lock.unlock()
        openContinuations.forEach { $0.yield(value) }
    }
}

// MARK: - Background tasks

final class DemoBackgroundTaskStore: BackgroundTaskStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedTasks: [BackgroundTask]
    private var storedTranscripts: [UUID: String]
    private let broadcaster = DemoBroadcaster<[BackgroundTask]>()

    init(tasks: [BackgroundTask] = DemoSampleData.backgroundTasks(relativeTo: Date())) {
        storedTasks = tasks
        storedTranscripts = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, DemoSampleData.transcript(for: $0)) })
    }

    func tasks() async -> [BackgroundTask] { currentTasks() }

    func updates() -> AsyncStream<[BackgroundTask]> { broadcaster.stream(startingWith: currentTasks()) }

    func cancel(taskID: UUID) async {
        mutate { tasks in
            guard let index = tasks.firstIndex(where: { $0.id == taskID }), tasks[index].status == .running else { return }
            tasks[index].status = .cancelled
            tasks[index].finishedAt = Date()
            tasks[index].latestActivity = "Stopped"
        }
    }

    func dismiss(taskID: UUID) async {
        mutate { tasks in tasks.removeAll { $0.id == taskID && $0.status != .running } }
    }

    func transcript(taskID: UUID) async -> String {
        lock.withLock { storedTranscripts[taskID] ?? "" }
    }

    /// Replaces one task, for the scripted demo (a task making progress, then finishing).
    func replace(_ task: BackgroundTask) {
        mutate { tasks in
            if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task } else { tasks.insert(task, at: 0) }
        }
    }

    func currentTasks() -> [BackgroundTask] {
        lock.lock()
        defer { lock.unlock() }
        return storedTasks
    }

    private func mutate(_ change: (inout [BackgroundTask]) -> Void) {
        lock.lock()
        change(&storedTasks)
        let snapshot = storedTasks
        lock.unlock()
        broadcaster.send(snapshot)
    }
}

// MARK: - Memory

final class DemoMemoryStore: MemoryStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedItems: [MemoryItem] = DemoSampleData.memoryItems(relativeTo: Date())
    private var storedAutomaticLearning = true
    private let broadcaster = DemoBroadcaster<[MemoryItem]>()

    func items() async -> [MemoryItem] { snapshot() }
    func updates() -> AsyncStream<[MemoryItem]> { broadcaster.stream(startingWith: snapshot()) }

    func add(text: String) async {
        mutate { $0.insert(MemoryItem(id: UUID(), text: text, createdAt: Date(), wasLearnedAutomatically: false), at: 0) }
    }

    func delete(itemID: UUID) async {
        mutate { $0.removeAll { $0.id == itemID } }
    }

    var isAutomaticLearningEnabled: Bool {
        get async { lock.withLock { storedAutomaticLearning } }
    }

    func setAutomaticLearningEnabled(_ isEnabled: Bool) async {
        lock.withLock { storedAutomaticLearning = isEnabled }
    }

    func learn(fromUserText userText: String, assistantText: String) async {}

    private func snapshot() -> [MemoryItem] {
        lock.lock()
        defer { lock.unlock() }
        return storedItems
    }

    private func mutate(_ change: (inout [MemoryItem]) -> Void) {
        lock.lock()
        change(&storedItems)
        let snapshot = storedItems
        lock.unlock()
        broadcaster.send(snapshot)
    }
}

// MARK: - Skills

final class DemoSkillStore: SkillStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storedSkills: [SkillSummary] = DemoSampleData.skills
    private let broadcaster = DemoBroadcaster<[SkillSummary]>()

    struct MissingSkillFileError: Error {}

    func skills() async -> [SkillSummary] { snapshot() }
    func updates() -> AsyncStream<[SkillSummary]> { broadcaster.stream(startingWith: snapshot()) }

    func install(fromDirectory directory: URL) async throws {
        let skillFile = directory.appendingPathComponent("SKILL.md")
        guard FileManager.default.fileExists(atPath: skillFile.path) else { throw MissingSkillFileError() }
        let installedSkill = SkillSummary(name: directory.lastPathComponent, description: "Installed from \(directory.path)", isBuiltIn: false, directory: directory)
        mutate { skills in
            skills.removeAll { $0.name == installedSkill.name }
            skills.append(installedSkill)
        }
    }

    func delete(skillName: String) async throws {
        mutate { $0.removeAll { $0.name == skillName && !$0.isBuiltIn } }
    }

    private func snapshot() -> [SkillSummary] {
        lock.lock()
        defer { lock.unlock() }
        return storedSkills
    }

    private func mutate(_ change: (inout [SkillSummary]) -> Void) {
        lock.lock()
        change(&storedSkills)
        let snapshot = storedSkills
        lock.unlock()
        broadcaster.send(snapshot)
    }
}

// MARK: - Connectors

final class DemoConnectorService: ConnectorService, @unchecked Sendable {
    enum Behaviour { case normal, failing, empty }

    private let lock = NSLock()
    private var connectedSlugs: Set<String> = ["gmail", "googlecalendar", "github"]
    private let behaviour: Behaviour
    /// Delays every answer a little, so the loading state is real rather than a flash.
    private let simulatedLatencyNanoseconds: UInt64

    struct ConnectorUnavailableError: Error {}

    init(behaviour: Behaviour = .normal, simulatedLatencyNanoseconds: UInt64 = 450_000_000) {
        self.behaviour = behaviour
        self.simulatedLatencyNanoseconds = simulatedLatencyNanoseconds
    }

    func apps(matching query: String) async throws -> [ConnectorApp] {
        try await Task.sleep(nanoseconds: simulatedLatencyNanoseconds)
        switch behaviour {
        case .failing: throw ConnectorUnavailableError()
        case .empty: return []
        case .normal: break
        }
        let connected = lock.withLock { connectedSlugs }
        let allApps = DemoSampleData.connectorCatalogue.map { entry in
            ConnectorApp(slug: entry.slug, name: entry.name, logoURL: nil, isConnected: connected.contains(entry.slug))
        }
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
        guard !trimmedQuery.isEmpty else { return allApps }
        return allApps.filter { $0.name.localizedCaseInsensitiveContains(trimmedQuery) || $0.slug.localizedCaseInsensitiveContains(trimmedQuery) }
    }

    func authorizationURL(forAppSlug slug: String) async throws -> URL {
        // The demo "authorises" straight away so the row flips to connected on the next load.
        lock.withLock { _ = connectedSlugs.insert(slug) }
        return URL(string: "https://example.com/connect/\(slug)")!
    }

    func disconnect(appSlug slug: String) async throws {
        try await Task.sleep(nanoseconds: simulatedLatencyNanoseconds / 2)
        lock.withLock { _ = connectedSlugs.remove(slug) }
    }
}

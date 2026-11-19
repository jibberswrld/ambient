import Foundation
import XCTest
import AmbientContracts
@testable import AmbientMemory

actor StubTextCompletionService: TextCompletionService {
    struct Call { let systemPrompt: String; let userPrompt: String; let tier: ModelTier }
    var replies: [String]
    var calls: [Call] = []
    var shouldFail = false
    init(_ replies: [String] = []) { self.replies = replies }
    func setFailure() { shouldFail = true }
    func append(_ reply: String) { replies.append(reply) }
    func complete(systemPrompt: String, userPrompt: String, tier: ModelTier) async throws -> String {
        calls.append(Call(systemPrompt: systemPrompt, userPrompt: userPrompt, tier: tier))
        if shouldFail { throw URLError(.notConnectedToInternet) }
        return replies.isEmpty ? "{\"add\":[],\"rewrite\":[],\"remove\":[]}" : replies.removeFirst()
    }
}

actor SuspendedTextCompletionService: TextCompletionService {
    var continuation: CheckedContinuation<String, Never>?
    var hasStarted = false
    func complete(systemPrompt: String, userPrompt: String, tier: ModelTier) async throws -> String {
        hasStarted = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ reply: String) { continuation?.resume(returning: reply); continuation = nil }
}

final class AmbientMemoryTests: XCTestCase {
    private var temporaryDirectory: URL!
    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("AmbientMemoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporaryDirectory) }
    private func memoryStore(_ service: any TextCompletionService = StubTextCompletionService()) throws -> PersistentMemoryStore {
        try PersistentMemoryStore(directory: temporaryDirectory.appendingPathComponent("memory"), completionService: service)
    }
    private func skillStore() throws -> FileSkillStore {
        try FileSkillStore(directory: temporaryDirectory.appendingPathComponent("skills"))
    }
    private func markdown(_ name: String = "test-routine", description: String = "A useful routine.", instructions: String = "Read the project instructions. Run the checks. Report what happened.") -> String {
        "---\nname: \(name)\ndescription: \(description)\n---\n\(instructions)\n"
    }
    private func sourceFolder(_ name: String = "test-routine", markdown suppliedMarkdown: String? = nil) throws -> URL {
        let folder = temporaryDirectory.appendingPathComponent("imports").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data((suppliedMarkdown ?? markdown(name)).utf8).write(to: folder.appendingPathComponent("SKILL.md"))
        return folder
    }
    private func tool(_ name: String, provider: any ToolProvider) async throws -> any AmbientTool {
        let tools = await provider.tools()
        return try XCTUnwrap(tools.first { $0.definition.name == name })
    }
    private func learn(_ store: PersistentMemoryStore, user: String = "A durable preference", assistant: String = "Understood.") async {
        await store.learn(fromUserText: user, assistantText: assistant)
        await store.finishPendingLearning()
    }

    func testPersistenceRoundTripAndLearningSetting() async throws {
        let store = try memoryStore()
        let item = try await store.remember(text: "  Prefers concise replies.  ")
        await store.setAutomaticLearningEnabled(false)
        let reopened = try memoryStore()
        let items = await reopened.items()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, item.id)
        XCTAssertEqual(items.first?.text, "Prefers concise replies.")
        XCTAssertEqual(items.first, item)
        XCTAssertFalse(items[0].wasLearnedAutomatically)
        let enabled = await reopened.isAutomaticLearningEnabled
        XCTAssertFalse(enabled)
        let content = try String(contentsOf: temporaryDirectory.appendingPathComponent("memory/memories.json"), encoding: .utf8)
        XCTAssertTrue(content.contains("\n"))
        XCTAssertTrue(content.contains("Prefers concise replies."))
        try await reopened.forget(itemID: item.id)
        let empty = await (try memoryStore()).items()
        XCTAssertTrue(empty.isEmpty)
    }

    func testCorruptMemoryFileIsNotOverwritten() throws {
        let folder = temporaryDirectory.appendingPathComponent("memory")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("memories.json")
        try Data("bad data".utf8).write(to: file)
        XCTAssertThrowsError(try memoryStore())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "bad data")
    }

    func testMemoryUpdatesContainInitialAndWholeLists() async throws {
        let store = try memoryStore()
        var iterator = store.updates().makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial, [])
        let first = try await store.remember(text: "First fact.")
        let firstUpdate = await iterator.next()
        XCTAssertEqual(firstUpdate?.map(\.id), [first.id])
        _ = try await store.remember(text: "Second fact.")
        let secondUpdate = await iterator.next()
        XCTAssertEqual(secondUpdate?.count, 2)
        try await store.forget(itemID: first.id)
        let deletionUpdate = await iterator.next()
        XCTAssertEqual(deletionUpdate?.map(\.text), ["Second fact."])
        await store.setAutomaticLearningEnabled(false)
        let settingUpdate = await iterator.next()
        XCTAssertEqual(settingUpdate, deletionUpdate)
    }

    func testLearningAddsAndUsesFastTierWithExistingMemories() async throws {
        let service = StubTextCompletionService(["{\"add\":[\"Prefers direct answers.\"],\"rewrite\":[],\"remove\":[]}"])
        let store = try memoryStore(service)
        _ = try await store.remember(text: "Works on Harbor.")
        await learn(store, user: "Skip the preamble from now on.", assistant: "Will do.")
        let items = await store.items()
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.filter(\.wasLearnedAutomatically).map(\.text), ["Prefers direct answers."])
        let calls = await service.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].tier, .fast)
        XCTAssertTrue(calls[0].userPrompt.contains("Works on Harbor."))
        XCTAssertTrue(calls[0].userPrompt.contains("Skip the preamble"))
        XCTAssertTrue(calls[0].systemPrompt.contains("Never store secrets"))
        let reopened = try memoryStore()
        let restored = await reopened.items()
        XCTAssertEqual(restored.map(\.id), items.map(\.id))
    }

    func testLearningRewritesPreserveIdentityAndRemoveContradictions() async throws {
        let service = StubTextCompletionService()
        let store = try memoryStore(service)
        let preference = try await store.remember(text: "Prefers short answers.")
        let obsolete = try await store.remember(text: "Uses an old editor.")
        await service.append("{\"add\":[],\"rewrite\":[{\"id\":\"\(preference.id)\",\"text\":\"Prefers detailed technical answers.\"}],\"remove\":[\"\(obsolete.id)\"]}")
        await learn(store)
        let items = await store.items()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, preference.id)
        XCTAssertEqual(items[0].createdAt, preference.createdAt)
        XCTAssertEqual(items[0].text, "Prefers detailed technical answers.")
        XCTAssertFalse(items[0].wasLearnedAutomatically)
    }

    func testNothingToLearnAndFailuresDoNotChangeMemory() async throws {
        let service = StubTextCompletionService()
        let store = try memoryStore(service)
        let item = try await store.remember(text: "A durable fact.")
        await learn(store, user: "Thanks!")
        await service.setFailure()
        await learn(store)
        let items = await store.items()
        XCTAssertEqual(items, [item])
    }

    func testMalformedAnswersAreWholeTransactionNoOps() async throws {
        let service = StubTextCompletionService()
        let store = try memoryStore(service)
        let item = try await store.remember(text: "Original.")
        let invalidReplies = [
            "not JSON", "Here is the result: {\"add\":[\"Wrong\"],\"rewrite\":[],\"remove\":[]}",
            "{\"add\":[\"Wrong\"]}", "{\"add\":[42],\"rewrite\":[],\"remove\":[]}",
            "{\"add\":[\"Wrong\"],\"rewrite\":[],\"remove\":[\"\(UUID())\"]}",
            "{\"add\":[\"Wrong\"],\"rewrite\":[{\"id\":\"\(item.id)\",\"text\":\"Replacement\"}],\"remove\":[\"\(item.id)\"]}",
            "{\"add\":[\"  \"],\"rewrite\":[],\"remove\":[]}"
        ]
        for reply in invalidReplies {
            await service.append(reply)
            await learn(store)
            let items = await store.items()
            XCTAssertEqual(items, [item], reply)
        }
    }

    func testLearningAcceptsOnlyCompleteJSONCodeFence() async throws {
        let service = StubTextCompletionService(["```json\n{\"add\":[\"Prefers clear answers.\"],\"rewrite\":[],\"remove\":[]}\n```"])
        let store = try memoryStore(service)
        await learn(store)
        let items = await store.items()
        XCTAssertEqual(items.map(\.text), ["Prefers clear answers."])
        await service.append("```json\n{\"add\":[\"Wrong.\"],\"rewrite\":[],\"remove\":[]}\n```\nExtra commentary")
        await learn(store)
        let unchanged = await store.items()
        XCTAssertEqual(unchanged, items)
    }

    func testLearningOffSkipsModelAndPersistsAcrossRestart() async throws {
        let service = StubTextCompletionService(["{\"add\":[\"Should not exist.\"],\"rewrite\":[],\"remove\":[]}"])
        let store = try memoryStore(service)
        await store.setAutomaticLearningEnabled(false)
        await learn(store)
        let calls = await service.calls
        let items = await store.items()
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(items.isEmpty)
        let enabled = await (try memoryStore()).isAutomaticLearningEnabled
        XCTAssertFalse(enabled)
    }

    func testLearningReturnsBeforeModelAndManualDeletionWins() async throws {
        let service = SuspendedTextCompletionService()
        let store = try memoryStore(service)
        let item = try await store.remember(text: "Original fact.")
        await store.learn(fromUserText: "Correction.", assistantText: "Okay.")
        for _ in 0..<100 {
            if await service.hasStarted { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let started = await service.hasStarted
        XCTAssertTrue(started, "learn must return while completion is still suspended")
        try await store.forget(itemID: item.id)
        await service.finish("{\"add\":[],\"rewrite\":[{\"id\":\"\(item.id)\",\"text\":\"New fact.\"}],\"remove\":[]}")
        await store.finishPendingLearning()
        let items = await store.items()
        XCTAssertTrue(items.isEmpty)
    }

    func testDisablingInFlightLearningInvalidatesItsAnswer() async throws {
        let service = SuspendedTextCompletionService()
        let store = try memoryStore(service)
        await store.learn(fromUserText: "A preference.", assistantText: "Okay.")
        for _ in 0..<100 {
            if await service.hasStarted { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await store.setAutomaticLearningEnabled(false)
        await store.setAutomaticLearningEnabled(true)
        await service.finish("{\"add\":[\"Stale fact.\"],\"rewrite\":[],\"remove\":[]}")
        await store.finishPendingLearning()
        let items = await store.items()
        XCTAssertTrue(items.isEmpty)
    }

    func testPromptBudgetUsesRecentConfirmationsAndSearchNote() async throws {
        let service = StubTextCompletionService()
        let store = try memoryStore(service)
        let first = try await store.remember(text: "Oldest preference that was confirmed again.")
        for index in 0..<12 { _ = try await store.remember(text: "Other preference number \(index) with a moderately long explanation.") }
        await service.append("{\"add\":[],\"rewrite\":[{\"id\":\"\(first.id)\",\"text\":\"Oldest preference that was confirmed again.\"}],\"remove\":[]}")
        await learn(store)
        let prompt = await MemoryToolProvider(store: store, promptCharacterBudget: 700).systemPromptSection() ?? ""
        XCTAssertLessThanOrEqual(prompt.count, 700)
        XCTAssertTrue(prompt.contains(first.text))
        XCTAssertTrue(prompt.contains("Only recently confirmed"))
        let fullPrompt = await MemoryToolProvider(store: store).systemPromptSection() ?? ""
        for item in await store.items() { XCTAssertTrue(fullPrompt.contains(item.text)) }
        XCTAssertFalse(fullPrompt.contains("Only recently confirmed"))
    }

    func testMemoryToolsRememberSearchAndForget() async throws {
        let store = try memoryStore()
        let provider = MemoryToolProvider(store: store)
        let remember = try await tool("remember", provider: provider)
        let saved = await remember.run(arguments: .object(["text": .string("Harbor uses Swift.")]))
        XCTAssertFalse(saved.isError)
        let items = await store.items()
        let item = try XCTUnwrap(items.first)
        let search = try await tool("search_memories", provider: provider)
        let result = await search.run(arguments: .object(["query": .string("harbor swift")]))
        XCTAssertTrue(result.content.contains(item.id.uuidString))
        let forget = try await tool("forget", provider: provider)
        let forgotten = await forget.run(arguments: .object(["id": .string(item.id.uuidString)]))
        XCTAssertFalse(forgotten.isError)
        let remaining = await store.items()
        XCTAssertTrue(remaining.isEmpty)
        let invalid = await forget.run(arguments: .object(["id": .string("not-an-id")]))
        XCTAssertTrue(invalid.isError)
    }

    func testGoodFrontmatterIncludingQuotedAndMultilineDescriptions() throws {
        let simple = try SkillDocument(markdown: markdown())
        XCTAssertEqual(simple.name, "test-routine")
        XCTAssertTrue(simple.instructions.contains("Run the checks"))
        let quoted = try SkillDocument(markdown: "---\nname: 'quoted-skill'\ndescription: \"A colon: and a quote \\\"here\\\".\"\nallowed-tools: [Read]\n---\nDo the work.")
        XCTAssertEqual(quoted.description, "A colon: and a quote \"here\".")
        let folded = try SkillDocument(markdown: "---\nname: folded-skill\ndescription: >-\n  First line\n  second line.\n---\nAct.")
        XCTAssertEqual(folded.description, "First line second line.")
        let literal = try SkillDocument(markdown: "---\r\nname: literal-skill\r\ndescription: |\r\n  First\r\n  second\r\n---\r\nAct.")
        XCTAssertEqual(literal.description, "First\nsecond")
    }

    func testBadFrontmatterIsRejected() {
        for invalid in ["No header", "---\nname: missing-end", markdown("../escape"), markdown("Uppercase"), markdown("bad--name"), markdown(description: ""), markdown(instructions: ""), "---\nname: test\ndescription: [not, text]\n---\nDo it.", "---\nname: test\nname: other\ndescription: Desc\n---\nAct."] {
            XCTAssertThrowsError(try SkillDocument(markdown: invalid), invalid)
        }
    }

    func testFourBuiltInsAndPromptContainsSummariesOnly() async throws {
        let store = try skillStore()
        let skills = await store.skills()
        XCTAssertEqual(skills.map(\.name), ["daily-brief", "delegate-coding-task", "inbox-triage", "meeting-prep"])
        XCTAssertTrue(skills.allSatisfy(\.isBuiltIn))
        let prompt = await SkillToolProvider(store: store).systemPromptSection() ?? ""
        for skill in skills {
            XCTAssertTrue(prompt.contains(skill.description))
            let loaded = try await store.load(skillName: skill.name)
            XCTAssertFalse(loaded.instructions.isEmpty)
            XCTAssertTrue(loaded.files.contains("SKILL.md"))
            XCTAssertFalse(prompt.contains(loaded.instructions))
        }
    }

    func testInstallCopiesSupportingFilesAndPersonalOverridesBuiltIn() async throws {
        let store = try skillStore()
        let source = try sourceFolder("daily-brief", markdown: markdown("daily-brief", description: "My own brief.", instructions: "Read notes.txt first."))
        try Data("Personal instructions.".utf8).write(to: source.appendingPathComponent("notes.txt"))
        try await store.install(fromDirectory: source)
        let skills = await store.skills()
        XCTAssertEqual(skills.count, 4)
        XCTAssertEqual(skills.first?.description, "My own brief.")
        XCTAssertFalse(skills[0].isBuiltIn)
        try FileManager.default.removeItem(at: source)
        let text = try await store.readFile(skillName: "daily-brief", relativePath: "notes.txt")
        XCTAssertEqual(text, "Personal instructions.")
        try await store.delete(skillName: "daily-brief")
        let restored = await store.skills()
        XCTAssertTrue(restored[0].isBuiltIn)
        do { try await store.delete(skillName: "daily-brief"); XCTFail("Built-in deletion must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("built in")) }
    }

    func testInstallValidationRejectsBadMetadataAndSymbolicLinks() async throws {
        let store = try skillStore()
        let bad = try sourceFolder("invalid", markdown: "No frontmatter.")
        do { try await store.install(fromDirectory: bad); XCTFail("Expected validation error") } catch {}
        let source = try sourceFolder()
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("outside"), withDestinationURL: temporaryDirectory)
        do { try await store.install(fromDirectory: source); XCTFail("Expected symlink rejection") } catch {}
        let skills = await store.skills()
        XCTAssertEqual(skills.count, 4)
    }

    func testWatcherDetectsHandDroppedEditedAndRemovedFolder() async throws {
        let store = try skillStore()
        let addition = expectation(description: "Hand-dropped skill appeared")
        let edit = expectation(description: "Hand-edited skill appeared")
        let removal = expectation(description: "Hand-removed skill disappeared")
        let initial = expectation(description: "Initial catalog")
        let observer = Task {
            var sawAddition = false
            var sawEdit = false
            for await skills in store.updates() {
                if !sawAddition && skills.count == 4 { initial.fulfill() }
                if let personal = skills.first(where: { $0.name == "test-routine" }) {
                    if !sawAddition { sawAddition = true; addition.fulfill() }
                    if personal.description == "Changed by hand." && !sawEdit { sawEdit = true; edit.fulfill() }
                } else if sawEdit { removal.fulfill(); return }
            }
        }
        defer { observer.cancel() }
        await fulfillment(of: [initial], timeout: 2)
        let source = try sourceFolder()
        let destination = temporaryDirectory.appendingPathComponent("skills/test-routine")
        try FileManager.default.copyItem(at: source, to: destination)
        await fulfillment(of: [addition], timeout: 3)
        try Data(markdown(description: "Changed by hand.").utf8).write(to: destination.appendingPathComponent("SKILL.md"), options: .atomic)
        await fulfillment(of: [edit], timeout: 3)
        try FileManager.default.removeItem(at: destination)
        await fulfillment(of: [removal], timeout: 3)
    }

    func testCreateUpdateLoadAndReadThroughTools() async throws {
        let store = try skillStore()
        let provider = SkillToolProvider(store: store)
        let create = try await tool("create_skill", provider: provider)
        let created = await create.run(arguments: .object(["markdown": .string(markdown()), "files": .object(["references/checks.md": .string("Run swift test.")])]))
        XCTAssertFalse(created.isError, created.content)
        let duplicate = await create.run(arguments: .object(["markdown": .string(markdown())]))
        XCTAssertTrue(duplicate.isError)
        let update = try await tool("update_skill", provider: provider)
        let updated = await update.run(arguments: .object(["name": .string("test-routine"), "markdown": .string(markdown(description: "Updated routine.", instructions: "Read references/checks.md. Report the result."))]))
        XCTAssertFalse(updated.isError, updated.content)
        let load = try await tool("load_skill", provider: provider)
        let loaded = await load.run(arguments: .object(["name": .string("test-routine")]))
        XCTAssertFalse(loaded.isError)
        XCTAssertTrue(loaded.content.contains("references/checks.md"))
        let read = try await tool("read_skill_file", provider: provider)
        let file = await read.run(arguments: .object(["name": .string("test-routine"), "path": .string("references/checks.md")]))
        XCTAssertEqual(file.content, "Run swift test.")
        for path in ["../SKILL.md", "/etc/passwd", "references/../../escape"] {
            let invalid = await read.run(arguments: .object(["name": .string("test-routine"), "path": .string(path)]))
            XCTAssertTrue(invalid.isError)
        }
        let reopened = try skillStore()
        let reloaded = try await reopened.load(skillName: "test-routine")
        XCTAssertTrue(reloaded.instructions.contains("Report the result"))
    }

    func testToolUpdateBuiltInCreatesPersonalOverrideAndRejectsRename() async throws {
        let store = try skillStore()
        let update = try await tool("update_skill", provider: SkillToolProvider(store: store))
        let overridden = await update.run(arguments: .object(["name": .string("daily-brief"), "markdown": .string(markdown("daily-brief", description: "Custom brief."))]))
        XCTAssertFalse(overridden.isError, overridden.content)
        let summaries = await store.skills()
        XCTAssertFalse(summaries[0].isBuiltIn)
        let rename = await update.run(arguments: .object(["name": .string("daily-brief"), "markdown": .string(markdown("different-name"))]))
        XCTAssertTrue(rename.isError)
    }

    func testToolRejectsEscapingSupportingFileWithoutPartialInstall() async throws {
        let store = try skillStore()
        let create = try await tool("create_skill", provider: SkillToolProvider(store: store))
        let result = await create.run(arguments: .object(["markdown": .string(markdown()), "files": .object(["../escape": .string("Bad")])]))
        XCTAssertTrue(result.isError)
        let skills = await store.skills()
        XCTAssertEqual(skills.count, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectory.appendingPathComponent("escape").path))
    }
}

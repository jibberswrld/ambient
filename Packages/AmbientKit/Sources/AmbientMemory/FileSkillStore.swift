import Foundation
import AmbientContracts

struct SkillDocument {
    let name: String
    let description: String
    let instructions: String

    init(markdown: String) throws {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first == "---", let closingIndex = lines.dropFirst().firstIndex(of: "---") else {
            throw AmbientMemoryError.invalidInput("SKILL.md must begin with YAML frontmatter between --- lines.")
        }
        var fields: [String: String] = [:]
        var index = 1
        while index < closingIndex {
            let line = lines[index]
            index += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"),
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard key == "name" || key == "description" else { continue }
            guard fields[key] == nil else { throw AmbientMemoryError.invalidInput("Duplicate \(key) in skill frontmatter.") }
            let rawValue = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if [">", ">-", ">+", "|", "|-", "|+"].contains(rawValue) {
                var block: [String] = []
                while index < closingIndex {
                    let nextLine = lines[index]
                    guard nextLine.isEmpty || nextLine.hasPrefix(" ") || nextLine.hasPrefix("\t") else { break }
                    block.append(nextLine.trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                fields[key] = block.joined(separator: rawValue.hasPrefix(">") ? " " : "\n")
            } else if rawValue.hasPrefix("\"") {
                guard let data = rawValue.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) else {
                    throw AmbientMemoryError.invalidInput("Invalid quoted \(key) in skill frontmatter.")
                }
                fields[key] = decoded
            } else if rawValue.hasPrefix("'") {
                guard rawValue.count >= 2, rawValue.hasSuffix("'") else {
                    throw AmbientMemoryError.invalidInput("Unclosed quote in skill frontmatter.")
                }
                fields[key] = String(rawValue.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            } else {
                guard !rawValue.hasPrefix("["), !rawValue.hasPrefix("{"), !rawValue.hasPrefix("&"), !rawValue.hasPrefix("*") else {
                    throw AmbientMemoryError.invalidInput("Skill \(key) must be text.")
                }
                fields[key] = rawValue.components(separatedBy: " #").first ?? rawValue
            }
        }
        let name = fields["name", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        let description = fields["description", default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = lines.dropFirst(closingIndex + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidName(name) else {
            throw AmbientMemoryError.invalidInput("Skill name must be 1–64 lowercase letters, digits or single hyphens, beginning and ending with a letter or digit.")
        }
        guard !description.isEmpty, !instructions.isEmpty else {
            throw AmbientMemoryError.invalidInput("SKILL.md needs a nonempty description and instructions.")
        }
        self.name = name
        self.description = description
        self.instructions = instructions
    }

    static func isValidName(_ name: String) -> Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        return !name.isEmpty && name.count <= 64 && name.allSatisfy(allowed.contains)
            && !name.hasPrefix("-") && !name.hasSuffix("-") && !name.contains("--")
    }
}

public actor FileSkillStore: SkillStore {
    public static var defaultDirectory: URL {
        PersistentMemoryStore.defaultDirectory.appendingPathComponent("skills", isDirectory: true)
    }

    private let directory: URL
    private let builtInDirectory: URL
    private var catalog: [SkillSummary] = []
    private var fingerprint = ""
    private var continuations: [UUID: AsyncStream<[SkillSummary]>.Continuation] = [:]
    private var watchingTask: Task<Void, Never>?

    public init(directory: URL = FileSkillStore.defaultDirectory) throws {
        self.directory = directory.standardizedFileURL
        guard let builtInDirectory = Bundle.module.resourceURL?.appendingPathComponent("BuiltInSkills", isDirectory: true) else {
            throw AmbientMemoryError.invalidInput("Ambient's built-in skills could not be found.")
        }
        self.builtInDirectory = builtInDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { watchingTask?.cancel() }

    public func skills() -> [SkillSummary] {
        startWatchingIfNeeded()
        refresh()
        return catalog
    }

    public nonisolated func updates() -> AsyncStream<[SkillSummary]> {
        AsyncStream { continuation in
            let subscriptionID = UUID()
            let registration = Task { await self.subscribe(continuation, id: subscriptionID) }
            continuation.onTermination = { _ in
                Task { await registration.value; await self.unsubscribe(id: subscriptionID) }
            }
        }
    }

    private func subscribe(_ continuation: AsyncStream<[SkillSummary]>.Continuation, id: UUID) {
        startWatchingIfNeeded()
        refresh()
        continuations[id] = continuation
        continuation.yield(catalog)
    }
    private func unsubscribe(id: UUID) { continuations.removeValue(forKey: id) }

    private func startWatchingIfNeeded() {
        guard watchingTask == nil else { return }
        // Watching by rescan also catches new nested folders and atomic directory replacements.
        // A root-only filesystem event source misses edits to files inside existing skill folders.
        watchingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard await self?.refresh() != nil else { return }
            }
        }
    }
    private func refresh() {
        var summaries: [String: SkillSummary] = [:]
        var signatures: [String] = []
        for (root, isBuiltIn) in [(builtInDirectory, true), (directory, false)] {
            let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for folder in folders.sorted(by: { $0.path < $1.path }) {
                guard let document = try? validatedDocument(in: folder),
                      folder.lastPathComponent == document.name else { continue }
                summaries[document.name] = SkillSummary(name: document.name, description: document.description, isBuiltIn: isBuiltIn, directory: folder)
                signatures.append(folder.path)
                // Include referenced files so an instruction/file edit emits an update even if the summary is unchanged.
                for file in (try? files(in: folder)) ?? [] {
                    let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(file).path)
                    let modificationTime = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
                    signatures.append("\(file):\(modificationTime):\(attributes?[.size] ?? "")")
                }
            }
        }
        let newCatalog = summaries.values.sorted { $0.name < $1.name }
        let newFingerprint = signatures.joined(separator: "\n")
        guard newCatalog != catalog || newFingerprint != fingerprint else { return }
        catalog = newCatalog
        fingerprint = newFingerprint
        for continuation in continuations.values { continuation.yield(catalog) }
    }

    public func install(fromDirectory sourceDirectory: URL) throws {
        let document = try validatedDocument(in: sourceDirectory)
        try replacePersonalSkill(name: document.name) { staging in
            try FileManager.default.copyItem(at: sourceDirectory, to: staging)
            _ = try self.validatedDocument(in: staging)
        }
    }

    public func delete(skillName: String) throws {
        let skill = try findSkill(named: skillName)
        guard !skill.isBuiltIn else {
            throw AmbientMemoryError.invalidInput("\(skillName) is built in and cannot be deleted. A personal skill with the same name can override it.")
        }
        try FileManager.default.removeItem(at: skill.directory)
        refresh()
    }

    public func load(skillName: String) throws -> (instructions: String, files: [String]) {
        let skill = try findSkill(named: skillName)
        let document = try validatedDocument(in: skill.directory)
        return (document.instructions, try files(in: skill.directory))
    }

    public func readFile(skillName: String, relativePath: String) throws -> String {
        let skill = try findSkill(named: skillName)
        let file = try containedFile(relativePath, in: skill.directory)
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// Supporting files are UTF-8 text; installed skill folders may also contain binary assets.
    public func writeSkill(markdown: String, files supportingFiles: [String: String] = [:], updating skillName: String? = nil) throws {
        let document = try SkillDocument(markdown: markdown)
        let existingSkill = skills().first { $0.name == document.name }
        if let skillName {
            guard document.name == skillName else { throw AmbientMemoryError.invalidInput("An updated skill must keep its existing name.") }
            guard existingSkill != nil else { throw AmbientMemoryError.invalidInput("No skill named \(skillName) is available.") }
        } else if existingSkill != nil {
            throw AmbientMemoryError.invalidInput("That skill already exists. Load it and use update_skill instead.")
        }
        for path in supportingFiles.keys {
            _ = try containedFile(path, in: directory)
            guard path != "SKILL.md" else { throw AmbientMemoryError.invalidInput("Pass SKILL.md using the markdown argument.") }
        }
        try replacePersonalSkill(name: document.name) { staging in
            if skillName != nil, let existingSkill {
                try FileManager.default.copyItem(at: existingSkill.directory, to: staging)
            } else {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            }
            try Data(markdown.utf8).write(to: staging.appendingPathComponent("SKILL.md"), options: .atomic)
            for (path, text) in supportingFiles {
                let destination = try self.containedFile(path, in: staging)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: destination, options: .atomic)
            }
            _ = try self.validatedDocument(in: staging)
        }
    }

    private func findSkill(named name: String) throws -> SkillSummary {
        guard SkillDocument.isValidName(name), let skill = skills().first(where: { $0.name == name }) else {
            throw AmbientMemoryError.invalidInput("No skill named \(name) is available.")
        }
        return skill
    }

    private func validatedDocument(in folder: URL) throws -> SkillDocument {
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw AmbientMemoryError.invalidInput("A skill must be a real folder, not a symbolic link.")
        }
        _ = try files(in: folder)
        return try SkillDocument(markdown: String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8))
    }

    private func files(in folder: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]) else {
            throw AmbientMemoryError.invalidInput("The skill folder cannot be read.")
        }
        var paths: [String] = []
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else {
                throw AmbientMemoryError.invalidInput("Skills may contain only regular files and folders; symbolic links are not allowed.")
            }
            if values.isRegularFile == true { paths.append(String(file.path.dropFirst(folder.path.count + 1))) }
        }
        return paths.sorted()
    }

    private func containedFile(_ path: String, in folder: URL) throws -> URL {
        let components = path.components(separatedBy: "/")
        guard !path.isEmpty, !path.hasPrefix("/"), !components.contains(".."), !components.contains("."), !components.contains("") else {
            throw AmbientMemoryError.invalidInput("Use a relative file path inside the skill folder, without . or .. components.")
        }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        let candidate = folder.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else {
            throw AmbientMemoryError.invalidInput("The requested file is outside the skill folder.")
        }
        return candidate
    }

    private func replacePersonalSkill(name: String, populate: (URL) throws -> Void) throws {
        let staging = directory.appendingPathComponent(".install-\(UUID().uuidString)")
        let backup = directory.appendingPathComponent(".backup-\(UUID().uuidString)")
        let destination = directory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: staging) }
        try populate(staging)
        var movedOriginal = false
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: destination, to: backup)
            movedOriginal = true
        }
        do { try FileManager.default.moveItem(at: staging, to: destination) }
        catch {
            if movedOriginal { try? FileManager.default.moveItem(at: backup, to: destination) }
            throw error
        }
        if movedOriginal { try? FileManager.default.removeItem(at: backup) }
        startWatchingIfNeeded()
        refresh()
    }
}

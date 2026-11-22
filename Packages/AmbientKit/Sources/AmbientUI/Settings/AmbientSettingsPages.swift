import AmbientContracts
import AppKit
import SwiftUI

// MARK: - Shared pieces

/// A search or entry field drawn in Ambient's style instead of the default bezel.
struct AmbientFieldContainer<Content: View>: View {
    var symbolName: String?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 8) {
            if let symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AmbientDesign.Palette.tertiaryText)
            }
            content
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(AmbientDesign.Palette.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(AmbientDesign.Palette.cardHairline, lineWidth: 1))
    }
}

/// A placeholder row while a list loads: the shape of the content, gently pulsing.
struct AmbientLoadingRow: View {
    var index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDimmed = false

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(AmbientDesign.Palette.quietFill).frame(width: 28, height: 28)
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(AmbientDesign.Palette.quietFill).frame(width: CGFloat(90 + (index * 37) % 80), height: 10)
            Spacer()
            Capsule(style: .continuous).fill(AmbientDesign.Palette.quietFill).frame(width: 72, height: 24)
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .opacity(isDimmed ? 0.45 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true).delay(Double(index) * 0.08)) { isDimmed = true }
        }
        .accessibilityHidden(true)
    }
}

/// A list card: rows with hairlines between them.
struct AmbientListCard<Item: Identifiable, Row: View>: View {
    var items: [Item]
    @ViewBuilder var row: (Item) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                if offset > 0 { AmbientGroupDivider() }
                row(item)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AmbientDesign.Palette.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AmbientDesign.Palette.cardHairline, lineWidth: 1))
    }
}

/// A one-line error under a control, in plain words.
struct AmbientInlineError: View {
    var message: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12))
            Text(message).font(.system(size: 12))
        }
        .foregroundStyle(AmbientDesign.Palette.alertDeep)
    }
}

// MARK: - Connectors

@MainActor
@Observable
final class AmbientConnectorsPageModel {
    enum LoadState: Equatable {
        case loading
        case loaded([ConnectorApp])
        case failed(String)
    }

    var searchQuery = ""
    private(set) var loadState: LoadState = .loading
    /// Apps whose browser authorisation is open, waiting for the person to come back.
    private(set) var appSlugsAwaitingAuthorization: Set<String> = []
    private(set) var appSlugsBeingDisconnected: Set<String> = []
    private(set) var actionErrorMessage: String?

    private let connectorService: any ConnectorService
    private let onOpenURL: (URL) -> Void

    init(connectorService: any ConnectorService, onOpenURL: @escaping (URL) -> Void) {
        self.connectorService = connectorService
        self.onOpenURL = onOpenURL
    }

    /// Connected apps first, then by name.
    static func sortedForDisplay(_ apps: [ConnectorApp]) -> [ConnectorApp] {
        apps.sorted { first, second in
            if first.isConnected != second.isConnected { return first.isConnected }
            return first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
        }
    }

    func load(showingSpinner: Bool) async {
        if showingSpinner { loadState = .loading }
        let queryAtStart = searchQuery
        do {
            let apps = try await connectorService.apps(matching: queryAtStart.trimmingCharacters(in: .whitespaces))
            guard queryAtStart == searchQuery else { return }
            loadState = .loaded(Self.sortedForDisplay(apps))
            appSlugsAwaitingAuthorization.subtract(apps.filter(\.isConnected).map(\.slug))
        } catch {
            guard queryAtStart == searchQuery else { return }
            loadState = .failed("Could not reach your connectors. Check your connection and try again.")
        }
    }

    func connect(_ app: ConnectorApp) async {
        actionErrorMessage = nil
        do {
            let authorizationURL = try await connectorService.authorizationURL(forAppSlug: app.slug)
            appSlugsAwaitingAuthorization.insert(app.slug)
            onOpenURL(authorizationURL)
        } catch {
            actionErrorMessage = "Could not start connecting \(app.name). Try again."
        }
    }

    func disconnect(_ app: ConnectorApp) async {
        actionErrorMessage = nil
        appSlugsBeingDisconnected.insert(app.slug)
        defer { appSlugsBeingDisconnected.remove(app.slug) }
        do {
            try await connectorService.disconnect(appSlug: app.slug)
            await load(showingSpinner: false)
        } catch {
            actionErrorMessage = "Could not disconnect \(app.name). Try again."
        }
    }
}

struct AmbientConnectorsSettingsPage: View {
    @State private var pageModel: AmbientConnectorsPageModel

    init(connectorService: any ConnectorService, onOpenURL: @escaping (URL) -> Void) {
        _pageModel = State(initialValue: AmbientConnectorsPageModel(connectorService: connectorService, onOpenURL: onOpenURL))
    }

    var body: some View {
        AmbientSettingsPage(section: .connectors) {
            VStack(alignment: .leading, spacing: 14) {
                AmbientFieldContainer(symbolName: "magnifyingglass") {
                    TextField("Search apps", text: $pageModel.searchQuery)
                }
                if let actionErrorMessage = pageModel.actionErrorMessage {
                    AmbientInlineError(message: actionErrorMessage)
                }
                content
            }
        }
        .task(id: pageModel.searchQuery) {
            // Wait for typing to pause before searching.
            if !pageModel.searchQuery.isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
            guard !Task.isCancelled else { return }
            await pageModel.load(showingSpinner: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Coming back from the browser after authorising: refresh so the new connection shows.
            Task { await pageModel.load(showingSpinner: false) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch pageModel.loadState {
        case .loading:
            AmbientListCard(items: Array(0..<6).map(LoadingPlaceholder.init)) { placeholder in
                AmbientLoadingRow(index: placeholder.id)
            }
        case .failed(let message):
            AmbientEmptyState(symbolName: "wifi.exclamationmark", title: "Connectors did not load", message: message, isError: true) {
                AmbientCapsuleButton(title: "Try again", prominence: .secondary, surface: .window) {
                    Task { await pageModel.load(showingSpinner: true) }
                }
            }
        case .loaded(let apps) where apps.isEmpty:
            AmbientEmptyState(symbolName: "magnifyingglass", title: "No apps match", message: "Nothing called \u{201C}\(pageModel.searchQuery)\u{201D}. Try another name.")
        case .loaded(let apps):
            let connectedCount = apps.filter(\.isConnected).count
            if connectedCount > 0 && pageModel.searchQuery.isEmpty {
                Text("\(connectedCount) connected")
                    .font(AmbientDesign.Typeface.sectionLabel)
                    .foregroundStyle(AmbientDesign.Palette.secondaryText)
                    .padding(.leading, 4)
                    .padding(.bottom, -6)
            }
            AmbientListCard(items: apps) { app in
                AmbientConnectorRow(
                    app: app,
                    isAwaitingAuthorization: pageModel.appSlugsAwaitingAuthorization.contains(app.slug),
                    isDisconnecting: pageModel.appSlugsBeingDisconnected.contains(app.slug),
                    onConnect: { Task { await pageModel.connect(app) } },
                    onDisconnect: { Task { await pageModel.disconnect(app) } }
                )
            }
        }
    }

    private struct LoadingPlaceholder: Identifiable { var id: Int }
}

struct AmbientConnectorRow: View {
    var app: ConnectorApp
    var isAwaitingAuthorization: Bool
    var isDisconnecting: Bool
    var onConnect: () -> Void
    var onDisconnect: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            AmbientAppLogo(name: app.name, logoURL: app.logoURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AmbientDesign.Palette.primaryText)
                if app.isConnected {
                    HStack(spacing: 4) {
                        Circle().fill(AmbientDesign.Palette.ember).frame(width: 5, height: 5)
                        Text("Connected").font(.system(size: 11.5)).foregroundStyle(AmbientDesign.Palette.secondaryText)
                    }
                } else if isAwaitingAuthorization {
                    Text("Finish in your browser").font(.system(size: 11.5)).foregroundStyle(AmbientDesign.Palette.secondaryText)
                }
            }
            Spacer(minLength: 12)
            trailingControl
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(isHovering ? AmbientDesign.Palette.rowHover : .clear)
        .onHover { hovering in isHovering = hovering }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if isDisconnecting {
            ProgressView().controlSize(.small)
        } else if app.isConnected {
            AmbientCapsuleButton(title: "Disconnect", prominence: .quiet, surface: .window, isCompact: true, action: onDisconnect)
                .opacity(isHovering ? 1 : 0.0)
                .accessibilityHidden(!isHovering)
        } else if isAwaitingAuthorization {
            AmbientCapsuleButton(title: "Open again", prominence: .quiet, surface: .window, isCompact: true, action: onConnect)
        } else {
            AmbientCapsuleButton(title: "Connect", prominence: .secondary, surface: .window, isCompact: true, action: onConnect)
        }
    }
}

/// The app's logo, or its first letter while the logo loads or when there is none.
struct AmbientAppLogo: View {
    var name: String
    var logoURL: URL?

    @State private var loadedLogo: NSImage?

    var body: some View {
        let monogram = Text(String(name.prefix(1)).uppercased())
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AmbientDesign.Palette.secondaryText)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(AmbientDesign.Palette.quietFill))
        Group {
            if let loadedLogo {
                Image(nsImage: loadedLogo).resizable().interpolation(.high).scaledToFit().padding(4)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white))
            } else {
                monogram
            }
        }
        // Connector logos are SVG, which AsyncImage cannot decode; NSImage can.
        .task(id: logoURL) {
            loadedLogo = nil
            guard let logoURL else { return }
            loadedLogo = await AmbientAppLogoCache.shared.logo(at: logoURL)
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(AmbientDesign.Palette.cardHairline, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// Logos fetched once per launch, so searching and scrolling the list never refetches or flickers.
@MainActor
final class AmbientAppLogoCache {
    static let shared = AmbientAppLogoCache()
    private var logosByURL: [URL: NSImage] = [:]

    func logo(at logoURL: URL) async -> NSImage? {
        if let cachedLogo = logosByURL[logoURL] { return cachedLogo }
        guard let (data, response) = try? await URLSession.shared.data(from: logoURL),
              (response as? HTTPURLResponse)?.statusCode == 200, let logo = NSImage(data: data), logo.isValid,
              logo.size.width > 0, logo.size.height > 0 else { return nil }
        logosByURL[logoURL] = logo
        return logo
    }
}

// MARK: - Memory

struct AmbientMemorySettingsPage: View {
    var memoryStore: any MemoryStore

    @State private var memoryItems: [MemoryItem]?
    @State private var isAutomaticLearningEnabled = true
    @State private var draftMemoryText = ""

    var body: some View {
        AmbientSettingsPage(section: .memory) {
            AmbientSettingsGroup(label: nil) {
                AmbientSwitchRow(
                    title: "Learn as I use it",
                    detail: "Ambient keeps short notes about your preferences and the people and projects you mention.",
                    isOn: Binding(
                        get: { isAutomaticLearningEnabled },
                        set: { isEnabled in
                            isAutomaticLearningEnabled = isEnabled
                            Task { await memoryStore.setAutomaticLearningEnabled(isEnabled) }
                        }
                    )
                )
            }
            HStack(spacing: 8) {
                AmbientFieldContainer(symbolName: "plus") {
                    TextField("Add something Ambient should know", text: $draftMemoryText)
                        .onSubmit(addDraftMemory)
                }
                AmbientCapsuleButton(title: "Add", prominence: draftMemoryText.trimmingCharacters(in: .whitespaces).isEmpty ? .secondary : .primary, surface: .window, action: addDraftMemory)
            }
            if let memoryItems {
                if memoryItems.isEmpty {
                    AmbientEmptyState(symbolName: "brain.head.profile", title: "Nothing yet", message: "Ambient learns as you use it. You can also add things yourself.")
                } else {
                    let learnedCount = memoryItems.filter(\.wasLearnedAutomatically).count
                    Text("\(memoryItems.count) things, \(learnedCount) learned automatically")
                        .font(AmbientDesign.Typeface.sectionLabel)
                        .foregroundStyle(AmbientDesign.Palette.secondaryText)
                        .padding(.leading, 4)
                        .padding(.bottom, -12)
                    AmbientListCard(items: memoryItems) { memoryItem in
                        AmbientMemoryRow(memoryItem: memoryItem) {
                            Task { await memoryStore.delete(itemID: memoryItem.id) }
                        }
                    }
                }
            } else {
                AmbientListCard(items: Array(0..<4).map(LoadingPlaceholder.init)) { placeholder in
                    AmbientLoadingRow(index: placeholder.id)
                }
            }
        }
        .task {
            isAutomaticLearningEnabled = await memoryStore.isAutomaticLearningEnabled
            memoryItems = sortedNewestFirst(await memoryStore.items())
            for await updatedItems in memoryStore.updates() {
                withAnimation(.easeOut(duration: 0.2)) { memoryItems = sortedNewestFirst(updatedItems) }
            }
        }
    }

    private func sortedNewestFirst(_ items: [MemoryItem]) -> [MemoryItem] {
        items.sorted { $0.createdAt > $1.createdAt }
    }

    private func addDraftMemory() {
        let trimmedText = draftMemoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        draftMemoryText = ""
        Task { await memoryStore.add(text: trimmedText) }
    }

    private struct LoadingPlaceholder: Identifiable { var id: Int }
}

struct AmbientMemoryRow: View {
    var memoryItem: MemoryItem
    var onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(memoryItem.text)
                    .font(.system(size: 13))
                    .foregroundStyle(AmbientDesign.Palette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    if memoryItem.wasLearnedAutomatically {
                        Image(systemName: "wand.and.rays").font(.system(size: 10, weight: .medium)).foregroundStyle(AmbientDesign.Palette.accentText)
                        Text("Learned")
                    } else {
                        Image(systemName: "person.fill").font(.system(size: 9.5))
                        Text("Added by you")
                    }
                    Text("\u{00B7}")
                    Text(memoryItem.createdAt.formatted(.relative(presentation: .named)))
                }
                .font(.system(size: 11.5))
                .foregroundStyle(AmbientDesign.Palette.tertiaryText)
            }
            Spacer(minLength: 8)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(AmbientDesign.Palette.secondaryText)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(AmbientDesign.Palette.quietFill))
            }
            .buttonStyle(AmbientPressScaleButtonStyle(pressedScale: 0.9))
            .ambientPointingHandCursor()
            .opacity(isHovering ? 1 : 0)
            .help("Forget this")
            .accessibilityLabel("Forget this")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(isHovering ? AmbientDesign.Palette.rowHover : .clear)
        .onHover { hovering in isHovering = hovering }
    }
}

// MARK: - Skills

struct AmbientSkillsSettingsPage: View {
    var skillStore: any SkillStore

    @State private var skills: [SkillSummary]?
    @State private var errorMessage: String?

    var body: some View {
        AmbientSettingsPage(section: .skills) {
            AmbientCapsuleButton(title: "Install from folder", systemImageName: "folder.badge.plus", prominence: .secondary, surface: .window, action: chooseSkillFolder)
        } content: {
            if let errorMessage { AmbientInlineError(message: errorMessage) }
            if let skills {
                let personalSkills = skills.filter { !$0.isBuiltIn }
                let builtInSkills = skills.filter(\.isBuiltIn)
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Yours")
                    if personalSkills.isEmpty {
                        Text("Install a folder that has a SKILL.md file in it, or ask Ambient to write one.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(AmbientDesign.Palette.secondaryText)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AmbientDesign.Palette.cardHairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    } else {
                        AmbientListCard(items: personalSkills) { skill in
                            AmbientSkillRow(skill: skill) { delete(skill) }
                        }
                    }
                }
                if !builtInSkills.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("Built in")
                        AmbientListCard(items: builtInSkills) { skill in
                            AmbientSkillRow(skill: skill, onDelete: nil)
                        }
                    }
                }
            } else {
                AmbientListCard(items: Array(0..<4).map(LoadingPlaceholder.init)) { placeholder in AmbientLoadingRow(index: placeholder.id) }
            }
        }
        .task {
            skills = await skillStore.skills()
            for await updatedSkills in skillStore.updates() {
                withAnimation(.easeOut(duration: 0.2)) { skills = updatedSkills }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(AmbientDesign.Typeface.sectionLabel)
            .foregroundStyle(AmbientDesign.Palette.secondaryText)
            .padding(.leading, 4)
    }

    private func chooseSkillFolder() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Install"
        openPanel.message = "Choose a skill folder. It needs a SKILL.md file inside."
        guard openPanel.runModal() == .OK, let folderURL = openPanel.url else { return }
        errorMessage = nil
        Task {
            do {
                try await skillStore.install(fromDirectory: folderURL)
            } catch {
                errorMessage = "That folder could not be installed. Check it has a SKILL.md file."
            }
        }
    }

    private func delete(_ skill: SkillSummary) {
        errorMessage = nil
        Task {
            do {
                try await skillStore.delete(skillName: skill.name)
            } catch {
                errorMessage = "Could not delete \(skill.name)."
            }
        }
    }

    private struct LoadingPlaceholder: Identifiable { var id: Int }
}

struct AmbientSkillRow: View {
    var skill: SkillSummary
    /// Nil for built-in skills, which cannot be deleted.
    var onDelete: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: skill.isBuiltIn ? "shippingbox" : "doc.text")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AmbientDesign.Palette.secondaryText)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(AmbientDesign.Palette.quietFill))
            VStack(alignment: .leading, spacing: 3) {
                Text(skill.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AmbientDesign.Palette.primaryText)
                Text(skill.description)
                    .font(.system(size: 12))
                    .foregroundStyle(AmbientDesign.Palette.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let onDelete {
                AmbientCapsuleButton(title: "Delete", prominence: .quiet, surface: .window, isCompact: true, action: onDelete)
                    .opacity(isHovering ? 1 : 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(isHovering ? AmbientDesign.Palette.rowHover : .clear)
        .onHover { hovering in isHovering = hovering }
    }
}

// MARK: - Activity

struct AmbientActivitySettingsPage: View {
    var backgroundTaskStore: any BackgroundTaskStore

    @State private var backgroundTasks: [AmbientBackgroundTask]?
    @Binding var selectedTaskID: UUID?
    @State private var transcriptText: String?
    /// A finished agent's report is shown by default; this switches to everything it printed while working.
    @State private var isShowingActivityLog = false
    @State private var didCopyReport = false

    var body: some View {
        AmbientSettingsPage(section: .activity, scrolls: false) {
            if let backgroundTasks {
                if backgroundTasks.isEmpty {
                    AmbientEmptyState(symbolName: "clock.arrow.circlepath", title: "No background work yet", message: "When you ask Ambient to start an agent or run a command, it shows up here.")
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        ScrollView(.vertical) {
                            VStack(spacing: 2) {
                                ForEach(backgroundTasks) { task in
                                    AmbientActivityTaskRow(backgroundTask: task, isSelected: task.id == selectedTaskID) {
                                        selectedTaskID = task.id
                                    }
                                }
                            }
                            .padding(6)
                        }
                        .frame(width: 230)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AmbientDesign.Palette.cardBackground))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AmbientDesign.Palette.cardHairline, lineWidth: 1))

                        transcriptPane
                    }
                    .frame(maxHeight: .infinity)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 40)
            }
        }
        .task {
            let initialTasks = await backgroundTaskStore.tasks()
            backgroundTasks = initialTasks
            if selectedTaskID == nil { selectedTaskID = initialTasks.first?.id }
            for await updatedTasks in backgroundTaskStore.updates() {
                backgroundTasks = updatedTasks
                if let selectedTaskID, !updatedTasks.contains(where: { $0.id == selectedTaskID }) {
                    self.selectedTaskID = updatedTasks.first?.id
                }
            }
        }
        .task(id: selectedTaskID) {
            transcriptText = nil
            isShowingActivityLog = false
            didCopyReport = false
            guard let selectedTaskID else { return }
            // Re-read while the task runs so the transcript follows it.
            while !Task.isCancelled {
                transcriptText = await backgroundTaskStore.transcript(taskID: selectedTaskID)
                let isRunning = backgroundTasks?.first(where: { $0.id == selectedTaskID })?.status == .running
                guard isRunning else { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private var transcriptPane: some View {
        let selectedTask = backgroundTasks?.first(where: { $0.id == selectedTaskID })
        return VStack(alignment: .leading, spacing: 0) {
            if let selectedTask {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedTask.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AmbientDesign.Palette.primaryText)
                    Text(transcriptCaption(for: selectedTask))
                        .font(.system(size: 11.5))
                        .foregroundStyle(AmbientDesign.Palette.tertiaryText)
                    if selectedTask.hasReport, let reportText = selectedTask.result {
                        HStack(spacing: 6) {
                            AmbientCapsuleButton(title: "Save as file", systemImageName: "square.and.arrow.down", prominence: .secondary, surface: .window, isCompact: true) {
                                saveReport(reportText, title: selectedTask.title)
                            }
                            AmbientCapsuleButton(title: didCopyReport ? "Copied" : "Copy", prominence: .quiet, surface: .window, isCompact: true) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(reportText, forType: .string)
                                didCopyReport = true
                            }
                            Spacer(minLength: 8)
                            AmbientCapsuleButton(title: isShowingActivityLog ? "Show report" : "Show activity log", prominence: .quiet, surface: .window, isCompact: true) {
                                isShowingActivityLog.toggle()
                            }
                        }
                        .padding(.top, 8)
                        .padding(.leading, -2)
                    }
                }
                .padding(14)
                AmbientGroupDivider().padding(.leading, -14)
            }
            ScrollView(.vertical) {
                if let selectedTask, selectedTask.hasReport, !isShowingActivityLog, let reportText = selectedTask.result {
                    AmbientLightMarkdownView(markdownText: reportText, surface: .window)
                        .textSelection(.enabled)
                        .frame(maxWidth: 620, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                } else {
                    Text(transcriptText ?? "Loading transcript")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(transcriptText == nil ? AmbientDesign.Palette.tertiaryText : AmbientDesign.Palette.primaryText)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AmbientDesign.Palette.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AmbientDesign.Palette.cardHairline, lineWidth: 1))
    }

    /// Reports are markdown; the person picks where the file goes, so no folder access is needed up front.
    private func saveReport(_ reportText: String, title: String) {
        let savePanel = NSSavePanel()
        let safeTitle = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: " ")
        savePanel.nameFieldStringValue = "\(safeTitle).md"
        savePanel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard savePanel.runModal() == .OK, let fileURL = savePanel.url else { return }
        do {
            try reportText.write(to: fileURL, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func transcriptCaption(for backgroundTask: AmbientBackgroundTask) -> String {
        let started = backgroundTask.startedAt.formatted(date: .abbreviated, time: .shortened)
        let duration = AmbientElapsedTimeFormatter.string(from: backgroundTask.startedAt, to: backgroundTask.finishedAt ?? Date())
        return "\(backgroundTask.kind.displayName), started \(started), ran \(duration)"
    }
}

struct AmbientActivityTaskRow: View {
    var backgroundTask: AmbientBackgroundTask
    var isSelected: Bool
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                statusGlyph.frame(width: 14, height: 14).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(backgroundTask.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(AmbientDesign.Palette.primaryText)
                        .lineLimit(1)
                    Text(backgroundTask.startedAt.formatted(.relative(presentation: .named)))
                        .font(.system(size: 11))
                        .foregroundStyle(AmbientDesign.Palette.tertiaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? AmbientDesign.Palette.selectedRow : (isHovering ? AmbientDesign.Palette.rowHover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovering = hovering }
        .ambientPointingHandCursor()
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch backgroundTask.status {
        case .running: AmbientRunningArc(diameter: 11)
        case .succeeded: Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(AmbientDesign.Palette.secondaryText)
        case .failed: Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(AmbientDesign.Palette.alertDeep)
        case .cancelled: Image(systemName: "minus.circle.fill").font(.system(size: 12)).foregroundStyle(AmbientDesign.Palette.tertiaryText)
        }
    }
}

// MARK: - Window

/// The settings window. A normal, focusable window in Ambient's own style.
///
///     let settingsController = AmbientSettingsWindowController(model: settingsModel, services: services)
///     settingsController.show(section: .connectors)
@MainActor
public final class AmbientSettingsWindowController {
    public let model: AmbientSettingsModel
    private let window: NSWindow

    public init(model: AmbientSettingsModel, services: AmbientSettingsServices) {
        self.model = model
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 820, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Ambient Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 780, height: 560)
        window.contentView = NSHostingView(rootView: AmbientSettingsView(model: model, services: services))
        window.center()
        window.setFrameAutosaveName("AmbientSettingsWindow")
    }

    public func show(section: AmbientSettingsSection? = nil) {
        if let section { model.selectedSection = section }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    public func close() {
        window.close()
    }

    /// The hosting window, for captures and tests.
    public var hostingWindow: NSWindow { window }
}

import AmbientContracts
import Foundation

/// Realistic content for the demo: the kind of things a person actually asks Ambient for.
enum DemoSampleData {

    // MARK: Replies

    static let shortReply = "Done. It's on your calendar."

    static let mediumReply = """
    You have **two new emails** from Priya about the launch. She moved the review to *Thursday at 3pm* and asked whether the pricing page is ready.

    I drafted a reply saying yes and attached the latest link. Want me to send it?
    """

    static let longReply = """
    ## This week

    Here is what needs you, in order:

    1. **Launch review** moved to Thursday at 3pm. Priya wants the pricing page by then.
    2. **Invoice from Fernhill** is due Friday. It matches last month, so I can pay it if you say so.
    3. **Sam asked for feedback** on the onboarding copy in Slack. Two messages, both short.

    The Codex agent finished the `settings-refactor` branch. All 214 tests pass and it opened a pull request.

    - Nothing urgent in GitHub besides that.
    - Linear has three new issues assigned to you, all low priority.

    I left your Friday afternoon clear because you asked me to keep it for deep work. If the review runs long, I can move your 4:30 with Alex to Monday.

    Ask me to draft any of these and I will do it in the background.
    """

    // MARK: Background tasks

    static let refactorTaskIdentifier = UUID(uuidString: "6A1D2E8B-0000-4000-8000-000000000001")!
    static let testsTaskIdentifier = UUID(uuidString: "6A1D2E8B-0000-4000-8000-000000000002")!
    static let inboxTaskIdentifier = UUID(uuidString: "6A1D2E8B-0000-4000-8000-000000000003")!
    static let failedTaskIdentifier = UUID(uuidString: "6A1D2E8B-0000-4000-8000-000000000004")!

    static func backgroundTasks(relativeTo now: Date) -> [BackgroundTask] {
        [
            BackgroundTask(
                id: refactorTaskIdentifier, kind: .codexAgent, title: "Refactor the settings screen",
                status: .running, workingDirectory: NSHomeDirectory() + "/code/ambient",
                startedAt: now.addingTimeInterval(-262), finishedAt: nil,
                latestActivity: "Editing SettingsView.swift", result: nil
            ),
            BackgroundTask(
                id: testsTaskIdentifier, kind: .shellCommand, title: "Run the test suite",
                status: .running, workingDirectory: NSHomeDirectory() + "/code/ambient",
                startedAt: now.addingTimeInterval(-41), finishedAt: nil,
                latestActivity: "148 of 214 passed", result: nil
            ),
            BackgroundTask(
                id: inboxTaskIdentifier, kind: .claudeAgent, title: "Summarise the launch thread",
                status: .succeeded, workingDirectory: nil,
                startedAt: now.addingTimeInterval(-900), finishedAt: now.addingTimeInterval(-780),
                latestActivity: "Wrote the summary",
                result: "Priya moved the review to Thursday. Pricing page is the only blocker."
            ),
        ]
    }

    static func failedTask(relativeTo now: Date) -> BackgroundTask {
        BackgroundTask(
            id: failedTaskIdentifier, kind: .shellCommand, title: "Deploy the preview",
            status: .failed, workingDirectory: NSHomeDirectory() + "/code/site",
            startedAt: now.addingTimeInterval(-95), finishedAt: now.addingTimeInterval(-3),
            latestActivity: "Build failed", result: "The build stopped: a page imports a file that no longer exists."
        )
    }

    static func transcript(for task: BackgroundTask) -> String {
        switch task.kind {
        case .codexAgent:
            return """
            > Refactor the settings screen into one file per page.

            Reading Sources/Settings/SettingsView.swift (488 lines)
            Plan: split General, Connectors, Memory, Skills, Activity and Account into their own files.
            Created Sources/Settings/GeneralPage.swift
            Created Sources/Settings/ConnectorsPage.swift
            Editing SettingsView.swift
            """
        case .claudeAgent:
            return """
            > Summarise the launch thread in Gmail.

            Searched Gmail for "launch review" (12 messages)
            Read 4 messages from Priya and Sam
            Priya moved the review to Thursday. Pricing page is the only blocker.
            """
        case .shellCommand:
            return """
            $ swift test --parallel
            Building for debugging...
            Test Suite 'All tests' started
            148 of 214 passed
            """
        }
    }

    // MARK: Memory

    static func memoryItems(relativeTo now: Date) -> [MemoryItem] {
        [
            MemoryItem(id: UUID(), text: "Keeps Friday afternoons free for deep work.", createdAt: now.addingTimeInterval(-3_600), wasLearnedAutomatically: true),
            MemoryItem(id: UUID(), text: "Prefers short replies, no greetings in drafts.", createdAt: now.addingTimeInterval(-86_400), wasLearnedAutomatically: true),
            MemoryItem(id: UUID(), text: "Works on the Ambient repo in ~/code/ambient.", createdAt: now.addingTimeInterval(-86_400 * 3), wasLearnedAutomatically: false),
            MemoryItem(id: UUID(), text: "Priya leads the launch; Sam owns onboarding copy.", createdAt: now.addingTimeInterval(-86_400 * 6), wasLearnedAutomatically: true),
            MemoryItem(id: UUID(), text: "Pay invoices from Fernhill only after asking.", createdAt: now.addingTimeInterval(-86_400 * 12), wasLearnedAutomatically: false),
        ]
    }

    // MARK: Skills

    static let skills: [SkillSummary] = [
        SkillSummary(name: "inbox-triage", description: "Sorts new email into reply, read later and ignore.", isBuiltIn: true, directory: URL(fileURLWithPath: "/tmp/skills/inbox-triage")),
        SkillSummary(name: "meeting-prep", description: "Pulls notes, attendees and open threads before a meeting.", isBuiltIn: true, directory: URL(fileURLWithPath: "/tmp/skills/meeting-prep")),
        SkillSummary(name: "write-a-skill", description: "Writes a new skill from something you showed Ambient how to do.", isBuiltIn: true, directory: URL(fileURLWithPath: "/tmp/skills/write-a-skill")),
        SkillSummary(name: "weekly-review", description: "Every Friday: what shipped, what slipped, what is next.", isBuiltIn: false, directory: URL(fileURLWithPath: "/tmp/skills/weekly-review")),
    ]

    // MARK: Connectors

    static let connectorCatalogue: [(slug: String, name: String)] = [
        ("gmail", "Gmail"), ("googlecalendar", "Google Calendar"), ("slack", "Slack"), ("github", "GitHub"),
        ("linear", "Linear"), ("notion", "Notion"), ("googledrive", "Google Drive"), ("figma", "Figma"),
        ("stripe", "Stripe"), ("hubspot", "HubSpot"), ("jira", "Jira"), ("discord", "Discord"),
    ]

    // MARK: Approvals

    static let shellCommandApprovalTitle = "Run this command?"
    static let shellCommandApprovalDetail = "git push origin feature/settings-refactor"
    static let agentApprovalTitle = "Start a Codex agent?"
    static let agentApprovalDetail = "Fix the three failing tests in AmbientUITests and open a pull request when they pass."
}

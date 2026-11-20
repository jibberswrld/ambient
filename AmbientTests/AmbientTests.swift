//
//  AmbientTests.swift
//  AmbientTests
//
//  Created by thorfinn on 3/2/26.
//

import Foundation
import Testing
@testable import Ambient

@MainActor
struct AmbientTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func automationHookPreservesEscapedText() throws {
        let url = try #require(URL(string: "ambient://ask?text=reply%20to%20Sam%3A%20yes%20%26%20thanks%2B1%3F"))
        #expect(CompanionAppDelegate.automationText(from: url) == "reply to Sam: yes & thanks+1?")
    }

    @Test func automationHookRejectsOtherRoutesAndEmptyInput() throws {
        for address in ["ambient://open?text=hello", "https://ask?text=hello", "ambient://ask", "ambient://ask?text=%20%0A"] {
            let url = try #require(URL(string: address))
            #expect(CompanionAppDelegate.automationText(from: url) == nil)
        }
    }

}

//
//  AmbientTests.swift
//  AmbientTests
//
//  Created by thorfinn on 3/2/26.
//

import Foundation
import Testing
import AmbientUI
@testable import Ambient

@MainActor
struct AmbientTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = AmbientPermissionHelper.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = AmbientPermissionHelper.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = AmbientPermissionHelper.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func automationHookPreservesEscapedText() throws {
        let url = try #require(URL(string: "ambient://ask?text=reply%20to%20Sam%3A%20yes%20%26%20thanks%2B1%3F"))
        #expect(AmbientAppDelegate.automationText(from: url) == "reply to Sam: yes & thanks+1?")
    }

    @Test func automationHookRejectsOtherRoutesAndEmptyInput() throws {
        for address in ["ambient://open?text=hello", "https://ask?text=hello", "ambient://ask", "ambient://ask?text=%20%0A"] {
            let url = try #require(URL(string: address))
            #expect(AmbientAppDelegate.automationText(from: url) == nil)
        }
    }

    @Test func walletOmitsMissingPlanAndPercentage() throws {
        let summary = AmbientAppDelegate.accountSummary(from: ["account": ["handle": "test"], "balance_micros": 123],
            baseURL: try #require(URL(string: "https://publik.example/api/v1")))
        #expect(summary.publikHandle == "test")
        #expect(summary.planName == nil)
        #expect(summary.usageRemainingFraction == nil)
        #expect(summary.usageResetsOn == nil)
    }

    @Test func walletUsesReturnedPercentageWithoutInferringMoney() throws {
        let summary = AmbientAppDelegate.accountSummary(from: ["remaining_percent": NSNull(), "prepaid_remaining_percent": 42,
            "plan": ["label": "Plus"], "top_up_url": "https://publik.example/top-up"],
            baseURL: try #require(URL(string: "https://publik.example/api/v1")))
        #expect(summary.publikHandle == nil)
        #expect(summary.planName == "Plus")
        #expect(summary.usageRemainingFraction == 0.42)
        #expect(summary.manageAccountURL.absoluteString == "https://publik.example/top-up")
    }

}

import Foundation
import Testing
@testable import MailModel

/// R5N: fidelity of what the README marks ✅ "read from the bundle" (Mail.app's MainMenu.nib, toolbars, loctables).
@Suite("Probe_R5N fidelity")
struct Probe_R5NFidelityTests {
    /// Edit ▸ Include Attachments With Replies lists its choices in IncludeAttachments.allCases order
    /// (MailCommands.swift: `ForEach(IncludeAttachments.allCases …)`). Mail.app's MainMenu.nib, menu
    /// "Include Attachments With Replies" (#2124): items in this order, and their tags agree
    /// (always 96, never 97, whenAddingRecipients 98, ask 99).
    @Test func includeAttachmentsMenuOrderMatchesMainMenuNib() {
        let nib = ["Always", "Never", "When Adding Recipients", "Ask"]
        #expect(IncludeAttachments.allCases.map(\.title) == nib)
    }
}

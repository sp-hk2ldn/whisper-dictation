import AppKit
import Foundation
import Testing
@testable import WhisperDictationFeature

@MainActor
struct PasteboardTransactionTests {
    @Test
    func restoresCompleteClipboardWithoutOverwritingNewerChanges() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("WhisperDictationTests.\(UUID())")
        )
        let customType = NSPasteboard.PasteboardType(
            "io.github.sp-hk2ldn.whisperdictation.test"
        )
        let customData = Data([0x01, 0x02, 0x03])
        let originalItem = NSPasteboardItem()
        originalItem.setString("original", forType: .string)
        originalItem.setData(customData, forType: customType)
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([originalItem]))

        let transaction = PasteboardTransactionStore.begin(
            text: "dictated",
            on: pasteboard
        )
        #expect(transaction != nil)
        #expect(pasteboard.string(forType: .string) == "dictated")
        #expect(
            transaction.map {
                PasteboardTransactionStore.restore($0, on: pasteboard)
            } == true
        )
        #expect(pasteboard.string(forType: .string) == "original")
        #expect(
            pasteboard.pasteboardItems?.first?.data(forType: customType)
                == customData
        )

        let concurrentTransaction = PasteboardTransactionStore.begin(
            text: "second dictation",
            on: pasteboard
        )
        #expect(concurrentTransaction != nil)
        pasteboard.clearContents()
        pasteboard.setString("newer clipboard", forType: .string)
        #expect(
            concurrentTransaction.map {
                PasteboardTransactionStore.restore($0, on: pasteboard)
            } == false
        )
        #expect(pasteboard.string(forType: .string) == "newer clipboard")
    }
}

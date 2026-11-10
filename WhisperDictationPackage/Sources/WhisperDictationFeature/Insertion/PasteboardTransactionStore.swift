import AppKit
import Foundation

struct PasteboardSnapshot: Sendable {
    let items: [[String: Data]]
}

struct PasteboardTransaction: Sendable {
    let snapshot: PasteboardSnapshot
    let ownedChangeCount: Int
}

@MainActor
enum PasteboardTransactionStore {
    static func begin(
        text: String,
        on pasteboard: NSPasteboard
    ) -> PasteboardTransaction? {
        let startingChangeCount = pasteboard.changeCount
        var savedItems: [[String: Data]] = []

        for item in pasteboard.pasteboardItems ?? [] {
            var savedItem: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    return nil
                }
                savedItem[type.rawValue] = data
            }
            savedItems.append(savedItem)
        }

        guard pasteboard.changeCount == startingChangeCount else {
            return nil
        }

        let snapshot = PasteboardSnapshot(items: savedItems)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            _ = restore(snapshot, to: pasteboard)
            return nil
        }

        return PasteboardTransaction(
            snapshot: snapshot,
            ownedChangeCount: pasteboard.changeCount
        )
    }

    static func restore(
        _ transaction: PasteboardTransaction,
        on pasteboard: NSPasteboard
    ) -> Bool {
        guard pasteboard.changeCount == transaction.ownedChangeCount else {
            return false
        }
        return restore(transaction.snapshot, to: pasteboard)
    }

    private static func restore(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: NSPasteboard
    ) -> Bool {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return true }

        let items = snapshot.items.map { savedItem in
            let item = NSPasteboardItem()
            for (rawType, data) in savedItem {
                item.setData(
                    data,
                    forType: NSPasteboard.PasteboardType(rawType)
                )
            }
            return item
        }
        return pasteboard.writeObjects(items)
    }
}

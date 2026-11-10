import Foundation
import Testing
@testable import WhisperDictationFeature

struct CodexMicroLightingTests {
    private static let working = MicroLightSetting(
        effect: .solid,
        color: 0x304FFE,
        brightness: 1,
        speed: 0
    )
    private static let breathing = MicroLightSetting(
        effect: .breath,
        color: 0x00FF4C,
        brightness: 1,
        speed: 0.4
    )
    private static let ring = MicroLightSetting(
        effect: .snake,
        color: 0x2E8B57,
        brightness: 1,
        speed: 0.4
    )

    @Test func lightingConfigSurvivesUSBAndBluetoothChunking() throws {
        let command = MicroCommand.lightingConfig(
            keys: .off,
            ambient: Self.ring
        )
        for bluetooth in [false, true] {
            let reports = try MicroHIDProtocol.reports(
                method: MicroHIDProtocol.method(for: command),
                parameters: MicroHIDProtocol.parameters(for: command),
                id: 901,
                bluetooth: bluetooth
            )
            let object = try decodeRequest(reports, bluetooth: bluetooth)
            let parameters = try #require(object["params"] as? [String: [String: Any]])
            #expect(reports.count > 1)
            #expect(reports.allSatisfy { $0.count == (bluetooth ? 64 : 63) })
            #expect(object["method"] as? String == "v.oai.rgbcfg")
            #expect(parameters["ambient"]?["c"] as? Int == 0x2E8B57)
            #expect(parameters["ambient"]?["e"] as? Int == 2)
            #expect(parameters["keys"]?["e"] as? Int == 0)
        }
    }

    @Test func threadsLightingEncodesEverySlotWithCodexFields() throws {
        let slots = [Self.working, Self.breathing] + Array(repeating: MicroLightSetting.off, count: 4)
        let command = MicroCommand.threadsLighting(slots)
        let reports = try MicroHIDProtocol.reports(
            method: MicroHIDProtocol.method(for: command),
            parameters: MicroHIDProtocol.parameters(for: command),
            id: 12,
            bluetooth: true
        )
        let object = try decodeRequest(reports, bluetooth: true)
        let encoded = try #require(object["params"] as? [[String: Double]])
        let expected: [[String: Double]] = [
            ["id": 0, "c": 0x304FFE, "b": 1, "e": 1, "s": 0, "sk": 0, "sa": 0],
            ["id": 1, "c": 0x00FF4C, "b": 1, "e": 4, "s": 0.4, "sk": 0, "sa": 0]
        ]
        #expect(object["method"] as? String == "v.oai.thstatus")
        #expect(encoded.count == 6)
        #expect(Array(encoded.prefix(2)) == expected)
        #expect(encoded[5] == ["id": 5, "c": 0, "b": 0, "e": 0, "s": 0, "sk": 0, "sa": 0])
    }

    @Test func writePlanSendsEverythingWhenNothingIsApplied() {
        let picture = MicroPicture(
            slots: MicroPicture.allOff.slots,
            keys: .off,
            ambient: Self.ring
        )
        #expect(MicroWritePlan.commands(for: picture, after: nil).count == 2)
    }

    @Test func writePlanSendsOnlyTheChangedSlots() {
        let picture = MicroPicture(
            slots: [Self.working] + Array(repeating: MicroLightSetting.off, count: 5),
            keys: .off,
            ambient: .off
        )
        let expected = [MicroCommand.threadsLighting(picture.slots)]
        #expect(MicroWritePlan.commands(for: picture, after: .allOff) == expected)
    }

    @Test func writePlanSendsNothingWhenPictureIsUnchanged() {
        #expect(MicroWritePlan.commands(for: .allOff, after: .allOff).isEmpty)
    }

    @Test func parserIgnoresOversizedInputAndRecovers() {
        var parser = MicroHIDProtocol.MessageParser()
        #expect(parser.receive([6, 2, 61, 0]).isEmpty)
        for _ in 0..<300 {
            #expect(parser.receive([6, 2, 61] + Array(repeating: 32, count: 61)).isEmpty)
        }
        let line = Array("{\"id\":91,\"result\":{\"version\":\"0.4.1\"}}\r\n".utf8)
        #expect(parser.receive([6, 2, UInt8(line.count)] + line) == [reply(91, version: "0.4.1")])
    }

    @Test func parserJoinsANotificationSplitAcrossReports() {
        var parser = MicroHIDProtocol.MessageParser()
        let text = "{\"method\":\"v.oai.hid\",\"params\":{\"k\":\"AG02\",\"act\":1,\"ag\":3}}\r\n"
        let reports = frames(text, size: 20)
        let messages = reports.flatMap { parser.receive($0) }
        let expected = MicroMessage.notification(
            .key(
                key: "AG02",
                act: 1,
                agent: 3
            )
        )
        #expect(reports.count > 2)
        #expect(messages == [expected])
    }

    @Test func parserReadsAJoystickNotificationOnUSBFraming() {
        var parser = MicroHIDProtocol.MessageParser()
        let line = Array("{\"method\":\"v.oai.rad\",\"params\":{\"a\":0.25,\"d\":1}}\n".utf8)
        let expected = MicroMessage.notification(.joystick(angle: 0.25, distance: 1))
        #expect(parser.receive([2, UInt8(line.count)] + line) == [expected])
    }

    @Test func parserReturnsRepliesAndNotificationsFromOneReportInOrder() {
        var parser = MicroHIDProtocol.MessageParser()
        let text = "{\"id\":7,\"result\":null}\n{\"m\":\"v.oai.hid\",\"p\":{\"k\":\"AG00\",\"act\":0}}\n"
        let expected: [MicroMessage] = [
            reply(7, version: nil),
            .notification(
                .key(
                    key: "AG00",
                    act: 0,
                    agent: nil
                )
            )
        ]
        #expect(frames(text, size: 61).flatMap { parser.receive($0) } == expected)
    }

    @Test func parserMarksAnErrorReplyAsFailed() {
        var parser = MicroHIDProtocol.MessageParser()
        let line = Array("{\"id\":8,\"error\":{\"code\":-1},\"result\":null}\n".utf8)
        let expected = MicroMessage.reply(
            MicroReply(
                id: 8,
                succeeded: false,
                version: nil
            )
        )
        #expect(parser.receive([6, 2, UInt8(line.count)] + line) == [expected])
    }

    private func reply(_ id: Int, version: String?) -> MicroMessage {
        .reply(
            MicroReply(
                id: id,
                succeeded: true,
                version: version
            )
        )
    }

    private func frames(_ text: String, size: Int) -> [[UInt8]] {
        let bytes = Array(text.utf8)
        return stride(from: 0, to: bytes.count, by: size).map { offset in
            let chunk = Array(bytes[offset..<min(offset + size, bytes.count)])
            return [6, 2, UInt8(chunk.count)] + chunk
        }
    }

    private func decodeRequest(_ reports: [[UInt8]], bluetooth: Bool) throws -> [String: Any] {
        let header = bluetooth ? 1 : 0
        let message = reports.flatMap { report -> [UInt8] in
            let count = Int(report[header + 1])
            return Array(report[(header + 2)..<(header + 2 + count)])
        }
        return try #require(JSONSerialization.jsonObject(with: Data(message)) as? [String: Any])
    }
}

import Foundation

public enum TranscriptPolicy {
    public static func safeText(
        from transcript: FinalTranscript,
        for target: TargetToken
    ) -> SafeInsertionText? {
        let value: String

        switch target.kind {
        case .standard:
            value = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .terminal:
            value = terminalSafeText(transcript.text)
        }

        guard !value.isEmpty else { return nil }
        return SafeInsertionText(value: value)
    }

    private static func terminalSafeText(_ text: String) -> String {
        var output = ""
        var pendingSpace = false

        for scalar in text.unicodeScalars {
            if scalar == "\r" || scalar == "\n" || scalar == "\t" {
                pendingSpace = !output.isEmpty
                continue
            }

            if CharacterSet.controlCharacters.contains(scalar) {
                continue
            }

            if pendingSpace, scalar != " " {
                output.append(" ")
            }
            pendingSpace = false
            output.unicodeScalars.append(scalar)
        }

        return output.trimmingCharacters(in: .whitespaces)
    }
}

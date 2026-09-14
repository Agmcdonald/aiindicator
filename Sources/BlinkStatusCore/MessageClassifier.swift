import Foundation

public enum MessageClassifier {
    public static func needsInput(_ message: String?) -> Bool {
        guard let message else {
            return false
        }

        let normalized = normalize(message)
        guard !normalized.isEmpty else {
            return false
        }

        if normalized.contains("let me know") {
            return false
        }

        if normalized.hasSuffix("?") {
            return true
        }

        return [
            "please attach",
            "attach the missing",
            "need your approval",
            "need your permission",
            "needs permission",
            "requires permission",
            "choose ",
            "select ",
        ].contains { normalized.contains($0) }
    }

    static func normalize(_ message: String) -> String {
        message
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }
}

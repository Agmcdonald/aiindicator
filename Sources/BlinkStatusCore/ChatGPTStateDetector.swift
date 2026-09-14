import Foundation

public struct AccessibilitySnapshot: Sendable {
    public let labels: [String]
    public let buttons: [String]
    public let promptEnabled: Bool

    public init(labels: [String], buttons: [String], promptEnabled: Bool) {
        self.labels = labels
        self.buttons = buttons
        self.promptEnabled = promptEnabled
    }
}

public enum ChatGPTStateDetector {
    public static func detect(_ snapshot: AccessibilitySnapshot) -> ActivityState {
        let buttonLabels = snapshot.buttons.map(MessageClassifier.normalize)
        let hasPermissionRequest = snapshot.labels.contains { label in
            let normalized = MessageClassifier.normalize(label)
            return normalized.contains("permission") || normalized.contains("approval")
        }

        if hasPermissionRequest && buttonLabels.contains(where: approvalControls.contains) {
            return .attention
        }

        if buttonLabels.contains(where: workingControls.contains) {
            return .working
        }

        if let latestResponse = snapshot.labels.last, MessageClassifier.needsInput(latestResponse) {
            return .attention
        }

        return .ready
    }

    private static let approvalControls: Set<String> = ["allow", "approve", "continue", "confirm"]
    private static let workingControls: Set<String> = ["stop generating", "stop", "cancel response"]
}

@preconcurrency import ApplicationServices
import BlinkStatusCore
import Foundation

/// Only the derived activity state survives a sample. Conversation text is
/// neither logged nor retained between polls.
protocol AccessibilityMonitoring: Sendable {
    func start() async
    func stop() async
}

actor AccessibilityMonitor: AccessibilityMonitoring {
    typealias Reader = @Sendable () -> AccessibilitySnapshot?
    private let read: Reader
    private let onChange: @Sendable (ActivityState?) async -> Void
    private var lastSample: TimeInterval?
    private var lastState: ActivityState?
    private var hasSample = false
    private var sampling = false
    private var loop: Task<Void, Never>?
    private var generation = 0

    init(read: @escaping Reader, onChange: @escaping @Sendable (ActivityState?) async -> Void) {
        self.read = read
        self.onChange = onChange
    }

    init(processID: pid_t, onChange: @escaping @Sendable (ActivityState?) async -> Void) {
        self.read = { AccessibilityTreeReader.snapshot(processID: processID) }
        self.onChange = onChange
    }

    static func requestTrust() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sample(at: ProcessInfo.processInfo.systemUptime)
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }

    func stop() {
        generation += 1
        loop?.cancel()
        loop = nil
    }

    func sample(at uptime: TimeInterval) async {
        guard !sampling, lastSample.map({ uptime - $0 >= 0.5 }) ?? true else { return }
        sampling = true
        lastSample = uptime
        let sampleGeneration = generation
        let read = read
        let state = await Task.detached(priority: .utility) {
            // Raw strings exist only inside this closure and the tree reader.
            read().map(ChatGPTStateDetector.detect)
        }.value
        sampling = false
        guard sampleGeneration == generation else { return }
        guard !hasSample || state != lastState else { return }
        hasSample = true
        lastState = state
        await onChange(state)
    }
}

enum AccessibilityTreeReader {
    static func snapshot(processID: pid_t) -> AccessibilitySnapshot? {
        guard AXIsProcessTrusted() else { return nil }
        let root = AXUIElementCreateApplication(processID)
        return snapshot(root: root)
    }

    static func snapshot(root: AXUIElement,
                         setTimeout: (AXUIElement, Float) -> AXError = AXUIElementSetMessagingTimeout,
                         readAttributes: (AXUIElement, CFArray) -> [Any]? = nativeAttributes) -> AccessibilitySnapshot? {
        let attributes = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                          kAXValueAttribute, kAXEnabledAttribute, kAXChildrenAttribute,
                          kAXRoleDescriptionAttribute] as CFArray
        let deadline = ProcessInfo.processInfo.systemUptime + 0.25
        var pending: [(AXUIElement, Int, Bool)] = [(root, 0, false)]
        var visited = 0
        var permissionLabels: [String] = []
        var buttons: [String] = []
        var assistantFragments: [String] = []
        var promptEnabled = false
        var readRoot = false

        while let (element, depth, inheritedAssistant) = pending.popLast(),
              visited < 1_500, ProcessInfo.processInfo.systemUptime < deadline {
            visited += 1
            // Messaging timeout belongs to this AX object, not its process/tree.
            // Skip an element if its bound cannot be configured safely.
            guard setTimeout(element, 0.05) == .success else { continue }
            guard let values = readAttributes(element, attributes), values.count == 7 else { continue }
            readRoot = true
            let role = values[0] as? String ?? ""
            let title = String((values[1] as? String ?? "").prefix(8_192))
            let description = String((values[2] as? String ?? "").prefix(8_192))
            let value = String((values[3] as? String ?? "").prefix(8_192))
            let enabled = values[4] as? Bool ?? true
            let roleDescription = values[6] as? String ?? ""
            let marker = "\(title) \(description) \(roleDescription)".lowercased()
            let explicitAssistant = marker.contains("assistant") || marker.contains("claude said") || marker.contains("chatgpt said")
            let isAssistant = explicitAssistant || inheritedAssistant
            if explicitAssistant && !inheritedAssistant { assistantFragments.removeAll(keepingCapacity: true) }
            if role == kAXButtonRole as String, enabled {
                buttons.append(contentsOf: [title, description].filter { !$0.isEmpty })
            }
            if role == kAXTextAreaRole as String || role == kAXTextFieldRole as String {
                promptEnabled = promptEnabled || enabled
                // Editable prompt text is never interpreted as an assistant response.
            } else {
                let text = [title, description, value].filter { !$0.isEmpty }.joined(separator: " ")
                let normalized = text.lowercased()
                if normalized.contains("permission") || normalized.contains("approval") {
                    permissionLabels.append(String(text.prefix(1_024)))
                }
                if isAssistant && role == kAXStaticTextRole as String && assistantFragments.count < 64 {
                    assistantFragments.append(value.isEmpty ? title : value)
                }
            }
            if depth < 24, let children = values[5] as? [AXUIElement] {
                for child in children.prefix(256).reversed() { pending.append((child, depth + 1, isAssistant)) }
            }
        }
        guard readRoot else { return nil }
        permissionLabels.append(String(assistantFragments.joined(separator: " ").prefix(32_768)))
        return AccessibilitySnapshot(labels: permissionLabels, buttons: buttons, promptEnabled: promptEnabled)
    }

    private static func nativeAttributes(_ element: AXUIElement, _ attributes: CFArray) -> [Any]? {
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes, [], &result) == .success else { return nil }
        return result as? [Any]
    }
}

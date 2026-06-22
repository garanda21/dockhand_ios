import Foundation
import SwiftUI
import UIKit
import Yams

enum StackEditorValidator {
    static func validateCompose(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StackEditorValidationError.emptyCompose
        }

        do {
            _ = try Yams.compose(yaml: text)
        } catch {
            throw StackEditorValidationError.invalidCompose(error.localizedDescription)
        }
    }

    static func validateEnv(_ text: String) throws {
        let lines = text.components(separatedBy: .newlines)

        for (index, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let body = trimmed.hasPrefix("export ")
                ? String(trimmed.dropFirst("export ".count))
                : trimmed

            guard let separatorIndex = body.firstIndex(of: "=") else {
                throw StackEditorValidationError.invalidEnv(line: index + 1, reason: "Missing '=' separator")
            }

            let key = String(body[..<separatorIndex]).trimmingCharacters(in: .whitespaces)
            guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
                throw StackEditorValidationError.invalidEnv(line: index + 1, reason: "Invalid variable name '\(key)'")
            }
        }
    }
}

enum StackEditorValidationError: LocalizedError {
    case emptyCompose
    case invalidCompose(String)
    case invalidEnv(line: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .emptyCompose:
            return "Compose file cannot be empty."
        case .invalidCompose(let reason):
            return "Invalid YAML: \(reason)"
        case .invalidEnv(let line, let reason):
            return "Invalid .env on line \(line): \(reason)"
        }
    }
}

enum StackEditorSyntaxKind {
    case yaml
    case env
}

@MainActor
struct SyntaxHighlightingTextEditor: UIViewRepresentable {
    @Binding var text: String
    let kind: StackEditorSyntaxKind

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.keyboardDismissMode = .interactive
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        view.textContainer.lineFragmentPadding = 0
        view.tintColor = UIColor(Color.accentColor)
        context.coordinator.applyHighlight(to: view)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyHighlight(to: uiView)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SyntaxHighlightingTextEditor
        private var isApplyingHighlight = false

        init(parent: SyntaxHighlightingTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingHighlight else { return }
            parent.text = textView.text
            applyHighlight(to: textView)
        }

        func applyHighlight(to textView: UITextView) {
            let selectedRange = textView.selectedRange
            let currentText = parent.text

            if textView.text == currentText, textView.attributedText.length > 0 {
                textView.typingAttributes = StackEditorHighlighter.typingAttributes
                return
            }

            isApplyingHighlight = true
            textView.attributedText = StackEditorHighlighter.highlightedText(for: currentText, kind: parent.kind)
            let clampedLocation = min(selectedRange.location, textView.attributedText.length)
            let clampedLength = min(selectedRange.length, max(0, textView.attributedText.length - clampedLocation))
            textView.selectedRange = NSRange(location: clampedLocation, length: clampedLength)
            textView.typingAttributes = StackEditorHighlighter.typingAttributes
            isApplyingHighlight = false
        }
    }
}

@MainActor
private enum StackEditorHighlighter {
    static let font = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
    static let typingAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: UIColor.label
    ]

    private static let keyColor = UIColor(Color.blue)
    private static let valueColor = UIColor(Color.primary)
    private static let commentColor = UIColor(Color.orange)
    private static let stringColor = UIColor(Color.red)
    private static let scalarColor = UIColor(Color.purple)
    private static let punctuationColor = UIColor.secondaryLabel

    static func highlightedText(for text: String, kind: StackEditorSyntaxKind) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: valueColor
            ]
        )

        switch kind {
        case .yaml:
            highlightYAML(in: attributed, text: text)
        case .env:
            highlightEnv(in: attributed, text: text)
        }

        return attributed
    }

    private static func highlightYAML(in attributed: NSMutableAttributedString, text: String) {
        apply(pattern: #"(?m)^\s*[^#\s][^:\n]*?(?=:\s|:$)"#, color: keyColor, in: attributed, text: text)
        apply(pattern: #"(?m)#.*$"#, color: commentColor, in: attributed, text: text)
        apply(pattern: #""[^"\n]*"|'[^'\n]*'"#, color: stringColor, in: attributed, text: text)
        apply(pattern: #"(?m)(?<=:\s)(true|false|null|~|[0-9]+(?:\.[0-9]+)?)\b"#, color: scalarColor, in: attributed, text: text)
        apply(pattern: #"(?m)^\s*-\s"#, color: punctuationColor, in: attributed, text: text)
    }

    private static func highlightEnv(in attributed: NSMutableAttributedString, text: String) {
        apply(pattern: #"(?m)^\s*#.*$"#, color: commentColor, in: attributed, text: text)
        apply(pattern: #"(?m)^\s*(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*(?==)"#, color: keyColor, in: attributed, text: text)
        apply(pattern: #"(?m)(?<==).*?$"#, color: stringColor, in: attributed, text: text)
    }

    private static func apply(pattern: String, color: UIColor, in attributed: NSMutableAttributedString, text: String) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let range = match?.range, range.location != NSNotFound else { return }
            attributed.addAttribute(.foregroundColor, value: color, range: range)
        }
    }
}

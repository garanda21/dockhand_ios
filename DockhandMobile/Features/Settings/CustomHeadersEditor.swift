import DockhandAPI
import SwiftUI

/// Editable copy of a custom header. Saved values are kept only in memory and
/// never rendered; typing a new value replaces the saved one on save.
struct CustomHeaderDraft: Identifiable, Hashable {
    let id: UUID
    var name: String
    var newValue: String
    var storedValue: String?
    var isReplacingValue: Bool

    init(id: UUID = UUID(), name: String, newValue: String = "", storedValue: String? = nil) {
        self.id = id
        self.name = name
        self.newValue = newValue
        self.storedValue = storedValue
        self.isReplacingValue = storedValue == nil
    }

    init(header: DockhandCustomHeader) {
        self.init(id: header.id, name: header.name, storedValue: header.value)
    }

    var effectiveValue: String {
        isReplacingValue || storedValue == nil ? newValue : storedValue ?? ""
    }

    var header: DockhandCustomHeader {
        DockhandCustomHeader(id: id, name: name, value: effectiveValue)
    }
}

extension [CustomHeaderDraft] {
    var headers: [DockhandCustomHeader] { map(\.header) }

    var issues: [UUID: DockhandCustomHeaderIssue] {
        DockhandCustomHeaderValidator.issues(for: headers)
    }

    var matchedPresets: [DockhandCustomHeaderPreset] {
        let names = Set(map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        return DockhandCustomHeaderPreset.allCases.filter { preset in
            preset.headerNames.contains { names.contains($0.lowercased()) }
        }
    }
}

extension DockhandCustomHeaderIssue {
    /// Blank fields are expected while typing, so they are shown softly.
    var isMissingInput: Bool {
        self == .emptyName || self == .emptyValue
    }

    var localizedDescription: String {
        switch self {
        case .emptyName:
            String(localized: "Enter a header name.")
        case .invalidNameCharacters:
            String(localized: "Header names can only use letters, numbers and - _ . ! # $ % & ' * + ^ ` | ~")
        case .nameTooLong:
            String(localized: "Header name is too long.")
        case .reservedName:
            String(localized: "This header is managed by the app and cannot be overridden.")
        case .duplicateName:
            String(localized: "This header is already in the list.")
        case .emptyValue:
            String(localized: "Enter a value.")
        case .invalidValueCharacters:
            String(localized: "Values cannot contain line breaks, control characters or emoji.")
        case .valueTooLong:
            String(localized: "Value is too long.")
        }
    }
}

extension DockhandCustomHeaderPreset {
    var setupHint: String {
        switch self {
        case .pangolin:
            String(localized: "Pangolin: create an access token for the Dockhand resource and paste its ID and token.")
        case .cloudflareAccess:
            String(localized: "Cloudflare Access: create a service token in Zero Trust and add a Service Auth policy to the Dockhand application.")
        }
    }

    var systemImage: String {
        switch self {
        case .pangolin: "shield.lefthalf.filled"
        case .cloudflareAccess: "cloud"
        }
    }
}

enum ConnectionTestOutcome: Equatable {
    case success(String)
    case failure(String)
}

struct CustomHeadersCard: View {
    @Binding var drafts: [CustomHeaderDraft]
    let baseURLText: String
    let isTesting: Bool
    let testResult: ConnectionTestOutcome?
    let onTest: () -> Void

    private var issues: [UUID: DockhandCustomHeaderIssue] { drafts.issues }

    private var canAddMore: Bool {
        drafts.count < DockhandCustomHeaderValidator.maximumHeaderCount
    }

    private var usesPlainHTTP: Bool {
        baseURLText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Custom headers"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(String(localized: "Sent with every request to this server, including logs and shell. Use them to authenticate with a reverse proxy. Values stay in this device's Keychain and are hidden after saving."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                addMenu
            }

            if drafts.isEmpty {
                Text(String(localized: "No custom headers."))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach($drafts) { $draft in
                    CustomHeaderRow(
                        draft: $draft,
                        issue: issues[draft.id],
                        onDelete: { drafts.removeAll { $0.id == draft.id } }
                    )
                }
            }

            ForEach(drafts.matchedPresets) { preset in
                Label(preset.setupHint, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if usesPlainHTTP && !drafts.isEmpty {
                Label(
                    String(localized: "This server uses HTTP. Header values will travel unencrypted. Use HTTPS when sending credentials."),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }

            Button(action: onTest) {
                HStack {
                    if isTesting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "bolt.horizontal.circle")
                    }
                    Text(String(localized: "Test connection"))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .buttonStyle(.glass)
            .disabled(isTesting || !issues.isEmpty)

            if let testResult {
                ConnectionTestResultBanner(outcome: testResult)
            }
        }
        .padding(18)
        .glassEffect(.regular.tint(.white.opacity(0.02)), in: .rect(cornerRadius: 22))
    }

    private var addMenu: some View {
        Menu {
            Section(String(localized: "Presets")) {
                ForEach(DockhandCustomHeaderPreset.allCases) { preset in
                    Button {
                        add(preset)
                    } label: {
                        Label(preset.displayName, systemImage: preset.systemImage)
                    }
                }
            }
            Button {
                drafts.append(CustomHeaderDraft(name: ""))
            } label: {
                Label(String(localized: "Custom header"), systemImage: "plus")
            }
        } label: {
            Label(String(localized: "Add header"), systemImage: "plus")
                .labelStyle(.iconOnly)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.glass)
        .disabled(!canAddMore)
    }

    private func add(_ preset: DockhandCustomHeaderPreset) {
        let existing = Set(drafts.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        for name in preset.headerNames where !existing.contains(name.lowercased()) && canAddMore {
            drafts.append(CustomHeaderDraft(name: name))
        }
    }
}

private struct CustomHeaderRow: View {
    @Binding var draft: CustomHeaderDraft
    let issue: DockhandCustomHeaderIssue?
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(String(localized: "Header name"), text: $draft.name)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .accessibilityLabel(String(localized: "Remove header"))
            }

            if draft.isReplacingValue {
                HStack(spacing: 8) {
                    SecureField(String(localized: "Value"), text: $draft.newValue)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))

                    if draft.storedValue != nil {
                        Button(String(localized: "Cancel")) {
                            draft.newValue = ""
                            draft.isReplacingValue = false
                        }
                        .font(.footnote)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Label(String(localized: "Value saved in Keychain"), systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(String(localized: "Replace")) {
                        draft.newValue = ""
                        draft.isReplacingValue = true
                    }
                    .font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
            }

            if let issue {
                Text(issue.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(issue.isMissingInput ? Color.secondary : Color.red)
            }
        }
    }
}

private struct ConnectionTestResultBanner: View {
    let outcome: ConnectionTestOutcome

    private var message: String {
        switch outcome {
        case .success(let message), .failure(let message): message
        }
    }

    private var isFailure: Bool {
        if case .failure = outcome { return true }
        return false
    }

    private var tint: Color { isFailure ? .red : .green }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: isFailure ? "xmark.octagon.fill" : "checkmark.circle.fill")
                .foregroundStyle(tint)
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(isFailure ? Color.red : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(tint.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

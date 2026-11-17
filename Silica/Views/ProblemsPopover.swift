import SwiftUI
import LanguageServerProtocol

/// The Problems list: one row per published diagnostic on the current file.
/// Clicking a row reveals that range in the editor. Diagnostics positions are
/// approximate until the next publish (they reflect the last server reply).
struct ProblemsPopover: View {
    let workspace: WorkspaceModel
    let buffer: EditorBuffer

    @Environment(\.dismiss) private var dismiss

    private var diagnostics: [LSPDiagnostic] {
        workspace.lsp?.diagnostics(for: buffer.url) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Problems")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 10)

            if diagnostics.isEmpty {
                Label("No Problems", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(diagnostics) { diagnostic in
                            row(diagnostic)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 380)
        .padding(.bottom, 10)
    }

    private func row(_ diagnostic: LSPDiagnostic) -> some View {
        Button {
            dismiss()
            workspace.revealDiagnostic(diagnostic, in: buffer)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: iconName(for: diagnostic.severity))
                    .foregroundStyle(iconColor(for: diagnostic.severity))
                VStack(alignment: .leading, spacing: 2) {
                    Text(diagnostic.message)
                        .multilineTextAlignment(.leading)
                    Text(detailText(for: diagnostic))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(for: diagnostic))
    }

    private func iconName(for severity: DiagnosticSeverity?) -> String {
        switch severity {
        case .error: "xmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        default: "info.circle"
        }
    }

    private func iconColor(for severity: DiagnosticSeverity?) -> SwiftUI.Color {
        switch severity {
        case .error: .red
        case .warning: .orange
        default: .secondary
        }
    }

    private func detailText(for diagnostic: LSPDiagnostic) -> String {
        var parts: [String] = []
        if let source = diagnostic.source { parts.append(source) }
        if let code = diagnostic.code { parts.append(code) }
        parts.append("Line \(diagnostic.range.lowerBound.line + 1)")
        return parts.joined(separator: " · ")
    }

    private func accessibilityText(for diagnostic: LSPDiagnostic) -> String {
        let kind: String
        switch diagnostic.severity {
        case .error: kind = "Error"
        case .warning: kind = "Warning"
        default: kind = "Information"
        }
        let line = diagnostic.range.lowerBound.line + 1
        return "\(kind) on line \(line): \(diagnostic.message)"
    }
}

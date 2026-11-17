import SwiftUI

/// The title bar's Git button for the active text buffer. Like the Markdown
/// preview's eye, it toggles the diff against HEAD inline in the editor card —
/// never in a floating sheet — shown side by side with the text, which stays
/// editable. It appears only while the buffer's text (staged, unstaged and
/// unsaved edits included) differs from HEAD; a file with no copy in HEAD diffs
/// against empty as additions.
struct GitDiffButton: View {
    let buffer: EditorBuffer
    let workspace: WorkspaceModel

    @State private var hasDiff = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var requestKey: RequestKey {
        RequestKey(
            buffer: ObjectIdentifier(buffer),
            url: buffer.url,
            textRevision: buffer.textRevision,
            encoding: buffer.encoding.rawValue,
            gitStateRevision: workspace.gitStateRevision
        )
    }

    var body: some View {
        ZStack {
            if buffer.textController != nil, !buffer.isUntitled, hasDiff {
                Button(action: toggleDiff) {
                    Image(systemName: "arrow.triangle.branch")
                        .frame(width: 26, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                // Off: the file's change calls for attention. On: the current mode,
                // drawn like the preview toggle's selected side.
                .foregroundStyle(buffer.isShowingGitDiff ? Color.primary : Color.orange)
                .background {
                    if buffer.isShowingGitDiff {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.primary.opacity(0.08))
                    }
                }
                .help(buffer.isShowingGitDiff ? "Show Source Only" : "View Git Diff Side by Side (HEAD)")
                .accessibilityLabel(
                    buffer.isShowingGitDiff
                        ? "Hide Git diff for \(buffer.name)"
                        : "View Git diff beside the source for \(buffer.name)"
                )
                .disabled(isLoading)
            }
        }
        .task(id: requestKey) { await refreshStatus(for: requestKey) }
        .alert("Couldn't load Git diff", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// An edit or a Git change reruns this: while the diff is shown it recomputes
    /// the patch itself so the card stays truthful, otherwise it moves the button
    /// in or out. Never alerts — only an explicit click does.
    private func refreshStatus(for key: RequestKey) async {
        guard buffer.textController != nil, !buffer.isUntitled else {
            hasDiff = false
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(250))
        } catch {
            return
        }
        guard !Task.isCancelled, isCurrent(key),
              let controller = buffer.textController else { return }
        let text = controller.textView.string
        if buffer.isShowingGitDiff {
            let result = try? await GitDiffService.diff(
                fileURL: buffer.url, currentText: text, encoding: buffer.encoding
            )
            guard !Task.isCancelled, isCurrent(key, expectedText: text) else { return }
            if let result {
                hasDiff = true
                buffer.updateGitDiff(patch: result.patch)
            } else {
                hasDiff = false
                buffer.setShowingGitDiff(false)
            }
            return
        }
        let changed = await GitDiffService.hasDiff(
            fileURL: buffer.url,
            currentText: text,
            encoding: buffer.encoding
        )
        guard !Task.isCancelled, isCurrent(key, expectedText: text) else { return }
        hasDiff = changed
        if !changed, buffer.isShowingGitDiff {
            // The file came to match HEAD while a check from before the click was in
            // flight; the card can't keep showing a diff that no longer exists.
            buffer.setShowingGitDiff(false)
        }
    }

    /// Swaps the card to the diff and back, as the preview eye does.
    private func toggleDiff() {
        if buffer.isShowingGitDiff {
            buffer.setShowingGitDiff(false)
            return
        }
        guard let controller = buffer.textController else { return }
        let text = controller.textView.string
        let url = buffer.url
        let encoding = buffer.encoding
        let key = requestKey
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                guard let result = try await GitDiffService.diff(fileURL: url, currentText: text, encoding: encoding) else {
                    guard isCurrent(key, expectedText: text) else { return }
                    hasDiff = false
                    buffer.setShowingGitDiff(false)
                    return
                }
                guard isCurrent(key, expectedText: text) else { return }
                buffer.setShowingGitDiff(true, patch: result.patch)
            } catch {
                guard isCurrent(key, expectedText: text) else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func isCurrent(_ key: RequestKey, expectedText: String? = nil) -> Bool {
        requestKey == key
            && workspace.activeBuffer === buffer
            && (expectedText == nil || buffer.textController?.textView.string == expectedText)
    }

    private struct RequestKey: Equatable {
        let buffer: ObjectIdentifier
        let url: URL
        let textRevision: Int
        let encoding: UInt
        let gitStateRevision: Int
    }
}

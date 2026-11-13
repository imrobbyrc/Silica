import AppKit
import SwiftUI

/// Opens a directly selected file without presenting or saving its parent as a project.
struct StandaloneFileWindow: View {
    let fileURL: URL?

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismiss) private var dismiss
    @State private var workspace: WorkspaceModel?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let workspace {
                WorkspaceView(
                    workspace: workspace,
                    showsSidebar: false,
                    windowTitle: workspace.activeBuffer?.url.lastPathComponent
                )
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Can’t Open File", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                }
                .frame(minWidth: 500, minHeight: 360)
            } else {
                ProgressView()
                    .frame(minWidth: 500, minHeight: 360)
            }
        }
        .onAppear {
            guard fileURL != nil else {
                dismiss()
                return
            }
            ExternalOpener.shared.openWindow = openWindow
            EditorWindowPresence.didOpen()
            dismissWindow(id: WindowID.welcome)
            load()
        }
        .onDisappear {
            guard fileURL != nil else { return }
            if let workspace, KeyWorkspace.shared.current === workspace {
                KeyWorkspace.shared.current = nil
            }
            workspace?.close()
            if EditorWindowPresence.didClose() {
                NSApp.terminate(nil)
            }
        }
    }

    private func load() {
        guard workspace == nil else { return }
        guard let fileURL else {
            errorMessage = "No file was provided."
            return
        }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false), isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            errorMessage = "The selected file no longer exists or is a folder."
            return
        }
        workspace = WorkspaceModel(
            rootURL: ExternalOpener.projectFolder(for: fileURL),
            standaloneFileURL: fileURL
        )
    }
}

import AVFoundation
import AppKit
import CryptoKit
import Foundation
import ImageIO
import Observation
import PDFKit
import UniformTypeIdentifiers

/// One open file. Text files own a live `TextController` so each tab keeps
/// its own undo history, selection and scroll position.
@Observable
final class EditorBuffer: Identifiable {
    enum Content {
        case text(TextController)
        case image(ImageFile)
        case pdf(PDFFile)
        case video(VideoFile)
        case binary
        case tooLarge(Int64)
        case unreadable(String)
    }

    private(set) var url: URL
    let content: Content
    /// A new file (⌘N) that hasn't been saved anywhere yet; `url` is a placeholder.
    let isUntitled: Bool
    private(set) var encoding: String.Encoding

    var isDirty = false
    /// Increments for each text edit so diff status can refresh beyond the first dirty transition.
    private(set) var textRevision = 0
    /// The file was deleted or moved away after it was opened. The tab keeps its
    /// text; saving writes the file again.
    private(set) var isMissingOnDisk = false
    /// The file on disk as Silica last read or wrote it, to tell when another app
    /// changes it.
    @ObservationIgnored private var diskSnapshot: DiskSnapshot?

    /// Where the cursor is, for the status bar.
    struct CursorStatus: Equatable {
        var line = 1
        var column = 1
        var selectedLength = 0
    }

    var cursor = CursorStatus()
    var indentation = EditorTextView.Indentation(usesTabs: false, width: 4)

    /// Markdown, CSV and HTML files can switch between their source and a rendered preview;
    /// `nil` for every other kind of file.
    private(set) var previewFormat: PreviewFormat?
    private(set) var isShowingPreview = false
    /// Created the first time the preview is shown, then kept with the tab.
    @ObservationIgnored private(set) var preview: DocumentPreview?
    /// The card shows the file's diff against HEAD beside its text, so the source
    /// stays editable. Toggled from the title bar's Git button when the file differs.
    private(set) var isShowingGitDiff = false
    /// The patch as a read-only editor with `.diff` highlighting — the file-level
    /// header lines (`diff --git`, `---`, `+++`) stripped from the display, hunks
    /// kept — rebuilt for each showing so it always describes HEAD as it is now.
    /// Observed so a live patch swap re-renders the card even though the mode
    /// itself didn't change.
    private(set) var gitDiffController: TextController?
    /// Opens a project file a preview link points to.
    @ObservationIgnored var openFile: ((URL) -> Void)?
    /// The project folder, which an HTML preview may load files from.
    @ObservationIgnored var projectURL: URL?

    var id: URL { url }
    var name: String { url.lastPathComponent }

    var textController: TextController? {
        if case .text(let controller) = content { controller } else { nil }
    }

    /// A decoded image shown read-only in the editor card.
    struct ImageFile {
        let image: NSImage
        let pixelSize: CGSize
        let byteCount: Int64
        /// e.g. "PNG", "JPEG", "WebP".
        let format: String
        /// For a GIF or other image with several frames to play; `image` is its first.
        let animation: ImageAnimation?
    }

    /// Plays an animated image's frames while its tab is shown. ImageIO decodes them
    /// as they come up, so a long GIF isn't held in memory whole.
    @Observable
    final class ImageAnimation {
        let frameCount: Int
        /// The frame to show now; `nil` until the first has been decoded.
        private(set) var frame: CGImage?
        @ObservationIgnored private let url: URL
        /// Stands for one run of the animation: ImageIO's only way to end a run is
        /// from inside its frame callback, which stops once this has changed.
        @ObservationIgnored private var run: Run?

        private final class Run {}

        init(url: URL, frameCount: Int) {
            self.url = url
            self.frameCount = frameCount
        }

        /// Plays from the first frame, with the file's own timing and loop count.
        func start() {
            guard run == nil else { return }
            let run = Run()
            self.run = run
            // Calls back on the main queue for each frame.
            CGAnimateImageAtURLWithBlock(url as CFURL, nil) { [weak self] _, frame, stop in
                guard let self, self.run === run else {
                    stop.pointee = true
                    return
                }
                self.frame = frame
            }
        }

        func stop() {
            run = nil
        }
    }

    /// A PDF shown read-only in the editor card. The tab owns the view, so it keeps
    /// its place and zoom while other tabs are shown.
    @Observable
    final class PDFFile {
        let view: PDFView
        let byteCount: Int64
        /// A password-protected PDF has no pages to show until it's unlocked.
        private(set) var isLocked: Bool
        private(set) var pageCount: Int
        private let document: PDFDocument

        init(document: PDFDocument, byteCount: Int64) {
            self.document = document
            self.byteCount = byteCount
            isLocked = document.isLocked
            pageCount = document.pageCount
            view = PDFView()
            view.displayMode = .singlePageContinuous
            // Fits the page width to the card until the reader zooms.
            view.autoScales = true
            // The pages lie on the card's glass, like images do.
            view.backgroundColor = .clear
            // The view gets a locked document only once it's unlocked, so what a
            // protected PDF shows is Silica's own prompt and never an empty card.
            if !document.isLocked { view.document = document }
        }

        /// Returns whether the password was right; the pages show once it is.
        func unlock(with password: String) -> Bool {
            guard document.unlock(withPassword: password) else { return false }
            view.document = document
            pageCount = document.pageCount
            isLocked = false
            return true
        }
    }

    /// A video played in the editor card. The tab owns the player, so it keeps its
    /// place in the video while other tabs are shown.
    @Observable
    final class VideoFile {
        enum State {
            case loading
            case ready
            /// A format AVFoundation has no decoder for (Matroska, WebM, …), or a damaged file.
            case unplayable
        }

        @ObservationIgnored let player = AVPlayer()
        let byteCount: Int64
        private(set) var state = State.loading
        /// As shown, after the track's rotation; `nil` when there's no picture.
        private(set) var pixelSize: CGSize?
        private(set) var duration: TimeInterval?

        init(url: URL, byteCount: Int64) {
            self.byteCount = byteCount
            let asset = AVURLAsset(url: url)
            Task { [weak self] in
                // Reading a movie's header can take a while on a slow disk; the card
                // stays empty until it's known whether there is anything to play.
                let isPlayable = (try? await asset.load(.isPlayable)) ?? false
                let duration = try? await asset.load(.duration)
                let pixelSize = await Self.pixelSize(of: asset)
                guard let self else { return }
                guard isPlayable else {
                    state = .unplayable
                    return
                }
                if let duration, duration.isNumeric { self.duration = duration.seconds }
                self.pixelSize = pixelSize
                player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
                state = .ready
            }
        }

        private static func pixelSize(of asset: AVURLAsset) async -> CGSize? {
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
            // A phone's portrait video is stored on its side and turned by the transform.
            let shown = CGRect(origin: .zero, size: size).applying(transform)
            guard shown.width >= 1, shown.height >= 1 else { return nil }
            return CGSize(width: shown.width.rounded(), height: shown.height.rounded())
        }
    }

    private static let maxFileSize: Int64 = 20 * 1024 * 1024
    /// For images and PDFs, which are shown rather than loaded into the editor.
    private static let maxPreviewSize: Int64 = 200 * 1024 * 1024

    /// An empty, untitled file, e.g. "Untitled-1".
    init(untitledName name: String) {
        url = URL.untitled(name)
        isUntitled = true
        encoding = .utf8
        let controller = TextController(text: "", language: nil)
        content = .text(controller)
        controller.buffer = self
        controller.updateStatus()
    }

    /// Whether closing it should ask to save: edited files, and untitled ones with
    /// any text (an empty untitled tab just closes).
    var needsSaving: Bool {
        if isUntitled { return !(textController?.textView.string.isEmpty ?? true) }
        return isDirty
    }

    func noteTextDidChange() {
        textRevision &+= 1
    }

    init(url: URL) {
        self.url = url
        isUntitled = false
        previewFormat = PreviewFormat(url: url)

        // From the file system, not URL's resource cache, which can be stale when a
        // changed file is opened again.
        let attributes = Self.attributes(of: url)
        let size = Int64(attributes?.size ?? 0)

        // Played from disk as it goes, so a video has no size limit.
        if Self.isVideo(url) {
            encoding = .utf8
            diskSnapshot = attributes.map { DiskSnapshot(attributes: $0, digest: nil) }
            content = .video(VideoFile(url: url, byteCount: size))
            return
        }

        let isImage = Self.isImage(url)
        if isImage || Self.isPDF(url) {
            encoding = .utf8
            diskSnapshot = attributes.map { DiskSnapshot(attributes: $0, digest: nil) }
            if size > Self.maxPreviewSize {
                content = .tooLarge(size)
            } else if isImage {
                content = Self.loadImage(url, byteCount: size).map(Content.image)
                    ?? .unreadable("“\(url.lastPathComponent)” couldn’t be decoded as an image.")
            } else {
                content = Self.loadPDF(url, byteCount: size).map(Content.pdf)
                    ?? .unreadable("“\(url.lastPathComponent)” couldn’t be read as a PDF.")
            }
            return
        }

        if size > Self.maxFileSize {
            content = .tooLarge(size)
            encoding = .utf8
            diskSnapshot = attributes.map { DiskSnapshot(attributes: $0, digest: nil) }
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            content = .unreadable(error.localizedDescription)
            encoding = .utf8
            return
        }
        diskSnapshot = attributes.map { DiskSnapshot(attributes: $0, digest: Self.digest(of: data)) }

        guard !Self.looksBinary(data), let (text, encoding) = Self.decode(data) else {
            content = .binary
            encoding = .utf8
            return
        }

        self.encoding = encoding
        let controller = TextController(text: text, language: SyntaxLanguage(url: url))
        content = .text(controller)
        controller.buffer = self
        controller.updateStatus()
    }

    /// Stops a video or animated image that is playing; a video keeps its place.
    func pausePlayback() {
        switch content {
        case .video(let file): file.player.pause()
        case .image(let file): file.animation?.stop()
        default: break
        }
    }

    // MARK: Status

    var language: SyntaxLanguage? { SyntaxLanguage(url: url) }

    /// e.g. "UTF-8", for the status bar.
    var encodingName: String {
        switch encoding {
        case .utf8: "UTF-8"
        case .utf16, .utf16BigEndian, .utf16LittleEndian: "UTF-16"
        case .ascii: "ASCII"
        case .isoLatin1: "ISO Latin 1"
        case .windowsCP1252: "Windows 1252"
        case .macOSRoman: "Mac Roman"
        case .shiftJIS: "Shift JIS"
        default: String.localizedName(of: encoding)
        }
    }

    /// "LF", "CRLF" or "CR".
    var lineEndingName: String {
        switch textController?.lineEnding {
        case "\r\n": "CRLF"
        case "\r": "CR"
        default: "LF"
        }
    }

    // MARK: Renaming

    /// Follows a rename or move made in Silica: same text, edits and undo history,
    /// new location (and language, if the extension changed).
    func move(to newURL: URL) {
        url = newURL
        let newFormat = PreviewFormat(url: newURL)
        previewFormat = newFormat
        // The preview resolves images relative to the old place, and renders the old
        // format; make a new one when needed.
        isShowingPreview = isShowingPreview && newFormat != nil
        preview = nil
        // The diff was made against HEAD's copy of the old path; back to the source
        // rather than show a patch for a file that no longer exists there.
        clearGitDiff()
        isShowingGitDiff = false
        if isShowingPreview, let newFormat, let controller = textController {
            let preview = makePreview(for: controller, format: newFormat)
            self.preview = preview
            preview.show(controller.textView.string, line: controller.topVisibleLine())
        }
        textController?.setLanguage(SyntaxLanguage(url: newURL))
    }

    /// Writes the text to another file (Save As), leaving this buffer as it is.
    func write(to destination: URL) throws {
        guard let controller = textController else { return }
        guard let data = controller.textView.string.data(using: encoding) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding, userInfo: [NSURLErrorKey: destination])
        }
        try data.write(to: destination.resolvingSymlinksInPath(), options: .atomic)
    }

    // MARK: Preview

    func togglePreview() {
        setShowingPreview(!isShowingPreview)
    }

    /// Switches between source and preview, keeping roughly the same place in the
    /// document. `editLine` (from a double-click) puts the cursor on that source line.
    /// Asking for the source also puts the Git diff away: the rendered preview and
    /// the side-by-side diff never show together.
    func setShowingPreview(_ show: Bool, editLine: Int? = nil) {
        guard let controller = textController, show != isShowingPreview else { return }
        if show, previewFormat == nil { return }
        if show {
            guard let format = previewFormat, !isShowingPreview else { return }
            clearGitDiff()
            isShowingGitDiff = false
            let preview = self.preview ?? makePreview(for: controller, format: format)
            self.preview = preview
            preview.show(controller.textView.string, line: controller.topVisibleLine())
            isShowingPreview = true
        } else if isShowingGitDiff {
            setShowingGitDiff(false)
        } else if case .html? = previewFormat {
            // A page has no source lines to match, so the editor stays where it was.
            isShowingPreview = false
            preview?.unloadPage()
        } else if let editLine {
            isShowingPreview = false
            DispatchQueue.main.async { controller.scroll(toLine: editLine, placingCursor: true) }
        } else if isShowingPreview {
            preview?.topVisibleLine { [weak self] line in
                self?.isShowingPreview = false
                DispatchQueue.main.async { controller.scroll(toLine: line) }
            }
        }
    }

    /// Shows `patch` (from `GitDiffService`, the buffer's text against HEAD) beside
    /// the source as a read-only diff, hiding any rendered preview; `false` returns
    /// the card to the source alone. The text keeps its undo, selection and scroll
    /// throughout: its editor stays mounted in both layouts.
    func setShowingGitDiff(_ show: Bool, patch: String? = nil) {
        guard textController != nil, show != isShowingGitDiff else { return }
        if show {
            guard let patch else { return }
            gitDiffController = makeGitDiffController(patch: patch)
            isShowingPreview = false
        } else {
            clearGitDiff()
        }
        isShowingGitDiff = show
    }

    /// Swaps the shown patch for one freshly computed against HEAD now, staying in
    /// the mode. Skipped when the displayed lines didn't change, so a save or an
    /// idle Git refresh doesn't jump the diff back to its top.
    func updateGitDiff(patch: String) {
        guard isShowingGitDiff, textController != nil else { return }
        let display = GitDiffDisplay(patch: patch)
        guard let current = gitDiffController, current.textView.string != display.text else { return }
        gitDiffController = makeGitDiffController(display: display)
    }

    /// Builds the read-only diff pane: the file-level header is stripped from the
    /// display, the pane opens where the source is being read, and both panes'
    /// scrolling follows the other through the patch's line map.
    private func makeGitDiffController(display: GitDiffDisplay) -> TextController {
        // A stale pane's link goes before the new one takes over.
        gitDiffController?.scrollPeer = nil
        gitDiffController?.peerTopLine = nil
        let diff = TextController(text: display.text, language: .diff)
        // The patch is a snapshot to read, not an editor: no cursor, no typing.
        diff.textView.isEditable = false
        if let source = textController {
            diff.restorePosition(cursor: nil, topLine: display.displayedLine(forSourceLine: source.topVisibleLine()))
            source.scrollPeer = diff
            source.peerTopLine = { display.displayedLine(forSourceLine: $0) }
            diff.scrollPeer = source
            diff.peerTopLine = { display.sourceLine(forDisplayedLine: $0) }
        }
        return diff
    }

    private func makeGitDiffController(patch: String) -> TextController {
        makeGitDiffController(display: GitDiffDisplay(patch: patch))
    }

    /// Takes the diff away (source, preview, rename) with its scroll link, so the
    /// source never follows a patch that is gone.
    private func clearGitDiff() {
        textController?.scrollPeer = nil
        textController?.peerTopLine = nil
        gitDiffController = nil
    }

    private func makePreview(for controller: TextController, format: PreviewFormat) -> DocumentPreview {
        // The project folder, so a page can use files outside its own folder in the project.
        let readAccessURL = projectURL.flatMap { url.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/") ? $0 : nil }
        let preview = DocumentPreview(fileURL: url, format: format, readAccessURL: readAccessURL)
        preview.onOpenFile = { [weak self] url in self?.openFile?(url) }
        preview.onType = { [weak self] characters in
            guard let self else { return }
            self.isShowingPreview = false
            // Once the editor is back in the card, type the character there.
            DispatchQueue.main.async {
                controller.textView.insertText(characters, replacementRange: controller.textView.selectedRange())
            }
        }
        return preview
    }

    func save() throws {
        guard !isUntitled, let controller = textController else { return }
        guard let data = controller.textView.string.data(using: encoding) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding, userInfo: [NSURLErrorKey: url])
        }
        // Through a symlink to its target: an atomic write to the link itself would
        // swap it for a regular file and leave the real file unchanged.
        try data.write(to: url.resolvingSymlinksInPath(), options: .atomic)
        diskSnapshot = Self.attributes(of: url).map { DiskSnapshot(attributes: $0, digest: Self.digest(of: data)) }
        isDirty = false
        isMissingOnDisk = false
    }

    // MARK: Changes on disk

    enum DiskChange {
        case unchanged
        case modified(Data?)
        case deleted
    }

    /// Compares the file on disk with what Silica last read or wrote. A new
    /// modification date with the same bytes (a `touch`, a checkout of the same
    /// content) counts as unchanged.
    func diskChange() -> DiskChange {
        guard let attributes = Self.attributes(of: url) else { return .deleted }
        guard let snapshot = diskSnapshot else { return .modified(nil) }
        if snapshot.matches(attributes) { return .unchanged }
        // Images and other files that aren't kept as text are compared by date and size only.
        guard snapshot.digest != nil else { return .modified(nil) }
        guard let data = try? Data(contentsOf: url) else { return .deleted }
        if Self.digest(of: data) == snapshot.digest {
            diskSnapshot = DiskSnapshot(attributes: attributes, digest: snapshot.digest)
            return .unchanged
        }
        return .modified(data)
    }

    /// Notes whether the file still exists and, for unedited text, takes in changes
    /// made by other apps. Returns `true` if the buffer can't follow the change itself
    /// (it isn't text) and should be opened again.
    func syncWithDisk() -> Bool {
        guard !isUntitled else { return false }
        switch diskChange() {
        case .unchanged:
            if isMissingOnDisk { isMissingOnDisk = false }
            return false
        case .deleted:
            if !isMissingOnDisk { isMissingOnDisk = true }
            return false
        case .modified(let data):
            if isMissingOnDisk { isMissingOnDisk = false }
            guard textController != nil else { return true }
            // Edited here too: keep the edits; saving asks which version wins.
            if !isDirty, let data { revert(to: data) }
            return false
        }
    }

    /// Replaces the text with the file on disk, discarding unsaved edits. It's one
    /// undoable change, so ⌘Z brings the edits back.
    func revertToDisk() {
        guard let data = try? Data(contentsOf: url) else { return }
        revert(to: data)
    }

    private func revert(to data: Data) {
        guard let controller = textController, !Self.looksBinary(data),
              let (text, newEncoding) = Self.decode(data) else { return }
        encoding = newEncoding
        controller.replaceText(with: text)
        diskSnapshot = Self.attributes(of: url).map { DiskSnapshot(attributes: $0, digest: Self.digest(of: data)) }
        isDirty = false
        isMissingOnDisk = false
        if isShowingPreview, let preview {
            preview.topVisibleLine { line in
                preview.show(controller.textView.string, line: line)
            }
        }
    }

    struct DiskSnapshot {
        let modificationDate: Date?
        let size: Int?
        /// SHA-256 of the bytes, for text files.
        let digest: Data?

        init(attributes: FileAttributes, digest: Data?) {
            modificationDate = attributes.modificationDate
            size = attributes.size
            self.digest = digest
        }

        func matches(_ attributes: FileAttributes) -> Bool {
            modificationDate == attributes.modificationDate && size == attributes.size
        }
    }

    struct FileAttributes {
        let modificationDate: Date?
        let size: Int?
    }

    /// The file's own date and size; for a symlink, its target's, so edits made
    /// through the link (or to the target directly) are noticed.
    private static func attributes(of url: URL) -> FileAttributes? {
        let path = url.resolvingSymlinksInPath().path(percentEncoded: false)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return FileAttributes(
            modificationDate: attributes[.modificationDate] as? Date,
            size: (attributes[.size] as? NSNumber)?.intValue
        )
    }

    private static func digest(of data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// Raster image formats ImageIO can decode. SVG stays text so it can be edited.
    private static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .svg)
    }

    private static func loadImage(_ url: URL, byteCount: Int64) -> ImageFile? {
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        var pixelSize = CGSize(width: image.size.width, height: image.size.height)
        var format = url.pathExtension.uppercased()
        var animation: ImageAnimation?
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int,
               let height = properties[kCGImagePropertyPixelHeight] as? Int {
                pixelSize = CGSize(width: width, height: height)
            }
            if let typeID = CGImageSourceGetType(source) as String?,
               let name = UTType(typeID)?.preferredFilenameExtension {
                format = name == "jpeg" ? "JPEG" : name == "webp" ? "WebP" : name.uppercased()
            }
            // Only in the formats that animate: an icon's or TIFF's several images are
            // sizes and pages, not frames.
            let frameCount = CGImageSourceGetCount(source)
            if frameCount > 1, let typeID = CGImageSourceGetType(source) as String?,
               let type = UTType(typeID), animatedTypes.contains(where: type.conforms(to:)) {
                animation = ImageAnimation(url: url, frameCount: frameCount)
            }
        }
        return ImageFile(image: image, pixelSize: pixelSize, byteCount: byteCount, format: format, animation: animation)
    }

    /// GIF, animated PNG, animated WebP and HEIC image sequences.
    private static let animatedTypes: [UTType] = [.gif, .png, .webP] + [UTType("public.heics")].compactMap { $0 }

    private static func isPDF(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true
    }

    private static func loadPDF(_ url: URL, byteCount: Int64) -> PDFFile? {
        PDFDocument(url: url).map { PDFFile(document: $0, byteCount: byteCount) }
    }

    private static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .movie) else { return false }
        // ".ts" and ".mts" name MPEG transport streams to the system, but are far more
        // often TypeScript: those count as video only if they don't read as text.
        if type.conforms(to: .mpeg2TransportStream) || url.pathExtension.lowercased() == "mts" {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            guard let head = try? handle.read(upToCount: 8192) else { return false }
            return looksBinary(head)
        }
        return true
    }

    private static func looksBinary(_ data: Data) -> Bool {
        data.prefix(8192).contains(0)
    }

    private static func decode(_ data: Data) -> (String, String.Encoding)? {
        if let text = String(data: data, encoding: .utf8) {
            return (text, .utf8)
        }
        var converted: NSString?
        var usedLossy: ObjCBool = false
        let raw = NSString.stringEncoding(
            for: data,
            encodingOptions: [.allowLossyKey: false],
            convertedString: &converted,
            usedLossyConversion: &usedLossy
        )
        guard raw != 0, let converted else { return nil }
        return (converted as String, String.Encoding(rawValue: raw))
    }
}

extension URL {
    /// The placeholder location of an untitled file.
    static func untitled(_ name: String) -> URL {
        URL(string: "untitled:///" + (name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name))!
    }

    /// A placeholder for a file that hasn't been saved yet: there's nothing on disk.
    var isUntitled: Bool { scheme == "untitled" }
}

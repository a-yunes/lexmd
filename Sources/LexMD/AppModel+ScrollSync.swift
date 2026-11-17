import AppKit

/// The editor and the preview as two views of one document: scrolling together in Split view,
/// and a double-click in the preview going to that place in the source.
extension AppModel {
    func configureScrollSync() {
        scrollSync.connect(editor: editor, preview: preview)
        scrollSync.isEnabled = viewMode == .split
        editor.onScroll = { [weak self] input in self?.scrollSync.paneScrolled(.editor, input: input) }
        preview.onReaderScroll = { [weak self] input in self?.scrollSync.paneScrolled(.preview, input: input) }
        preview.onEditRequest = { [weak self] lines, word in self?.editSource(lines, word: word) }
    }

    /// A double-click in the preview: the editor shows the block's source lines, with the word
    /// that was double-clicked selected when it is found there, and takes focus. Preview Only
    /// switches to Split first. The preview stays where the reader clicked.
    func editSource(_ lines: ClosedRange<Int>, word: String) {
        guard currentFile != nil else { return }
        let block = editor.range(ofLines: lines)
        let found = word.isEmpty ? NSRange(location: NSNotFound, length: 0) : (text as NSString).range(of: word, options: [], range: block)
        let target = found.location != NSNotFound ? found : NSRange(location: block.location, length: 0)
        if viewMode == .read { setViewMode(.split, focusesEditor: false) }
        editor.whenVisible { [weak self] in
            guard let self else { return }
            self.editor.selectKeepingPlace(target)
            self.editor.focus()
        }
    }
}

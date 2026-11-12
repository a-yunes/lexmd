import AppKit

extension AppModel {
    /// Connects the editor's image paste, spelling, focus, and typewriter features to settings.
    func configureEditorFeatures() {
        editor.imageContext = { [weak self] in
            guard let self, let file = self.currentFile else { return nil }
            return ImageContext(document: file, root: self.rootURL, folder: self.imageFolder)
        }
        editor.onCheckingChange = { [weak self] spelling, grammar in
            guard let self else { return }
            if self.checksSpelling != spelling { self.checksSpelling = spelling }
            if self.checksGrammar != grammar { self.checksGrammar = grammar }
        }
        editor.onSubstitutionsChange = { [weak self] value in
            if self?.substitutions != value { self?.substitutions = value }
        }
        observeEditorSelectionForFind()
        applyEditorSettings()
    }

    func applyEditorSettings() {
        editor.setSpellChecking(spelling: checksSpelling, grammar: checksGrammar)
        editor.isFocusModeEnabled = focusMode
        editor.isTypewriterScrollingEnabled = typewriterScrolling
        editor.substitutions = substitutions
    }
}

import SwiftUI

/// The Editor section of the General settings.
struct EditorSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("Editor") {
            TextField(text: $model.imageFolder, prompt: Text("assets")) {
                Text("Image folder")
                Text("Pasted and dropped images are saved in this folder next to the document. Images already in the project are linked where they are.")
            }
            Toggle("Check spelling while typing", isOn: $model.checksSpelling)
            Toggle(isOn: $model.checksGrammar) {
                Text("Check grammar")
                Text("Code, links, and front matter are never marked.")
            }
            Toggle("Focus mode", isOn: $model.focusMode)
            Toggle(isOn: $model.typewriterScrolling) {
                Text("Typewriter scrolling")
                Text("Keeps the line you are typing in the middle of the editor.")
            }
        }
    }
}

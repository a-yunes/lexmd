import SwiftUI

/// The Editor tab of Settings: inserting links and images, spelling, and focus.
struct EditorSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Links and Images") {
                Toggle(isOn: $model.suggestsLinks) {
                    Text("Suggest links while typing")
                    Text("After ](, # in a link, or [[, the editor lists matching documents, images, and headings.")
                }
                TextField(text: $model.imageFolder, prompt: Text("assets")) {
                    Text("Image folder")
                    Text("Pasted and dropped images are saved in this folder next to the document. Images already in the project are linked where they are.")
                }
            }
            Section("Spelling and Grammar") {
                Toggle("Check spelling while typing", isOn: $model.checksSpelling)
                Toggle(isOn: $model.checksGrammar) {
                    Text("Check grammar with spelling")
                    Text("Code, links, and front matter are never marked.")
                }
            }
            Section("Focus") {
                Toggle(isOn: $model.focusMode) {
                    Text("Focus mode")
                    Text("Dims everything except the paragraph you are editing.")
                }
                Toggle(isOn: $model.typewriterScrolling) {
                    Text("Typewriter scrolling")
                    Text("Keeps the line you are typing in the middle of the editor.")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

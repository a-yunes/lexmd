import AppKit

/// The `lexmd` command bundled in `Contents/Resources/bin`, and its link in /usr/local/bin.
enum CommandLineTool {
    static let linkPath = "/usr/local/bin/lexmd"

    /// The tool inside this copy of LexMD, if it has one (builds run with `swift run` do not).
    static var bundledTool: String? {
        guard let path = Bundle.main.resourceURL?.appendingPathComponent("bin/lexmd").path,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    enum LinkState: Equatable {
        case missing
        /// A link to this tool.
        case installed
        /// A link to something else, with its destination as written.
        case otherLink(String)
        /// A file or folder that is not a link.
        case otherItem
    }

    static func state(of link: String, tool: String) -> LinkState {
        let manager = FileManager.default
        if let destination = try? manager.destinationOfSymbolicLink(atPath: link) {
            let absolute = destination.hasPrefix("/")
                ? destination
                : ((link as NSString).deletingLastPathComponent as NSString).appendingPathComponent(destination)
            return FileScanner.canonicalPath(absolute) == FileScanner.canonicalPath(tool) ? .installed : .otherLink(destination)
        }
        return (try? manager.attributesOfItem(atPath: link)) == nil ? .missing : .otherItem
    }

    /// Whether macOS runs this copy from a temporary location (an unmoved download).
    static func isTranslocated(_ path: String) -> Bool {
        path.contains("/AppTranslocation/")
    }

    /// Quotes a string for a POSIX shell.
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// An AppleScript string literal.
    static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The shell command that links `link` to `tool`. Only `replace` overwrites an existing link.
    static func linkCommand(tool: String, link: String, replace: Bool) -> String {
        let folder = (link as NSString).deletingLastPathComponent
        return "/bin/mkdir -p \(shellQuote(folder)) && /bin/ln -s\(replace ? "fn" : "") \(shellQuote(tool)) \(shellQuote(link))"
    }

    /// AppleScript that runs `linkCommand` after the standard administrator password prompt.
    static func installScript(tool: String, link: String, replace: Bool) -> String {
        "do shell script \(appleScriptString(linkCommand(tool: tool, link: link, replace: replace))) with administrator privileges"
    }

    /// A command for linking the tool into ~/bin without an administrator password.
    static func userCommand(tool: String) -> String {
        "mkdir -p ~/bin && ln -s \(shellQuote(tool)) ~/bin/lexmd"
    }
}

extension AppModel {
    /// Explains, then links /usr/local/bin/lexmd to the bundled tool with the administrator prompt.
    func installCommandLineTool() {
        let alert = NSAlert()
        guard let tool = CommandLineTool.bundledTool else {
            alert.messageText = "This copy of LexMD has no command line tool"
            alert.informativeText = "Build LexMD with scripts/build-app.sh, then try again."
            present(alert) { _ in }
            return
        }
        if CommandLineTool.isTranslocated(tool) {
            alert.messageText = "Move LexMD to Applications first"
            alert.informativeText = "macOS is running LexMD from a temporary location, so a link to it would stop working."
            present(alert) { _ in }
            return
        }
        let link = CommandLineTool.linkPath
        let replace: Bool
        switch CommandLineTool.state(of: link, tool: tool) {
        case .installed:
            alert.messageText = "The lexmd command is already installed"
            alert.informativeText = "\(link) links to this copy of LexMD. Type lexmd --help in Terminal to get started."
            present(alert) { _ in }
            return
        case .otherItem:
            alert.alertStyle = .warning
            alert.messageText = "\(link) already exists"
            alert.informativeText = "It is not a link, so LexMD leaves it alone. You can link the tool from your own bin folder instead."
            alert.addButton(withTitle: "Copy Command")
            alert.addButton(withTitle: "Cancel")
            present(alert) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.copyCommandLineToolCommand(tool) }
            }
            return
        case .otherLink(let destination):
            alert.alertStyle = .warning
            alert.messageText = "\(link) already links somewhere else"
            alert.informativeText = """
            It points to \(destination). Replace it with a link to this copy of LexMD? macOS will ask for an administrator password.
            """
            alert.addButton(withTitle: "Replace…")
            replace = true
        case .missing:
            alert.messageText = "Install the lexmd command?"
            alert.informativeText = """
            LexMD will create a link at \(link) so you can open files and folders from Terminal, for example lexmd . or lexmd notes.md. macOS will ask for an administrator password.

            To skip the password, copy a command that links it in ~/bin instead.
            """
            alert.addButton(withTitle: "Install…")
            replace = false
        }
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Cancel")
        present(alert) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                DispatchQueue.main.async { self?.runCommandLineToolInstall(tool: tool, link: link, replace: replace) }
            case .alertSecondButtonReturn:
                self?.copyCommandLineToolCommand(tool)
            default:
                break
            }
        }
    }

    private func runCommandLineToolInstall(tool: String, link: String, replace: Bool) {
        var error: NSDictionary?
        let script = NSAppleScript(source: CommandLineTool.installScript(tool: tool, link: link, replace: replace))
        script?.executeAndReturnError(&error)
        // -128: the user cancelled the password prompt.
        if let code = error?[NSAppleScript.errorNumber] as? Int, code == -128 { return }
        let alert = NSAlert()
        if let error {
            alert.alertStyle = .warning
            alert.messageText = "The lexmd command could not be installed"
            alert.informativeText = (error[NSAppleScript.errorMessage] as? String) ?? "Unknown error."
        } else if CommandLineTool.state(of: link, tool: tool) == .installed {
            alert.messageText = "The lexmd command is installed"
            alert.informativeText = "Type lexmd --help in Terminal to get started."
        } else {
            alert.alertStyle = .warning
            alert.messageText = "The lexmd command could not be installed"
            alert.informativeText = "\(link) does not link to LexMD."
        }
        present(alert) { _ in }
    }

    private func copyCommandLineToolCommand(_ tool: String) {
        let command = CommandLineTool.userCommand(tool: tool)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        let alert = NSAlert()
        alert.messageText = "Command copied"
        alert.informativeText = "Paste it in Terminal:\n\n\(command)\n\nThen make sure ~/bin is in your PATH."
        DispatchQueue.main.async { [weak self] in self?.present(alert) { _ in } }
    }
}

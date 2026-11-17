import AppKit
import Foundation
import Testing
@testable import LexMD

/// Known state bugs in documents, find, links, git, shortcuts and quick search.
/// Each test passes while its bug exists and fails once the bug is fixed; then drop `withKnownIssue`.
/// See docs/state-machines.md.
extension TabCommandTests {
    private func project(_ folder: TestFolder, files: Int) async throws -> (AppModel, (String) -> String) {
        let model = AppModel.shared
        model.open(folder.url)
        try await waitUntil { FileScanner.paths(in: model.tree).files.count == files }
        let root = FileScanner.canonicalPath(folder.url.path)
        return (model, { root + "/" + $0 })
    }

    private func typeText(_ text: String, in model: AppModel) {
        model.editor.textView.string = text
        model.editor.onTextChange?(text)
    }

    @Test func openingAnotherDocumentKeepsTextThatCouldNotBeSaved() async throws {
        let folder = try TestFolder()
        try folder.write("a.md", "# A\n")
        try folder.write("b.md", "# B\n")
        let (model, path) = try await project(folder, files: 2)
        model.open(URL(fileURLWithPath: path("a.md")))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path("a.md"))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path("a.md")) }
        typeText("# A unsaved\n", in: model)
        model.saveNow()
        #expect(model.saveError != nil)

        // The sidebar, Open Quickly, links and Back all show a document this way.
        model.sidebarSelected(path("b.md"))
        #expect(model.currentFile?.path == path("b.md"))
        #expect(model.tabStore.list.tabs.map(\.path) == [path("a.md"), path("b.md")], "b opens in a new tab")
        #expect(model.unsavedDocuments().map(\.text) == ["# A unsaved\n"], "a's text stays in its tab")
        model.discardUnsavedText()
        model.closeTabsForProjectChange()
    }

    /// A Discard question answered after another tab came forward discards nothing.
    @Test func discardAnsweredLateLeavesTheOtherTabAlone() async throws {
        let folder = try TestFolder()
        try folder.write("a.md", "# A\n")
        try folder.write("b.md", "# B\n")
        let (model, path) = try await project(folder, files: 2)
        model.open(URL(fileURLWithPath: path("a.md")))
        let aTab = try #require(model.tabStore.list.activeID)
        model.openInNewTab(path("b.md"))
        let bTab = try #require(model.tabStore.list.activeID)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path("b.md"))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path("b.md")) }
        typeText("# B unsaved\n", in: model)
        model.saveNow()

        let ask = AppModel.askToDiscard
        defer { AppModel.askToDiscard = ask }
        var pending: (() -> Void)?
        AppModel.askToDiscard = { _, discard in pending = discard }
        model.closeTab(bTab)
        model.selectTab(aTab)
        pending?()
        #expect(model.tabStore.list.tab(bTab) != nil, "the tab the question was about stays open")
        #expect(model.unsavedDocuments().map(\.text) == ["# B unsaved\n"])

        model.discardUnsavedText()
        model.closeTabsForProjectChange()
    }

    @Test func unreadableBackgroundTabKeepsItsText() async throws {
        let folder = try TestFolder()
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try folder.write("sub/a.md", "# A\n")
        try folder.write("b.md", "# B\n")
        let (model, path) = try await project(folder, files: 2)
        model.open(URL(fileURLWithPath: path("sub/a.md")))
        let aTab = try #require(model.tabStore.list.activeID)
        model.openInNewTab(path("b.md"))
        model.selectTab(aTab)
        try FileManager.default.removeItem(atPath: path("sub"))
        typeText("# A unsaved\n", in: model)
        model.saveNow()
        let bTab = try #require(model.tabStore.list.tabs.first { $0.id != aTab }?.id)
        model.selectTab(bTab)
        let keep = AppModel.keepUnsavedElsewhere
        defer { AppModel.keepUnsavedElsewhere = keep }
        var offered: [String] = []
        AppModel.keepUnsavedElsewhere = { documents, _, finish in
            offered += documents.map(\.text)
            finish()
        }
        model.selectTab(aTab)
        #expect(model.tabStore.list.tab(aTab) == nil, "the unreadable tab closes")
        #expect(model.currentFile?.path == path("b.md"))
        #expect(offered == ["# A unsaved\n"], "its text is offered to be kept elsewhere")
        model.discardUnsavedText()
        model.closeTabsForProjectChange()
    }

    @Test func savingKeepsTheFilesBytes() async throws {
        let folder = try TestFolder()
        try folder.write("a.md", "# A\n")
        try Data([0x63, 0x61, 0x66, 0xC3, 0xA9, 0x20, 0xFF, 0x0A]).write(to: folder.url.appendingPathComponent("x.md"))
        let (model, path) = try await project(folder, files: 2)
        model.open(URL(fileURLWithPath: path("x.md")))
        let shown = model.text
        typeText(model.text + "!", in: model)
        model.saveNow()
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path("x.md")))
        #expect(bytes.starts(with: [0x63, 0x61, 0x66, 0xC3, 0xA9]), "shown as \(shown.debugDescription), saved \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))")
        model.closeTabsForProjectChange()
    }

    @Test func savingKeepsUTF16AndItsByteOrderMark() async throws {
        let folder = try TestFolder()
        var bytes = Data([0xFF, 0xFE])
        bytes += "# Über\n".data(using: .utf16LittleEndian)!
        try bytes.write(to: folder.url.appendingPathComponent("u.md"))
        let (model, path) = try await project(folder, files: 1)
        model.open(URL(fileURLWithPath: path("u.md")))
        #expect(model.text == "# Über\n")
        typeText("# Über alles\n", in: model)
        model.saveNow()
        let saved = try Data(contentsOf: URL(fileURLWithPath: path("u.md")))
        #expect(saved == Data([0xFF, 0xFE]) + "# Über alles\n".data(using: .utf16LittleEndian)!)
        model.closeTabsForProjectChange()
    }

    /// Another app saves the open document while it has edits: nothing is written until the
    /// user picks a version.
    @Test func editsMadeByAnotherAppAreNotOverwrittenSilently() async throws {
        let folder = try TestFolder()
        try folder.write("a.md", "# A\n")
        let (model, path) = try await project(folder, files: 1)
        model.open(URL(fileURLWithPath: path("a.md")))
        let ask = AppModel.askAboutExternalChange
        defer { AppModel.askAboutExternalChange = ask }
        var asked = 0
        var keepMine = true
        AppModel.askAboutExternalChange = { _, reply in asked += 1; reply(keepMine) }

        typeText("# A mine\n", in: model)
        try "# A theirs, longer\n".write(toFile: path("a.md"), atomically: false, encoding: .utf8)
        model.saveNow()
        #expect(asked == 1)
        #expect(try String(contentsOfFile: path("a.md"), encoding: .utf8) == "# A mine\n", "Keep My Edits writes them")
        #expect(model.saveError == nil)

        keepMine = false
        typeText("# A mine again\n", in: model)
        try "# A theirs again, longer\n".write(toFile: path("a.md"), atomically: false, encoding: .utf8)
        model.saveNow()
        #expect(asked == 2)
        #expect(model.text == "# A theirs again, longer\n", "Use Other Version loads it")
        #expect(try String(contentsOfFile: path("a.md"), encoding: .utf8) == "# A theirs again, longer\n")
        #expect(model.saveError == nil)
        model.closeTabsForProjectChange()
    }

    @Test func undoingBackToTheSavedTextClearsTheSaveError() async throws {
        let folder = try TestFolder()
        try folder.write("a.md", "# A\n")
        let (model, path) = try await project(folder, files: 1)
        model.open(URL(fileURLWithPath: path("a.md")))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path("a.md"))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path("a.md")) }
        typeText("# A unsaved\n", in: model)
        model.saveNow()
        #expect(model.saveError != nil)
        typeText("# A\n", in: model)
        model.saveNow()
        #expect(model.saveError == nil, "still says: \(model.saveError ?? "")")
        model.closeTabsForProjectChange()
    }

    /// The page's matches leave out link targets, so Preview Only can't say which source match
    /// to replace: replacing shows the source first, and replaces what the editor highlights.
    @Test func replaceInReadModeShowsTheSourceFirst() async throws {
        let folder = try TestFolder()
        try folder.write("a.md", "[x](foo.md) foo\n")
        try folder.write("foo.md", "# Foo\n")
        let (model, path) = try await project(folder, files: 2)
        let mode = model.viewMode
        defer { model.setViewMode(mode) }
        model.open(URL(fileURLWithPath: path("a.md")))
        model.setViewMode(.read)
        model.showFind()
        model.findQuery = "foo"
        model.highlightCountChanged(1)  // The page shows one "foo": the link text is "x".
        model.replaceQuery = "bar"
        model.replaceCurrent()
        #expect(model.text == "[x](foo.md) foo\n", "nothing is replaced from Preview Only")
        #expect(model.viewMode == .split)
        #expect(model.findCount == 2, "the source has two matches")
        model.findNext(true)
        model.replaceCurrent()
        #expect(model.text == "[x](foo.md) bar\n")

        model.setViewMode(.read)
        model.showFind(replacing: true)
        #expect(model.viewMode == .split, "Find and Replace shows the source")
        model.closeFindBar()
        model.discardUnsavedText()
        model.closeTabsForProjectChange()
    }

    @Test func eachTabKeepsItsFindOptions() async throws {
        let folder = try TestFolder()
        try folder.write("a.md", "abc a.c\n")
        try folder.write("b.md", "# B\n")
        let (model, path) = try await project(folder, files: 2)
        let mode = model.viewMode
        defer { model.setViewMode(mode) }
        model.setViewMode(.split)
        model.open(URL(fileURLWithPath: path("a.md")))
        let aTab = try #require(model.tabStore.list.activeID)
        model.showFind()
        model.findUsesRegex = true
        model.findQuery = "a.c"
        #expect(model.findCount == 2)
        model.openInNewTab(path("b.md"))
        model.showFind()
        model.findUsesRegex = false
        model.selectTab(aTab)
        #expect(model.findUsesRegex)
        #expect(model.findCount == 2)
        model.closeFindBar()
        model.findUsesRegex = false
        model.closeTabsForProjectChange()
    }

    /// A shortcut chosen before ⌥⌘O became Show or Hide Outline's default keeps working, and
    /// the outline loses its default instead of sharing the key.
    @Test func storedShortcutsNeverBindOneKeyTwice() {
        let resolved = AppModel.resolvingShortcutConflicts(["toggleSidebar": "option+cmd+o", "find": "cmd+h"])
        #expect(resolved.overrides["toggleSidebar"] == "option+cmd+o")
        #expect(resolved.overrides["toggleOutline"] == "none")
        #expect(resolved.cleared == [.toggleOutline])
        #expect(resolved.overrides["find"] == nil, "a combination macOS keeps for itself goes back to the default")
        let all = ShortcutAction.allCases.compactMap { action -> String? in
            guard let value = resolved.overrides[action.rawValue] else { return action.defaultShortcut?.string }
            return value == "none" ? nil : value
        }
        #expect(Set(all).count == all.count)
    }

    /// One recorder at a time, and keys typed in another window are not recorded.
    @Test func recordingAShortcutStaysInItsWindow() throws {
        let model = AppModel.shared
        let saved = model.shortcutOverrides
        defer { model.shortcutOverrides = saved; model.stopRecordingShortcut() }
        let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        let document = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false
        document.isReleasedWhenClosed = false
        settings.orderBack(nil)
        document.orderBack(nil)
        defer { settings.close(); document.close() }
        func key(_ characters: String, _ code: UInt16, in window: NSWindow) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            ))
        }

        model.startRecordingShortcut(.bold, in: settings)
        model.startRecordingShortcut(.italic, in: settings)
        #expect(model.recordingShortcut == .italic, "starting a recorder stops the other")
        let typed = try key("s", 1, in: document)
        #expect(model.recordShortcutKey(typed) === typed, "⌘S in a document window goes to the document")
        #expect(model.recordingShortcut == nil)
        #expect(model.shortcut(for: .save)?.string == "cmd+s")

        model.startRecordingShortcut(.italic, in: settings)
        #expect(model.recordShortcutKey(try key("j", 38, in: settings)) == nil)
        #expect(model.shortcut(for: .italic)?.string == "cmd+j")
    }

    /// A result clicked while a newer query is still searching opens where that result was found.
    @Test func clickedSearchResultRevealsItsOwnMatch() async throws {
        let folder = try TestFolder()
        try folder.write("a.md", "alphabet first, then alpha alone\n")
        try folder.write("b.md", "# B\n")
        let (model, path) = try await project(folder, files: 2)
        model.open(URL(fileURLWithPath: path("b.md")))
        model.toggleQuickSearch(mode: .everything)
        model.quickQuery = "alpha"
        try await waitUntil { !model.isQuickSearching && model.quickResults.hits.count == 2 }
        let second = model.quickResults.files.count + 1
        model.quickQuery = "alphabet"
        model.activateQuickItem(at: second)
        #expect(model.currentFile?.path == path("a.md"))
        let selected = (model.text as NSString).substring(with: model.editor.textView.selectedRange())
        #expect(selected == "alpha" && model.editor.textView.selectedRange().location == 21, "the second alpha is selected, not \(selected)")
        model.closeTabsForProjectChange()
    }

    /// A result whose file can't be read leaves the open document's selection alone.
    @Test func unreadableSearchResultLeavesTheOpenDocumentAlone() async throws {
        let folder = try TestFolder()
        try folder.write("a.md", "needle here\n")
        try folder.write("b.md", "and a needle\n")
        let (model, path) = try await project(folder, files: 2)
        model.open(URL(fileURLWithPath: path("b.md")))
        model.editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        model.toggleQuickSearch(mode: .everything)
        model.quickQuery = "needle"
        try await waitUntil { !model.isQuickSearching && model.quickResults.hits.count == 2 }
        let index = try #require(model.quickResults.hits.firstIndex { $0.path == path("a.md") })
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path("a.md"))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path("a.md")) }
        model.activateQuickItem(at: model.quickResults.files.count + index)
        #expect(model.currentFile?.path == path("b.md"))
        #expect(model.editor.textView.selectedRange() == NSRange(location: 0, length: 0))
        model.closeTabsForProjectChange()
    }

    @Test func findInFilesAfterNewTabOpensInPlace() async throws {
        let folder = try TestFolder()
        try folder.write("a.md", "# A\n")
        let (model, _) = try await project(folder, files: 1)
        model.newTab()
        model.toggleQuickSearch(mode: .everything)
        #expect(!model.quickOpensInNewTab || !model.isQuickSearchVisible, "Find in Files still opens hits in a new tab")
        model.closeQuickSearch()
        model.closeTabsForProjectChange()
    }

    /// A discover cancelled while git is being located must not leave git off for the session.
    @Test func locatingGitSurvivesACancelledCaller() async throws {
        // Off the main actor: the lookup runs processes, and other tests wait on the main thread.
        let installed = await Task.detached { Git.locate() != nil }.value
        let git = await Task.detached { () -> Git? in
            withUnsafeCurrentTask { $0?.cancel() }
            return Git.system
        }.value
        #expect((git != nil) == installed, "a cancelled discover still finds git")
        // The lookup runs outside the caller's task, so a slow one isn't killed either.
        let slow = await Task.detached { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return Git.outsideAnyTask {
                ProcessRunner.run("/bin/sh", ["-c", "sleep 0.3; echo /usr/bin/git"], timeout: 10).succeeded
            }
        }.value
        #expect(slow)
    }

    @Test func commitIsNotOfferedForThePreviousProject() async throws {
        let repo = try TestFolder()
        let plain = try TestFolder()
        let gitPath = try #require(Git.system?.executable)
        for args in [["init", "-q", "-b", "main"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: gitPath)
            p.arguments = args
            p.currentDirectoryURL = repo.url
            try p.run(); p.waitUntilExit()
        }
        try repo.write("notes.md", "# Notes\n")
        for i in 0..<400 { try plain.write("p\(i).md", "# P\(i)\n") }
        let model = AppModel.shared
        model.open(repo.url)
        try await waitUntil(seconds: 60) { model.git.isActive && model.canCommitCurrentDocument }
        model.closeTabsForProjectChange()
        model.open(plain.url)
        let offered = model.canCommitCurrentDocument
        try await waitUntil(seconds: 60) { !model.git.isDiscovering && model.tree.count > 0 }
        #expect(!offered, "Commit is offered for \(repo.url.lastPathComponent) while \(plain.url.lastPathComponent) is open")
        model.closeTabsForProjectChange()
    }

    /// One drop of two linked documents: one question, and the link between them stays.
    @Test func movingTwoLinkedFilesKeepsTheirLink() async throws {
        let folder = try TestFolder()
        try folder.write("a.md", "[b](b.md) [c](c.md)\n")
        try folder.write("b.md", "# B\n")
        try folder.write("c.md", "# C\n")
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("F"), withIntermediateDirectories: true)
        try folder.write("F/keep.md", "# Keep\n")
        let (model, path) = try await project(folder, files: 4)
        let ask = AppModel.askToUpdateLinks
        defer { AppModel.askToUpdateLinks = ask }
        var asked: [LinkUpdatePlan] = []
        AppModel.askToUpdateLinks = { plan, _, reply in asked.append(plan); reply(true) }

        #expect(model.moveItems([URL(fileURLWithPath: path("a.md")), URL(fileURLWithPath: path("b.md"))], into: URL(fileURLWithPath: path("F"))))
        try await waitUntil { !asked.isEmpty && model.sidebarFiles.pendingLinkUpdates.isEmpty }
        try await Task.sleep(for: .milliseconds(300))
        #expect(asked.count == 1, "one question for the drop")
        #expect(try String(contentsOfFile: path("F/a.md"), encoding: .utf8) == "[b](b.md) [c](../c.md)\n")
        model.closeTabsForProjectChange()
    }

    /// A rename undone before the question is answered updates nothing.
    @Test func undoneRenameUpdatesNoLinks() async throws {
        let folder = try TestFolder()
        try folder.write("a.md", "[old](old.md)\n")
        try folder.write("old.md", "# Old\n")
        let (model, path) = try await project(folder, files: 2)
        let ask = AppModel.askToUpdateLinks
        defer { AppModel.askToUpdateLinks = ask }
        var pending: ((Bool) -> Void)?
        AppModel.askToUpdateLinks = { _, _, reply in pending = reply }

        let move = PathMove(from: path("old.md"), to: path("new.md"))
        #expect(model.performMove(move, actionName: "Rename", offerLinks: true))
        try await waitUntil { pending != nil }
        #expect(model.performMove(move.inverse, actionName: "Rename", offerLinks: false))
        pending?(true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try String(contentsOfFile: path("a.md"), encoding: .utf8) == "[old](old.md)\n")
        model.closeTabsForProjectChange()
    }

    /// Renamed twice before the first question showed: links follow to the final name.
    @Test func renamingAgainUpdatesLinksToTheFinalName() async throws {
        let folder = try TestFolder()
        try folder.write("a.md", "[x](x.md)\n")
        try folder.write("x.md", "# X\n")
        let (model, path) = try await project(folder, files: 2)
        let ask = AppModel.askToUpdateLinks
        defer { AppModel.askToUpdateLinks = ask }
        var asked = 0
        AppModel.askToUpdateLinks = { _, _, reply in asked += 1; reply(true) }

        #expect(model.performMove(PathMove(from: path("x.md"), to: path("y.md")), actionName: "Rename", offerLinks: true))
        #expect(model.performMove(PathMove(from: path("y.md"), to: path("z.md")), actionName: "Rename", offerLinks: true))
        try await waitUntil { asked > 0 && model.sidebarFiles.pendingLinkUpdates.isEmpty }
        try await Task.sleep(for: .milliseconds(300))
        #expect(asked == 1)
        #expect(try String(contentsOfFile: path("a.md"), encoding: .utf8) == "[x](z.md)\n")
        model.closeTabsForProjectChange()
    }

    /// The question for a deleted project answered after another project opened: that one stays.
    @Test func lateAnswerForADeletedProjectKeepsTheNextProject() async throws {
        let first = try TestFolder()
        let second = try TestFolder()
        try first.write("a.md", "# A\n")
        try second.write("b.md", "# B\n")
        let (model, path) = try await project(first, files: 1)
        model.open(URL(fileURLWithPath: path("a.md")))
        typeText("# A unsaved\n", in: model)

        let keep = AppModel.keepUnsavedElsewhere
        let ask = AppModel.askAboutUnsavedText
        defer { AppModel.keepUnsavedElsewhere = keep; AppModel.askAboutUnsavedText = ask }
        var finish: (() -> Void)?
        AppModel.keepUnsavedElsewhere = { _, _, done in finish = done }
        AppModel.askAboutUnsavedText = { _, _, reply in reply(.discard) }

        try FileManager.default.removeItem(at: first.url)
        model.projectFolderChanged()
        #expect(finish != nil)
        model.open(second.url)
        let secondRoot = FileScanner.canonicalPath(second.url.path)
        #expect(model.rootURL?.path == secondRoot)
        finish?()
        #expect(model.rootURL?.path == secondRoot, "the late answer leaves the new project open")
        model.closeTabsForProjectChange()
    }

    /// A folder opened with files from it asks about unsaved text once, then opens each file in a tab.
    @Test func openingAFolderWithFilesAsksOnce() async throws {
        let first = try TestFolder()
        let second = try TestFolder()
        try first.write("a.md", "# A\n")
        try second.write("c.md", "# C\n")
        try second.write("d.md", "# D\n")
        let (model, path) = try await project(first, files: 1)
        model.open(URL(fileURLWithPath: path("a.md")))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path("a.md"))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path("a.md")) }
        typeText("# A unsaved\n", in: model)
        model.saveNow()

        let ask = AppModel.askAboutUnsavedText
        defer { AppModel.askAboutUnsavedText = ask }
        var asked = 0
        var reply: ((UnsavedTextChoice) -> Void)?
        AppModel.askAboutUnsavedText = { _, _, answer in asked += 1; reply = answer }
        let root = FileScanner.canonicalPath(second.url.path)
        model.open([second.url, second.url.appendingPathComponent("c.md"), second.url.appendingPathComponent("d.md")])
        #expect(asked == 1)
        reply?(.discard)
        #expect(model.rootURL?.path == root)
        #expect(model.tabStore.list.tabs.map(\.path) == [root + "/c.md", root + "/d.md"])
        model.closeTabsForProjectChange()
    }

    /// Back to a document that can't be read leaves the history where it was.
    @Test func backToAnUnreadableDocumentKeepsTheHistoryInStep() async throws {
        let folder = try TestFolder()
        for name in ["a", "b", "c"] { try folder.write("\(name).md", "# \(name)\n") }
        let (model, path) = try await project(folder, files: 3)
        for name in ["a", "b", "c"] { model.sidebarSelected(path("\(name).md")) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path("b.md"))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path("b.md")) }
        model.goBack()
        #expect(model.currentFile?.path == path("c.md"))
        #expect(model.history[model.historyIndex] == model.currentFile?.path)
        model.closeTabsForProjectChange()
    }

    /// Trashing a document earlier in the history keeps the index on the shown document.
    @Test func trashKeepsTheHistoryIndexOnTheShownDocument() async throws {
        let folder = try TestFolder()
        for name in ["t", "a", "b", "c"] { try folder.write("\(name).md", "# \(name)\n") }
        let (model, path) = try await project(folder, files: 4)
        for name in ["t", "a", "b", "c"] { model.sidebarSelected(path("\(name).md")) }
        model.goBack()
        model.goBack()
        #expect(model.currentFile?.path == path("a.md"))
        model.itemWasTrashed(path("t.md"), to: nil, registerUndo: false)
        #expect(model.history[model.historyIndex] == path("a.md"))
        model.closeTabsForProjectChange()
    }

    /// Renaming a document onto the name of a tab whose file was deleted leaves one tab for it.
    @Test func renamingOntoAMissingTabsNameLeavesOneTab() async throws {
        let folder = try TestFolder()
        try folder.write("a.md", "# A\n")
        try folder.write("b.md", "# B\n")
        let (model, path) = try await project(folder, files: 2)
        model.open(URL(fileURLWithPath: path("a.md")))
        model.openInNewTab(path("b.md"))
        let aTab = try #require(model.tabStore.list.tabs.first?.id)
        model.selectTab(aTab)
        try FileManager.default.removeItem(atPath: path("b.md"))
        model.followMovedDocuments()
        #expect(model.performMove(PathMove(from: path("a.md"), to: path("b.md")), actionName: "Rename", offerLinks: false))
        #expect(model.tabStore.list.tabs.map(\.path) == [path("b.md")])
        #expect(model.currentFile?.path == path("b.md"))
        #expect(model.text == "# A\n")
        model.closeTabsForProjectChange()
    }

    /// Move to Trash, Undo, Redo: the trash can be undone again.
    @Test func redoneTrashCanBeUndoneAgain() async throws {
        let folder = try TestFolder()
        let trash = try TestFolder()
        try folder.write("a.md", "# A\n")
        try folder.write("t.md", "# T\n")
        let (model, path) = try await project(folder, files: 2)
        model.open(URL(fileURLWithPath: path("a.md")))
        let host = EditorHost(model)
        defer {
            host.restore()
        }
        let undo = try #require(model.fileUndoManager)
        undo.removeAllActions()
        let trashRoot = FileScanner.canonicalPath(trash.url.path)
        model.sidebarFiles.recycler = { urls in
            var result: [URL: URL] = [:]
            for url in urls {
                let destination = URL(fileURLWithPath: trashRoot).appendingPathComponent(UUID().uuidString + url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: destination)
                result[url] = destination
            }
            return result
        }
        defer { model.sidebarFiles.recycler = FileOperations.systemRecycler }

        model.moveToTrash(URL(fileURLWithPath: path("t.md")))
        try await waitUntil { undo.canUndo }
        undo.undo()
        #expect(FileManager.default.fileExists(atPath: path("t.md")))
        #expect(undo.canRedo)
        undo.redo()
        try await waitUntil { !FileManager.default.fileExists(atPath: path("t.md")) && undo.canUndo }
        #expect(undo.undoActionName == "Move to Trash")
        undo.undo()
        #expect(FileManager.default.fileExists(atPath: path("t.md")))
        undo.removeAllActions()
        model.closeTabsForProjectChange()
    }

    /// A moved document opened after its file was rewritten, and typed into before the update
    /// finished, keeps its links as rewritten instead of getting them moved a second time.
    @Test func documentReadAfterItsRewriteIsNotRebasedAgain() async throws {
        let folder = try TestFolder()
        try folder.write("b.md", "# B\n")
        try folder.write("c.md", "# C\n")
        try folder.write("m.md", "[b](b.md)\n")
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("F"), withIntermediateDirectories: true)
        let (model, path) = try await project(folder, files: 3)
        model.open(URL(fileURLWithPath: path("c.md")))

        let move = PathMove(from: path("m.md"), to: path("F/m.md"))
        try FileOperations.move(URL(fileURLWithPath: move.from), to: URL(fileURLWithPath: move.to))
        let files = [path("b.md"), path("c.md"), path("F/m.md")]
        let context = LinkUpdater.context(root: FileScanner.canonicalPath(folder.url.path), move: move, markdownFiles: files)
        let plan = LinkUpdater.plan(markdownFiles: files, context: context, overrides: [:])
        // The update pauses after writing the file, while the document is opened and edited.
        let gate = AsyncStream<Void>.makeStream()
        var finished = false
        AppModel.afterLinkRewrite = { for await _ in gate.stream { break } }
        defer { AppModel.afterLinkRewrite = nil }
        model.applyLinkUpdate(plan, context: context)
        try await waitUntil { (try? String(contentsOfFile: path("F/m.md"), encoding: .utf8)) == "[b](../b.md)\n" }
        model.open(URL(fileURLWithPath: path("F/m.md")))
        #expect(model.text == "[b](../b.md)\n")
        typeText("Typed. [b](../b.md)\n", in: model)
        gate.continuation.yield()
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(400)); finished = true }
        try await waitUntil { finished }
        #expect(model.text == "Typed. [b](../b.md)\n")
        model.saveNow()
        model.closeTabsForProjectChange()
    }

    /// Duplicate, Undo, Redo: the copy comes back, and it can be undone again.
    @Test func undoneDuplicateCanBeRedone() async throws {
        let folder = try TestFolder()
        let trash = try TestFolder()
        try folder.write("a.md", "# A\n")
        let (model, path) = try await project(folder, files: 1)
        model.open(URL(fileURLWithPath: path("a.md")))
        let host = EditorHost(model)
        defer {
            host.restore()
        }
        let undo = try #require(model.fileUndoManager)
        undo.removeAllActions()
        let trashRoot = FileScanner.canonicalPath(trash.url.path)
        model.sidebarFiles.recycler = { urls in
            var result: [URL: URL] = [:]
            for url in urls {
                let destination = URL(fileURLWithPath: trashRoot).appendingPathComponent(UUID().uuidString + url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: destination)
                result[url] = destination
            }
            return result
        }
        defer { model.sidebarFiles.recycler = FileOperations.systemRecycler }
        let copies = { (try? FileManager.default.contentsOfDirectory(atPath: path(""))).map { $0.filter { $0 != "a.md" } } ?? [] }

        model.duplicateItem(URL(fileURLWithPath: path("a.md")))
        try await waitUntil { undo.canUndo && copies().count == 1 }
        undo.undo()
        try await waitUntil { copies().isEmpty }
        #expect(undo.canRedo)
        #expect(undo.redoActionName == "Duplicate")
        undo.redo()
        try await waitUntil { copies().count == 1 && undo.canUndo }
        #expect(undo.undoActionName == "Duplicate")
        undo.removeAllActions()
        model.closeTabsForProjectChange()
    }
}

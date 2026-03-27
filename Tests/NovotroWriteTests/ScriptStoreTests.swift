import XCTest
import AppKit
import NovotroProjectKit
@testable import NovotroWriteUI

@available(macOS 26.0, *)
@MainActor
final class ScriptStoreTests: XCTestCase {
    func testProjectHistoryStorePersistsState() throws {
        let tempDirectory = try makeTempDirectory()
        let storageURL = tempDirectory.appendingPathComponent("history.json")
        let historyStore = ProjectHistoryStore(storageURL: storageURL)
        let projectURL = tempDirectory.appendingPathComponent("Example.owp", isDirectory: true)

        let recordedAt = Date(timeIntervalSince1970: 1234)
        let state = PersistedProjectHistoryState(
            fileSnapshots: [
                "Songs/01 Scene.ows": ProjectFileSnapshot(
                    modificationDate: Date(timeIntervalSince1970: 10),
                    fileSize: 42
                )
            ],
            entries: [
                ProjectHistoryEntry(
                    kind: .autosave,
                    title: "Auto-saved 1 scene",
                    message: "Songs/01 Scene.ows",
                    relativePaths: ["Songs/01 Scene.ows"],
                    recordedAt: recordedAt
                )
            ]
        )

        historyStore.saveState(state, for: projectURL)
        let loaded = historyStore.loadState(for: projectURL)

        XCTAssertEqual(loaded.fileSnapshots, state.fileSnapshots)
        XCTAssertEqual(loaded.entries, state.entries)
    }

    func testLoadProjectPromotesNewestVersionAfterExternalChangesWhileClosed() async throws {
        let tempDirectory = try makeTempDirectory()
        let historyStore = ProjectHistoryStore(storageURL: tempDirectory.appendingPathComponent("history.json"))
        let projectURL = try makeProjectPackage(in: tempDirectory, sceneTitle: "Opening", sceneLyrics: "Original lyrics")

        let firstStore = makeStore(historyStore: historyStore)
        await firstStore.loadProject(url: projectURL)
        firstStore.stopFileWatching()

        XCTAssertEqual(firstStore.librettoFiles.first?.content, "Original lyrics")
        XCTAssertTrue(firstStore.projectHistoryEntries.isEmpty)

        try writeSong(
            at: projectURL.appendingPathComponent("Songs/01 Opening.ows"),
            title: "Opening",
            activeLyrics: "Original lyrics",
            latestLyrics: "Newest lyrics from disk",
            activeVersionIsLatest: false,
            latestUpdatedAt: Date(timeIntervalSinceNow: 60)
        )

        let reopenedStore = makeStore(historyStore: historyStore)
        await reopenedStore.loadProject(url: projectURL)
        reopenedStore.stopFileWatching()

        XCTAssertEqual(reopenedStore.librettoFiles.first?.content, "Newest lyrics from disk")
        XCTAssertEqual(reopenedStore.songAssets.first?.document.activeVersion()?.lyrics, "Newest lyrics from disk")
        XCTAssertEqual(reopenedStore.projectHistoryEntries.first?.kind, .openedWithExternalChanges)
    }

    func testManualSaveWritesLyricsAndRecordsHistory() async throws {
        let tempDirectory = try makeTempDirectory()
        let projectURL = try makeProjectPackage(in: tempDirectory, sceneTitle: "Opening", sceneLyrics: "Before")
        let store = makeStore(historyStore: ProjectHistoryStore(storageURL: tempDirectory.appendingPathComponent("history.json")))

        await store.loadProject(url: projectURL)
        store.stopFileWatching()

        XCTAssertEqual(store.librettoFiles.first?.relativePath, "Songs/01 Opening.ows")
        store.updateLyricsForSong(atPath: "Songs/01 Opening.ows", lyrics: "After")
        store.save()

        try await waitUntil {
            store.projectHistoryEntries.contains(where: { $0.kind == .manualSave })
        }

        let data = try Data(contentsOf: projectURL.appendingPathComponent("Songs/01 Opening.ows"))
        let reopened = try OWSSongDocument.fromJSON(data: data)

        XCTAssertEqual(reopened.activeVersion()?.lyrics, "After")
        XCTAssertEqual(store.projectHistoryEntries.first?.kind, .manualSave)
    }

    func testSaveDoesNothingWhenProjectIsClean() async throws {
        let tempDirectory = try makeTempDirectory()
        let projectURL = try makeProjectPackage(in: tempDirectory, sceneTitle: "Opening", sceneLyrics: "Before")
        let store = makeStore(historyStore: ProjectHistoryStore(storageURL: tempDirectory.appendingPathComponent("history.json")))

        await store.loadProject(url: projectURL)
        store.stopFileWatching()

        store.save()

        XCTAssertEqual(store.saveIndicator, .saved)
        XCTAssertTrue(store.projectHistoryEntries.isEmpty)

        let data = try Data(contentsOf: projectURL.appendingPathComponent("Songs/01 Opening.ows"))
        let reopened = try OWSSongDocument.fromJSON(data: data)
        XCTAssertEqual(reopened.activeVersion()?.lyrics, "Before")
    }

    func testRenameSongSyncsCanonicalSceneTitleToDatabaseImmediately() async throws {
        let tempDirectory = try makeTempDirectory()
        let projectURL = try makeProjectPackage(in: tempDirectory, sceneTitle: "Opening", sceneLyrics: "Before")
        let store = makeStore(historyStore: ProjectHistoryStore(storageURL: tempDirectory.appendingPathComponent("history.json")))

        await store.loadProject(url: projectURL)
        defer { store.stopFileWatching() }

        let scenePath = try XCTUnwrap(store.songAssets.first?.relativePath)
        store.renameSong(atPath: scenePath, newTitle: "Opening Reprise")

        XCTAssertEqual(store.songAssets.first?.displayName, "Opening Reprise")
        try await waitForDatabaseSceneTitle(
            in: projectURL,
            relativePath: scenePath,
            expectedTitle: "Opening Reprise"
        )
    }

    func testSaveReloadsNewerExternalChangesInsteadOfOverwriting() async throws {
        let tempDirectory = try makeTempDirectory()
        let projectURL = try makeProjectPackage(in: tempDirectory, sceneTitle: "Opening", sceneLyrics: "Before")
        let store = makeStore(historyStore: ProjectHistoryStore(storageURL: tempDirectory.appendingPathComponent("history.json")))

        await store.loadProject(url: projectURL)
        store.stopFileWatching()

        store.updateLyricsForSong(atPath: "Songs/01 Opening.ows", lyrics: "Local draft")
        try writeSong(
            at: projectURL.appendingPathComponent("Songs/01 Opening.ows"),
            title: "Opening",
            activeLyrics: "Agent rewrite",
            latestLyrics: "Agent rewrite",
            activeVersionIsLatest: true,
            latestUpdatedAt: Date(timeIntervalSinceNow: 120)
        )

        store.save()

        try await waitUntil {
            store.librettoFiles.first?.content == "Agent rewrite"
        }

        let data = try Data(contentsOf: projectURL.appendingPathComponent("Songs/01 Opening.ows"))
        let reopened = try OWSSongDocument.fromJSON(data: data)

        XCTAssertEqual(reopened.activeVersion()?.lyrics, "Agent rewrite")
        XCTAssertEqual(store.librettoFiles.first?.content, "Agent rewrite")
        XCTAssertTrue(store.projectHistoryEntries.contains(where: { $0.kind == .externalReload }))
    }

    func testExternalReloadPreservesLocalDraftAsRevision() async throws {
        let tempDirectory = try makeTempDirectory()
        let projectURL = try makeProjectPackage(in: tempDirectory, sceneTitle: "Opening", sceneLyrics: "Before")
        let store = makeStore(historyStore: ProjectHistoryStore(storageURL: tempDirectory.appendingPathComponent("history.json")))

        await store.loadProject(url: projectURL)
        defer { store.stopFileWatching() }

        store.applyEditorChange(path: "Songs/01 Opening.ows", lyrics: "Local draft")
        try writeSong(
            at: projectURL.appendingPathComponent("Songs/01 Opening.ows"),
            title: "Opening",
            activeLyrics: "Agent rewrite",
            latestLyrics: "Agent rewrite",
            activeVersionIsLatest: true,
            latestUpdatedAt: Date(timeIntervalSinceNow: 120)
        )

        try await waitUntil {
            store.librettoFiles.first?.content == "Agent rewrite"
        }

        let revisions = store.songAssets.first?.document.versions ?? []
        XCTAssertTrue(revisions.contains(where: { $0.lyrics == "Local draft" && $0.saveType == .autosave }))
        XCTAssertTrue(store.projectHistoryEntries.contains(where: { $0.title == "Preserved local draft" }))
        XCTAssertEqual(store.librettoFiles.first?.content, "Agent rewrite")
    }

    func testEditorChangeCreatesRevisionButDoesNotWriteToDisk() async throws {
        let tempDirectory = try makeTempDirectory()
        let projectURL = try makeProjectPackage(in: tempDirectory, sceneTitle: "Opening", sceneLyrics: "Before")
        let store = makeStore(historyStore: ProjectHistoryStore(storageURL: tempDirectory.appendingPathComponent("history.json")))

        await store.loadProject(url: projectURL)
        store.stopFileWatching()

        store.applyEditorChange(path: "Songs/01 Opening.ows", lyrics: "Draft change")

        let data = try Data(contentsOf: projectURL.appendingPathComponent("Songs/01 Opening.ows"))
        let reopened = try OWSSongDocument.fromJSON(data: data)

        XCTAssertEqual(store.librettoFiles.first?.content, "Draft change")
        XCTAssertEqual(reopened.activeVersion()?.lyrics, "Before")
        XCTAssertEqual(store.projectHistoryEntries.first?.kind, .autosave)
        XCTAssertTrue(store.isDirty)
    }

    func testScratchpadSectionsRoundTripSceneMarkers() {
        let orderedPaths = [
            "Songs/01 Opening.ows",
            "Songs/02 Finale.ows",
        ]
        let sections = [
            ProjectTextFile(
                id: UUID(),
                relativePath: orderedPaths[0],
                content: "Tighten the opening stanza.\nKeep the brass entrance later."
            ),
            ProjectTextFile(
                id: UUID(),
                relativePath: orderedPaths[1],
                content: "Replace the ending cadence with a quieter landing."
            ),
        ]

        let serialized = ScriptStore.serializeScratchpadSections(sections)
        let parsed = ScriptStore.parseScratchpadSections(
            from: serialized,
            orderedPaths: orderedPaths
        )

        XCTAssertTrue(serialized.contains("{{{SCENE:Songs/01 Opening.ows}}}"))
        XCTAssertTrue(serialized.contains("{{{SCENE:Songs/02 Finale.ows}}}"))
        XCTAssertEqual(parsed.map(\.relativePath), orderedPaths)
        XCTAssertEqual(parsed.map(\.content), sections.map(\.content))
    }

    func testAddingSceneExtendsScratchpadBoundaries() async throws {
        let tempDirectory = try makeTempDirectory()
        let projectURL = try makeProjectPackage(in: tempDirectory, sceneTitle: "Opening", sceneLyrics: "Before")
        let store = makeStore(historyStore: ProjectHistoryStore(storageURL: tempDirectory.appendingPathComponent("history.json")))

        await store.loadProject(url: projectURL)
        store.stopFileWatching()

        store.updateScratchpadText(
            forPath: "Songs/01 Opening.ows",
            text: "Rewrite the first two lines with more urgency."
        )
        store.addScene()

        XCTAssertEqual(store.scratchpadFiles.map(\.relativePath), store.librettoFiles.map(\.relativePath))
        XCTAssertEqual(
            store.scratchpadText(forPath: "Songs/01 Opening.ows"),
            "Rewrite the first two lines with more urgency."
        )
        XCTAssertEqual(store.scratchpadFilledSceneCount, 1)
        XCTAssertTrue(store.scratchpadDocumentText.contains("{{{SCENE:Songs/02 New Scene.ows}}}"))
        XCTAssertEqual(store.scratchpadText(forPath: "Songs/02 New Scene.ows"), "")
    }

    func testExternalSongMembershipChangesReloadWithoutRestart() async throws {
        let tempDirectory = try makeTempDirectory()
        let projectURL = try makeProjectPackage(in: tempDirectory, sceneTitle: "Opening", sceneLyrics: "Before")
        let store = makeStore(historyStore: ProjectHistoryStore(storageURL: tempDirectory.appendingPathComponent("history.json")))

        await store.loadProject(url: projectURL)
        defer { store.stopFileWatching() }

        let songsURL = projectURL.appendingPathComponent("Songs", isDirectory: true)
        try writeSong(
            at: songsURL.appendingPathComponent("02 Finale.ows"),
            title: "Finale",
            activeLyrics: "Finale lyrics",
            latestLyrics: "Finale lyrics",
            activeVersionIsLatest: true,
            latestUpdatedAt: Date(timeIntervalSinceNow: 120)
        )

        try await waitUntil {
            store.songStubs.map(\.relativePath) == [
                "Songs/01 Opening.ows",
                "Songs/02 Finale.ows",
            ] && store.librettoFiles.first(where: { $0.relativePath == "Songs/02 Finale.ows" })?.content == "Finale lyrics"
        }

        try FileManager.default.removeItem(at: songsURL.appendingPathComponent("01 Opening.ows"))

        try await waitUntil {
            store.songStubs.map(\.relativePath) == ["Songs/02 Finale.ows"]
        }

        XCTAssertEqual(store.songAssets.map(\.relativePath), ["Songs/02 Finale.ows"])
        XCTAssertEqual(store.librettoFiles.map(\.relativePath), ["Songs/02 Finale.ows"])
        XCTAssertTrue(store.projectHistoryEntries.contains(where: {
            $0.kind == .externalReload && $0.relativePaths.contains("Songs/02 Finale.ows")
        }))
    }

    func testHiddenRangesRemoveInlineMarkupAndSyllableAnnotations() {
        let text = """
        [[1.01.0.001 - Lanterns rise]]
        [Storyboard flare]
        {camera: push_in | to=close}
        Lyric line (8)
        {{{SUMMARY}}}
        Hidden summary
        {{{/SUMMARY}}}
        Visible line
        """

        let fullyHidden = ScriptTextEditor.hiddenRanges(
            in: text,
            showDirections: false,
            showStoryboarding: false,
            showAnimateDirections: false
        )
        let visibleMarkup = ScriptTextEditor.hiddenRanges(
            in: text,
            showDirections: true,
            showStoryboarding: true,
            showAnimateDirections: true
        )
        let displayText = ScriptTextEditor.displayText(
            from: text,
            showDirections: false,
            showStoryboarding: false,
            showAnimateDirections: false
        )

        let fullyHiddenSnippets = substrings(in: fullyHidden, from: text)
        let visibleMarkupSnippets = substrings(in: visibleMarkup, from: text)

        XCTAssertTrue(fullyHiddenSnippets.contains("[[1.01.0.001 - Lanterns rise]]"))
        XCTAssertTrue(fullyHiddenSnippets.contains("[Storyboard flare]"))
        XCTAssertTrue(fullyHiddenSnippets.contains("{camera: push_in | to=close}"))
        XCTAssertTrue(fullyHiddenSnippets.contains(" (8)"))
        XCTAssertTrue(fullyHiddenSnippets.contains("{{{SUMMARY}}}\nHidden summary\n{{{/SUMMARY}}}"))

        XCTAssertFalse(visibleMarkupSnippets.contains("[[1.01.0.001 - Lanterns rise]]"))
        XCTAssertFalse(visibleMarkupSnippets.contains("[Storyboard flare]"))
        XCTAssertFalse(visibleMarkupSnippets.contains("{camera: push_in | to=close}"))
        XCTAssertTrue(visibleMarkupSnippets.contains(" (8)"))
        XCTAssertTrue(visibleMarkupSnippets.contains("{{{SUMMARY}}}\nHidden summary\n{{{/SUMMARY}}}"))
        XCTAssertFalse(displayText.contains("{camera:"))
        XCTAssertFalse(displayText.contains("(8)"))
        XCTAssertFalse(displayText.contains("[[1.01.0.001 - Lanterns rise]]"))
        XCTAssertTrue(displayText.contains("Visible line"))
    }

    func testScriptStoreDefaultsHideInlineMarkup() {
        let store = makeStore(historyStore: ProjectHistoryStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))

        XCTAssertFalse(store.showDirections)
        XCTAssertFalse(store.showStoryboarding)
        XCTAssertFalse(store.showAnimateDirections)
    }

    func testApplyDirectionStylingRemovesHiddenTextFromRenderedString() {
        let textView = NSTextView()
        textView.string = """
        Lyric line (8)
        [[1.01.0.001 - Lanterns rise]]
        [Storyboard flare]
        {camera: push_in | to=close}
        Visible
        """

        ScriptTextEditor.applyDirectionStyling(
            to: textView,
            showDirections: false,
            showStoryboarding: false,
            showAnimateDirections: false
        )

        XCTAssertFalse(textView.string.contains("(8)"))
        XCTAssertFalse(textView.string.contains("[[1.01.0.001 - Lanterns rise]]"))
        XCTAssertFalse(textView.string.contains("[Storyboard flare]"))
        XCTAssertFalse(textView.string.contains("{camera: push_in | to=close}"))
        XCTAssertTrue(textView.string.contains("Lyric line"))
        XCTAssertTrue(textView.string.contains("Visible"))
    }

    func testApplyDisplayEditPreservesHiddenMarkupAcrossCollapsedGapEdits() {
        let rawText = """
        First stanza

        [[1.01.0.001 - Lanterns rise]]
        [He looks toward the valley below.]
        {lipsync: "Johnny" | mode=singing | bars=17-24}

        Second stanza
        """

        let projection = ScriptTextEditor.displayProjection(
            from: rawText,
            showDirections: false,
            showStoryboarding: false,
            showAnimateDirections: false
        )
        let display = projection.displayText as NSString
        let gapRange = display.range(of: "\n\nSecond stanza")
        XCTAssertNotEqual(gapRange.location, NSNotFound)

        let editedRaw = ScriptTextEditor.applyDisplayEdit(
            rawText: rawText,
            projection: projection,
            affectedDisplayRange: NSRange(location: gapRange.location, length: 1),
            replacementString: ""
        )

        XCTAssertTrue(editedRaw.contains("[[1.01.0.001 - Lanterns rise]]"))
        XCTAssertTrue(editedRaw.contains("[He looks toward the valley below.]"))
        XCTAssertTrue(editedRaw.contains("{lipsync: \"Johnny\" | mode=singing | bars=17-24}"))
        XCTAssertTrue(editedRaw.contains("First stanza"))
        XCTAssertTrue(editedRaw.contains("Second stanza"))
    }

    func testExactSceneSampleDoesNotRenderDirectionOrCameraMarkup() {
        let rawText = """
        JOHNNY:
        Whole is not the job.
        Breathing is.
        Keep the notebook.
        Keep your hands steady.
        Leave the rest for later.

        [[1.03.0.003 - They lift another crate together. Johnny shoulders the heavier end without making a point of it.]]
        {camera: hold | from=medium | to=medium | bars=9-16}

        LUKE:
        You make it sound simple.
        """

        let rendered = ScriptTextEditor.displayText(
            from: rawText,
            showDirections: false,
            showStoryboarding: false,
            showAnimateDirections: false
        )

        XCTAssertTrue(rendered.contains("JOHNNY:"))
        XCTAssertTrue(rendered.contains("Leave the rest for later."))
        XCTAssertTrue(rendered.contains("LUKE:"))
        XCTAssertTrue(rendered.contains("You make it sound simple."))
        XCTAssertFalse(rendered.contains("[[1.03.0.003 - They lift another crate together."))
        XCTAssertFalse(rendered.contains("{camera: hold | from=medium | to=medium | bars=9-16}"))

        let textView = NSTextView()
        textView.string = rawText
        ScriptTextEditor.applyDirectionStyling(
            to: textView,
            showDirections: false,
            showStoryboarding: false,
            showAnimateDirections: false
        )

        XCTAssertEqual(textView.string, rendered)
    }

    func testDisplayTextHidesParentheticalStageDirectionsAndCollapsesGaps() {
        let rawText = """
        1.03.0 - Silver
        INT. BASE CORRIDOR / OUTSIDE BRIEFING - MIDDAY (DAY 1)
        (SUNG - Mark + Johnny. Duet about guilt, complicity, institutional erasure.)
        (The briefing room has emptied. MARK sits at the comms desk, logbook open.
        JOHNNY leans against the corridor wall, camera hanging from his neck.)

        MARK

        [Mark stares at his logbook. The room is quiet.]

        \tIt's that moment of quiet,
        \tfinally sitting alone.

        [Mark turns a page. His pen hesitates.]

        \tBut why can't I shake this weight that follows me,
        \tthese timestamps and hurt?
        """

        let rendered = ScriptTextEditor.displayText(
            from: rawText,
            showDirections: false,
            showStoryboarding: false,
            showAnimateDirections: false
        )

        XCTAssertFalse(rendered.contains("(SUNG - Mark + Johnny."))
        XCTAssertFalse(rendered.contains("(The briefing room has emptied."))
        XCTAssertFalse(rendered.contains("[Mark stares at his logbook."))
        XCTAssertFalse(rendered.contains("[Mark turns a page."))
        XCTAssertFalse(rendered.contains("\n\n\n"))
        XCTAssertTrue(rendered.contains("MARK\n\n\tIt's that moment of quiet,"))
        XCTAssertTrue(rendered.contains("\tfinally sitting alone.\n\n\tBut why can't I shake this weight that follows me,"))
    }

    func testDisplayTextHidesGenericDoubleBracketAndAnimateKeywords() {
        let rawText = """
        [[Wide shot without address]]
        {action: "Amira" | picks up journal | bars=37-38}
        {INSTRUMENTAL: Ancient Waters motif returns}
        Visible line
        """

        let rendered = ScriptTextEditor.displayText(
            from: rawText,
            showDirections: false,
            showStoryboarding: false,
            showAnimateDirections: false
        )

        XCTAssertFalse(rendered.contains("[[Wide shot without address]]"))
        XCTAssertFalse(rendered.contains("{action: \"Amira\" | picks up journal | bars=37-38}"))
        XCTAssertFalse(rendered.contains("{INSTRUMENTAL: Ancient Waters motif returns}"))
        XCTAssertEqual(rendered, "Visible line")
    }

    func testSynopsisScenePathResolverHandlesWhitespaceAndFilenameFallback() {
        let availablePaths = [
            "Songs/01 Opening.ows",
            "Songs/02 Finale.ows",
        ]

        XCTAssertEqual(
            LegacySynopsisParser.resolvePath(" Songs/01 Opening.ows \n", availablePaths: availablePaths),
            "Songs/01 Opening.ows"
        )
        XCTAssertEqual(
            LegacySynopsisParser.resolvePath("02 Finale.ows", availablePaths: availablePaths),
            "Songs/02 Finale.ows"
        )
        XCTAssertEqual(
            LegacySynopsisParser.resolvePath(".\\Songs\\02 Finale.ows", availablePaths: availablePaths),
            "Songs/02 Finale.ows"
        )
    }

    func testRecentProjectsStorePersistsAndDeduplicatesProjects() throws {
        let tempDirectory = try makeTempDirectory()
        let suiteName = "NovotroWriteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let firstProject = try makeProjectPackage(in: tempDirectory, sceneTitle: "Opening", sceneLyrics: "Before")
        let secondProject = tempDirectory.appendingPathComponent("Second.ows")
        try "{}".write(to: secondProject, atomically: true, encoding: .utf8)

        let store = RecentProjectsStore(
            userDefaults: defaults,
            fileManager: .default,
            storageKey: "testRecentProjects"
        )

        _ = store.noteProject(firstProject)
        _ = store.noteProject(secondProject)
        _ = store.noteProject(firstProject)

        XCTAssertEqual(store.recentProjects().map(\.path), [firstProject.path, secondProject.path])
    }

    func testGlobalChangeLogBuildsWholeShowTimelineAndTouchedFiles() {
        let now = Date(timeIntervalSince1970: 2_000)
        let projectEntries = [
            ProjectHistoryEntry(
                kind: .agentSync,
                title: "Applied synced AI change",
                message: "Songs/02 Finale.ows",
                relativePaths: ["Songs/02 Finale.ows"],
                recordedAt: now
            ),
            ProjectHistoryEntry(
                kind: .externalReload,
                title: "Reloaded external scene change",
                message: "Songs/01 Opening.ows",
                relativePaths: ["Songs/01 Opening.ows", "Songs/02 Finale.ows"],
                recordedAt: now.addingTimeInterval(-60)
            ),
        ]
        let gitEntries = [
            GitCommitEntry(
                hash: "abcdef123456",
                shortHash: "abcdef1",
                subject: "Rewrite finale cadence",
                committedAt: now.addingTimeInterval(-30)
            )
        ]

        let allItems = GlobalChangeLogWindowView.buildActivityItems(
            projectHistory: projectEntries,
            gitHistory: gitEntries,
            filter: .all,
            query: ""
        )
        let filteredGit = GlobalChangeLogWindowView.buildActivityItems(
            projectHistory: projectEntries,
            gitHistory: gitEntries,
            filter: .git,
            query: "cadence"
        )
        let touchedFiles = GlobalChangeLogWindowView.touchedFiles(from: projectEntries)

        XCTAssertEqual(allItems.map(\.title), [
            "Applied synced AI change",
            "Rewrite finale cadence",
            "Reloaded external scene change",
        ])
        XCTAssertEqual(filteredGit.map(\.title), ["Rewrite finale cadence"])
        XCTAssertEqual(touchedFiles.first?.path, "Songs/02 Finale.ows")
        XCTAssertEqual(touchedFiles.first?.count, 2)
        XCTAssertEqual(touchedFiles.last?.path, "Songs/01 Opening.ows")
    }

    func testConsoleProjectSyncAppliesLyricsImmediately() async throws {
        let tempDirectory = try makeTempDirectory()
        let projectURL = try makeProjectPackage(in: tempDirectory, sceneTitle: "Opening", sceneLyrics: "Committed")
        let store = makeStore(historyStore: ProjectHistoryStore(storageURL: tempDirectory.appendingPathComponent("history.json")))

        await store.loadProject(url: projectURL)
        store.stopFileWatching()

        let sync = ConsoleProjectSync(store: store)
        let workspace = try sync.extractToTempDirectory()
        let librettoDirectory = workspace.appendingPathComponent("libretto", isDirectory: true)
        let librettoURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: librettoDirectory, includingPropertiesForKeys: nil).first
        )
        try "AI updated lyrics".write(to: librettoURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(sync.syncChangesBack())

        XCTAssertEqual(store.librettoFiles.first?.content, "AI updated lyrics")
        XCTAssertTrue(store.pendingAgentEdits.isEmpty)
        XCTAssertEqual(store.projectHistoryEntries.first?.kind, .agentSync)
    }

    func testGitHistoryServiceReturnsCommitsForProjectPath() throws {
        let tempDirectory = try makeTempDirectory()
        let repoURL = tempDirectory.appendingPathComponent("Repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)

        let projectURL = try makeProjectPackage(in: repoURL, sceneTitle: "Opening", sceneLyrics: "Version A")
        try runGit(["init"], at: repoURL)
        try runGit(["config", "user.email", "tests@example.com"], at: repoURL)
        try runGit(["config", "user.name", "Tests"], at: repoURL)
        try runGit(["add", "."], at: repoURL)
        try runGit(["commit", "-m", "Initial project commit"], at: repoURL)

        try writeSong(
            at: projectURL.appendingPathComponent("Songs/01 Opening.ows"),
            title: "Opening",
            activeLyrics: "Version B",
            latestLyrics: "Version B",
            activeVersionIsLatest: true,
            latestUpdatedAt: Date(timeIntervalSinceNow: 120)
        )
        try runGit(["add", "."], at: repoURL)
        try runGit(["commit", "-m", "Update opening scene"], at: repoURL)

        let unrelatedURL = repoURL.appendingPathComponent("README.md")
        try "Unrelated".write(to: unrelatedURL, atomically: true, encoding: .utf8)
        try runGit(["add", "."], at: repoURL)
        try runGit(["commit", "-m", "Add README"], at: repoURL)

        let commits = GitHistoryService.live.loadCommits(projectURL)

        XCTAssertTrue(commits.contains(where: { $0.subject == "Update opening scene" }))
        XCTAssertTrue(commits.contains(where: { $0.subject == "Initial project commit" }))
        XCTAssertFalse(commits.contains(where: { $0.subject == "Add README" }))
    }

    func testGitHistoryFallsBackToRepoCommitsWhenProjectPathHasNoHistory() throws {
        let tempDirectory = try makeTempDirectory()
        let repoURL = tempDirectory.appendingPathComponent("Repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)

        try runGit(["init"], at: repoURL)
        try runGit(["config", "user.email", "tests@example.com"], at: repoURL)
        try runGit(["config", "user.name", "Tests"], at: repoURL)

        let readmeURL = repoURL.appendingPathComponent("README.md")
        try "Repo history".write(to: readmeURL, atomically: true, encoding: .utf8)
        try runGit(["add", "."], at: repoURL)
        try runGit(["commit", "-m", "Initial repo commit"], at: repoURL)

        let projectURL = try makeProjectPackage(in: repoURL, sceneTitle: "Untracked", sceneLyrics: "Draft")

        let commits = GitHistoryService.live.loadCommits(projectURL)

        XCTAssertEqual(commits.first?.subject, "Initial repo commit")
    }

    private func makeStore(historyStore: ProjectHistoryStore) -> ScriptStore {
        ScriptStore(
            projectHistoryStore: historyStore,
            gitHistoryService: GitHistoryService { _ in [] }
        )
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeProjectPackage(in root: URL, sceneTitle: String, sceneLyrics: String) throws -> URL {
        let projectURL = root.appendingPathComponent("Example.owp", isDirectory: true)
        let songsURL = projectURL.appendingPathComponent("Songs", isDirectory: true)
        let synopsisURL = projectURL.appendingPathComponent("Synopsis", isDirectory: true)

        try FileManager.default.createDirectory(at: songsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: synopsisURL, withIntermediateDirectories: true)
        try writeSong(
            at: songsURL.appendingPathComponent("01 \(sceneTitle).ows"),
            title: sceneTitle,
            activeLyrics: sceneLyrics,
            latestLyrics: sceneLyrics,
            activeVersionIsLatest: true,
            latestUpdatedAt: Date(timeIntervalSince1970: 10)
        )
        try "Synopsis".write(to: synopsisURL.appendingPathComponent("synopsis.txt"), atomically: true, encoding: .utf8)

        return projectURL
    }

    private func writeSong(
        at url: URL,
        title: String,
        activeLyrics: String,
        latestLyrics: String,
        activeVersionIsLatest: Bool,
        latestUpdatedAt: Date
    ) throws {
        let activeVersionID = UUID()
        let latestVersionID = activeVersionIsLatest ? activeVersionID : UUID()
        let createdAt = Date(timeIntervalSince1970: 1)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let activeUpdatedAt = latestUpdatedAt.addingTimeInterval(activeVersionIsLatest ? 0 : -120)

        var versions: [[String: Any]] = [[
            "id": activeVersionID.uuidString,
            "label": "Active",
            "createdAt": formatter.string(from: createdAt),
            "updatedAt": formatter.string(from: activeUpdatedAt),
            "lyrics": activeLyrics,
            "saveType": "manual",
            "isBookmarked": false,
        ]]

        if !activeVersionIsLatest {
            versions.append([
                "id": latestVersionID.uuidString,
                "label": "Imported",
                "createdAt": formatter.string(from: latestUpdatedAt),
                "updatedAt": formatter.string(from: latestUpdatedAt),
                "lyrics": latestLyrics,
                "saveType": "imported",
                "isBookmarked": false,
            ])
        }

        let json: [String: Any] = [
            "songID": UUID().uuidString,
            "title": title,
            "canonicalTitle": title.lowercased(),
            "notes": "",
            "updatedAt": formatter.string(from: latestUpdatedAt),
            "activeVersionID": activeVersionID.uuidString,
            "versions": versions,
        ]

        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: latestUpdatedAt],
            ofItemAtPath: url.path
        )
    }

    private func runGit(_ arguments: [String], at url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", url.path] + arguments

        let stderr = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "git failed"
            XCTFail(message)
            throw NSError(domain: "ScriptStoreTests", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
    }

    private func substrings(in ranges: [NSRange], from text: String) -> [String] {
        let nsString = text as NSString
        return ranges.map { nsString.substring(with: $0) }
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        pollIntervalNanoseconds: UInt64 = 50_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        XCTFail("Timed out waiting for condition")
    }

    private func waitForDatabaseSceneTitle(
        in projectURL: URL,
        relativePath: String,
        expectedTitle: String,
        timeout: TimeInterval = 2,
        pollIntervalNanoseconds: UInt64 = 50_000_000
    ) async throws {
        let connection = try await NovotroProjectConnection.open(projectURL: projectURL, preferService: false)
        try await connection.ensureCurrentIndex()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let scene = try await connection.loadScene(relativePath: relativePath),
               scene.title == expectedTitle {
                return
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        XCTFail("Timed out waiting for database scene title \(expectedTitle)")
    }
}

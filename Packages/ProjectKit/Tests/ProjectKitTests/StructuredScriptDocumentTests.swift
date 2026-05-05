import XCTest
@testable import ProjectKit

final class StructuredScriptDocumentTests: XCTestCase {
    func testParseAndExportPreservesCameraAndTechnicalMarkup() throws {
        let raw = """
        Hello [camera: wide | focus=amira | bars=1-2]world
        [object: lantern | position=center | bars=1-2]
        [action: "amira" | description="lifts the lantern" | bars=1-2]
        [Lantern smoke fills the tent.]
        Done
        """

        let document = StructuredScriptDocumentProjector.parse(raw)

        XCTAssertEqual(
            document.visibleText,
            """
            Hello world



            Done
            """
        )
        XCTAssertEqual(document.shots.count, 1)
        XCTAssertEqual(document.hiddenMarkup.count, 3)
        XCTAssertEqual(document.hiddenMarkup.filter { $0.kind == .action }.count, 2)
        XCTAssertEqual(document.shots.first?.card.camera.shotSize, "wide")
        XCTAssertEqual(document.shots.first?.card.camera.focus, "amira")
        XCTAssertEqual(StructuredScriptDocumentProjector.export(document), raw)
    }

    func testPlainBracketActionCuesBecomeHiddenActionMarkup() throws {
        let raw = """
        [camera: wide | label="Valley opening"]
        [The valley is seen from high above before the sun reaches the ridge.]
        Sung line stays visible.
        """

        let document = StructuredScriptDocumentProjector.parse(raw)

        XCTAssertEqual(
            document.visibleText,
            """


            Sung line stays visible.
            """
        )
        XCTAssertEqual(document.shots.count, 1)
        XCTAssertEqual(document.hiddenMarkup.count, 1)
        XCTAssertEqual(document.hiddenMarkup.first?.kind, .action)
        XCTAssertEqual(
            document.hiddenMarkup.first?.rawMarkup,
            "[The valley is seen from high above before the sun reaches the ridge.]"
        )
        XCTAssertEqual(StructuredScriptDocumentProjector.export(document), raw)
    }

    func testActionDisplayTextRemovesMarkupSyntax() throws {
        XCTAssertEqual(
            StructuredScriptDocumentProjector.actionDisplayText(
                from: "[The valley is seen from high above.]"
            ),
            "The valley is seen from high above."
        )
        XCTAssertEqual(
            StructuredScriptDocumentProjector.actionDisplayText(
                from: "[Johnny sits opposite Luke. The mission camera comes up for the official record: road, valley, military passage.]"
            ),
            "Johnny sits opposite Luke. The mission camera comes up for the official record: road, valley, military passage."
        )
        XCTAssertEqual(
            StructuredScriptDocumentProjector.actionDisplayText(
                from: "[action: \"mark\" | description=\"checks the radio\" | bars=1-4]"
            ),
            "Mark checks the radio"
        )
    }

    func testActionTextEditPreservesBackendActionMarkup() throws {
        let raw = "[action: \"mark\" | description=\"checks the radio\" | bars=1-4]"

        XCTAssertEqual(
            StructuredScriptDocumentProjector.actionRawMarkup(
                displayText: "Mark lifts the radio handset",
                preserving: raw
            ),
            "[action: mark | bars=1-4 | description=\"lifts the radio handset\"]"
        )
        XCTAssertEqual(
            StructuredScriptDocumentProjector.actionRawMarkup(
                displayText: "The valley wakes.",
                preserving: "[The valley is still.]"
            ),
            "[The valley wakes.]"
        )
    }

    func testLyricStanzaCanProjectAsCardAndRoundTrip() throws {
        let raw = """
        LUKE:
        Then start with the boxes.
        Somebody will need what's in them.
        """

        let plain = StructuredScriptDocumentProjector.parse(raw)
        XCTAssertEqual(plain.visibleText, raw)
        XCTAssertTrue(plain.lyricBlocks.isEmpty)

        let document = StructuredScriptDocumentProjector.parse(raw, hideLyricSpeakerCues: true)

        XCTAssertEqual(
            document.visibleText,
            ""
        )
        XCTAssertEqual(document.lyricBlocks.count, 1)
        let block = try XCTUnwrap(document.lyricBlocks.first)
        XCTAssertEqual(block.speakerName, "LUKE")
        XCTAssertEqual(
            block.text,
            """
            Then start with the boxes.
            Somebody will need what's in them.
            """
        )
        XCTAssertEqual(StructuredScriptDocumentProjector.export(document), raw)
    }

    func testLyricSpeakerAllowsLowercaseParentheticalQualifier() throws {
        let raw = """
        MARK (radio):

        Listen, Matt.
        There's something you should know.
        """

        let document = StructuredScriptDocumentProjector.parse(raw, hideLyricSpeakerCues: true)

        XCTAssertEqual(document.visibleText, "")
        XCTAssertEqual(document.lyricBlocks.count, 1)
        let block = try XCTUnwrap(document.lyricBlocks.first)
        XCTAssertEqual(block.speakerName, "MARK (radio)")
        XCTAssertEqual(
            block.text,
            """
            Listen, Matt.
            There's something you should know.
            """
        )
        XCTAssertEqual(StructuredScriptDocumentProjector.export(document), raw)
    }

    func testMixedCaseActionLabelDoesNotBecomeLyricSpeaker() throws {
        let raw = """
        Weather note:

        The rain is closing in.
        """

        let document = StructuredScriptDocumentProjector.parse(raw, hideLyricSpeakerCues: true)

        XCTAssertEqual(document.visibleText, raw)
        XCTAssertTrue(document.lyricBlocks.isEmpty)
    }

    func testTripleBraceMetadataIsHiddenAndRoundTrips() throws {
        let raw = """
        {{{SYNOPSIS}}}
        Internal summary only.
        {{{/SYNOPSIS}}}
        Scene title
        """

        let document = StructuredScriptDocumentProjector.parse(raw, hideLyricSpeakerCues: true)

        XCTAssertEqual(document.visibleText, "Scene title")
        XCTAssertEqual(document.hiddenMarkup.count, 1)
        XCTAssertEqual(document.hiddenMarkup.first?.kind, .technical)
        XCTAssertEqual(StructuredScriptDocumentProjector.export(document), raw)
    }

    func testLyricStanzaCardEditRewritesOnlyThatCard() throws {
        let raw = """
        LUKE:
        Then start with the boxes.
        """
        let document = StructuredScriptDocumentProjector.parse(raw, hideLyricSpeakerCues: true)
        let block = try XCTUnwrap(document.lyricBlocks.first)

        let speakerUpdated = StructuredScriptDocumentProjector.updatingLyricSpeaker(
            in: document,
            markerID: block.id,
            speakerName: "Johnny"
        )
        let updated = StructuredScriptDocumentProjector.updatingLyricBlockText(
            in: speakerUpdated,
            blockID: block.id,
            text: "Then start with the crates."
        )

        XCTAssertEqual(
            StructuredScriptDocumentProjector.export(updated),
            """
            JOHNNY:

            Then start with the crates.

            """
        )
    }

    func testMultipleStanzasUnderOneSpeakerBecomeSeparateCards() throws {
        let raw = """
        JOHNNY:

        Sent to this ridge,
        with my camera in hand.

        I wanted to work for my country,
        but I found myself unsure.
        """

        let document = StructuredScriptDocumentProjector.parse(raw, hideLyricSpeakerCues: true)

        XCTAssertEqual(document.lyricBlocks.count, 2)
        XCTAssertEqual(document.lyricBlocks.map(\.speakerName), ["JOHNNY", "JOHNNY"])
        XCTAssertEqual(
            document.lyricBlocks.map(\.text),
            [
                "Sent to this ridge,\nwith my camera in hand.",
                "I wanted to work for my country,\nbut I found myself unsure."
            ]
        )
        XCTAssertEqual(StructuredScriptDocumentProjector.export(document), raw)
    }

    func testLyricCardTextRemovesLegacyLineIndentation() throws {
        let raw = """
        JOHNNY:
        First line left.
        \tSecond line tabbed.
            Third line spaced.
        """

        let document = StructuredScriptDocumentProjector.parse(raw, hideLyricSpeakerCues: true)
        let block = try XCTUnwrap(document.lyricBlocks.first)

        XCTAssertEqual(
            block.text,
            """
            First line left.
            Second line tabbed.
            Third line spaced.
            """
        )
        XCTAssertEqual(StructuredScriptDocumentProjector.export(document), raw)
    }

    func testLyricCardHidesLeadingTechnicalCuesButPreservesThemOnEdit() throws {
        let raw = """
        JOHNNY:

        [camera: medium_close | label="Johnny lyric beat" | focus=johnny | bars=29-32]
        [action: "johnny" | description="delivers this pass2 lyric beat in the scene context" | bars=29-32]
        Then start with the boxes.
        Somebody will need what's in them.
        """

        let document = StructuredScriptDocumentProjector.parse(raw, hideLyricSpeakerCues: true)

        XCTAssertEqual(document.lyricBlocks.count, 1)
        let block = try XCTUnwrap(document.lyricBlocks.first)
        XCTAssertEqual(
            block.text,
            """
            Then start with the boxes.
            Somebody will need what's in them.
            """
        )
        XCTAssertTrue(block.technicalPrefix.contains("[camera: medium_close"))
        XCTAssertTrue(block.technicalPrefix.contains("[action: \"johnny\""))
        XCTAssertEqual(StructuredScriptDocumentProjector.export(document), raw)

        let updated = StructuredScriptDocumentProjector.updatingLyricBlockText(
            in: document,
            blockID: block.id,
            text: "Then start with the crates."
        )
        let exported = StructuredScriptDocumentProjector.export(updated)

        XCTAssertTrue(exported.contains("[camera: medium_close"))
        XCTAssertTrue(exported.contains("[action: \"johnny\""))
        XCTAssertTrue(exported.contains("Then start with the crates."))
        XCTAssertFalse(exported.contains("Then start with the boxes."))
    }

    func testLaterLyricParagraphWithTechnicalCueDoesNotRemainVisible() throws {
        let raw = """
        LUKE:
        [camera: medium | label="First lyric beat"]
        [lipsync: "luke" | transcript="First line." | bars=1-4]
        First line.

        [camera: close | label="Second lyric beat"]
        [lipsync: "luke" | transcript="Second line." | bars=5-8]
        Second line.
        """

        let document = StructuredScriptDocumentProjector.parse(raw, hideLyricSpeakerCues: true)

        XCTAssertEqual(
            document.visibleText.trimmingCharacters(in: .whitespacesAndNewlines),
            ""
        )
        XCTAssertEqual(document.lyricBlocks.count, 2)
        XCTAssertEqual(document.lyricBlocks.map(\.text), ["First line.", "Second line."])
        XCTAssertEqual(document.shots.count, 1)
        XCTAssertEqual(document.shots.first?.card.camera.label, "Second lyric beat")
        XCTAssertEqual(StructuredScriptDocumentProjector.export(document), raw)
    }

    func testVisibleLyricEditShiftsShotAndHiddenMarkupAnchors() throws {
        let raw = "[camera: wide]Hello [object: lantern]world[camera: close]"
        let document = StructuredScriptDocumentProjector.parse(raw)
        let insertionPoint = ("Hello " as NSString).length
        let editedVisible = "Hello bright world"

        let edited = StructuredScriptDocumentProjector.applyingVisibleEdit(
            to: document,
            affectedRange: NSRange(location: insertionPoint, length: 0),
            replacementString: "bright ",
            resultingVisibleText: editedVisible
        )
        let exported = StructuredScriptDocumentProjector.export(edited)

        XCTAssertEqual(edited.visibleText, editedVisible)
        XCTAssertTrue(exported.contains("Hello bright [object: lantern]world"))
        XCTAssertTrue(exported.hasPrefix("[camera: wide]"))
        XCTAssertTrue(exported.hasSuffix("[camera: close]"))
    }

    func testMovingShotEndCanPlaceNextShotMidLyric() throws {
        let raw = "[camera: wide]I thought I could carry the silence alone[camera: close]"
        let document = StructuredScriptDocumentProjector.parse(raw)
        let firstShot = try XCTUnwrap(document.shots.first)
        let targetOffset = ("I thought I could carry " as NSString).length

        let moved = StructuredScriptDocumentProjector.movingShotEnd(
            in: document,
            shotID: firstShot.id,
            to: targetOffset
        )
        let exported = StructuredScriptDocumentProjector.export(moved)

        XCTAssertEqual(moved.visibleText, "I thought I could carry the silence alone")
        XCTAssertTrue(exported.contains("carry [camera: close"))
        XCTAssertTrue(exported.contains("id="))
        XCTAssertTrue(exported.contains("]the silence"))
    }

    func testMovingShotBoundaryPreservesAllHiddenPromptMarkup() throws {
        let raw = """
        [scene: "Mountain Valley" | bg=mountain_valley_dawn]
        [camera: hold | label="Dawn line crosses the valley" | from=extreme_wide | to=extreme_wide | focus=valley-sunrise-line | intent=establishing | bars=1-8]
        [object: "valley-sunrise-line" | position=center | bars=1-8]

        The valley is seen from high above before the sun has cleared the mountain.

        [camera: wide | label="Three Humvees crest the ridge" | focus=convoy-column | intent=reveal | bars=9-12]
        [object_move: "convoy-column" | from_x=0.78 | to_x=0.58 | bars=9-12]

        As the sunlight touches the ridge, three Humvees break the skyline.
        """
        let document = StructuredScriptDocumentProjector.parse(raw)
        let firstShot = try XCTUnwrap(document.shots.first)
        let targetOffset = ("The valley is seen from high above before " as NSString).length

        let moved = StructuredScriptDocumentProjector.movingShotEnd(
            in: document,
            shotID: firstShot.id,
            to: targetOffset
        )
        let exported = StructuredScriptDocumentProjector.export(moved)

        XCTAssertEqual(promptCount(in: exported), promptCount(in: raw))
        XCTAssertEqual(cameraPromptCount(in: exported), cameraPromptCount(in: raw))
        XCTAssertTrue(exported.contains("[object: \"valley-sunrise-line\""))
        XCTAssertTrue(exported.contains("[object_move: \"convoy-column\""))
    }

    func testRemovingShotLeavesLyricTextAndOtherShotsUntouched() throws {
        let raw = "[camera: wide]First line[camera: close] second line"
        let document = StructuredScriptDocumentProjector.parse(raw)
        let firstShot = try XCTUnwrap(document.shots.first)

        let removed = StructuredScriptDocumentProjector.removingShot(
            from: document,
            shotID: firstShot.id
        )
        let exported = StructuredScriptDocumentProjector.export(removed)

        XCTAssertEqual(removed.visibleText, "First line second line")
        XCTAssertFalse(exported.contains("[camera: wide]"))
        XCTAssertTrue(exported.contains("[camera: close]"))
        XCTAssertTrue(exported.contains("First line"))
        XCTAssertTrue(exported.contains("second line"))
    }

    func testEditingShotCardRewritesOnlyThatCameraMarkup() throws {
        let raw = "[camera: wide | label=\"Start\"]First line[camera: close] second line"
        let document = StructuredScriptDocumentProjector.parse(raw)
        let firstShot = try XCTUnwrap(document.shots.first)

        var editedCard = firstShot.card
        editedCard.label = "Closer Start"
        editedCard.camera.label = "Closer Start"
        editedCard.camera.shotSize = "medium_close"
        editedCard.camera.focus = "luke"
        editedCard.status = .manual
        editedCard.provenance = CardProvenance(source: .manual)

        let updated = StructuredScriptDocumentProjector.updatingShotCard(
            in: document,
            shotID: firstShot.id,
            card: editedCard
        )
        let exported = StructuredScriptDocumentProjector.export(updated)

        XCTAssertTrue(exported.contains("[camera: medium_close"))
        XCTAssertTrue(exported.contains("label=Closer Start"))
        XCTAssertTrue(exported.contains("focus=luke"))
        XCTAssertTrue(exported.contains("[camera: close] second line"))
        XCTAssertFalse(exported.contains("label=\"Start\""))
    }

    func testEditingShotCardPreservesCharacterFramingFields() throws {
        let raw = "[camera: wide | time_of_day=dusk | interior_exterior=exterior | weather_atmosphere=haze | light_source=moonlight | lens=wide | camera_angle=low_angle | depth_of_field=shallow_focus | continuity_notes=match dust on uniforms | character_left=johnny | character_left_facing=towards_camera | character_middle=amira | character_middle_facing=left | character_right=luke | character_right_facing=away_from_camera]First line"
        let document = StructuredScriptDocumentProjector.parse(raw)
        let firstShot = try XCTUnwrap(document.shots.first)

        XCTAssertEqual(firstShot.card.setting.timeOfDay, "dusk")
        XCTAssertEqual(firstShot.card.setting.interiorExterior, "exterior")
        XCTAssertEqual(firstShot.card.setting.weatherAtmosphere, "haze")
        XCTAssertEqual(firstShot.card.setting.lightSource, "moonlight")
        XCTAssertEqual(firstShot.card.setting.lens, "wide")
        XCTAssertEqual(firstShot.card.setting.cameraAngle, "low_angle")
        XCTAssertEqual(firstShot.card.setting.depthOfField, "shallow_focus")
        XCTAssertEqual(firstShot.card.setting.continuityNotes, "match dust on uniforms")
        XCTAssertEqual(firstShot.card.characterFraming.left, ["johnny"])
        XCTAssertEqual(firstShot.card.characterFraming.middle, ["amira"])
        XCTAssertEqual(firstShot.card.characterFraming.right, ["luke"])
        XCTAssertEqual(firstShot.card.characterFraming.leftFacing, "towards_camera")
        XCTAssertEqual(firstShot.card.characterFraming.middleFacing, "left")
        XCTAssertEqual(firstShot.card.characterFraming.rightFacing, "away_from_camera")

        var editedCard = firstShot.card
        editedCard.status = .manual
        editedCard.provenance = CardProvenance(source: .manual)

        let updated = StructuredScriptDocumentProjector.updatingShotCard(
            in: document,
            shotID: firstShot.id,
            card: editedCard
        )
        let exported = StructuredScriptDocumentProjector.export(updated)

        XCTAssertTrue(exported.contains("time_of_day=dusk"))
        XCTAssertTrue(exported.contains("interior_exterior=exterior"))
        XCTAssertTrue(exported.contains("weather_atmosphere=haze"))
        XCTAssertTrue(exported.contains("light_source=moonlight"))
        XCTAssertTrue(exported.contains("lens=wide"))
        XCTAssertTrue(exported.contains("camera_angle=low_angle"))
        XCTAssertTrue(exported.contains("depth_of_field=shallow_focus"))
        XCTAssertTrue(exported.contains("continuity_notes=match dust on uniforms"))
        XCTAssertTrue(exported.contains("character_left=johnny"))
        XCTAssertTrue(exported.contains("character_left_facing=towards_camera"))
        XCTAssertTrue(exported.contains("character_middle=amira"))
        XCTAssertTrue(exported.contains("character_middle_facing=left"))
        XCTAssertTrue(exported.contains("character_right=luke"))
        XCTAssertTrue(exported.contains("character_right_facing=away_from_camera"))
    }

    func testStructuredCardCreationExportsBackendMarkup() throws {
        let raw = "Existing line"
        let base = StructuredScriptDocumentProjector.parse(raw, hideLyricSpeakerCues: true)
        let withLyric = StructuredScriptDocumentProjector.addingLyricBlock(
            to: base,
            at: 0,
            speakerName: "Johnny",
            text: "New lyric"
        )
        let withAction = StructuredScriptDocumentProjector.addingAction(
            to: withLyric,
            at: 0,
            text: "Johnny lifts the camera"
        )
        let withShot = StructuredScriptDocumentProjector.addingShot(
            to: withAction,
            at: 0
        )
        let exported = StructuredScriptDocumentProjector.export(withShot)

        XCTAssertTrue(exported.contains("JOHNNY:"))
        XCTAssertTrue(exported.contains("New lyric"))
        XCTAssertTrue(exported.contains("[Johnny lifts the camera]"))
        XCTAssertTrue(exported.contains("[camera: medium"))
        XCTAssertTrue(exported.contains("id="))
        XCTAssertTrue(exported.contains("Existing line"))
    }

    func testSourceOrderFollowsRawTimelineOrderWhenLyricsAreHidden() throws {
        let raw = """
        JOHNNY:
        First stanza.

        [camera: wide | label="Second beat"]
        JOHNNY:
        Second stanza.
        """
        let document = StructuredScriptDocumentProjector.parse(raw, hideLyricSpeakerCues: true)
        let firstLyric = try XCTUnwrap(document.lyricBlocks.first)
        let shot = try XCTUnwrap(document.shots.first)
        let secondLyric = try XCTUnwrap(document.lyricBlocks.dropFirst().first)

        XCTAssertLessThan(firstLyric.sourceOrder, shot.sourceOrder)
        XCTAssertLessThan(shot.sourceOrder, secondLyric.sourceOrder)
    }

    private func promptCount(in text: String) -> Int {
        countMatches(#"(?<!\[)\[[A-Za-z_][A-Za-z0-9_\-]*\s*:[^\[\]]+\](?!\])"#, in: text)
    }

    private func cameraPromptCount(in text: String) -> Int {
        countMatches(#"(?<!\[)\[(?:camera|cinematography)\s*:[^\[\]]+\](?!\])"#, in: text)
    }

    private func countMatches(_ pattern: String, in text: String) -> Int {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.numberOfMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length)
        )
    }
}

import XCTest
@testable import NovotroWriteUI

@available(macOS 26.0, *)
final class SunoLyricsFormatterTests: XCTestCase {
    func testSoloFormattingBuildsVersesAndInstrumentalBreak() {
        let input = """
        {{{SYNOPSIS}}}
        Johnny spirals through insomnia.
        {{{/SYNOPSIS}}}
        1.26.0 - How
        INT. BARRACKS - JOHNNY'S ROOM / EARLIER NIGHT MEMORY
        (SUNG - Johnny solo. Earlier insomnia replayed inside the later night.)

        JOHNNY

        [Johnny in memory on his cot, camera beside him. The dark presses in.]

        \tWhat are these images
        \tthat keep developing in me?
        \tWhy does each frame feel like a crime?

        \tHow can I shelve them
        \tand wake to another morning?
        \tWhy can't this lens let me sleep?

        \tHow can one instant
        \tturn into a hundred frozen pictures?
        \tWhy do they stay in me?

        \tMy life was so simple,
        \twhy can't I stop seeing
        \tthe dust, the wall, the faces following me?

        {Instrumental - 8 bars. Johnny on his cot, camera beside him.}

        \tHow can I think,
        \twhen all these frozen negatives
        \tnever stop following me?

        \tWhat if I'm not witness,
        \tbut part of what feeds on sorrow?
        \tWhen will this war let me sleep?
        """

        let result = SunoLyricsFormatter.format(librettoText: input)

        XCTAssertEqual(
            result.formattedText,
            """
            [Verse 1]
            What are these images
            that keep developing in me?
            Why does each frame feel like a crime?

            [Verse 2]
            How can I shelve them
            and wake to another morning?
            Why can't this lens let me sleep?

            [Verse 3]
            How can one instant
            turn into a hundred frozen pictures?
            Why do they stay in me?

            [Verse 4]
            My life was so simple,
            why can't I stop seeing
            the dust, the wall, the faces following me?

            [Instrumental]

            [Verse 5]
            How can I think,
            when all these frozen negatives
            never stop following me?

            [Verse 6]
            What if I'm not witness,
            but part of what feeds on sorrow?
            When will this war let me sleep?
            """
        )
        XCTAssertEqual(result.speakerLabels["JOHNNY"], "Male 1")
    }

    func testDuetFormattingKeepsSpeakerLabelsThroughStageDirections() {
        let input = """
        2.09.0 - The Confession
        INT. AMIRA'S HOME - NIGHT
        (SUNG - Luke, with Amira responding.)

        LUKE:
        \t[voice breaking, facing Amira]
        \tDon't you get it?
        \tI was a soldier.

        AMIRA:
        \t[to Luke, steady and unsparing]
        \tI know what you are.
        \tI know what you've done.

        BOTH:
        There is truth we cannot bury.
        There is grief we do not choose.
        """

        let result = SunoLyricsFormatter.format(librettoText: input)

        XCTAssertEqual(
            result.formattedText,
            """
            [Verse 1]
            [Male 1]
            Don't you get it?
            I was a soldier.

            [Verse 2]
            [Female 1]
            I know what you are.
            I know what you've done.

            [Verse 3]
            [Duet]
            There is truth we cannot bury.
            There is grief we do not choose.
            """
        )
        XCTAssertEqual(result.speakerLabels["LUKE"], "Male 1")
        XCTAssertEqual(result.speakerLabels["AMIRA"], "Female 1")
    }

    func testRepeatedStanzaBecomesChorus() {
        let input = """
        JOHNNY:
        Take me home
        Take me home

        JOHNNY:
        I walk alone
        Through the night

        JOHNNY:
        Take me home
        Take me home
        """

        let result = SunoLyricsFormatter.format(librettoText: input)

        XCTAssertEqual(
            result.formattedText,
            """
            [Chorus]
            Take me home
            Take me home

            [Verse]
            I walk alone
            Through the night

            [Chorus]
            Take me home
            Take me home
            """
        )
    }
}

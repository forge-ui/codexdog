import Foundation
import Testing
@testable import CodexRelayMenu

@Test func enrollmentParserStripsRealANSIAndExtractsKeyTexts() {
    let output = """
    1. Open this link in your browser and sign in to your account
       \u{001B}[94mhttps://auth.openai.com/codex/device\u{001B}[0m

    2. Enter this one-time code \u{001B}[90m(expires in 15 minutes)\u{001B}[0m
       \u{001B}[94mTEST-C0DEX\u{001B}[0m
    """

    let parsed = EnrollmentOutputParser.parse(output)

    #expect(parsed.authorizationURL?.absoluteString == "https://auth.openai.com/codex/device")
    #expect(parsed.authorizationCode == "TEST-C0DEX")
    #expect(!parsed.cleanOutput.contains("[94m"))
    #expect(!parsed.cleanOutput.contains("\u{001B}"))
}

@Test func enrollmentParserStripsVisibleANSIFragments() {
    let output = """
    [94mhttps://auth.openai.com/codex/device[0m
    Enter this one-time code [90m(expires in 15 minutes)[0m
    [94mTEST-C0DEX[0m
    """

    let parsed = EnrollmentOutputParser.parse(output)

    #expect(parsed.authorizationURL?.absoluteString == "https://auth.openai.com/codex/device")
    #expect(parsed.authorizationCode == "TEST-C0DEX")
    #expect(!parsed.cleanOutput.contains("[90m"))
    #expect(!parsed.cleanOutput.contains("[0m"))
}

@Test func enrollmentParserHandlesControlSequencesSplitAcrossPipeChunks() {
    let chunks = [
        "Open \u{001B}",
        "[94mhttps://auth.openai.com/codex/device\u{001B}[0",
        "m\nEnter this one-time code: [9",
        "4mABCD-12345[0m",
    ]
    var buffer = ""
    var parsed = EnrollmentOutputParser.parse(buffer)

    for chunk in chunks {
        buffer.append(chunk)
        parsed = EnrollmentOutputParser.parse(buffer)
    }

    #expect(parsed.authorizationURL?.absoluteString == "https://auth.openai.com/codex/device")
    #expect(parsed.authorizationCode == "ABCD-12345")
    #expect(!parsed.cleanOutput.contains("[94m"))
}

@Test func enrollmentParserDoesNotInventAnIncompleteCode() {
    let parsed = EnrollmentOutputParser.parse(
        "https://auth.openai.com/codex/device\nEnter this one-time code: ABCD-"
    )

    #expect(parsed.authorizationURL?.absoluteString == "https://auth.openai.com/codex/device")
    #expect(parsed.authorizationCode == nil)
}

@Test func enrollmentParserDoesNotTreatHyphenatedProductNamesAsCodes() {
    let parsed = EnrollmentOutputParser.parse("Starting OPENAI-CODEX enrollment")

    #expect(parsed.authorizationCode == nil)
}

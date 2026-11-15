import Testing
@testable import TagKit

// Plain literals (not #_sourceLocation) so the shared cases file doesn't need `import Testing`.
func check(_ condition: Bool, _ message: @autoclosure () -> String = "",
           fileID: String = #fileID, filePath: String = #filePath, line: Int = #line, column: Int = #column) {
    #expect(condition, Comment(rawValue: message()),
            sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column))
}

@Suite("Tag protocol")
struct ProtocolTests {
    @Test func legacyWording() { TagKitCases.legacyWording() }
    @Test func structuredTags() { TagKitCases.structuredTags() }
    @Test func commands() { TagKitCases.commands() }
    @Test func snapshotTransitions() { TagKitCases.snapshotTransitions() }
    @Test func configurationParsing() { TagKitCases.configurationParsing() }
    @Test func findMyDecoding() throws { try TagKitCases.findMyDecoding() }
}

@Suite("Tag link") @MainActor
struct LinkTests {
    @Test func confirmsOnTagPush() async { await TagKitCases.linkConfirmsOnTagPush() }
    @Test func timesOutWithoutAnswer() async { await TagKitCases.linkTimesOutWithoutAnswer() }
    @Test func unconfirmableAndBusy() async { await TagKitCases.linkUnconfirmableAndBusy() }
    @Test func matchesRequestIDs() async { await TagKitCases.linkMatchesRequestIDs() }
    @Test func persistsAndDedupes() async { await TagKitCases.linkPersistsAndDedupes() }
    @Test func catchUpDoesNotConfirm() async { await TagKitCases.linkCatchUpDoesNotConfirm() }
}

// Toolchain-only test runner for machines without Xcode (see verify.sh).
// Runs the same TagKitCases as the Swift Testing suite.
import Foundation

nonisolated(unsafe) var failures: [String] = []

func check(_ condition: Bool, _ message: @autoclosure () -> String = "", file: StaticString = #fileID, line: UInt = #line) {
    if !condition { failures.append("\(file):\(line) \(message())") }
}

@main
struct Runner {
    @MainActor
    static func main() async {
        let sync: [(String, () throws -> Void)] = [
            ("legacyWording", TagKitCases.legacyWording),
            ("structuredTags", TagKitCases.structuredTags),
            ("commands", TagKitCases.commands),
            ("snapshotTransitions", TagKitCases.snapshotTransitions),
            ("configurationParsing", TagKitCases.configurationParsing),
            ("findMyDecoding", TagKitCases.findMyDecoding),
        ]
        let async: [(String, @MainActor () async -> Void)] = [
            ("linkConfirmsOnTagPush", TagKitCases.linkConfirmsOnTagPush),
            ("linkTimesOutWithoutAnswer", TagKitCases.linkTimesOutWithoutAnswer),
            ("linkUnconfirmableAndBusy", TagKitCases.linkUnconfirmableAndBusy),
            ("linkMatchesRequestIDs", TagKitCases.linkMatchesRequestIDs),
            ("linkPersistsAndDedupes", TagKitCases.linkPersistsAndDedupes),
            ("linkCatchUpDoesNotConfirm", TagKitCases.linkCatchUpDoesNotConfirm),
        ]
        var passed = 0
        for (name, run) in sync {
            let before = failures.count
            do { try run() } catch { failures.append("\(name) threw \(error)") }
            report(name, ok: failures.count == before, &passed)
        }
        for (name, run) in async {
            let before = failures.count
            await run()
            report(name, ok: failures.count == before, &passed)
        }
        let total = sync.count + async.count
        print("\n\(passed)/\(total) test cases passed")
        for f in failures { print("  FAIL \(f)") }
        exit(failures.isEmpty ? 0 : 1)
    }

    static func report(_ name: String, ok: Bool, _ passed: inout Int) {
        print("\(ok ? "✔" : "✘") \(name)")
        if ok { passed += 1 }
    }
}

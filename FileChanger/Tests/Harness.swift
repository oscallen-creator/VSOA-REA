import Foundation

// Minimal test harness (XCTest needs Xcode; this Mac has Command Line Tools only).
// Add a suite with `TestSuites.all.append(...)` is not possible at load time in Swift, so each
// test file declares `extension TestSuites { static let <name> = Suite(...) }` and is listed in `TestSuites.all`.

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

struct Suite {
    let name: String
    let tests: [(String, () async throws -> Void)]
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
            file: StaticString = #fileID, line: UInt = #line) throws {
    if try !condition() { throw TestFailure(description: "\(file):\(line) \(message())") }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #fileID, line: UInt = #line) throws {
    if a != b { throw TestFailure(description: "\(file):\(line) expected \(b), got \(a)") }
}

/// Fixtures live in Tests/Fixtures; generated media go to a fresh temp folder per run.
enum Fixtures {
    static let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FILECHANGER_FIXTURES"] ?? "Tests/Fixtures")
    static let scratch: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("filechanger-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
}

@main
enum TestMain {
    static func main() async {
        let filter = (ProcessInfo.processInfo.environment["FILECHANGER_TEST_FILTER"] ?? "").lowercased()
        var passed = 0, failed = 0
        for suite in TestSuites.all where filter.isEmpty || suite.name.lowercased().contains(filter) {
            for (name, body) in suite.tests {
                do {
                    try await body()
                    passed += 1
                    print("pass  \(suite.name) / \(name)")
                } catch {
                    failed += 1
                    print("FAIL  \(suite.name) / \(name): \(error)")
                }
            }
        }
        print("\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

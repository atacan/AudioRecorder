import XCTest

@testable import AudioRecorderClient

let deadbeefID = UUID(uuidString: "DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF")!
let deadbeefURL = URL(fileURLWithPath: "/tmp/DEADBEEF-DEAD-BEEF-DEAD-BEEFDEADBEEF.m4a")

@MainActor
final class AudioRecorderClientTests: XCTestCase {
}

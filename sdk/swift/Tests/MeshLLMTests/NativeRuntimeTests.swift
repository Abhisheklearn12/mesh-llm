import CryptoKit
import Foundation
import XCTest
@testable import MeshLLM

final class NativeRuntimeTests: XCTestCase {
    func testValidateAcceptsVerifiedArtifact() throws {
        let artifactDirectory = try writeArtifact()

        let artifact = try NativeRuntime.validate(artifactDirectory: artifactDirectory)

        XCTAssertEqual(artifact.artifactId, "meshllm-native-test-cpu")
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.library.path))
    }

    func testValidateRejectsChecksumMismatch() throws {
        let artifactDirectory = try writeArtifact()
        let library = artifactDirectory.appendingPathComponent("lib/libmeshllm_ffi.dylib")
        let handle = try FileHandle(forWritingTo: library)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("changed".utf8))

        XCTAssertThrowsError(try NativeRuntime.validate(artifactDirectory: artifactDirectory)) { error in
            XCTAssertEqual(error as? NativeRuntimeError, .checksumMismatch(library.standardizedFileURL))
        }
    }

    func testResolveUsesExplicitArtifactDirectory() throws {
        let artifactDirectory = try writeArtifact()

        let artifact = try NativeRuntime.resolve(
            NativeRuntimeConfig(artifactDirectory: artifactDirectory)
        )

        XCTAssertEqual(artifact.artifactDirectory.path, artifactDirectory.standardizedFileURL.path)
    }

    private func writeArtifact() throws -> URL {
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let libDirectory = artifactDirectory.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: libDirectory, withIntermediateDirectories: true)

        let library = libDirectory.appendingPathComponent("libmeshllm_ffi.dylib")
        let bytes = Data("native runtime".utf8)
        try bytes.write(to: library)
        let sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let manifest = """
        {
          "artifact_id": "meshllm-native-test-cpu",
          "library": "lib/libmeshllm_ffi.dylib",
          "library_sha256": "\(sha256)"
        }
        """
        try Data(manifest.utf8).write(to: artifactDirectory.appendingPathComponent("manifest.json"))
        return artifactDirectory
    }
}

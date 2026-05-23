import CryptoKit
import Foundation

public struct NativeRuntimeConfig: Sendable {
    public let artifactDirectory: URL?
    public let searchDirectories: [URL]

    public init(artifactDirectory: URL? = nil, searchDirectories: [URL] = []) {
        self.artifactDirectory = artifactDirectory
        self.searchDirectories = searchDirectories
    }
}

public struct NativeRuntimeArtifact: Sendable, Equatable {
    public let artifactId: String
    public let artifactDirectory: URL
    public let manifest: URL
    public let library: URL
}

public enum NativeRuntimeError: Error, LocalizedError, Equatable {
    case notFound(String)
    case invalidArtifact(String)
    case checksumMismatch(URL)

    public var errorDescription: String? {
        switch self {
        case .notFound(let detail):
            return "MeshLLM native runtime artifact not found: \(detail)"
        case .invalidArtifact(let detail):
            return "Invalid MeshLLM native runtime artifact: \(detail)"
        case .checksumMismatch(let url):
            return "MeshLLM native runtime checksum mismatch: \(url.path)"
        }
    }
}

public enum NativeRuntime {
    public static func resolve(_ config: NativeRuntimeConfig = NativeRuntimeConfig()) throws -> NativeRuntimeArtifact {
        var candidates: [URL] = []
        if let artifactDirectory = config.artifactDirectory {
            candidates.append(artifactDirectory)
        }
        candidates.append(contentsOf: environmentDirectories())
        candidates.append(contentsOf: config.searchDirectories)
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("meshllm-native"))
            candidates.append(resourceURL.appendingPathComponent("native"))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("meshllm-native"))
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("native"))

        var errors: [String] = []
        var seen = Set<String>()
        for candidate in candidates {
            for artifactDirectory in artifactCandidates(candidate) {
                let normalized = artifactDirectory.standardizedFileURL
                guard seen.insert(normalized.path).inserted else {
                    continue
                }
                do {
                    return try validate(artifactDirectory: normalized)
                } catch {
                    errors.append("\(normalized.path): \(error.localizedDescription)")
                }
            }
        }

        let detail = errors.isEmpty
            ? "no candidate runtime artifact directories were configured"
            : errors.joined(separator: "; ")
        throw NativeRuntimeError.notFound(detail)
    }

    @discardableResult
    public static func prepare(_ config: NativeRuntimeConfig = NativeRuntimeConfig()) throws -> NativeRuntimeArtifact {
        try resolve(config)
    }

    public static func validate(artifactDirectory: URL) throws -> NativeRuntimeArtifact {
        let artifactDirectory = artifactDirectory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: artifactDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NativeRuntimeError.invalidArtifact("artifact directory does not exist: \(artifactDirectory.path)")
        }

        let manifestURL = artifactDirectory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw NativeRuntimeError.invalidArtifact("manifest.json does not exist: \(manifestURL.path)")
        }

        let manifest = try JSONDecoder().decode(
            NativeRuntimeManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let library = artifactDirectory.appendingPathComponent(manifest.library)
        guard FileManager.default.fileExists(atPath: library.path) else {
            throw NativeRuntimeError.invalidArtifact("native library does not exist: \(library.path)")
        }

        let expected = manifest.librarySha256.lowercased()
        guard try sha256Hex(library) == expected else {
            throw NativeRuntimeError.checksumMismatch(library)
        }

        return NativeRuntimeArtifact(
            artifactId: manifest.artifactId,
            artifactDirectory: artifactDirectory,
            manifest: manifestURL,
            library: library
        )
    }

    private static func environmentDirectories() -> [URL] {
        let env = ProcessInfo.processInfo.environment
        var urls: [URL] = []
        for name in [
            "MESHLLM_NATIVE_RUNTIME_ARTIFACT_DIR",
            "MESHLLM_NATIVE_RUNTIME_DIR",
            "MESH_SDK_NATIVE_RUNTIME_DIR",
        ] {
            if let value = env[name], !value.isEmpty {
                urls.append(URL(fileURLWithPath: value))
            }
        }
        if let library = env["MESHLLM_NATIVE_RUNTIME_LIBRARY"], !library.isEmpty {
            urls.append(URL(fileURLWithPath: library).deletingLastPathComponent().deletingLastPathComponent())
        }
        return urls
    }

    private static func artifactCandidates(_ candidate: URL) -> [URL] {
        let normalized = candidate.standardizedFileURL
        if FileManager.default.fileExists(atPath: normalized.appendingPathComponent("manifest.json").path) {
            return [normalized]
        }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: normalized,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        let artifacts = children
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                return values?.isDirectory == true && url.lastPathComponent.hasPrefix("meshllm-native-")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return [normalized] + artifacts
    }

    private static func sha256Hex(_ url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct NativeRuntimeManifest: Decodable {
    let artifactId: String
    let library: String
    let librarySha256: String

    enum CodingKeys: String, CodingKey {
        case artifactId = "artifact_id"
        case library
        case librarySha256 = "library_sha256"
    }
}

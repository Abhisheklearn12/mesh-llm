package ai.meshllm

import java.io.File
import java.security.MessageDigest

data class NativeRuntimeConfig(
    val artifactDir: File? = null,
    val searchDirs: List<File> = emptyList(),
)

data class NativeRuntimeArtifact(
    val artifactId: String,
    val artifactDir: File,
    val manifest: File,
    val library: File,
)

object NativeRuntime {
    private const val COMPONENT_LIBRARY_OVERRIDE = "uniffi.component.mesh_ffi.libraryOverride"

    fun configure(config: NativeRuntimeConfig = NativeRuntimeConfig()): NativeRuntimeArtifact {
        val artifact = resolve(config)
        System.setProperty(COMPONENT_LIBRARY_OVERRIDE, artifact.library.absolutePath)
        return artifact
    }

    fun resolve(config: NativeRuntimeConfig = NativeRuntimeConfig()): NativeRuntimeArtifact {
        val candidates = buildList {
            config.artifactDir?.let(::add)
            systemPath("meshllm.nativeRuntime.artifactDir")?.let(::add)
            systemPath("meshllm.nativeRuntime.dir")?.let(::add)
            envPath("MESHLLM_NATIVE_RUNTIME_ARTIFACT_DIR")?.let(::add)
            envPath("MESHLLM_NATIVE_RUNTIME_DIR")?.let(::add)
            envPath("MESH_SDK_NATIVE_RUNTIME_DIR")?.let(::add)
            envPath("MESHLLM_NATIVE_RUNTIME_LIBRARY")?.parentFile?.parentFile?.let(::add)
            addAll(config.searchDirs)
            add(File(System.getProperty("user.dir"), "meshllm-native"))
            add(File(System.getProperty("user.dir"), "native"))
        }

        val errors = mutableListOf<String>()
        for (candidate in candidates.distinctBy { it.normalized().path }) {
            for (artifactDir in artifactCandidates(candidate)) {
                val result = runCatching { validate(artifactDir) }
                result.getOrNull()?.let { return it }
                result.exceptionOrNull()?.message?.let { errors.add("${artifactDir.path}: $it") }
            }
        }

        val detail = if (errors.isEmpty()) {
            "no candidate runtime artifact directories were configured"
        } else {
            errors.joinToString("; ")
        }
        throw IllegalStateException("MeshLLM native runtime artifact not found: $detail")
    }

    fun validate(artifactDir: File): NativeRuntimeArtifact {
        val normalizedDir = artifactDir.normalized()
        val manifest = normalizedDir.resolve("manifest.json")
        require(normalizedDir.isDirectory) { "artifact directory does not exist" }
        require(manifest.isFile) { "manifest.json does not exist" }

        val manifestText = manifest.readText()
        val artifactId = stringField(manifestText, "artifact_id")
        val libraryRelativePath = stringField(manifestText, "library")
        val expectedSha256 = stringField(manifestText, "library_sha256").lowercase()

        val library = normalizedDir.resolve(libraryRelativePath).normalized()
        require(library.isFile) { "native library does not exist: ${library.path}" }

        val actualLibrarySha256 = sha256(library)
        require(actualLibrarySha256 == expectedSha256) {
            "native library checksum mismatch for ${library.path}"
        }

        return NativeRuntimeArtifact(
            artifactId = artifactId,
            artifactDir = normalizedDir,
            manifest = manifest,
            library = library,
        )
    }

    private fun systemPath(name: String): File? =
        System.getProperty(name)?.takeIf(String::isNotBlank)?.let(::File)

    private fun envPath(name: String): File? =
        System.getenv(name)?.takeIf(String::isNotBlank)?.let(::File)

    private fun artifactCandidates(candidate: File): List<File> {
        val normalized = candidate.normalized()
        if (normalized.resolve("manifest.json").isFile) {
            return listOf(normalized)
        }
        val children = normalized.listFiles()
            ?.filter { it.isDirectory && it.name.startsWith("meshllm-native-") }
            ?.sortedBy(File::getName)
            .orEmpty()
        return listOf(normalized) + children
    }

    private fun stringField(json: String, key: String): String {
        val pattern = Regex("\"${Regex.escape(key)}\"\\s*:\\s*\"((?:\\\\.|[^\"])*)\"")
        val match = pattern.find(json) ?: error("manifest field missing or not a string: $key")
        return match.groupValues[1]
            .replace("\\/", "/")
            .replace("\\\"", "\"")
            .replace("\\\\", "\\")
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) {
                    break
                }
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun File.normalized(): File = absoluteFile.toPath().normalize().toFile()
}

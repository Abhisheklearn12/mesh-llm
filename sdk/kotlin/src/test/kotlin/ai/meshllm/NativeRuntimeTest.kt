package ai.meshllm

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest

class NativeRuntimeTest {
    @Test
    fun validateAcceptsVerifiedArtifact() {
        val artifactDir = writeArtifact()

        val artifact = NativeRuntime.validate(artifactDir)

        assertEquals("meshllm-native-test-cpu", artifact.artifactId)
        assertTrue(artifact.library.isFile)
    }

    @Test
    fun validateRejectsChecksumMismatch() {
        val artifactDir = writeArtifact()
        artifactDir.resolve("lib/libmeshllm_ffi.so").appendText("changed")

        val error = runCatching { NativeRuntime.validate(artifactDir) }.exceptionOrNull()

        assertTrue(error is IllegalArgumentException)
        assertTrue(error?.message?.contains("checksum mismatch") == true)
    }

    @Test
    fun configureSetsUniffiLibraryOverride() {
        val previous = System.getProperty("uniffi.component.mesh_ffi.libraryOverride")
        val artifactDir = writeArtifact()

        try {
            val artifact = NativeRuntime.configure(NativeRuntimeConfig(artifactDir = artifactDir))

            assertEquals(
                artifact.library.absolutePath,
                System.getProperty("uniffi.component.mesh_ffi.libraryOverride"),
            )
        } finally {
            if (previous == null) {
                System.clearProperty("uniffi.component.mesh_ffi.libraryOverride")
            } else {
                System.setProperty("uniffi.component.mesh_ffi.libraryOverride", previous)
            }
        }
    }

    private fun writeArtifact(): File {
        val artifactDir = Files.createTempDirectory("meshllm-native-test").toFile()
        val libDir = artifactDir.resolve("lib")
        libDir.mkdirs()
        val library = libDir.resolve("libmeshllm_ffi.so")
        library.writeText("native runtime")
        val sha256 = sha256(library)
        artifactDir.resolve("manifest.json").writeText(
            """
            {
              "artifact_id": "meshllm-native-test-cpu",
              "library": "lib/libmeshllm_ffi.so",
              "library_sha256": "$sha256"
            }
            """.trimIndent(),
        )
        return artifactDir
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        digest.update(file.readBytes())
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}

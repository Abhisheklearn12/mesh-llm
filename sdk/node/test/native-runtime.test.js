'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const crypto = require('node:crypto')
const { validateNativeRuntime } = require('../native-runtime')

test('validateNativeRuntime accepts a single-library artifact', () => {
  const artifactDir = fs.mkdtempSync(path.join(os.tmpdir(), 'meshllm-native-test-'))
  const libDir = path.join(artifactDir, 'lib')
  fs.mkdirSync(libDir)
  const library = path.join(libDir, process.platform === 'win32' ? 'meshllm_ffi.dll' : 'libmeshllm_ffi.so')
  fs.writeFileSync(library, 'native runtime')
  const sha = crypto.createHash('sha256').update(fs.readFileSync(library)).digest('hex')
  fs.writeFileSync(path.join(artifactDir, 'manifest.json'), JSON.stringify({
    artifact_id: 'meshllm-native-test-cpu',
    library: `lib/${path.basename(library)}`,
    library_sha256: sha
  }))

  const artifact = validateNativeRuntime(artifactDir)
  assert.equal(artifact.artifactId, 'meshllm-native-test-cpu')
  assert.equal(artifact.library, library)
})

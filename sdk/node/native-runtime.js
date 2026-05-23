'use strict'

const fs = require('node:fs')
const path = require('node:path')
const crypto = require('node:crypto')

const runtimeEnvNames = [
  'MESHLLM_NATIVE_RUNTIME_ARTIFACT_DIR',
  'MESHLLM_NATIVE_RUNTIME_DIR',
  'MESH_SDK_NATIVE_RUNTIME_DIR'
]

function resolveNativeRuntime(options = {}) {
  const candidates = []
  if (options.artifactDir) candidates.push(options.artifactDir)
  for (const name of runtimeEnvNames) {
    if (process.env[name]) candidates.push(process.env[name])
  }
  if (process.env.MESHLLM_NATIVE_RUNTIME_LIBRARY) {
    candidates.push(path.dirname(path.dirname(process.env.MESHLLM_NATIVE_RUNTIME_LIBRARY)))
  }
  for (const dir of options.searchDirs || []) candidates.push(dir)
  candidates.push(path.join(process.cwd(), 'meshllm-native'))
  candidates.push(path.join(process.cwd(), 'native'))

  const errors = []
  const seen = new Set()
  for (const candidate of candidates) {
    for (const artifactDir of artifactCandidates(candidate)) {
      const normalized = path.resolve(artifactDir)
      if (seen.has(normalized)) continue
      seen.add(normalized)
      try {
        return validateNativeRuntime(normalized)
      } catch (error) {
        errors.push(`${normalized}: ${error.message}`)
      }
    }
  }

  const detail = errors.length === 0
    ? 'no candidate native runtime artifact directories were configured'
    : errors.join('; ')
  throw new Error(`MeshLLM native runtime artifact not found: ${detail}`)
}

function validateNativeRuntime(artifactDir) {
  const normalized = path.resolve(artifactDir)
  const manifestPath = path.join(normalized, 'manifest.json')
  if (!fs.existsSync(normalized) || !fs.statSync(normalized).isDirectory()) {
    throw new Error('artifact directory does not exist')
  }
  if (!fs.existsSync(manifestPath)) {
    throw new Error('manifest.json does not exist')
  }

  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'))
  const library = path.resolve(normalized, requiredString(manifest, 'library'))
  const expected = requiredString(manifest, 'library_sha256').toLowerCase()
  if (!fs.existsSync(library)) {
    throw new Error(`native library does not exist: ${library}`)
  }
  const actual = sha256(library)
  if (actual !== expected) {
    throw new Error(`native library checksum mismatch for ${library}`)
  }

  return {
    artifactId: requiredString(manifest, 'artifact_id'),
    artifactDir: normalized,
    manifest: manifestPath,
    library,
    metadata: manifest
  }
}

function artifactCandidates(candidate) {
  if (!candidate) return []
  const normalized = path.resolve(candidate)
  if (fs.existsSync(path.join(normalized, 'manifest.json'))) {
    return [normalized]
  }
  if (!fs.existsSync(normalized) || !fs.statSync(normalized).isDirectory()) {
    return [normalized]
  }
  const children = fs.readdirSync(normalized)
    .map((entry) => path.join(normalized, entry))
    .filter((entry) => fs.statSync(entry).isDirectory() && path.basename(entry).startsWith('meshllm-native-'))
    .sort()
  return [normalized, ...children]
}

function requiredString(object, key) {
  if (typeof object[key] !== 'string' || object[key].length === 0) {
    throw new Error(`manifest field missing or not a string: ${key}`)
  }
  return object[key]
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')
}

module.exports = {
  resolveNativeRuntime,
  validateNativeRuntime
}

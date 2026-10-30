import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import vm from 'node:vm'
import test from 'node:test'

const publicDirectory = new URL('../public/', import.meta.url)
const readPublicFile = name => readFile(new URL(name, publicDirectory), 'utf8')

async function renderReleaseVersions(payload, { fetchError = false } = {}) {
  const elements = new Map()
  const document = {
    getElementById(id) {
      if (!elements.has(id)) {
        const classes = new Set(['skeleton'])
        elements.set(id, {
          classList: {
            add: name => classes.add(name),
            remove: name => classes.delete(name),
            contains: name => classes.has(name),
          },
          textContent: '',
          href: '',
        })
      }
      return elements.get(id)
    },
    addEventListener() {},
  }
  const window = {
    MoumusicI18n: {
      language: () => 'en',
      t: (key, values) => key === 'install.latestVersion'
        ? `version:${values.version}`
        : 'unavailable',
    },
  }
  const context = {
    document,
    window,
    Date,
    fetch: async () => {
      if (fetchError) throw new Error('request failed')
      return { ok: true, json: async () => payload }
    },
  }
  const installScript = await readPublicFile('install.js')
  const loadPromise = vm.runInNewContext(installScript, context)
  await loadPromise

  return {
    latest: elements.get('latest-release-version').textContent,
    ios: elements.get('ios-release-version').textContent,
  }
}

test('public HTML exposes only the iOS IPA installation path', async () => {
  const [home, install] = await Promise.all([
    readPublicFile('index.html'),
    readPublicFile('install.html'),
  ])

  assert.doesNotMatch(`${home}\n${install}`, /android|\bapk\b/i)
  assert.doesNotMatch(install, /id=["']android-download["']/i)
  assert.match(install, /id=["']ios-download["']/)
})

test('public platform translations describe iOS IPA only', async () => {
  const translations = await readPublicFile('i18n.js')

  assert.doesNotMatch(translations, /android|\bapk\b/i)
  assert.match(translations, /'hero\.meta': '最新版 iOS IPA'/)
  assert.match(translations, /'install\.iosDownload': '下载 iOS IPA'/)
  assert.match(translations, /'hero\.meta': 'Latest iOS IPA'/)
  assert.match(translations, /'install\.iosDownload': 'Download iOS IPA'/)
})

test('install script uses only iOS release metadata and does not request Android assets', async () => {
  const installScript = await readPublicFile('install.js')

  assert.doesNotMatch(installScript, /android|\bapk\b/i)
  assert.match(installScript, /release\?\.ios\?\.version/)
  assert.match(installScript, /fetch\(`\/api\/releases\/latest\?/)
})

test('release version labels never fall back to aggregate or Android versions', async () => {
  for (const release of [
    { version: 'v9.0.0', android: { version: 'v9.0.0' } },
    { version: 'v9.0.0' },
  ]) {
    assert.deepEqual(await renderReleaseVersions({ success: true, release }), {
      latest: 'unavailable',
      ios: 'unavailable',
    })
  }
})

test('release version labels use the iOS version and treat latest as unavailable', async () => {
  assert.deepEqual(await renderReleaseVersions({
    success: true,
    release: { version: 'v9.0.0', ios: { version: 'v2.3.4' } },
  }), {
    latest: 'version:v2.3.4',
    ios: 'version:v2.3.4',
  })

  assert.deepEqual(await renderReleaseVersions({
    success: true,
    release: { version: 'v9.0.0', ios: { version: 'latest' } },
  }), {
    latest: 'unavailable',
    ios: 'unavailable',
  })
})

test('release version labels are unavailable when release lookup fails', async () => {
  assert.deepEqual(await renderReleaseVersions(null, { fetchError: true }), {
    latest: 'unavailable',
    ios: 'unavailable',
  })
})

test('the single supported installer occupies a centered single-column grid', async () => {
  const css = await readPublicFile('styles.css')
  const grid = css.match(/\.install-grid\s*\{([^}]+)\}/)?.[1]

  assert.ok(grid)
  assert.match(grid, /grid-template-columns:\s*minmax\(0,\s*1fr\)/)
  assert.match(grid, /margin:\s*56px auto 0/)
})

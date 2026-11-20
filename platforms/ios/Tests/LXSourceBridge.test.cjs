// Run on Windows or macOS: node --test platforms/ios/Tests/LXSourceBridge.test.cjs
// Sanitized source only. No personal scripts, credentials, or live audio.
const { test } = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')

const preload = fs.readFileSync(path.join(__dirname, '../Sources/Kumone/LXUserAPIPreload.js'), 'utf8')
const flush = () => new Promise(resolve => setImmediate(resolve))
const id = '003fixtureSongId'

function bridge(script) {
  const calls = []
  const context = vm.createContext({
    console: { log() {} },
    __lx_native_call__: (key, action, data) => {
      assert.equal(key, 'fixture-key')
      calls.push({ action, data: JSON.parse(data) })
    },
    __lx_native_call__set_timeout() {},
    __lx_native_call__utils_str2b64() {},
    __lx_native_call__utils_b642buf() {},
    __lx_native_call__utils_str2md5() {},
    __lx_native_call__utils_aes_encrypt() {},
    __lx_native_call__utils_rsa_encrypt() {},
  })
  vm.runInContext(preload, context)
  context.lx_setup('fixture-key', 'fixture', 'Fixture', '', '1', 'tests', '', script)
  vm.runInContext(script, context)
  return {
    calls,
    dispatch(action, data) { context.__lx_native__('fixture-key', action, JSON.stringify(data)) },
    request(key, action = 'musicUrl', source = 'tx') {
      context.__lx_native__('fixture-key', 'request', JSON.stringify({ requestKey: key, data: {
        source, action, info: { type: '128k', musicInfo: { id, songmid: id } },
      } }))
    },
  }
}

const init = `lx.send(lx.EVENT_NAMES.inited, {sources:{tx:{type:'music',actions:['musicUrl','lyric'],qualitys:['128k']}}})`

test('full source Promise -> lx.request -> native HTTP response -> musicUrl result', async () => {
  const host = bridge(`
    lx.on(lx.EVENT_NAMES.request, async ({source, info}) => {
      if (source !== 'tx' || info.musicInfo.songmid !== '${id}' || info.musicInfo.id !== '${id}') throw new Error('wrong identity')
      return await new Promise((resolve, reject) => {
        lx.request('https://fixture.invalid/resolve', {method:'POST',body:JSON.stringify({id:info.musicInfo.id})}, (error, response, body) => {
          if (error) return reject(error)
          if (response.statusCode !== 200 || body.id !== info.musicInfo.id) return reject(new Error('wrong response'))
          resolve(body.url)
        })
      })
    })
    ${init}
  `)
  host.request('root')
  const child = host.calls.find(call => call.action === 'request').data
  assert.equal(child.parentRequestKey, 'root')
  assert.deepEqual(JSON.parse(child.options.body), { id })
  host.dispatch('response', { requestKey: child.requestKey, response: {
    statusCode: 200, headers: {}, body: { id, url: 'https://fixture.invalid/audio.mp3' },
  } })
  await flush()
  const response = host.calls.find(call => call.action === 'response').data
  assert.equal(response.status, true)
  assert.equal(response.result.source, 'tx')
  assert.equal(response.result.data.url, 'https://fixture.invalid/audio.mp3')
})

test('keep all four supported providers and ignore retired declarations', async () => {
  const supported = ['kw', 'kg', 'tx', 'wy']
  const retired = ['mg', 'sd', 'qs', 'git', 'local']
  const sources = Object.fromEntries([...supported, ...retired].map(source => [source, {
    type: 'music', actions: ['musicUrl'], qualitys: ['128k'],
  }]))
  const host = bridge(`
    lx.on(lx.EVENT_NAMES.request, ({source}) => 'https://fixture.invalid/' + source + '.mp3')
    lx.send(lx.EVENT_NAMES.inited, {sources:${JSON.stringify(sources)}})
  `)
  const initialization = host.calls.find(call => call.action === 'init').data
  assert.deepEqual(Object.keys(initialization.info.sources), supported)
  for (const source of [...supported, ...retired]) host.request(source, 'musicUrl', source)
  await flush()
  const responses = new Map(host.calls.filter(call => call.action === 'response')
    .map(call => [call.data.requestKey, call.data]))
  for (const source of supported) {
    assert.equal(responses.get(source).result.data.url, `https://fixture.invalid/${source}.mp3`)
  }
  for (const source of retired) {
    assert.equal(responses.get(source).status, false)
    assert.match(responses.get(source).errorMessage, /does not declare/)
  }
  assert.equal(host.calls.filter(call => call.action === 'request').length, 0)
})

test('root cancellation aborts child HTTP and suppresses late Promise responses', async () => {
  const host = bridge(`
    lx.on(lx.EVENT_NAMES.request, () => new Promise((resolve, reject) => {
      lx.request('https://fixture.invalid/resolve', {}, (error, response, body) => error ? reject(error) : resolve(body.url))
    }))
    ${init}
  `)
  host.request('cancelled-root')
  const child = host.calls.find(call => call.action === 'request').data
  host.dispatch('cancelRequest', { requestKey: 'cancelled-root' })
  host.dispatch('response', { requestKey: child.requestKey, response: { statusCode: 200, headers: {}, body: { url: 'https://fixture.invalid/stale.mp3' } } })
  await flush()
  assert.ok(host.calls.some(call => call.action === 'cancelRequest' && call.data === child.requestKey))
  assert.equal(host.calls.filter(call => call.action === 'response').length, 0)
  host.request('next-root')
  const next = host.calls.filter(call => call.action === 'request').at(-1).data
  assert.equal(next.parentRequestKey, 'next-root')
  host.dispatch('response', { requestKey: next.requestKey, response: { statusCode: 200, headers: {}, body: { url: 'https://fixture.invalid/next.mp3' } } })
  await flush()
  const responses = host.calls.filter(call => call.action === 'response')
  assert.equal(responses.length, 1)
  assert.equal(responses[0].data.requestKey, 'next-root')
})

for (const [format, payload, expected] of [
  ['string', `'[00:01.000]fixture'`, { lyric: '[00:01.000]fixture' }],
  ['nested LRC', `{lrc:{lyric:'[00:01.000]fixture'}}`, { lyric: '[00:01.000]fixture' }],
  ['YRC only', `{yrc:'[1000,500](1000,500,0)fixture'}`, { lyric: '[1000,500](1000,500,0)fixture', yrc: '[1000,500](1000,500,0)fixture' }],
  ['LRC URL', `{lrcUrl:'https://fixture.invalid/fixture.lrc'}`, { url: 'https://fixture.invalid/fixture.lrc' }],
]) {
  test(`declared lyric action preserves ${format}`, async () => {
    const host = bridge(`lx.on(lx.EVENT_NAMES.request, () => (${payload})); ${init}`)
    host.request('lyric', 'lyric')
    await flush()
    const response = host.calls.find(call => call.action === 'response').data
    assert.equal(response.status, true, response.errorMessage)
    for (const [key, value] of Object.entries(expected)) assert.equal(response.result.data[key], value)
  })
}

test('malformed lyric payload returns an error, not an empty success', async () => {
  const host = bridge(`lx.on(lx.EVENT_NAMES.request, () => ({token:'not a lyric'})); ${init}`)
  host.request('lyric', 'lyric')
  await flush()
  const response = host.calls.find(call => call.action === 'response').data
  assert.equal(response.status, false)
  assert.match(response.errorMessage, /Empty LX lyric response/)
})

test('failed source initialization cannot expose working-looking capabilities', async () => {
  const host = bridge(`
    lx.on(lx.EVENT_NAMES.request, () => 'https://fixture.invalid/audio.mp3')
    lx.send(lx.EVENT_NAMES.inited, {status:false,sources:{tx:{type:'music',actions:['musicUrl'],qualitys:['128k']}}})
  `)
  const initialization = host.calls.find(call => call.action === 'init').data
  assert.equal(initialization.status, false)
  host.request('failed-init')
  await flush()
  assert.equal(host.calls.find(call => call.action === 'response').data.status, false)
})

test('a second failed initialization cannot replay an init event over successful capabilities', async () => {
  const host = bridge(`
    lx.on(lx.EVENT_NAMES.request, () => 'https://fixture.invalid/audio.mp3')
    ${init}
    lx.send(lx.EVENT_NAMES.inited, {status:false,sources:{}}).catch(() => {})
  `)
  await flush()
  const initializations = host.calls.filter(call => call.action === 'init')
  assert.equal(initializations.length, 1)
  assert.equal(initializations[0].data.status, true)
  host.request('still-original-context')
  await flush()
  const result = host.calls.find(call => call.action === 'response').data
  assert.equal(result.status, true)
  assert.equal(result.result.data.url, 'https://fixture.invalid/audio.mp3')
})

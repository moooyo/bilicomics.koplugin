// Remote-only size probe using synthetic content and the official Node oracle.
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const child = require('child_process');
const [nativeRoot, wasmRoot] = process.argv.slice(2).map(value => path.resolve(value));
globalThis.crypto = crypto.webcrypto;
require(path.join(wasmRoot, 'wasm_exec.js'));

(async () => {
  const go = new Go();
  const modulePath = path.join(wasmRoot, 'e461bfa6b471a22c06fc.wasm');
  const instantiated = await WebAssembly.instantiate(fs.readFileSync(modulePath), go.importObject);
  go.run(instantiated.instance);
  const outcomes = [];
  for (const size of [32768, 262144, 1048576, 3145728]) {
    const plain = JSON.stringify({fixture: 'x'.repeat(size)});
    const key = Buffer.from('SNHTCBVDweb215==========');
    const cipher = crypto.createCipheriv('aes-192-cbc', key, key.subarray(0, 16));
    const encoded = Buffer.concat([cipher.update(plain), cipher.final()]).toString('base64');
    const args = ['/twirp/comic.v1.Comic/ComicDetail', encoded, 'SYNTHETIC-BUVID', 'web', '{"comic_id":36215}'];
    const oracle = globalThis.c1_r9k2m7(...args);
    if (oracle.error !== '' || oracle.data !== plain) throw new Error('Official synthetic decode failed');
    const start = performance.now();
    const run = child.spawnSync(path.join(nativeRoot, 'biliwasm'), [modulePath], {
      input: JSON.stringify({function: 'c1_r9k2m7', args}),
      encoding: 'utf8', maxBuffer: 20 * 1024 * 1024, timeout: 30000,
    });
    const elapsed = Math.round(performance.now() - start);
    if (run.error) throw run.error;
    const native = JSON.parse(run.stdout);
    if (!native.ok || native.result.error !== oracle.error || native.result.data !== oracle.data)
      throw new Error('Native mismatch at size ' + size + ': ' + JSON.stringify(native).slice(0, 200));
    outcomes.push({payload_bytes: Buffer.byteLength(plain), native_milliseconds: elapsed, match: true});
  }
  console.log(JSON.stringify(outcomes, null, 2));
  process.exit(0);
})().catch(error => { console.error(error.message); process.exit(1); });

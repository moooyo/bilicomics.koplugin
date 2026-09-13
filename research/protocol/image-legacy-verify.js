'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const crypto = require('crypto');
const zlib = require('zlib');
const researchDir = process.argv[2] || process.cwd();
const outputDir = process.argv[3] || process.cwd();
const subtle = crypto.webcrypto.subtle;
const sandbox = {console, TextDecoder, TextEncoder, Uint8Array, ArrayBuffer, URL, URLSearchParams, Blob, atob, btoa, performance, crypto:crypto.webcrypto, setTimeout, clearTimeout, setInterval, clearInterval};
sandbox.window = sandbox;
sandbox.self = sandbox;
sandbox.globalThis = sandbox;
sandbox.fetch = () => { throw new Error('Network disabled for synthetic image verification'); };
sandbox.alert = () => { throw new Error('Unsupported browser alert'); };
const context = vm.createContext(sandbox);
vm.runInContext('Object.assign(globalThis,{Date,Promise,RegExp,Object,Array,Math,String,Number,JSON,Error,TypeError,parseInt,parseFloat,isNaN,decodeURIComponent,encodeURIComponent})',context);
// A plain browser window preserves standard prototype traversal for the official VM.
vm.runInContext('window = Object.assign({}, globalThis); window.window = window; window.self = window; window.globalThis = window;', context);
const officialWindow = sandbox.window;
const officialHashes = { 'XdNhUHQNH1.js': '8e3b0117f4df4be452c0b6af5b8f0a0acf9d4ade23d08d55d7e312af22077762', 'oAOxa2eJJd.js': '852239b9143e4f56565233f03ef092770691567c63b13814f005d0909263b31b' };
for (const file of ['XdNhUHQNH1.js','oAOxa2eJJd.js']) {
  if (crypto.createHash('sha256').update(fs.readFileSync(path.join(researchDir,file))).digest('hex') !== officialHashes[file]) throw new Error('Official legacy script hash mismatch');
  vm.runInContext(fs.readFileSync(path.join(researchDir,file),'utf8'),context,{timeout:3000,filename:file});
}

(async()=>{
  const fixtures=JSON.parse(fs.readFileSync(path.join(outputDir,'image-legacy-fixtures.json'),'utf8'));
  const results=[];
  for(const fixture of fixtures){
    const body=Buffer.from(fixture.bodyBase64,'base64');
    const length=body.readInt32BE(1);
    if(body[0]!==fixture.version || body.length-(5+length)!==65)throw new Error('Container shape mismatch for '+fixture.id);
    const metadata=await officialWindow.c_f_11(new URL(fixture.url).searchParams.get('cpx'),fixture.version);
    const actual=await officialWindow.c_f_49(fixture.version,new Uint8Array(body.subarray(5,5+length)),new Uint8Array(body.subarray(5+length)),metadata.n,metadata.al,metadata.t,fixture.privateKey,metadata.s);
    const expected=Buffer.from(fixture.expectedBase64,'base64');
    const actualBytes=Buffer.from(actual);
    if(!actualBytes.equals(expected))throw new Error('Byte mismatch for '+fixture.id);
    const result={id:fixture.id,pass:true,bytes:actualBytes.length,sha256:crypto.createHash('sha256').update(actualBytes).digest('hex')};
    results.push(result);
    console.log(JSON.stringify(result));
  }
  fs.writeFileSync(path.join(outputDir,'verify-legacy-fixtures-results.json'),JSON.stringify(results,null,2)+'\n');
  console.log('PASS '+results.length+' persisted official helper fixtures');
})().catch(error=>{console.error(error.message);process.exitCode=1;});


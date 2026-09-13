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
function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let bit=0; bit<8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  return (crc ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const name=Buffer.from(type,'ascii'), prefix=Buffer.alloc(4), suffix=Buffer.alloc(4);
  prefix.writeUInt32BE(data.length); suffix.writeUInt32BE(crc32(Buffer.concat([name,data])));
  return Buffer.concat([prefix,name,data,suffix]);
}
function makePng(width,height) {
  const header=Buffer.alloc(13);
  header.writeUInt32BE(width,0);header.writeUInt32BE(height,4);header[8]=8;header[9]=6;
  const pixels=Buffer.alloc((width*4+1)*height);
  let state=0x71823391;
  for(let row=0;row<height;row++){
    const start=row*(width*4+1);pixels[start]=0;
    for(let col=0;col<width*4;col++){
      state^=state<<13;state^=state>>>17;state^=state<<5;
      pixels[start+col+1]=state&255;
    }
  }
  return Buffer.concat([Buffer.from('89504e470d0a1a0a','hex'),chunk('IHDR',header),chunk('IDAT',zlib.deflateSync(pixels)),chunk('IEND',Buffer.alloc(0))]);
}
async function encryptPayload(version,plain,shared,iv,salt,limit) {
  let name, key, algorithm;
  if(version===5){
    name='AES-GCM';
    const material=await subtle.importKey('raw',shared,'PBKDF2',false,['deriveKey']);
    key=await subtle.deriveKey({name:'PBKDF2',salt,iterations:100000,hash:'SHA-512'},material,{name,length:256},false,['encrypt']);
    algorithm={name,iv,additionalData:salt,tagLength:128};
  } else {
    name=version===6?'AES-CBC':'AES-CTR';
    key=await subtle.importKey('raw',shared,{name},false,['encrypt']);
    algorithm=name==='AES-CBC'?{name,iv}:{name,counter:iv,length:64};
  }
  const encrypted=Buffer.from(await subtle.encrypt(algorithm,key,plain.subarray(0,limit)));
  return {payload:Buffer.concat([encrypted,plain.subarray(limit)]),name};
}
function deadline(promise,milliseconds) {
  let timer;
  return Promise.race([promise,new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error('Official helper deadline')),milliseconds);})]).finally(()=>clearTimeout(timer));
}
async function main(){
  const configs={3:{iv:[25,41],span:25},5:{iv:[32,48],salt:[48,64],span:30},6:{iv:[33,49],span:21},7:{iv:[25,41],span:25}};
  const sizes=[['small',3,2],['large',130,80]];
  const fixtures=[];
  const results=[];
  for(const version of [3,5,6,7]){
    for(const [size,width,height] of sizes){
      const cfg=configs[version];
      const client=await subtle.generateKey({name:'ECDH',namedCurve:'P-256'},true,['deriveKey','deriveBits']);
      const server=await subtle.generateKey({name:'ECDH',namedCurve:'P-256'},true,['deriveKey','deriveBits']);
      const privateJwk=await subtle.exportKey('jwk',client.privateKey);
      const privateKey=Buffer.from(JSON.stringify(privateJwk)).toString('base64');
      const peer=Buffer.from(await subtle.exportKey('raw',server.publicKey));
      const shared=Buffer.from(await subtle.deriveBits({name:'ECDH',public:server.publicKey},client.privateKey,256));
      const expected=makePng(width,height);
      const metadata=crypto.randomBytes(64);
      const iv=metadata.subarray(...cfg.iv);
      const salt=cfg.salt?metadata.subarray(...cfg.salt):undefined;
      const {payload,name}=await encryptPayload(version,expected,shared,iv,salt,cfg.span*1024);
      const length=Buffer.alloc(4);length.writeInt32BE(payload.length);
      const body=Buffer.concat([Buffer.from([version]),length,payload,peer]);
      const url=new URL('https://example.invalid/synthetic-legacy-v'+version+'-'+size+'.png');
      url.searchParams.set('cpx',metadata.toString('base64'));
      url.searchParams.set('ts',Math.floor(Date.now()/1000).toString(16));
      const fixture={id:'legacy-v'+version+'-'+size,synthetic:true,version,privateKey,url:url.toString(),bodyBase64:body.toString('base64'),expectedBase64:expected.toString('base64'),sharedHex:shared.toString('hex'),expectedSha256:crypto.createHash('sha256').update(expected).digest('hex'),plaintextLength:expected.length,payloadLength:payload.length,prefixPlaintextLength:Math.min(expected.length,cfg.span*1024)};
      fixtures.push(fixture);
      try{
        const actual=await deadline(officialWindow.c_f_49(version,new Uint8Array(payload),new Uint8Array(peer),new Uint8Array(iv),name,[0,cfg.span],privateKey,salt?new Uint8Array(salt):undefined),4000);
        const output=Buffer.from(actual);
        if(!output.equals(expected))throw new Error('Official helper output differs: '+output.length+' versus '+expected.length);
        const result={id:fixture.id,pass:true,plaintextLength:expected.length,payloadLength:payload.length,sha256:fixture.expectedSha256};
        results.push(result);console.log(JSON.stringify(result));
      }catch(error){
        const result={id:fixture.id,pass:false,error:error.message};results.push(result);console.log(JSON.stringify(result));
      }
    }
  }
  fs.writeFileSync(path.join(outputDir,'image-legacy-fixtures.pending.json'),JSON.stringify(fixtures,null,2)+'\n');
  fs.writeFileSync(path.join(outputDir,'image-legacy-results.json'),JSON.stringify(results,null,2)+'\n');
  if(results.every(result=>result.pass)){
    fs.renameSync(path.join(outputDir,'image-legacy-fixtures.pending.json'),path.join(outputDir,'image-legacy-fixtures.json'));
    console.log('VERIFIED '+results.length+' official helper round trips');
  }else{
    process.exitCode=1;
  }
}
process.on('unhandledRejection',error=>console.error('Unhandled helper rejection:',error.message));
main().catch(error=>{console.error(error.message);process.exitCode=1;});


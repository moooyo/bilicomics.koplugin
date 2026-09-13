"use strict";

// This reference generator runs only on the authorized remote test host.
const crypto = require("node:crypto");

function sequence(length, seed) {
    return Buffer.from(Array.from({ length }, (_, i) => (i * 29 + seed) & 255));
}

const pbkdf2 = [
    [0, 0, 1, 32], [32, 16, 100000, 32], [129, 257, 17, 80],
    [1024, 1024, 2, 1024], [32, 16, 15625, 1024],
].map(([passlen, saltlen, iterations, outlen], i) => {
    const password = sequence(passlen, i + 1);
    const salt = sequence(saltlen, i + 19);
    const expected = crypto.pbkdf2Sync(password, salt, iterations, outlen, "sha512");
    return { password: password.toString("hex"), salt: salt.toString("hex"),
        iterations, outlen, expected: expected.toString("hex") };
});

const gcm = [
    [16, 1, 0, 0], [24, 12, 1, 1], [32, 16, 16, 92],
    [32, 16, 16, 30720], [32, 128, 1024, 33],
].map(([keylen, ivlen, aadlen, plainlen], i) => {
    const key = sequence(keylen, i + 3);
    const iv = sequence(ivlen, i + 23);
    const aad = sequence(aadlen, i + 47);
    const plain = sequence(plainlen, i + 97);
    const cipher = crypto.createCipheriv(`aes-${keylen * 8}-gcm`, key, iv);
    cipher.setAAD(aad);
    const encrypted = Buffer.concat([cipher.update(plain), cipher.final()]);
    return { key: key.toString("hex"), iv: iv.toString("hex"),
        aad: aad.toString("hex"), cipher: encrypted.toString("hex"),
        tag: cipher.getAuthTag().toString("hex"), plain: plain.toString("hex") };
});

process.stdout.write(JSON.stringify({ pbkdf2, gcm }));

"use strict";

// Incremental SHA-256 from the FIPS 180-4 algorithm. It also works on a LAN
// HTTP origin where SubtleCrypto is unavailable, without buffering whole files.
class LanSha256 {
  constructor() {
    this.h = new Uint32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
    this.block = new Uint8Array(64);
    this.words = new Uint32Array(64);
    this.length = 0;
    this.used = 0;
    this.finished = false;
  }
  update(bytes) {
    if (this.finished) throw new Error("SHA-256 already finalized");
    const data = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
    this.length += data.length;
    let offset = 0;
    while (offset < data.length) {
      if (this.used === 0 && data.length - offset >= 64) {
        this.transform(data, offset);
        offset += 64;
      } else {
        const count = Math.min(64 - this.used, data.length - offset);
        this.block.set(data.subarray(offset, offset + count), this.used);
        this.used += count;
        offset += count;
        if (this.used === 64) { this.transform(this.block, 0); this.used = 0; }
      }
    }
    return this;
  }
  transform(data, offset) {
    const w = this.words, k = LanSha256.k;
    for (let i = 0; i < 16; i++) {
      const p = offset + i * 4;
      w[i] = (data[p] << 24) | (data[p + 1] << 16) | (data[p + 2] << 8) | data[p + 3];
    }
    const rotr = (x, n) => (x >>> n) | (x << (32 - n));
    for (let i = 16; i < 64; i++) {
      const a = w[i - 15], b = w[i - 2];
      const s0 = rotr(a, 7) ^ rotr(a, 18) ^ (a >>> 3);
      const s1 = rotr(b, 17) ^ rotr(b, 19) ^ (b >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }
    let [a, b, c, d, e, f, g, h] = this.h;
    for (let i = 0; i < 64; i++) {
      const s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const choice = (e & f) ^ (~e & g);
      const t1 = (h + s1 + choice + k[i] + w[i]) >>> 0;
      const s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const majority = (a & b) ^ (a & c) ^ (b & c);
      const t2 = (s0 + majority) >>> 0;
      h = g; g = f; f = e; e = (d + t1) >>> 0;
      d = c; c = b; b = a; a = (t1 + t2) >>> 0;
    }
    [a, b, c, d, e, f, g, h].forEach((v, i) => { this.h[i] = (this.h[i] + v) >>> 0; });
  }
  digest() {
    if (this.finished) throw new Error("SHA-256 already finalized");
    this.finished = true;
    this.block[this.used++] = 0x80;
    if (this.used > 56) {
      this.block.fill(0, this.used);
      this.transform(this.block, 0);
      this.used = 0;
    }
    this.block.fill(0, this.used, 56);
    const view = new DataView(this.block.buffer);
    view.setUint32(56, Math.floor(this.length / 0x20000000));
    view.setUint32(60, (this.length * 8) >>> 0);
    this.transform(this.block, 0);
    return Array.from(this.h, x => x.toString(16).padStart(8, "0")).join("");
  }
}
LanSha256.k = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);
globalThis.LanSha256 = LanSha256;

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const script = fs.readFileSync(path.join(__dirname, '../../assets/lan/sha256.js'), 'utf8');
const context = vm.createContext({ Uint8Array, Uint32Array, DataView, Array, Error });
vm.runInContext(script, context);

test('LAN HTTP incremental SHA-256 matches padding and chunk boundaries', () => {
  for (const length of [0, 1, 55, 56, 63, 64, 65, 1000, 2097152, 2097159]) {
    const bytes = Buffer.alloc(length);
    for (let i = 0; i < length; i++) bytes[i] = (i * 31) % 251;
    const expected = crypto.createHash('sha256').update(bytes).digest('hex');
    for (const chunk of [1, 17, 64, 1011, 2097152]) {
      const digest = new context.LanSha256();
      for (let start = 0; start < bytes.length; start += chunk) {
        digest.update(bytes.subarray(start, start + chunk));
      }
      assert.equal(digest.digest(), expected, `length=${length}, chunk=${chunk}`);
    }
  }
});

test('LAN SHA-256 interoperates for Unicode text and rejects reuse after digest', () => {
  const bytes = Buffer.from('局域网互传 📱 & 文件\n');
  const hash = new context.LanSha256().update(bytes);
  assert.equal(hash.digest(), crypto.createHash('sha256').update(bytes).digest('hex'));
  assert.throws(() => hash.update(bytes));
  assert.throws(() => hash.digest());
});

/**
 * Offline waiter-PIN tests.
 *
 * The whole feature rests on one guarantee: a PIN hashed on the Station must
 * verify on the server, and one hashed on the server must verify on the Station.
 * If those ever drift, a PIN set during an outage silently stops working the
 * moment the internet returns — the worst possible failure mode.
 *
 * So we don't test copies of the hashing code: we extract the REAL functions out
 * of the shipped sources (main.js, setWaiterPin.js, redeemWaiterToken.js) and
 * cross-verify them against each other.
 *
 * Run: node test-pin.js
 */

const fs     = require('fs');
const path   = require('path');
const crypto = require('crypto');
const { scryptSync, randomBytes, timingSafeEqual } = crypto;

const APP_FN = 'C:/Users/arcel/Desktop/LightMenuApp/app/server/functions/';

// Pull `function NAME(...) { ... }` out of a source file by brace matching.
function extractFn(src, name) {
  const start = src.indexOf('function ' + name + '(');
  if (start < 0) throw new Error('function not found: ' + name);
  let depth = 0;
  for (let j = src.indexOf('{', start); j < src.length; j++) {
    if (src[j] === '{') depth++;
    else if (src[j] === '}' && --depth === 0) return src.slice(start, j + 1);
  }
  throw new Error('unbalanced braces: ' + name);
}

// Compile an extracted function, supplying the crypto names each file expects
// (the Station calls crypto.*, the server files use bare imported names).
function load(src, name) {
  return new Function(
    'crypto', 'scryptSync', 'randomBytes', 'timingSafeEqual',
    extractFn(src, name) + '; return ' + name + ';'
  )(crypto, scryptSync, randomBytes, timingSafeEqual);
}

const stationSrc = fs.readFileSync(path.join(__dirname, 'main.js'), 'utf8');
const setSrc     = fs.readFileSync(APP_FN + 'setWaiterPin.js', 'utf8');
const redeemSrc  = fs.readFileSync(APP_FN + 'redeemWaiterToken.js', 'utf8');

const stationHash   = load(stationSrc, 'hashPin');
const stationVerify = load(stationSrc, 'verifyPinHash');
const serverHash    = load(setSrc,     'hashPin');
const serverVerify  = load(redeemSrc,  'verifyPin');

let pass = 0, fail = 0;
function ok(cond, label) {
  if (cond) { pass++; console.log('  ✓ ' + label); }
  else      { fail++; console.log('  ✗ ' + label); }
}

console.log('1. Cross-compatibility (the core guarantee):');
// A manager sets 4821 on the Station during an outage. It syncs up. The waiter
// later logs in online — the server must accept it.
ok(serverVerify('4821', stationHash('4821')) === true,
   'server accepts a PIN hashed by the Station');
// A 6-digit PIN emailed by the web app, cached locally, checked on the LAN.
ok(stationVerify('063194', serverHash('063194')) === true,
   'Station accepts a PIN hashed by the server');

console.log('2. Wrong PINs are rejected in both directions:');
ok(serverVerify('4822', stationHash('4821')) === false, 'server rejects a wrong PIN');
ok(stationVerify('000000', serverHash('063194')) === false, 'Station rejects a wrong PIN');
ok(stationVerify('4821', null) === false, 'Station rejects a missing hash');
ok(stationVerify('4821', 'garbage-no-colon') === false, 'Station rejects a malformed hash');

console.log('3. Hash format matches the server allowlist regex:');
// server/index.js staff.set_pin refuses anything that isn't 16-byte salt + 32-byte key.
const ALLOWLIST = /^[0-9a-f]{32}:[0-9a-f]{64}$/i;
ok(ALLOWLIST.test(stationHash('4821')), 'Station hash passes staff.set_pin validation');
ok(ALLOWLIST.test(serverHash('063194')), 'server hash passes the same validation');
ok(!ALLOWLIST.test('4821'), 'a plaintext PIN is rejected by that validation');

console.log('4. Salt is random (same PIN never yields the same hash):');
ok(stationHash('4821') !== stationHash('4821'), 'two hashes of one PIN differ');

console.log('5. Every accepted PIN length round-trips:');
for (const p of ['1234', '12345', '123456']) {
  ok(serverVerify(p, stationHash(p)) === true, `${p.length}-digit PIN round-trips`);
}

console.log('6. Local lockout mirrors the server (5 tries, 15 min):');
// store writes next to this file; use a scratch token and clean up after.
const PINS_FILE = path.join(__dirname, 'pins.local.json');
const hadPins = fs.existsSync(PINS_FILE);
const backup  = hadPins ? fs.readFileSync(PINS_FILE, 'utf8') : null;
try {
  const store = require('./store.js');
  const TOKEN = '__test_token__';
  store.setPin({ staff_id: '__test_staff__', token: TOKEN, pin_hash: stationHash('4821'), synced: false });

  ok(store.getUnsyncedPins().some(p => p.token === TOKEN), 'offline-set PIN is queued for sync');

  let st;
  for (let i = 0; i < 4; i++) st = store.recordPinFailure(null, TOKEN);
  ok(st.locked === false, 'not locked after 4 failures');
  ok(st.attempts_left === 1, 'reports 1 attempt left');

  st = store.recordPinFailure(null, TOKEN);
  ok(st.locked === true, 'locked on the 5th failure');
  ok(store.pinLockMinutes(store.getPin(null, TOKEN)) > 0, 'lockout has minutes remaining');

  store.clearPinFailures(null, TOKEN);
  ok(store.pinLockMinutes(store.getPin(null, TOKEN)) === 0, 'a correct PIN clears the lockout');

  store.markPinSynced('__test_staff__', TOKEN);
  ok(!store.getUnsyncedPins().some(p => p.token === TOKEN), 'sync clears the pending flag');

  store.clearPin('__test_staff__', TOKEN);
  ok(store.getPin(null, TOKEN) === null, 'clearPin removes the record');
} finally {
  if (backup !== null) fs.writeFileSync(PINS_FILE, backup);
  else if (fs.existsSync(PINS_FILE)) fs.unlinkSync(PINS_FILE);
}

console.log('\n' + (fail === 0
  ? '✅ ALL ' + pass + ' PIN CHECKS PASSED'
  : '❌ ' + fail + ' FAILED, ' + pass + ' passed'));
process.exit(fail === 0 ? 0 : 1);

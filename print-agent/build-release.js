/**
 * LightMenu Print Agent — Release Builder
 * ----------------------------------------
 * Obfuscates the source JS into print-agent/dist/ and rewrites version.json so
 * the auto-updater pulls the PROTECTED build, not the readable source.
 *
 * Why this exists: updater.js re-downloads any tracked file whose sha256 differs
 * from version.json on every boot. If version.json pointed at the plaintext
 * source, the updater would overwrite an installed obfuscated copy with plaintext.
 * So we publish the obfuscated artifact to dist/ and point version.json there.
 *
 * Hashing note: the repo's .gitattributes forces `*.js text eol=lf`, so GitHub
 * serves LF. The updater hashes the raw downloaded bytes, so we hash the
 * LF-normalized content here to match what will be served.
 *
 * Run via build-release.bat (double-click). Needs javascript-obfuscator on PATH.
 */
const fs     = require('fs');
const path   = require('path');
const crypto = require('crypto');
const { execSync } = require('child_process');

const ROOT = __dirname;                       // print-agent/
const DIST = path.join(ROOT, 'dist');
const VPATH = path.join(ROOT, 'version.json');
const RAW_BASE = 'https://raw.githubusercontent.com/arcelen/lightmenu-releases/main/print-agent/dist/';
const OBF_FILES = ['main.js', 'store.js', 'qrcode.js'];

function sha256LF(buf) {
    const lf = buf.toString('utf8').replace(/\r\n/g, '\n');
    return crypto.createHash('sha256').update(Buffer.from(lf, 'utf8')).digest('hex');
}

fs.mkdirSync(DIST, { recursive: true });

console.log('Obfuscating source -> dist/ ...');
for (const f of OBF_FILES) {
    const src = path.join(ROOT, f);
    const out = path.join(DIST, f);
    if (!fs.existsSync(src)) { console.error('  MISSING source: ' + f); process.exit(1); }
    execSync(
        `javascript-obfuscator "${src}" --output "${out}" ` +
        `--compact true --string-array true --string-array-encoding base64 --string-array-threshold 1 ` +
        `--split-strings true --split-strings-chunk-length 10 --unicode-escape-sequence true ` +
        `--control-flow-flattening true --control-flow-flattening-threshold 0.75 ` +
        `--dead-code-injection true --dead-code-injection-threshold 0.4 ` +
        `--identifier-names-generator hexadecimal --rename-globals false --self-defending true`,
        { stdio: 'inherit' }
    );
}

console.log('Rehashing version.json (LF-normalized) ...');
const v = JSON.parse(fs.readFileSync(VPATH, 'utf8'));
for (const f of OBF_FILES) {
    const buf = fs.readFileSync(path.join(DIST, f));
    const h = sha256LF(buf);
    if (!v.files[f]) v.files[f] = {};
    v.files[f].sha256 = h;
    v.files[f].url = RAW_BASE + f;
    console.log('  ' + f + '  ' + h);
}
fs.writeFileSync(VPATH, JSON.stringify(v, null, 2) + '\n');
console.log('Done. version.json now publishes obfuscated dist/ for v' + v.version + '.');

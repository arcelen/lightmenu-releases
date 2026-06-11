/**
 * LightMenu Print Agent — Auto-Updater
 * --------------------------------------
 * Runs on every agent start, before main.js.
 *
 * Pulls https://raw.githubusercontent.com/arcelen/lightmenu-releases/main/print-agent/version.json
 * If any tracked file (main.js, qrcode.js) has a different SHA-256 than the local
 * copy, downloads the new one to a .tmp file, verifies its hash, then atomically
 * replaces the local file.
 *
 * Failure modes: if the remote is unreachable, nothing changes — the agent boots
 * with whatever local files it has. The user is never blocked by an update.
 *
 * The local version.json acts as the install's own state. It is overwritten only
 * after every tracked file has been verified to match the remote's hashes.
 */

const fs    = require('fs');
const path  = require('path');
const https = require('https');
const crypto = require('crypto');

const APP_DIR        = path.resolve(__dirname, '..', 'app');
const LOCAL_VERSION  = path.join(APP_DIR, 'version.json');
const REMOTE_VERSION = 'https://raw.githubusercontent.com/arcelen/lightmenu-releases/main/print-agent/version.json';
const TIMEOUT_MS     = 10000;

// Fetch a URL and resolve with the raw body buffer.
function fetchBuffer(url) {
    return new Promise((resolve, reject) => {
        const req = https.get(url, {
            headers: { 'User-Agent': 'LightMenu-PrintAgent-Updater' },
            timeout: TIMEOUT_MS,
        }, (res) => {
            // Follow one redirect (GitHub raw sometimes redirects)
            if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
                return fetchBuffer(res.headers.location).then(resolve, reject);
            }
            if (res.statusCode !== 200) {
                return reject(new Error(`HTTP ${res.statusCode} for ${url}`));
            }
            const chunks = [];
            res.on('data', (c) => chunks.push(c));
            res.on('end', () => resolve(Buffer.concat(chunks)));
            res.on('error', reject);
        });
        req.on('timeout', () => req.destroy(new Error('timeout')));
        req.on('error', reject);
    });
}

// SHA-256 of a buffer in hex.
function sha256(buf) {
    return crypto.createHash('sha256').update(buf).digest('hex');
}

// Returns true if semver string a is strictly greater than b (e.g. '6.0.9' > '6.0.8').
function semverGt(a, b) {
    const pa = String(a).split('.').map(Number);
    const pb = String(b).split('.').map(Number);
    for (let i = 0; i < 3; i++) {
        const va = pa[i] || 0, vb = pb[i] || 0;
        if (va > vb) return true;
        if (va < vb) return false;
    }
    return false;
}

// SHA-256 of a file on disk (returns empty string if missing).
function sha256File(p) {
    try {
        const data = fs.readFileSync(p);
        return sha256(data);
    } catch {
        return '';
    }
}

async function main() {
    let localManifest = { version: '0.0.0', files: {} };
    try {
        localManifest = JSON.parse(fs.readFileSync(LOCAL_VERSION, 'utf8'));
    } catch {
        // No local manifest yet — first run. Treat everything as new.
    }

    let remoteManifest;
    try {
        const body = await fetchBuffer(REMOTE_VERSION);
        remoteManifest = JSON.parse(body.toString('utf8'));
    } catch (err) {
        console.log(`[updater] Skip: cannot reach update server (${err.message})`);
        return;
    }

    if (!remoteManifest?.files) {
        console.log('[updater] Skip: malformed remote manifest.');
        return;
    }

    const versionMatch = remoteManifest.version === localManifest.version;
    if (versionMatch) {
        // Still verify every tracked file hash — a previous partial update or
        // manual edit may have left a file out of sync despite a matching version.
        const allHashesMatch = Object.entries(remoteManifest.files).every(([filename, meta]) => {
            return sha256File(path.join(APP_DIR, filename)) === meta.sha256;
        });
        if (allHashesMatch) {
            console.log(`[updater] Up to date (v${localManifest.version}).`);
            return;
        }
        console.log(`[updater] Version matches but file hashes differ — repairing files...`);
    } else if (!semverGt(remoteManifest.version, localManifest.version)) {
        // Remote is the same version or older (CDN lag / rollback). Never downgrade.
        console.log(`[updater] Remote v${remoteManifest.version} <= local v${localManifest.version} — skipping (CDN may be stale).`);
        return;
    } else {
        console.log(`[updater] Local v${localManifest.version} -> remote v${remoteManifest.version}`);
    }

    // Walk each remote file, download if hash differs from local.
    let allOk = true;
    for (const [filename, meta] of Object.entries(remoteManifest.files)) {
        const localPath = path.join(APP_DIR, filename);
        const localHash = sha256File(localPath);
        if (localHash === meta.sha256) {
            console.log(`[updater]   ${filename}: already current.`);
            continue;
        }
        console.log(`[updater]   ${filename}: downloading...`);
        try {
            const buf = await fetchBuffer(meta.url);
            const got = sha256(buf);
            if (got !== meta.sha256) {
                console.log(`[updater]   ${filename}: hash mismatch (got ${got.slice(0,8)}, want ${meta.sha256.slice(0,8)}). Skipped.`);
                allOk = false;
                continue;
            }
            const tmp = localPath + '.tmp';
            fs.writeFileSync(tmp, buf);
            // Atomic replace
            fs.renameSync(tmp, localPath);
            console.log(`[updater]   ${filename}: updated.`);
        } catch (err) {
            console.log(`[updater]   ${filename}: download failed (${err.message}).`);
            allOk = false;
        }
    }

    // Only update the local manifest if every file made it through.
    if (allOk) {
        fs.writeFileSync(LOCAL_VERSION, JSON.stringify(remoteManifest, null, 2));
        console.log(`[updater] Now on v${remoteManifest.version}.`);
    } else {
        console.log('[updater] One or more files failed — keeping previous version manifest.');
    }
}

main().catch((e) => {
    console.log(`[updater] Fatal: ${e.message}`);
});

const net   = require('net');
const http  = require('http');
const https = require('https');
const fs    = require('fs');
const path  = require('path');
const os    = require('os');
const crypto = require('crypto');
const { exec, execSync } = require('child_process');

// ─── AGENT VERSION ─────────────────────────────────────────────────────────
// Read from the local version.json so /status reports whatever the updater has
// last installed — no need to bump a hard-coded string in main.js when we ship
// a new build.
const AGENT_VERSION = (() => {
    try {
        const m = JSON.parse(fs.readFileSync(path.join(__dirname, 'version.json'), 'utf8'));
        return m?.version || '6.0.0';
    } catch {
        return '6.0.0';
    }
})();

// --- PRE-CONFIGURED PER RESTAURANT --------------------------------------------
// These placeholders are replaced automatically when you download the
// Print Agent from your LightMenu Printer Setup page.
// Credentials live in config.json — never overwritten by auto-updates.
// Falls back to legacy hardcoded values for agents installed before this change.
// --- Machine-bound credential storage --------------------------------------
// The token is the only secret worth stealing, so we bind it to THIS machine.
// On first boot we read the plaintext config.json, encrypt it (AES-256-GCM with
// a key derived from the Windows MachineGuid) to config.enc, then shred the
// plaintext. A config.enc copied to any other machine fails to decrypt -> the
// agent refuses to start. config.enc is intentionally NOT in version.json, so
// the auto-updater never touches it.
const _CFG_PLAIN = path.join(__dirname, 'config.json');
const _CFG_ENC   = path.join(__dirname, 'config.enc');

// Read the Windows MachineGuid (stable per-install, unique per machine, present
// on every Windows since XP, locale-independent). This is the binding anchor.
function _machineGuid() {
    try {
        const out = execSync(
            'reg query "HKLM\\SOFTWARE\\Microsoft\\Cryptography" /v MachineGuid',
            { windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'] }
        ).toString();
        const m = out.match(/MachineGuid\s+REG_SZ\s+([0-9a-fA-F-]+)/);
        if (m) return m[1].trim().toLowerCase();
    } catch {}
    return '';
}

// 32-byte key from the machine identity. Returns null if no machine anchor is
// available (then we fall back to plaintext rather than lock the user out).
function _machineKey() {
    const guid = _machineGuid();
    if (!guid) return null;
    return crypto.scryptSync(guid, 'lightmenu-station-cfg-v1', 32);
}

function _encryptCfg(obj, key) {
    const iv  = crypto.randomBytes(12);
    const c   = crypto.createCipheriv('aes-256-gcm', key, iv);
    const enc = Buffer.concat([c.update(JSON.stringify(obj), 'utf8'), c.final()]);
    const tag = c.getAuthTag();
    // Format: magic(4) | iv(12) | tag(16) | ciphertext
    return Buffer.concat([Buffer.from('LMC1'), iv, tag, enc]);
}

function _decryptCfg(buf, key) {
    if (buf.length < 32 || buf.slice(0, 4).toString() !== 'LMC1') throw new Error('bad blob');
    const iv  = buf.slice(4, 16);
    const tag = buf.slice(16, 32);
    const enc = buf.slice(32);
    const d   = crypto.createDecipheriv('aes-256-gcm', key, iv);
    d.setAuthTag(tag);
    const dec = Buffer.concat([d.update(enc), d.final()]);
    return JSON.parse(dec.toString('utf8'));
}

const _cfg = (() => {
    const key = _machineKey();

    // 1) Sealed config present -> decrypt with this machine's key.
    if (fs.existsSync(_CFG_ENC)) {
        if (key) {
            try {
                return _decryptCfg(fs.readFileSync(_CFG_ENC), key);
            } catch {
                // Won't decrypt here. If there's ALSO a plaintext config, this is a
                // legit re-provision -> fall through and re-seal. Otherwise this is
                // a config.enc copied from another machine -> refuse to run.
                if (!fs.existsSync(_CFG_PLAIN)) {
                    console.error('[security] config.enc cannot be decrypted on this machine. ' +
                                  'This install appears to have been copied from another computer. Refusing to start.');
                    process.exit(1);
                }
            }
        } else if (!fs.existsSync(_CFG_PLAIN)) {
            // No machine anchor and no plaintext to fall back on.
            console.error('[security] cannot read machine identity to unseal config. Refusing to start.');
            process.exit(1);
        }
    }

    // 2) No (usable) sealed config -> read plaintext and, if possible, seal it.
    let cfg = {};
    try { cfg = JSON.parse(fs.readFileSync(_CFG_PLAIN, 'utf8')); }
    catch { return {}; }

    if (key && cfg && cfg.api_token) {
        try {
            const blob = _encryptCfg(cfg, key);
            fs.writeFileSync(_CFG_ENC, blob);
            // Verify the seal round-trips before destroying the plaintext.
            const check = _decryptCfg(fs.readFileSync(_CFG_ENC), key);
            if (check.api_token === cfg.api_token) {
                try { fs.writeFileSync(_CFG_PLAIN, crypto.randomBytes(512)); } catch {}
                try { fs.unlinkSync(_CFG_PLAIN); } catch {}
                console.log('[security] credentials sealed to this machine.');
            }
        } catch (e) {
            // Sealing failed (e.g. read-only dir) — keep running on plaintext.
            console.log('[security] could not seal config (' + e.message + '); continuing.');
        }
    }
    return cfg;
})();
const RESTAURANT_ID   = _cfg.restaurant_id   || '__RESTAURANT_ID__';
const API_TOKEN       = _cfg.api_token       || '__API_TOKEN__';
let   RESTAURANT_NAME = _cfg.restaurant_name || '';

// Machine fingerprint sent to the server kill switch (sha256 of the MachineGuid,
// never the raw guid). Falls back to the hostname if the guid can't be read.
const MACHINE_HASH = crypto.createHash('sha256')
    .update(_machineGuid() || ('host:' + os.hostname())).digest('hex');
// Server-controlled kill switch. Defaults OPEN so a server/network outage never
// stops printing; only an explicit { ok:false } from the server flips it off.
let STATION_ALLOWED = true;

// LightMenu Supabase endpoint - do not change
const SUPABASE_URL     = 'https://xakaknyanjzabxqmcipz.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhha2Frbnlhbmp6YWJ4cW1jaXB6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzcxOTc2MjUsImV4cCI6MjA5Mjc3MzYyNX0.NqGyREZO2o_-ZUvIltQCTZ6zJAO7ARGa45cDU9OX7G4';

const SERVER_PORT = 3000;

// Default printer - overridden by the first active PrinterConfig from LightMenu
let PRINTER_IP   = ''; // set automatically by network scan
let PRINTER_PORT = 9100;

// --- PRINTER CACHE (refreshed every 30s from LightMenu) -----------------------
let printersCache = [];

// --- USB PRINTING ------------------------------------------------------
// Strategy 1 (preferred, NO driver needed):
//   Write directly to \\.\USB001 … \\.\USB009 via FileStream.
//   Works as long as Windows' built-in usbprint.sys class driver loaded —
//   that happens automatically the first time any USB printer is plugged in.
// Strategy 2 (fallback):
//   Install a “LightMenu USB” Windows printer using Generic/Text-Only driver
//   (bundled with every Windows 10/11), then send bytes via the spooler API.

const LM_WIN_PRINTER = 'LightMenu USB';
let usbDirectPort  = null;  // '\\.\USB001' etc  — strategy 1 (no driver)
let usbWinPrinter  = null;  // 'LightMenu USB'   — strategy 2 (spooler)

// Write lines to a temp .ps1 file, run it, return stdout (trimmed)
function psRun(lines) {
  return new Promise(resolve => {
    const tmp = path.join(os.tmpdir(), 'lm_ps_' + Date.now() + '.ps1');
    fs.writeFileSync(tmp, lines.join('\r\n'), 'utf8');
    exec(`powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "${tmp}"`,
      { timeout: 15000 },
      (err, out) => {
        try { fs.unlinkSync(tmp); } catch {}
        resolve((out || '').trim());
      }
    );
  });
}

async function scanUsb() {
  const r = await psRun([
    // ── Strategy 1: direct write to \\.\USBxxx (no driver needed) ─────────────
    // usbprint.sys (built-in Windows class driver) makes \\.\USB001…009 writable
    // the first time any USB printer is plugged in — no manufacturer driver
    // needed. Windows names these zero-padded (USB001), so probe BOTH the padded
    // and unpadded forms — the old code only tried \\.\USB1 and always missed.
    `$direct = $null`,
    `$cands = @()`,
    `for ($i = 1; $i -le 9; $i++) { $cands += ('\\\\.\\USB00' + $i); $cands += ('\\\\.\\USB' + $i) }`,
    `foreach ($p in $cands) {`,
    `  try {`,
    `    $s = [System.IO.File]::Open($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)`,
    `    $s.Close()`,
    `    $direct = $p`,
    `    break`,
    `  } catch {}`,
    `}`,
    `if ($direct) { Write-Output ('DIRECT:' + $direct); exit }`,

    // ── Strategy 2: our own "LightMenu USB" printer if we created it before ────
    // Only use it when Windows reports PrinterStatus = 3 (Normal/online).
    // Status 4 = Offline means the USB cable is removed — the spooler entry
    // stays registered in Windows permanently but the printer is physically gone.
    `$n = '${LM_WIN_PRINTER}'`,
    `$sp = Get-Printer -Name $n -ErrorAction SilentlyContinue`,
    `if ($sp -and $sp.PrinterStatus -eq 3) { Write-Output 'SPOOLER:READY'; exit }`,

    // ── Strategy 3: ANY printer already installed on a USB port ───────────────
    // Same status check: only pick it up when it is physically connected (status 3).
    `$ex = Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.PortName -match 'USB' -and $_.Name -ne $n -and $_.Name -notmatch 'PDF|XPS|OneNote|Fax|Microsoft' -and $_.PrinterStatus -eq 3 } | Select-Object -First 1`,
    `if ($ex) { Write-Output ('SPOOLER:EXISTING:' + $ex.Name); exit }`,

    // ── Strategy 4: create our own on a USBxxx port (Generic/Text-Only) ───────
    `try { pnputil /scan-devices 2>$null | Out-Null } catch {}`,
    `Start-Sleep -Milliseconds 1500`,
    `$port = Get-PrinterPort | Where-Object { $_.Name -match '^USB\\d+' } | Select-Object -First 1`,
    `if (-not $port) { Write-Output 'NO_PORT'; exit }`,
    `$drv = Get-PrinterDriver -Name 'Generic / Text Only' -ErrorAction SilentlyContinue`,
    `if (-not $drv) { try { Add-PrinterDriver -Name 'Generic / Text Only' -ErrorAction Stop } catch {}; $drv = Get-PrinterDriver -Name 'Generic / Text Only' -ErrorAction SilentlyContinue }`,
    `if (-not $drv) { $drv = Get-PrinterDriver | Where-Object { $_.Name -match 'Generic|Text Only|ESC|Receipt|POS' } | Select-Object -First 1 }`,
    `if (-not $drv) { Write-Output 'NO_DRIVER'; exit }`,
    `try { Add-Printer -Name $n -DriverName $drv.Name -PortName $port.Name -ErrorAction Stop; Write-Output ('SPOOLER:ADDED:' + $port.Name) }`,
    `catch { Write-Output ('FAIL:' + $_.Exception.Message) }`,
  ]);

  if (r.startsWith('DIRECT:')) {
    const port = r.slice(7); // '\\.\USB001' etc.
    if (usbDirectPort !== port) {
      log('USB direct port ready: ' + port + ' (no driver needed)');
      usbDirectPort = port;
      try { track('usb_connected', { port, strategy: 'direct' }); } catch {}
      // Register physical printer by hardware fingerprint so the same device
      // stays on the same DB row across USB↔ETH transport switches.
      registerUsbFingerprints().catch(() => {});
    }
    usbWinPrinter = null; // prefer direct over spooler
  } else if (r === 'SPOOLER:READY' || r.startsWith('SPOOLER:ADDED') || r.startsWith('SPOOLER:EXISTING:')) {
    // Resolve which Windows printer name to spool to: an existing vendor
    // printer (Strategy 3) keeps its own name; ours uses LM_WIN_PRINTER.
    const name = r.startsWith('SPOOLER:EXISTING:') ? r.slice('SPOOLER:EXISTING:'.length) : LM_WIN_PRINTER;
    // When an ETH printer IP is already configured, ignore the Windows spooler
    // entirely. The spooler entry (e.g. "LightMenu USB") stays installed in
    // Windows permanently — even after the cable is removed — and would shadow
    // the ETH printer if we let usbWinPrinter be set. The direct-write path
    // (DIRECT: above) is safe to keep because it opens the actual USB device
    // file, which fails instantly when the device is physically absent.
    if (PRINTER_IP) {
      if (usbWinPrinter) { log('USB spooler ignored (ETH active at ' + PRINTER_IP + ')'); usbWinPrinter = null; }
      usbDirectPort = null;
      return;
    }
    if (usbWinPrinter !== name) {
      log('USB printer ready via spooler: ' + name);
      usbWinPrinter = name;
      try { track('usb_connected', { name, strategy: r.startsWith('SPOOLER:EXISTING:') ? 'spooler-existing' : 'spooler' }); } catch {}
      registerUsbFingerprints().catch(() => {});
    }
    usbDirectPort = null;
  } else {
    const wasConnected = usbDirectPort || usbWinPrinter;
    if (wasConnected) {
      log('USB lost - falling back to network (' + r + ')');
      try { track('usb_lost', { last_port: usbDirectPort || usbWinPrinter, reason: r }); } catch {}
    }
    else if (r && r !== 'NO_PORT') log('USB scan: ' + r);
    usbDirectPort = null;
    usbWinPrinter = null;
  }
}

setTimeout(scanUsb, 2000);
setInterval(scanUsb, 30000);

function supabaseGet(table, query, limit) {
  return new Promise((resolve, reject) => {
    const qs = Object.entries(query).map(([k, v]) => k + '=eq.' + encodeURIComponent(v)).join('&');
    const url = SUPABASE_URL + '/rest/v1/' + table + '?' + qs + '&limit=' + (limit || 20);
    const req = https.request(url, {
      method: 'GET',
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer ' + SUPABASE_ANON_KEY,
        'Content-Type': 'application/json',
      }
    }, (res) => {
      let body = '';
      res.on('data', c => body += c);
      res.on('end', () => {
        try { resolve(JSON.parse(body)); }
        catch (e) { reject(e); }
      });
    });
    req.on('error', reject);
    req.end();
  });
}

// Like supabaseGet but takes a fully-formed PostgREST query string (so callers
// can use in.()/not.in.() filters the eq-only helper can't express). Read-only.
function supabaseGetRaw(pathWithQuery) {
  return new Promise((resolve, reject) => {
    const url = SUPABASE_URL + '/rest/v1/' + pathWithQuery;
    const req = https.request(url, {
      method: 'GET',
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer ' + SUPABASE_ANON_KEY,
        'Content-Type': 'application/json',
      }
    }, (res) => {
      let body = '';
      res.on('data', c => body += c);
      res.on('end', () => {
        try { resolve(JSON.parse(body)); }
        catch (e) { reject(e); }
      });
    });
    req.on('error', reject);
    req.end();
  });
}

function supabasePatch(table, id, patch) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify(patch);
    const url = SUPABASE_URL + '/rest/v1/' + table + '?id=eq.' + encodeURIComponent(id);
    const req = https.request(url, {
      method: 'PATCH',
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer ' + SUPABASE_ANON_KEY,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
        'Prefer': 'return=minimal',
      }
    }, (res) => {
      res.resume();
      res.on('end', resolve);
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

function supabaseDelete(table, query) {
  return new Promise((resolve, reject) => {
    const qs = Object.entries(query).map(([k, v]) => k + '=eq.' + encodeURIComponent(v)).join('&');
    const url = SUPABASE_URL + '/rest/v1/' + table + '?' + qs;
    const req = https.request(url, {
      method: 'DELETE',
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer ' + SUPABASE_ANON_KEY,
        'Prefer': 'return=minimal',
      }
    }, (res) => {
      res.resume();
      res.on('end', () => {
        if (res.statusCode < 200 || res.statusCode >= 300) reject(new Error('HTTP ' + res.statusCode));
        else resolve(true);
      });
    });
    req.on('error', reject);
    req.end();
  });
}

function genWaiterToken() {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  let t = '';
  for (let i = 0; i < 32; i++) t += chars.charAt(Math.floor(Math.random() * chars.length));
  return t;
}

function supabaseRpc(funcName, params) {
  return new Promise((resolve, reject) => {
    const bodyStr = JSON.stringify(params);
    const url = SUPABASE_URL + '/rest/v1/rpc/' + funcName;
    const req = https.request(url, {
      method: 'POST',
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer ' + SUPABASE_ANON_KEY,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(bodyStr),
      }
    }, (res) => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => {
        if (res.statusCode < 200 || res.statusCode >= 300) {
          reject(new Error('HTTP ' + res.statusCode + ': ' + data));
        } else {
          try { resolve(JSON.parse(data)); } catch { resolve(null); }
        }
      });
    });
    req.on('error', reject);
    req.write(bodyStr);
    req.end();
  });
}

function supabasePost(table, body) {
  return new Promise((resolve, reject) => {
    const bodyStr = JSON.stringify(body);
    const url = SUPABASE_URL + '/rest/v1/' + table;
    const req = https.request(url, {
      method: 'POST',
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer ' + SUPABASE_ANON_KEY,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(bodyStr),
        'Prefer': 'return=representation',
      }
    }, (res) => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => {
        if (res.statusCode < 200 || res.statusCode >= 300) {
          reject(new Error('HTTP ' + res.statusCode + ': ' + data));
        } else {
          try { resolve(JSON.parse(data)); } catch { resolve(null); }
        }
      });
    });
    req.on('error', reject);
    req.write(bodyStr);
    req.end();
  });
}

// ─── SUPABASE RPC ─────────────────────────────────────────────────────────────
// Calls a SECURITY DEFINER Postgres function. Used for slug routing,
// fingerprint upsert, and honest print-outcome logging — all defined in
// migration 0006_printer_identity.sql. RPC fails silently to a soft null
// so legacy deployments without the migration applied keep working.
function supabaseRpc(fnName, args) {
  return new Promise((resolve) => {
    const bodyStr = JSON.stringify(args || {});
    const url = SUPABASE_URL + '/rest/v1/rpc/' + fnName;
    const req = https.request(url, {
      method: 'POST',
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer ' + SUPABASE_ANON_KEY,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(bodyStr),
      }
    }, (res) => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => {
        if (res.statusCode < 200 || res.statusCode >= 300) {
          resolve(null); // RPC not deployed yet — caller falls back to legacy path
        } else {
          try { resolve(JSON.parse(data)); } catch { resolve(null); }
        }
      });
    });
    req.on('error', () => resolve(null));
    req.write(bodyStr);
    req.end();
  });
}

// ─── PRINTER IDENTITY HELPERS ─────────────────────────────────────────────────
// These wrap the SECURITY DEFINER RPCs from migration 0006. They return the
// useful payload directly, or null when the migration isn't applied yet
// (so the agent keeps working on older Supabase schemas).

// Resolve a printer slug (e.g. "kitchen-main") to the current active row.
// Used as preferred routing when kitchens.printer_slug is set.
async function resolvePrinterBySlug(slug) {
  if (!slug) return null;
  const r = await supabaseRpc('get_active_printer_by_slug', {
    p_restaurant_id: RESTAURANT_ID,
    p_slug: slug,
  });
  return (r && r.id) ? r : null;
}

// Find-or-create a printer by hardware fingerprint. Used on discovery so
// the same physical printer stays on the same DB row across transport
// changes (USB → ETH, IP reassignments).
async function upsertPrinterByFingerprint(fingerprint, type, ip, port, name) {
  if (!fingerprint) return null;
  const r = await supabaseRpc('upsert_printer_by_fingerprint', {
    p_restaurant_id: RESTAURANT_ID,
    p_fingerprint:  fingerprint,
    p_printer_type: type || 'kitchen',
    p_printer_ip:   ip || null,
    p_printer_port: Number(port) || 9100,
    p_name:         name || null,
  });
  return (r && r.id) ? r : null;
}

// Log an honest outcome for a print job: 'printed' | 'failed' | 'uncertain'.
// Writes to print_queue.status AND to printer_events (audit log). The
// dashboard subscribes to printer_events for realtime alerts/retry.
async function logPrintOutcome(jobId, printerId, status, message, payload) {
  const r = await supabaseRpc('log_print_outcome', {
    p_job_id:        jobId,
    p_printer_id:    printerId || null,
    p_restaurant_id: RESTAURANT_ID,
    p_status:        status,
    p_message:       message || null,
    p_payload:       payload || {},
  });
  // If RPC isn't deployed, fall back to legacy direct PATCH so old setups still mark printed.
  if (r === null && status === 'printed') {
    try { await supabasePatch('print_queue', jobId, { status: 'printed' }); } catch {}
  }
  return r;
}

// --- NETWORK PRINTER DISCOVERY -----------------------------------------------
function getLocalSubnets() {
  const ifaces = os.networkInterfaces();
  const subnets = [];
  // Skip virtual/software adapters by interface name
  const skipNames = /virtualbox|vmware|hyper.v|vethernet|loopback|pseudo|tap|tunnel|npcap|wsl/i;
  // Skip known virtual subnet ranges
  const skipSubnets = ['192.168.56', '192.168.99', '192.168.100', '172.16.0', '172.17.0'];
  for (const [name, list] of Object.entries(ifaces)) {
    if (skipNames.test(name)) continue;
    for (const addr of list) {
      if (addr.family !== 'IPv4' || addr.internal) continue;
      const subnet = addr.address.split('.').slice(0, 3).join('.');
      if (skipSubnets.includes(subnet)) continue;
      if (!subnets.includes(subnet)) subnets.push(subnet);
    }
  }
  return subnets.length > 0 ? subnets : ['192.168.1'];
}

// Best-guess LAN IPv4 of THIS PC (the machine running the agent).
// This is the address the mobile/web app POSTs to at http://<ip>:3000/print.
// We broadcast it via the heartbeat so the app auto-fills the "Printer Agent IP"
// field with zero manual setup — and picks up DHCP changes within ~20s.
// Same adapter/subnet filtering as getLocalSubnets so we skip VM/VPN/loopback.
function getLocalIp() {
  const ifaces = os.networkInterfaces();
  const skipNames = /virtualbox|vmware|hyper.v|vethernet|loopback|pseudo|tap|tunnel|npcap|wsl/i;
  const skipSubnets = ['192.168.56', '192.168.99', '192.168.100', '172.16.0', '172.17.0'];
  const candidates = [];
  for (const [name, list] of Object.entries(ifaces)) {
    if (skipNames.test(name)) continue;
    for (const addr of list) {
      if (addr.family !== 'IPv4' || addr.internal) continue;
      if (addr.address.startsWith('169.254.')) continue; // APIPA / no DHCP
      const subnet = addr.address.split('.').slice(0, 3).join('.');
      if (skipSubnets.includes(subnet)) continue;
      candidates.push(addr.address);
    }
  }
  // Prefer common home/office LAN ranges (what the phone is most likely on).
  const preferred = candidates.find(ip => ip.startsWith('192.168.') || ip.startsWith('10.'));
  return preferred || candidates[0] || null;
}

function checkPort(ip, port, timeout) {
  return new Promise(resolve => {
    const s = new net.Socket();
    const t = setTimeout(() => { s.destroy(); resolve(false); }, timeout);
    s.connect(port, ip, () => { clearTimeout(t); s.destroy(); resolve(true); });
    s.on('error', () => { clearTimeout(t); resolve(false); });
  });
}

// Confirm a device on port 9100 is a REAL ESC/POS printer, not just something
// with the port open. Plenty of non-printers listen on 9100 — IP cameras/MJPEG
// servers, NAS boxes, other PCs — and they'll silently swallow print data, so
// the agent reports jobs as "printed" while nothing comes out.
//
// We send a DLE EOT 1 real-time status request. A genuine ESC/POS printer
// answers with a single status byte whose fixed bits always satisfy
// (byte & 0x93) === 0x12. A non-printer either stays silent or replies with
// something unrelated (e.g. an MJPEG server answers our bytes with an HTTP
// header — long, and its first byte 'H' fails the invariant). So we require:
// a short reply (<= 4 bytes) whose first byte matches the printer-status mask.
function probeIsPrinter(ip, port, timeout) {
  port = port || 9100; timeout = timeout || 2500;
  return new Promise(resolve => {
    const s = new net.Socket();
    let done = false;
    const finish = (ok) => { if (done) return; done = true; clearTimeout(t); try { s.destroy(); } catch {} resolve(ok); };
    const t = setTimeout(() => finish(false), timeout);
    s.connect(port, ip, () => { try { s.write(Buffer.from([0x10, 0x04, 0x01])); } catch { finish(false); } });
    s.on('data', d => finish(d.length >= 1 && d.length <= 4 && (d[0] & 0x93) === 0x12));
    s.on('error', () => finish(false));
    s.on('close', () => finish(false));
  });
}

// Filter a list of port-9100 candidates down to devices that verify as real
// printers. If NONE verify (e.g. a printer that doesn't implement DLE EOT
// status), return the original list unchanged — better a best-guess than
// dropping a working printer. Only when at least one device is confirmed do we
// exclude the unconfirmed ones (that's what kicks the webcam off the list).
async function keepRealPrinters(ips) {
  if (!ips || ips.length <= 1) return ips || [];
  const results = await Promise.all(ips.map(ip => probeIsPrinter(ip).then(ok => ok ? ip : null)));
  const verified = results.filter(Boolean);
  if (verified.length === 0) return ips;
  if (verified.length !== ips.length) {
    const rejected = ips.filter(ip => !verified.includes(ip));
    log('Ignoring non-printer device(s) on port 9100: ' + rejected.join(', ') + ' (kept: ' + verified.join(', ') + ')');
  }
  return verified;
}

// Read the Windows ARP table - lists every device the PC has seen on the LAN recently.
// This is instant and much more reliable than port scanning 254 IPs.
function getArpIps() {
  return new Promise(resolve => {
    exec('arp -a', (err, out) => {
      if (err || !out) { resolve([]); return; }
      const ips = new Set();
      for (const line of out.split('\n')) {
        const m = line.match(/\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b/);
        if (!m) continue;
        const ip = m[1];
        const parts = ip.split('.').map(Number);
        // Skip broadcast (.255), multicast (224+), and local machine (.0)
        if (parts[3] === 0 || parts[3] === 255 || parts[0] >= 224) continue;
        // Skip known non-printer ranges
        if (ip.startsWith('169.254.')) continue;
        ips.add(ip);
      }
      resolve([...ips]);
    });
  });
}

// Build an ip→MAC map from the Windows ARP table.
// MAC is the stable hardware identity of an ETH printer — survives DHCP
// reassignments, router swaps, etc. We use it as the printer's fingerprint
// so the same physical printer always lands on the same DB row.
function getArpMacMap() {
  return new Promise(resolve => {
    exec('arp -a', (err, out) => {
      if (err || !out) { resolve({}); return; }
      const map = {};
      for (const line of out.split('\n')) {
        // Matches lines like:  "  192.168.1.200        00-11-22-aa-bb-cc     dynamic"
        const m = line.match(/(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+([0-9a-f]{2}([-:][0-9a-f]{2}){5})/i);
        if (!m) continue;
        const ip  = m[1];
        const mac = m[2].toLowerCase().replace(/-/g, ':');
        map[ip] = mac;
      }
      resolve(map);
    });
  });
}

// Push every currently-attached USB printer's fingerprint into the DB so the
// same physical device keeps the same printer_configs row across transport
// changes (USB ↔ ETH). Called once whenever scanUsb succeeds.
async function registerUsbFingerprints() {
  if (!RESTAURANT_ID || RESTAURANT_ID === '__RESTAURANT_ID__') return;
  try {
    const fps = await getUsbPrinterFingerprints();
    for (const fp of fps) {
      const r = await upsertPrinterByFingerprint(fp, 'kitchen', null, null, null);
      if (r) log('USB fingerprint registered: ' + fp + ' (' + (r.is_new ? 'new' : 'matched') + ')');
    }
  } catch (e) { log('USB fingerprint register failed: ' + e.message); }
}

// Pull the USB hardware fingerprint (VendorID:ProductID:Serial) for printers
// currently attached to this PC. Returns a list of strings like
// "usb:0519:000B:ABCD123". Stable across reboots and USB-port moves, so we
// use it as fingerprint when the printer is on USB.
async function getUsbPrinterFingerprints() {
  const r = await psRun([
    `$pnp = Get-CimInstance Win32_PnPEntity -Filter "Service='usbprint'" -ErrorAction SilentlyContinue`,
    `if (-not $pnp) { Write-Output ''; exit }`,
    `$pnp | ForEach-Object {`,
    `  $id = $_.DeviceID`,
    `  if ($id -match 'USB\\\\VID_([0-9A-F]{4})&PID_([0-9A-F]{4})\\\\(.+)$') {`,
    `    Write-Output ('usb:' + $matches[1] + ':' + $matches[2] + ':' + $matches[3])`,
    `  }`,
    `}`,
  ]);
  return r.split(/\r?\n/).map(s => s.trim()).filter(Boolean);
}

// Check a list of IPs in controlled batches - avoids overwhelming the Windows TCP stack
async function checkPortBatch(ips, port, timeout, batchSize) {
  const found = [];
  for (let i = 0; i < ips.length; i += batchSize) {
    const batch = ips.slice(i, i + batchSize);
    const results = await Promise.all(batch.map(ip => checkPort(ip, port, timeout).then(ok => ok ? ip : null)));
    found.push(...results.filter(Boolean));
  }
  return found;
}

async function scanNetworkForPrinters() {
  const PRINTER_PORTS = [9100, 515, 9101]; // RAW, LPD, alt-RAW

  // -- Step 1: ARP table - instant, catches printer the moment it gets an IP --
  const arpIps = await getArpIps();
  if (arpIps.length > 0) {
    log('ARP table has ' + arpIps.length + ' device(s) - checking for printer ports...');
    for (const port of PRINTER_PORTS) {
      const found = await checkPortBatch(arpIps, port, 2000, 20);
      if (found.length > 0) {
        log('Found ' + found.length + ' device(s) via ARP on port ' + port + ': ' + found.join(', '));
        const real = await keepRealPrinters(found);
        if (real.length > 0) return real;
      }
    }
    log('ARP devices found but none verified as printers on ports (' + PRINTER_PORTS.join('/') + ')');
  } else {
    log('ARP table empty - falling back to subnet scan');
  }

  // -- Step 2: Batched subnet scan as fallback --
  const subnets = getLocalSubnets();
  log('Scanning ' + subnets.map(s => s + '.1-254').join(', ') + ' in batches...');
  const allIps = [];
  for (const subnet of subnets) {
    for (let i = 1; i <= 254; i++) allIps.push(subnet + '.' + i);
  }
  for (const port of PRINTER_PORTS) {
    const found = await checkPortBatch(allIps, port, 1200, 30);
    if (found.length > 0) {
      log('Found ' + found.length + ' device(s) via subnet scan on port ' + port + ': ' + found.join(', '));
      const real = await keepRealPrinters(found);
      if (real.length > 0) return real;
    }
  }

  log('Scan complete - 0 printer(s) found');
  return [];
}

async function reportDiscoveredPrinters(ips) {
  if (!RESTAURANT_ID || RESTAURANT_ID === '__RESTAURANT_ID__') return;
  try {
    const existing = await supabaseGet('printer_configs', { restaurant_id: RESTAURANT_ID, printer_type: 'scan' });
    const payload = { settings: { discovered_ips: ips, scanned_at: new Date().toISOString() } };
    if (Array.isArray(existing) && existing.length > 0) {
      await supabasePatch('printer_configs', existing[0].id, payload);
    } else {
      await supabasePost('printer_configs', {
        restaurant_id: RESTAURANT_ID,
        name: '__scan__',
        printer_type: 'scan',
        is_active: false,
        ...payload,
      });
    }
    log('Reported ' + ips.length + ' discovered printer(s) to LightMenu dashboard');
  } catch (e) {
    log('Discovery report failed: ' + e.message);
  }
}

async function autoAssignPrinterIps(discoveredIps) {
  if (!RESTAURANT_ID || RESTAURANT_ID === '__RESTAURANT_ID__') return;
  if (discoveredIps.length === 0) return;
  // Pull MACs once — used as the fingerprint for each discovered ETH printer.
  // Same physical printer → same DB row even after DHCP reassigns the IP.
  const macMap = await getArpMacMap();
  try {
    const all  = await supabaseGet('printer_configs', { restaurant_id: RESTAURANT_ID, is_active: 'true' });
    const real = Array.isArray(all) ? all.filter(c => c.printer_type !== 'scan') : [];

    if (real.length === 0) {
      // First-time setup - create a config for each discovered printer
      for (let i = 0; i < discoveredIps.length; i++) {
        const ip  = discoveredIps[i];
        const mac = macMap[ip];
        const fp  = mac ? ('eth:' + mac) : null;
        try {
          // Prefer the fingerprint upsert RPC — if the printer has been seen
          // before (even on a different IP), this returns the existing row
          // instead of creating a duplicate. Falls back to plain POST when
          // the migration isn't applied or no MAC was resolved.
          const upserted = fp ? await upsertPrinterByFingerprint(fp, 'kitchen', ip, 9100,
            discoveredIps.length === 1 ? 'Printer' : 'Printer ' + (i + 1)
          ) : null;
          if (upserted) {
            log('Auto-registered printer ' + ip + ' (fp=' + fp + ', ' + (upserted.is_new ? 'new' : 'matched existing') + ')');
            continue;
          }
          await stationDb('printer_config.create', { values: {
            name: discoveredIps.length === 1 ? 'Printer' : 'Printer ' + (i + 1),
            printer_type: 'kitchen',
            printer_ip: ip,
            is_active: true,
          } });
          log('Auto-created printer config for ' + ip);
        } catch (e) {
          log('Auto-create failed for ' + (discoveredIps[i]) + ': ' + e.message);
          // Fall back: set IP in memory directly so printing still works
          PRINTER_IP = discoveredIps[i];
          PRINTER_PORT = 9100;
          log('Using discovered IP in memory: ' + PRINTER_IP);
        }
      }
      // Small delay to let Supabase propagate the new record before reading it back
      await new Promise(r => setTimeout(r, 1500));
      await refreshPrinters();
    } else if (real.length === 1 && discoveredIps.length >= 1) {
      // Single-printer setup - keep the IP current automatically, including when
      // the restaurant switches the printer from USB to Ethernet or the router
      // hands it a new DHCP address. discoveredIps here has already been verified
      // to be real ESC/POS printers (see keepRealPrinters), so a webcam/PC that
      // merely has port 9100 open can no longer hijack the config. Prefer the
      // device whose MAC matches the printer's learned fingerprint; otherwise
      // take the verified printer and learn its fingerprint so future scans
      // track the same physical device across IP changes.
      const cfg = real[0];
      const macMap = await getArpMacMap();
      let targetIp = null;
      if (cfg.fingerprint && cfg.fingerprint.startsWith('eth:')) {
        const wantMac = cfg.fingerprint.slice(4);
        targetIp = discoveredIps.find(ip => macMap[ip] === wantMac) || null;
      }
      if (!targetIp) targetIp = discoveredIps[0];
      const targetMac = macMap[targetIp];
      const targetFp  = targetMac ? ('eth:' + targetMac) : cfg.fingerprint;
      if (cfg.printer_ip !== targetIp || (targetFp && cfg.fingerprint !== targetFp)) {
        const patch = { printer_ip: targetIp };
        if (targetFp && cfg.fingerprint !== targetFp) patch.fingerprint = targetFp;
        await stationDb('printer_config.update', { id: cfg.id, patch });
        log('Printer auto-updated: ' + (cfg.printer_ip || '(none)') + ' -> ' + targetIp + (patch.fingerprint ? ' (fingerprint learned: ' + targetFp + ')' : ''));
        PRINTER_IP = targetIp;
        PRINTER_PORT = Number(cfg.printer_port) || 9100;
        await new Promise(r => setTimeout(r, 1500));
        await refreshPrinters();
      } else {
        // IP is already correct - make sure it's loaded into memory
        if (PRINTER_IP !== cfg.printer_ip) {
          PRINTER_IP = cfg.printer_ip;
          PRINTER_PORT = Number(cfg.printer_port) || 9100;
          log('Loaded printer IP from config: ' + PRINTER_IP);
        }
      }
    } else {
      // Multiple printers - only fill in configs that have no IP set
      const noIp = real.filter(c => !c.printer_ip);
      let changed = false;
      for (let i = 0; i < Math.min(noIp.length, discoveredIps.length); i++) {
        await stationDb('printer_config.update', { id: noIp[i].id, patch: { printer_ip: discoveredIps[i] } });
        log('Assigned IP ' + discoveredIps[i] + ' -> ' + noIp[i].name);
        changed = true;
      }
      if (changed) await refreshPrinters();
    }
  } catch (e) {
    log('Auto-assign failed: ' + e.message);
  }
}

let _scanTimer = null;
let _scanCount = 0;
let _notifiedNotFound = false;

// ─── HEARTBEAT ────────────────────────────────────────────────────────────────
// The dashboard's "Print Agent: Active/Inactive" pill reads this timestamp from
// the agent's "scan" printer_configs row. We write it every 20s. The dashboard
// shows Active when it's within the last 60s, Inactive otherwise.
//
// Why DB-based instead of an HTTP /status ping from the browser:
//   - With shared tunnel mode (print.lightmenu.app) the browser can't tell which
//     restaurant's agent it's reaching — all agents share the same domain.
//   - Browsers block direct LAN HTTP calls from HTTPS pages (mixed content).
//   - This works identically for LAN + tunnel + behind-NAT setups.
async function sendHeartbeat() {
  if (!RESTAURANT_ID || RESTAURANT_ID === '__RESTAURANT_ID__') return;
  try {
    const existing = await supabaseGet('printer_configs', { restaurant_id: RESTAURANT_ID, printer_type: 'scan' });
    const now = new Date().toISOString();
    // The PC's own LAN IP — what the mobile/web app uses to reach this agent
    // directly. Broadcasting it here means the "Printer Agent IP" field fills
    // itself, and a DHCP/PC change is reflected on the next heartbeat (≤20s).
    const agentIp = getLocalIp();
    const beat = { last_heartbeat: now, agent_version: AGENT_VERSION };
    if (agentIp) { beat.agent_ip = agentIp; beat.agent_port = SERVER_PORT; beat.agent_hostname = os.hostname(); }
    if (Array.isArray(existing) && existing.length > 0) {
      // Merge into existing settings so we don't wipe discovered_ips/scanned_at
      const prevSettings = existing[0].settings || {};
      await supabasePatch('printer_configs', existing[0].id, {
        settings: { ...prevSettings, ...beat },
      });
    } else {
      await supabasePost('printer_configs', {
        restaurant_id: RESTAURANT_ID,
        name: '__scan__',
        printer_type: 'scan',
        is_active: false,
        settings: beat,
      });
    }
  } catch (e) {
    log('Heartbeat failed: ' + e.message);
  }
}
setTimeout(sendHeartbeat, 1500);   // first ping right after boot
setInterval(sendHeartbeat, 20000); // then every 20s

function showWindowsNotification(title, msg) {
  psRun([
    `Add-Type -AssemblyName System.Windows.Forms`,
    `$n = New-Object System.Windows.Forms.NotifyIcon`,
    `$n.Icon = [System.Drawing.SystemIcons]::Information`,
    `$n.Visible = $true`,
    `$n.ShowBalloonTip(8000, '${title.replace(/'/g,"''")}', '${msg.replace(/'/g,"''")}', [System.Windows.Forms.ToolTipIcon]::Warning)`,
    `Start-Sleep -Milliseconds 9000`,
    `$n.Visible = $false`,
  ]).catch(() => {});
}

async function runNetworkScan() {
  _scanCount++;
  const prevIp = PRINTER_IP;
  const ips = await scanNetworkForPrinters();
  await reportDiscoveredPrinters(ips);
  await autoAssignPrinterIps(ips);
  if (!prevIp && PRINTER_IP) {
    try { track('printer_found', { ip: PRINTER_IP, port: PRINTER_PORT, scan_attempts: _scanCount }); } catch {}
  }

  if (!PRINTER_IP && !usbWinPrinter) {
    // Aggressive retry schedule: every 30s for the first 10 scans (5 min), then every 2 min
    const delay = _scanCount <= 10 ? 30 * 1000 : 2 * 60 * 1000;
    if (_scanTimer) clearTimeout(_scanTimer);
    _scanTimer = setTimeout(runNetworkScan, delay);
    log('No printer found - will rescan in ' + (delay / 1000) + 's (attempt ' + _scanCount + ')');

    // After ~2 minutes of no printer, show a Windows notification so the user knows
    if (_scanCount === 4 && !_notifiedNotFound) {
      _notifiedNotFound = true;
      log('Showing printer-not-found notification to user');
      showWindowsNotification(
        'LightMenu - Printer not found',
        'No thermal printer detected on the network. Make sure the printer is on and connected to the same WiFi router, then open http://localhost:3000 to scan again or enter the IP manually.'
      );
      // Also auto-open the dashboard so the user sees it
      exec('start http://localhost:3000');
    }
  } else {
    _notifiedNotFound = false; // reset if printer later disconnects
  }
}
setTimeout(runNetworkScan, 5000);
setInterval(runNetworkScan, 10 * 60 * 1000);

async function refreshPrinters() {
  try {
    if (!RESTAURANT_ID) return;
    // is_active=true excludes the internal scan record (is_active=false)
    const list = await supabaseGet('printer_configs', { restaurant_id: RESTAURANT_ID, is_active: 'true' });
    if (Array.isArray(list) && list.length) {
      printersCache = list;
      // Prefer a printer that has an IP set (ETH) over one that doesn't (stale
      // USB row). Without this, switching USB→ETH left PRINTER_IP empty because
      // the old USB row (no IP) was list[0] and blocked the ETH row from loading.
      const first = list.find(p => p.printer_ip) || list[0];
      if (first.printer_ip) PRINTER_IP = first.printer_ip;
      if (first.printer_port) PRINTER_PORT = Number(first.printer_port);
      log('Synced ' + list.length + ' printer(s) - default: ' + PRINTER_IP + ':' + PRINTER_PORT);
    }
  } catch (e) { log('Printer sync failed: ' + e.message); }
}
setInterval(refreshPrinters, 30000);
setTimeout(refreshPrinters, 1000);

// ─── Category → printer routing (multi-printer) ──────────────────────────────
// Rows of {menu_category_id, printer_config_id, printer_number, printer_ip, ...}
// from get_category_routing (kitchens + kitchen_categories). Empty when the
// restaurant has no kitchen stations configured → single-printer fallback.
let categoryRoutingCache = [];
async function refreshCategoryRouting() {
  try {
    if (!RESTAURANT_ID) return;
    const r = await supabaseRpc('get_category_routing', { p_restaurant_id: RESTAURANT_ID });
    if (Array.isArray(r)) categoryRoutingCache = r;
  } catch (e) { log('Category routing sync failed: ' + e.message); }
}
setInterval(refreshCategoryRouting, 30000);
setTimeout(refreshCategoryRouting, 1500);

// True once the owner has set up at least one station with an assigned category.
// Only then does strict routing apply (unassigned categories don't print).
function stationsConfigured() { return categoryRoutingCache.length > 0; }

// The printer_config rows a category is assigned to (may be more than one).
function printersForCategory(catId) {
  if (!catId) return [];
  const key = String(catId);
  return categoryRoutingCache.filter(r => String(r.menu_category_id) === key);
}

// Split a kitchen ticket by category and print each group to its printer.
//   • category assigned to printer(s) → each of those printers
//   • item with NO category id (old client / missing metadata) → default printer
//     (a safety net — we never silently drop for lack of a tag)
//   • category known but assigned to no station → dropped (strict, user's choice)
// buildIdentifierTicket/buildKitchenTicket + sendToPrinterConfig defined later.
async function printKitchenRouted(ticket, copies) {
  const items = Array.isArray(ticket.items) ? ticket.items : [];
  const groups = new Map(); // key -> { pc, number, items: [] }
  for (const it of items) {
    const catId = it.menu_category_id || it.category_id || null;
    const routes = printersForCategory(catId);
    if (routes.length) {
      for (const r of routes) {
        const key = 'p:' + r.printer_config_id;
        if (!groups.has(key)) groups.set(key, { pc: r, number: r.printer_number, items: [] });
        groups.get(key).items.push(it);
      }
    } else if (!catId) {
      const key = 'default';
      if (!groups.has(key)) groups.set(key, { pc: null, number: null, items: [] });
      groups.get(key).items.push(it);
    }
    // else: known category, no station → drop
  }
  if (groups.size === 0) { log('KITCHEN: all items unassigned — nothing printed (strict routing)'); return; }
  for (const g of groups.values()) {
    const sub = Object.assign({}, ticket, { items: g.items });
    if (g.number != null) sub.kitchen_name = 'PRINTER ' + g.number;
    const data = buildKitchenTicket(sub);
    for (let i = 0; i < copies; i++) await sendToPrinterConfig(data, g.pc);
    log('KITCHEN -> printer ' + (g.number != null ? '#' + g.number : 'default') + ' (' + g.items.length + ' item[s])');
  }
}

// ─── Restaurant branding (header logo) ───────────────────────────────────────
// The Station header shows the restaurant's own logo — the same image uploaded
// through the web builder (e.g. pulled in via the Instagram-import flow) —
// instead of a static LightMenu icon. logo_url rarely changes, so this is
// cached and refreshed on a slow interval rather than on every /status poll.
let BRANDING_LOGO_URL = null;
// Prefer the logo_url column; fall back to the logo uploaded in the Builder,
// which lives in the header block's data.logoUrl inside website_blocks. That's
// where the Instagram-import flow stores it, and logo_url is usually empty — so
// without this fallback the Station showed the static LightMenu icon even when
// the restaurant had a real logo. Mirrors the web/Flutter effectiveRestaurantLogo.
function resolveBrandingLogo(row) {
  if (!row) return null;
  if (row.logo_url) return row.logo_url;
  let blocks = row.website_blocks;
  if (typeof blocks === 'string') { try { blocks = JSON.parse(blocks); } catch (_) { blocks = null; } }
  if (Array.isArray(blocks)) {
    for (const b of blocks) {
      if (b && b.type === 'header' && b.data && b.data.logoUrl) return b.data.logoUrl;
    }
  }
  return null;
}
async function refreshBranding() {
  try {
    if (!RESTAURANT_ID) return;
    const rows = await supabaseGet('restaurants', { id: RESTAURANT_ID }, 1);
    const row = Array.isArray(rows) ? rows[0] : null;
    BRANDING_LOGO_URL = resolveBrandingLogo(row);
  } catch (e) { log('Branding sync failed: ' + e.message); }
}
setInterval(refreshBranding, 5 * 60 * 1000);
setTimeout(refreshBranding, 1000);

// --- PRINT QUEUE POLLING ------------------------------------------------------
async function fetchPendingJobs() {
  if (!RESTAURANT_ID) return [];
  const cutoff = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
  const url = SUPABASE_URL + '/rest/v1/print_queue?restaurant_id=eq.' + encodeURIComponent(RESTAURANT_ID) + '&status=eq.pending&limit=50&order=created_date.asc';
  const data = await new Promise((resolve, reject) => {
    const req = https.request(url, {
      method: 'GET',
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer ' + SUPABASE_ANON_KEY,
      }
    }, (res) => {
      let body = '';
      res.on('data', c => body += c);
      res.on('end', () => { try { resolve(JSON.parse(body)); } catch (e) { reject(e); } });
    });
    req.on('error', reject);
    req.end();
  });
  return (Array.isArray(data) ? data : []).filter(r => !r.created_date || r.created_date >= cutoff);
}

async function markJobPrinted(id) {
  await supabasePatch('print_queue', id, { status: 'printed' });
}

async function pollAndPrint() {
  if (!STATION_ALLOWED) return;   // server kill switch — paused, but keep re-checking
  try {
    const jobs = await fetchPendingJobs();
    for (const job of jobs) {
      if (processingJobs.has(job.id)) continue;

      // Print-twice guard: if we already physically printed this job (the
      // Supabase ack just never landed — crash or network blip), don't print
      // again. Just retry telling Supabase, then move on.
      if (store.wasPrinted(job.id)) {
        try { await logPrintOutcome(job.id, null, 'printed', null, {}); } catch {}
        continue;
      }

      processingJobs.add(job.id);
      let printerIp   = PRINTER_IP;
      let printerPort = PRINTER_PORT;
      try {
        const items    = JSON.parse(job.items_json || '[]');
        const settings = job.settings_json ? JSON.parse(job.settings_json) : {};
        // Map printer_type to ticket type
        const ticketType = ['check','cancel','transfer'].includes(job.printer_type)
          ? job.printer_type : 'kitchen';

        const ticket = {
          type:                 ticketType,
          restaurant_id:        job.restaurant_id,
          restaurant_name:      job.restaurant_name || '',
          table_number:         job.table_number,
          waiter_name:          job.waiter_name,
          currency:             job.currency || 'EUR',
          time:                 job.order_time || job.created_date,
          order_id:             job.order_id,
          // per_section routing: show BAR or KITCHEN label on the ticket
          kitchen_name:         job.printer_type === 'bar' ? 'BAR' : null,
          // check ticket fields
          payment_method:       job.payment_method,
          total:                job.total_amount,
          guest_count:          job.guest_count,
          bill_url:             job.bill_url,
          // cancel/transfer extra info from settings
          cancelled_by:         settings._cancelled_by || job.waiter_name,
          from_table:           settings._from_table || job.table_number,
          to_table:             settings._to_table,
          restaurant_address:   settings._restaurant_address || '',
          restaurant_phone:     settings._restaurant_phone || '',
          restaurant_instagram: settings._restaurant_instagram || '',
          items,
          settings,
        };

        // ─── Multi-printer routing cascade ─────────────────────────────────
        // Each job is resolved to ONE specific printer in this order:
        //   1. job.printer_config_id   — explicit per-job target (best)
        //   2. job.printer_slug        — human-readable slot via RPC
        //   3. printer_type match      — first active printer of that type
        //   4. any active kitchen      — last-resort fallback
        // This stops the old bug where USB globals or first-match-by-type
        // stole jobs meant for a different printer (catastrophic with 2+
        // printers of the same type).
        let printerConfig = null;
        if (job.printer_config_id) {
          printerConfig = printersCache.find(p => p.id === job.printer_config_id && p.is_active);
        }
        if (!printerConfig && job.printer_slug) {
          printerConfig = await resolvePrinterBySlug(job.printer_slug);
        }
        if (!printerConfig) {
          printerConfig = printersCache.find(p =>
            p.printer_type === (job.printer_type || 'kitchen') && p.is_active
          );
        }
        if (!printerConfig) {
          // Prefer a config that has an IP set so ETH printers aren't skipped
          // when a stale USB row (no IP) sorts first in the cache.
          printerConfig = printersCache.find(p => p.printer_type === (job.printer_type || 'kitchen') && p.is_active && p.printer_ip)
                       || printersCache.find(p => p.printer_type === 'kitchen' && p.is_active && p.printer_ip)
                       || printersCache.find(p => p.printer_type === (job.printer_type || 'kitchen') && p.is_active)
                       || printersCache.find(p => p.printer_type === 'kitchen' && p.is_active)
                       || printersCache.find(p => p.is_active);
        }
        if (printerConfig?.printer_ip) {
          printerIp   = printerConfig.printer_ip;
          printerPort = Number(printerConfig.printer_port) || 9100;
        }

        if (!printerIp && !usbWinPrinter && !usbDirectPort) {
          log('Waiting for printer IP - job ' + job.id + ' will retry (scan in progress)');
          processingJobs.delete(job.id);
          continue;
        }

        // Known-bad printer from a recent failure — back off instead of
        // hammering it again every 3s. Job stays pending and retries once
        // the cooldown expires.
        const cooldownKey = printerConfig?.id || printerIp || 'usb';
        const cooldownUntil = printerCooldowns.get(cooldownKey);
        if (cooldownUntil && Date.now() < cooldownUntil) {
          processingJobs.delete(job.id);
          continue;
        }

        // Raster path FIRST: if the web app sent a pre-rendered bitmap (used
        // for Arabic/CJK/Hebrew/Thai where this printer has no font ROM),
        // print the pixels directly and skip the text builder entirely. If
        // the bitmap is malformed, buildRasterTicket returns null and we
        // fall through to the text path — never a silent failure.
        let data = null;
        if (job.bitmap_b64) {
          data = buildRasterTicket(job.bitmap_b64, job.bitmap_width_dots, job.bitmap_height);
          if (data) log('Raster mode: ' + job.bitmap_width_dots + 'x' + job.bitmap_height + ' dots');
        }
        if (!data) {
          switch (ticketType) {
            case 'check':    data = buildCheckTicket(ticket);    break;
            case 'cancel':   data = buildCancelTicket(ticket);   break;
            case 'transfer': data = buildTransferTicket(ticket); break;
            default:         data = buildKitchenTicket(ticket);  break;
          }
        }

        const copies = (ticketType === 'check' ? settings.check_copies : settings.order_copies) || 1;
        // Network-first dispatch: if the resolved config has an IP, send via TCP DIRECTLY.
        // Bypasses USB globals (usbDirectPort/usbWinPrinter) that would otherwise steal
        // every job — the core multi-printer bug. USB path only triggers when the
        // resolved config has no IP (true USB-only printer).
        // Transport selection. In a single-printer setup, PREFER a connected
        // USB printer — the operator plugged it in on purpose, so don't waste
        // 8s timing out on a stale network IP first. Network stays primary for
        // multi-printer setups and when no USB is present. Either path falls
        // back to the other so a wrong dashboard config never blocks printing.
        const usbAvailable = !!(usbDirectPort || usbWinPrinter);
        const physicalPrinters = printersCache.filter(p => p.printer_type && p.printer_type !== 'scan');
        const singlePrinter = physicalPrinters.length <= 1;
        // Only prefer USB when there is NO ETH IP configured. If an IP exists
        // the operator switched to Ethernet — the Windows spooler (LightMenu USB)
        // stays installed even after the cable is removed, so usbAvailable stays
        // true even on ETH, which wrongly routed every job to a dead USB queue.
        const preferUsb = usbAvailable && singlePrinter && !printerIp;
        const useNetwork = !!printerIp && !preferUsb;
        let transport = useNetwork ? 'network' : 'usb';
        for (let i = 0; i < Math.min(copies, 3); i++) {
          if (useNetwork) {
            try {
              await sendViaNetwork(data, printerIp, printerPort);
            } catch (netErr) {
              if (!usbAvailable || !singlePrinter) throw netErr;
              log('Network printer ' + printerIp + ':' + printerPort + ' unreachable (' + netErr.message + ') — falling back to USB');
              await sendToPrinter(data, '', printerPort); // empty IP → USB-direct then spooler
              transport = 'usb-fallback';
            }
          } else {
            // USB-first. sendToPrinter tries USB direct → spooler, and only if
            // both USB methods fail does it fall through to the network IP.
            await sendToPrinter(data, printerIp, printerPort);
          }
        }
        // Record the physical print BEFORE telling Supabase — if the PATCH/RPC
        // below fails (network blip) the next poll will see this job is
        // already printed and skip straight to re-confirming, never reprinting.
        store.markPrinted(job.id);
        jobFailureCounts.delete(job.id);
        printerCooldowns.delete(cooldownKey);
        // Honest reporting via log_print_outcome RPC — writes BOTH print_queue.status
        // AND a printer_events audit row. Dashboard subscribes to printer_events for
        // realtime alerts. Falls back to legacy PATCH if RPC isn't deployed yet.
        await logPrintOutcome(job.id, printerConfig?.id, 'printed', null, {
          ip: printerIp, port: printerPort, transport,
        });
        processingJobs.delete(job.id);
        printed++;
        updateDailyStats('printed');
        // Save to local store — survives offline + powers Analytics/Bills/Daily Report pages
        try {
          const storeRec = {
            order_id:       job.order_id,
            date:           job.order_time || job.created_date || new Date().toISOString(),
            table:          ticket.table_number,
            waiter:         ticket.waiter_name,
            items:          items,
            printer_type:   job.printer_type || 'kitchen',
            total:          ticket.total,
            guest_count:    ticket.guest_count,
            currency:       ticket.currency,
            payment_method: job.payment_method || settings.payment_method || ticket.payment_method,
            bill_url:       ticket.bill_url,
            source:         'supabase',
          };
          if (ticketType === 'check') store.addBill(storeRec);
          else                        store.addOrder(storeRec);
        } catch (e) { log('Store save failed: ' + e.message); }
        log('Printed job ' + job.id + ' (' + ticket.type + ') Mesa ' + ticket.table_number);
        track('job_printed', { job_id: job.id, type: ticketType, table: ticket.table_number, printer_mode: usbDirectPort ? 'usb-direct' : usbWinPrinter ? 'usb-spooler' : 'network', printer_ip: printerIp });
      } catch (e) {
        processingJobs.delete(job.id);
        failed++;
        updateDailyStats('failed');
        const errMsg = e?.message || String(e) || 'unknown error';
        log('Failed job ' + job.id + ': ' + errMsg + ' [ip=' + printerIp + ']');

        // Cool the printer off for a bit so a dead IP doesn't get re-hit
        // every 3s — it'll be retried automatically once the cooldown lapses.
        const failKey = printerIp || 'usb';
        printerCooldowns.set(failKey, Date.now() + PRINTER_COOLDOWN_MS);

        const attempts = (jobFailureCounts.get(job.id) || 0) + 1;
        jobFailureCounts.set(job.id, attempts);
        const giveUp = attempts >= MAX_JOB_RETRIES;

        // Honest failure log: writes printer_events row + (normally) leaves
        // print_queue.status as pending so it's retryable. Once we've hit the
        // retry cap, also PATCH it straight to 'failed' so it stops being
        // refetched forever and shows up for manual attention instead.
        try {
          await logPrintOutcome(job.id, null, 'failed', errMsg, {
            ip: printerIp, port: printerPort, attempts,
          });
          if (giveUp) {
            await supabasePatch('print_queue', job.id, { status: 'failed' });
            jobFailureCounts.delete(job.id);
            log('Giving up on job ' + job.id + ' after ' + attempts + ' attempts — marked failed');
          }
        } catch {}
        track('job_failed', { job_id: job.id, error: errMsg, attempts, printer_mode: usbDirectPort ? 'usb-direct' : usbWinPrinter ? 'usb-spooler' : 'network', printer_ip: printerIp });
      }
    }
  } catch (e) {
    log('Poll error: ' + e.message);
  }
}

// Poll every 3 seconds
setInterval(pollAndPrint, 3000);
setTimeout(pollAndPrint, 2000);

let printed = 0, failed = 0;
let LAST_ACTIVITY_TS = 0;   // updated on every print; the auto-updater waits for a quiet window
const processingJobs = new Set();
// Per-job failure counter + per-printer cooldown — stops a single dead
// printer from being hammered every 3s forever and gives jobs a real
// terminal state (print_queue.status = 'failed') after enough attempts.
const jobFailureCounts = new Map();
const printerCooldowns = new Map();
const MAX_JOB_RETRIES = 10;
const PRINTER_COOLDOWN_MS = 15000;

// Durable rotating log — so a failure can be diagnosed after the fact instead
// of vanishing with the console window. Rotates at ~5MB, keeps one previous
// file (agent.log -> agent.log.1).
const LOG_FILE = path.join(__dirname, 'agent.log');
const LOG_FILE_OLD = path.join(__dirname, 'agent.log.1');
const MAX_LOG_BYTES = 5 * 1024 * 1024;

function log(m) {
  const line = '[' + new Date().toLocaleTimeString() + '] ' + m;
  console.log(line);
  try {
    let size = 0;
    try { size = fs.statSync(LOG_FILE).size; } catch {}
    if (size > MAX_LOG_BYTES) {
      try { fs.renameSync(LOG_FILE, LOG_FILE_OLD); } catch {}
    }
    fs.appendFileSync(LOG_FILE, line + '\n');
  } catch {}
}

// ─── OFFLINE ANALYTICS ────────────────────────────────────────────────────────
// Events are written to a local JSON file immediately — works with zero internet.
// A background flush drains the queue into Supabase whenever connectivity allows.
// Required table (run once in Supabase SQL editor):
//   create table if not exists agent_analytics (
//     id uuid default gen_random_uuid() primary key,
//     restaurant_id text, agent_version text,
//     event text not null, ts timestamptz not null,
//     data jsonb default '{}'
//   );
const ANALYTICS_FILE = path.join(__dirname, 'analytics.queue.json');
const ANALYTICS_CAP  = 500; // max events to buffer locally
const STATS_FILE     = path.join(__dirname, 'stats.daily.json');
// Menu snapshot — fetched from Supabase when online, served from disk when
// offline so the Station's Menu tab keeps working during an internet outage.
const MENU_CACHE_FILE = path.join(__dirname, 'menu.cache.json');
const STATIONS_CACHE_FILE = path.join(__dirname, 'stations.cache.json');

// Read/write today's cumulative stats — survives agent restarts.
// ui.ps1 reads this file directly so it shows accurate totals even when
// the agent is disconnected or the HTTP server isn't responding.
function updateDailyStats(type) {
  const today = new Date().toISOString().slice(0, 10); // 'YYYY-MM-DD'
  let s = { date: today, printed: 0, failed: 0, last_sync: null };
  try {
    const raw = JSON.parse(fs.readFileSync(STATS_FILE, 'utf8'));
    if (raw.date === today) s = raw; // keep today's counts; reset on new day
  } catch {}
  if (type === 'printed') s.printed++;
  else if (type === 'failed') s.failed++;
  else if (type === 'sync') s.last_sync = new Date().toISOString();
  s.date = today;
  try { fs.writeFileSync(STATS_FILE, JSON.stringify(s)); } catch {}
}

function _readQueue() {
  try { return JSON.parse(fs.readFileSync(ANALYTICS_FILE, 'utf8')); }
  catch { return []; }
}

function track(event, data) {
  if (!RESTAURANT_ID || RESTAURANT_ID === '__RESTAURANT_ID__') return;
  const q = _readQueue();
  q.push({ event, ts: new Date().toISOString(), restaurant_id: RESTAURANT_ID, agent_version: AGENT_VERSION, data: data || {} });
  if (q.length > ANALYTICS_CAP) q.splice(0, q.length - ANALYTICS_CAP);
  try { fs.writeFileSync(ANALYTICS_FILE, JSON.stringify(q)); } catch {}
  _flushAnalytics().catch(() => {});
}

let _flushPending = false;
async function _flushAnalytics() {
  if (_flushPending) return;
  const q = _readQueue();
  if (q.length === 0) return;
  _flushPending = true;
  try {
    await supabasePost('agent_analytics', q);
    fs.writeFileSync(ANALYTICS_FILE, '[]');
    updateDailyStats('sync');
    if (q.length > 1) log('Analytics: flushed ' + q.length + ' event(s)');
  } catch {
    // offline — events stay queued; next interval will retry
  } finally {
    _flushPending = false;
  }
}
setInterval(() => _flushAnalytics().catch(() => {}), 60000);
// ─────────────────────────────────────────────────────────────────────────────

function sendViaNetwork(data, ip, port) {
  ip   = ip   || PRINTER_IP;
  port = port || PRINTER_PORT;
  return new Promise((resolve, reject) => {
    const s = new net.Socket();
    const t = setTimeout(() => { s.destroy(); reject(new Error('Printer timeout')); }, 8000);
    s.connect(port, ip, () => { s.write(data, () => s.end()); });
    s.on('close', () => { clearTimeout(t); resolve(); });
    s.on('error', e => { clearTimeout(t); reject(e); });
  });
}

function sendToPrinter(data, ip, port) {
  LAST_ACTIVITY_TS = Date.now();   // let the auto-updater avoid exiting mid-print
  // Strategy 1: direct write (no driver needed)
  if (usbDirectPort) {
    return sendViaDirectUsb(data, usbDirectPort).catch(e => {
      log('USB direct write failed (' + e.message + ') - retrying via spooler or network');
      usbDirectPort = null;
      return sendToPrinter(data, ip, port); // retry with next available method
    });
  }
  // Strategy 2: Windows spooler (Generic/Text-Only driver)
  if (usbWinPrinter) {
    return sendViaSpooler(data, usbWinPrinter).catch(e => {
      log('USB spooler failed (' + e.message + ') - switching to network');
      usbWinPrinter = null;
      return sendViaNetwork(data, ip, port);
    });
  }
  return sendViaNetwork(data, ip, port);
}

// Send to ONE specific printer (multi-printer routing). A network printer with
// its own IP is addressed directly, bypassing the USB globals — otherwise a
// local USB printer would hijack every job. A printer with no IP (the local USB
// one, or no config) falls through to the default USB/network path.
function sendToPrinterConfig(data, pc) {
  if (pc && pc.printer_ip) {
    return sendViaNetwork(data, pc.printer_ip, Number(pc.printer_port) || 9100);
  }
  return sendToPrinter(data);
}

// Write ESC/POS bytes directly to \\.\USB001 etc. — no Windows printer or driver needed.
// Requires usbprint.sys (built into Windows, auto-installed when any USB printer is first plugged in).
function sendViaDirectUsb(data, portPath) {
  const tmp = path.join(os.tmpdir(), 'lm_job_' + Date.now() + '.bin');
  fs.writeFileSync(tmp, data);
  const pf = tmp.replace(/\\/g, '\\\\');
  const pp = portPath.replace(/\\/g, '\\\\');
  return psRun([
    `$b = [System.IO.File]::ReadAllBytes('${pf}')`,
    `try {`,
    `  $s = [System.IO.File]::Open('${pp}', [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)`,
    `  $s.Write($b, 0, $b.Length)`,
    `  $s.Flush(); $s.Close()`,
    `  Write-Output 'OK'`,
    `} catch { Write-Output ('FAIL:' + $_.Exception.Message) }`,
    `Remove-Item '${pf}' -Force -ErrorAction SilentlyContinue`,
  ]).then(r => {
    try { fs.unlinkSync(tmp); } catch {}
    if (r === 'OK') { log('Printed via direct USB (' + portPath + ')'); return; }
    throw new Error(r);
  });
}

function sendViaSpooler(data, printerName) {
  const tmp = path.join(os.tmpdir(), 'lm_job_' + Date.now() + '.bin');
  fs.writeFileSync(tmp, data);
  const pn = printerName.replace(/'/g, "''");
  const pf = tmp.replace(/\\/g, '\\\\');
  return psRun([
    `$n='${pn}'; $f='${pf}'`,
    `$b=[IO.File]::ReadAllBytes($f)`,
    `Add-Type -TypeDefinition @"`,
    `using System;`,
    `using System.Runtime.InteropServices;`,
    `public class RawPrt{`,
    `  [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Ansi)]`,
    `  public class DI{[MarshalAs(UnmanagedType.LPStr)]public string n;[MarshalAs(UnmanagedType.LPStr)]public string o;[MarshalAs(UnmanagedType.LPStr)]public string t;}`,
    `  [DllImport("winspool.Drv",EntryPoint="OpenPrinterA")]public static extern bool OpenPrinter(string n,out IntPtr h,IntPtr d);`,
    `  [DllImport("winspool.Drv")]public static extern bool ClosePrinter(IntPtr h);`,
    `  [DllImport("winspool.Drv",EntryPoint="StartDocPrinterA")]public static extern bool StartDoc(IntPtr h,int l,[In,MarshalAs(UnmanagedType.LPStruct)]DI d);`,
    `  [DllImport("winspool.Drv")]public static extern bool EndDocPrinter(IntPtr h);`,
    `  [DllImport("winspool.Drv")]public static extern bool StartPagePrinter(IntPtr h);`,
    `  [DllImport("winspool.Drv")]public static extern bool EndPagePrinter(IntPtr h);`,
    `  [DllImport("winspool.Drv")]public static extern bool WritePrinter(IntPtr h,IntPtr p,int c,out int w);`,
    `  public static string Send(string name,byte[] data){`,
    `    IntPtr hP;if(!OpenPrinter(name,out hP,IntPtr.Zero))return "OPEN_FAIL:"+Marshal.GetLastWin32Error();`,
    `    var di=new DI{n="LM",t="RAW"};`,
    `    if(!StartDoc(hP,1,di)){ClosePrinter(hP);return "DOC_FAIL";}`,
    `    StartPagePrinter(hP);`,
    `    var ptr=Marshal.AllocCoTaskMem(data.Length);Marshal.Copy(data,0,ptr,data.Length);`,
    `    int w;bool ok=WritePrinter(hP,ptr,data.Length,out w);`,
    `    Marshal.FreeCoTaskMem(ptr);EndPagePrinter(hP);EndDocPrinter(hP);ClosePrinter(hP);`,
    `    return ok?"OK:"+w:"WRITE_FAIL:"+Marshal.GetLastWin32Error();`,
    `  }`,
    `}`,
    `"@`,
    `$r=[RawPrt]::Send($n,$b)`,
    `Remove-Item $f -Force -ErrorAction SilentlyContinue`,
    `Write-Output $r`,
  ]).then(r => {
    try { fs.unlinkSync(tmp); } catch {}
    if (r.startsWith('OK:')) return;
    if (r.startsWith('OPEN_FAIL')) { usbWinPrinter = null; }
    throw new Error('USB print failed: ' + r);
  });
}

// --- ESC/POS ------------------------------------------------------------------
const E = '\x1B', G = '\x1D';
const W = 48;
const FONT_NORMAL  = E + '!' + '\x00';
const FONT_BOLD    = E + '!' + '\x08';
const FONT_TITLE   = E + '!' + '\x10';
const FONT_LARGE   = E + '!' + '\x30';
const FONT_LARGE_B = E + '!' + '\x38';
const ALIGN_LEFT   = E + 'a' + '\x00';
const ALIGN_CENTER = E + 'a' + '\x01';
const ALIGN_RIGHT  = E + 'a' + '\x02';
const REVERSE_ON   = G + 'B' + '\x01';
const REVERSE_OFF  = G + 'B' + '\x00';
const FEED = (n) => E + 'd' + String.fromCharCode(n);
const CUT  = G + 'V' + '\x42' + '\x00';
const INIT = E + '@';

const qrcode = require('./qrcode.js');
const store  = require('./store.js');

// ─── OFFLINE-FIRST ACTIVE ORDERS ──────────────────────────────────────────────
// Local file tracks open orders per table. All ordering operations write here
// first, print locally, then sync to Supabase in the background. Survives
// full internet outages — the kitchen keeps getting tickets.
const ACTIVE_ORDERS_FILE = path.join(__dirname, 'active-orders.json');

function _loadActiveOrders() {
  try { const d = JSON.parse(fs.readFileSync(ACTIVE_ORDERS_FILE, 'utf8')); return d && typeof d === 'object' ? d : {}; }
  catch { return {}; }
}
function _saveActiveOrders(data) {
  try { fs.writeFileSync(ACTIVE_ORDERS_FILE, JSON.stringify(data)); } catch {}
}
function _activeOrder(tableNum) {
  return _loadActiveOrders()[String(tableNum)] || null;
}
function _saveActiveOrder(tableNum, order) {
  const all = _loadActiveOrders();
  all[String(tableNum)] = order;
  _saveActiveOrders(all);
}
function _removeActiveOrder(tableNum) {
  const all = _loadActiveOrders();
  delete all[String(tableNum)];
  _saveActiveOrders(all);
}

// Snapshot of what is open on THIS Station right now, for the AI.
//
// Why this exists: ordering is offline-first, so active-orders.json is the truth
// for open tables while Supabase is only a best-effort background mirror. An
// order that hasn't been SENT yet — or that was written during an internet cut —
// exists only here. The server agent used to answer purely from Supabase and so
// told the user "no tables are open" while the floor plan showed two. We ship
// this snapshot with every AI turn so the agent reads the same reality the
// waiter sees. Bounded on purpose: this goes into a model prompt.
const AI_STATE_MAX_TABLES = 60;
const AI_STATE_MAX_ITEMS = 40;

function _stationStateForAI() {
  const all = _loadActiveOrders();
  const tables = [];
  for (const key of Object.keys(all).slice(0, AI_STATE_MAX_TABLES)) {
    const o = all[key];
    if (!o || !Array.isArray(o.items)) continue;
    const items = o.items.filter(i => i && i.status !== 'cancelled_by_admin');
    if (!items.length) continue;
    const total = items.reduce((s, i) => s + (i.is_invitation ? 0 : (i.price_at_order_time || 0) * (i.quantity || 1)), 0);
    tables.push({
      table: Number(key) || key,
      order_id: o.order_id,
      guest_count: o.guest_count || 1,
      opened_at: o.created_at,
      total: Number(total.toFixed(2)),
      // Unsent items haven't reached the kitchen — the agent must not imply they have.
      all_sent: items.every(i => i.status !== 'pending'),
      items: items.slice(0, AI_STATE_MAX_ITEMS).map(i => ({
        name: i.menu_item_name || 'Item',
        qty: i.quantity || 1,
        price: i.price_at_order_time || 0,
        course: i.course || 'direct',
        status: i.status,
        special_requests: i.special_requests || undefined,
        is_invitation: i.is_invitation || undefined,
      })),
    });
  }
  tables.sort((a, b) => (Number(a.table) || 0) - (Number(b.table) || 0));
  return { currency: _getTicketSettings().currency || 'EUR', tables };
}

// Build the table list the Station UI renders (ordering selector + floor plan)
// from the `tables` rows plus every live signal about what's actually open.
//
// Pure so it can be tested without a server or Supabase.
//
//   rows           `tables` rows from Supabase (the floor LAYOUT)
//   localNums      table numbers with an open order in active-orders.json (live)
//   remoteOccupied table numbers with an open order in the cloud (live)
//   occupiedNums   table numbers with a ticket printed today (stale-prone: a
//                  closed table stays in here, so it only ever adds occupancy
//                  to a known row, and never conjures a table into the list)
//   heldTables     table numbers holding s1–s4 plates to reclaim (yellow)
function _mergeTablesView({ rows, localNums, occupiedNums, remoteOccupied, heldTables }) {
  const tables = (rows || []).map(t => ({
    id:               t.id,
    table_number:     t.table_number,
    status:           t.status || 'available',
    pos_x:            t.pos_x,
    pos_y:            t.pos_y,
    shape:            t.shape || 'square',
    zone:             t.zone || null,
    occupied:         localNums.has(String(t.table_number)) || occupiedNums.has(String(t.table_number)) || !!t.current_order_id || remoteOccupied.has(String(t.table_number)),
    has_held_items:   heldTables.has(String(t.table_number)),
    check_printed_at: t.check_printed_at || null,
  }));

  // A table with an open order but no `tables` row was invisible here — "Open
  // table" opens whatever number is typed in, so serving table 2 without it
  // being in the floor layout is normal, and it must still be reachable.
  // `virtual` marks a row with no `tables` record behind it: the floor-plan
  // editor skips these, since there is no id to move, rename or delete.
  const known = new Set((rows || []).map(t => String(t.table_number)));
  for (const n of new Set([...localNums, ...remoteOccupied])) {
    if (known.has(n)) continue;
    tables.push({
      id: null, table_number: Number.isFinite(Number(n)) ? Number(n) : n,
      status: 'occupied', pos_x: null, pos_y: null, shape: 'square', zone: null,
      occupied: true, has_held_items: heldTables.has(n),
      check_printed_at: null, virtual: true,
    });
  }

  // Stable numeric order so the selector reads T1, T2, T12 — not insertion order.
  tables.sort((a, b) => {
    const an = Number(a.table_number), bn = Number(b.table_number);
    if (Number.isFinite(an) && Number.isFinite(bn)) return an - bn;
    return String(a.table_number).localeCompare(String(b.table_number), undefined, { numeric: true });
  });
  return tables;
}

// ─── BILL → PDF ───────────────────────────────────────────────────────────────
// A hand-rolled PDF writer. No library: only main.js/store.js/qrcode.js reach an
// installed Station via the updater, so an npm dependency could never ship — and
// a bill is just text, which the PDF base fonts cover without embedding.
//
// Courier (a standard font, always present in readers) makes every glyph exactly
// 0.6em wide, so column alignment is arithmetic rather than a font-metrics table
// — and monospace is what a receipt should look like anyway.
const PDF_W    = 226.77;                        // 80mm in points, matching the roll
const PDF_M    = 12;                            // side margin
const PDF_FS   = 9;                             // font size
const PDF_CW   = PDF_FS * 0.6;                  // Courier advance per char
const PDF_COLS = Math.floor((PDF_W - PDF_M * 2) / PDF_CW);
const PDF_LH   = 11.5;                          // line height

// PDF text is WinAnsi here, so '€' and accented Spanish/French glyphs survive.
// Latin-1 matches WinAnsi from 0xA0 up; only 0x80–0x9F needs a map.
const WINANSI_EXTRA = {
  '€':0x80,'‚':0x82,'ƒ':0x83,'„':0x84,'…':0x85,'†':0x86,'‡':0x87,'ˆ':0x88,'‰':0x89,
  'Š':0x8A,'‹':0x8B,'Œ':0x8C,'Ž':0x8E,'‘':0x91,'’':0x92,'“':0x93,
  '”':0x94,'•':0x95,'–':0x96,'—':0x97,'˜':0x98,'™':0x99,'š':0x9A,'›':0x9B,
  'œ':0x9C,'ž':0x9E,'Ÿ':0x9F,
};
function _pdfBytes(s) {
  const out = [];
  for (const ch of String(s == null ? '' : s)) {
    const c = ch.codePointAt(0);
    if (c < 0x80) out.push(c);
    else if (WINANSI_EXTRA[ch] != null) out.push(WINANSI_EXTRA[ch]);
    else if (c >= 0xA0 && c <= 0xFF) out.push(c);
    else out.push(0x3F);                        // unrepresentable -> '?'
  }
  // \ ( ) are structural inside a PDF string literal.
  const esc = [];
  for (const b of out) {
    if (b === 0x5C || b === 0x28 || b === 0x29) esc.push(0x5C);
    esc.push(b);
  }
  return Buffer.from(esc);
}

// lines: [{ text, y, bold }] with y measured from the page BOTTOM, PDF-style.
function _pdfDoc(lines, pageH) {
  const chunks = [];
  for (const L of lines) {
    if (!L.text) continue;
    chunks.push(Buffer.from(`BT ${L.bold ? '/F2' : '/F1'} ${PDF_FS} Tf 1 0 0 1 ${PDF_M.toFixed(2)} ${L.y.toFixed(2)} Tm (`, 'latin1'));
    chunks.push(_pdfBytes(L.text));
    chunks.push(Buffer.from(') Tj ET\n', 'latin1'));
  }
  const content = Buffer.concat(chunks);
  const objs = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${PDF_W.toFixed(2)} ${pageH.toFixed(2)}] ` +
      `/Resources << /Font << /F1 4 0 R /F2 5 0 R >> >> /Contents 6 0 R >>`,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Courier-Bold /Encoding /WinAnsiEncoding >>',
    null,                                        // 6 = the content stream
  ];
  const parts = [Buffer.from('%PDF-1.4\n', 'latin1')];
  const offsets = [];
  let pos = parts[0].length;
  for (let i = 0; i < objs.length; i++) {
    offsets.push(pos);
    const b = (i === 5)
      ? Buffer.concat([
          Buffer.from(`6 0 obj\n<< /Length ${content.length} >>\nstream\n`, 'latin1'),
          content,
          Buffer.from('\nendstream\nendobj\n', 'latin1'),
        ])
      : Buffer.from(`${i + 1} 0 obj\n${objs[i]}\nendobj\n`, 'latin1');
    parts.push(b);
    pos += b.length;
  }
  // The xref offsets must be exact byte positions or readers reject the file.
  let xref = `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n`;
  for (const o of offsets) xref += String(o).padStart(10, '0') + ' 00000 n \n';
  xref += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${pos}\n%%EOF\n`;
  parts.push(Buffer.from(xref, 'latin1'));
  return Buffer.concat(parts);
}

// Lay the bill out as receipt rows, then render. Mirrors the printed check.
function _billRows(bill) {
  const C = PDF_COLS;
  const rows = [];
  const add  = (text, bold) => rows.push({ text: String(text ?? ''), bold: !!bold });
  const mid  = (t, bold) => add(center(String(t), C), bold);
  const fill = (l, r, bold) => {
    l = String(l); r = String(r);
    const gap = C - l.length - r.length;
    add(gap < 1 ? tr(l, Math.max(0, C - r.length - 1)) + ' ' + r : l + ' '.repeat(gap) + r, bold);
  };
  const sep = '-'.repeat(C);
  const cur = bill.currency;

  if (bill.restaurant) mid(bill.restaurant, true);
  if (bill.bill_number) mid(bill.bill_number, true);
  add('');
  if (bill.table != null) fill('Table', String(bill.table));
  if (bill.printed_at) {
    const d = new Date(bill.printed_at);
    if (!isNaN(d)) fill('Date', fmtDate(d, 'dd/MM/yyyy HH:mm'));
  }
  if (bill.waiter) fill('Waiter', tr(bill.waiter, C - 8));
  if (bill.guests) fill('Guests', String(bill.guests));
  add(sep);

  for (const it of (bill.items || [])) {
    const qty = Number(it.qty) || 1;
    const line = Number(it.price || 0) * qty;
    // Long names wrap rather than being cut: the price column must stay readable.
    const label = `${qty} x ${it.name}`;
    const right = it.is_invitation ? 'FREE' : fmtPrice(line, cur);
    if (label.length + right.length + 1 <= C) {
      fill(label, right);
    } else {
      add(tr(label, C));
      fill('', right);
    }
  }

  add(sep);
  fill('TOTAL', fmtPrice(bill.total, cur), true);
  if (bill.payment && bill.payment !== 'unspecified' && bill.payment !== 'unpaid') {
    add('');
    mid(`** ${String(bill.payment).toUpperCase()} **`, true);
  }
  add('');
  mid('LightMenu');
  return rows;
}

function _billPdf(bill) {
  const rows = _billRows(bill);
  const top = 16, bottom = 16;
  const pageH = top + bottom + rows.length * PDF_LH;
  let y = pageH - top - PDF_FS;
  const lines = rows.map(r => { const L = { text: r.text, bold: r.bold, y }; y -= PDF_LH; return L; });
  return _pdfDoc(lines, pageH);
}

function _getTicketSettings() {
  const cfg = printersCache.find(c => c.printer_type === 'kitchen' && c.is_active);
  return (cfg?.settings) || {};
}

// ─── Ordering core (shared by the POS HTTP endpoints and StationAI) ──────────
// Extracted so both the WPF Orders page and the AI drive the exact same
// offline-first path: local state first, always-local printing, best-effort
// background sync to Supabase.
async function stationSendOrder(tableNum, cartItems, guestCount) {
  guestCount = guestCount || 1;
  if (!tableNum || !Array.isArray(cartItems) || !cartItems.length) {
    throw new Error('table_number and items required');
  }
  // 1. Local state first — always succeeds
  let local = _activeOrder(tableNum);
  if (!local) {
    local = {
      order_id: 'local-' + crypto.randomUUID(),
      table_number: tableNum,
      guest_count: guestCount,
      items: [],
      synced: false,
      remote_order_id: null,
      created_at: new Date().toISOString(),
    };
  }
  const newItems = cartItems.map(i => ({
    id: 'li-' + crypto.randomUUID(),
    menu_item_id: i.menu_item_id || null,
    menu_item_name: i.menu_item_name || i.name || 'Item',
    price_at_order_time: i.price || 0,
    quantity: i.quantity || 1,
    status: (!i.course || i.course === 'direct') ? 'preparing' : 'pending',
    course: i.course || 'direct',
    special_requests: i.special_requests || null,
    is_invitation: i.is_invitation || false,
    selected_addons: i.selected_addons || null,
    synced: false,
  }));
  local.items = local.items.concat(newItems);
  _saveActiveOrder(tableNum, local);

  // 2. Print kitchen ticket for direct items — always local, but fire-and-forget.
  // We do NOT await the printer: a slow/unreachable printer must not block the
  // SEND response (that made the Station feel frozen for seconds). The order is
  // already saved locally; printing happens in the background and is logged.
  const directItems = cartItems.filter(i => !i.course || i.course === 'direct');
  if (directItems.length) {
    (async () => {
      try {
        const settings = _getTicketSettings();
        const ticket = {
          type: 'kitchen', restaurant_id: RESTAURANT_ID,
          restaurant_name: RESTAURANT_NAME, table_number: tableNum,
          waiter_name: 'Station', currency: settings.currency || 'EUR',
          time: new Date().toISOString(), order_id: local.order_id,
          items: directItems.map(i => ({
            name: i.menu_item_name || i.name || 'Item', qty: i.quantity || 1,
            price: i.price || 0, special_requests: i.special_requests,
            is_invitation: i.is_invitation, selected_addons: i.selected_addons,
          })),
          settings,
        };
        const data = buildKitchenTicket(ticket);
        const copies = settings.order_copies || 1;
        for (let i = 0; i < Math.min(copies, 3); i++) await sendToPrinter(data);
        printed++; updateDailyStats('printed');
        log('STATION ORDER: Mesa ' + tableNum + ' (' + directItems.length + ' direct items)');
      } catch (pe) { log('Station order print failed: ' + pe.message); }
    })();
  }

  // 3. Save to local store (analytics/bills)
  try {
    store.addOrder({
      order_id: local.order_id, date: new Date().toISOString(),
      table: tableNum, waiter: 'Station',
      items: cartItems.map(i => ({ name: i.menu_item_name || i.name, qty: i.quantity || 1, price: i.price || 0 })),
      printer_type: 'kitchen',
      total: cartItems.reduce((s, i) => s + (i.price || 0) * (i.quantity || 1), 0),
      guest_count: guestCount, currency: 'EUR', source: 'station',
    });
  } catch (_) {}

  // 4. Background sync to Supabase (non-blocking, best-effort)
  _syncOrderToSupabase(tableNum).catch(e => log('Sync failed (will retry): ' + e.message));

  return { ok: true, order_id: local.order_id, printed_now: directItems.length, held: newItems.length - directItems.length };
}

async function stationReclaimOrder(tableNum) {
  if (!tableNum) throw new Error('table_number required');
  // Reconcile with Supabase first so held courses added on ANY device (waiter
  // web/Flutter, or a Station fetch that beat the local save) are reclaimable —
  // reading only the local file would miss them and reclaim would do nothing.
  let local;
  try { local = await _pullOrderFromSupabase(tableNum); }
  catch { local = _activeOrder(tableNum); }
  if (!local) return { ok: false, error: 'No open order' };

  // Find next held course from local state
  const courseOrder = ['first_plate', 'second_plate', 'third_plate', 'fourth_plate'];
  let nextCourse = null;
  for (const c of courseOrder) {
    if (local.items.some(i => i.status === 'pending' && i.course === c)) { nextCourse = c; break; }
  }
  if (!nextCourse) return { ok: false, error: 'Nothing to reclaim' };

  // Update local state
  const courseItems = [];
  for (const item of local.items) {
    if (item.status === 'pending' && item.course === nextCourse) {
      item.status = 'preparing';
      item.synced = false;
      courseItems.push(item);
    }
  }
  _saveActiveOrder(tableNum, local);

  // Print kitchen ticket
  try {
    const settings = _getTicketSettings();
    const courseLbl = { first_plate: 'S1', second_plate: 'S2', third_plate: 'S3', fourth_plate: 'S4' }[nextCourse] || nextCourse;
    const ticket = {
      type: 'kitchen', restaurant_id: RESTAURANT_ID,
      restaurant_name: RESTAURANT_NAME, table_number: tableNum,
      waiter_name: 'Station', kitchen_name: courseLbl,
      currency: settings.currency || 'EUR',
      time: new Date().toISOString(), order_id: local.order_id,
      items: courseItems.map(i => ({
        name: i.menu_item_name || 'Item', qty: i.quantity || 1,
        price: i.price_at_order_time || 0, special_requests: i.special_requests,
        is_invitation: i.is_invitation,
        selected_addons: i.selected_addons ? (typeof i.selected_addons === 'string' ? JSON.parse(i.selected_addons) : i.selected_addons) : null,
      })),
      settings,
    };
    const data = buildKitchenTicket(ticket);
    const copies = settings.order_copies || 1;
    for (let j = 0; j < Math.min(copies, 3); j++) await sendToPrinter(data);
    printed++; updateDailyStats('printed');
    log('STATION RECLAIM: Mesa ' + tableNum + ' course=' + courseLbl + ' (' + courseItems.length + ' items)');
  } catch (pe) { log('Station reclaim print failed: ' + pe.message); }

  // Background sync
  _syncReclaimToSupabase(local, courseItems).catch(e => log('Reclaim sync failed: ' + e.message));

  return { ok: true, course: nextCourse, items: courseItems };
}

// `paymentMethod` ('cash' | 'card' | 'mixed') is optional but worth passing:
// without it the cloud row closes as merely 'paid' and the cash-vs-card split in
// Analytics silently loses the sale.
async function stationCloseOrder(tableNum, paymentMethod) {
  if (!tableNum) throw new Error('table_number required');
  // Remove from local active orders
  const local = _activeOrder(tableNum);
  if (!local) return { ok: true, had_order: false };
  _removeActiveOrder(tableNum);

  const pm = ['cash', 'card', 'mixed'].includes(paymentMethod) ? paymentMethod : null;

  // Background sync close to Supabase
  if (local?.remote_order_id) {
    (async () => {
      try {
        const patch = { status: 'paid' };
        if (pm) patch.payment_method = pm;
        await supabasePatch('orders', local.remote_order_id, patch);
        const tables = await supabaseGet('tables', { restaurant_id: RESTAURANT_ID, table_number: tableNum }, 1);
        if (tables?.length) await supabasePatch('tables', tables[0].id, { status: 'available', current_order_id: null });
      } catch (e) { log('Close sync failed: ' + e.message); }
    })();
  }
  return { ok: true, had_order: true, table: tableNum, payment_method: pm || 'unspecified' };
}

// Print the customer check for a table's open order. Reads local state (always
// available offline), builds a check ticket, prints it, and best-effort stamps
// check_printed_at on the table so the floor plan turns purple.
async function stationPrintCheck(tableNum) {
  if (!tableNum) throw new Error('table_number required');
  const local = _activeOrder(tableNum);
  if (!local || !Array.isArray(local.items) || !local.items.length) {
    return { ok: false, error: 'No open order for this table' };
  }
  const settings = _getTicketSettings();
  const items = local.items.map(i => ({
    name: i.menu_item_name || 'Item',
    qty: i.quantity || 1,
    price: i.price_at_order_time || 0,
    is_invitation: i.is_invitation,
    selected_addons: i.selected_addons
      ? (typeof i.selected_addons === 'string' ? JSON.parse(i.selected_addons) : i.selected_addons)
      : null,
  }));
  const total = items.reduce((s, i) => s + (i.is_invitation ? 0 : (i.price || 0) * (i.qty || 1)), 0);

  const ticket = {
    type: 'check', restaurant_id: RESTAURANT_ID, restaurant_name: RESTAURANT_NAME,
    table_number: tableNum, waiter_name: 'Station', currency: settings.currency || 'EUR',
    time: new Date().toISOString(), order_id: local.order_id,
    total, guest_count: local.guest_count || 1, items, settings,
  };
  try {
    const copies = settings.check_copies || 1;
    for (let i = 0; i < Math.min(copies, 3); i++) await sendToPrinter(buildCheckTicket(ticket));
    printed++; updateDailyStats('printed');
    log('STATION CHECK: Mesa ' + tableNum);
  } catch (pe) {
    log('Station check print failed: ' + pe.message);
    return { ok: false, error: 'Printer error: ' + pe.message };
  }

  // Stamp check_printed_at so the floor plan reflects it (best-effort).
  (async () => {
    try {
      const tables = await supabaseGet('tables', { restaurant_id: RESTAURANT_ID, table_number: tableNum }, 1);
      if (tables?.length) await supabasePatch('tables', tables[0].id, { check_printed_at: new Date().toISOString() });
    } catch (e) { log('Check stamp failed: ' + e.message); }
  })();

  return { ok: true };
}

// Void the whole open order for a table. Clears local state, prints a
// cancellation notice to the kitchen (so they stop cooking), and best-effort
// marks the remote order cancelled and frees the table.
async function stationCancelOrder(tableNum) {
  if (!tableNum) throw new Error('table_number required');
  const local = _activeOrder(tableNum);
  if (!local) return { ok: false, error: 'No open order for this table' };
  _removeActiveOrder(tableNum);

  // Kitchen cancellation ticket (best-effort — never blocks the void).
  try {
    const settings = _getTicketSettings();
    const ticket = {
      type: 'cancel', restaurant_id: RESTAURANT_ID, restaurant_name: RESTAURANT_NAME,
      table_number: tableNum, waiter_name: 'Station', cancelled_by: 'Station',
      currency: settings.currency || 'EUR', time: new Date().toISOString(),
      items: (local.items || []).map(i => ({ name: i.menu_item_name || 'Item', qty: i.quantity || 1 })),
      settings,
    };
    await sendToPrinter(buildCancelTicket(ticket));
  } catch (pe) { log('Cancel ticket print failed: ' + pe.message); }

  if (local.remote_order_id) {
    (async () => {
      try {
        await supabasePatch('orders', local.remote_order_id, { status: 'cancelled' });
        const tables = await supabaseGet('tables', { restaurant_id: RESTAURANT_ID, table_number: tableNum }, 1);
        if (tables?.length) await supabasePatch('tables', tables[0].id, { status: 'available', current_order_id: null });
      } catch (e) { log('Cancel sync failed: ' + e.message); }
    })();
  }
  return { ok: true, had_order: true };
}

// Move a table's open order to a different table number. Local state moves
// immediately; a transfer ticket prints; the remote order + both tables sync
// in the background.
async function stationTransferOrder(fromTable, toTable) {
  if (!fromTable || !toTable) throw new Error('from_table and to_table required');
  if (String(fromTable) === String(toTable)) return { ok: false, error: 'Same table' };
  const local = _activeOrder(fromTable);
  if (!local) return { ok: false, error: 'No open order on table ' + fromTable };
  if (_activeOrder(toTable)) return { ok: false, error: 'Table ' + toTable + ' already has an open order' };

  // Move locally.
  local.table_number = toTable;
  _removeActiveOrder(fromTable);
  _saveActiveOrder(toTable, local);

  // Transfer ticket (best-effort).
  try {
    const settings = _getTicketSettings();
    const ticket = {
      type: 'transfer', restaurant_id: RESTAURANT_ID, restaurant_name: RESTAURANT_NAME,
      from_table: fromTable, to_table: toTable, table_number: toTable, waiter_name: 'Station',
      currency: settings.currency || 'EUR', time: new Date().toISOString(),
      items: (local.items || []).map(i => ({ name: i.menu_item_name || 'Item', qty: i.quantity || 1 })),
      settings,
    };
    await sendToPrinter(buildTransferTicket(ticket));
  } catch (pe) { log('Transfer ticket print failed: ' + pe.message); }

  // Remote sync (best-effort).
  if (local.remote_order_id) {
    (async () => {
      try {
        await supabasePatch('orders', local.remote_order_id, { table_number: toTable });
        const fromT = await supabaseGet('tables', { restaurant_id: RESTAURANT_ID, table_number: fromTable }, 1);
        if (fromT?.length) await supabasePatch('tables', fromT[0].id, { status: 'available', current_order_id: null });
        const toT = await supabaseGet('tables', { restaurant_id: RESTAURANT_ID, table_number: toTable }, 1);
        if (toT?.length) await supabasePatch('tables', toT[0].id, { status: 'occupied', current_order_id: local.remote_order_id });
      } catch (e) { log('Transfer sync failed: ' + e.message); }
    })();
  }
  return { ok: true, from_table: fromTable, to_table: toTable };
}

// ─── Per-unit order actions (Cancel / Transfer / Invitation) ─────────────────
// These clone the waiter web app's TableActionsPopup: they act on individual
// units of sent/held items. Local state is authoritative for the Station UI;
// Supabase is patched best-effort. An item id that isn't a local 'li-' id is a
// real order_items row, so we can PATCH/POST it directly by id.
function _isRemoteId(id) { return typeof id === 'string' && id.length >= 30 && !id.startsWith('li-'); }

async function stationCancelItems(tableNum, selections) {
  if (!tableNum || !Array.isArray(selections) || !selections.length) throw new Error('table_number and items required');
  let local; try { local = await _pullOrderFromSupabase(tableNum); } catch { local = _activeOrder(tableNum); }
  if (!local) return { ok: false, error: 'No open order' };

  const cancelled = [];
  let removedTotal = 0;
  for (const sel of selections) {
    const item = local.items.find(i => String(i.id) === String(sel.id));
    if (!item) continue;
    const q = Math.min(Math.max(1, parseInt(sel.qty) || 0), item.quantity);
    if (q <= 0) continue;
    cancelled.push({ name: item.menu_item_name, qty: q });
    removedTotal += (item.price_at_order_time || 0) * q;
    if (q >= item.quantity) {
      if (_isRemoteId(item.id)) { try { await supabasePatch('order_items', item.id, { status: 'cancelled_by_admin' }); } catch {} }
      item._remove = true;
    } else {
      item.quantity -= q;
      if (_isRemoteId(item.id)) {
        try {
          await supabasePatch('order_items', item.id, { quantity: item.quantity });
          await supabasePost('order_items', {
            order_id: local.remote_order_id, menu_item_id: item.menu_item_id,
            menu_item_name: item.menu_item_name, price_at_order_time: item.price_at_order_time,
            quantity: q, special_requests: item.special_requests || null, course: item.course,
            status: 'cancelled_by_admin',
          });
        } catch {}
      }
    }
  }
  local.items = local.items.filter(i => !i._remove);
  _saveActiveOrder(tableNum, local);

  if (local.remote_order_id && removedTotal > 0) {
    (async () => { try { const o = await supabaseGet('orders', { id: local.remote_order_id }, 1); if (o?.[0]) await supabasePatch('orders', local.remote_order_id, { total_amount: Math.max(0, (o[0].total_amount || 0) - removedTotal) }); } catch {} })();
  }
  if (cancelled.length) {
    (async () => {
      try {
        const settings = _getTicketSettings();
        await sendToPrinter(buildCancelTicket({
          type: 'cancel', restaurant_id: RESTAURANT_ID, restaurant_name: RESTAURANT_NAME,
          table_number: tableNum, waiter_name: 'Station', cancelled_by: 'Station',
          currency: settings.currency || 'EUR', time: new Date().toISOString(),
          items: cancelled.map(c => ({ name: c.name, qty: c.qty })), settings,
        }));
      } catch (e) { log('Cancel ticket print failed: ' + e.message); }
    })();
  }
  return { ok: true, cancelled: cancelled.reduce((s, c) => s + c.qty, 0) };
}

async function stationInviteItems(tableNum, ids) {
  if (!tableNum || !Array.isArray(ids) || !ids.length) throw new Error('table_number and ids required');
  let local; try { local = await _pullOrderFromSupabase(tableNum); } catch { local = _activeOrder(tableNum); }
  if (!local) return { ok: false, error: 'No open order' };
  let n = 0, removedTotal = 0;
  for (const id of ids) {
    const item = local.items.find(i => String(i.id) === String(id));
    if (!item || item.is_invitation) continue;
    item.is_invitation = true; n++;
    removedTotal += (item.price_at_order_time || 0) * (item.quantity || 1);
    if (_isRemoteId(item.id)) { try { await supabasePatch('order_items', item.id, { is_invitation: true }); } catch {} }
  }
  _saveActiveOrder(tableNum, local);
  if (local.remote_order_id && removedTotal > 0) {
    (async () => { try { const o = await supabaseGet('orders', { id: local.remote_order_id }, 1); if (o?.[0]) await supabasePatch('orders', local.remote_order_id, { total_amount: Math.max(0, (o[0].total_amount || 0) - removedTotal) }); } catch {} })();
  }
  return { ok: true, invited: n };
}

async function stationTransferItems(fromTable, toTable, selections) {
  if (!fromTable || !toTable || !Array.isArray(selections) || !selections.length) throw new Error('from_table, to_table and items required');
  if (String(fromTable) === String(toTable)) return { ok: false, error: 'Same table' };
  let src; try { src = await _pullOrderFromSupabase(fromTable); } catch { src = _activeOrder(fromTable); }
  if (!src) return { ok: false, error: 'No open order on table ' + fromTable };

  // Find or create the target's remote order.
  let targetOrderId = null;
  try {
    const existing = await supabaseGetRaw(
      'orders?restaurant_id=eq.' + encodeURIComponent(RESTAURANT_ID) +
      '&table_number=eq.' + encodeURIComponent(toTable) +
      '&status=not.in.(paid,cancelled)&select=id&limit=1&order=created_at.desc');
    if (existing?.length) targetOrderId = existing[0].id;
    else {
      const rows = await supabasePost('orders', { restaurant_id: RESTAURANT_ID, table_number: toTable, waiter_id: 'station', waiter_name: 'Station', status: 'sent_to_kitchen', total_amount: 0, guest_count: 1 });
      targetOrderId = Array.isArray(rows) ? rows[0]?.id : rows?.id;
    }
  } catch {}

  const tgt = _activeOrder(toTable) || { order_id: 'local-' + crypto.randomUUID(), table_number: toTable, guest_count: 1, items: [], synced: false, remote_order_id: targetOrderId, created_at: new Date().toISOString() };
  if (targetOrderId) tgt.remote_order_id = targetOrderId;

  const moved = [];
  let movedTotal = 0;
  for (const sel of selections) {
    const item = src.items.find(i => String(i.id) === String(sel.id));
    if (!item) continue;
    const q = Math.min(Math.max(1, parseInt(sel.qty) || 0), item.quantity);
    if (q <= 0) continue;
    moved.push({ name: item.menu_item_name, qty: q });
    movedTotal += (item.price_at_order_time || 0) * q;
    if (q >= item.quantity) {
      if (_isRemoteId(item.id) && targetOrderId) { try { await supabasePatch('order_items', item.id, { order_id: targetOrderId }); } catch {} }
      tgt.items.push({ ...item, synced: _isRemoteId(item.id) });
      item._remove = true;
    } else {
      item.quantity -= q;
      let newRemoteId = null;
      if (targetOrderId) {
        try {
          const rows = await supabasePost('order_items', { order_id: targetOrderId, menu_item_id: item.menu_item_id, menu_item_name: item.menu_item_name, price_at_order_time: item.price_at_order_time, quantity: q, special_requests: item.special_requests || null, course: item.course, status: item.status || 'preparing', is_invitation: item.is_invitation || false, selected_addons: item.selected_addons || null });
          newRemoteId = Array.isArray(rows) ? rows[0]?.id : rows?.id;
        } catch {}
      }
      if (_isRemoteId(item.id)) { try { await supabasePatch('order_items', item.id, { quantity: item.quantity }); } catch {} }
      tgt.items.push({ id: newRemoteId || ('li-' + crypto.randomUUID()), menu_item_id: item.menu_item_id, menu_item_name: item.menu_item_name, price_at_order_time: item.price_at_order_time, quantity: q, status: item.status || 'preparing', course: item.course, special_requests: item.special_requests || null, is_invitation: item.is_invitation || false, selected_addons: item.selected_addons || null, synced: !!newRemoteId });
    }
  }
  src.items = src.items.filter(i => !i._remove);
  _saveActiveOrder(toTable, tgt);

  try { const tt = await supabaseGet('tables', { restaurant_id: RESTAURANT_ID, table_number: toTable }, 1); if (tt?.length) await supabasePatch('tables', tt[0].id, { status: 'occupied', current_order_id: targetOrderId }); } catch {}

  const sourceEmptied = src.items.length === 0;
  if (sourceEmptied) {
    _removeActiveOrder(fromTable);
    if (src.remote_order_id) { try { await supabasePatch('orders', src.remote_order_id, { status: 'cancelled', total_amount: 0 }); } catch {} }
    try { const st = await supabaseGet('tables', { restaurant_id: RESTAURANT_ID, table_number: fromTable }, 1); if (st?.length) await supabasePatch('tables', st[0].id, { status: 'available', current_order_id: null }); } catch {}
  } else {
    _saveActiveOrder(fromTable, src);
    if (src.remote_order_id) { try { const o = await supabaseGet('orders', { id: src.remote_order_id }, 1); if (o?.[0]) await supabasePatch('orders', src.remote_order_id, { total_amount: Math.max(0, (o[0].total_amount || 0) - movedTotal) }); } catch {} }
  }

  (async () => {
    try {
      const settings = _getTicketSettings();
      await sendToPrinter(buildTransferTicket({
        type: 'transfer', restaurant_id: RESTAURANT_ID, restaurant_name: RESTAURANT_NAME,
        from_table: fromTable, to_table: toTable, table_number: toTable, waiter_name: 'Station',
        currency: settings.currency || 'EUR', time: new Date().toISOString(),
        items: moved.map(m => ({ name: m.name, qty: m.qty })), settings,
      }));
    } catch (e) { log('Transfer ticket print failed: ' + e.message); }
  })();

  return { ok: true, moved: moved.reduce((s, m) => s + m.qty, 0), to_table: toTable, source_emptied: sourceEmptied };
}

async function _syncOrderToSupabase(tableNum) {
  const local = _activeOrder(tableNum);
  if (!local) return;

  let remoteId = local.remote_order_id;

  // Create or find remote order
  if (!remoteId) {
    try {
      const existing = await supabaseGetRaw(
        'orders?restaurant_id=eq.' + encodeURIComponent(RESTAURANT_ID) +
        '&table_number=eq.' + encodeURIComponent(tableNum) +
        '&status=not.in.(paid,cancelled)&select=id&limit=1&order=created_at.desc'
      );
      if (existing?.length) {
        remoteId = existing[0].id;
      } else {
        const total = local.items.reduce((s, i) => s + (i.price_at_order_time || 0) * (i.quantity || 1), 0);
        const rows = await supabasePost('orders', {
          restaurant_id: RESTAURANT_ID, table_number: tableNum,
          waiter_id: 'station', waiter_name: 'Station',
          status: 'sent_to_kitchen', total_amount: total,
          guest_count: local.guest_count || 1,
        });
        remoteId = Array.isArray(rows) ? rows[0]?.id : rows?.id;
      }
    } catch { return; } // offline — will retry later
  }
  if (!remoteId) return;

  local.remote_order_id = remoteId;

  // Sync unsynced items
  for (const item of local.items) {
    if (item.synced) continue;
    try {
      await supabasePost('order_items', {
        order_id: remoteId, menu_item_id: item.menu_item_id,
        menu_item_name: item.menu_item_name, price_at_order_time: item.price_at_order_time,
        quantity: item.quantity, status: item.status, course: item.course,
        special_requests: item.special_requests, is_invitation: item.is_invitation,
        selected_addons: item.selected_addons,
      });
      item.synced = true;
    } catch { break; } // offline — stop trying
  }

  // Mark table occupied
  try {
    const tables = await supabaseGet('tables', { restaurant_id: RESTAURANT_ID, table_number: tableNum }, 1);
    if (tables?.length) await supabasePatch('tables', tables[0].id, { status: 'occupied', current_order_id: remoteId });
  } catch {}

  local.synced = local.items.every(i => i.synced);
  _saveActiveOrder(tableNum, local);
  log('Sync OK: Mesa ' + tableNum + ' → remote ' + remoteId);
}

async function _syncReclaimToSupabase(local, courseItems) {
  if (!local?.remote_order_id) return;
  // Find remote items by matching order_id + course + name and update status
  try {
    const remoteItems = await supabaseGetRaw(
      'order_items?order_id=eq.' + encodeURIComponent(local.remote_order_id) +
      '&status=eq.pending&select=id,course,menu_item_name&limit=500'
    );
    if (!remoteItems?.length) return;
    for (const ci of courseItems) {
      const match = remoteItems.find(r => r.course === ci.course && r.menu_item_name === ci.menu_item_name);
      if (match) await supabasePatch('order_items', match.id, { status: 'preparing' });
    }
  } catch (e) { log('Reclaim sync to Supabase failed: ' + e.message); }
}

// Pull the current OPEN order for a table FROM Supabase into local state. This
// is the read-side counterpart to _syncOrderToSupabase (the write side): it is
// what makes orders taken on the waiter web/Flutter apps appear on the Station,
// and keeps status changes made there (reclaimed courses, added items) in sync.
//
// Merge rule: Supabase is authoritative for the items it knows about. Any local
// items still flagged unsynced (added on the Station while offline and not yet
// pushed) are preserved on top, so nothing typed on the Station is ever lost.
// On any network error we fall back to whatever local state we have — the
// Station keeps working fully offline.
async function _pullOrderFromSupabase(tableNum) {
  let remoteOrder = null;
  try {
    const orders = await supabaseGetRaw(
      'orders?restaurant_id=eq.' + encodeURIComponent(RESTAURANT_ID) +
      '&table_number=eq.' + encodeURIComponent(tableNum) +
      '&status=not.in.(paid,cancelled)&select=id,guest_count&limit=1&order=created_at.desc'
    );
    remoteOrder = (orders && orders.length) ? orders[0] : null;
  } catch { return _activeOrder(tableNum); }   // offline — trust local

  // No open order in Supabase for this table → nothing to merge; local wins.
  if (!remoteOrder) return _activeOrder(tableNum);

  let remoteItems = [];
  try {
    remoteItems = await supabaseGetRaw(
      'order_items?order_id=eq.' + encodeURIComponent(remoteOrder.id) +
      '&select=id,menu_item_id,menu_item_name,price_at_order_time,quantity,status,course,special_requests,is_invitation,selected_addons&limit=500'
    ) || [];
  } catch { return _activeOrder(tableNum); }

  const local = _activeOrder(tableNum);
  // Local items not yet pushed to Supabase — keep them (offline-added).
  const pendingLocal = (local && Array.isArray(local.items)) ? local.items.filter(i => !i.synced) : [];

  const merged = {
    order_id:        (local && local.order_id) || ('local-' + remoteOrder.id),
    table_number:    tableNum,
    guest_count:     remoteOrder.guest_count || (local && local.guest_count) || 1,
    remote_order_id: remoteOrder.id,
    created_at:      (local && local.created_at) || new Date().toISOString(),
    synced:          pendingLocal.length === 0,
    items: remoteItems.map(r => ({
      id:                  r.id,
      menu_item_id:        r.menu_item_id || null,
      menu_item_name:      r.menu_item_name || 'Item',
      price_at_order_time: r.price_at_order_time || 0,
      quantity:            r.quantity || 1,
      status:              r.status || 'preparing',
      course:              r.course || 'direct',
      special_requests:    r.special_requests || null,
      is_invitation:       r.is_invitation || false,
      selected_addons:     r.selected_addons || null,
      synced:              true,
    })).concat(pendingLocal),
  };
  _saveActiveOrder(tableNum, merged);
  return merged;
}

// Periodic sync: retry any unsynced active orders every 30s
setInterval(() => {
  const all = _loadActiveOrders();
  for (const tableNum of Object.keys(all)) {
    if (!all[tableNum].synced) {
      _syncOrderToSupabase(tableNum).catch(() => {});
    }
  }
}, 30000);

// ─── MULTI-LANGUAGE ENCODING ──────────────────────────────────────────────────
// Thermal printers use ESC/POS, which is byte-based. JS strings are Unicode.
// Buffer.from(s, 'binary') = Latin-1 — safe for ASCII/ESC commands, but silently
// mangles any character above U+00FF (Cyrillic, Arabic, CJK). This block detects
// the dominant script in the ticket text and encodes accordingly.

/** Scan strings to detect dominant non-Latin script. */
function detectScript(...texts) {
  let cyr = 0, arb = 0, cjk = 0;
  for (const t of texts) {
    if (!t) continue;
    for (const ch of String(t)) {
      const cp = ch.codePointAt(0);
      if (cp >= 0x0400 && cp <= 0x04FF) cyr++;
      else if (cp >= 0x0600 && cp <= 0x06FF) arb++;
      else if (cp >= 0x3000 && cp <= 0x9FFF) cjk++;
    }
  }
  const m = Math.max(cyr, arb, cjk);
  if (m === 0) return 'latin';
  if (arb === m) return 'arabic';
  if (cyr === m) return 'cyrillic';
  return 'cjk';
}

/** Collect all renderable text from a ticket for script detection. */
function ticketScript(t) {
  const items = t.items || [];
  const s = t.settings || {};
  // s.labels holds the user-translated UI strings ("Стол", "Mesa", etc.).
  // Scan ALL its values, not just the few hand-picked fields — otherwise a
  // ticket with Latin item names but Cyrillic labels falls back to 'latin'
  // and the labels get truncated to ASCII garbage.
  return detectScript(
    t.restaurant_name, t.waiter_name, t.cancelled_by,
    t.restaurant_address, s.kitchen_footer_text, s.check_footer_text,
    ...Object.values(s.labels || {}),
    ...items.map(i => i.name),
    ...items.map(i => i.special_requests || ''),
    ...items.flatMap(i => (i.selected_addons || []).map(a => a.name)),
    ...items.flatMap(i => (i.addons || []).map(a => a.name))
  );
}

/** ESC/POS code page select — emitted after INIT, before any text. */
function codePageHeader(script) {
  if (script === 'cyrillic') return '\x1B\x74\x11'; // ESC t 17 — CP866 Cyrillic
  return ''; // arabic/cjk/latin: rely on printer's default UTF-8 / Latin-1 mode
}

/** Unicode codepoint → CP866 byte. Returns 0x3F ('?') for unmapped chars. */
function cp866(cp) {
  if (cp < 0x80)                    return cp;
  if (cp >= 0x0410 && cp <= 0x042F) return cp - 0x0410 + 0x80; // А–Я  → 0x80–0x9F
  if (cp >= 0x0430 && cp <= 0x043F) return cp - 0x0430 + 0xA0; // а–п  → 0xA0–0xAF
  if (cp >= 0x0440 && cp <= 0x044F) return cp - 0x0440 + 0xE0; // р–я  → 0xE0–0xEF
  if (cp === 0x0401)                 return 0xF0;               // Ё
  if (cp === 0x0451)                 return 0xF1;               // ё
  if (cp === 0x2116)                 return 0xFC;               // №
  return 0x3F;
}

// Arabic letter forms lookup: codepoint → [isolated, final, initial, medial]
const AR_FORMS = {
  0x0621:[0xFE80,0xFE80,0xFE80,0xFE80], 0x0622:[0xFE81,0xFE82,0xFE81,0xFE82],
  0x0623:[0xFE83,0xFE84,0xFE83,0xFE84], 0x0624:[0xFE85,0xFE86,0xFE85,0xFE86],
  0x0625:[0xFE87,0xFE88,0xFE87,0xFE88], 0x0626:[0xFE89,0xFE8A,0xFE8B,0xFE8C],
  0x0627:[0xFE8D,0xFE8E,0xFE8D,0xFE8E], 0x0628:[0xFE8F,0xFE90,0xFE91,0xFE92],
  0x0629:[0xFE93,0xFE94,0xFE93,0xFE94], 0x062A:[0xFE95,0xFE96,0xFE97,0xFE98],
  0x062B:[0xFE99,0xFE9A,0xFE9B,0xFE9C], 0x062C:[0xFE9D,0xFE9E,0xFE9F,0xFEA0],
  0x062D:[0xFEA1,0xFEA2,0xFEA3,0xFEA4], 0x062E:[0xFEA5,0xFEA6,0xFEA7,0xFEA8],
  0x062F:[0xFEA9,0xFEAA,0xFEA9,0xFEAA], 0x0630:[0xFEAB,0xFEAC,0xFEAB,0xFEAC],
  0x0631:[0xFEAD,0xFEAE,0xFEAD,0xFEAE], 0x0632:[0xFEAF,0xFEB0,0xFEAF,0xFEB0],
  0x0633:[0xFEB1,0xFEB2,0xFEB3,0xFEB4], 0x0634:[0xFEB5,0xFEB6,0xFEB7,0xFEB8],
  0x0635:[0xFEB9,0xFEBA,0xFEBB,0xFEBC], 0x0636:[0xFEBD,0xFEBE,0xFEBF,0xFEC0],
  0x0637:[0xFEC1,0xFEC2,0xFEC3,0xFEC4], 0x0638:[0xFEC5,0xFEC6,0xFEC7,0xFEC8],
  0x0639:[0xFEC9,0xFECA,0xFECB,0xFECC], 0x063A:[0xFECD,0xFECE,0xFECF,0xFED0],
  0x0641:[0xFED1,0xFED2,0xFED3,0xFED4], 0x0642:[0xFED5,0xFED6,0xFED7,0xFED8],
  0x0643:[0xFED9,0xFEDA,0xFEDB,0xFEDC], 0x0644:[0xFEDD,0xFEDE,0xFEDF,0xFEE0],
  0x0645:[0xFEE1,0xFEE2,0xFEE3,0xFEE4], 0x0646:[0xFEE5,0xFEE6,0xFEE7,0xFEE8],
  0x0647:[0xFEE9,0xFEEA,0xFEEB,0xFEEC], 0x0648:[0xFEED,0xFEEE,0xFEED,0xFEEE],
  0x0649:[0xFEEF,0xFEF0,0xFEEF,0xFEF0], 0x064A:[0xFEF1,0xFEF2,0xFEF3,0xFEF4],
};
// Letters that don't connect on their left side (right-joining only)
const AR_RJ = new Set([0x0621,0x0622,0x0623,0x0624,0x0625,0x0627,0x0629,
                        0x062F,0x0630,0x0631,0x0632,0x0648,0x0649]);

/** Reshape Arabic text: choose the correct letter form based on context. */
function reshapeArabic(text) {
  const cps = [...text].map(c => c.codePointAt(0));
  return cps.map((cp, i) => {
    const f = AR_FORMS[cp];
    if (!f) return String.fromCodePoint(cp);
    let prev = false, next = false;
    for (let j = i - 1; j >= 0; j--) {
      const p = cps[j];
      if (p >= 0x064B && p <= 0x065F) continue; // skip diacritics
      prev = AR_FORMS[p] !== undefined && !AR_RJ.has(p); break;
    }
    for (let j = i + 1; j < cps.length; j++) {
      const n = cps[j];
      if (n >= 0x064B && n <= 0x065F) continue;
      next = AR_FORMS[n] !== undefined; break;
    }
    const idx = prev && next ? 3 : prev ? 1 : next ? 2 : 0;
    return String.fromCodePoint(f[idx]);
  }).join('');
}

/**
 * Reverse a single line's Arabic content for RTL display. Any leading non-Arabic
 * characters (whitespace, "2x ", "[INVIT] ") stay at the left margin so layout
 * alignment is preserved.
 */
function rtlLine(line) {
  if (!/[؀-ۿ]/.test(line)) return line;
  const m = line.match(/^([^؀-ۿ]*)([\s\S]*?)([^؀-ۿ]*)$/);
  if (!m) return line;
  const [, head, mid, tail] = m;
  return head + [...reshapeArabic(mid)].reverse().join('') + tail;
}

/**
 * Convert a ticket string to a printable Buffer with script-aware encoding.
 *
 * - ESC/POS control bytes (codepoint ≤ 0xFF) always pass through as raw bytes.
 * - latin    → Buffer.from(b, 'binary')  (unchanged from v6.0.2 behaviour)
 * - cyrillic → CP866 byte per character (printer is in CP866 mode via ESC t 17)
 * - arabic   → reshape + RTL-reverse per line, then UTF-8
 * - cjk      → UTF-8 (works on printers with built-in CJK font)
 */
function toBuffer(b, script) {
  if (script === 'latin') return Buffer.from(b, 'binary');

  if (script === 'arabic') {
    b = b.split('\n').map(rtlLine).join('\n');
  }

  const bytes = [];
  for (const ch of b) {
    const cp = ch.codePointAt(0);
    if (cp <= 0xFF) {
      bytes.push(cp); // ASCII + ESC/POS command bytes pass through unchanged
    } else if (script === 'cyrillic') {
      bytes.push(cp866(cp));
    } else {
      // arabic (Presentation Forms FE70–FEFF) and cjk: encode as UTF-8
      const utf = Buffer.from(ch, 'utf8');
      for (const byte of utf) bytes.push(byte);
    }
  }
  return Buffer.from(bytes);
}
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Build an ESC/POS raster ticket from a pre-rendered 1-bit bitmap.
 *
 * The web app rasterises tickets containing non-Latin/Cyrillic text (Arabic,
 * CJK, Hebrew, Thai) on a <canvas> because the printer firmware has no font
 * ROM for those scripts. We get the resulting bitmap as base64-encoded
 * packed bytes (MSB-first, row-major) plus its dimensions, and emit the
 * exact byte stream the printer's `GS v 0` raster command expects.
 *
 * Wrapped with INIT + line feeds + CUT so it prints as a complete ticket,
 * not a hanging image. Returns null if anything looks malformed — callers
 * fall back to the text path.
 *
 * @param {string} b64        base64 of the packed bitmap bytes
 * @param {number} widthDots  width in pixels (must be multiple of 8)
 * @param {number} height     height in pixels
 */
function buildRasterTicket(b64, widthDots, height) {
  if (!b64 || !widthDots || !height) return null;
  let buf;
  try { buf = Buffer.from(b64, 'base64'); }
  catch (e) { log('Raster decode failed: ' + e.message); return null; }

  const bytesPerRow = widthDots >> 3;
  const expected = bytesPerRow * height;
  if (buf.length !== expected) {
    log('Raster size mismatch — expected ' + expected + ' bytes, got ' + buf.length + '. Falling back to text path.');
    return null;
  }

  // GS v 0 m xL xH yL yH d1...dk
  //   m   = 0 (normal — no horizontal/vertical doubling)
  //   xL/xH = width in BYTES, little-endian
  //   yL/yH = height in DOTS, little-endian
  const xL = bytesPerRow & 0xFF, xH = (bytesPerRow >> 8) & 0xFF;
  const yL = height & 0xFF,      yH = (height >> 8) & 0xFF;
  const rasterCmd = Buffer.from([0x1D, 0x76, 0x30, 0x00, xL, xH, yL, yH]);

  // Wrap with init + a few line feeds + cut so it prints as a finished ticket.
  // INIT and CUT are pure ASCII control bytes; safe to emit as latin1 bytes.
  // FEED(1) here is INTENTIONALLY shorter than the kitchen/text builders'
  // FEED(4): the rasterised bitmap already includes its own bottom padding
  // sized in the web app, so emitting extra paper here would leave a visible
  // white gap below the QR before the cut. This is the RASTER path only —
  // text-mode Spanish/English/French bills still use their original FEED.
  const init   = Buffer.from(INIT,    'binary');
  const center = Buffer.from(ALIGN_CENTER, 'binary');
  const feed   = Buffer.from(FEED(1), 'binary');
  const cut    = Buffer.from(CUT,     'binary');
  return Buffer.concat([init, center, rasterCmd, buf, feed, cut]);
}

function qrToRaster(text) {
  if (!text || typeof text !== 'string') return null;
  let qr;
  try { qr = qrcode(0, 'M'); qr.addData(text); qr.make(); } catch (e) { return null; }
  const modules = qr.getModuleCount();
  // Keep the printed QR a consistent, compact footprint no matter how much
  // data it encodes. The self-contained bill URL has far more data than the
  // old short token, which at a fixed scale printed a huge code. Target a
  // fixed width and shrink the per-module scale for denser codes (min 2 so it
  // stays scannable). Small codes (e.g. the old token) keep the original
  // SCALE 4, so they look exactly like before.
  const TARGET_PX = 220;
  const SCALE = Math.max(2, Math.min(4, Math.floor(TARGET_PX / modules)));
  const pixelW = modules * SCALE, pixelH = modules * SCALE;
  const padW = ((pixelW + 7) & ~7);
  const bytesPerRow = padW >> 3;
  const buf = Buffer.alloc(bytesPerRow * pixelH, 0);
  for (let r = 0; r < modules; r++) {
    for (let c = 0; c < modules; c++) {
      if (!qr.isDark(r, c)) continue;
      for (let dy = 0; dy < SCALE; dy++) {
        const y = r * SCALE + dy;
        const rowOff = y * bytesPerRow;
        for (let dx = 0; dx < SCALE; dx++) {
          const x = c * SCALE + dx;
          buf[rowOff + (x >> 3)] |= (0x80 >> (x & 7));
        }
      }
    }
  }
  const xL = bytesPerRow & 0xFF, xH = (bytesPerRow >> 8) & 0xFF;
  const yL = pixelH & 0xFF, yH = (pixelH >> 8) & 0xFF;
  const header = Buffer.from([0x1D, 0x76, 0x30, 0x00, xL, xH, yL, yH]);
  return Buffer.concat([header, buf]);
}

function igHandle(url) {
  if (!url) return '';
  let s = String(url).trim();
  s = s.replace(/^https?:\/\/(www\.)?instagram\.com\//i, '').replace(/^@/, '').split(/[/?#]/)[0];
  return s || '';
}

function getAddons(item) {
  if (Array.isArray(item.selected_addons) && item.selected_addons.length) return item.selected_addons;
  if (Array.isArray(item.addons) && item.addons.length) return item.addons;
  return [];
}

function sepLine(style) {
  if (style === 'dashes') return '-'.repeat(W);
  if (style === 'stars')  return '*'.repeat(W);
  if (style === 'dots')   return '.'.repeat(W);
  return '='.repeat(W);
}

function resolveCurrency(c) {
  const m = {EUR:'EUR',USD:'$',GBP:'GBP',TND:'DT',MAD:'MAD',DZD:'DZD',CHF:'CHF',CAD:'CAD',AUD:'AUD',JPY:'JPY',CNY:'CNY'};
  if (c && c.length <= 3 && !m[c]) return c;
  return m[c] || c || 'EUR';
}
function fmtPrice(amount, currency) {
  const sym = resolveCurrency(currency);
  const val = Number(amount || 0).toFixed(2);
  return (sym.length > 1 ? sym + ' ' : sym) + val;
}
function tr(s, m) { s = String(s || ''); return s.length > m ? s.slice(0, m) : s; }
function center(text, w) { w = w || W; text = tr(text, w); const p = Math.floor((w - text.length) / 2); return ' '.repeat(Math.max(0, p)) + text; }
function fillLine(left, right) { const dots = W - left.length - right.length; if (dots <= 0) return tr(left, W - right.length) + right; return left + ' '.repeat(dots) + right; }
function padLR(l, r) { const sp = W - l.length - r.length; return l + ' '.repeat(sp < 1 ? 1 : sp) + r; }
function fmtDate(d, fmt) {
  const days=['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];
  const dd=String(d.getDate()).padStart(2,'0');
  const mm=String(d.getMonth()+1).padStart(2,'0');
  const yyyy=d.getFullYear();
  switch (fmt) {
    case 'MM/DD/YYYY': return days[d.getDay()]+' '+mm+'/'+dd+'/'+yyyy;
    case 'YYYY-MM-DD': return days[d.getDay()]+' '+yyyy+'-'+mm+'-'+dd;
    case 'DD/MM/YYYY':
    default:           return days[d.getDay()]+' '+dd+'/'+mm+'/'+yyyy;
  }
}
function fmtTime(d, fmt) {
  let h=d.getHours();
  const m=String(d.getMinutes()).padStart(2,'0');
  if (fmt === '12h') {
    const ampm = h>=12 ? 'PM' : 'AM';
    h = h % 12 || 12;
    return h+':'+m+' '+ampm;
  }
  return String(h).padStart(2,'0')+':'+m;
}
// lbl(s, key, fallback) — single source for translated labels on the agent
function lbl(s, key, fb) {
  const v = s && s.labels && s.labels[key];
  return (v && String(v).trim()) ? v : fb;
}
// Logo prefix — prepends raster bytes when configured
function logoBytes(s) {
  if (!s || !s.logo_print_enabled || !s.logo_raster_b64) return null;
  try { return Buffer.from(s.logo_raster_b64, 'base64'); } catch { return null; }
}

function zonePrefix(s, defaults) {
  defaults = defaults || {};
  const size  = (s.size  && s.size  !== '') ? s.size  : (defaults.size  || '');
  const bold  = (s.bold  && s.bold  !== '') ? s.bold  : (defaults.bold  || '');
  const align = (s.align && s.align !== '') ? s.align : (defaults.align || '');
  const bg    = s.bg || defaults.bg || 'transparent';
  let out = '';
  if (align === 'center') out += ALIGN_CENTER;
  else if (align === 'right') out += ALIGN_RIGHT;
  else out += ALIGN_LEFT;
  if      (size === 'L') out += (bold === 'bold') ? FONT_LARGE_B : FONT_LARGE;
  else if (size === 'M') out += FONT_TITLE + (bold === 'bold' ? FONT_BOLD : '');
  else if (size === 'S') out += FONT_NORMAL + (bold === 'bold' ? FONT_BOLD : '');
  else                   out += (bold === 'bold') ? FONT_BOLD : FONT_NORMAL;
  if (bg && bg !== 'transparent' && bg !== '' && bg !== '#ffffff' && bg !== '#fff') {
    const hex = bg.replace('#', '');
    if (hex.length >= 6) {
      const r = parseInt(hex.slice(0,2),16), g = parseInt(hex.slice(2,4),16), bl = parseInt(hex.slice(4,6),16);
      if (0.299*r + 0.587*g + 0.114*bl < 128) out += REVERSE_ON;
    }
  }
  return out;
}
function zoneSuffix() { return REVERSE_OFF + FONT_NORMAL + ALIGN_LEFT; }

// ── Ticket label translations (ported from web lib/ticketTranslations.js) ────
// The agent resolves the language → printed labels at save time and stores the
// result in settings.labels, which the ticket builders read as s.labels?.X.
const TICKET_LABEL_KEYS = [
  'table','waiter','date','time','covers','total','cancelled','cancelled_by',
  'transfer','from','to','thank_you','tel','split','persons','per_person',
  'cash','card','mixed','invitation','gratis','drinks','food','order_details',
  'scan_to_save','vat_incl',
];
const TICKET_LABELS = {
  en: { table:'Table', waiter:'Waiter', date:'Date', time:'Time', covers:'Covers', total:'TOTAL', cancelled:'!! CANCELLED !!', cancelled_by:'Cancelled by', transfer:'** TRANSFER **', from:'FROM', to:'TO', thank_you:'Thank you for your visit!', tel:'Tel', split:'Split', persons:'persons', per_person:'per person', cash:'** CASH **', card:'** CARD **', mixed:'** CASH + CARD **', invitation:'[INVIT]', gratis:'[GRATIS]', drinks:'-- DRINKS --', food:'-- MENU --', order_details:'- ORDER DETAILS -', scan_to_save:'Scan to save this bill:', vat_incl:'(VAT incl.)' },
  fr: { table:'Table', waiter:'Serveur', date:'Date', time:'Heure', covers:'Couverts', total:'TOTAL', cancelled:'!! ANNULÉ !!', cancelled_by:'Annulé par', transfer:'** TRANSFERT **', from:'DE', to:'VERS', thank_you:'Merci de votre visite !', tel:'Tél', split:'Partage', persons:'personnes', per_person:'par personne', cash:'** ESPÈCES **', card:'** CARTE **', mixed:'** ESPÈCES + CARTE **', invitation:'[OFFERT]', gratis:'[OFFERT]', drinks:'-- BOISSONS --', food:'-- MENU --', order_details:'- DÉTAILS DE LA COMMANDE -', scan_to_save:"Scannez pour sauvegarder l'addition :", vat_incl:'(TVA incluse)' },
  es: { table:'Mesa', waiter:'Camarero', date:'Fecha', time:'Hora', covers:'Comensales', total:'TOTAL', cancelled:'!! CANCELADO !!', cancelled_by:'Cancelado por', transfer:'** TRANSFERIDO **', from:'DESDE', to:'A', thank_you:'¡Gracias por su visita!', tel:'Tel', split:'Dividir', persons:'personas', per_person:'por persona', cash:'** EFECTIVO **', card:'** TARJETA **', mixed:'** EFECTIVO + TARJETA **', invitation:'[INVIT]', gratis:'[GRATIS]', drinks:'-- BEBIDAS --', food:'-- MENÚ --', order_details:'- DETALLES DEL PEDIDO -', scan_to_save:'Escanee para guardar el ticket:', vat_incl:'(IVA incl.)' },
  it: { table:'Tavolo', waiter:'Cameriere', date:'Data', time:'Ora', covers:'Coperti', total:'TOTALE', cancelled:'!! ANNULLATO !!', cancelled_by:'Annullato da', transfer:'** TRASFERITO **', from:'DA', to:'A', thank_you:'Grazie per la sua visita!', tel:'Tel', split:'Dividi', persons:'persone', per_person:'a persona', cash:'** CONTANTI **', card:'** CARTA **', mixed:'** CONTANTI + CARTA **', invitation:'[OMAGGIO]', gratis:'[OMAGGIO]', drinks:'-- BEVANDE --', food:'-- MENÙ --', order_details:'- DETTAGLI ORDINE -', scan_to_save:'Scansiona per salvare lo scontrino:', vat_incl:'(IVA incl.)' },
  de: { table:'Tisch', waiter:'Kellner', date:'Datum', time:'Zeit', covers:'Gäste', total:'GESAMT', cancelled:'!! STORNIERT !!', cancelled_by:'Storniert von', transfer:'** ÜBERTRAGEN **', from:'VON', to:'NACH', thank_you:'Vielen Dank für Ihren Besuch!', tel:'Tel', split:'Aufteilen', persons:'Personen', per_person:'pro Person', cash:'** BAR **', card:'** KARTE **', mixed:'** BAR + KARTE **', invitation:'[EINLADUNG]', gratis:'[GRATIS]', drinks:'-- GETRÄNKE --', food:'-- SPEISEN --', order_details:'- BESTELLDETAILS -', scan_to_save:'Scannen zum Speichern der Rechnung:', vat_incl:'(inkl. MwSt.)' },
  nl: { table:'Tafel', waiter:'Ober', date:'Datum', time:'Tijd', covers:'Gasten', total:'TOTAAL', cancelled:'!! GEANNULEERD !!', cancelled_by:'Geannuleerd door', transfer:'** OVERGEZET **', from:'VAN', to:'NAAR', thank_you:'Bedankt voor uw bezoek!', tel:'Tel', split:'Splitsen', persons:'personen', per_person:'per persoon', cash:'** CONTANT **', card:'** PIN **', mixed:'** CONTANT + PIN **', invitation:'[GRATIS]', gratis:'[GRATIS]', drinks:'-- DRANKEN --', food:'-- MENU --', order_details:'- BESTELDETAILS -', scan_to_save:'Scan om de rekening op te slaan:', vat_incl:'(incl. BTW)' },
  ru: { table:'Стол', waiter:'Официант', date:'Дата', time:'Время', covers:'Гостей', total:'ИТОГО', cancelled:'!! ОТМЕНЕНО !!', cancelled_by:'Отменил', transfer:'** ПЕРЕНОС **', from:'ОТ', to:'К', thank_you:'Спасибо за визит!', tel:'Тел', split:'Разделить', persons:'персон', per_person:'на персону', cash:'** НАЛИЧНЫЕ **', card:'** КАРТА **', mixed:'** НАЛИЧНЫЕ + КАРТА **', invitation:'[УГОЩЕНИЕ]', gratis:'[БЕСПЛАТНО]', drinks:'-- НАПИТКИ --', food:'-- МЕНЮ --', order_details:'- ДЕТАЛИ ЗАКАЗА -', scan_to_save:'Отсканируйте, чтобы сохранить счёт:', vat_incl:'(вкл. НДС)' },
  ar: { table:'طاولة', waiter:'النادل', date:'التاريخ', time:'الوقت', covers:'الضيوف', total:'المجموع', cancelled:'!! تم الإلغاء !!', cancelled_by:'تم الإلغاء بواسطة', transfer:'** تم النقل **', from:'من', to:'إلى', thank_you:'شكراً لزيارتكم!', tel:'هاتف', split:'تقسيم', persons:'أشخاص', per_person:'للشخص', cash:'** نقدًا **', card:'** بطاقة **', mixed:'** نقدًا + بطاقة **', invitation:'[دعوة]', gratis:'[مجاناً]', drinks:'-- المشروبات --', food:'-- الطعام --', order_details:'- تفاصيل الطلب -', scan_to_save:'امسح لحفظ الفاتورة:', vat_incl:'(شامل الضريبة)' },
  zh: { table:'桌号', waiter:'服务员', date:'日期', time:'时间', covers:'人数', total:'总计', cancelled:'!! 已取消 !!', cancelled_by:'取消人', transfer:'** 已转移 **', from:'从', to:'到', thank_you:'感谢您的光临!', tel:'电话', split:'分单', persons:'人', per_person:'每人', cash:'** 现金 **', card:'** 银行卡 **', mixed:'** 现金 + 银行卡 **', invitation:'[赠送]', gratis:'[免费]', drinks:'-- 饮品 --', food:'-- 菜单 --', order_details:'- 订单详情 -', scan_to_save:'扫码保存账单:', vat_incl:'(含税)' },
  pt: { table:'Mesa', waiter:'Garçom', date:'Data', time:'Hora', covers:'Pessoas', total:'TOTAL', cancelled:'!! CANCELADO !!', cancelled_by:'Cancelado por', transfer:'** TRANSFERIDO **', from:'DE', to:'PARA', thank_you:'Obrigado pela sua visita!', tel:'Tel', split:'Dividir', persons:'pessoas', per_person:'por pessoa', cash:'** DINHEIRO **', card:'** CARTÃO **', mixed:'** DINHEIRO + CARTÃO **', invitation:'[CORTESIA]', gratis:'[GRÁTIS]', drinks:'-- BEBIDAS --', food:'-- MENU --', order_details:'- DETALHES DO PEDIDO -', scan_to_save:'Digitalize para salvar a conta:', vat_incl:'(IVA incl.)' },
};
function resolveTicketLabels(lang, overrides) {
  const base = TICKET_LABELS.en;
  const loc = TICKET_LABELS[lang] || {};
  const out = {};
  for (const k of TICKET_LABEL_KEYS) out[k] = loc[k] || base[k] || '';
  if (overrides && typeof overrides === 'object') {
    for (const k of TICKET_LABEL_KEYS) {
      const v = overrides[k];
      if (v != null && String(v).trim() !== '') out[k] = String(v);
    }
  }
  return out;
}

// The functional ticket-setting keys the Station exposes — the ones that
// actually change a printed ticket (copies, toggles, footers, formats, mode,
// language). Per-zone colour styling and logo rastering stay in the web editor;
// the agent still honours them if other clients set them.
const TICKET_SETTING_DEFAULTS = {
  // Global
  ticket_language: 'en',         // en|fr|es|it|de|nl|ru|ar|zh|pt
  date_format: 'DD/MM/YYYY',     // DD/MM/YYYY | MM/DD/YYYY | YYYY-MM-DD
  time_format: '24h',            // 24h | 12h
  logo_print_enabled: false,     // print the uploaded logo at the top of tickets
  logo_size: 'medium',           // small | medium | large
  // Order / kitchen ticket
  order_copies: 1,
  order_header_align: 'center',  // left | center | right
  order_item_bold: false,
  separator_style: 'lines',      // lines | dashes | stars | dots
  font_size: 'normal',           // small | normal | large
  show_restaurant_header: true,
  show_waiter_name: true,
  show_item_price: false,
  kitchen_footer_text: '',
  ticket_mode: 'per_item',       // per_item | per_table | per_section
  // Order per-zone layout overrides ('' = auto). size: ''|S|M|L, bold: ''|bold, align: ''|left|center|right
  order_header_font_size: '', order_header_font_bold: '',
  order_info_font_size: '',   order_info_font_bold: '',   order_info_font_align: '',
  order_items_font_size: '',  order_items_font_bold: '',  order_items_font_align: '',
  order_footer_font_size: '', order_footer_font_bold: '', order_footer_font_align: '',
  // Check ticket
  check_copies: 1,
  check_item_size: 'normal',     // small | normal | large
  check_show_address: true,
  check_show_phone: true,
  check_show_instagram: true,
  check_show_waiter: true,
  check_bold_total: true,
  check_footer_text: 'Gracias por su visita! / Thank you for your visit!',
  // Check per-zone layout overrides (Info + Items zones)
  check_info_font_size: '',  check_info_font_bold: '',  check_info_font_align: '',
  check_items_font_size: '', check_items_font_bold: '', check_items_font_align: '',
  // Cancel ticket
  cancel_ticket_enabled: true,
  cancel_show_restaurant_name: true,
  cancel_show_cancelled_by: true,
  cancel_header_align: 'center',
  cancel_item_size: 'normal',
  cancel_footer_text: '',
  // Transfer ticket
  transfer_ticket_enabled: true,
  transfer_show_restaurant_name: true,
  transfer_header_align: 'center',
  transfer_item_size: 'normal',
  transfer_footer_text: '',
};

// Return only the whitelisted ticket keys, coercing types and filling defaults.
// `label_overrides` (free-form object) is passed through when present.
function pickTicketSettings(src) {
  src = src && typeof src === 'object' ? src : {};
  const out = {};
  for (const [k, def] of Object.entries(TICKET_SETTING_DEFAULTS)) {
    const v = src[k];
    if (v === undefined || v === null) { out[k] = def; continue; }
    if (typeof def === 'boolean')      out[k] = (v === true || v === 'true');
    else if (typeof def === 'number')  out[k] = Math.max(1, Math.min(3, Number(v) || 1)); // copies 1..3
    else                               out[k] = String(v);
  }
  if (src.label_overrides && typeof src.label_overrides === 'object') {
    out.label_overrides = src.label_overrides;
  }
  return out;
}

// ─── STATION AI ─────────────────────────────────────────────────────────────
// A management assistant that can read + modify the menu. It calls the LightMenu
// backend (authenticated by the restaurant's print_agent_token = API_TOKEN), runs
// a bounded agentic loop, and executes tool calls locally against Supabase.
// The LightMenu API backend. www.lightmenu.app is the Vercel SPA (its /api is
// not proxied to the server), so the agent talks to the Railway backend directly.
const LM_API_BASE = 'https://lightmenu-production.up.railway.app/api';
// ─── Unified agent (server-side brain) ──────────────────────────────────────
// The Station no longer runs its own agentic loop + tool catalog. It posts the
// conversation to /api/station/agent, which runs the SAME 62-tool brain the web
// and Flutter apps use (native tool-use, owner authority, quota-enforced). That
// makes the Station assistant fully capable — sales, orders, tables, menu,
// staff, printers — instead of the menu-only subset the local loop had, and
// there's now one place to add capability for all three surfaces.
//
// `messages` = [{ role:'user'|'assistant', content:'…' }], ending with a user turn.
// `stationState` is this Station's live offline-first order state (see
// _stationStateForAI) — the server can't read active-orders.json, so we ship it.
// Resolves { reply, steps }.
function stationAgent(messages, stationState) {
  return new Promise((resolve, reject) => {
    const bodyStr = JSON.stringify({ token: API_TOKEN, messages, stationState });
    let u;
    try { u = new URL(LM_API_BASE + '/station/agent'); } catch (e) { return reject(e); }
    const r = https.request(u, { method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(bodyStr) } }, (res) => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => {
        let parsed = null;
        try { parsed = JSON.parse(data); } catch {}
        if (res.statusCode < 200 || res.statusCode >= 300) {
          reject(new Error((parsed && parsed.error) || ('AI HTTP ' + res.statusCode + ': ' + data.slice(0, 200))));
          return;
        }
        resolve({
          reply: (parsed && parsed.reply) || 'Done.',
          steps: (parsed && parsed.steps) || [],
          clientActions: (parsed && parsed.clientActions) || [],
        });
      });
    });
    r.on('error', reject);
    // The agent may chain several tool calls server-side, so allow more headroom
    // than the old single-shot call did.
    r.setTimeout(90000, () => r.destroy(new Error('AI request timed out')));
    r.write(bodyStr); r.end();
  });
}

// Perform an action the server agent delegated to THIS Station. These are the
// things a server physically cannot do — talk to the USB/network printers wired
// to this machine. The server tool only records the intent; we carry it out here
// once the reply is on its way back, which is why the assistant phrases them as
// "running now" rather than reporting a result.
async function runClientAction(action, args) {
  args = args || {};
  if (action === 'rescan_printers') {
    runNetworkScan();
    return { ok: true, message: 'Network scan started.' };
  }
  if (action === 'test_print') {
    const label = args.printer_type ? (String(args.printer_type) + ' printer') : 'Printer';
    const ticket = buildTestTicket(label);
    let ip = (args.ip || '').trim();
    // A printer_type with no IP → look up that printer's configured IP.
    if (!ip && args.printer_type) {
      const rows = await supabaseGet('printer_configs', { restaurant_id: RESTAURANT_ID }, 100);
      const match = (Array.isArray(rows) ? rows : []).find(c => c.printer_type === args.printer_type && c.printer_ip);
      if (match) ip = match.printer_ip;
    }
    if (ip && /^\d+\.\d+\.\d+\.\d+$/.test(ip)) await sendViaNetwork(ticket, ip, 9100);
    else await sendToPrinter(ticket);
    return { ok: true, target: ip || 'active printer' };
  }
  if (action === 'update_ticket_settings') {
    // Applied here rather than server-side because changing the language must
    // also re-resolve the printed label set, and that resolver lives here. Same
    // path the old local tool used, so behaviour is unchanged.
    const incoming = pickTicketSettings(args.patch || args.settings || args);
    const rows = await supabaseGet('printer_configs', { restaurant_id: RESTAURANT_ID, printer_type: 'kitchen' }, 5);
    const cfg = Array.isArray(rows) ? rows.find(c => c.printer_type === 'kitchen') : null;
    const merged = Object.assign({}, (cfg && cfg.settings) || {}, incoming);
    merged.labels = resolveTicketLabels(merged.ticket_language || 'en', merged.label_overrides);
    await stationDb('kitchen_settings.save', { settings: merged });
    return { ok: true, language: merged.ticket_language || 'en' };
  }
  if (action === 'print_check') {
    // The check for a still-open table (real items + total, honours check_copies,
    // stamps check_printed_at). Distinct from reprint_bill, which reprints an
    // already-saved bill.
    const r = await stationPrintCheck(Number(args.table));
    if (!r || r.ok !== true) throw new Error((r && r.error) || 'Check print failed');
    return r;
  }
  if (action === 'close_table') {
    // Closing must go through the local store, not a Supabase UPDATE: the open
    // order may exist only in active-orders.json (opened offline, or not synced
    // yet). stationCloseOrder clears it locally and mirrors the close upstream.
    const r = await stationCloseOrder(Number(args.table), args.payment_method);
    if (!r || r.ok !== true) throw new Error((r && r.error) || 'Close failed');
    if (r.had_order === false) throw new Error('Table ' + args.table + ' had no open order');
    return r;
  }
  if (action === 'download_bill') {
    // The server resolved the bill from saved_bills and handed us the whole
    // payload (this Station's local store may not hold an older one), so all
    // that's left is to render and save it where a download would land.
    const bill = args.bill;
    if (!bill) throw new Error('download_bill got no bill payload');
    const dir = path.join(os.homedir(), 'Downloads');
    fs.mkdirSync(dir, { recursive: true });
    const safe = String(args.filename || 'bill.pdf').replace(/[\\/:*?"<>|]/g, '-');
    // Never clobber an existing download — suffix like a browser does.
    let file = path.join(dir, safe);
    if (fs.existsSync(file)) {
      const base = safe.replace(/\.pdf$/i, '');
      for (let n = 2; n < 500; n++) {
        const cand = path.join(dir, `${base} (${n}).pdf`);
        if (!fs.existsSync(cand)) { file = cand; break; }
      }
    }
    fs.writeFileSync(file, _billPdf(bill));
    log('AI saved bill PDF: ' + file);
    return { ok: true, path: file };
  }
  if (action === 'reprint_bill') {
    // The cloud (saved_bills) and this Station's local store use different ids —
    // order_id is the shared key, so resolve on that.
    //
    // Never fall back to "the latest bill" when handed no id: a vague request
    // then printed an unrelated table's bill, which is worse than printing
    // nothing. The caller must say which bill it means.
    const bills = store.getBills() || [];
    let bill = null;
    if (args.order_id)         bill = bills.find(b => b.order_id === args.order_id) || null;
    else if (args.bill_number) bill = bills.find(b => String(b.id) === String(args.bill_number)) || null;
    else throw new Error('reprint_bill needs order_id or bill_number — refusing to guess which bill');
    if (!bill) throw new Error('No matching bill found on this Station');
    await sendToPrinter(buildCheckTicket({
      type: 'check', restaurant_id: RESTAURANT_ID, restaurant_name: RESTAURANT_NAME,
      table_number: bill.table, waiter_name: bill.waiter, currency: bill.currency || 'EUR',
      time: bill.date, order_id: bill.order_id, payment_method: bill.payment_method,
      total: bill.total, guest_count: bill.guest_count, bill_url: bill.bill_url,
      items: bill.items || [], settings: {},
    }));
    return { ok: true, bill_id: bill.id };
  }
  return { ok: false, error: 'Unknown client action: ' + action };
}

function stationAI(prompt, systemPrompt) {
  return new Promise((resolve, reject) => {
    const bodyStr = JSON.stringify({ token: API_TOKEN, prompt, system_prompt: systemPrompt, tier: 'standard' });
    let u;
    try { u = new URL(LM_API_BASE + '/station/ai'); } catch (e) { return reject(e); }
    const r = https.request(u, { method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(bodyStr) } }, (res) => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => {
        if (res.statusCode < 200 || res.statusCode >= 300) { reject(new Error('AI HTTP ' + res.statusCode + ': ' + data.slice(0, 200))); return; }
        try { resolve(JSON.parse(data).result); } catch (e) { reject(e); }
      });
    });
    r.on('error', reject);
    r.setTimeout(45000, () => r.destroy(new Error('AI request timed out')));
    r.write(bodyStr); r.end();
  });
}

// Station WRITES go through the LightMenu backend (token-authed, scoped
// server-side to this restaurant) instead of writing to Supabase with the
// public anon key. The DB no longer grants anon writes (migration 0022), so a
// leaked anon key can only READ public menu data. Returns the action's `result`.
function stationDb(action, payload) {
  return new Promise((resolve, reject) => {
    const bodyStr = JSON.stringify({ token: API_TOKEN, action, payload: payload || {} });
    let u;
    try { u = new URL(LM_API_BASE + '/station/db'); } catch (e) { return reject(e); }
    const r = https.request(u, { method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(bodyStr) } }, (res) => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => {
        let parsed = null;
        try { parsed = JSON.parse(data); } catch {}
        if (res.statusCode < 200 || res.statusCode >= 300) {
          reject(new Error((parsed && parsed.error) || ('Station DB HTTP ' + res.statusCode)));
          return;
        }
        resolve(parsed ? parsed.result : null);
      });
    });
    r.on('error', reject);
    r.setTimeout(20000, () => r.destroy(new Error('Station DB request timed out')));
    r.write(bodyStr); r.end();
  });
}

// ─── Waiter PIN (offline-capable) ────────────────────────────────────────────
// The PIN is hashed HERE, never sent anywhere in plaintext. Format is
// byte-identical to the server's setWaiterPin ("saltHex:hashHex", scrypt with a
// 16-byte salt and 32-byte key), so redeemWaiterToken accepts a PIN set from
// this Station and we can verify one set on the web — in both directions.
function hashPin(pin) {
  const salt = crypto.randomBytes(16);
  return salt.toString('hex') + ':' + crypto.scryptSync(String(pin), salt, 32).toString('hex');
}

function verifyPinHash(pin, stored) {
  if (!stored || !stored.includes(':')) return false;
  const [saltHex, hashHex] = stored.split(':');
  const salt = Buffer.from(saltHex, 'hex');
  const expected = Buffer.from(hashHex, 'hex');
  if (!expected.length) return false;
  const actual = crypto.scryptSync(String(pin), salt, expected.length);
  return expected.length === actual.length && crypto.timingSafeEqual(expected, actual);
}

// Accepts a raw token or a full https://…/waiter/<token> link.
function extractWaiterToken(v) {
  const s = String(v || '').trim();
  if (!s) return null;
  const m = s.match(/\/waiter\/([^/?#]+)/);
  return m ? m[1] : s;
}

// Replay PINs that were set while the internet was down. We store the hash and
// the backend takes a hash, so no plaintext has to be retained to make this work.
let _pinFlushPending = false;
async function flushPendingPins() {
  if (_pinFlushPending) return;
  const pending = store.getUnsyncedPins();
  if (!pending.length) return;
  _pinFlushPending = true;
  try {
    for (const p of pending) {
      if (!p.staff_id || !p.pin_hash) continue;
      try {
        const r = await stationDb('staff.set_pin', { staff_id: p.staff_id, pin_hash: p.pin_hash });
        if (r && r.error) throw new Error(r.error);
        store.markPinSynced(p.staff_id, p.token);
        log('PIN: synced offline-set PIN for staff ' + p.staff_id);
      } catch { /* still offline — retry on the next interval */ }
    }
  } finally {
    _pinFlushPending = false;
  }
}
setInterval(() => flushPendingPins().catch(() => {}), 60000);

// Station READS for Analytics/Bills go through the same backend, scoped
// server-side to this restaurant's saved_bills rows — the exact rows the web
// app and Flutter app read, so all three surfaces show the same numbers
// regardless of which device closed which bill. Local store.js stays as the
// offline fallback when the server is unreachable.
function stationReports(type, params) {
  return new Promise((resolve, reject) => {
    const qs = new URLSearchParams({ token: API_TOKEN, type, ...(params || {}) });
    let u;
    try { u = new URL(LM_API_BASE + '/station/reports?' + qs.toString()); } catch (e) { return reject(e); }
    const r = https.request(u, { method: 'GET' }, (res) => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => {
        let parsed = null;
        try { parsed = JSON.parse(data); } catch {}
        if (res.statusCode < 200 || res.statusCode >= 300) {
          reject(new Error((parsed && parsed.error) || ('Station reports HTTP ' + res.statusCode)));
          return;
        }
        resolve(parsed);
      });
    });
    r.on('error', reject);
    r.setTimeout(15000, () => r.destroy(new Error('Station reports request timed out')));
    r.end();
  });
}

// Server-side machine kill switch. Reports this machine to the backend and learns
// whether this install may run. Fail-OPEN: any network/HTTP error leaves
// STATION_ALLOWED unchanged so an outage never bricks a restaurant. Only an
// explicit { ok:false } (machine revoked or restaurant disabled) pauses printing;
// a later { ok:true } resumes it automatically — no restart needed.
function stationVerify() {
  return new Promise((resolve) => {
    const bodyStr = JSON.stringify({ token: API_TOKEN, machine_hash: MACHINE_HASH, agent_version: AGENT_VERSION });
    let u;
    try { u = new URL(LM_API_BASE + '/station/verify'); } catch { return resolve(); }
    const r = https.request(u, { method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(bodyStr) } }, (res) => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          let parsed = null; try { parsed = JSON.parse(data); } catch {}
          if (parsed && typeof parsed.ok === 'boolean') {
            const was = STATION_ALLOWED;
            STATION_ALLOWED = parsed.ok;
            if (was && !STATION_ALLOWED) log('Station disabled by server (' + (parsed.reason || 'revoked') + ') — printing paused.');
            if (!was && STATION_ALLOWED) log('Station re-enabled by server — printing resumed.');
          }
        }
        resolve();
      });
    });
    r.on('error', () => resolve());           // fail open
    r.setTimeout(15000, () => r.destroy());   // fail open
    r.write(bodyStr); r.end();
  });
}
setTimeout(() => { stationVerify().catch(() => {}); }, 2500);            // shortly after boot
setInterval(() => { stationVerify().catch(() => {}); }, 5 * 60 * 1000); // every 5 min

// ─── AUTO-UPDATE CHECK ───────────────────────────────────────────────────────
// The runner (agent-runner.ps1) only pulls updates when node exits, so before
// this a new release sat unfetched until a reboot or crash. Here main.js polls
// the published version.json and, when a NEWER version is out, exits cleanly so
// the runner re-runs the updater and relaunches on the new build. ui.ps1 then
// notices its own file changed and reloads itself — so a push reaches the screen
// on its own, no reboot. We only exit during a quiet window (no print in the
// last few seconds) so an update never interrupts a ticket mid-flight.
const UPDATE_MANIFEST_URL = 'https://raw.githubusercontent.com/arcelen/lightmenu-releases/main/print-agent/version.json';
function _semverGt(a, b) {
  const pa = String(a).split('.').map(n => parseInt(n, 10) || 0);
  const pb = String(b).split('.').map(n => parseInt(n, 10) || 0);
  for (let i = 0; i < 3; i++) { const x = pa[i] || 0, y = pb[i] || 0; if (x > y) return true; if (x < y) return false; }
  return false;
}
function checkForUpdate() {
  https.get(UPDATE_MANIFEST_URL, { headers: { 'User-Agent': 'LightMenu-Agent-UpdateCheck' }, timeout: 10000 }, (res) => {
    if (res.statusCode !== 200) { res.resume(); return; }
    let body = '';
    res.on('data', c => body += c);
    res.on('end', () => {
      let remote = null;
      try { remote = JSON.parse(body); } catch { return; }
      if (!remote || !remote.version || !_semverGt(remote.version, AGENT_VERSION)) return;
      // A newer build is published. Wait for a quiet moment, then exit so the
      // runner pulls it. If a ticket just printed, defer to the next check.
      if (Date.now() - LAST_ACTIVITY_TS < 8000) {
        log('Update v' + remote.version + ' available — deferring (printer busy).');
        return;
      }
      log('Update v' + remote.version + ' available (on v' + AGENT_VERSION + ') — exiting so the runner applies it.');
      setTimeout(() => process.exit(0), 400);
    });
  }).on('error', () => {}).on('timeout', function () { this.destroy(); });
}
setTimeout(checkForUpdate, 60 * 1000);            // first check ~1 min after boot
setInterval(checkForUpdate, 10 * 60 * 1000);      // then every 10 min

const STATION_AI_SYSTEM =
  'You are StationAI, the on-site operator of a restaurant POS/print station. ' +
  'You have FULL control of the station — everything a human standing at the station can do, you can do: ' +
  'manage the menu, run the floor plan and tables, take and fire and close orders, drive the printers, ' +
  'configure ticket/receipt settings, read live sales & bills, and manage staff. Act decisively. ' +
  'Reply in the SAME language as the user. ' +
  'Return ONLY JSON: {"reasoning":"...","tool_name":"...","tool_args":{}}. ' +

  'THINK/FINISH: ' +
  'think{note} -> record a private planning note and continue (no user-visible effect; use it to plan multi-step work); ' +
  'say{message} -> the final answer for the user (ALWAYS end here). ' +

  'MENU tools: ' +
  'list_menu{} -> current categories+items with ids; ' +
  'add_item{name,price,description?,category_id?,is_available?,is_addon?}; ' +
  'update_item{id,name?,price?,description?,menu_category_id?,is_available?,is_addon?}; ' +
  'delete_item{id}; move_item{id,category_id}; set_item_availability{id,available} -> 86 / restore an item live; ' +
  'add_category{name,section?}; rename_category{id,name}; move_category{id,section}; delete_category{id}; ' +

  'FLOOR/TABLE tools: ' +
  'list_tables{} -> every table with id, table_number, zone, and live state (free / occupied / has_held_items); ' +
  'create_table{zone?,capacity?,shape?,table_number?} -> add a table (server assigns the number if omitted); ' +
  'update_table{id,zone?,capacity?,shape?,table_number?,status?}; delete_table{id}; ' +
  'delete_floor{zone,confirm} -> delete EVERY table in a zone (needs confirm:true); ' +

  'ORDER tools (offline-first; printing is always local): ' +
  'get_order{table_number} -> the open order on a table: line items with course + status; ' +
  'send_order{table_number,items:[{name,price?,quantity?,menu_item_id?,course?,special_requests?}],guest_count?} ' +
  '-> add items to a table and fire the kitchen ticket. course is "direct" (fire now) or ' +
  'first_plate|second_plate|third_plate|fourth_plate (held until reclaimed); ' +
  'reclaim_order{table_number} -> fire the next held course for a table and print its ticket; ' +
  'close_order{table_number} -> mark the table paid/closed and free it; ' +

  'PRINTER tools: ' +
  'list_printers{} -> configured printers with ids/type/ip and live state; ' +
  'test_print{printer_type?,ip?} -> print a test ticket (printer_type is "kitchen" or "bar"; omit both for the active printer); ' +
  'add_printer{name,type?,ip?}; update_printer{id,name?,type?,ip?,is_active?}; delete_printer{id}; ' +
  'rescan_printers{} -> rescan the network for printers; ' +

  'TICKET SETTINGS tools: ' +
  'get_ticket_settings{} -> current kitchen/receipt settings (language, header/footer, copies, layout); ' +
  'update_ticket_settings{patch} -> merge changes, e.g. {ticket_language:"fr"} or {order_copies:2} or {header_text:"..."}; ' +

  'SALES/BILLS tools: ' +
  'sales_summary{period?} -> revenue, order count and average ticket for today|week|month|all; ' +
  'get_analytics{period?} -> deeper breakdown: payment split (cash/card/mixed), best day, 7-day trend; ' +
  'list_recent_bills{limit?} -> most recent bills with ids and totals; ' +
  'list_bills{start?,end?,limit?} -> bills in a YYYY-MM-DD..YYYY-MM-DD range; ' +
  'bill_details{id} -> full breakdown of one bill; ' +
  'reprint_bill{id?} -> reprint a saved bill (omit id for the most recent); ' +

  'STAFF tools: ' +
  'list_staff{} -> team members with ids and roles; ' +
  'add_staff{name,role_id?}; remove_staff{staff_id}; toggle_staff{staff_id}; set_staff_role{staff_id,role_id}; ' +

  'RULES: ' +
  '(1) ALWAYS finish with say{}. ' +
  '(2) Before acting on anything by id, call the matching list_* tool first (list_menu / list_tables / list_printers / list_staff / list_recent_bills) — NEVER invent ids. ' +
  '(3) When sending an order, resolve item names to menu_item_id + real price via list_menu first, so the kitchen ticket and revenue are correct. ' +
  '(4) A table that has_held_items should usually be reclaimed (fire the next course) rather than sent brand-new items — check get_order if unsure. ' +
  '(5) Destructive actions (delete_*, remove_staff, close_order, delete_floor): only when the user clearly asked. For delete_floor and any bulk/irreversible action, confirm what you are about to do in a say{} first UNLESS the user was already explicit; delete_floor additionally requires confirm:true. ' +
  '(6) Use think{} to plan before long multi-step jobs (e.g. "close every table and print the nightly report"). ' +
  '(7) State the concrete result (name, price, table, printer, amount) in your say{}.';

async function stationExecTool(name, args) {
  args = args || {};
  switch (name) {
    case 'list_menu': {
      const [cats, items] = await Promise.all([
        supabaseGet('menu_categories', { restaurant_id: RESTAURANT_ID }, 500),
        supabaseGet('menu_items', { restaurant_id: RESTAURANT_ID }, 2000),
      ]);
      return {
        categories: (Array.isArray(cats) ? cats : []).map(x => ({ id: x.id, name: x.name, section: x.section })),
        items: (Array.isArray(items) ? items : []).map(x => ({ id: x.id, name: x.name, price: x.price, category_id: x.menu_category_id, available: x.is_available !== false, addon: x.is_addon === true })),
      };
    }
    case 'add_item': {
      if (!args.name) throw new Error('name required');
      const r = await stationDb('menu_item.create', { name: String(args.name), price: Number(args.price) || 0, description: args.description || '', menu_category_id: args.category_id || null, is_available: args.is_available !== false, is_addon: args.is_addon === true });
      return { ok: true, id: r && r.id };
    }
    case 'update_item': {
      if (!args.id) throw new Error('id required');
      const patch = {};
      if (args.name !== undefined) patch.name = String(args.name);
      if (args.description !== undefined) patch.description = String(args.description);
      if (args.price !== undefined) patch.price = Number(args.price) || 0;
      if (args.menu_category_id !== undefined) patch.menu_category_id = args.menu_category_id || null;
      if (args.is_available !== undefined) patch.is_available = args.is_available !== false;
      if (args.is_addon !== undefined) patch.is_addon = args.is_addon === true;
      await stationDb('menu_item.update', { id: args.id, patch });
      return { ok: true };
    }
    case 'delete_item': { if (!args.id) throw new Error('id required'); await stationDb('menu_item.delete', { id: args.id }); return { ok: true }; }
    case 'move_item': { if (!args.id) throw new Error('id required'); await stationDb('menu_item.update', { id: args.id, patch: { menu_category_id: args.category_id || null } }); return { ok: true }; }
    case 'add_category': {
      if (!args.name) throw new Error('name required');
      const r = await stationDb('menu_category.create', { name: String(args.name).trim(), section: args.section || 'menu' });
      return { ok: true, id: r && r.id };
    }
    case 'rename_category': { if (!args.id) throw new Error('id required'); await stationDb('menu_category.update', { id: args.id, patch: { name: String(args.name) } }); return { ok: true }; }
    case 'move_category': { if (!args.id) throw new Error('id required'); await stationDb('menu_category.update', { id: args.id, patch: { section: args.section || 'menu' } }); return { ok: true }; }
    case 'delete_category': {
      if (!args.id) throw new Error('id required');
      await stationDb('menu_category.delete', { id: args.id });
      return { ok: true };
    }

    // ── Printers ──────────────────────────────────────────────────────────
    case 'list_printers': {
      const rows = await supabaseGet('printer_configs', { restaurant_id: RESTAURANT_ID }, 100);
      return { printers: (Array.isArray(rows) ? rows : [])
        .filter(c => c.printer_type !== 'scan')
        .map(c => ({ id: c.id, name: c.name || 'Printer', type: c.printer_type || 'kitchen', ip: c.printer_ip || '', active: c.is_active !== false })) };
    }
    case 'test_print': {
      const label = args.printer_type ? (String(args.printer_type) + ' printer') : 'Printer';
      const ticket = buildTestTicket(label);
      let ip = (args.ip || '').trim();
      // If a printer_type was named but no IP, look up that printer's IP.
      if (!ip && args.printer_type) {
        const rows = await supabaseGet('printer_configs', { restaurant_id: RESTAURANT_ID }, 100);
        const match = (Array.isArray(rows) ? rows : []).find(c => c.printer_type === args.printer_type && c.printer_ip);
        if (match) ip = match.printer_ip;
      }
      if (ip && /^\d+\.\d+\.\d+\.\d+$/.test(ip)) await sendViaNetwork(ticket, ip, 9100);
      else await sendToPrinter(ticket);
      return { ok: true, target: ip || 'active printer' };
    }
    case 'add_printer': {
      if (!args.name) throw new Error('name required');
      const ip = (args.ip || '').trim();
      if (ip && !/^\d+\.\d+\.\d+\.\d+$/.test(ip)) throw new Error('Invalid IP');
      const r = await stationDb('printer_config.create', { values: {
        name: String(args.name).slice(0, 60), printer_type: args.type || 'kitchen', printer_ip: ip || null, is_active: true } });
      return { ok: true, id: r && r.printer && r.printer.id };
    }
    case 'update_printer': {
      if (!args.id) throw new Error('id required');
      const patch = {};
      if (args.name !== undefined) patch.name = String(args.name).slice(0, 60);
      if (args.type !== undefined) patch.printer_type = args.type;
      if (args.ip !== undefined) { const ip = String(args.ip).trim(); if (ip && !/^\d+\.\d+\.\d+\.\d+$/.test(ip)) throw new Error('Invalid IP'); patch.printer_ip = ip || null; }
      if (args.is_active !== undefined) patch.is_active = args.is_active !== false;
      await stationDb('printer_config.update', { id: args.id, patch });
      return { ok: true };
    }
    case 'delete_printer': { if (!args.id) throw new Error('id required'); await stationDb('printer_config.delete', { id: args.id }); return { ok: true }; }

    // ── Sales / bills ─────────────────────────────────────────────────────
    case 'sales_summary': {
      const period = ['today', 'week', 'month', 'all'].includes(args.period) ? args.period : 'today';
      const s = store.getStats(period) || {};
      return { period, total_revenue: s.total_revenue || 0, total_orders: s.total_orders || 0, avg_ticket: Number((s.avg_ticket || 0).toFixed(2)) };
    }
    case 'list_recent_bills': {
      const limit = Math.min(Number(args.limit) || 10, 30);
      const bills = store.getBills() || [];
      return { bills: bills.slice(-limit).reverse().map(b => ({ id: b.id, table: b.table, total: b.total, date: b.date, payment: b.payment_method })) };
    }
    case 'bill_details': {
      const bill = args.id ? store.findBill(args.id) : null;
      if (!bill) throw new Error('No matching bill found');
      return {
        id: bill.id, table: bill.table, waiter: bill.waiter, date: bill.date,
        payment: bill.payment_method, currency: bill.currency || 'EUR',
        guest_count: bill.guest_count, total: bill.total,
        items: (bill.items || []).map(i => ({
          name: i.name || i.menu_item_name || 'Item',
          qty: i.qty || i.quantity || 1,
          price: i.price != null ? i.price : (i.price_at_order_time != null ? i.price_at_order_time : 0),
        })),
      };
    }
    case 'reprint_bill': {
      let bill = null;
      if (args.id) bill = store.findBill(args.id);
      else { const bills = store.getBills() || []; bill = bills.length ? bills[bills.length - 1] : null; }
      if (!bill) throw new Error('No matching bill found');
      const ticket = {
        type: 'check', restaurant_id: RESTAURANT_ID, restaurant_name: RESTAURANT_NAME,
        table_number: bill.table, waiter_name: bill.waiter, currency: bill.currency || 'EUR',
        time: bill.date, order_id: bill.order_id, payment_method: bill.payment_method,
        total: bill.total, guest_count: bill.guest_count, bill_url: bill.bill_url,
        items: bill.items || [], settings: {},
      };
      await sendToPrinter(buildCheckTicket(ticket));
      return { ok: true, bill_id: bill.id };
    }

    // ── Staff ─────────────────────────────────────────────────────────────
    case 'list_staff': {
      const r = await stationDb('staff.list', {});
      const members = (r && Array.isArray(r.members)) ? r.members : [];
      return { staff: members.map(m => ({ id: m.id, name: m.display_name || m.user_email || m.full_name || 'Staff', role: m.role || 'Waiter' })) };
    }
    case 'add_staff': {
      if (!args.name) throw new Error('name required');
      const r = await stationDb('staff.create', { name: String(args.name), role_id: args.role_id || null });
      return { ok: true, id: r && r.id };
    }
    case 'remove_staff': { const id = args.staff_id || args.id; if (!id) throw new Error('staff_id required'); await stationDb('staff.delete', { staff_id: id }); return { ok: true }; }
    case 'toggle_staff': { const id = args.staff_id || args.id; if (!id) throw new Error('staff_id required'); const r = await stationDb('staff.toggle', { staff_id: id }); return { ok: true, active: r ? r.active : null }; }
    case 'set_staff_role': { const id = args.staff_id || args.id; if (!id) throw new Error('staff_id required'); await stationDb('staff.role', { staff_id: id, role_id: args.role_id || null }); return { ok: true }; }

    // ── Menu availability (86 / restore) ──────────────────────────────────
    case 'set_item_availability': {
      if (!args.id) throw new Error('id required');
      await stationDb('menu_item.update', { id: args.id, patch: { is_available: args.available !== false } });
      return { ok: true, available: args.available !== false };
    }

    // ── Floor / tables ────────────────────────────────────────────────────
    case 'list_tables': {
      const rows = await supabaseGet('tables', { restaurant_id: RESTAURANT_ID }, 300);
      const active = _loadActiveOrders();
      const courseHeld = ['first_plate', 'second_plate', 'third_plate', 'fourth_plate'];
      return { tables: (Array.isArray(rows) ? rows : []).map(t => {
        const local = active[String(t.table_number)];
        const occupied = !!local || !!t.current_order_id || (t.status && t.status !== 'available');
        const has_held_items = !!(local && (local.items || []).some(i => i.status === 'pending' && courseHeld.includes(i.course)));
        return { id: t.id, table_number: t.table_number, zone: t.zone || null, shape: t.shape || 'square',
                 capacity: t.capacity || null, status: t.status || 'available', occupied, has_held_items,
                 check_printed: !!t.check_printed_at };
      }) };
    }
    case 'create_table': {
      const r = await stationDb('table.create', {
        zone: args.zone || null, pos_x: args.pos_x, pos_y: args.pos_y,
        capacity: args.capacity, shape: args.shape, table_number: args.table_number,
      });
      return { ok: true, table: r || null };
    }
    case 'update_table': {
      if (!args.id) throw new Error('id required');
      const patch = {};
      ['zone', 'capacity', 'shape', 'table_number', 'status', 'pos_x', 'pos_y'].forEach(k => { if (args[k] !== undefined) patch[k] = args[k]; });
      await stationDb('table.update', { id: args.id, patch });
      return { ok: true };
    }
    case 'delete_table': { if (!args.id) throw new Error('id required'); await stationDb('table.delete', { id: args.id }); return { ok: true }; }
    case 'delete_floor': {
      if (!args.zone) throw new Error('zone required');
      if (args.confirm !== true) return { ok: false, needs_confirmation: true, message: 'delete_floor removes every table in "' + args.zone + '". Confirm with the user, then call again with confirm:true.' };
      await stationDb('table.delete_zone', { zone: args.zone });
      return { ok: true, zone: args.zone };
    }

    // ── Live orders ───────────────────────────────────────────────────────
    case 'get_order': {
      const t = args.table_number || args.table;
      if (!t) throw new Error('table_number required');
      let local;
      try { local = await _pullOrderFromSupabase(t); } catch { local = _activeOrder(t); }
      if (!local) return { open: false, table_number: t, items: [] };
      return { open: true, table_number: t, order_id: local.order_id, guest_count: local.guest_count,
        items: (local.items || []).map(i => ({ name: i.menu_item_name, qty: i.quantity, price: i.price_at_order_time, course: i.course, status: i.status })) };
    }
    case 'send_order': {
      const t = args.table_number || args.table;
      const items = Array.isArray(args.items) ? args.items : [];
      if (!t || !items.length) throw new Error('table_number and items required');
      return await stationSendOrder(t, items, args.guest_count || 1);
    }
    case 'reclaim_order': {
      const t = args.table_number || args.table;
      if (!t) throw new Error('table_number required');
      return await stationReclaimOrder(t);
    }
    case 'close_order': {
      const t = args.table_number || args.table;
      if (!t) throw new Error('table_number required');
      return await stationCloseOrder(t);
    }

    // ── Printers (rescan) ─────────────────────────────────────────────────
    case 'rescan_printers': { runNetworkScan(); return { ok: true, message: 'Network scan started.' }; }

    // ── Ticket / receipt settings ─────────────────────────────────────────
    case 'get_ticket_settings': {
      const rows = await supabaseGet('printer_configs', { restaurant_id: RESTAURANT_ID, printer_type: 'kitchen' }, 5);
      const cfg = Array.isArray(rows) ? rows.find(c => c.printer_type === 'kitchen') : null;
      return { settings: pickTicketSettings((cfg && cfg.settings) || {}) };
    }
    case 'update_ticket_settings': {
      const incoming = pickTicketSettings(args.patch || args.settings || args);
      const rows = await supabaseGet('printer_configs', { restaurant_id: RESTAURANT_ID, printer_type: 'kitchen' }, 5);
      const cfg = Array.isArray(rows) ? rows.find(c => c.printer_type === 'kitchen') : null;
      const merged = { ...((cfg && cfg.settings) || {}), ...incoming };
      merged.labels = resolveTicketLabels(merged.ticket_language || 'en', merged.label_overrides);
      await stationDb('kitchen_settings.save', { settings: merged });
      return { ok: true, language: merged.ticket_language || 'en' };
    }

    // ── Analytics / bills ─────────────────────────────────────────────────
    case 'get_analytics': {
      const period = ['today', 'week', 'month', 'all'].includes(args.period) ? args.period : 'today';
      const s = store.getStats(period) || {};
      return { period, currency: s.currency || 'EUR', total_revenue: s.total_revenue || 0, total_orders: s.total_orders || 0,
        avg_ticket: Number((s.avg_ticket || 0).toFixed(2)), best_day: s.best_day, best_amount: s.best_amount,
        payment: s.payment, daily: s.daily };
    }
    case 'list_bills': {
      const limit = Math.min(Number(args.limit) || 30, 100);
      const bills = store.getBills(args.start || null, args.end || null) || [];
      return { count: bills.length, bills: bills.slice(-limit).reverse().map(b => ({ id: b.id, table: b.table, waiter: b.waiter, total: b.total, date: b.date, payment: b.payment_method })) };
    }

    default: throw new Error('Unknown tool: ' + name);
  }
}

async function runStationAgent(userMessage, history) {
  const convo = [];
  (history || []).forEach(h => convo.push((h.role === 'user' ? 'User: ' : 'Assistant: ') + h.text));
  convo.push('User: ' + userMessage);
  const actions = [];
  const MAX_STEPS = 20;
  for (let step = 0; step < MAX_STEPS; step++) {
    const prompt = convo.join('\n') + '\n\nDecide your next action. Return ONLY the JSON.';
    const resp = await stationAI(prompt, STATION_AI_SYSTEM);
    let obj = resp;
    if (typeof resp === 'string') {
      try { obj = JSON.parse(resp.replace(/```json?/gi, '').replace(/```/g, '').trim()); }
      catch { obj = { tool_name: 'say', tool_args: { message: resp } }; }
    }
    const tool = obj && obj.tool_name, targs = (obj && obj.tool_args) || {};
    if (tool === 'say' || !tool) { return { reply: targs.message || 'Done.', actions }; }
    // Private planning step — no side effect, just fold the note back into context.
    if (tool === 'think') {
      convo.push('(thought: ' + String(targs.note || targs.message || '').slice(0, 500) + ')');
      continue;
    }
    try {
      const result = await stationExecTool(tool, targs);
      actions.push(tool);
      // Large catalogue/floor reads need room; everything else stays compact.
      const cap = (tool === 'list_menu' || tool === 'list_tables' || tool === 'get_analytics') ? 12000 : 1500;
      convo.push('(called ' + tool + ' -> ' + JSON.stringify(result).slice(0, cap) + ')');
    } catch (e) {
      convo.push('(called ' + tool + ' -> ERROR: ' + e.message + ')');
    }
  }
  return { reply: 'I ran through many steps without finishing — please narrow the request or check the result.', actions };
}

// Simple diagnostic ticket fired from the Station's Kitchen & Printing tab so
// the owner can confirm a printer is wired up correctly without taking an order.
function buildTestTicket(printerName) {
  const d = new Date();
  let b = INIT;
  b += ALIGN_CENTER + FONT_LARGE_B + 'LightMenu' + '\n' + FONT_NORMAL;
  b += ALIGN_CENTER + FONT_TITLE + 'TEST PRINT' + '\n' + FONT_NORMAL;
  b += ALIGN_CENTER + '------------------------------' + '\n';
  b += ALIGN_LEFT + FONT_BOLD + 'Printer: ' + FONT_NORMAL + (printerName || 'Printer') + '\n';
  if (RESTAURANT_NAME) b += FONT_BOLD + 'Venue:   ' + FONT_NORMAL + RESTAURANT_NAME + '\n';
  b += FONT_BOLD + 'Time:    ' + FONT_NORMAL + d.toLocaleString() + '\n';
  b += ALIGN_CENTER + '------------------------------' + '\n';
  b += ALIGN_CENTER + 'If you can read this,\nyour printer is connected.' + '\n';
  b += FEED(4) + CUT;
  return Buffer.from(b, 'binary');
}

// "I'M PRINTER No. N" slip — lets staff physically identify which printer is
// which (IP addresses mean nothing to them). Triggered by the Print Identifier
// button in the apps' Kitchen Stations screen.
function buildIdentifierTicket(number, name) {
  let b = INIT;
  b += ALIGN_CENTER + FONT_LARGE_B + 'LightMenu' + '\n' + FONT_NORMAL;
  b += ALIGN_CENTER + '==============================' + '\n';
  b += ALIGN_CENTER + FONT_TITLE + "I'M PRINTER" + '\n';
  b += ALIGN_CENTER + FONT_TITLE + 'No. ' + (number != null ? number : '?') + '\n' + FONT_NORMAL;
  b += ALIGN_CENTER + '==============================' + '\n';
  if (name) b += ALIGN_CENTER + FONT_BOLD + name + '\n' + FONT_NORMAL;
  if (RESTAURANT_NAME) b += ALIGN_CENTER + RESTAURANT_NAME + '\n';
  b += ALIGN_CENTER + 'Assign what prints here in the\nKitchen Stations screen.' + '\n';
  b += FEED(4) + CUT;
  return Buffer.from(b, 'binary');
}

function buildKitchenTicket(t) {
  const s = t.settings || {};
  const d = new Date(t.time || Date.now());
  const currency = t.currency;
  const sep = sepLine(s.separator_style);
  const logo = logoBytes(s);
  const script = ticketScript(t);
  let b = INIT + codePageHeader(script);
  if (s.show_restaurant_header !== false && t.restaurant_name) {
    b += zonePrefix({size:s.order_header_font_size, bold:s.order_header_font_bold, align:s.order_header_align, bg:s.order_header_bg}, {size:'M', bold:'bold', align:'center'});
    b += t.restaurant_name.toUpperCase() + '\n';
    b += zoneSuffix();
  }
  // Show station label for per_section mode (BAR, KITCHEN, etc.)
  if (t.kitchen_name) {
    b += ALIGN_CENTER + FONT_LARGE_B + '[ ' + t.kitchen_name + ' ]' + '\n' + FONT_NORMAL + ALIGN_LEFT;
  }
  b += sep + '\n';
  const infoPrefix = zonePrefix({size:s.order_info_font_size, bold:s.order_info_font_bold, align:s.order_info_font_align, bg:s.order_info_bg});
  b += infoPrefix;
  // Date in normal font right-aligned, then table number large+bold centered
  b += ALIGN_RIGHT + FONT_NORMAL + fmtDate(d, s.date_format) + '\n';
  b += ALIGN_CENTER + FONT_LARGE_B + lbl(s,'table','Table') + ': ' + (t.table_number || '?') + '\n';
  if (s.show_waiter_name !== false && t.waiter_name) {
    b += FONT_BOLD + ALIGN_LEFT + padLR(lbl(s,'waiter','Waiter') + ': ' + tr(t.waiter_name, 20), fmtTime(d, s.time_format)) + '\n';
  } else {
    b += FONT_NORMAL + ALIGN_RIGHT + fmtTime(d, s.time_format) + '\n';
  }
  b += zoneSuffix();
  b += sep + '\n';
  const itemsBold = (s.order_items_font_bold === 'bold') || s.order_item_bold;
  const itemsSize = s.order_items_font_size || (s.font_size === 'large' ? 'L' : '');
  for (const item of (t.items || [])) {
    const isInv = item.is_invitation;
    const prefix = isInv ? lbl(s,'invitation','[INVIT]') + ' ' : '';
    const showPrice = s.show_item_price && !isInv;
    const priceStr = showPrice ? fmtPrice(item.qty * item.price, currency) : '';
    // Item name UPPERCASE + large bold for kitchen readability
    const itemName = prefix + item.qty + 'x ' + (item.name || '').toUpperCase();
    const nameLine = tr(itemName, W - (showPrice ? priceStr.length + 1 : 0));
    b += FONT_LARGE_B;
    if (showPrice) b += fillLine(nameLine, priceStr) + '\n';
    else           b += nameLine + '\n';
    b += FONT_NORMAL;
    for (const addon of getAddons(item)) b += FONT_LARGE + tr('   ' + (item.qty || 1) + 'x + ' + addon.name, W) + '\n' + FONT_NORMAL;
    if (item.special_requests) b += FONT_LARGE + tr('  * ' + item.special_requests, W) + '\n' + FONT_NORMAL;
  }
  b += sep + '\n';
  if (s.kitchen_footer_text) {
    b += zonePrefix({size:s.order_footer_font_size, bold:s.order_footer_font_bold, align:s.order_footer_font_align, bg:s.order_footer_bg}, {align:'center'});
    b += tr(s.kitchen_footer_text, W) + '\n';
    b += zoneSuffix();
  }
  b += CUT;
  const textBuf = toBuffer(b, script);
  return logo ? Buffer.concat([Buffer.from(INIT, 'binary'), logo, textBuf]) : textBuf;
}


// --- CANCEL TICKET ------------------------------------------------------------
function buildCancelTicket(t) {
  var s = t.settings || {};
  var d = new Date(t.time || Date.now());
  var timeStr = fmtTime(d, s.time_format);
  var dateStr = fmtDate(d, s.date_format);
  var logo = logoBytes(s);
  var script = ticketScript(t);
  var b = INIT + codePageHeader(script) + ALIGN_CENTER + FONT_LARGE_B + lbl(s,'cancelled','!! CANCELLED !!') + '\n' + FONT_NORMAL;
  b += ALIGN_LEFT + '\n';
  b += FONT_BOLD + dateStr + '   ' + timeStr + '\n' + FONT_NORMAL;
  b += FONT_TITLE + lbl(s,'table','Table') + ' : ' + (t.table_number || '?') + '\n' + FONT_NORMAL;
  b += FONT_TITLE + lbl(s,'cancelled_by','By') + ' : ' + (t.cancelled_by || t.waiter_name || 'Staff') + '\n' + FONT_NORMAL;
  b += '='.repeat(48) + '\n';
  for (var i = 0; i < (t.items || []).length; i++) {
    var item = t.items[i];
    b += FONT_LARGE_B + (item.qty || 1) + 'x ' + (item.name || '').toUpperCase() + '\n' + FONT_NORMAL;
  }
  b += CUT;
  var textBuf = toBuffer(b, script);
  return logo ? Buffer.concat([Buffer.from(INIT, 'binary'), logo, textBuf]) : textBuf;
}

// --- TRANSFER TICKET ----------------------------------------------------------
function buildTransferTicket(t) {
  var s = t.settings || {};
  var d = new Date(t.time || Date.now());
  var timeStr = fmtTime(d, s.time_format);
  var dateStr = fmtDate(d, s.date_format);
  var from = t.from_table || '?';
  var to = t.to_table || t.table_number || '?';
  var logo = logoBytes(s);
  var tableLbl = lbl(s,'table','Table');
  var script = ticketScript(t);
  var b = INIT + codePageHeader(script) + ALIGN_CENTER + FONT_LARGE_B + lbl(s,'transfer','** TRANSFER **') + '\n' + FONT_NORMAL;
  b += ALIGN_LEFT + '\n';
  b += FONT_BOLD + dateStr + '   ' + timeStr + '\n' + FONT_NORMAL;
  b += FONT_TITLE + lbl(s,'from','FROM') + '  : ' + tableLbl + ' ' + from + '\n' + FONT_NORMAL;
  b += FONT_TITLE + lbl(s,'to','TO') + '    : ' + tableLbl + ' ' + to + '\n' + FONT_NORMAL;
  b += FONT_TITLE + lbl(s,'waiter','Waiter') + ': ' + (t.waiter_name || 'Staff') + '\n' + FONT_NORMAL;
  b += '='.repeat(48) + '\n';
  for (var j = 0; j < (t.items || []).length; j++) {
    var it = t.items[j];
    b += FONT_LARGE_B + (it.qty || 1) + 'x ' + (it.name || '').toUpperCase() + '\n' + FONT_NORMAL;
  }
  b += CUT;
  var textBuf = toBuffer(b, script);
  return logo ? Buffer.concat([Buffer.from(INIT, 'binary'), logo, textBuf]) : textBuf;
}

function buildCheckTicket(t) {
  const s = t.settings || {};
  const currency = t.currency;
  const d = new Date(t.time || Date.now());
  const sep = sepLine(s.separator_style);
  const logo = logoBytes(s);
  const script = ticketScript(t);
  const WL = 24;
  function centerL(text) { text = String(text || '').slice(0, WL); const p = Math.floor((WL - text.length) / 2); return ' '.repeat(Math.max(0, p)) + text; }
  let b = INIT + codePageHeader(script);
  // When a logo is printed first, skip the leading blank line so there is no
  // gap between the logo image and the restaurant name below it.
  b += (logo ? '' : '\n') + ALIGN_CENTER + FONT_LARGE_B;
  b += (t.restaurant_name || 'Restaurant').toUpperCase() + '\n';
  b += FONT_NORMAL + ALIGN_LEFT + '\n';
  if ((s.check_show_address !== false) && t.restaurant_address) b += FONT_BOLD + center(tr(t.restaurant_address, W)) + '\n' + FONT_NORMAL;
  if ((s.check_show_phone !== false) && t.restaurant_phone)    b += FONT_BOLD + center(lbl(s,'tel','Tel') + ': ' + t.restaurant_phone) + '\n' + FONT_NORMAL;
  const igName = igHandle(t.restaurant_instagram);
  if (igName && s.check_show_instagram !== false)              b += FONT_BOLD + center('[IG] @' + igName) + '\n' + FONT_NORMAL;
  b += '\n' + ALIGN_LEFT + sep + '\n\n';
  b += zonePrefix({size:s.check_info_font_size, bold:s.check_info_font_bold, align:s.check_info_font_align, bg:s.check_info_bg}, {bold:'bold'});
  const LW = 10;
  function infoRow(label, value) { const l = (label + ':').padEnd(LW); return l + tr(String(value), W - LW) + '\n'; }
  b += infoRow(lbl(s,'date','Date'), fmtDate(d, s.date_format));
  b += infoRow(lbl(s,'time','Time'), fmtTime(d, s.time_format));
  b += infoRow(lbl(s,'table','Table'), String(t.table_number || '?'));
  if ((s.check_show_waiter !== false) && t.waiter_name) b += infoRow(lbl(s,'waiter','Waiter'), t.waiter_name);
  if (t.guest_count && t.guest_count >= 1)              b += infoRow(lbl(s,'covers','Covers'), t.guest_count + ' ' + lbl(s,'persons','persons'));
  b += zoneSuffix();
  b += '\n' + sep + '\n';
  const itemsSize = s.check_items_font_size || s.check_item_size || '';
  const itemsBold = s.check_items_font_bold || '';
  let subtotal = 0, itemCount = 0;
  const allItems = t.items || [];
  const hasSections = allItems.some(it => it && (it.section === 'drinks' || it.section === 'menu'));
  const renderItem = (item) => {
    const qty = item.qty || 1, price = item.price || 0, lineTotal = qty * price;
    b += zonePrefix({size:itemsSize, bold:itemsBold||'bold', align:s.check_items_font_align, bg:s.check_items_bg});
    if (item.is_invitation) {
      const gratisLbl = lbl(s,'gratis','[GRATIS]');
      b += fillLine(tr(qty + 'x ' + item.name, W - (gratisLbl.length + 1)), gratisLbl) + '\n';
    } else {
      subtotal += lineTotal; itemCount += qty;
      const priceStr = fmtPrice(lineTotal, currency);
      b += fillLine(tr(qty + 'x ' + item.name, W - priceStr.length - 1), priceStr) + '\n';
    }
    b += zoneSuffix();
    for (const addon of getAddons(item)) {
      const aprice = Number(addon.price || 0);
      const addonLabel = '   ' + qty + 'x + ' + addon.name;
      if (aprice > 0) {
        subtotal += aprice * qty;
        const aps = fmtPrice(aprice * qty, currency);
        b += FONT_BOLD + fillLine(tr(addonLabel, W - aps.length - 1), aps) + '\n' + FONT_NORMAL;
      } else {
        b += FONT_NORMAL + tr(addonLabel, W) + '\n';
      }
    }
    // special_requests intentionally hidden on check ticket (kitchen only)
  };
  if (hasSections) {
    const drinks = allItems.filter(it => it && it.section === 'drinks');
    const menu   = allItems.filter(it => it && it.section !== 'drinks');
    if (drinks.length) { b += '\n' + ALIGN_CENTER + FONT_BOLD + center(lbl(s,'drinks','-- DRINKS --')) + '\n' + FONT_NORMAL + ALIGN_LEFT; for (const item of drinks) renderItem(item); }
    if (menu.length)   { b += (drinks.length ? '\n' : '') + ALIGN_CENTER + FONT_BOLD + center(lbl(s,'food','-- MENU --')) + '\n' + FONT_NORMAL + ALIGN_LEFT; for (const item of menu) renderItem(item); }
  } else {
    for (const item of allItems) renderItem(item);
  }
  b += '\n' + sep + '\n\n' + ALIGN_CENTER;
  const totalPrice = fmtPrice(t.total || subtotal, currency);
  b += ALIGN_LEFT + FONT_LARGE_B + lbl(s,'total','TOTAL') + ' ' + FONT_NORMAL + ' ' + lbl(s,'vat_incl','(VAT incl.)') + ' ' + FONT_LARGE_B + totalPrice + FONT_NORMAL + '\n';
  b += '\n' + ALIGN_LEFT + sep + '\n';
  if (t.guest_count && t.guest_count >= 2) {
    const total = t.total || subtotal;
    const half = W / 2;
    b += '\n';
    const splitLbl = lbl(s,'split','Split');
    const personsLbl = lbl(s,'persons','persons');
    const perPersonLbl = lbl(s,'per_person','per person');
    if (t.guest_count > 2) {
      function padHalf(x) { x = String(x).slice(0, half); return x + ' '.repeat(half - x.length); }
      b += FONT_NORMAL + padHalf(splitLbl + ' / ' + t.guest_count + ' ' + personsLbl) + padHalf(splitLbl + ' / 2 ' + personsLbl) + '\n';
      b += FONT_BOLD   + padHalf(fmtPrice(total / t.guest_count, currency) + ' /pers') + padHalf(fmtPrice(total / 2, currency) + ' /pers') + '\n' + FONT_NORMAL;
    } else {
      b += FONT_BOLD + fillLine(splitLbl + ' / 2 ' + personsLbl, fmtPrice(total / 2, currency) + ' ' + perPersonLbl) + '\n' + FONT_NORMAL;
    }
    b += '\n';
  }
  if (t.payment_method && t.payment_method !== 'unpaid') {
    const pl = ({
      cash:  lbl(s,'cash','** CASH **'),
      card:  lbl(s,'card','** CARD **'),
      mixed: lbl(s,'mixed','** CASH + CARD **'),
    })[t.payment_method] || '';
    if (pl) b += '\n' + ALIGN_CENTER + FONT_TITLE + center(pl) + '\n' + FONT_NORMAL + ALIGN_LEFT + '\n';
  }
  b += sep + '\n\n';
  // Footer: just the user's "thank you" text. The LightMenu branding used
  // to be appended as a default fallback here, but that meant any custom
  // check_footer_text wiped it out. We now print branding ALWAYS, after the
  // QR — see brandingText below.
  const footerText = s.check_footer_text || lbl(s,'thank_you','Thank you for your visit!');
  b += ALIGN_CENTER + FONT_BOLD;
  for (const line of footerText.split(/\\n|\n/)) if (line.trim()) b += line.trim() + '\n';
  b += FONT_NORMAL + ALIGN_LEFT + '\n';
  const qrUrl = t.bill_url || t.qr_url || (t.order_id ? 'https://lightmenu.app/bill/' + t.order_id : 'https://lightmenu.app');
  const qrBuf = qrToRaster(qrUrl);
  // Branding line printed AFTER the QR on every bill, every language.
  // Latin ASCII, safe to encode via toBuffer regardless of script.
  const brandingText = '\n' + ALIGN_CENTER + FONT_NORMAL + 'Powered by LightMenu\nlightmenu.app\n' + ALIGN_LEFT;
  if (qrBuf) {
    b += '\n' + ALIGN_CENTER + FONT_NORMAL + lbl(s,'scan_to_save','Scan to save this bill:') + '\n';
    const textBefore = toBuffer(b, script);
    const branding = toBuffer(brandingText, script);
    const after = Buffer.from(CUT, 'binary');
    // Order: text → QR image → branding → cut
    const checkBuf = Buffer.concat([textBefore, Buffer.from(ALIGN_CENTER, 'binary'), qrBuf, branding, after]);
    return logo ? Buffer.concat([Buffer.from(ALIGN_CENTER, 'binary'), logo, checkBuf]) : checkBuf;
  }
  // No QR fallback path — branding still goes last.
  b += brandingText + CUT;
  const textBuf = toBuffer(b, script);
  return logo ? Buffer.concat([Buffer.from(ALIGN_CENTER, 'binary'), logo, textBuf]) : textBuf;
}

// --- HTTP SERVER (for direct /print calls from LightMenu frontend) ------------
function setCORS(res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Accept, Origin');
  res.setHeader('Access-Control-Max-Age', '86400');
}

http.createServer((req, res) => {
  setCORS(res);
  if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

  if (req.method === 'GET' && req.url === '/status') {
    const configured = !!(RESTAURANT_ID && RESTAURANT_ID !== '__RESTAURANT_ID__' && API_TOKEN && API_TOKEN !== '__API_TOKEN__');
    // Detected printers for the apps' Kitchen Stations screen: number + IP +
    // transport (eth/usb) + health. 'scan' is the internal scanner pseudo-row.
    const printers = (Array.isArray(printersCache) ? printersCache : [])
      .filter(p => p.printer_type !== 'scan')
      .map(p => ({
        id:            p.id,
        name:          p.name || null,
        number:        p.printer_number != null ? p.printer_number : null,
        ip:            p.printer_ip || null,
        transport:     p.printer_ip ? 'eth' : 'usb',
        type:          p.printer_type || 'kitchen',
        status:        p.status || 'unknown',
        last_seen_at:  p.last_seen_at || null,
      }));
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'running', configured, version: AGENT_VERSION, restaurant_name: RESTAURANT_NAME, logo_url: BRANDING_LOGO_URL, printer: { usb: usbDirectPort || usbWinPrinter || null, ip: PRINTER_IP, port: PRINTER_PORT, mode: usbDirectPort ? 'usb-direct' : usbWinPrinter ? 'usb-spooler' : 'network' }, printers, stations_configured: stationsConfigured(), printed, failed, analytics_queued: _readQueue().length }));
    return;
  }

  if (req.method === 'GET' && req.url === '/analytics') {
    const q = _readQueue();
    const summary = {};
    for (const e of q) summary[e.event] = (summary[e.event] || 0) + 1;
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ queued: q.length, summary, recent: q.slice(-20) }));
    return;
  }

  // ─── LOCAL STORE ENDPOINTS (consumed by ui.ps1) ─────────────────────────
  if (req.method === 'GET' && req.url.startsWith('/local/stats')) {
    const u = new URL(req.url, 'http://x');
    const period = u.searchParams.get('period') || 'today';
    (async () => {
      try {
        const live = await stationReports('stats', { period });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(live));
      } catch (_) {
        // Server unreachable — fall back to this PC's local cache so the
        // page still shows something instead of erroring out.
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(store.getStats(period)));
      }
    })();
    return;
  }

  if (req.method === 'GET' && req.url.startsWith('/local/bills')) {
    const u = new URL(req.url, 'http://x');
    const start = u.searchParams.get('start') || null;
    const end   = u.searchParams.get('end')   || null;
    (async () => {
      try {
        const params = {};
        if (start) params.start = start;
        if (end)   params.end   = end;
        const live = await stationReports('bills', params);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(live));
      } catch (_) {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(store.getBills(start, end)));
      }
    })();
    return;
  }

  if (req.method === 'GET' && req.url.startsWith('/local/orders')) {
    const u = new URL(req.url, 'http://x');
    const date = u.searchParams.get('date') || null;
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(store.getOrders(date)));
    return;
  }

  if (req.method === 'GET' && req.url === '/local/tables') {
    (async () => {
      try {
        const rows = await supabaseGet('tables', { restaurant_id: RESTAURANT_ID }, 200);
        const today = new Date().toISOString().slice(0, 10);
        const todayOrders = store.getOrders(today);
        const occupiedNums = new Set(todayOrders.map(o => String(o.table)));

        // This Station's own open orders — the offline-first truth. Consulted
        // first because a table can be opened by typing its number, which starts
        // an order without ever creating a `tables` row, and because an order
        // taken during an internet cut reaches Supabase only later.
        const localActive = _loadActiveOrders();
        const localLive = Object.entries(localActive).filter(([, o]) =>
          o && Array.isArray(o.items) && o.items.some(i => i && i.status !== 'cancelled_by_admin'));
        const localNums = new Set(localLive.map(([n]) => String(n)));

        // Live order state for the 4-colour floor map: which tables have an
        // active order, and which of those hold "secondary" plates (s1–s4)
        // still waiting to be fired/reclaimed (yellow). Best-effort: any failure
        // just leaves the map on the occupied/free colours.
        const heldTables = new Set();
        const remoteOccupied = new Set();
        for (const [num, o] of localLive) {
          if ((o.items || []).some(i => i.status === 'pending' && i.course && i.course !== 'direct')) {
            heldTables.add(String(num));
          }
        }
        try {
          const activeOrders = await supabaseGetRaw(
            'orders?restaurant_id=eq.' + encodeURIComponent(RESTAURANT_ID) +
            '&status=not.in.(paid,cancelled)&select=id,table_number&limit=300'
          );
          // Any open order (incl. ones taken on the waiter apps) occupies its table.
          for (const o of (activeOrders || [])) remoteOccupied.add(String(o.table_number));
          const orderById = new Map((activeOrders || []).map(o => [o.id, o]));
          const orderIds = (activeOrders || []).map(o => o.id);
          if (orderIds.length) {
            const idList = orderIds.map(encodeURIComponent).join(',');
            const items = await supabaseGetRaw(
              'order_items?order_id=in.(' + idList + ')&status=eq.pending' +
              '&select=order_id,course,status&limit=2000'
            );
            for (const it of (items || [])) {
              if (it.course && it.course !== 'direct') {
                const o = orderById.get(it.order_id);
                if (o) heldTables.add(String(o.table_number));
              }
            }
          }
        } catch (_) { /* leave map on occupied/free colours */ }

        const tables = _mergeTablesView({ rows, localNums, occupiedNums, remoteOccupied, heldTables });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(tables));
      } catch(e) {
        res.writeHead(500); res.end(JSON.stringify({ error: e.message }));
      }
    })();
    return;
  }

  // Delete every table on a floor/zone (POST so zone names need no URL encoding).
  if (req.method === 'POST' && req.url === '/local/tables/delete-zone') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const { zone } = JSON.parse(body || '{}');
        await stationDb('table.delete_zone', { zone: zone || null });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch(e) { res.writeHead(500); res.end(JSON.stringify({ error: e.message })); }
    });
    return;
  }

  // Create a table on a floor (server assigns the next number).
  if (req.method === 'POST' && req.url === '/local/tables') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const b = JSON.parse(body || '{}');
        const r = await stationDb('table.create', {
          zone: b.zone || null, pos_x: b.pos_x, pos_y: b.pos_y,
          capacity: b.capacity, shape: b.shape, table_number: b.table_number,
        });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(r || { ok: true }));
      } catch(e) { res.writeHead(500); res.end(JSON.stringify({ error: e.message })); }
    });
    return;
  }

  // Update one table (move = patch pos_x/pos_y; edit = capacity/shape/zone/number).
  if (req.method === 'PATCH' && req.url.startsWith('/local/tables/')) {
    const id = decodeURIComponent(req.url.slice('/local/tables/'.length));
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const patch = JSON.parse(body || '{}');
        await stationDb('table.update', { id, patch });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch(e) { res.writeHead(500); res.end(JSON.stringify({ error: e.message })); }
    });
    return;
  }

  // Delete one table.
  if (req.method === 'DELETE' && req.url.startsWith('/local/tables/')) {
    const id = decodeURIComponent(req.url.slice('/local/tables/'.length));
    (async () => {
      try {
        await stationDb('table.delete', { id });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch(e) { res.writeHead(500); res.end(JSON.stringify({ error: e.message })); }
    })();
    return;
  }

  // ─── ORDERING — Station POS (offline-first) ─────────────────────────────
  // Local-first ordering: all state lives in active-orders.json, printing is
  // always local, Supabase sync is best-effort in the background. The Station
  // keeps taking orders even with zero internet.

  if (req.method === 'GET' && req.url.startsWith('/local/order/items')) {
    const u = new URL(req.url, 'http://x');
    const tableNum = u.searchParams.get('table');
    if (!tableNum) { res.writeHead(400); res.end(JSON.stringify({ error: 'table required' })); return; }
    // Reconcile with Supabase first so orders taken on the waiter web/Flutter
    // apps show up here. Falls back to local state when offline.
    (async () => {
      let order;
      try { order = await _pullOrderFromSupabase(tableNum); }
      catch { order = _activeOrder(tableNum); }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        order_id: order ? order.order_id : null,
        items: order ? order.items : [],
      }));
    })();
    return;
  }

  if (req.method === 'POST' && req.url === '/local/order/send') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const b = JSON.parse(body || '{}');
        const tableNum = b.table_number;
        const cartItems = b.items || [];
        const guestCount = b.guest_count || 1;
        if (!tableNum || !cartItems.length) {
          res.writeHead(400); res.end(JSON.stringify({ error: 'table_number and items required' }));
          return;
        }
        const r = await stationSendOrder(tableNum, cartItems, guestCount);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(r));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    });
    return;
  }

  if (req.method === 'POST' && req.url === '/local/order/reclaim') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const b = JSON.parse(body || '{}');
        const tableNum = b.table_number;
        if (!tableNum) { res.writeHead(400); res.end(JSON.stringify({ error: 'table_number required' })); return; }
        const r = await stationReclaimOrder(tableNum);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(r));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    });
    return;
  }

  if (req.method === 'POST' && req.url === '/local/order/close') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const b = JSON.parse(body || '{}');
        const tableNum = b.table_number;
        if (!tableNum) { res.writeHead(400); res.end(JSON.stringify({ error: 'table_number required' })); return; }
        const r = await stationCloseOrder(tableNum);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(r));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    });
    return;
  }

  if (req.method === 'POST' && req.url === '/local/order/print-check') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const b = JSON.parse(body || '{}');
        if (!b.table_number) { res.writeHead(400); res.end(JSON.stringify({ error: 'table_number required' })); return; }
        const r = await stationPrintCheck(b.table_number);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(r));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    });
    return;
  }

  if (req.method === 'POST' && req.url === '/local/order/cancel') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const b = JSON.parse(body || '{}');
        if (!b.table_number) { res.writeHead(400); res.end(JSON.stringify({ error: 'table_number required' })); return; }
        const r = await stationCancelOrder(b.table_number);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(r));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    });
    return;
  }

  if (req.method === 'POST' && req.url === '/local/order/transfer') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const b = JSON.parse(body || '{}');
        if (!b.from_table || !b.to_table) { res.writeHead(400); res.end(JSON.stringify({ error: 'from_table and to_table required' })); return; }
        const r = await stationTransferOrder(b.from_table, b.to_table);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(r));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    });
    return;
  }

  // Per-unit order actions (clone of the waiter web app's TableActionsPopup).
  if (req.method === 'POST' && req.url === '/local/order/cancel-items') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const b = JSON.parse(body || '{}');
        const r = await stationCancelItems(b.table_number, b.items);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(r));
      } catch (e) { res.writeHead(500, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ ok: false, error: e.message })); }
    });
    return;
  }

  if (req.method === 'POST' && req.url === '/local/order/invite-items') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const b = JSON.parse(body || '{}');
        const r = await stationInviteItems(b.table_number, b.ids);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(r));
      } catch (e) { res.writeHead(500, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ ok: false, error: e.message })); }
    });
    return;
  }

  if (req.method === 'POST' && req.url === '/local/order/transfer-items') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const b = JSON.parse(body || '{}');
        const r = await stationTransferItems(b.from_table, b.to_table, b.items);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(r));
      } catch (e) { res.writeHead(500, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ ok: false, error: e.message })); }
    });
    return;
  }

  if (req.method === 'GET' && req.url.startsWith('/local/report')) {
    const u = new URL(req.url, 'http://x');
    const date  = u.searchParams.get('date')  || new Date().toISOString().slice(0,10);
    const start = u.searchParams.get('start') || '00:00';
    const end   = u.searchParams.get('end')   || '23:59';
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(store.dailyReport(date, start, end)));
    return;
  }

  // ─── MENU — read ────────────────────────────────────────────────────────
  // Fetches categories + items from Supabase, normalises them for the UI, and
  // caches the result to disk. When offline, serves the last cached snapshot so
  // the Menu tab still renders. Add an optional ?fresh=1 to force a re-fetch.
  if (req.method === 'GET' && req.url === '/local/menu') {
    (async () => {
      try {
        const [cats, items] = await Promise.all([
          supabaseGet('menu_categories', { restaurant_id: RESTAURANT_ID }, 500),
          supabaseGet('menu_items',      { restaurant_id: RESTAURANT_ID }, 2000),
        ]);
        if (!Array.isArray(cats) || !Array.isArray(items)) throw new Error('bad payload');

        const categories = cats
          .map(c => ({ id: c.id, name: c.name || 'Category', section: c.section || '', order_index: c.order_index ?? 0 }))
          .sort((a, b) => a.order_index - b.order_index);

        const normItems = items
          .filter(i => !i.is_addon)
          .map(i => ({
            id:           i.id,
            name:         i.name || 'Item',
            price:        Number(i.price) || 0,
            description:  i.description || '',
            category_id:  i.menu_category_id || null,
            available:    i.is_available !== false,
            order_index:  i.order_index ?? 0,
            // Per-item toppings from the "Item Customization" editor
            // (modifiers.addons = [{id,name,price}]). The Station's add-on
            // modal shows these first, then the global add-ons below.
            addons: (i.modifiers && Array.isArray(i.modifiers.addons) ? i.modifiers.addons : [])
              .filter(a => a && (a.name || '').trim())
              .map(a => ({ id: a.id || ('mod-' + a.name), name: a.name, price: Number(a.price) || 0 })),
          }))
          .sort((a, b) => a.order_index - b.order_index);

        const addons = items
          .filter(i => i.is_addon)
          .map(i => ({ id: i.id, name: i.name || 'Add-on', price: Number(i.price) || 0, available: i.is_available !== false }));

        const payload = { categories, items: normItems, addons, synced_at: new Date().toISOString(), source: 'supabase' };
        try { fs.writeFileSync(MENU_CACHE_FILE, JSON.stringify(payload)); } catch {}
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(payload));
      } catch (e) {
        // Offline / fetch failed — fall back to the cached snapshot.
        try {
          const cached = JSON.parse(fs.readFileSync(MENU_CACHE_FILE, 'utf8'));
          cached.source = 'cache';
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify(cached));
        } catch {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ categories: [], items: [], addons: [], synced_at: null, source: 'empty' }));
        }
      }
    })();
    return;
  }

  // ─── MENU — translate everything ────────────────────────────────────────
  // Fills in every missing translation for this restaurant's categories and
  // items. All the work happens server-side (autoTranslateMenu); we just
  // trigger it and report how many rows it touched. Needs a connection, and
  // says so plainly when there isn't one.
  if (req.method === 'POST' && req.url === '/local/menu/translate') {
    (async () => {
      try {
        const r = await stationDb('menu.translate', {});
        if (r && r.error) throw new Error(r.error);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, translated: (r && r.translated) || 0, languages: (r && r.target_languages) || [] }));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: e.message || String(e) }));
      }
    })();
    return;
  }

  // ─── KITCHEN STATIONS (multi-printer routing) ───────────────────────────
  // Everything the Kitchen Stations tab needs in one round trip: the detected
  // printers, the kitchen station bound to each, and the menu categories routed
  // to it. kitchens/kitchen_categories are anon-readable so these are direct
  // reads; only the writes below need the token-authed backend.
  //
  // Cached to disk so the tab still renders during an outage — you can see how
  // routing is currently configured even when you can't change it.
  if (req.method === 'GET' && req.url === '/local/kitchen-stations') {
    (async () => {
      try {
        const [kitchens, kitchenCats, cats] = await Promise.all([
          supabaseGet('kitchens',           { restaurant_id: RESTAURANT_ID }, 200),
          supabaseGet('kitchen_categories', { restaurant_id: RESTAURANT_ID }, 500),
          supabaseGet('menu_categories',    { restaurant_id: RESTAURANT_ID }, 500),
        ]);
        if (!Array.isArray(kitchens) || !Array.isArray(kitchenCats) || !Array.isArray(cats)) {
          throw new Error('bad payload');
        }

        const categories = cats
          .map(c => ({ id: c.id, name: c.name || 'Category', order_index: c.order_index ?? 0 }))
          .sort((a, b) => a.order_index - b.order_index);

        // One entry per printer, with its station and current category set.
        const printers = (printersCache || []).map(p => {
          const k = kitchens.find(x => x.printer_config_id === p.id) || null;
          const assigned = k ? kitchenCats.filter(kc => kc.kitchen_id === k.id).map(kc => kc.menu_category_id) : [];
          return {
            id:            p.id,
            name:          p.name || (p.printer_number != null ? 'Printer ' + p.printer_number : 'Printer'),
            printer_number: p.printer_number ?? null,
            printer_ip:    p.printer_ip || null,
            // No IP means it's reached over USB rather than the network.
            mode:          p.printer_ip ? 'ETH' : 'USB',
            printer_type:  p.printer_type || 'kitchen',
            kitchen_id:    k ? k.id : null,
            kitchen_name:  k ? k.name : null,
            category_ids:  assigned,
          };
        });

        const payload = {
          printers, categories,
          kitchens: kitchens.map(k => ({
            id: k.id, name: k.name || 'Kitchen', printer_config_id: k.printer_config_id || null,
            is_active: k.is_active !== false,
            category_count: kitchenCats.filter(kc => kc.kitchen_id === k.id).length,
          })),
          stations_configured: stationsConfigured(),
          synced_at: new Date().toISOString(), source: 'supabase',
        };
        try { fs.writeFileSync(STATIONS_CACHE_FILE, JSON.stringify(payload)); } catch {}
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(payload));
      } catch (e) {
        try {
          const cached = JSON.parse(fs.readFileSync(STATIONS_CACHE_FILE, 'utf8'));
          cached.source = 'cache';
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify(cached));
        } catch {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ printers: [], categories: [], kitchens: [], stations_configured: false, synced_at: null, source: 'empty' }));
        }
      }
    })();
    return;
  }

  // Save one printer's routing: ensure a kitchen station exists for it, then
  // replace its category set. Mirrors the web PrinterRoutingDialog's save.
  // Needs the backend (writes aren't anon-permitted), so it fails cleanly while
  // offline rather than pretending to have saved.
  if (req.method === 'POST' && req.url === '/local/kitchen-stations/routing') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const data = JSON.parse(body || '{}');
        const printerId = data.printer_config_id;
        if (!printerId) throw new Error('printer_config_id required');
        const categoryIds = Array.isArray(data.category_ids) ? data.category_ids : [];

        let kitchenId = data.kitchen_id || null;
        if (!kitchenId) {
          const created = await stationDb('kitchen.create', {
            name: data.name || 'Printer',
            printer_config_id: printerId,
          });
          if (created && created.error) throw new Error(created.error);
          kitchenId = created && created.kitchen ? created.kitchen.id : null;
          if (!kitchenId) throw new Error('could not create the kitchen station');
        }

        const r = await stationDb('kitchen_categories.set', { kitchen_id: kitchenId, category_ids: categoryIds });
        if (r && r.error) throw new Error(r.error);

        // Routing changed — refresh the cache that printKitchenRouted consults
        // so the very next ticket honours it instead of waiting up to 30s.
        await refreshCategoryRouting();

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, kitchen_id: kitchenId, count: categoryIds.length }));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: e.message || String(e) }));
      }
    });
    return;
  }

  // Remove a kitchen station (its category assignments go with it).
  if (req.method === 'DELETE' && req.url.startsWith('/local/kitchen-stations/')) {
    const kitchenId = decodeURIComponent(req.url.slice('/local/kitchen-stations/'.length));
    (async () => {
      try {
        const r = await stationDb('kitchen.delete', { kitchen_id: kitchenId });
        if (r && r.error) throw new Error(r.error);
        await refreshCategoryRouting();
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: e.message || String(e) }));
      }
    })();
    return;
  }

  // ─── MENU — create item ─────────────────────────────────────────────────
  if (req.method === 'POST' && req.url === '/local/menu/item') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const d = JSON.parse(body || '{}');
        if (!d.name || !String(d.name).trim()) throw new Error('Name is required');
        const r = await stationDb('menu_item.create', {
          name:             String(d.name).trim(),
          description:      d.description || '',
          price:            Number(d.price) || 0,
          menu_category_id: d.menu_category_id || null,
          is_available:     d.is_available !== false,
          is_addon:         d.is_addon === true,
        });
        log('Menu item created via Station: ' + d.name);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, item: r && r.item }));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    });
    return;
  }

  // ─── MENU — update item ─────────────────────────────────────────────────
  if (req.method === 'PATCH' && req.url.startsWith('/local/menu/item/')) {
    const id = decodeURIComponent(req.url.slice('/local/menu/item/'.length));
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const d = JSON.parse(body || '{}');
        const patch = {};
        if (d.name !== undefined)             patch.name = String(d.name).trim();
        if (d.description !== undefined)      patch.description = d.description || '';
        if (d.price !== undefined)            patch.price = Number(d.price) || 0;
        if (d.menu_category_id !== undefined) patch.menu_category_id = d.menu_category_id || null;
        if (d.is_available !== undefined)     patch.is_available = d.is_available !== false;
        if (d.is_addon !== undefined)         patch.is_addon = d.is_addon === true;
        await stationDb('menu_item.update', { id, patch });
        log('Menu item updated via Station: ' + id);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    });
    return;
  }

  // ─── MENU — delete item ─────────────────────────────────────────────────
  if (req.method === 'DELETE' && req.url.startsWith('/local/menu/item/')) {
    const id = decodeURIComponent(req.url.slice('/local/menu/item/'.length));
    (async () => {
      try {
        await stationDb('menu_item.delete', { id });
        log('Menu item deleted via Station: ' + id);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    })();
    return;
  }

  // ─── MENU — create category ─────────────────────────────────────────────
  if (req.method === 'POST' && req.url === '/local/menu/category') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const d = JSON.parse(body || '{}');
        if (!d.name || !String(d.name).trim()) throw new Error('Name is required');
        // slug is generated server-side (menu_categories.slug is NOT NULL).
        const r = await stationDb('menu_category.create', {
          name:        String(d.name).trim(),
          section:     d.section || 'menu',
          order_index: Number(d.order_index) || 0,
        });
        log('Menu category created via Station: ' + d.name);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, category: r && r.category }));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    });
    return;
  }

  // ─── MENU — rename / update category ────────────────────────────────────
  if (req.method === 'PATCH' && req.url.startsWith('/local/menu/category/')) {
    const id = decodeURIComponent(req.url.slice('/local/menu/category/'.length));
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const d = JSON.parse(body || '{}');
        const patch = {};
        if (d.name !== undefined)    patch.name = String(d.name).trim();
        if (d.section !== undefined) patch.section = d.section || 'menu';
        await stationDb('menu_category.update', { id, patch });
        log('Menu category updated via Station: ' + id);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    });
    return;
  }

  // ─── MENU — delete category (and its items) ─────────────────────────────
  if (req.method === 'DELETE' && req.url.startsWith('/local/menu/category/')) {
    const id = decodeURIComponent(req.url.slice('/local/menu/category/'.length));
    (async () => {
      try {
        // Server deletes the category's items first (mirrors the web behaviour).
        const r = await stationDb('menu_category.delete', { id });
        log('Menu category deleted via Station: ' + id + ' (+' + ((r && r.deleted_items) || 0) + ' items)');
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    })();
    return;
  }

  // ─── PRINTERS — list ────────────────────────────────────────────────────
  // Returns the restaurant's printer_configs (excluding the internal "scan"
  // heartbeat row) merged with this agent's live transport state.
  if (req.method === 'GET' && req.url === '/local/printers') {
    (async () => {
      let rows = [];
      try { rows = await supabaseGet('printer_configs', { restaurant_id: RESTAURANT_ID }, 100); } catch {}
      if (!Array.isArray(rows)) rows = [];
      const printers = rows
        .filter(c => c.printer_type !== 'scan')
        .map(c => ({
          id:        c.id,
          name:      c.name || 'Printer',
          type:      c.printer_type || 'kitchen',
          ip:        c.printer_ip || '',
          port:      9100, // thermal printers always listen on 9100
          active:    c.is_active !== false,
          status:    c.status || 'unknown',
          last_seen: c.last_seen || c.updated_date || null,
        }));
      const live = {
        usb:  usbDirectPort || usbWinPrinter || null,
        mode: usbDirectPort ? 'usb-direct' : usbWinPrinter ? 'usb-spooler' : (PRINTER_IP ? 'network' : 'none'),
        ip:   PRINTER_IP || '',
        port: PRINTER_PORT,
      };
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ printers, live }));
    })();
    return;
  }

  // ─── PRINTERS — add ─────────────────────────────────────────────────────
  if (req.method === 'POST' && req.url === '/local/printers') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const d = JSON.parse(body || '{}');
        const ip = (d.ip || '').trim();
        if (ip && !/^\d+\.\d+\.\d+\.\d+$/.test(ip)) throw new Error('Invalid IP');
        const r = await stationDb('printer_config.create', { values: {
          name:          (d.name || 'Printer').slice(0, 60),
          printer_type:  d.type || 'kitchen',
          printer_ip:    ip || null,
          is_active:     true,
        } });
        log('Printer added via Station: ' + (d.name || 'Printer') + ' ' + ip);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, printer: r && r.printer }));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    });
    return;
  }

  // ─── PRINTERS — test print ──────────────────────────────────────────────
  if (req.method === 'POST' && req.url === '/local/printers/test') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const d = JSON.parse(body || '{}');
        const ip = (d.ip || '').trim();
        const port = Number(d.port) || 9100;
        const data = buildTestTicket(d.name || 'Printer');
        if (ip && /^\d+\.\d+\.\d+\.\d+$/.test(ip)) {
          await sendViaNetwork(data, ip, port); // force the specific network printer
        } else {
          await sendToPrinter(data); // active transport (USB / default network)
        }
        log('Test print sent to ' + (ip ? ip + ':' + port : 'active printer'));
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        log('Test print failed: ' + e.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    });
    return;
  }

  // ─── PRINTERS — update (rename / change IP / change type) ───────────────
  if (req.method === 'PATCH' && req.url.startsWith('/local/printers/')) {
    const pid = decodeURIComponent(req.url.slice('/local/printers/'.length));
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const d = JSON.parse(body || '{}');
        const patch = {};
        if (d.name !== undefined) patch.name = String(d.name).slice(0, 60);
        if (d.type !== undefined) patch.printer_type = d.type;
        if (d.ip !== undefined) {
          const ip = String(d.ip).trim();
          if (ip && !/^\d+\.\d+\.\d+\.\d+$/.test(ip)) throw new Error('Invalid IP');
          patch.printer_ip = ip || null;
        }
        if (d.is_active !== undefined) patch.is_active = d.is_active !== false;
        await stationDb('printer_config.update', { id: pid, patch });
        log('Printer updated via Station: ' + pid);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    });
    return;
  }

  // ─── PRINTERS — delete ──────────────────────────────────────────────────
  if (req.method === 'DELETE' && req.url.startsWith('/local/printers/')) {
    const pid = decodeURIComponent(req.url.slice('/local/printers/'.length));
    (async () => {
      try {
        await stationDb('printer_config.delete', { id: pid });
        log('Printer removed via Station: ' + pid);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    })();
    return;
  }

  // ─── TICKET SETTINGS ────────────────────────────────────────────────────
  // The appearance/behaviour of printed tickets lives in the kitchen
  // printer_config's `settings` JSONB. Whoever prints (web / Flutter / agent)
  // loads these and passes them with the job, so editing them here changes
  // every future ticket. We expose the functional subset that actually alters
  // the printout (copies, show_* toggles, footers, formats, ticket mode).
  if (req.method === 'GET' && req.url === '/local/ticket-settings') {
    (async () => {
      try {
        const rows = await supabaseGet('printer_configs', { restaurant_id: RESTAURANT_ID, printer_type: 'kitchen' }, 5);
        const cfg = Array.isArray(rows) ? rows.find(c => c.printer_type === 'kitchen') : null;
        const s = (cfg && cfg.settings) ? cfg.settings : {};
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ has_config: !!cfg, has_logo: !!s.logo_raster_b64, settings: pickTicketSettings(s) }));
      } catch (e) {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ has_config: false, settings: pickTicketSettings({}), error: e.message }));
      }
    })();
    return;
  }

  if (req.method === 'PATCH' && req.url === '/local/ticket-settings') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const incoming = pickTicketSettings(JSON.parse(body || '{}'));
        // Read current kitchen settings (still anon-readable) so we merge rather
        // than clobber; the WRITE goes through the token-authed server.
        const rows = await supabaseGet('printer_configs', { restaurant_id: RESTAURANT_ID, printer_type: 'kitchen' }, 5);
        const cfg = Array.isArray(rows) ? rows.find(c => c.printer_type === 'kitchen') : null;
        const merged = { ...((cfg && cfg.settings) || {}), ...incoming };
        // Resolve the printed labels from the chosen language + any overrides,
        // so the ticket builders (which read s.labels) print in that language.
        merged.labels = resolveTicketLabels(merged.ticket_language || 'en', merged.label_overrides);
        await stationDb('kitchen_settings.save', { settings: merged });
        log('Ticket settings saved via Station (lang=' + (merged.ticket_language || 'en') + ')');
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    });
    return;
  }

  // Send a sample ticket of the chosen type so the user can preview a real
  // print with the current (possibly unsaved) settings.
  if (req.method === 'POST' && req.url === '/local/ticket-settings/test') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const d = JSON.parse(body || '{}');
        const type = d.type === 'check' ? 'check' : (d.type === 'cancel' || d.type === 'transfer' ? d.type : 'kitchen');
        const settings = pickTicketSettings(d.settings || {});
        settings.labels = resolveTicketLabels(settings.ticket_language || 'en', settings.label_overrides);
        const sample = {
          type,
          restaurant_id:   RESTAURANT_ID,
          restaurant_name: RESTAURANT_NAME || 'Restaurant',
          table_number:    '5',
          waiter_name:     'Sample',
          from_table:      '5',
          to_table:        '8',
          cancelled_by:    'Manager',
          currency:        'EUR',
          time:            new Date().toISOString(),
          total:           12.0,
          items: [
            { qty: 2, name: 'Expresso',     price: 2.0 },
            { qty: 1, name: 'Croissant',    price: 3.5 },
            { qty: 1, name: 'Orange Juice', price: 4.5 },
          ],
          settings,
        };
        let data;
        switch (type) {
          case 'check':    data = buildCheckTicket(sample); break;
          case 'cancel':   data = buildCancelTicket(sample); break;
          case 'transfer': data = buildTransferTicket(sample); break;
          default:         data = buildKitchenTicket(sample);
        }
        await sendToPrinter(data);
        log('Ticket-settings test print (' + type + ')');
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        log('Ticket test print failed: ' + e.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    });
    return;
  }

  // ─── LOGO — rasterize + store ───────────────────────────────────────────
  // The Station (PowerShell) decodes/resizes the image and posts the per-pixel
  // luminance (0..255, one byte each, row-major). We Floyd–Steinberg dither and
  // pack to ESC/POS GS v 0 raster bytes (identical to the web's imageToEscPos),
  // then store it in the kitchen config so every ticket can print it.
  if (req.method === 'POST' && req.url === '/local/logo') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const d = JSON.parse(body || '{}');
        const w = Number(d.width), h = Number(d.height);
        if (!w || !h || !d.gray_b64) throw new Error('Missing image data');
        const gray = Buffer.from(d.gray_b64, 'base64');
        if (gray.length !== w * h) throw new Error('Gray buffer size mismatch (' + gray.length + ' != ' + (w * h) + ')');
        const g = new Float32Array(w * h);
        for (let i = 0; i < w * h; i++) g[i] = gray[i];
        const padW = (w + 7) & ~7;
        const bytesPerRow = padW >> 3;
        const out = Buffer.alloc(bytesPerRow * h, 0);
        for (let y = 0; y < h; y++) {
          for (let x = 0; x < w; x++) {
            const i = y * w + x, old = g[i], isBlack = old < 128, nv = isBlack ? 0 : 255, err = old - nv;
            if (x + 1 < w) g[i + 1] += err * 7 / 16;
            if (y + 1 < h) { if (x > 0) g[i + w - 1] += err * 3 / 16; g[i + w] += err * 5 / 16; if (x + 1 < w) g[i + w + 1] += err * 1 / 16; }
            if (isBlack) out[y * bytesPerRow + (x >> 3)] |= 0x80 >> (x & 7);
          }
        }
        const xL = bytesPerRow & 0xff, xH = (bytesPerRow >> 8) & 0xff, yL = h & 0xff, yH = (h >> 8) & 0xff;
        const full = Buffer.concat([
          Buffer.from([0x1B, 0x61, 0x01]),                          // ALIGN_CENTER
          Buffer.from([0x1D, 0x76, 0x30, 0x00, xL, xH, yL, yH]),    // GS v 0
          out,
          Buffer.from([0x0A, 0x1B, 0x61, 0x00]),                    // LF + ALIGN_LEFT
        ]);
        const b64 = full.toString('base64');
        const rows = await supabaseGet('printer_configs', { restaurant_id: RESTAURANT_ID, printer_type: 'kitchen' }, 5);
        const cfg = Array.isArray(rows) ? rows.find(c => c.printer_type === 'kitchen') : null;
        const merged = { ...((cfg && cfg.settings) || {}), logo_raster_b64: b64, logo_print_enabled: d.enabled !== false, logo_size: d.size || 'medium' };
        await stationDb('kitchen_settings.save', { settings: merged });
        log('Logo set via Station (' + w + 'x' + h + ')');
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    });
    return;
  }

  // ─── STATION AI — chat ──────────────────────────────────────────────────
  if (req.method === 'POST' && req.url === '/local/ai') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const d = JSON.parse(body || '{}');
        if (!d.message) throw new Error('message required');
        // Forward the whole conversation to the unified server brain. The UI
        // sends history as [{ role, text }]; the agent expects [{ role, content }].
        const hist = Array.isArray(d.history) ? d.history : [];
        const messages = hist
          .filter(h => h && (h.role === 'user' || h.role === 'assistant') && (h.text || h.content))
          .map(h => ({ role: h.role, content: String(h.text || h.content) }));
        // An attached photo rides on the current turn as content blocks, so the
        // model can read a menu/ticket/printer label. The server validates the
        // media type + size; we just pass it through.
        if (d.image && d.image.data && d.image.media_type) {
          messages.push({
            role: 'user',
            content: [
              { type: 'text', text: String(d.message) },
              { type: 'image', source: { type: 'base64', media_type: String(d.image.media_type), data: String(d.image.data) } },
            ],
          });
        } else {
          messages.push({ role: 'user', content: String(d.message) });
        }
        // Ship the live local order state with the turn: Supabase alone would
        // make the agent blind to tables opened offline or not yet sent.
        let state = null;
        try { state = _stationStateForAI(); } catch (e) { log('AI state snapshot failed: ' + e.message); }
        const out = await stationAgent(messages, state);
        // Carry out anything the agent delegated to this Station (local printer
        // work it can't do server-side). Best-effort and non-blocking for the
        // reply: a failure is logged, never swallows the answer the user needs.
        for (const ca of (out.clientActions || [])) {
          try {
            await runClientAction(ca.action, ca.args);
            log('AI ran local action: ' + ca.action);
          } catch (e) {
            log('AI local action failed (' + ca.action + '): ' + (e && e.message));
          }
        }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        // Keep the ui.ps1 contract: { ok, reply, actions } — actions are the
        // tools the agent ran, shown as a small trace bubble.
        res.end(JSON.stringify({ ok: true, reply: out.reply, actions: (out.steps || []).map(s => s && s.tool).filter(Boolean) }));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    });
    return;
  }

  // ─── LOGO — remove ──────────────────────────────────────────────────────
  if (req.method === 'POST' && req.url === '/local/logo/remove') {
    (async () => {
      try {
        const rows = await supabaseGet('printer_configs', { restaurant_id: RESTAURANT_ID, printer_type: 'kitchen' }, 5);
        const cfg = Array.isArray(rows) ? rows.find(c => c.printer_type === 'kitchen') : null;
        if (cfg) {
          const merged = { ...(cfg.settings || {}), logo_raster_b64: '', logo_print_enabled: false };
          await stationDb('kitchen_settings.save', { settings: merged });
        }
        log('Logo removed via Station');
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    })();
    return;
  }

  if (req.method === 'POST' && req.url === '/local/reprint') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const { id } = JSON.parse(body);
        const bill = store.findBill(id);
        if (!bill) {
          res.writeHead(404, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: false, error: 'Bill not found' }));
          return;
        }
        const ticket = {
          type:                'check',
          restaurant_id:       RESTAURANT_ID,
          restaurant_name:     RESTAURANT_NAME,
          table_number:        bill.table,
          waiter_name:         bill.waiter,
          currency:            bill.currency || 'EUR',
          time:                bill.date,
          order_id:            bill.order_id,
          payment_method:      bill.payment_method,
          total:               bill.total,
          guest_count:         bill.guest_count,
          bill_url:            bill.bill_url,
          items:               bill.items || [],
          settings:            {},
        };
        const data = buildCheckTicket(ticket);
        await sendToPrinter(data);
        log('Reprinted bill ' + bill.id);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        log('Reprint failed: ' + e.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    });
    return;
  }

  // Staff endpoints — merge Supabase (when online) with local store
  if (req.method === 'GET' && req.url === '/local/staff') {
    (async () => {
      const local = store.getStaff();
      let members = [], tokens = [], staffRoles = [], rolesTable = [];
      try {
        // staff_members + waiter_tokens are no longer anon-readable (migration
        // 0022) — fetch the whole Staff tab through the token-authed server,
        // scoped server-side to this restaurant.
        const r = await stationDb('staff.list', {});
        if (r) {
          members    = Array.isArray(r.members)    ? r.members    : [];
          tokens     = Array.isArray(r.tokens)     ? r.tokens     : [];
          staffRoles = Array.isArray(r.staffRoles) ? r.staffRoles : [];
          rolesTable = Array.isArray(r.rolesTable) ? r.rolesTable : [];
        }
      } catch { /* offline or pre-deploy server — fall back to local store only */ }
      if (!Array.isArray(members))    members = [];
      if (!Array.isArray(tokens))     tokens = [];
      if (!Array.isArray(staffRoles)) staffRoles = [];
      if (!Array.isArray(rolesTable)) rolesTable = [];

      const linkBase = 'https://www.lightmenu.app';

      const rolesById = {};
      for (const r of rolesTable) rolesById[r.id] = { name: r.name || r.label || 'Role', color: r.color || null };

      const remoteNorm = members.map(m => {
        const activeTok = tokens.find(t => t.staff_member_id === m.id && t.is_active);
        const anyTok    = activeTok || tokens.find(t => t.staff_member_id === m.id);
        const sRoles    = staffRoles.filter(sr => sr.staff_member_id === m.id);
        const roleEntry = sRoles.length ? rolesById[sRoles[0].role_id] : null;
        const roleName  = roleEntry ? roleEntry.name : (m.role || 'Waiter');
        const roleColor = roleEntry ? roleEntry.color : null;
        return {
          id:          m.id,
          name:        m.display_name || m.user_email || m.full_name || 'Staff',
          role:        roleName,
          role_color:  roleColor,
          waiter_link: anyTok ? `${linkBase}/waiter/${anyTok.token}` : null,
          created_at:  m.created_date || m.created_at || null,
          last_used:   m.last_login_at || (anyTok && anyTok.last_used_at) || null,
          active:      activeTok ? true : false,
          synced:      true,
          source:      'supabase',
        };
      });

      const remoteIds = new Set(remoteNorm.map(x => x.id));
      const localOnly = local.filter(l => !remoteIds.has(l.id)).map(l => ({ ...l, source: 'local' }));
      const merged = [...remoteNorm, ...localOnly];

      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(merged));
    })();
    return;
  }

  if (req.method === 'POST' && req.url === '/local/staff') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const data = JSON.parse(body || '{}');
        if (!data.name) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Missing name' }));
          return;
        }
        let result = null;
        try {
          // Create staff + token atomically server-side (token-authed, scoped).
          const rpcResult = await stationDb('staff.create', {
            name:    data.name,
            role_id: data.role_id || null,
          });
          if (rpcResult && rpcResult.id) {
            result = { id: rpcResult.id, name: rpcResult.name, source: 'supabase' };
          }
        } catch { /* fall through to local */ }

        if (!result) {
          // RPC failed — likely because SQL not installed. Save locally WITHOUT
          // a token: a local token wouldn't work in Supabase anyway, and giving
          // one would mislead the user into thinking the waiter link is live.
          const entry = store.addStaff(data);
          result = { ...entry, local_only: true };
        }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: e.message }));
      }
    });
    return;
  }

  if (req.method === 'DELETE' && req.url.startsWith('/local/staff/')) {
    const staffId = decodeURIComponent(req.url.slice('/local/staff/'.length));
    (async () => {
      let supaOk = false;
      try {
        const result = await stationDb('staff.delete', { staff_id: staffId });
        supaOk = result && !result.error;
      } catch {}
      const localOk = store.removeStaff(staffId);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: supaOk || localOk }));
    })();
    return;
  }

  // Toggle staff active state (waiter_token.is_active)
  if (req.method === 'POST' && req.url.match(/^\/local\/staff\/[^/]+\/toggle$/)) {
    const staffId = decodeURIComponent(req.url.split('/')[3]);
    (async () => {
      try {
        const result = await stationDb('staff.toggle', { staff_id: staffId });
        if (result && result.error === 'not_found') {
          // local-only staff — toggle in store
          const active = store.toggleStaff(staffId);
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: true, active: active !== null ? active : false }));
        } else {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: true, active: result ? result.active : false }));
        }
      } catch (e) {
        // Offline — fall back to local store
        const active = store.toggleStaff(staffId);
        if (active !== null) {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: true, active, offline: true }));
        } else {
          res.writeHead(500, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: e.message }));
        }
      }
    })();
    return;
  }

  // Generate new waiter link (deactivate existing, create new)
  if (req.method === 'POST' && req.url.match(/^\/local\/staff\/[^/]+\/new_link$/)) {
    const staffId = decodeURIComponent(req.url.split('/')[3]);
    const isLocal = staffId.startsWith('STAFF-');
    (async () => {
      // Local-only staff lives only in the agent's file store — never in Supabase.
      // Generate a local token; warn the caller that the link won't work server-side.
      if (isLocal) {
        const newToken = genWaiterToken();
        const link = `https://www.lightmenu.app/waiter/${newToken}`;
        const updated = store.updateStaffLink(staffId, link);
        if (updated) {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: true, link, local_only: true }));
        } else {
          res.writeHead(404, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Staff not found' }));
        }
        return;
      }
      try {
        const result = await stationDb('staff.new_link', { staff_id: staffId });
        if (result && result.error) throw new Error(result.error);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, link: `https://www.lightmenu.app/waiter/${result.token}` }));
      } catch (e) {
        const msg = e.message || String(e);
        const sqlMissing = /404|not found|does not exist|PGRST202|PGRST201/i.test(msg);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
          error: sqlMissing ? 'sql_not_installed' : msg,
          detail: msg,
        }));
      }
    })();
    return;
  }

  // Change role
  if (req.method === 'POST' && req.url.match(/^\/local\/staff\/[^/]+\/role$/)) {
    const staffId = decodeURIComponent(req.url.split('/')[3]);
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const data = JSON.parse(body || '{}');
        if (!data.role_id) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Missing role_id' }));
          return;
        }
        try {
          const result = await stationDb('staff.role', { staff_id: staffId, role_id: data.role_id });
          if (result && result.error) throw new Error(result.error);
        } catch {
          // Local staff or offline — update role in local store
          const staff = store.getStaff();
          const s = staff.find(x => x.id === staffId);
          // role_id not applicable locally; name will come from roles list
        }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: e.message }));
      }
    });
    return;
  }

  // Set / replace a staff member's login PIN (4-6 digits).
  //
  // Unlike the web app's PIN button — which has the server generate a 6-digit
  // PIN and email it — the manager picks the PIN here and tells the waiter. That
  // makes it the option that works with no internet and no waiter email address.
  //
  // Offline-safe: the PIN is hashed locally and saved to the local store first,
  // so /local/waiter/verify-pin can check it over the LAN during an outage. The
  // hash is then pushed to the backend, immediately if we're online, otherwise by
  // flushPendingPins() when the connection returns. Saving therefore SUCCEEDS
  // while offline — `synced:false` tells the UI it's still owed to the server.
  if (req.method === 'POST' && req.url.match(/^\/local\/staff\/[^/]+\/pin$/)) {
    const staffId = decodeURIComponent(req.url.split('/')[3]);
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const data = JSON.parse(body || '{}');
        const pin = String(data.pin || '').trim();
        if (!/^\d{4,6}$/.test(pin)) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'PIN must be 4 to 6 digits' }));
          return;
        }
        const token   = extractWaiterToken(data.token || data.waiter_link);
        const pinHash = hashPin(pin);
        store.setPin({ staff_id: staffId, token, pin_hash: pinHash, synced: false });

        let synced = false, syncError = null;
        try {
          const result = await stationDb('staff.set_pin', { staff_id: staffId, pin_hash: pinHash });
          if (result && result.error) throw new Error(result.error);
          store.markPinSynced(staffId, token);
          synced = true;
        } catch (e) {
          syncError = e.message || String(e);
        }

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, synced, sync_error: syncError }));
      } catch (e) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: e.message || String(e) }));
      }
    });
    return;
  }

  // Verify a waiter's PIN against the locally cached hash.
  //
  // The app falls back to this when the backend is unreachable, so a
  // PIN-protected waiter can still start a shift during an outage. Attempt
  // limits mirror redeemWaiterToken (5 tries, then a 15-minute lockout) so being
  // offline doesn't quietly turn the second factor into an unlimited guess.
  if (req.method === 'POST' && req.url === '/local/waiter/verify-pin') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', () => {
      const send = (code, obj) => {
        res.writeHead(code, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(obj));
      };
      try {
        const data  = JSON.parse(body || '{}');
        const token = extractWaiterToken(data.token);
        const pin   = String(data.pin || '').trim();
        if (!token || !pin) return send(400, { error: 'token and pin are required' });

        const rec = store.getPin(null, token);
        // No cached hash — this waiter's PIN was never set from this Station, so
        // we can't vouch for them. The caller must wait for the backend.
        if (!rec || !rec.pin_hash) return send(404, { error: 'no_local_pin' });

        const lockMins = store.pinLockMinutes(rec);
        if (lockMins > 0) return send(423, { error: 'locked', minutes: lockMins });

        if (!verifyPinHash(pin, rec.pin_hash)) {
          const st = store.recordPinFailure(null, token);
          return send(401, {
            error: 'bad_pin',
            attempts_left: st.attempts_left,
            locked: st.locked,
            minutes: st.locked ? store.PIN_LOCK_MINUTES : 0,
          });
        }
        store.clearPinFailures(null, token);
        return send(200, { ok: true, offline_verified: true });
      } catch (e) {
        send(500, { error: e.message || String(e) });
      }
    });
    return;
  }

  // Wipe local-only staff entries (STAFF- prefixed) — useful after switching to Supabase
  if (req.method === 'POST' && req.url === '/local/staff/wipe-local') {
    const local = store.getStaff();
    let removed = 0;
    for (const s of local) {
      if (s.id && s.id.startsWith('STAFF-')) {
        store.removeStaff(s.id);
        removed++;
      }
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, removed }));
    return;
  }

  // Diagnostic: attempt a create + immediately delete, return the raw result
  if (req.method === 'GET' && req.url === '/local/staff/test-create') {
    (async () => {
      const testName = '__test__' + Date.now();
      const out = { name: testName, restaurant_id: RESTAURANT_ID };
      try {
        const r = await stationDb('staff.create', { name: testName, role_id: null });
        out.rpc_result = r;
        out.success = r && r.id ? true : false;
        if (r && r.id) {
          // cleanup
          await stationDb('staff.delete', { staff_id: r.id }).catch(() => {});
        }
      } catch (e) {
        out.success = false;
        out.error = e.message || String(e);
      }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(out, null, 2));
    })();
    return;
  }

  // Diagnostic: check which staff-management SQL functions are installed.
  // PostgREST matches RPC by parameter NAMES — must send the right params per function.
  if (req.method === 'GET' && req.url === '/local/staff/diag') {
    (async () => {
      const ZERO = '00000000-0000-0000-0000-000000000000';
      const probes = {
        manage_staff_create:   { p_restaurant_id: ZERO, p_name: '__probe__', p_role_id: null },
        manage_staff_new_link: { p_staff_id: ZERO, p_restaurant_id: ZERO },
        manage_staff_toggle:   { p_staff_id: ZERO, p_restaurant_id: ZERO },
        manage_staff_role:     { p_staff_id: ZERO, p_role_id: ZERO, p_restaurant_id: ZERO },
        manage_staff_delete:   { p_staff_id: ZERO, p_restaurant_id: ZERO },
      };
      const status = {};
      for (const [fn, params] of Object.entries(probes)) {
        try {
          await supabaseRpc(fn, params);
          status[fn] = 'installed';
        } catch (e) {
          const msg = e.message || String(e);
          if (/PGRST202|does not exist|Could not find the function/i.test(msg)) status[fn] = 'MISSING';
          else status[fn] = 'installed';
        }
      }
      const allInstalled = Object.values(status).every(v => v === 'installed');
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ all_installed: allInstalled, functions: status }));
    })();
    return;
  }

  // List available roles for this restaurant
  if (req.method === 'GET' && req.url === '/local/roles') {
    (async () => {
      try {
        const roles = await supabaseGet('roles', { restaurant_id: RESTAURANT_ID }, 100);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(Array.isArray(roles) ? roles : []));
      } catch {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end('[]');
      }
    })();
    return;
  }

  // QR code: returns 2D matrix of modules for client-side rendering.
  // Two modes:
  //   GET /local/qr?text=<url>           — direct: just QR the given text
  //   GET /local/staff/:id/qr            — legacy: look up active token from Supabase
  if (req.method === 'GET' && req.url.startsWith('/local/qr')) {
    try {
      const u = new URL(req.url, 'http://x');
      const text = u.searchParams.get('text') || '';
      if (!text) { res.writeHead(400); res.end('{}'); return; }
      const qr = qrcode(0, 'M'); qr.addData(text); qr.make();
      const n = qr.getModuleCount();
      const modules = [];
      for (let r = 0; r < n; r++) {
        const row = [];
        for (let c = 0; c < n; c++) row.push(qr.isDark(r, c) ? 1 : 0);
        modules.push(row);
      }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ link: text, size: n, modules }));
    } catch (e) {
      res.writeHead(500); res.end(JSON.stringify({ error: e.message }));
    }
    return;
  }

  if (req.method === 'GET' && req.url.match(/^\/local\/staff\/[^/]+\/qr$/)) {
    const staffId = decodeURIComponent(req.url.split('/')[3]);
    (async () => {
      try {
        const tokens = await supabaseGet('waiter_tokens', { staff_member_id: staffId }, 50).catch(() => []);
        const active = (Array.isArray(tokens) ? tokens : []).find(t => t.is_active) || (Array.isArray(tokens) ? tokens : [])[0];
        if (!active) { res.writeHead(404); res.end('{}'); return; }
        const link = `https://www.lightmenu.app/waiter/${active.token}`;
        const qr = qrcode(0, 'M'); qr.addData(link); qr.make();
        const n = qr.getModuleCount();
        const modules = [];
        for (let r = 0; r < n; r++) {
          const row = [];
          for (let c = 0; c < n; c++) row.push(qr.isDark(r, c) ? 1 : 0);
          modules.push(row);
        }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ link, size: n, modules }));
      } catch (e) {
        res.writeHead(500); res.end(JSON.stringify({ error: e.message }));
      }
    })();
    return;
  }

  if (req.method === 'POST' && req.url === '/rescan') {
    log('Manual rescan triggered from dashboard');
    runNetworkScan();
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, message: 'Scan started - check console for results' }));
    return;
  }

  // Remotely trigger an update: the agent process exits cleanly, and the
  // runner loop (agent-runner.ps1) runs the auto-updater before relaunching —
  // so the next boot is on the latest version. Without this, an update only
  // lands on a manual restart/reboot, because main.js is a long-lived server.
  if ((req.method === 'POST' || req.method === 'GET') && req.url === '/update') {
    log('Update requested — exiting so the runner re-runs the updater and relaunches');
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, version: AGENT_VERSION, message: 'Restarting to apply updates…' }));
    // Give the HTTP response time to flush before the process exits, otherwise
    // the caller sees a dropped connection instead of the 200.
    setTimeout(() => { try { res.end(); } catch {} process.exit(0); }, 600);
    return;
  }

  if (req.method === 'POST' && req.url === '/set-ip') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', () => {
      try {
        const { ip, port } = JSON.parse(body);
        if (!ip || !/^\d+\.\d+\.\d+\.\d+$/.test(ip)) throw new Error('Invalid IP');
        PRINTER_IP   = ip;
        PRINTER_PORT = Number(port) || 9100;
        log('Printer IP set manually: ' + PRINTER_IP + ':' + PRINTER_PORT);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    });
    return;
  }

  // Print an "I'M PRINTER No. N" slip on a specific printer so staff can tell
  // which physical device is which. Body: { printer_config_id } or { printer_number }.
  if (req.method === 'POST' && req.url === '/print-identifier') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const b = JSON.parse(body || '{}');
        let pc = null;
        if (b.printer_config_id) pc = printersCache.find(p => p.id === b.printer_config_id);
        if (!pc && b.printer_number != null) pc = printersCache.find(p => Number(p.printer_number) === Number(b.printer_number));
        const number = pc ? pc.printer_number : b.printer_number;
        const data = buildIdentifierTicket(number, pc ? pc.name : null);
        await sendToPrinterConfig(data, pc);
        log('IDENTIFIER printed for printer #' + (number != null ? number : '?'));
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, printer_number: number }));
      } catch (e) {
        log('print-identifier FAILED: ' + e.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    });
    return;
  }

  if (req.method === 'POST' && req.url === '/print') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        // Reject anything not addressed to this restaurant. print.lightmenu.app is
        // one shared Cloudflare Tunnel hostname for every Station — Cloudflare can
        // hand a request to ANY connected machine, not necessarily the right one.
        // A direct LAN call (no X-Station-Token header) already only ever reaches
        // this one PC, so it's exempt; only the shared-tunnel path needs this check.
        const incomingToken = req.headers['x-station-token'];
        if (incomingToken && API_TOKEN && API_TOKEN !== '__API_TOKEN__' && incomingToken !== API_TOKEN) {
          log('REJECTED /print: token does not match this restaurant (shared-tunnel misroute)');
          res.writeHead(403, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ ok: false, error: 'restaurant mismatch' }));
          return;
        }
        const ticket = JSON.parse(body);
        // Raster path: prefer pre-rendered bitmap when present (Arabic/CJK/etc.)
        let data = null;
        if (ticket.bitmap_b64) {
          data = buildRasterTicket(ticket.bitmap_b64, ticket.bitmap_width_dots, ticket.bitmap_height);
          if (data) log('RASTER: ' + ticket.bitmap_width_dots + 'x' + ticket.bitmap_height);
        }
        const copies = (ticket.type === 'check' ? ticket.settings?.check_copies : ticket.settings?.order_copies) || 1;
        const isKitchen = !data && !['check', 'cancel', 'transfer'].includes(ticket.type);
        // Multi-printer: a kitchen ticket is split by category and each group is
        // sent to its assigned printer. Everything else (checks, cancels, raster,
        // or when no stations are configured) prints once to the default printer.
        if (isKitchen && stationsConfigured()) {
          await printKitchenRouted(ticket, Math.min(copies, 3));
        } else {
          if (!data) {
            switch (ticket.type) {
              case 'check':    data = buildCheckTicket(ticket);    log('CHECK: Mesa ' + ticket.table_number); break;
              case 'cancel':   data = buildCancelTicket(ticket);   log('CANCEL: Mesa ' + ticket.table_number); break;
              case 'transfer': data = buildTransferTicket(ticket); log('TRANSFER: Mesa ' + ticket.from_table + '->' + ticket.to_table); break;
              default:         data = buildKitchenTicket(ticket);  log('KITCHEN: Mesa ' + ticket.table_number);
            }
          }
          for (let i = 0; i < Math.min(copies, 3); i++) await sendToPrinter(data);
        }
        printed++;
        updateDailyStats('printed');
        try {
          const storeRec = {
            order_id:       ticket.order_id,
            date:           ticket.time || new Date().toISOString(),
            table:          ticket.table_number,
            waiter:         ticket.waiter_name,
            items:          ticket.items || [],
            printer_type:   ticket.type === 'check' ? 'check' : 'kitchen',
            total:          ticket.total,
            guest_count:    ticket.guest_count,
            currency:       ticket.currency,
            payment_method: ticket.payment_method,
            bill_url:       ticket.bill_url,
            source:         'local',
          };
          if (ticket.type === 'check') store.addBill(storeRec);
          else                          store.addOrder(storeRec);
        } catch (e) { log('Store save failed: ' + e.message); }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        failed++;
        log('FAILED: ' + e.message);
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: false, error: e.message }));
      }
    });
    return;
  }

  if (req.method === 'GET') {
    const mode = usbDirectPort ? 'USB Direct (' + usbDirectPort + ')' : usbWinPrinter ? 'USB Spooler (' + usbWinPrinter + ')' : (PRINTER_IP ? 'Network ' + PRINTER_IP + ':' + PRINTER_PORT : 'Not connected');
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(`<!DOCTYPE html><html><head><meta charset="utf-8"><style>
body{font-family:sans-serif;background:#0f0f0f;color:#e0e0e0;padding:30px;max-width:600px}
h1{color:#a78bfa;margin-bottom:4px}.ok{color:#22c55e}.warn{color:#f59e0b}.dim{color:#666}
table{border-collapse:collapse;margin-top:10px;width:100%}
td{padding:8px 12px;border-bottom:1px solid #222;font-size:13px}
td:first-child{color:#9ca3af;width:140px}
button{margin-top:6px;padding:8px 18px;border:none;border-radius:8px;cursor:pointer;font-size:13px;font-weight:600}
.btn-teal{background:#14b8a6;color:#fff}.btn-gray{background:#374151;color:#e0e0e0}
input{background:#1a1d29;border:1px solid #2a2d3e;color:#fff;padding:7px 10px;border-radius:6px;font-size:13px;width:160px}
.row{display:flex;gap:8px;align-items:center;margin-top:12px}
#msg{margin-top:10px;font-size:13px;color:#22c55e;min-height:18px}
</style></head><body>
<h1>&#x1F5A8; LightMenu Print Agent</h1>
<span class=dim>v5.0.0 &nbsp;|&nbsp; Restaurant: ${RESTAURANT_ID.slice(0,8)}...</span>
<table style="margin-top:16px">
<tr><td>Mode</td><td><span class="${PRINTER_IP || usbDirectPort || usbWinPrinter ? 'ok' : 'warn'}">${mode}</span></td></tr>
<tr><td>Jobs printed</td><td><span class=ok>${printed}</span></td></tr>
<tr><td>Failed</td><td>${failed}</td></tr>
<tr><td>Uptime</td><td>${Math.floor(process.uptime())}s</td></tr>
</table>

<div style="margin-top:20px">
  <button class="btn-teal" onclick="rescan()">&#x1F50D; Scan network now</button>
  <div id="msg"></div>
</div>

<div style="margin-top:20px;padding:14px;background:#13151f;border-radius:10px;border:1px solid #1e2130">
  <div style="font-size:13px;color:#9ca3af;margin-bottom:8px">Manual IP (if scan can't find printer)</div>
  <div class=row>
    <input id="ip" placeholder="192.168.1.xxx" value="${PRINTER_IP}">
    <input id="port" placeholder="9100" value="${PRINTER_PORT}" style="width:70px">
    <button class="btn-gray" onclick="setIp()">Set IP</button>
  </div>
</div>

<script>
async function rescan(){
  document.getElementById('msg').textContent='Scanning...';
  const r=await fetch('/rescan',{method:'POST'});
  const j=await r.json();
  document.getElementById('msg').textContent=j.message||'Done - check console';
  setTimeout(()=>location.reload(),4000);
}
async function setIp(){
  const ip=document.getElementById('ip').value.trim();
  const port=document.getElementById('port').value.trim()||'9100';
  const r=await fetch('/set-ip',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ip,port})});
  const j=await r.json();
  document.getElementById('msg').textContent=j.ok?'IP set to '+ip+':'+port:'Error: '+j.error;
  if(j.ok) setTimeout(()=>location.reload(),1500);
}
</script>
</body></html>`);
    return;
  }

  res.writeHead(404); res.end();
}).listen(SERVER_PORT, '0.0.0.0', () => {
  log('LightMenu Station v' + AGENT_VERSION + ' | Restaurant: ' + RESTAURANT_ID + ' | Network: ' + PRINTER_IP + ':' + PRINTER_PORT + ' | USB: direct + spooler fallback');
  log('Dashboard: http://localhost:' + SERVER_PORT);
  // Loud, actionable warning when the install has no restaurant identity. This
  // happens when config.json was not next to Setup.exe at install time (e.g. the
  // downloaded .zip was not fully extracted before running the installer). Without
  // it the agent runs but is attached to no restaurant, so nothing prints.
  if (!RESTAURANT_ID || RESTAURANT_ID === '__RESTAURANT_ID__' || !API_TOKEN || API_TOKEN === '__API_TOKEN__') {
    log('==================================================================');
    log('  NOT CONFIGURED: no restaurant credentials found (config.json).');
    log('  This install is not linked to any restaurant, so nothing will');
    log('  print. Fix: fully UNZIP the download, then run the installer from');
    log('  the extracted folder (config.json must sit next to Setup.exe).');
    log('  Then re-download LightMenu Station from your dashboard if needed.');
    log('==================================================================');
  }
  try { track('agent_start', { port: SERVER_PORT, platform: process.platform, node_version: process.version }); } catch {}
});

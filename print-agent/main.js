const net   = require('net');
const http  = require('http');
const https = require('https');
const fs    = require('fs');
const path  = require('path');
const os    = require('os');
const { exec } = require('child_process');

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

// â”€â”€â”€ PRE-CONFIGURED PER RESTAURANT â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// These placeholders are replaced automatically when you download the
// Print Agent from your LightMenu Printer Setup page.
// Credentials live in config.json — never overwritten by auto-updates.
// Falls back to legacy hardcoded values for agents installed before this change.
const _cfg = (() => {
    try { return JSON.parse(fs.readFileSync(path.join(__dirname, 'config.json'), 'utf8')); }
    catch { return {}; }
})();
const RESTAURANT_ID   = _cfg.restaurant_id   || '__RESTAURANT_ID__';
const API_TOKEN       = _cfg.api_token       || '__API_TOKEN__';
let   RESTAURANT_NAME = _cfg.restaurant_name || '';

// LightMenu Supabase endpoint â€” do not change
const SUPABASE_URL     = 'https://xakaknyanjzabxqmcipz.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inhha2Frbnlhbmp6YWJ4cW1jaXB6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzcxOTc2MjUsImV4cCI6MjA5Mjc3MzYyNX0.NqGyREZO2o_-ZUvIltQCTZ6zJAO7ARGa45cDU9OX7G4';

const SERVER_PORT = 3000;

// Default printer â€” overridden by the first active PrinterConfig from LightMenu
let PRINTER_IP   = ''; // set automatically by network scan
let PRINTER_PORT = 9100;

// â”€â”€â”€ PRINTER CACHE (refreshed every 30s from LightMenu) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
let printersCache = [];

// â”€â”€â”€ USB PRINTING â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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
    // ── Strategy 1: direct write to \\.\USBx (no driver needed) ───────────────
    // usbprint.sys (built-in Windows class driver) makes \\.\USB001…009 writable
    // the first time any USB printer is plugged in — no manufacturer driver needed.
    `$direct = $null`,
    `for ($i = 1; $i -le 9; $i++) {`,
    `  $p = '\\\\.\\USB' + $i`,
    `  try {`,
    `    $s = [System.IO.File]::Open($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)`,
    `    $s.Close()`,
    `    $direct = $p`,
    `    break`,
    `  } catch {}`,
    `}`,
    `if ($direct) { Write-Output ('DIRECT:' + $direct); exit }`,

    // ── Strategy 2: spooler via Generic/Text-Only (also built into Windows) ────
    `$n = '${LM_WIN_PRINTER}'`,
    `$pr = Get-Printer -Name $n -ErrorAction SilentlyContinue`,
    `if ($pr) { Write-Output 'SPOOLER:READY'; exit }`,
    // pnputil rescan — triggers usbprint.sys install for newly-connected printers
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
    const port = r.slice(7); // '\\.\USB1' etc.
    if (usbDirectPort !== port) {
      log('USB direct port ready: ' + port + ' (no driver needed)');
      usbDirectPort = port;
      try { track('usb_connected', { port, strategy: 'direct' }); } catch {}
    }
    usbWinPrinter = null; // prefer direct over spooler
  } else if (r === 'SPOOLER:READY' || r.startsWith('SPOOLER:ADDED')) {
    if (!usbWinPrinter) {
      const port = r.startsWith('SPOOLER:ADDED:') ? r.split(':')[2] : 'USB001';
      log('USB spooler printer ready on ' + port);
      usbWinPrinter = LM_WIN_PRINTER;
      try { track('usb_connected', { port, strategy: 'spooler' }); } catch {}
    }
    usbDirectPort = null;
  } else {
    const wasConnected = usbDirectPort || usbWinPrinter;
    if (wasConnected) {
      log('USB lost â€” falling back to network (' + r + ')');
      try { track('usb_lost', { last_port: usbDirectPort || usbWinPrinter, reason: r }); } catch {}
    }
    else if (r && r !== 'NO_PORT') log('USB scan: ' + r);
    usbDirectPort = null;
    usbWinPrinter = null;
  }
}

setTimeout(scanUsb, 2000);
setInterval(scanUsb, 30000);

function supabaseGet(table, query) {
  return new Promise((resolve, reject) => {
    const qs = Object.entries(query).map(([k, v]) => k + '=eq.' + encodeURIComponent(v)).join('&');
    const url = SUPABASE_URL + '/rest/v1/' + table + '?' + qs + '&limit=20';
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

// â”€â”€â”€ NETWORK PRINTER DISCOVERY â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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

function checkPort(ip, port, timeout) {
  return new Promise(resolve => {
    const s = new net.Socket();
    const t = setTimeout(() => { s.destroy(); resolve(false); }, timeout);
    s.connect(port, ip, () => { clearTimeout(t); s.destroy(); resolve(true); });
    s.on('error', () => { clearTimeout(t); resolve(false); });
  });
}

// Read the Windows ARP table â€” lists every device the PC has seen on the LAN recently.
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

// Check a list of IPs in controlled batches â€” avoids overwhelming the Windows TCP stack
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

  // â”€â”€ Step 1: ARP table â€” instant, catches printer the moment it gets an IP â”€â”€
  const arpIps = await getArpIps();
  if (arpIps.length > 0) {
    log('ARP table has ' + arpIps.length + ' device(s) â€” checking for printer ports...');
    for (const port of PRINTER_PORTS) {
      const found = await checkPortBatch(arpIps, port, 2000, 20);
      if (found.length > 0) {
        log('Found printer(s) via ARP on port ' + port + ': ' + found.join(', '));
        return found;
      }
    }
    log('ARP devices found but none responded on printer ports (' + PRINTER_PORTS.join('/') + ')');
  } else {
    log('ARP table empty â€” falling back to subnet scan');
  }

  // â”€â”€ Step 2: Batched subnet scan as fallback â”€â”€
  const subnets = getLocalSubnets();
  log('Scanning ' + subnets.map(s => s + '.1-254').join(', ') + ' in batches...');
  const allIps = [];
  for (const subnet of subnets) {
    for (let i = 1; i <= 254; i++) allIps.push(subnet + '.' + i);
  }
  for (const port of PRINTER_PORTS) {
    const found = await checkPortBatch(allIps, port, 1200, 30);
    if (found.length > 0) {
      log('Found printer(s) via subnet scan on port ' + port + ': ' + found.join(', '));
      return found;
    }
  }

  log('Scan complete â€” 0 printer(s) found');
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
  try {
    const all  = await supabaseGet('printer_configs', { restaurant_id: RESTAURANT_ID, is_active: 'true' });
    const real = Array.isArray(all) ? all.filter(c => c.printer_type !== 'scan') : [];

    if (real.length === 0) {
      // First-time setup â€” create a config for each discovered printer
      for (let i = 0; i < discoveredIps.length; i++) {
        try {
          await supabasePost('printer_configs', {
            restaurant_id: RESTAURANT_ID,
            name: discoveredIps.length === 1 ? 'Printer' : 'Printer ' + (i + 1),
            printer_type: 'kitchen',
            printer_ip: discoveredIps[i],
            is_active: true,
          });
          log('Auto-created printer config for ' + discoveredIps[i]);
        } catch (e) {
          log('Auto-create failed for ' + discoveredIps[i] + ': ' + e.message);
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
      // Single-printer setup â€” keep the IP current (handles DHCP changes automatically)
      const cfg = real[0];
      if (cfg.printer_ip !== discoveredIps[0]) {
        await supabasePatch('printer_configs', cfg.id, { printer_ip: discoveredIps[0] });
        log('Updated printer IP: ' + (cfg.printer_ip || '(none)') + ' â†’ ' + discoveredIps[0]);
        await new Promise(r => setTimeout(r, 1500));
        await refreshPrinters();
      } else {
        // IP is already correct â€” make sure it's loaded into memory
        if (PRINTER_IP !== cfg.printer_ip) {
          PRINTER_IP = cfg.printer_ip;
          PRINTER_PORT = Number(cfg.printer_port) || 9100;
          log('Loaded printer IP from config: ' + PRINTER_IP);
        }
      }
    } else {
      // Multiple printers â€” only fill in configs that have no IP set
      const noIp = real.filter(c => !c.printer_ip);
      let changed = false;
      for (let i = 0; i < Math.min(noIp.length, discoveredIps.length); i++) {
        await supabasePatch('printer_configs', noIp[i].id, { printer_ip: discoveredIps[i] });
        log('Assigned IP ' + discoveredIps[i] + ' â†’ ' + noIp[i].name);
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
    if (Array.isArray(existing) && existing.length > 0) {
      // Merge into existing settings so we don't wipe discovered_ips/scanned_at
      const prevSettings = existing[0].settings || {};
      await supabasePatch('printer_configs', existing[0].id, {
        settings: { ...prevSettings, last_heartbeat: now, agent_version: AGENT_VERSION },
      });
    } else {
      await supabasePost('printer_configs', {
        restaurant_id: RESTAURANT_ID,
        name: '__scan__',
        printer_type: 'scan',
        is_active: false,
        settings: { last_heartbeat: now, agent_version: AGENT_VERSION },
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
    log('No printer found â€” will rescan in ' + (delay / 1000) + 's (attempt ' + _scanCount + ')');

    // After ~2 minutes of no printer, show a Windows notification so the user knows
    if (_scanCount === 4 && !_notifiedNotFound) {
      _notifiedNotFound = true;
      log('Showing printer-not-found notification to user');
      showWindowsNotification(
        'LightMenu â€” Printer not found',
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
      const first = list[0];
      if (first.printer_ip) PRINTER_IP = first.printer_ip;
      if (first.printer_port) PRINTER_PORT = Number(first.printer_port);
      log('Synced ' + list.length + ' printer(s) â€” default: ' + PRINTER_IP + ':' + PRINTER_PORT);
    }
  } catch (e) { log('Printer sync failed: ' + e.message); }
}
setInterval(refreshPrinters, 30000);
setTimeout(refreshPrinters, 1000);

// â”€â”€â”€ PRINT QUEUE POLLING â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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
  try {
    const jobs = await fetchPendingJobs();
    for (const job of jobs) {
      if (processingJobs.has(job.id)) continue;
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

        // Fall back to any active printer config if no exact match
        let printerConfig = printersCache.find(p =>
          p.printer_type === (job.printer_type || 'kitchen') && p.is_active
        );
        if (!printerConfig) {
          printerConfig = printersCache.find(p => p.printer_type === 'kitchen' && p.is_active)
                       || printersCache.find(p => p.is_active);
        }
        if (printerConfig?.printer_ip) {
          printerIp   = printerConfig.printer_ip;
          printerPort = Number(printerConfig.printer_port) || 9100;
        }

        if (!printerIp && !usbWinPrinter) {
          log('Waiting for printer IP â€” job ' + job.id + ' will retry (scan in progress)');
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
        for (let i = 0; i < Math.min(copies, 3); i++) {
          await sendToPrinter(data, printerIp, printerPort);
        }
        await markJobPrinted(job.id);
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
            payment_method: ticket.payment_method,
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
        log('Failed job ' + job.id + ': ' + (e?.message || String(e) || 'unknown error') + ' [ip=' + printerIp + ']');
        track('job_failed', { job_id: job.id, error: e?.message || String(e), printer_mode: usbDirectPort ? 'usb-direct' : usbWinPrinter ? 'usb-spooler' : 'network', printer_ip: printerIp });
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
const processingJobs = new Set();

function log(m) { console.log('[' + new Date().toLocaleTimeString() + '] ' + m); }

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
  // Strategy 1: direct write (no driver needed)
  if (usbDirectPort) {
    return sendViaDirectUsb(data, usbDirectPort).catch(e => {
      log('USB direct write failed (' + e.message + ') â€” retrying via spooler or network');
      usbDirectPort = null;
      return sendToPrinter(data, ip, port); // retry with next available method
    });
  }
  // Strategy 2: Windows spooler (Generic/Text-Only driver)
  if (usbWinPrinter) {
    return sendViaSpooler(data, usbWinPrinter).catch(e => {
      log('USB spooler failed (' + e.message + ') â€” switching to network');
      usbWinPrinter = null;
      return sendViaNetwork(data, ip, port);
    });
  }
  return sendViaNetwork(data, ip, port);
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

// â”€â”€â”€ ESC/POS â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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
  const SCALE = 4;
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


// â”€â”€â”€ CANCEL TICKET â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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

// â”€â”€â”€ TRANSFER TICKET â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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

// â”€â”€â”€ HTTP SERVER (for direct /print calls from LightMenu frontend) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
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
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'running', version: AGENT_VERSION, restaurant_name: RESTAURANT_NAME, printer: { usb: usbDirectPort || usbWinPrinter || null, ip: PRINTER_IP, port: PRINTER_PORT, mode: usbDirectPort ? 'usb-direct' : usbWinPrinter ? 'usb-spooler' : 'network' }, printed, failed, analytics_queued: _readQueue().length }));
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
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(store.getStats(period)));
    return;
  }

  if (req.method === 'GET' && req.url.startsWith('/local/bills')) {
    const u = new URL(req.url, 'http://x');
    const start = u.searchParams.get('start') || null;
    const end   = u.searchParams.get('end')   || null;
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(store.getBills(start, end)));
    return;
  }

  if (req.method === 'GET' && req.url.startsWith('/local/orders')) {
    const u = new URL(req.url, 'http://x');
    const date = u.searchParams.get('date') || null;
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(store.getOrders(date)));
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

  // Staff endpoints
  if (req.method === 'GET' && req.url === '/local/staff') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(store.getStaff()));
    return;
  }

  if (req.method === 'POST' && req.url === '/local/staff') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', () => {
      try {
        const data = JSON.parse(body || '{}');
        const result = store.addStaff(data);
        res.writeHead(result ? 200 : 400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result || { error: 'Missing name' }));
      } catch (e) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: e.message }));
      }
    });
    return;
  }

  if (req.method === 'DELETE' && req.url.startsWith('/local/staff/')) {
    const staffId = decodeURIComponent(req.url.slice('/local/staff/'.length));
    const ok = store.removeStaff(staffId);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok }));
    return;
  }

  if (req.method === 'POST' && req.url === '/rescan') {
    log('Manual rescan triggered from dashboard');
    runNetworkScan();
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, message: 'Scan started â€” check console for results' }));
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

  if (req.method === 'POST' && req.url === '/print') {
    let body = '';
    req.on('data', c => body += c);
    req.on('end', async () => {
      try {
        const ticket = JSON.parse(body);
        // Raster path: prefer pre-rendered bitmap when present (Arabic/CJK/etc.)
        let data = null;
        if (ticket.bitmap_b64) {
          data = buildRasterTicket(ticket.bitmap_b64, ticket.bitmap_width_dots, ticket.bitmap_height);
          if (data) log('RASTER: ' + ticket.bitmap_width_dots + 'x' + ticket.bitmap_height);
        }
        if (!data) {
          switch (ticket.type) {
            case 'check':    data = buildCheckTicket(ticket);   log('CHECK: Mesa ' + ticket.table_number); break;
            default:         data = buildKitchenTicket(ticket); log('KITCHEN: Mesa ' + ticket.table_number);
          }
        }
        const copies = (ticket.type === 'check' ? ticket.settings?.check_copies : ticket.settings?.order_copies) || 1;
        for (let i = 0; i < Math.min(copies, 3); i++) await sendToPrinter(data);
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
  document.getElementById('msg').textContent=j.message||'Done â€” check console';
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
  log('LightMenu Print Agent v' + AGENT_VERSION + ' | Restaurant: ' + RESTAURANT_ID + ' | Network: ' + PRINTER_IP + ':' + PRINTER_PORT + ' | USB: direct + spooler fallback');
  log('Dashboard: http://localhost:' + SERVER_PORT);
  try { track('agent_start', { port: SERVER_PORT, platform: process.platform, node_version: process.version }); } catch {}
});

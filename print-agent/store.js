// LightMenu Print Agent — Local Store
// ------------------------------------
// Offline-first persistence for orders and bills. Survives restarts, syncs to
// Supabase opportunistically. Single source of truth for the WPF dashboard's
// Analytics, Bills, and Daily Report pages.
//
// Files written next to main.js:
//   orders.local.json — every kitchen/bar/cancel/transfer ticket
//   bills.local.json  — every check ticket (revenue data)
//
// Sync rule: agent only adds records Supabase is missing. It never overwrites
// remote rows. Conflicts resolve by Supabase wins.

const fs   = require('fs');
const path = require('path');

const ORDERS_FILE  = path.join(__dirname, 'orders.local.json');
const BILLS_FILE   = path.join(__dirname, 'bills.local.json');
const PRINTED_FILE = path.join(__dirname, 'printed.local.json');

const MAX_ORDERS  = 5000; // ~30 days at 150 orders/day
const MAX_BILLS   = 5000;
const MAX_PRINTED = 5000;

function _readArr(file) {
  try { const a = JSON.parse(fs.readFileSync(file, 'utf8')); return Array.isArray(a) ? a : []; }
  catch { return []; }
}

function _writeArr(file, arr) {
  try { fs.writeFileSync(file, JSON.stringify(arr)); } catch {}
}

function _today() { return new Date().toISOString().slice(0, 10); }

// Generate BILL-YYYYMMDD-NNN by counting today's bills locally.
// On sync, the agent uses order_id (UUID) for matching, so the display number
// doesn't need to match Supabase exactly — it's just for offline UI.
function _nextBillNumber(allBills) {
  const today = _today().replace(/-/g, '');
  const todays = allBills.filter(b => b.date && b.date.slice(0, 10) === _today());
  const n = String(todays.length + 1).padStart(3, '0');
  return `BILL-${today}-${n}`;
}

function addOrder(record) {
  if (!record) return;
  const orders = _readArr(ORDERS_FILE);
  // Dedupe by order_id + table + timestamp window (avoid double-add on retry)
  if (record.order_id && orders.some(o => o.order_id === record.order_id && o.printer_type === record.printer_type)) {
    return;
  }
  const entry = {
    id:           record.order_id || `LOCAL-${Date.now()}-${Math.random().toString(36).slice(2,8)}`,
    order_id:     record.order_id || null,
    date:         record.date || new Date().toISOString(),
    table:        record.table || record.table_number || '?',
    waiter:       record.waiter || record.waiter_name || 'Staff',
    items:        record.items || [],
    printer_type: record.printer_type || 'kitchen',
    total:        Number(record.total || 0),
    source:       record.source || 'supabase',
    synced:       record.source !== 'local',
  };
  orders.push(entry);
  if (orders.length > MAX_ORDERS) orders.splice(0, orders.length - MAX_ORDERS);
  _writeArr(ORDERS_FILE, orders);
}

function addBill(record) {
  if (!record) return;
  const bills = _readArr(BILLS_FILE);
  if (record.order_id && bills.some(b => b.order_id === record.order_id)) {
    return; // already saved (avoid dupe on reprint)
  }
  const entry = {
    id:             _nextBillNumber(bills),
    order_id:       record.order_id || null,
    date:           record.date || new Date().toISOString(),
    table:          record.table || record.table_number || '?',
    waiter:         record.waiter || record.waiter_name || 'Staff',
    items:          record.items || [],
    total:          Number(record.total || 0),
    guest_count:    Number(record.guest_count || 0),
    currency:       record.currency || 'EUR',
    payment_method: record.payment_method || 'unpaid',
    bill_url:       record.bill_url || null,
    source:         record.source || 'supabase',
    synced:         record.source !== 'local',
  };
  bills.push(entry);
  if (bills.length > MAX_BILLS) bills.splice(0, bills.length - MAX_BILLS);
  _writeArr(BILLS_FILE, bills);
  return entry;
}

function getBills(startDate, endDate) {
  const bills = _readArr(BILLS_FILE);
  if (!startDate && !endDate) return bills;
  const start = startDate ? new Date(startDate).getTime() : 0;
  const end   = endDate   ? new Date(endDate + 'T23:59:59').getTime() : Date.now();
  return bills.filter(b => {
    const t = new Date(b.date).getTime();
    return t >= start && t <= end;
  });
}

function getOrders(date) {
  const orders = _readArr(ORDERS_FILE);
  if (!date) return orders;
  return orders.filter(o => o.date && o.date.slice(0, 10) === date);
}

function _periodStart(period) {
  const now = new Date();
  const d = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  switch (period) {
    case 'today': return d.getTime();
    case 'week': {
      const day = now.getDay() || 7; // Sun=0 → 7 so Monday=1 stays Monday
      d.setDate(d.getDate() - (day - 1));
      return d.getTime();
    }
    case 'month': d.setDate(1); return d.getTime();
    case 'all':
    default: return 0;
  }
}

function getStats(period) {
  const bills = _readArr(BILLS_FILE);
  const start = _periodStart(period || 'today');
  const inRange = bills.filter(b => new Date(b.date).getTime() >= start);

  const total_revenue = inRange.reduce((sum, b) => sum + Number(b.total || 0), 0);
  const total_orders  = inRange.length;
  const avg_ticket    = total_orders ? total_revenue / total_orders : 0;

  // Payment method breakdown
  const payment = { cash: { count: 0, total: 0 }, card: { count: 0, total: 0 }, mixed: { count: 0, total: 0 }, unpaid: { count: 0, total: 0 } };
  for (const b of inRange) {
    const m = b.payment_method || 'unpaid';
    if (!payment[m]) payment[m] = { count: 0, total: 0 };
    payment[m].count++;
    payment[m].total += Number(b.total || 0);
  }

  // Daily breakdown for chart (last 7 days regardless of period).
  // Use UTC consistently — bill dates are ISO UTC timestamps, so both key and
  // label must derive from the same source to stay in sync.
  const daily = [];
  const today = new Date();
  const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  for (let i = 6; i >= 0; i--) {
    const d = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), today.getUTCDate() - i));
    const key = d.toISOString().slice(0, 10);
    const label = months[d.getUTCMonth()] + ' ' + d.getUTCDate();
    const dayBills = bills.filter(b => b.date && b.date.slice(0, 10) === key);
    daily.push({
      date:    key,
      label,
      revenue: dayBills.reduce((s, b) => s + Number(b.total || 0), 0),
      orders:  dayBills.length,
    });
  }

  // Best day in period
  const byDay = {};
  for (const b of inRange) {
    const k = b.date.slice(0, 10);
    byDay[k] = (byDay[k] || 0) + Number(b.total || 0);
  }
  let best_day = null, best_amount = 0;
  for (const [k, v] of Object.entries(byDay)) {
    if (v > best_amount) { best_amount = v; best_day = k; }
  }

  // Currency — use most common
  const curr = {};
  for (const b of inRange) { const c = b.currency || 'EUR'; curr[c] = (curr[c] || 0) + 1; }
  let currency = 'EUR', max = 0;
  for (const [c, n] of Object.entries(curr)) if (n > max) { currency = c; max = n; }

  return {
    period, currency,
    total_revenue, total_orders, avg_ticket,
    best_day, best_amount,
    payment, daily,
  };
}

function getUnsynced() {
  const bills  = _readArr(BILLS_FILE).filter(b => !b.synced);
  const orders = _readArr(ORDERS_FILE).filter(o => !o.synced);
  return { bills, orders };
}

function markBillSynced(id) {
  const bills = _readArr(BILLS_FILE);
  const b = bills.find(x => x.id === id || x.order_id === id);
  if (b) { b.synced = true; _writeArr(BILLS_FILE, bills); }
}

function markOrderSynced(id) {
  const orders = _readArr(ORDERS_FILE);
  const o = orders.find(x => x.id === id || x.order_id === id);
  if (o) { o.synced = true; _writeArr(ORDERS_FILE, orders); }
}

function findBill(id) {
  return _readArr(BILLS_FILE).find(b => b.id === id || b.order_id === id) || null;
}

function dailyReport(date, startTime, endTime) {
  const bills = _readArr(BILLS_FILE);
  const dayBills = bills.filter(b => b.date && b.date.slice(0, 10) === date);
  const startMin = startTime ? _toMin(startTime) : 0;
  const endMin   = endTime   ? _toMin(endTime)   : 24 * 60;
  const inWindow = dayBills.filter(b => {
    const d = new Date(b.date);
    const m = d.getHours() * 60 + d.getMinutes();
    return m >= startMin && m <= endMin;
  });

  const total_revenue = inWindow.reduce((s, b) => s + Number(b.total || 0), 0);
  const total_orders  = inWindow.length;
  const avg_ticket    = total_orders ? total_revenue / total_orders : 0;

  // Item breakdown
  const items = {};
  for (const b of inWindow) {
    for (const it of (b.items || [])) {
      const name = it.name || '?';
      if (!items[name]) items[name] = { qty: 0, revenue: 0 };
      items[name].qty     += Number(it.qty || 1);
      items[name].revenue += Number(it.price || 0) * Number(it.qty || 1);
    }
  }
  const top_items = Object.entries(items)
    .map(([name, v]) => ({ name, qty: v.qty, revenue: v.revenue }))
    .sort((a, b) => b.qty - a.qty)
    .slice(0, 20);

  // Payment split
  const payment = { cash: 0, card: 0, mixed: 0, unpaid: 0 };
  for (const b of inWindow) { payment[b.payment_method || 'unpaid'] = (payment[b.payment_method || 'unpaid'] || 0) + Number(b.total || 0); }

  return { date, startTime, endTime, total_revenue, total_orders, avg_ticket, top_items, payment };
}

function _toMin(hhmm) {
  const m = /^(\d{1,2}):(\d{2})/.exec(hhmm || '');
  if (!m) return 0;
  return Number(m[1]) * 60 + Number(m[2]);
}

// ─── Staff store ─────────────────────────────────────────────────────────────
const STAFF_FILE = path.join(__dirname, 'staff.local.json');

function getStaff() { return _readArr(STAFF_FILE); }

function addStaff(record) {
  if (!record || !record.name) return null;
  const staff = _readArr(STAFF_FILE);
  const entry = {
    id:          'STAFF-' + Date.now() + '-' + Math.random().toString(36).slice(2, 8),
    name:        record.name,
    role:        record.role || 'Waiter',
    waiter_link: record.waiter_link || null,
    created_at:  new Date().toISOString(),
    last_used:   record.last_used || null,
    active:      true,
    synced:      false,
  };
  staff.push(entry);
  _writeArr(STAFF_FILE, staff);
  return entry;
}

function removeStaff(id) {
  const staff = _readArr(STAFF_FILE);
  const idx = staff.findIndex(s => s.id === id);
  if (idx >= 0) { staff.splice(idx, 1); _writeArr(STAFF_FILE, staff); return true; }
  return false;
}

function toggleStaff(id) {
  const staff = _readArr(STAFF_FILE);
  const s = staff.find(x => x.id === id);
  if (!s) return null;
  s.active = !s.active;
  s.synced = false;
  _writeArr(STAFF_FILE, staff);
  return s.active;
}

function updateStaffLink(id, link) {
  const staff = _readArr(STAFF_FILE);
  const s = staff.find(x => x.id === id);
  if (!s) return false;
  s.waiter_link = link;
  s.active = true;
  s.synced = false;
  _writeArr(STAFF_FILE, staff);
  return true;
}

// ─── Waiter PIN store (offline second factor) ────────────────────────────────
// Mirrors the waiter_tokens PIN columns locally so a manager can set a PIN and a
// waiter can log in while the internet is down. The hash format is byte-identical
// to the server's ("saltHex:hashHex", scrypt) — a PIN set offline keeps working
// once it syncs up, and one set online can be cached here and verified on the LAN.
//
// Only the hash is ever stored, never the PIN itself. Attempt limits mirror
// redeemWaiterToken so an offline brute-force is bounded the same way.
const PINS_FILE = path.join(__dirname, 'pins.local.json');

const PIN_MAX_ATTEMPTS = 5;
const PIN_LOCK_MINUTES = 15;

function _findPin(pins, staffId, token) {
  if (staffId) { const s = pins.find(p => p.staff_id === staffId); if (s) return s; }
  if (token)   { const t = pins.find(p => p.token === token);      if (t) return t; }
  return null;
}

function getPin(staffId, token) {
  return _findPin(_readArr(PINS_FILE), staffId, token);
}

// synced:false means "set while offline, still owed to the backend".
function setPin(record) {
  if (!record || !record.pin_hash) return null;
  const pins = _readArr(PINS_FILE);
  const existing = _findPin(pins, record.staff_id, record.token);
  const entry = existing || {};
  entry.staff_id        = record.staff_id || entry.staff_id || null;
  entry.token           = record.token    || entry.token    || null;
  entry.pin_hash        = record.pin_hash;
  entry.pin_required    = true;
  entry.pin_set_at      = new Date().toISOString();
  entry.failed_attempts = 0;
  entry.locked_until    = null;
  entry.synced          = record.synced === true;
  if (!existing) pins.push(entry);
  _writeArr(PINS_FILE, pins);
  return entry;
}

function clearPin(staffId, token) {
  const pins = _readArr(PINS_FILE);
  const idx = pins.findIndex(p => (staffId && p.staff_id === staffId) || (token && p.token === token));
  if (idx < 0) return false;
  pins.splice(idx, 1);
  _writeArr(PINS_FILE, pins);
  return true;
}

// Returns { locked, locked_until, attempts_left } after counting one failure.
// Mirrors the server: on hitting the cap we set locked_until and reset the
// counter, so the next window starts clean.
function recordPinFailure(staffId, token) {
  const pins = _readArr(PINS_FILE);
  const p = _findPin(pins, staffId, token);
  if (!p) return { locked: false, locked_until: null, attempts_left: PIN_MAX_ATTEMPTS };
  const attempts = (p.failed_attempts || 0) + 1;
  if (attempts >= PIN_MAX_ATTEMPTS) {
    p.failed_attempts = 0;
    p.locked_until = new Date(Date.now() + PIN_LOCK_MINUTES * 60000).toISOString();
  } else {
    p.failed_attempts = attempts;
  }
  _writeArr(PINS_FILE, pins);
  return {
    locked: !!p.locked_until,
    locked_until: p.locked_until,
    attempts_left: Math.max(0, PIN_MAX_ATTEMPTS - attempts),
  };
}

function clearPinFailures(staffId, token) {
  const pins = _readArr(PINS_FILE);
  const p = _findPin(pins, staffId, token);
  if (!p) return;
  p.failed_attempts = 0;
  p.locked_until = null;
  _writeArr(PINS_FILE, pins);
}

// Minutes still remaining on a lockout, or 0 if not locked.
function pinLockMinutes(pin) {
  if (!pin || !pin.locked_until) return 0;
  const ms = new Date(pin.locked_until).getTime() - Date.now();
  return ms > 0 ? Math.ceil(ms / 60000) : 0;
}

function getUnsyncedPins() { return _readArr(PINS_FILE).filter(p => !p.synced); }

function markPinSynced(staffId, token) {
  const pins = _readArr(PINS_FILE);
  const p = _findPin(pins, staffId, token);
  if (p) { p.synced = true; _writeArr(PINS_FILE, pins); }
}

// ─── Print-twice guard ───────────────────────────────────────────────────────
// Records job ids that have already physically printed, so a crash or network
// blip between "printed the ticket" and "told Supabase it printed" can never
// cause a reprint on the next poll — we check this before sending to the
// printer, not just before marking Supabase.
function wasPrinted(jobId) {
  if (!jobId) return false;
  return _readArr(PRINTED_FILE).includes(jobId);
}

function markPrinted(jobId) {
  if (!jobId) return;
  const ids = _readArr(PRINTED_FILE);
  if (ids.includes(jobId)) return;
  ids.push(jobId);
  if (ids.length > MAX_PRINTED) ids.splice(0, ids.length - MAX_PRINTED);
  _writeArr(PRINTED_FILE, ids);
}

module.exports = {
  addOrder, addBill,
  getBills, getOrders, getStats,
  getUnsynced, markBillSynced, markOrderSynced,
  findBill, dailyReport,
  getStaff, addStaff, removeStaff, toggleStaff, updateStaffLink,
  getPin, setPin, clearPin, recordPinFailure, clearPinFailures,
  pinLockMinutes, getUnsyncedPins, markPinSynced,
  PIN_MAX_ATTEMPTS, PIN_LOCK_MINUTES,
  wasPrinted, markPrinted,
};

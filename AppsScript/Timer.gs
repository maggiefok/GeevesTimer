/**
 * Geeves Timer endpoint
 *
 * Lets the Geeves Mac timer read your client list and add rows to the Time Log.
 * Add this as a new file (named "Timer") in the Geeves sheet's Apps Script project,
 * change TIMER_KEY below, then Deploy > New deployment > Web app
 * (Execute as: Me, Who has access: Anyone).
 */

// Change this to any long random phrase. The Mac app sends it with every request.
const TIMER_KEY = 'change-me-to-a-long-random-phrase';

// The Geeves spreadsheet. getActive() works too when this file lives inside the sheet.
const GEEVES_SHEET_ID = '1iZWu89RiL_hBwUfDT6tpI2k6owh0KPR7q_6_-cZAj7k';

function doGet(e) {
  return respond_((e && e.parameter) || {});
}

function doPost(e) {
  let body = {};
  try {
    body = JSON.parse(e.postData.contents);
  } catch (err) {
    return json_({ ok: false, error: 'Request was not valid JSON' });
  }
  return respond_(body);
}

function respond_(p) {
  if (p.key !== TIMER_KEY) return json_({ ok: false, error: 'Wrong key. Check the key in the Geeves timer matches TIMER_KEY.' });
  try {
    switch (p.action) {
      case 'ping':
        return json_({ ok: true });
      case 'clients':
        return json_({ ok: true, clients: listClients_() });
      case 'addTime':
        return json_({ ok: true, row: addTime_(p) });
      case 'addClient':
        addClient_(p);
        return json_({ ok: true });
      default:
        return json_({ ok: false, error: 'Unknown action: ' + p.action });
    }
  } catch (err) {
    return json_({ ok: false, error: String(err && err.message ? err.message : err) });
  }
}

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

// ---------- sheet helpers ----------

function book_() {
  try {
    return SpreadsheetApp.openById(GEEVES_SHEET_ID);
  } catch (err) {
    return SpreadsheetApp.getActive();
  }
}

function tab_(name) {
  const sh = book_().getSheetByName(name);
  if (!sh) throw new Error('Could not find a tab named "' + name + '"');
  return sh;
}

function headers_(sh) {
  return sh.getRange(1, 1, 1, sh.getLastColumn()).getValues()[0].map(function (h) { return String(h).trim(); });
}

function colOf_(headers, name) {
  return headers.indexOf(name) + 1; // 0 when missing
}

function readTable_(name) {
  const sh = tab_(name);
  const values = sh.getDataRange().getValues();
  if (values.length < 2) return [];
  const headers = values[0].map(function (h) { return String(h).trim(); });
  return values.slice(1)
    .filter(function (r) { return r.some(function (v) { return v !== '' && v !== null; }); })
    .map(function (r) {
      const o = {};
      headers.forEach(function (h, i) { if (h) o[h] = r[i]; });
      return o;
    });
}

// Last row that has something in the given column (1 if only the header).
function lastFilledRow_(sh, col) {
  const max = sh.getMaxRows();
  if (max < 2) return 1;
  const vals = sh.getRange(2, col, max - 1, 1).getValues();
  for (let i = vals.length - 1; i >= 0; i--) {
    if (vals[i][0] !== '' && vals[i][0] !== null) return i + 2;
  }
  return 1;
}

function toNumber_(v) {
  if (typeof v === 'number') return v;
  const n = parseFloat(String(v || '').replace(/[^0-9.\-]/g, ''));
  return isNaN(n) ? null : n;
}

function same_(a, b) {
  return String(a || '').trim().toLowerCase() === String(b || '').trim().toLowerCase();
}

// ---------- actions ----------

function listClients_() {
  const clients = readTable_('Clients');
  const inactive = {};
  clients.forEach(function (c) {
    if (same_(c['Active'], 'no')) inactive[String(c['Client']).trim()] = true;
  });

  const out = [];
  const seen = {};
  const hasRate = {};
  readTable_('Rates').forEach(function (r) {
    const client = String(r['Client'] || '').trim();
    const type = String(r['Work Type'] || '').trim();
    if (!client || inactive[client]) return;
    const k = client + '|' + type;
    if (seen[k]) return;
    seen[k] = true;
    hasRate[client] = true;
    out.push({ client: client, workType: type });
  });

  // Active clients with no row in Rates still show up, with no work type.
  clients.forEach(function (c) {
    const name = String(c['Client'] || '').trim();
    if (name && !inactive[name] && !hasRate[name]) out.push({ client: name, workType: '' });
  });
  return out;
}

function rateFor_(client, workType) {
  const rates = readTable_('Rates');
  for (let i = 0; i < rates.length; i++) {
    if (same_(rates[i]['Client'], client) && same_(rates[i]['Work Type'], workType)) {
      const n = toNumber_(rates[i]['Hourly Rate']);
      if (n !== null) return n;
    }
  }
  const clients = readTable_('Clients');
  for (let i = 0; i < clients.length; i++) {
    if (same_(clients[i]['Client'], client)) {
      const n = toNumber_(clients[i]['Default Rate']);
      if (n !== null) return n;
    }
  }
  const settings = tab_('Settings').getDataRange().getValues();
  for (let i = 0; i < settings.length; i++) {
    if (same_(settings[i][0], 'Default Hourly Rate')) return toNumber_(settings[i][1]);
  }
  return null;
}

function addTime_(p) {
  // If the Mac retries after a dropped connection, don't add the row twice.
  const cache = CacheService.getScriptCache();
  if (p.id && cache.get('t:' + p.id)) return Number(cache.get('t:' + p.id));

  const lock = LockService.getScriptLock();
  lock.waitLock(15000);
  try {
    const sh = tab_('Time Log');
    const headers = headers_(sh);
    const dateCol = colOf_(headers, 'Date');
    if (!dateCol) throw new Error('Time Log needs a "Date" column');
    const row = lastFilledRow_(sh, dateCol) + 1;
    if (row > sh.getMaxRows()) sh.insertRowsAfter(sh.getMaxRows(), 50);

    const parts = String(p.date).split('-').map(Number);
    const hours = Number(p.hours);
    const rate = rateFor_(p.client, p.workType);
    const values = {
      'Date': new Date(parts[0], parts[1] - 1, parts[2]),
      'Client': p.client,
      'Work Type': p.workType || '',
      'Task': p.task || '',
      'Duration': hours,
      'Hourly Rate': rate === null ? '' : rate,
      'Total Price': rate === null ? '' : Math.round(hours * rate * 100) / 100,
      'Logged At': new Date()
    };

    Object.keys(values).forEach(function (h) {
      const c = colOf_(headers, h);
      if (!c) return;
      const cell = sh.getRange(row, c);
      if (cell.getFormula()) return; // leave any formulas you already set up
      cell.setValue(values[h]);
    });

    if (p.id) cache.put('t:' + p.id, String(row), 21600);
    return row;
  } finally {
    lock.releaseLock();
  }
}

function addClient_(p) {
  const name = String(p.client || '').trim();
  const type = String(p.workType || '').trim();
  if (!name) throw new Error('Client name is empty');

  const lock = LockService.getScriptLock();
  lock.waitLock(15000);
  try {
    // Clients tab: just the name and Active = Yes. Fill in the rest in the sheet.
    const known = readTable_('Clients').some(function (c) { return same_(c['Client'], name); });
    if (!known) {
      writeNextRow_(tab_('Clients'), 'Client', { 'Client': name, 'Invoice To (name)': name, 'Active': 'Yes' });
    }
    // Rates tab: client + work type, rate left blank for you to fill in.
    if (type) {
      const hasRate = readTable_('Rates').some(function (r) { return same_(r['Client'], name) && same_(r['Work Type'], type); });
      if (!hasRate) writeNextRow_(tab_('Rates'), 'Client', { 'Client': name, 'Work Type': type });
    }
  } finally {
    lock.releaseLock();
  }
}

function writeNextRow_(sh, keyHeader, values) {
  const headers = headers_(sh);
  const keyCol = colOf_(headers, keyHeader);
  const row = lastFilledRow_(sh, keyCol || 1) + 1;
  if (row > sh.getMaxRows()) sh.insertRowsAfter(sh.getMaxRows(), 10);
  Object.keys(values).forEach(function (h) {
    const c = colOf_(headers, h);
    if (c) sh.getRange(row, c).setValue(values[h]);
  });
}

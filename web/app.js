// Episode Renamer web UI. Talks to server.ps1's JSON API. All file/folder names are inserted with
// textContent, never innerHTML, so odd file names can't inject markup.
'use strict';

const $ = (id) => document.getElementById(id);
const state = {
  kind: 'TV',
  plans: { TV: [], Movie: [] },
  checked: { TV: new Set(), Movie: new Set() },
  settings: null,
  info: null,
  busy: false,
  browsePath: '',
  match: null,          // { index, plan, results, selected }
};

const HINTS = {
  TV: 'Pick one show folder or a whole TV library. Show folders become "Show (Year)", season folders "Season 01", and episodes follow your name scheme (Settings).',
  Movie: 'Pick a movies folder (or one movie\'s folder). Movies become "Title (Year)/Title (Year).mkv". Add a free TMDB key in Settings for exact titles; otherwise the title and year come from the file name.',
};

// ---------------------------------------------------------------- api

async function api(method, path, body) {
  const res = await fetch(path, {
    method,
    headers: body ? { 'Content-Type': 'application/json' } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  let data = null;
  try { data = await res.json(); } catch (e) { /* not json */ }
  if (!res.ok) throw new Error((data && data.error) || `Request failed (${res.status})`);
  return data;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitForJob(id) {
  for (;;) {
    const j = await api('GET', `/api/job?id=${encodeURIComponent(id)}`);
    if (j.status) setStatus(j.status);
    if (j.done) {
      if (j.error) throw new Error(j.error);
      return j;
    }
    await sleep(600);
  }
}

// ---------------------------------------------------------------- status + busy

function setStatus(text, isError) {
  const el = $('status');
  el.textContent = text || '';
  el.classList.toggle('error', !!isError);
}

function setBusy(on) {
  state.busy = on;
  $('spinner').hidden = !on;
  for (const id of ['analyzeBtn', 'browseBtn', 'renameBtn', 'undoBtn', 'settingsBtn', 'checkAllBtn', 'checkNoneBtn']) $(id).disabled = on;
  document.querySelectorAll('.tab').forEach((t) => (t.disabled = on));
  document.querySelectorAll('button[data-rematch]').forEach((b) => (b.disabled = on));
}

async function run(task) {
  if (state.busy) return;
  setBusy(true);
  try { await task(); }
  catch (e) { setStatus(e.message, true); }
  finally { setBusy(false); }
}

// ---------------------------------------------------------------- theme

const THEMES = ['auto', 'light', 'dark'];
function currentTheme() {
  try { return localStorage.getItem('theme') || 'auto'; } catch (e) { return 'auto'; }
}
function applyTheme(t) {
  if (t === 'auto') delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = t;
  try { localStorage.setItem('theme', t); } catch (e) { /* private mode */ }
  const label = { auto: '\u25D0 Auto', light: '\u2600 Light', dark: '\u263E Dark' }[t];
  $('themeBtn').textContent = label;
}

// ---------------------------------------------------------------- tabs + rendering

function statusClass(s) {
  if (!s) return 'st-dim';
  if (/^(Ready|Renamed|Rename folder)/.test(s)) return 'st-ok';
  if (/^Up to date/.test(s)) return 'st-dim';
  return 'st-bad';
}

function cell(tr, text, cls) {
  const td = document.createElement('td');
  td.textContent = text == null ? '' : String(text);
  td.title = td.textContent;
  if (cls) td.className = cls;
  tr.appendChild(td);
  return td;
}

function render() {
  const kind = state.kind;
  const plans = state.plans[kind];
  const tbody = document.querySelector('#results tbody');
  tbody.replaceChildren();
  $('hint').textContent = HINTS[kind];
  $('movieFoldersWrap').hidden = kind !== 'Movie';
  $('folder').placeholder = kind === 'TV' ? '/media/TV' : '/media/Movies';

  const has = plans.length > 0;
  $('results').hidden = !has;
  $('toolbar').hidden = !has;
  $('empty').hidden = has;
  if (!has) return;

  const only = $('onlyChk').checked;
  let hiddenShows = 0, hiddenFiles = 0;
  for (const p of plans) {
    // Hide what needs nothing; shows that need attention (not found, errors) stay visible.
    if (only && p.changes === 0 && /^Up to date/.test(p.status)) { hiddenShows++; continue; }
    const tr = document.createElement('tr');
    tr.className = 'parent';
    const tdUse = document.createElement('td');
    if (p.changes > 0) {
      const cb = document.createElement('input');
      cb.type = 'checkbox';
      cb.checked = state.checked[kind].has(p.index);
      cb.title = 'Include in rename';
      cb.addEventListener('change', () => {
        if (cb.checked) state.checked[kind].add(p.index); else state.checked[kind].delete(p.index);
        updateSummary();
      });
      tdUse.appendChild(cb);
    }
    tr.appendChild(tdUse);
    cell(tr, p.label).title = p.dir;
    cell(tr, p.newName || '');
    const tdMatch = cell(tr, p.match ? `${p.match.name}${p.match.year ? ` (${p.match.year})` : ''}` : '');
    if (p.match) {
      const s = document.createElement('span');
      s.className = 'src';
      s.textContent = p.match.source === 'Filename' ? 'from filename' : p.match.source;
      tdMatch.appendChild(s);
    }
    cell(tr, p.status, statusClass(p.status));
    const tdAct = document.createElement('td');
    const btn = document.createElement('button');
    btn.className = 'small';
    btn.textContent = 'Change\u2026';
    btn.title = 'Change what this was matched as';
    btn.dataset.rematch = p.index;
    btn.disabled = state.busy;
    btn.addEventListener('click', () => openMatch(p));
    tdAct.appendChild(btn);
    tr.appendChild(tdAct);
    tbody.appendChild(tr);

    for (const r of p.rows) {
      if (only && !/^(Ready|Rename folder)/.test(r.status)) { hiddenFiles++; continue; }
      const c = document.createElement('tr');
      c.className = 'child';
      c.appendChild(document.createElement('td'));
      cell(c, r.current, 'indent');
      cell(c, r.new, 'indent');
      cell(c, '');
      cell(c, r.status, statusClass(r.status));
      c.appendChild(document.createElement('td'));
      tbody.appendChild(c);
    }
  }
  state.hidden = { shows: hiddenShows, files: hiddenFiles };
  updateSummary();
}

function updateSummary() {
  const plans = state.plans[state.kind];
  const ready = plans.filter((p) => p.changes > 0).length;
  const checked = state.checked[state.kind].size;
  const what = state.kind === 'TV' ? 'show' : 'movie';
  const h = state.hidden || { shows: 0, files: 0 };
  const hidden = h.shows + h.files ? ` \u00B7 hidden: ${[h.shows ? `${h.shows} up to date` : '', h.files ? `${h.files} unchanged file(s)` : ''].filter(Boolean).join(', ')}` : '';
  $('summary').textContent = `${plans.length} ${what}${plans.length === 1 ? '' : 's'} \u00B7 ${ready} with changes \u00B7 ${checked} checked${hidden}`;
}

function switchTab(kind) {
  state.kind = kind;
  document.querySelectorAll('.tab').forEach((t) => t.classList.toggle('active', t.dataset.kind === kind));
  const s = state.settings || {};
  $('folder').value = (kind === 'TV' ? s.TvRoot : s.MovieRoot) || '';
  setStatus('');
  render();
}

async function loadPlans(kind, keepChecks) {
  const data = await api('GET', `/api/plans?kind=${kind}`);
  state.plans[kind] = data.plans;
  if (!keepChecks) state.checked[kind] = new Set(data.plans.filter((p) => p.changes > 0 && !/^Error/.test(p.status)).map((p) => p.index));
  else for (const i of [...state.checked[kind]]) if (!data.plans[i] || data.plans[i].changes === 0) state.checked[kind].delete(i);
  if (kind === state.kind) render();
}

// ---------------------------------------------------------------- actions

function analyze() {
  return run(async () => {
    const root = $('folder').value.trim();
    if (!root) throw new Error('Pick a folder first.');
    const kind = state.kind;
    state.plans[kind] = [];
    render();
    setStatus('Starting\u2026');
    const { job } = await api('POST', '/api/analyze', { kind, root });
    await waitForJob(job);
    if (kind === 'TV') state.settings.TvRoot = root; else state.settings.MovieRoot = root;
    await loadPlans(kind, false);
    const plans = state.plans[kind];
    const ready = plans.filter((p) => p.changes > 0).length;
    setStatus(plans.length ? `Found ${plans.length} ${kind === 'TV' ? 'show' : 'movie'}${plans.length === 1 ? '' : 's'}, ${ready} with changes to make.` : 'Nothing found in that folder.');
  });
}

function renameChecked() {
  return run(async () => {
    const kind = state.kind;
    const indexes = [...state.checked[kind]];
    const plans = state.plans[kind].filter((p) => indexes.includes(p.index));
    const changes = plans.reduce((n, p) => n + p.changes, 0);
    if (!plans.length) throw new Error('Nothing is checked that has changes to make.');
    const what = kind === 'TV' ? 'show' : 'movie';
    if (!confirm(`Apply ${changes} rename${changes === 1 ? '' : 's'} across ${plans.length} ${what}${plans.length === 1 ? '' : 's'}?\n\nYou can put everything back with "Undo last rename".`)) return;
    setStatus('Renaming\u2026');
    const { results, sync } = await api('POST', '/api/rename', { kind, indexes });
    const ok = results.filter((r) => r.ok).length;
    await loadPlans(kind, true);
    state.checked[kind].clear();
    render();
    setStatus(`Done: ${ok} of ${results.length} ${what}${results.length === 1 ? '' : 's'} renamed.${ok < results.length ? ' See the Status column for problems.' : ''} Analyze again to see the result.${syncSummary(sync)}`, ok < results.length || syncFailed(sync));
  });
}

function undo() {
  return run(async () => {
    if (!confirm('Undo the most recent batch of renames?')) return;
    setStatus('Undoing\u2026');
    const r = await api('POST', '/api/undo');
    let msg = `Restored ${r.restored} file(s) and folder(s).${syncSummary(r.sync)}`;
    if (r.errors.length) msg += ` Problems: ${r.errors.slice(0, 3).join(' \u00B7 ')}`;
    setStatus(msg, r.errors.length > 0);
    // Old previews are stale now.
    state.plans = { TV: [], Movie: [] };
    state.checked = { TV: new Set(), Movie: new Set() };
    render();
  });
}

// Sonarr/Radarr/Plex/Jellyfin results: a short summary in the status bar, every line in its tooltip.
const SYNC_BAD = /couldn't|rejected|failed|isn't connected/i;
function syncFailed(lines) { return (lines || []).some((l) => SYNC_BAD.test(l)); }
function syncSummary(lines) {
  lines = lines || [];
  $('status').title = lines.join('\n');
  if (!lines.length) return '';
  const bad = lines.filter((l) => SYNC_BAD.test(l)).length;
  return `   Media apps: ${lines.length - bad} updated${bad ? `, ${bad} problem(s): ${lines.filter((l) => SYNC_BAD.test(l)).join(' \u00B7 ')}` : ''}.`;
}

// ---------------------------------------------------------------- folder browser

async function browseTo(path) {
  const data = await api('GET', `/api/browse?path=${encodeURIComponent(path || '')}`);
  state.browsePath = data.path;
  $('browsePath').textContent = data.path || 'Media folders';
  $('useFolderBtn').disabled = !data.path;
  const list = $('dirList');
  list.replaceChildren();
  if (data.path) {
    const li = document.createElement('li');
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'up';
    b.textContent = '\u2191  Up';
    b.addEventListener('click', () => browseTo(data.parent).catch((e) => setStatus(e.message, true)));
    li.appendChild(b);
    list.appendChild(li);
  }
  for (const d of data.dirs) {
    const li = document.createElement('li');
    const b = document.createElement('button');
    b.type = 'button';
    b.textContent = `\uD83D\uDCC1  ${d.name}`;
    b.addEventListener('click', () => browseTo(d.path).catch((e) => setStatus(e.message, true)));
    li.appendChild(b);
    list.appendChild(li);
  }
  if (!data.dirs.length && data.path) {
    const li = document.createElement('li');
    li.className = 'st-dim';
    li.style.padding = '8px 10px';
    li.textContent = 'No sub-folders.';
    list.appendChild(li);
  }
}

async function openBrowse() {
  try {
    const start = $('folder').value.trim();
    try { await browseTo(start); } catch (e) { await browseTo(''); }
    $('browseDlg').showModal();
  } catch (e) { setStatus(e.message, true); }
}

// ---------------------------------------------------------------- change match

function renderMatchList() {
  const m = state.match;
  const list = $('matchList');
  list.replaceChildren();
  m.results.forEach((r, i) => {
    const li = document.createElement('li');
    const label = document.createElement('label');
    const radio = document.createElement('input');
    radio.type = 'radio';
    radio.name = 'match';
    radio.checked = i === m.selected;
    radio.addEventListener('change', () => { m.selected = i; renderMatchList(); });
    label.appendChild(radio);
    const span = document.createElement('span');
    span.textContent = r.display || `${r.name} (${r.year})`;
    label.appendChild(span);
    if (i === m.selected) label.classList.add('selected');
    label.addEventListener('dblclick', () => { m.selected = i; useMatch(r); });
    li.appendChild(label);
    list.appendChild(li);
  });
  if (!m.results.length) {
    const li = document.createElement('li');
    li.className = 'st-dim';
    li.style.padding = '8px 10px';
    li.textContent = 'No results yet. Search above.';
    list.appendChild(li);
  }
  $('matchUseBtn').disabled = m.selected < 0;
}

function openMatch(plan) {
  const isMovie = state.kind === 'Movie';
  const results = plan.results || [];
  let selected = -1;
  if (plan.match) selected = results.findIndex((r) => r.id === plan.match.id && r.source === plan.match.source);
  if (selected < 0 && results.length) selected = 0;
  state.match = { index: plan.index, plan, results, selected };
  $('matchTitle').textContent = `Change match: ${plan.label}`;
  $('matchQuery').value = plan.query || '';
  $('matchYear').value = plan.year || '';
  $('matchTypedBtn').hidden = !isMovie;
  $('matchNote').textContent = isMovie && !(state.settings && (state.settings.TmdbKey || (state.settings.RadarrUrl && state.settings.RadarrKey)))
    ? 'No Radarr or TMDB key set, so search is off. Type the title and year and click "Use title and year as typed".'
    : '';
  renderMatchList();
  $('matchDlg').showModal();
}

async function searchMatch() {
  const m = state.match;
  $('matchSearchBtn').disabled = true;
  $('matchNote').textContent = 'Searching\u2026';
  try {
    const { results } = await api('POST', '/api/search', { kind: state.kind, query: $('matchQuery').value, year: $('matchYear').value });
    m.results = results;
    m.selected = results.length ? 0 : -1;
    $('matchNote').textContent = results.length ? '' : 'Nothing found.';
    renderMatchList();
  } catch (e) {
    $('matchNote').textContent = e.message;
  } finally {
    $('matchSearchBtn').disabled = false;
  }
}

function useMatch(match) {
  const kind = state.kind;
  const index = state.match.index;
  $('matchDlg').close();
  return run(async () => {
    setStatus(`Re-checking as ${match.name}\u2026`);
    const { job } = await api('POST', '/api/rematch', { kind, index, match });
    await waitForJob(job);
    await loadPlans(kind, true);
    const p = state.plans[kind][index];
    if (p && p.changes > 0) { state.checked[kind].add(index); render(); }
    setStatus(`Matched ${p ? p.label : ''} as ${match.name}${match.year ? ` (${match.year})` : ''}.`);
  });
}

// ---------------------------------------------------------------- settings

const SETTING_FIELDS = ['Source', 'Order', 'MatchMode', 'Numbering', 'TitleMode', 'Language', 'Scheme', 'TvdbApiKey', 'TvdbPin', 'TmdbKey',
  'SonarrUrl', 'SonarrKey', 'RadarrUrl', 'RadarrKey', 'PlexUrl', 'PlexToken', 'JellyfinUrl', 'JellyfinKey'];
const SETTING_CHECKS = ['RenameExtras', 'ArrSync'];

function openSettings() {
  const f = $('settingsForm');
  const s = state.settings;
  for (const k of SETTING_FIELDS) if (f.elements[k]) f.elements[k].value = s[k] ?? '';
  for (const k of SETTING_CHECKS) f.elements[k].checked = !!s[k];
  $('testResult').textContent = '';
  $('settingsDlg').showModal();
}

async function saveSettings(extra) {
  const body = extra || {};
  if (!extra) {
    const f = $('settingsForm');
    for (const k of SETTING_FIELDS) body[k] = f.elements[k].value;
    for (const k of SETTING_CHECKS) body[k] = f.elements[k].checked;
  }
  state.settings = await api('POST', '/api/settings', body);
}

// ---------------------------------------------------------------- wiring

document.querySelectorAll('.tab').forEach((t) => t.addEventListener('click', () => { if (!state.busy) switchTab(t.dataset.kind); }));
$('analyzeBtn').addEventListener('click', analyze);
$('folder').addEventListener('keydown', (e) => { if (e.key === 'Enter') analyze(); });
$('browseBtn').addEventListener('click', openBrowse);
$('useFolderBtn').addEventListener('click', () => { if (state.browsePath) $('folder').value = state.browsePath; });
$('renameBtn').addEventListener('click', renameChecked);
$('undoBtn').addEventListener('click', undo);
$('checkAllBtn').addEventListener('click', () => {
  const k = state.kind;
  state.plans[k].forEach((p) => { if (p.changes > 0) state.checked[k].add(p.index); });
  render();
});
$('checkNoneBtn').addEventListener('click', () => { state.checked[state.kind].clear(); render(); });
$('detailsChk').addEventListener('change', (e) => $('results').classList.toggle('details-off', !e.target.checked));
$('onlyChk').addEventListener('change', (e) => { try { localStorage.setItem('onlyChanges', e.target.checked ? '1' : '0'); } catch (err) { /* private mode */ } render(); });
try { if (localStorage.getItem('onlyChanges') === '0') $('onlyChk').checked = false; } catch (e) { /* private mode */ }
$('movieFoldersChk').addEventListener('change', (e) => run(async () => {
  await saveSettings({ MovieFolders: e.target.checked });
  if (state.plans.Movie.length) { setBusy(false); await analyze(); }
}));
$('themeBtn').addEventListener('click', () => {
  const t = THEMES[(THEMES.indexOf(currentTheme()) + 1) % THEMES.length];
  applyTheme(t);
});
$('settingsBtn').addEventListener('click', openSettings);
$('settingsSaveBtn').addEventListener('click', async () => {
  try {
    await saveSettings();
    $('settingsDlg').close();
    setStatus('Settings saved. Analyze again to apply them.');
  } catch (e) { setStatus(e.message, true); }
});
document.querySelectorAll('button[data-test]').forEach((b) => b.addEventListener('click', async () => {
  const app = b.dataset.test;
  const f = $('settingsForm');
  const urlField = { Sonarr: 'SonarrUrl', Radarr: 'RadarrUrl', Plex: 'PlexUrl', Jellyfin: 'JellyfinUrl' }[app];
  const keyField = { Sonarr: 'SonarrKey', Radarr: 'RadarrKey', Plex: 'PlexToken', Jellyfin: 'JellyfinKey' }[app];
  const out = $('testResult');
  out.className = 'dlg-note';
  out.textContent = `Testing ${app}\u2026`;
  b.disabled = true;
  try {
    const r = await api('POST', '/api/test', { app, url: f.elements[urlField].value, key: f.elements[keyField].value });
    out.textContent = r.message;
    out.className = `dlg-note ${r.ok ? 'ok' : 'bad'}`;
  } catch (e) {
    out.textContent = e.message;
    out.className = 'dlg-note bad';
  } finally { b.disabled = false; }
}));
$('matchSearchBtn').addEventListener('click', searchMatch);
$('matchQuery').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); searchMatch(); } });
$('matchYear').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); searchMatch(); } });
$('matchUseBtn').addEventListener('click', () => {
  const m = state.match;
  if (m.selected >= 0) useMatch(m.results[m.selected]);
});
$('matchTypedBtn').addEventListener('click', () => {
  const name = $('matchQuery').value.trim();
  if (!name) { $('matchNote').textContent = 'Type a title first.'; return; }
  const year = /^\d{4}$/.test($('matchYear').value.trim()) ? $('matchYear').value.trim() : '';
  useMatch({ source: 'Filename', id: null, name, year, display: name });
});

(async function init() {
  applyTheme(currentTheme());
  try {
    [state.info, state.settings] = await Promise.all([api('GET', '/api/info'), api('GET', '/api/settings')]);
    $('version').textContent = `v${state.info.version}`;
    $('movieFoldersChk').checked = !!state.settings.MovieFolders;
    switchTab('TV');
    setStatus(`Media folders: ${state.info.roots.join(', ')}`);
  } catch (e) {
    setStatus(`Can't reach the server: ${e.message}`, true);
  }
})();

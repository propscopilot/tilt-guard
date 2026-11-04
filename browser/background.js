// PropsCopilot Tilt Guard - a plain client for your PropsCopilot cockpit. Holds your guard key and one device token per
// trading account, checks in for each open platform tab, and asks the cockpit about each new entry. Every decision is
// made by the cockpit.
// Only propscopilot.com is ever contacted. No broker login, password or order details beyond the entry being checked.
const VERSION = "web-1.00";
const PLATFORM = [[/tradelocker\./, "tradelocker"], [/match-trader\.|mtr\./, "matchtrader"], [/tradovate\./, "tradovate"],
                  [/topstepx\.|projectx\./, "projectx"], [/dx\.trade|dxtrade/, "dxtrade"], [/tradingview\./, "tradingview"]];
const tabs = {};                                         // tab id -> {block}

function platformOf(host) {
  for (const [re, p] of PLATFORM) if (re.test(host)) return p;
  return "web";
}

async function store() {
  return Object.assign({ key: "", api: "https://propscopilot.com", tokens: {}, locks: {}, sites: [] },
                       await chrome.storage.local.get(["key", "api", "tokens", "locks", "sites"]));
}

async function post(api, path, body, token) {
  const headers = { "Content-Type": "application/json" };
  if (token) headers.Authorization = "Bearer " + token;
  const r = await fetch(api + path, { method: "POST", headers, body: JSON.stringify(body) });
  let j = {};
  try { j = await r.json(); } catch (e) { /* not JSON */ }
  return { status: r.status, j };
}

function idOf(host, account) { return host + "|" + (account || ""); }

async function token(host, account, facts) {
  const st = await store();
  const id = idOf(host, account);
  if (st.tokens[id]) return { tok: st.tokens[id], st };
  if (!st.key) return { err: "Paste your guard key: click the Tilt Guard icon", st };
  const { status, j } = await post(st.api, "/api/guard/v1/link", {
    code: st.key, platform: platformOf(host), login: account || host, server: host, version: VERSION,
    company: host, balance: facts.balance || 0, trade_mode: /demo|practice|sim/i.test(host + " " + (account || "")) ? "demo" : "",
  });
  if (status !== 200 || !j.token) return { err: j.error || "couldn't link (" + status + ")", st };
  st.tokens[id] = j.token;
  await chrome.storage.local.set({ tokens: st.tokens });
  return { tok: j.token, st };
}

function hhmm(t) { return new Date(t * 1000).toISOString().slice(11, 16) + " UTC"; }

async function forget(id, st) {
  delete st.tokens[id];
  await chrome.storage.local.set({ tokens: st.tokens });
}

async function onSync(m, tabId) {
  const facts = { balance: m.balance, equity: m.equity };
  const { tok, err, st } = await token(m.host, m.account, facts);
  const id = idOf(m.host, m.account);
  const cached = (st.locks[id] || 0) > Date.now() / 1000 ? "locked until " + hhmm(st.locks[id]) : "";
  if (!tok) return { ok: false, linked: false, err, locked_reason: cached };
  let r;
  try {
    r = await post(st.api, "/api/guard/v1/sync", {
      engine: "server", login: m.account || m.host, server: m.host, company: m.host, equity: m.equity || m.balance || 0,
      balance: m.balance || 0, version: VERSION, algo: true, events: m.events || [], done_commands: m.done || [],
    }, tok);
  } catch (e) {
    return { ok: false, linked: true, err: "offline", locked_reason: cached };
  }
  if (r.status === 401) { await forget(id, st); return { ok: false, linked: false, err: "unlinked: it will link again", locked_reason: cached }; }
  if (r.status !== 200 || !r.j.ok) return { ok: false, linked: true, err: "server said " + r.status, locked_reason: cached };
  const j = r.j;                                   // what to do, never how it was decided: that stays on the server
  st.locks[id] = j.lock_until || 0;
  await chrome.storage.local.set({ locks: st.locks });
  const block = j.entry_block || ((j.lock_until || 0) > Date.now() / 1000 ? "locked until " + hhmm(j.lock_until) : "");
  tabs[tabId] = { block };
  return { ok: true, linked: true, entry_block: block, state: j.state, score: j.score, label: j.label,
           left: j.room_left, nearest: j.room_text || "", commands: j.commands || [] };
}

async function onCheck(m) {
  const { tok, st } = await token(m.host, m.account, m.info || {});
  if (!tok) return { ok: false };
  const i = m.info || {};
  try {
    const r = await post(st.api, "/api/guard/v1/check", {
      id: "w-" + Date.now() + "-" + Math.random().toString(36).slice(2, 8), symbol: i.symbol || "", side: i.side || "buy",
      volume: i.volume || 0, equity: i.equity || 0, balance: i.balance || 0, stop_grace: true, open_positions: [],
    }, tok);
    if (r.status !== 200) return { ok: false };
    if (!r.j.allow && r.j.until) {
      const id = idOf(m.host, m.account);
      st.locks[id] = Math.max(st.locks[id] || 0, r.j.until);
      await chrome.storage.local.set({ locks: st.locks });
    }
    return { ok: true, allow: r.j.allow, why: r.j.why, score: r.j.score, state: r.j.state };
  } catch (e) {
    return { ok: false };
  }
}

chrome.runtime.onMessage.addListener((m, sender, reply) => {
  const tabId = sender.tab ? sender.tab.id : -1;
  if (m.type === "sync") { onSync(m, tabId).then(reply, () => reply(null)); return true; }
  if (m.type === "check") { onCheck(m).then(reply, () => reply(null)); return true; }
  if (m.type === "peek") { reply(tabs[tabId] || { block: "" }); return false; }
  if (m.type === "guard-site") { guardSite(m.origin).then(reply, (e) => reply({ ok: false, err: String(e) })); return true; }
  return false;
});

// ------------------------------------------------------------ sites the trader adds (a firm's own web platform)
async function register(origins) {
  const pats = origins.map((o) => o.replace(/\/$/, "") + "/*");
  try { await chrome.scripting.unregisterContentScripts({ ids: ["pcg-page", "pcg-content"] }); } catch (e) { /* none yet */ }
  if (!pats.length) return;
  await chrome.scripting.registerContentScripts([
    { id: "pcg-page", matches: pats, js: ["page.js"], runAt: "document_start", world: "MAIN", allFrames: true },
    { id: "pcg-content", matches: pats, js: ["content.js"], runAt: "document_start", allFrames: true },
  ]);
}

async function guardSite(origin) {
  const st = await store();
  if (!st.sites.includes(origin)) st.sites.push(origin);
  await chrome.storage.local.set({ sites: st.sites });
  await register(st.sites);
  return { ok: true };
}

chrome.runtime.onInstalled.addListener(async (d) => {
  const st = await store();
  await register(st.sites);
  if (d.reason === "install") chrome.tabs.create({ url: "https://propscopilot.com/guard?browser=1#connect" });
});
chrome.runtime.onStartup.addListener(async () => { const st = await store(); await register(st.sites); });

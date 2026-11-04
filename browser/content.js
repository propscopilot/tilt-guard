// PropsCopilot Tilt Guard - the guard's eyes and hands on the trading page: the panel, the answers to page.js,
// the shield on the Buy/Sell buttons while a lock runs, and the check-in with your cockpit every few seconds.
(() => {
  if (window.__pcgContent) return;
  window.__pcgContent = true;
  const host = location.hostname;
  const top = window === window.top;
  const S = { block: "", state: "calm", score: 0, label: "", left: null, nearest: "", online: false, linked: false, err: "",
              acct: "", balance: null, equity: null, lastBal: null, events: [], done: [], fromData: false, synced: 0 };

  function send(msg) {
    return new Promise((resolve) => {
      try { chrome.runtime.sendMessage(msg, (r) => { void chrome.runtime.lastError; resolve(r || null); }); }
      catch (e) { resolve(null); }       // the extension was updated or removed: the page keeps working
    });
  }

  // ------------------------------------------------------------ answers to page.js
  window.addEventListener("message", async (e) => {
    if (e.source !== window || !e.data || !e.data.__pcg) return;
    const d = e.data;
    if (d.__pcg === "acct") { S.acct = d.id; return; }
    if (d.__pcg === "data") { takeNumbers(d.accounts); return; }
    if (d.__pcg !== "ask") return;
    let res = null;
    if (S.block) res = { allow: false, why: S.block };
    else {
      const info = Object.assign({}, d.info, { equity: S.equity, balance: S.balance });
      res = await Promise.race([send({ type: "check", host, account: S.acct, info }),
                                new Promise((r) => setTimeout(() => r(null), 2500))]);
      if (!res || res.ok === false) res = { allow: !S.block, why: S.block };      // can't reach the server: last known locks
    }
    if (!res.allow) { toast("Blocked: " + (res.why || "Tilt Guard")); if (res.state) S.state = res.state; }
    if (res.score != null) { S.score = res.score; S.state = res.state || S.state; }
    window.postMessage({ __pcg: "answer", rid: d.rid, res: { allow: !!res.allow, why: res.why || "" } }, "*");
    draw();
  });

  function takeNumbers(list) {
    if (!list || !list.length) return;
    let a = list.find((x) => S.acct && x.id === S.acct) || (list.length === 1 ? list[0] : null);
    if (!a) a = list.find((x) => x.balance != null) || list[0];
    if (!S.acct && a.id) S.acct = a.id;
    if (a.balance != null) S.balance = a.balance;
    if (a.equity != null) S.equity = a.equity;
    S.fromData = true;
  }

  // the page's own words, when the platform's data didn't say: "Balance 100,000.00", "Equity 99,870.12"
  function readDom() {
    if (S.fromData || !document.body) return;
    const want = { balance: /^(balance|account balance|cash balance)\s*:?$/i, equity: /^(equity|net liq(uidation)?( value)?|account equity)\s*:?$/i };
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    let n, seen = 0;
    while ((n = walker.nextNode()) && seen < 20000) {
      seen++;
      const t = n.nodeValue.trim();
      for (const k of Object.keys(want)) {
        if (!want[k].test(t)) continue;
        const box = n.parentElement && (n.parentElement.parentElement || n.parentElement);
        const m = box && /-?[\d,]+(?:\.\d+)?/.exec(box.innerText.replace(t, ""));
        if (m) S[k] = parseFloat(m[0].replace(/,/g, ""));
      }
    }
  }

  // ------------------------------------------------------------ the shield: while locked, entry buttons don't work
  const ENTRY_BTN = /^(buy|sell|long|short|place( order)?|submit( order)?|join (bid|ask)|reverse)\b/i;
  const EXIT_BTN = /(close|exit|flatten|cancel|liquidat|remove|modify|edit)/i;
  function entryButton(el) {
    for (let i = 0; el && i < 5; i++, el = el.parentElement) {
      const role = el.getAttribute && (el.getAttribute("role") || "");
      if (el.tagName === "BUTTON" || role === "button" || el.tagName === "A" || (el.onclick != null)) {
        const t = (el.innerText || el.getAttribute("aria-label") || "").trim().split("\n")[0];
        return ENTRY_BTN.test(t) && !EXIT_BTN.test(t) ? el : null;
      }
    }
    return null;
  }
  for (const ev of ["pointerdown", "mousedown", "click", "touchstart"]) {
    window.addEventListener(ev, (e) => {
      if (!S.block || !entryButton(e.target)) return;
      e.stopImmediatePropagation();
      e.preventDefault();
      if (ev === "click") toast("Locked: " + S.block);
    }, true);
  }

  // ------------------------------------------------------------ flatten from your cockpit (panic, limits)
  const CLOSE_ALL = /^(close all( positions)?|flatten( all)?|liquidate( all)?|exit all|close all trades)$/i;
  function flatten() {
    const els = [...document.querySelectorAll("button,[role=button],a")].filter((b) => CLOSE_ALL.test((b.innerText || "").trim()));
    els.slice(0, 2).forEach((b) => b.click());
    setTimeout(() => {
      const ok = [...document.querySelectorAll("[role=dialog] button, .modal button, dialog button")]
        .filter((b) => /^(confirm|yes|ok|close( all)?( positions)?)$/i.test((b.innerText || "").trim()));
      ok.slice(0, 1).forEach((b) => b.click());
    }, 600);
    banner(els.length ? "Flattening: closing everything as your cockpit asked."
                      : "FLATTEN NOW: your cockpit asked to close every position. Close them by hand.");
  }

  // ------------------------------------------------------------ check in
  async function sync() {
    if (!top) return;
    readDom();
    if (S.balance != null && S.lastBal != null && Math.abs(S.balance - S.lastBal) >= 0.01) {
      S.events.push({ id: "c-" + host + "-" + Date.now(), t: Date.now() / 1000, kind: "close", pnl: +(S.balance - S.lastBal).toFixed(2) });
    }
    if (S.balance != null) S.lastBal = S.balance;
    const ev = S.events.slice(0, 100), done = S.done.slice();
    const r = await send({ type: "sync", host, account: S.acct, balance: S.balance, equity: S.equity, events: ev, done });
    if (!r) { S.online = false; draw(); return; }
    S.linked = !!r.linked;
    S.err = r.err || "";
    if (r.ok) {
      S.events.splice(0, ev.length);
      S.done.splice(0, done.length);
      S.online = true; S.synced = Date.now();
      S.block = r.entry_block || "";
      S.state = r.state || "calm"; S.score = r.score || 0; S.label = r.label || "";
      S.left = r.left; S.nearest = r.nearest || "";
      for (const c of r.commands || []) if (c.kind === "flatten") { flatten(); S.done.push(c.id); }
    } else {
      S.online = false;              // offline: a lock we heard about still runs; an older "blocked" note fades after 2 min
      S.block = r.locked_reason || (Date.now() - S.synced < 120000 ? S.block : "");
    }
    draw();
  }

  // ------------------------------------------------------------ the panel (bottom-left, out of the way of order tickets)
  let root, els = {};
  function build() {
    if (!top || root || !document.body) return;
    const host_ = document.createElement("div");
    host_.id = "pcg-tilt-guard";
    host_.style.cssText = "position:fixed;left:12px;bottom:12px;z-index:2147483646;";
    root = host_.attachShadow({ mode: "open" });
    root.innerHTML = `<style>
      .p{font:12px/1.5 ui-monospace,Consolas,monospace;background:rgba(12,12,20,.94);color:#C9CCDA;border:1px solid #3C3E5A;
         border-radius:10px;padding:8px 12px;min-width:240px;max-width:360px;box-shadow:0 6px 24px rgba(0,0,0,.4)}
      .t{color:#fff;font-weight:700;display:flex;justify-content:space-between;gap:10px;cursor:pointer}
      .t span{color:#9AA0B8;font-weight:400}.calm{color:#9BE564}.caution{color:#FFC83D}.pause{color:#FF9F43}.stop{color:#FF3D7F}
      .lk{color:#FF3D7F}.ok{color:#9AA0B8}.r{color:#2EE6FF}.e{color:#FFC83D}.min .b{display:none}
      .toast,.ban{position:fixed;left:12px;bottom:150px;background:#FF3D7F;color:#07070C;font:700 13px system-ui;padding:10px 14px;border-radius:10px;
         max-width:420px;box-shadow:0 6px 24px rgba(0,0,0,.4)}
      .ban{bottom:auto;top:12px;left:50%;transform:translateX(-50%);font-size:15px}
      </style><div class="p" id="p"><div class="t" id="t">TILT GUARD <span id="lb"></span></div><div class="b">
      <div id="o"></div><div id="s"></div><div class="r" id="r"></div><div id="l"></div><div class="e" id="e"></div></div></div>`;
    for (const k of ["p", "t", "lb", "o", "s", "r", "l", "e"]) els[k] = root.getElementById(k);
    els.t.addEventListener("click", () => els.p.classList.toggle("min"));
    document.body.appendChild(host_);
    draw();
  }
  function draw() {
    if (!root) return;
    els.lb.textContent = S.label || host;
    els.o.textContent = !S.linked ? (S.err || "Paste your guard key: click the Tilt Guard icon") :
                        S.online ? "Online" : "Offline: obeying your last locks";
    els.o.className = S.online ? "calm" : "e";
    els.s.textContent = `TILT ${Math.round(S.score)}/100  ${String(S.state).toUpperCase()}`;
    els.s.className = S.state;
    els.r.textContent = S.left == null ? "Room left: set a limit or your firm at propscopilot.com/guard" :
                        `Room left $${Math.round(S.left).toLocaleString()} to ${S.nearest}`;
    els.l.textContent = S.block ? "LOCKED: " + S.block : "Entries open. Exits always open.";
    els.l.className = S.block ? "lk" : "ok";
    els.e.textContent = S.linked && S.err ? S.err : "";
  }
  function toast(msg) {
    if (!top) { window.top.postMessage({ __pcgToast: msg }, "*"); return; }
    build();
    if (!root) return;
    const d = document.createElement("div");
    d.className = "toast"; d.textContent = "Tilt Guard. " + msg;
    root.appendChild(d);
    setTimeout(() => d.remove(), 6000);
  }
  function banner(msg) {
    build();
    if (!root) return;
    const d = document.createElement("div");
    d.className = "ban"; d.textContent = msg;
    root.appendChild(d);
    setTimeout(() => d.remove(), 30000);
  }
  if (top) window.addEventListener("message", (e) => { if (e.data && e.data.__pcgToast) toast(String(e.data.__pcgToast).slice(0, 200)); });

  function start() {
    build();
    // give the platform a few seconds to say which account is open, so the account links once under its own number
    setTimeout(() => { sync(); setInterval(sync, 5000); }, S.acct ? 500 : 6000);
  }
  if (!top) setInterval(async () => { const r = await send({ type: "peek" }); if (r) S.block = r.block || ""; }, 3000);
  if (top) {
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start); else start();
  }
})();

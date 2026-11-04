// PropsCopilot Tilt Guard - runs inside the trading page itself, before the platform's own code.
// It sees each order the page tries to send (fetch, XHR or WebSocket). A new entry is held for a moment while the
// guard asks your PropsCopilot cockpit whether it may go ahead; the cockpit decides. A refused entry is never
// sent. Anything that closes, cancels or changes an order or position is never held: exits always go through.
// It also notices balance and equity figures in the platform's own data and passes them to your cockpit.
(() => {
  if (window.__pcgPage) return;
  window.__pcgPage = true;

  const ENTRY = /(\/orders?(\/|$|\?)|place-?order|placeoso|placeoco|new-?order|submit-?order|position\/open|open-?position|market-?order|pending-?order\/create|\/trade\/(buy|sell))/i;
  const NOT_ENTRY = /(cancel|close|delete|flatten|liquidat|modify|amend|replace|history|preview|validat|commission|margin|estimate|calc|quote|config|status|search|bracket|stoploss|takeprofit|sl-?tp|\/list)/i;
  const WS_ENTRY = /(placeorder|placeoso|placeoco|place_order|new_?order|open_?position|market_?order|"(?:type|action|command|method|op|event)"\s*:\s*"[^"]*(?:place|new|submit|create|open)[^"]*(?:order|position|trade)")/i;
  const WS_NOT = /(cancel|close|liquidat|modify|amend|replace|flatten)/i;
  const pend = new Map();
  let seq = 0;

  function ask(info) {
    return new Promise((resolve) => {
      const rid = "r" + (++seq) + Math.random().toString(36).slice(2, 8);
      const t = setTimeout(() => { pend.delete(rid); resolve({ allow: true, why: "", timeout: true }); }, 4000);
      pend.set(rid, (v) => { clearTimeout(t); resolve(v); });
      window.postMessage({ __pcg: "ask", rid, info }, "*");
    });
  }
  window.addEventListener("message", (e) => {
    if (e.source !== window || !e.data || e.data.__pcg !== "answer") return;
    const f = pend.get(e.data.rid);
    if (f) { pend.delete(e.data.rid); f(e.data.res || { allow: true }); }
  });

  // ------------------------------------------------------------ what an order is
  function parse(body) {
    if (body == null) return null;
    if (typeof body !== "string") {
      try {
        if (body instanceof URLSearchParams) return Object.fromEntries(body.entries());
        if (body instanceof FormData) return Object.fromEntries(body.entries());
      } catch (e) { /* not readable */ }
      return null;
    }
    try { return JSON.parse(body); } catch (e) { /* not JSON */ }
    try { if (body.includes("=")) return Object.fromEntries(new URLSearchParams(body).entries()); } catch (e) { /* no */ }
    // Tradovate-style frames: "order/placeorder\n12\n\n{...}"
    const i = body.indexOf("{");
    if (i >= 0) { try { return JSON.parse(body.slice(i)); } catch (e) { /* no */ } }
    return null;
  }

  function walk(o, fn, depth) {
    if (!o || typeof o !== "object" || depth > 6) return;
    for (const k of Object.keys(o)) {
      fn(k, o[k], o);
      if (o[k] && typeof o[k] === "object") walk(o[k], fn, depth + 1);
    }
  }

  function summarize(url, body) {
    const o = parse(body) || {};
    const info = { url: String(url).slice(0, 300), side: "", volume: 0, symbol: "", exit: false };
    walk(o, (k, v) => {
      const key = k.toLowerCase();
      if (/^(reduceonly|reduce_only|closeposition|isclose|close|positionclose)$/.test(key) && (v === true || v === "true" || v === 1)) info.exit = true;
      if (!info.side && /^(side|direction|orderside|action|buysell|type|ordertype)$/.test(key) && typeof v === "string") {
        if (/^(buy|long|bid)/i.test(v)) info.side = "buy";
        else if (/^(sell|short|ask)/i.test(v)) info.side = "sell";
      }
      if (!info.side && /^(isbuy|buy)$/.test(key) && typeof v === "boolean") info.side = v ? "buy" : "sell";
      if (!info.volume && /^(qty|quantity|volume|amount|lots|orderqty|size|units|lotsize)$/.test(key) && !isNaN(parseFloat(v))) info.volume = Math.abs(parseFloat(v));
      if (!info.symbol && /^(symbol|instrument|ticker|symbolname|contract|contractid|tradableinstrumentid|instrumentid|name)$/.test(key) &&
          (typeof v === "string" || typeof v === "number")) info.symbol = String(v).slice(0, 20);
    }, 0);
    return info;
  }

  function isEntry(method, url) {
    return method === "POST" && ENTRY.test(url) && !NOT_ENTRY.test(url);
  }

  // ------------------------------------------------------------ the platform's numbers
  const ACCT = /accounts?\/([A-Za-z0-9_-]{3,40})/i;
  let lastAcct = "";
  function noteUrl(url) {
    const m = ACCT.exec(String(url));
    if (m && m[1] !== lastAcct && !/^(state|list|info|details|config|orders?|positions?)$/i.test(m[1])) {
      lastAcct = m[1];
      window.postMessage({ __pcg: "acct", id: lastAcct }, "*");
    }
  }

  function sniff(text) {
    if (!text || text.length > 2000000 || !/balance|equity|netliq/i.test(text)) return;
    let o;
    try { o = JSON.parse(text); } catch (e) { return; }
    const found = [];
    walk(o, (k, v, parent) => {
      if (!/^(balance|cashbalance|accountbalance|netliq|netliquidatingvalue|netliquidation|equity|accountequity)$/i.test(k)) return;
      const n = typeof v === "number" ? v : parseFloat(v);
      if (!isFinite(n) || found.length > 20) return;
      const id = parent.accNum ?? parent.accountId ?? parent.accountNumber ?? parent.login ?? parent.id ?? parent.name ?? parent.account ?? "";
      let f = found.find((x) => x.id === String(id));
      if (!f) { f = { id: String(id).slice(0, 40) }; found.push(f); }
      if (/equity|netliq/i.test(k)) f.equity = n; else f.balance = n;
    }, 0);
    if (found.length) window.postMessage({ __pcg: "data", accounts: found }, "*");
  }

  function blockedResponse(why) {
    const body = JSON.stringify({ s: "error", status: "error", error: "Blocked by Tilt Guard: " + why, errmsg: "Blocked by Tilt Guard: " + why,
                                  message: "Blocked by Tilt Guard: " + why });
    return new Response(body, { status: 403, statusText: "Blocked by Tilt Guard", headers: { "Content-Type": "application/json" } });
  }

  // ------------------------------------------------------------ fetch
  const ofetch = window.fetch;
  window.fetch = async function (input, init) {
    let url = "";
    try {
      const req = input instanceof Request ? input : null;
      url = String(req ? req.url : input);
      noteUrl(url);
      const method = String((init && init.method) || (req && req.method) || "GET").toUpperCase();
      if (isEntry(method, url)) {
        let body = init && init.body;
        if (body == null && req) { try { body = await req.clone().text(); } catch (e) { /* unreadable */ } }
        const info = summarize(url, body);
        if (!info.exit) {
          const r = await ask(info);
          if (!r.allow) return blockedResponse(r.why);
        }
      }
    } catch (e) { /* never break the platform */ }
    const resp = await ofetch.apply(this, arguments);
    try {
      if ((resp.headers.get("content-type") || "").includes("json")) resp.clone().text().then(sniff, () => {});
    } catch (e) { /* ignore */ }
    return resp;
  };

  // ------------------------------------------------------------ XMLHttpRequest
  const XO = XMLHttpRequest.prototype.open, XS = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__pcg = { method: String(method || "GET").toUpperCase(), url: String(url) };
    try { noteUrl(url); } catch (e) { /* ignore */ }
    return XO.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function (body) {
    const x = this, args = arguments, m = x.__pcg || {};
    x.addEventListener("load", () => { try { if (typeof x.responseText === "string") sniff(x.responseText); } catch (e) { /* ignore */ } });
    if (!isEntry(m.method, m.url || "")) return XS.apply(x, args);
    const info = summarize(m.url, body);
    if (info.exit) return XS.apply(x, args);
    ask(info).then((r) => {
      if (r.allow) { XS.apply(x, args); return; }
      try { x.abort(); } catch (e) { /* ignore */ }
      x.dispatchEvent(new ProgressEvent("error"));
    });
  };

  // ------------------------------------------------------------ WebSocket
  const WS = window.WebSocket;
  const wsend = WS.prototype.send;
  WS.prototype.send = function (data) {
    const ws = this, args = arguments;
    if (typeof data === "string" && WS_ENTRY.test(data) && !WS_NOT.test(data)) {
      const info = summarize("ws", data);
      if (!info.exit) {
        ask(info).then((r) => { if (r.allow) wsend.apply(ws, args); });
        return;
      }
    }
    return wsend.apply(ws, args);
  };
})();

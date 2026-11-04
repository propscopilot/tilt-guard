const $ = (id) => document.getElementById(id);
const KNOWN = /(tradelocker|match-trader|tradovate|topstepx|projectx|dx\.trade|tradingview)\./;

async function load() {
  const st = await chrome.storage.local.get(["key", "sites", "tokens"]);
  $("key").value = st.key || "";
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  let url;
  try { url = new URL(tab.url); } catch (e) { return; }
  if (!/^https:$/.test(url.protocol)) return;
  const linked = Object.keys(st.tokens || {}).some((k) => k.startsWith(url.hostname + "|"));
  const guarded = KNOWN.test(url.hostname) || (st.sites || []).includes(url.origin);
  if (guarded) {
    $("site").innerHTML = `<p class="${linked ? "ok" : "no"}">${url.hostname}: ${linked ? "guarded and linked to your cockpit" :
      "guarded. It links when the platform page is open and your key is saved."}</p>`;
  } else {
    $("site").innerHTML = `<p class="m">Your firm's platform on its own web address (${url.hostname})?</p>
      <button class="alt" id="add">Guard this site</button>`;
    $("add").onclick = async () => {
      const ok = await chrome.permissions.request({ origins: [url.origin + "/*"] });
      if (!ok) return;
      await chrome.runtime.sendMessage({ type: "guard-site", origin: url.origin });
      chrome.tabs.reload(tab.id);
      window.close();
    };
  }
}

$("save").onclick = async () => {
  const k = $("key").value.trim().toUpperCase();
  if (!/^PCK-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$/.test(k)) { $("keymsg").textContent = "That doesn't look like a guard key (PCK-XXXX-XXXX-XXXX)."; return; }
  await chrome.storage.local.set({ key: k, tokens: {} });
  $("keymsg").textContent = "Saved. Open or reload your trading platform tab.";
};
load();

// PropsCopilotGuard - Tilt Guard for NinjaTrader 8 (an AddOn: it watches your accounts, not one chart)
//
// A plain client for your PropsCopilot cockpit, for futures accounts traded through NinjaTrader (Rithmic, Tradovate,
// CQG connections). It reports your accounts to propscopilot.com and does what the cockpit says: while entries are
// closed it flattens new entries and cancels working entry orders, and it flattens an account if equity reaches the
// protection line the cockpit gives it. It never opens a trade. Exits, stops and closing are NEVER blocked. All
// decisions are made by the cockpit; if it can't be reached, the last lock and protection line it gave still apply.
// A blocked add on a contract you already hold closes that whole position, not just the add.
//
// Setup (3 minutes):
//   1. Download this file from propscopilot.com/guard while signed in: your guard key is already filled in below.
//   2. Save it in  Documents\NinjaTrader 8\bin\Custom\AddOns\  then in NinjaTrader open New > NinjaScript Editor
//      and press F5 to compile. The guard starts by itself (and with NinjaTrader from then on).
//   3. Connect as usual. New > NinjaScript Output shows what the guard is doing.
// No broker password is ever asked for or sent anywhere.

#region Using declarations
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Threading;
using NinjaTrader.Cbi;
#endregion

namespace NinjaTrader.NinjaScript.AddOns
{
    public class PropsCopilotGuard : AddOnBase
    {
        // ---------------------------------------------------------------- your settings
        const string GuardKey = "PASTE-YOUR-GUARD-KEY";      // from propscopilot.com/guard (filled in when you download signed in)
        const string GuardAccounts = "";                      // empty: every account on a live connection; or "Sim101,APEX-1234"
        const string Api = "https://propscopilot.com";
        const int SyncSeconds = 5;

        const string Version = "nt8-1.00";
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        class Guarded
        {
            public Account Acc;
            public string Token = "", Label = "", EntryBlock = "", State = "calm", LastErr = "", RoomText = "";
            public double LockEnds, Score, RoomLeft = -1, FlattenAt;
            public bool Online;
            public DateTime LastOk = DateTime.MinValue;
            public readonly Dictionary<string, int> Held = new Dictionary<string, int>();   // instrument -> signed quantity
            public readonly List<string> Queue = new List<string>();
            public readonly List<string> Done = new List<string>();
            public double LastRealized;
        }

        readonly Dictionary<string, Guarded> _guarded = new Dictionary<string, Guarded>();
        readonly object _sync = new object();
        Timer _timer;
        int _tick;

        static double Now => (DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
        static string F(double v, int d = 2) => v.ToString("F" + d, Inv);
        static string Esc(string s) => (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", " ").Replace("\r", " ");

        protected override void OnStateChange()
        {
            if (State == State.SetDefaults)
            {
                Name = "PropsCopilotGuard";
                Description = "Tilt Guard: lockouts, limits and tilt protection for prop accounts. Exits are never blocked.";
            }
            else if (State == State.Active)
            {
                ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
                Account.AccountStatusUpdate += OnAccountStatus;
                lock (Account.All)
                    foreach (var a in Account.All) Attach(a);
                _timer = new Timer(_ => Tick(), null, 1000, 1000);
                Say("PropsCopilot Guard " + Version + " is watching your accounts.");
            }
            else if (State == State.Terminated)
            {
                if (_timer != null) _timer.Dispose();
                Account.AccountStatusUpdate -= OnAccountStatus;
                lock (_sync)
                    foreach (var g in _guarded.Values) Detach(g.Acc);
            }
        }

        static void Say(string msg) { NinjaTrader.Code.Output.Process("PropsCopilot Guard: " + msg, PrintTo.OutputTab1); }

        bool Wanted(Account a)
        {
            if (a == null || a.Name.StartsWith("Backtest", StringComparison.OrdinalIgnoreCase) ||
                a.Name.StartsWith("Playback", StringComparison.OrdinalIgnoreCase)) return false;
            if (GuardAccounts.Trim() != "")
                return GuardAccounts.Split(',').Any(x => x.Trim().Equals(a.Name, StringComparison.OrdinalIgnoreCase));
            return a.Provider != Provider.Simulator;
        }

        void OnAccountStatus(object sender, AccountStatusEventArgs e)
        {
            if (e.Status == ConnectionStatus.Connected) Attach(e.Account);
        }

        void Attach(Account a)
        {
            if (!Wanted(a)) return;
            lock (_sync)
            {
                if (_guarded.ContainsKey(a.Name)) return;
                var g = new Guarded { Acc = a, Token = LoadToken(a.Name) };
                foreach (var p in a.Positions) g.Held[p.Instrument.FullName] = Signed(p.MarketPosition, p.Quantity);
                g.LastRealized = a.Get(AccountItem.RealizedProfitLoss, Currency.UsDollar);
                _guarded[a.Name] = g;
            }
            a.PositionUpdate += OnPositionUpdate;
            a.OrderUpdate += OnOrderUpdate;
            Say("guarding " + a.Name);
        }

        void Detach(Account a)
        {
            a.PositionUpdate -= OnPositionUpdate;
            a.OrderUpdate -= OnOrderUpdate;
        }

        static int Signed(MarketPosition mp, int qty) => mp == MarketPosition.Long ? qty : mp == MarketPosition.Short ? -qty : 0;

        // ---------------------------------------------------------------- storage (the device token per account)
        static string Folder()
        {
            var d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "PropsCopilotGuard");
            Directory.CreateDirectory(d);
            return d;
        }

        static string Safe(string s) => new string((s ?? "").Select(c => char.IsLetterOrDigit(c) ? c : '_').ToArray());

        static string LoadToken(string acc)
        {
            var f = Path.Combine(Folder(), Safe(acc) + ".token");
            return File.Exists(f) ? File.ReadAllText(f).Trim() : "";
        }

        static void SaveToken(string acc, string token) { File.WriteAllText(Path.Combine(Folder(), Safe(acc) + ".token"), token); }

        // ---------------------------------------------------------------- HTTP
        static int Post(string path, string body, string token, int timeoutMs, out string resp)
        {
            resp = "";
            try
            {
                var req = (HttpWebRequest)WebRequest.Create(Api + path);
                req.Method = "POST";
                req.ContentType = "application/json";
                req.Timeout = timeoutMs;
                req.Headers.Add("X-PC-Format", "kv");
                if (token != "") req.Headers.Add("Authorization", "Bearer " + token);
                var bytes = Encoding.UTF8.GetBytes(body);
                using (var s = req.GetRequestStream()) s.Write(bytes, 0, bytes.Length);
                using (var r = (HttpWebResponse)req.GetResponse())
                using (var rd = new StreamReader(r.GetResponseStream(), Encoding.UTF8))
                {
                    resp = rd.ReadToEnd();
                    return (int)r.StatusCode;
                }
            }
            catch (WebException e)
            {
                var r = e.Response as HttpWebResponse;
                if (r == null) return -1;
                using (var rd = new StreamReader(r.GetResponseStream(), Encoding.UTF8)) resp = rd.ReadToEnd();
                return (int)r.StatusCode;
            }
            catch (Exception) { return -1; }
        }

        static string Kv(string body, string key)
        {
            foreach (var line in (body ?? "").Split('\n'))
                if (line.StartsWith(key + "=", StringComparison.Ordinal)) return line.Substring(key.Length + 1).Trim('\r');
            return "";
        }

        static double D(string s)
        {
            double v;
            return double.TryParse(s, NumberStyles.Float, Inv, out v) ? v : 0;
        }

        static string JsonString(string json, string key)
        {
            var k = (json ?? "").IndexOf("\"" + key + "\"", StringComparison.Ordinal);
            if (k < 0) return "";
            var c = json.IndexOf(':', k);
            var q1 = json.IndexOf('"', c + 1);
            var q2 = q1 < 0 ? -1 : json.IndexOf('"', q1 + 1);
            return c < 0 || q1 < 0 || q2 < 0 ? "" : json.Substring(q1 + 1, q2 - q1 - 1);
        }

        double Equity(Account a)
        {
            var nl = a.Get(AccountItem.NetLiquidation, Currency.UsDollar);
            return nl > 0 ? nl : a.Get(AccountItem.CashValue, Currency.UsDollar) + a.Get(AccountItem.UnrealizedProfitLoss, Currency.UsDollar);
        }

        string Facts(Account a)
        {
            return ",\"company\":\"" + Esc(a.Name + " " + a.Provider) + "\",\"trade_mode\":\"" +
                   (a.Provider == Provider.Simulator ? "demo" : "real") + "\",\"balance\":" + F(a.Get(AccountItem.CashValue, Currency.UsDollar));
        }

        bool Link(Guarded g)
        {
            if (GuardKey.StartsWith("PASTE", StringComparison.Ordinal))
            { g.LastErr = "no guard key: download this file again from propscopilot.com/guard while signed in"; return false; }
            var a = g.Acc;
            var server = a.Connection != null && a.Connection.Options != null ? a.Connection.Options.Name : a.Provider.ToString();
            var body = "{\"code\":\"" + Esc(GuardKey) + "\",\"platform\":\"ninjatrader\",\"login\":\"" + Esc(a.Name) + "\",\"server\":\"" +
                       Esc(server) + "\",\"version\":\"" + Version + "\"" + Facts(a) + "}";
            string resp;
            var code = Post("/api/guard/v1/link", body, "", 5000, out resp);
            if (code != 200) { g.LastErr = code > 0 ? JsonString(resp, "error") : "no connection"; return false; }
            g.Token = JsonString(resp, "token");
            if (g.Token.Length < 10) { g.LastErr = "link failed"; return false; }
            SaveToken(a.Name, g.Token);
            Say(a.Name + " is linked to your cockpit");
            return true;
        }

        // ---------------------------------------------------------------- every second
        void Tick()
        {
            List<Guarded> all;
            lock (_sync) all = _guarded.Values.ToList();
            _tick++;
            foreach (var g in all)
            {
                try
                {
                    CloseEvents(g);
                    CheckLines(g);
                    if (_tick % Math.Max(2, SyncSeconds) == 0) Sync(g);
                }
                catch (Exception e) { Say(g.Acc.Name + ": " + e.Message); }
            }
        }

        string LocalBlock(Guarded g)
        {
            if (g.LockEnds > Now)
                return "locked until " + new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(g.LockEnds).ToString("HH:mm", Inv) + " UTC";
            if (g.EntryBlock != "" && (DateTime.UtcNow - g.LastOk).TotalSeconds < 120) return g.EntryBlock;
            return "";
        }

        // a closed trade shows up as a change in realised P&L: reported to your cockpit
        void CloseEvents(Guarded g)
        {
            var realized = g.Acc.Get(AccountItem.RealizedProfitLoss, Currency.UsDollar);
            var diff = realized - g.LastRealized;
            if (Math.Abs(diff) < 0.005) return;
            g.LastRealized = realized;
            lock (g.Queue)
                g.Queue.Add("{\"id\":\"c-" + Safe(g.Acc.Name) + "-" + F(Now, 0) + "-" + F(Math.Abs(diff), 0) + "\",\"t\":" + F(Now, 0) +
                            ",\"kind\":\"close\",\"pnl\":" + F(diff) + "}");
        }

        void CheckLines(Guarded g)
        {
            var a = g.Acc;
            if (LocalBlock(g) != "") CancelEntries(a);
            if (g.FlattenAt > 0 && a.Positions.Any(p => p.MarketPosition != MarketPosition.Flat) && Equity(a) <= g.FlattenAt)
                Flatten(g, "equity reached your protection line");
        }

        static bool IsEntryOrder(Order o)
        {
            var n = (o.Name ?? "").ToLowerInvariant();
            if (n.Contains("stop") || n.Contains("target") || n.Contains("profit") || n.Contains("close") || n.Contains("exit")) return false;
            return o.OrderState == OrderState.Working || o.OrderState == OrderState.Accepted || o.OrderState == OrderState.Submitted;
        }

        void CancelEntries(Account a)
        {
            var cancel = a.Orders.Where(o => IsEntryOrder(o) && !Reduces(a, o)).ToList();
            if (cancel.Count > 0) a.Cancel(cancel);
        }

        // an order that only makes an open position smaller is an exit, never blocked
        static bool Reduces(Account a, Order o)
        {
            var p = a.Positions.FirstOrDefault(x => x.Instrument == o.Instrument);
            if (p == null || p.MarketPosition == MarketPosition.Flat) return false;
            var sells = o.OrderAction == OrderAction.Sell || o.OrderAction == OrderAction.SellShort;
            return (p.MarketPosition == MarketPosition.Long && sells && o.Quantity <= p.Quantity) ||
                   (p.MarketPosition == MarketPosition.Short && !sells && o.Quantity <= p.Quantity);
        }

        void Flatten(Guarded g, string why)
        {
            var a = g.Acc;
            var ins = a.Positions.Where(p => p.MarketPosition != MarketPosition.Flat).Select(p => p.Instrument).ToList();
            var working = a.Orders.Where(o => o.OrderState == OrderState.Working || o.OrderState == OrderState.Accepted).ToList();
            if (working.Count > 0) a.Cancel(working);
            if (ins.Count > 0) a.Flatten(ins);
            lock (g.Queue)
                g.Queue.Add("{\"id\":\"f-" + Safe(a.Name) + "-" + F(Now, 0) + "\",\"t\":" + F(Now, 0) + ",\"kind\":\"flatten\",\"reason\":\"" + Esc(why) + "\"}");
            Say(a.Name + " flattened (" + why + ")");
        }

        // ---------------------------------------------------------------- entries
        void OnOrderUpdate(object sender, OrderEventArgs e)
        {
            var a = sender as Account;
            Guarded g;
            if (a == null) return;
            lock (_sync) if (!_guarded.TryGetValue(a.Name, out g)) return;
            if (e.OrderState != OrderState.Working && e.OrderState != OrderState.Accepted) return;
            var why = LocalBlock(g);
            if (why != "" && IsEntryOrder(e.Order) && !Reduces(a, e.Order))
            {
                a.Cancel(new[] { e.Order });
                Say(a.Name + ": entry order cancelled: " + why);
            }
        }

        void OnPositionUpdate(object sender, PositionEventArgs e)
        {
            var a = sender as Account;
            Guarded g;
            if (a == null) return;
            lock (_sync) if (!_guarded.TryGetValue(a.Name, out g)) return;
            var key = e.Position.Instrument.FullName;
            var now = Signed(e.MarketPosition, e.Quantity);
            int before;
            lock (g.Held) { g.Held.TryGetValue(key, out before); g.Held[key] = now; }
            var grew = Math.Abs(now) > Math.Abs(before) && (before == 0 || Math.Sign(now) == Math.Sign(before));
            var flipped = before != 0 && now != 0 && Math.Sign(now) != Math.Sign(before);
            if (!grew && !flipped) return;                      // a smaller position is an exit: always fine
            var added = flipped ? Math.Abs(now) : Math.Abs(now) - Math.Abs(before);
            ThreadPool.QueueUserWorkItem(_ => Judge(g, e.Position.Instrument, key, now > 0 ? "buy" : "sell", added));
        }

        void Judge(Guarded g, Instrument instrument, string key, string side, int added)
        {
            var a = g.Acc;
            var why = LocalBlock(g);
            if (why == "" && g.Token != "")
            {
                var opens = string.Join(",", a.Positions.Where(p => p.MarketPosition != MarketPosition.Flat && p.Instrument.FullName != key).Select(p =>
                    "{\"symbol\":\"" + Esc(p.Instrument.FullName) + "\",\"side\":\"" + (p.MarketPosition == MarketPosition.Long ? "buy" : "sell") +
                    "\",\"volume\":" + p.Quantity + ",\"profit\":" + F(p.GetUnrealizedProfitLoss(PerformanceUnit.Currency)) + "}"));
                var own = a.Positions.FirstOrDefault(p => p.Instrument.FullName == key);
                var ownProfit = own != null ? own.GetUnrealizedProfitLoss(PerformanceUnit.Currency) : 0;
                if (own != null && Math.Abs(own.Quantity) > added)             // adding to a position: the earlier part counts too
                    opens = (opens == "" ? "" : opens + ",") + "{\"symbol\":\"" + Esc(key) + "\",\"side\":\"" + side +
                            "\",\"volume\":" + (own.Quantity - added) + ",\"profit\":" + F(ownProfit) + "}";
                var body = "{\"id\":\"" + Safe(a.Name) + "-" + Safe(key) + "-" + F(Now, 0) + "\",\"symbol\":\"" + Esc(key) + "\",\"side\":\"" + side +
                           "\",\"volume\":" + added + ",\"stop_grace\":true,\"equity\":" + F(Equity(a)) + ",\"balance\":" +
                           F(a.Get(AccountItem.CashValue, Currency.UsDollar)) + ",\"open_positions\":[" + opens + "]}";
                string resp;
                var code = Post("/api/guard/v1/check", body, g.Token, 3000, out resp);
                if (code == 200)
                {
                    if (Kv(resp, "allow") == "0") why = Kv(resp, "why");
                    g.Score = D(Kv(resp, "score"));
                    g.State = Kv(resp, "state");
                    var until = D(Kv(resp, "until"));
                    if (why != "" && until > g.LockEnds) g.LockEnds = until;
                }
                else Say(a.Name + ": couldn't reach the server about this entry; your last locks still apply");
            }
            if (why == "") return;
            a.Flatten(new[] { instrument });
            Say(a.Name + " blocked " + key + ": " + why);
            NinjaTrader.NinjaScript.NinjaScript.Log("PropsCopilot Guard blocked " + key + " on " + a.Name + ": " + why, LogLevel.Alert);
        }

        // ---------------------------------------------------------------- check in with the cockpit
        void Sync(Guarded g)
        {
            var a = g.Acc;
            if (g.Token == "" && !Link(g)) { g.Online = false; return; }
            List<string> batch;
            lock (g.Queue) batch = g.Queue.Take(100).ToList();
            var openCount = a.Positions.Count(p => p.MarketPosition != MarketPosition.Flat);
            var body = "{\"engine\":\"server\",\"login\":\"" + Esc(a.Name) + "\",\"equity\":" + F(Equity(a)) + ",\"algo\":true,\"version\":\"" +
                       Version + "\",\"open_count\":" + openCount + ",\"done_commands\":[" + string.Join(",", g.Done) + "],\"events\":[" +
                       string.Join(",", batch) + "]" + Facts(a) + "}";
            string resp;
            var code = Post("/api/guard/v1/sync", body, g.Token, 5000, out resp);
            if (code == 200 && resp.Contains("ok=1"))
            {
                lock (g.Queue) g.Queue.RemoveRange(0, Math.Min(batch.Count, g.Queue.Count));
                g.Done.Clear();
                Apply(g, resp);
                if (!g.Online) Say(a.Name + " online");
                g.Online = true; g.LastOk = DateTime.UtcNow; g.LastErr = "";
            }
            else
            {
                if (g.Online) Say(a.Name + " offline: obeying the last locks");
                g.Online = false;
                if (code == 401) { g.Token = ""; SaveToken(a.Name, ""); g.LastErr = "unlinked"; }
            }
        }

        void Apply(Guarded g, string body)
        {
            var was = g.LockEnds;
            foreach (var raw in body.Split('\n'))
            {
                var line = raw.Trim('\r');
                var i = line.IndexOf('=');
                if (i <= 0) continue;
                var k = line.Substring(0, i);
                var v = line.Substring(i + 1);
                switch (k)
                {
                    case "label": g.Label = v; break;
                    case "entry_block": g.EntryBlock = v; break;
                    case "lock_until": g.LockEnds = D(v); break;
                    case "flatten_at": g.FlattenAt = D(v); break;
                    case "score": g.Score = D(v); break;
                    case "state": g.State = v; break;
                    case "room_left": g.RoomLeft = D(v); break;
                    case "room_text": g.RoomText = v; break;
                    case "cmd":
                        var c = v.Split('|');
                        if (c.Length >= 2 && c[1] == "flatten") { Flatten(g, "flatten from your cockpit"); g.Done.Add(c[0]); }
                        break;
                }
            }
            if (g.LockEnds > Now && was <= Now)
                Say(g.Acc.Name + " LOCKED until " + new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(g.LockEnds).ToString("HH:mm", Inv) + " UTC");
        }
    }
}

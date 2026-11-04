// PropsCopilotGuard - Tilt Guard for cTrader
//
// A plain client for your PropsCopilot cockpit. Runs as a cBot on ONE chart and reports the whole account to
// propscopilot.com, then does what the cockpit says: while entries are closed it closes new positions and removes
// pending entries, and it closes everything if equity reaches the protection line the cockpit gives it. It never opens
// a trade. Exits, stops and closing are NEVER blocked. All decisions are made by the cockpit; if it can't be reached,
// the last lock and protection line it gave still apply.
//
// Setup (2 minutes):
//   1. Double-click PropsCopilotGuard.algo (or Automate > cBots > Import) to add it to cTrader.
//   2. Add an instance on any chart, paste your guard key from propscopilot.com/guard into "Guard key", press Start.
//   3. Keep it running. The panel bottom-left shows the guard.
// No broker password is ever asked for or sent anywhere. Network access only to propscopilot.com.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using cAlgo.API;
using cAlgo.API.Internals;

namespace cAlgo.Robots
{
    [Robot(AccessRights = AccessRights.None, TimeZone = TimeZones.UTC)]
    public class PropsCopilotGuard : Robot
    {
        [Parameter("Guard key", DefaultValue = "")]
        public string Key { get; set; }

        [Parameter("Server (leave as is)", DefaultValue = "https://propscopilot.com")]
        public string Api { get; set; }

        [Parameter("Check in every (seconds)", DefaultValue = 5, MinValue = 2, MaxValue = 60)]
        public int SyncSeconds { get; set; }

        const string Version = "ctr-1.00";
        static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

        string _token = "", _label = "", _roomText = "", _lastErr = "", _entryBlock = "", _state = "calm";
        bool _online;
        DateTime _lastOk = DateTime.MinValue;
        double _roomLeft = -1, _score, _lockEnds, _flattenAt;
        int _stopWithin;
        int _tick;
        readonly List<string> _queue = new List<string>();
        readonly List<string> _done = new List<string>();
        readonly Dictionary<int, DateTime> _stopCheck = new Dictionary<int, DateTime>();
        readonly HashSet<int> _judged = new HashSet<int>();
        readonly List<string> _barsReq = new List<string>();          // "id|symbol|from|to": prices the cockpit asked for

        StackPanel _panel;
        TextBlock _t1, _t2, _t3, _t4, _t5, _t6;

        string TokenKey => "pcguard_token_" + Account.Number;
        string LockKey => "pcguard_locks_" + Account.Number;
        static double Now => (DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
        static string F(double v, int d = 2) => v.ToString("F" + d, Inv);

        protected override void OnStart()
        {
            _token = LocalStorage.GetString(TokenKey, LocalStorageScope.Device) ?? "";
            double.TryParse(LocalStorage.GetString(LockKey, LocalStorageScope.Device) ?? "0", NumberStyles.Float, Inv, out _lockEnds);
            foreach (var p in Positions) _judged.Add(p.Id);        // trades already open aren't judged again
            Positions.Opened += OnPositionOpened;
            Positions.Closed += OnPositionClosed;
            PendingOrders.Created += OnPendingCreated;
            BuildPanel();
            Sync();
            DrawPanel();
            Timer.Start(TimeSpan.FromSeconds(1));
        }

        protected override void OnStop()
        {
            Print("PropsCopilot Guard stopped. Your locks stay on the server and apply when it runs again.");
        }

        protected override void OnTimer()
        {
            _tick++;
            CheckLines();
            if (_tick % Math.Max(2, SyncSeconds) == 0) Sync();
            DrawPanel();
        }

        // ------------------------------------------------------------ helpers
        static string Esc(string s) => (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", " ").Replace("\r", " ");

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
            var k = json.IndexOf("\"" + key + "\"", StringComparison.Ordinal);
            if (k < 0) return "";
            var c = json.IndexOf(':', k);
            var q1 = json.IndexOf('"', c + 1);
            var q2 = q1 < 0 ? -1 : json.IndexOf('"', q1 + 1);
            return c < 0 || q1 < 0 || q2 < 0 ? "" : json.Substring(q1 + 1, q2 - q1 - 1);
        }

        HttpResponse Post(string path, string body, bool auth)
        {
            var req = new HttpRequest(new Uri(Api.TrimEnd('/') + path)) { Method = HttpMethod.Post, Body = body };
            req.Headers.Add("Content-Type", "application/json");
            req.Headers.Add("X-PC-Format", "kv");
            if (auth) req.Headers.Add("Authorization", "Bearer " + _token);
            return Http.Send(req);
        }

        string LocalBlock()
        {
            if (_lockEnds > Now) return "locked until " + new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(_lockEnds).ToString("HH:mm", Inv) + " UTC";
            if (_entryBlock != "" && (DateTime.UtcNow - _lastOk).TotalSeconds < 120) return _entryBlock;
            return "";
        }

        string Facts()
        {
            double first = 0;
            return ",\"company\":\"" + Esc(Account.BrokerName) + "\",\"trade_mode\":\"" + (Account.IsLive ? "real" : "demo") +
                   "\",\"first_deposit\":" + F(first) + ",\"balance\":" + F(Account.Balance);
        }

        // ------------------------------------------------------------ link and check in
        bool Link()
        {
            if ((Key ?? "").Trim().Length < 6) { _lastErr = "Paste your guard key from propscopilot.com/guard into the cBot's parameters"; return false; }
            var body = "{\"code\":\"" + Esc(Key.Trim()) + "\",\"platform\":\"ctrader\",\"login\":\"" + Account.Number + "\",\"server\":\"" +
                       Esc(Account.BrokerName) + "\",\"version\":\"" + Version + "\"" + Facts() + "}";
            var r = Post("/api/guard/v1/link", body, false);
            if (r.StatusCode != 200) { _lastErr = r.StatusCode > 0 ? JsonString(r.Body ?? "", "error") : "no connection"; return false; }
            _token = JsonString(r.Body ?? "", "token");
            if (_token.Length < 10) { _lastErr = "link failed"; return false; }
            LocalStorage.SetString(TokenKey, _token, LocalStorageScope.Device);
            LocalStorage.Flush(LocalStorageScope.Device);
            Print("PropsCopilot Guard: linked to your cockpit");
            return true;
        }

        void Sync()
        {
            if (_token == "" && !Link()) { _online = false; return; }
            var batch = _queue.Take(100).ToList();
            var body = new StringBuilder();
            body.Append("{\"engine\":\"server\",\"login\":\"").Append(Account.Number).Append("\",\"server\":\"").Append(Esc(Account.BrokerName))
                .Append("\",\"equity\":").Append(F(Account.Equity)).Append(",\"server_offset_s\":0,\"algo\":true,\"version\":\"").Append(Version)
                .Append("\",\"open_count\":").Append(Positions.Count).Append(",\"done_commands\":[").Append(string.Join(",", _done))
                .Append("],\"events\":[").Append(string.Join(",", batch)).Append("],\"bars\":[").Append(BarsJson()).Append("]")
                .Append(Facts()).Append("}");
            HttpResponse r;
            try { r = Post("/api/guard/v1/sync", body.ToString(), true); }
            catch (Exception e) { _online = false; _lastErr = "no connection: " + e.Message; return; }
            if (r.StatusCode == 200 && (r.Body ?? "").Contains("ok=1"))
            {
                _queue.RemoveRange(0, batch.Count);
                _done.Clear();
                Apply(r.Body);
                _online = true; _lastOk = DateTime.UtcNow; _lastErr = "";
            }
            else
            {
                _online = false;
                if (r.StatusCode == 401) { _token = ""; LocalStorage.SetString(TokenKey, "", LocalStorageScope.Device); _lastErr = "unlinked: check your guard key"; }
                else if (r.StatusCode > 0) _lastErr = "server said " + r.StatusCode;
                else _lastErr = "no connection";
            }
        }

        string BarsJson()
        {
            var items = new List<string>();
            var epoch = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc);
            foreach (var req in _barsReq)
            {
                var p = req.Split('|');
                if (p.Length < 4) continue;
                var sym = Symbols.GetSymbol(p[1]);
                DateTime from = epoch.AddSeconds(D(p[2])), to = epoch.AddSeconds(D(p[3]));
                Bars bars = sym == null ? null : MarketData.GetBars(TimeFrame.Minute, p[1]);
                var rows = bars == null ? new List<Bar>() : bars.Where(b => b.OpenTime >= from && b.OpenTime <= to).ToList();
                if (rows.Count == 0 || sym.PipSize <= 0) { items.Add("{\"id\":\"" + Esc(p[0]) + "\",\"none\":true}"); continue; }
                var lotValue = sym.PipValue / sym.PipSize * sym.LotSize;
                items.Add("{\"id\":\"" + Esc(p[0]) + "\",\"lot_value\":" + F(lotValue, 4) +
                          ",\"h\":[" + string.Join(",", rows.Select(b => F(b.High, 6))) + "],\"l\":[" +
                          string.Join(",", rows.Select(b => F(b.Low, 6))) + "],\"c\":[" + string.Join(",", rows.Select(b => F(b.Close, 6))) + "]}");
            }
            return string.Join(",", items);
        }

        void Apply(string body)
        {
            _barsReq.Clear();
            foreach (var raw in body.Split('\n'))
            {
                var line = raw.Trim('\r');
                var e = line.IndexOf('=');
                if (e <= 0) continue;
                var k = line.Substring(0, e);
                var v = line.Substring(e + 1);
                switch (k)
                {
                    case "label": _label = v; break;
                    case "entry_block": _entryBlock = v; break;
                    case "lock_until": _lockEnds = D(v); break;
                    case "flatten_at": _flattenAt = D(v); break;
                    case "stop_within": _stopWithin = (int)D(v); break;
                    case "score": _score = D(v); break;
                    case "state": _state = v; break;
                    case "room_left": _roomLeft = D(v); break;
                    case "room_text": _roomText = v; break;
                    case "bars": if (_barsReq.Count < 5) _barsReq.Add(v); break;
                    case "cmd":
                        var c = v.Split('|');
                        if (c.Length >= 2 && c[1] == "flatten") { Flatten("flatten from your cockpit"); _done.Add(c[0]); }
                        break;
                }
            }
            LocalStorage.SetString(LockKey, F(_lockEnds, 0), LocalStorageScope.Device);
        }

        // ------------------------------------------------------------ entries and exits
        void OnPositionOpened(PositionOpenedEventArgs args)
        {
            var pos = args.Position;
            if (!_judged.Add(pos.Id)) return;
            var why = LocalBlock();
            if (why == "" && _token != "")
            {
                double risk = -1;
                if (pos.StopLoss.HasValue)
                {
                    var sym = Symbols.GetSymbol(pos.SymbolName);
                    if (sym != null && sym.PipSize > 0)
                        risk = Math.Abs(pos.EntryPrice - pos.StopLoss.Value) / sym.PipSize * sym.PipValue * pos.VolumeInUnits;
                }
                var opens = string.Join(",", Positions.Where(x => x.Id != pos.Id).Select(x =>
                    "{\"symbol\":\"" + Esc(x.SymbolName) + "\",\"side\":\"" + (x.TradeType == TradeType.Buy ? "buy" : "sell") +
                    "\",\"volume\":" + F(x.Quantity) + ",\"profit\":" + F(x.NetProfit) + "}"));
                var body = "{\"id\":\"" + Account.Number + "-" + pos.Id + "\",\"symbol\":\"" + Esc(pos.SymbolName) + "\",\"side\":\"" +
                           (pos.TradeType == TradeType.Buy ? "buy" : "sell") + "\",\"volume\":" + F(pos.Quantity) + ",\"price\":" +
                           F(pos.EntryPrice, 6) + ",\"sl\":" + F(pos.StopLoss ?? 0, 6) +
                           (risk >= 0 ? ",\"sl_risk\":" + F(risk) : ",\"stop_grace\":true") + ",\"equity\":" + F(Account.Equity) +
                           ",\"balance\":" + F(Account.Balance) + ",\"open_positions\":[" + opens + "]}";
                try
                {
                    var r = Post("/api/guard/v1/check", body, true);
                    if (r.StatusCode == 200)
                    {
                        if (Kv(r.Body, "allow") == "0") why = Kv(r.Body, "why");
                        _score = D(Kv(r.Body, "score"));
                        _state = Kv(r.Body, "state");
                        var until = D(Kv(r.Body, "until"));
                        if (why != "" && until > _lockEnds) _lockEnds = until;
                    }
                    else Print("PropsCopilot Guard: the server said " + r.StatusCode + " about this entry; your last locks still apply");
                }
                catch (Exception e) { Print("PropsCopilot Guard: couldn't reach the server (" + e.Message + "); your last locks still apply"); }
            }
            if (why != "")
            {
                var res = ClosePosition(pos);
                Print("PropsCopilot Guard blocked " + pos.SymbolName + ": " + why + (res.IsSuccessful ? "" : " (closing failed, retrying)"));
                _lastErr = "Blocked " + pos.SymbolName + ": " + why;
                return;
            }
            if (_stopWithin > 0 && !pos.StopLoss.HasValue) _stopCheck[pos.Id] = DateTime.UtcNow.AddSeconds(_stopWithin);
        }

        void OnPositionClosed(PositionClosedEventArgs args)
        {
            var p = args.Position;
            _stopCheck.Remove(p.Id);
            _queue.Add("{\"id\":\"c-" + p.Id + "\",\"t\":" + F(Now, 0) + ",\"kind\":\"close\",\"symbol\":\"" + Esc(p.SymbolName) +
                       "\",\"side\":\"" + (p.TradeType == TradeType.Buy ? "sell" : "buy") + "\",\"volume\":" + F(p.Quantity) +
                       ",\"pnl\":" + F(p.NetProfit) + "}");
        }

        void OnPendingCreated(PendingOrderCreatedEventArgs args)
        {
            var why = LocalBlock();
            if (why == "") return;
            CancelPendingOrder(args.PendingOrder);
            Print("PropsCopilot Guard: pending order removed: " + why);
        }

        void Flatten(string why)
        {
            foreach (var o in PendingOrders.ToList()) CancelPendingOrder(o);
            foreach (var p in Positions.ToList())
            {
                var r = ClosePosition(p);
                if (!r.IsSuccessful) Print("PropsCopilot Guard: close " + p.Id + " failed: " + r.Error + " (retrying next second)");
            }
            _queue.Add("{\"id\":\"f-" + Account.Number + "-" + F(Now, 0) + "\",\"t\":" + F(Now, 0) + ",\"kind\":\"flatten\",\"reason\":\"" + Esc(why) + "\"}");
            Print("PropsCopilot Guard: flattened (" + why + ")");
        }

        void CheckLines()
        {
            if (LocalBlock() != "")
                foreach (var o in PendingOrders.ToList()) CancelPendingOrder(o);
            foreach (var id in _stopCheck.Where(x => DateTime.UtcNow >= x.Value).Select(x => x.Key).ToList())
            {
                _stopCheck.Remove(id);
                var p = Positions.FirstOrDefault(x => x.Id == id);
                if (p != null && !p.StopLoss.HasValue)
                {
                    ClosePosition(p);
                    Print("PropsCopilot Guard closed " + p.SymbolName + ": no stop loss after " + _stopWithin + " s");
                }
            }
            if (Positions.Count > 0 && _flattenAt > 0 && Account.Equity <= _flattenAt) Flatten("equity reached your protection line");
        }

        // ------------------------------------------------------------ the panel (bottom-left)
        TextBlock Line(int size = 12)
        {
            var t = new TextBlock { FontSize = size, FontFamily = "Consolas", ForegroundColor = Color.Silver, Margin = new Thickness(0, 1, 0, 1) };
            _panel.AddChild(t);
            return t;
        }

        void BuildPanel()
        {
            _panel = new StackPanel { Orientation = Orientation.Vertical };
            _t1 = Line(13); _t2 = Line(); _t3 = Line(); _t4 = Line(); _t5 = Line(); _t6 = Line();
            var border = new Border
            {
                HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(10, 0, 0, 30),
                Padding = new Thickness(12, 8, 12, 8), BackgroundColor = Color.FromArgb(235, 12, 12, 20), BorderColor = Color.FromArgb(255, 60, 62, 90),
                BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6), Child = _panel
            };
            Chart.AddControl(border);
        }

        void DrawPanel()
        {
            if (_panel == null) return;
            var st = (_state ?? "calm").ToUpperInvariant();
            _t1.Text = "TILT GUARD" + (_label != "" ? "  " + _label : "");
            _t1.ForegroundColor = Color.White;
            _t2.Text = _online ? "Online" : "Offline: obeying your last locks";
            _t2.ForegroundColor = _online ? Color.LimeGreen : Color.Gold;
            _t3.Text = "TILT " + F(_score, 0) + "/100  " + st;
            _t3.ForegroundColor = _state == "calm" ? Color.LimeGreen : _state == "caution" ? Color.Gold : _state == "pause" ? Color.Orange : Color.DeepPink;
            _t4.Text = _roomLeft < 0 ? "Room left: set a limit or your firm at propscopilot.com/guard"
                                     : "Room left $" + F(_roomLeft, 0) + " to " + _roomText + Distance(_roomLeft);
            _t4.ForegroundColor = Color.DeepSkyBlue;
            var why = LocalBlock();
            _t5.Text = why == "" ? "Entries open. Exits always open." : "LOCKED: " + why;
            _t5.ForegroundColor = why == "" ? Color.Silver : Color.DeepPink;
            _t6.Text = _lastErr;
            _t6.ForegroundColor = Color.Gold;
            _t6.IsVisible = _lastErr != "";
        }

        string Distance(double money)
        {
            if (money <= 0 || Symbol.PipValue <= 0) return "";
            var pips = money / (Symbol.PipValue * Symbol.LotSize);
            return " = " + F(pips, 0) + " pips on " + SymbolName + " at 1 lot";
        }
    }
}

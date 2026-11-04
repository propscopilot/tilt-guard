//+------------------------------------------------------------------+
//| PropsCopilotGuard.mq4 - Tilt Guard for MetaTrader 4              |
//|                                                                  |
//| A plain client for your PropsCopilot cockpit. It reports this   |
//| account to propscopilot.com and does what the cockpit says:      |
//| while entries are closed it closes new trades and removes        |
//| pending entries, and it closes everything if equity reaches the  |
//| protection line the cockpit gives it. It never opens a trade.    |
//| Exits, stops and closing are NEVER blocked. All decisions are    |
//| made by the cockpit; if it can't be reached, the last lock and   |
//| protection line it gave still apply.                             |
//|                                                                  |
//| Setup (2 minutes):                                               |
//|  1. Tools > Options > Expert Advisors: tick "Allow WebRequest    |
//|     for listed URL" and add https://propscopilot.com             |
//|  2. Drag this guard onto ONE chart. In Inputs, paste your guard  |
//|     key from propscopilot.com/guard. Tick "Allow live trading".  |
//|  3. Keep AutoTrading on. The panel bottom-left shows the guard.  |
//| No broker password is ever asked for or sent anywhere.           |
//+------------------------------------------------------------------+
#property copyright "PropsCopilot"
#property link      "https://propscopilot.com/guard"
#property version   "1.00"
#property description "Tilt Guard: lockouts, limits and tilt protection for prop accounts. Exits are never blocked."
#property strict

input string InpLinkCode   = "";                          // Your guard key from propscopilot.com/guard
input string InpApi        = "https://propscopilot.com";  // Server (leave as is)
input int    InpSyncSec    = 5;                           // How often to check in (seconds)

#define GUARD_VERSION "mt4-1.00"
#define MAX_KNOWN  500
#define MAX_EVENTS 300
#define MAX_STOP   64

string   g_token = "", g_label = "", g_roomText = "", g_lastErr = "", g_entryBlock = "", g_state = "calm";
int      g_login = 0;
bool     g_online = false;
datetime g_lastOk = 0;
double   g_roomLeft = -1, g_score = 0, g_lockEnds = 0, g_flattenAt = 0;
int      g_stopWithin = 0;                           // seconds to add a stop loss (0: not required)

int      g_known[MAX_KNOWN];  int g_nKnown = 0;      // open tickets already judged
int      g_histCount = -1;                           // closed orders seen so far
int      g_stopTicket[MAX_STOP]; double g_stopAt[MAX_STOP]; int g_nStop = 0;
string   g_q[MAX_EVENTS];     int g_nQ = 0;          // events (JSON) waiting to be sent
string   g_done = "";                                // command ids carried out since the last check-in
string   g_barsReq[5];        int g_nBars = 0;       // "id|symbol|from|to": prices the cockpit asked for

//------------------------------------------------------------------ small helpers
double Now() { return (double)TimeGMT(); }
string Fmt(double v) { return DoubleToString(v, 2); }

string JsonEsc(string s)
{
   string o = s;
   StringReplace(o, "\\", "\\\\");
   StringReplace(o, "\"", "\\\"");
   StringReplace(o, "\n", " ");
   StringReplace(o, "\r", " ");
   return o;
}

string JsonField(string json, string key)
{
   int k = StringFind(json, "\"" + key + "\"");
   if(k < 0) return "";
   int c = StringFind(json, ":", k);
   int q1 = StringFind(json, "\"", c + 1);
   int q2 = StringFind(json, "\"", q1 + 1);
   if(c < 0 || q1 < 0 || q2 < 0) return "";
   return StringSubstr(json, q1 + 1, q2 - q1 - 1);
}

string KvField(string body, string key)
{
   string lines[];
   int n = StringSplit(body, '\n', lines);
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], key + "=") == 0) return StringSubstr(lines[i], StringLen(key) + 1);
   return "";
}

void QueueEvent(string json)
{
   if(g_nQ >= MAX_EVENTS) { for(int i = 1; i < g_nQ; i++) g_q[i - 1] = g_q[i]; g_nQ--; }
   g_q[g_nQ++] = json;
}

string TokenFile() { return "pcguard4_" + IntegerToString(g_login) + ".token"; }
string LockFile()  { return "pcguard4_" + IntegerToString(g_login) + ".locks"; }

void LoadState()
{
   int h = FileOpen(TokenFile(), FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h != INVALID_HANDLE) { g_token = FileReadString(h); FileClose(h); }
   StringTrimLeft(g_token); StringTrimRight(g_token);
   h = FileOpen(LockFile(), FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h != INVALID_HANDLE) { g_lockEnds = StringToDouble(FileReadString(h)); FileClose(h); }
}

void SaveToken()
{
   int h = FileOpen(TokenFile(), FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   FileWriteString(h, g_token);
   FileClose(h);
}

void SaveLocks()
{
   int h = FileOpen(LockFile(), FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   FileWriteString(h, DoubleToString(g_lockEnds, 0));
   FileClose(h);
}

//------------------------------------------------------------------ HTTP
int Http(string path, string body, string &resp, bool auth, int timeoutMs)
{
   char data[], result[];
   string rh;
   int n = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(n > 0) ArrayResize(data, n - 1);
   string headers = "Content-Type: application/json\r\nX-PC-Format: kv\r\n";
   if(auth) headers += "Authorization: Bearer " + g_token + "\r\n";
   ResetLastError();
   int code = WebRequest("POST", InpApi + path, headers, timeoutMs, data, result, rh);
   if(code == -1)
   {
      int err = GetLastError();
      g_lastErr = (err == 4060 || err == 4014) ? "Allow WebRequest for " + InpApi + " in Tools > Options > Expert Advisors"
                                               : "no connection (" + IntegerToString(err) + ")";
      return -1;
   }
   resp = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   return code;
}

//------------------------------------------------------------------ what the account is (so the trader types nothing)
double FirstDeposit()
{
   for(int i = 0; i < OrdersHistoryTotal(); i++)
      if(OrderSelect(i, SELECT_BY_POS, MODE_HISTORY) && OrderType() == 6 && OrderProfit() > 0) return OrderProfit();
   return 0;
}

string AccountFacts()
{
   return ",\"company\":\"" + JsonEsc(AccountCompany()) + "\",\"trade_mode\":\"" + (IsDemo() ? "demo" : "real") +
          "\",\"first_deposit\":" + Fmt(FirstDeposit()) + ",\"balance\":" + Fmt(AccountBalance());
}

bool DoLink()
{
   if(StringLen(InpLinkCode) < 6) { g_lastErr = "Paste your guard key from propscopilot.com/guard into Inputs"; return false; }
   string body = "{\"code\":\"" + JsonEsc(InpLinkCode) + "\",\"platform\":\"mt4\",\"login\":\"" + IntegerToString(g_login) +
                 "\",\"server\":\"" + JsonEsc(AccountServer()) + "\",\"version\":\"" + GUARD_VERSION + "\"" + AccountFacts() + "}";
   string resp;
   int code = Http("/api/guard/v1/link", body, resp, false, 5000);
   if(code != 200) { if(code > 0) g_lastErr = JsonField(resp, "error"); return false; }
   g_token = JsonField(resp, "token");
   if(StringLen(g_token) < 10) { g_lastErr = "link failed"; return false; }
   SaveToken();
   Print("PropsCopilot Guard: linked to your cockpit");
   return true;
}

//------------------------------------------------------------------ the account right now
bool IsEntry(int type) { return type == OP_BUY || type == OP_SELL; }
bool IsPending(int type) { return type == OP_BUYLIMIT || type == OP_SELLLIMIT || type == OP_BUYSTOP || type == OP_SELLSTOP; }

int OpenCount()
{
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES) && IsEntry(OrderType())) n++;
   return n;
}

string OpenPositionsJson(int except)
{
   string s = "[";
   bool first = true;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES) || !IsEntry(OrderType()) || OrderTicket() == except) continue;
      if(!first) s += ",";
      first = false;
      s += "{\"symbol\":\"" + JsonEsc(OrderSymbol()) + "\",\"side\":\"" + (OrderType() == OP_BUY ? "buy" : "sell") +
           "\",\"volume\":" + DoubleToString(OrderLots(), 2) + ",\"profit\":" + Fmt(OrderProfit() + OrderSwap() + OrderCommission()) + "}";
   }
   return s + "]";
}

bool Known(int t)
{
   for(int i = 0; i < g_nKnown; i++) if(g_known[i] == t) return true;
   return false;
}

void Remember(int t)
{
   if(g_nKnown >= MAX_KNOWN) { for(int i = 1; i < g_nKnown; i++) g_known[i - 1] = g_known[i]; g_nKnown--; }
   g_known[g_nKnown++] = t;
}

// '' when entries are allowed by what we last heard (the server decides each entry when it can be reached)
string LocalBlock()
{
   double now = Now();
   if(g_lockEnds > now) return "locked until " + TimeToString((datetime)g_lockEnds, TIME_MINUTES) + " UTC";
   if(g_entryBlock != "" && now - (double)g_lastOk < 120) return g_entryBlock;
   return "";
}

//------------------------------------------------------------------ actions (exits only)
bool CloseTicket(int ticket)
{
   if(!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES) || OrderCloseTime() != 0) return true;
   RefreshRates();
   string sym = OrderSymbol();
   if(IsPending(OrderType())) return OrderDelete(ticket);
   double px = OrderType() == OP_BUY ? MarketInfo(sym, MODE_BID) : MarketInfo(sym, MODE_ASK);
   bool ok = OrderClose(ticket, OrderLots(), px, 50, clrNONE);
   if(!ok) Print("PropsCopilot Guard: close #", ticket, " failed (", GetLastError(), "), retrying next second");
   return ok;
}

void FlattenAll(string why)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) CloseTicket(OrderTicket());
   QueueEvent("{\"id\":\"f-" + IntegerToString(g_login) + "-" + IntegerToString((int)TimeGMT()) + "\",\"t\":" +
              DoubleToString(Now(), 0) + ",\"kind\":\"flatten\",\"reason\":\"" + JsonEsc(why) + "\"}");
   Print("PropsCopilot Guard: flattened (", why, ")");
}

//------------------------------------------------------------------ each new entry
double StopRisk(int ticket)
{
   if(!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES) || OrderStopLoss() <= 0) return -1;
   string sym = OrderSymbol();
   double ts = MarketInfo(sym, MODE_TICKSIZE), tv = MarketInfo(sym, MODE_TICKVALUE);
   if(ts <= 0 || tv <= 0) return -1;
   return MathAbs(OrderOpenPrice() - OrderStopLoss()) / ts * tv * OrderLots();
}

void Judge(int ticket)
{
   if(!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES)) return;
   string sym = OrderSymbol();
   string side = OrderType() == OP_BUY ? "buy" : "sell";
   double lots = OrderLots(), price = OrderOpenPrice(), sl = OrderStopLoss();
   string why = LocalBlock();
   if(why == "" && g_token != "")
   {
      double risk = StopRisk(ticket);
      string body = "{\"id\":\"" + IntegerToString(g_login) + "-" + IntegerToString(ticket) + "\",\"symbol\":\"" + JsonEsc(sym) +
                    "\",\"side\":\"" + side + "\",\"volume\":" + DoubleToString(lots, 2) + ",\"price\":" + DoubleToString(price, 6) +
                    ",\"sl\":" + DoubleToString(sl, 6) + (risk >= 0 ? ",\"sl_risk\":" + Fmt(risk) : ",\"stop_grace\":true") +
                    ",\"equity\":" + Fmt(AccountEquity()) + ",\"balance\":" + Fmt(AccountBalance()) +
                    ",\"open_positions\":" + OpenPositionsJson(ticket) + "}";
      string resp;
      int code = Http("/api/guard/v1/check", body, resp, true, 3000);
      if(code == 200)
      {
         if(KvField(resp, "allow") == "0") why = KvField(resp, "why");
         g_score = StringToDouble(KvField(resp, "score"));
         g_state = KvField(resp, "state");
         double until = StringToDouble(KvField(resp, "until"));
         if(until > g_lockEnds && why != "") { g_lockEnds = until; SaveLocks(); }
      }
      else
         Print("PropsCopilot Guard: couldn't reach the server about #", ticket, "; your last locks still apply");
   }
   if(why != "")
   {
      CloseTicket(ticket);
      Alert("PropsCopilot Guard blocked ", sym, ": ", why);
      return;
   }
   if(g_stopWithin > 0 && sl <= 0 && g_nStop < MAX_STOP) { g_stopTicket[g_nStop] = ticket; g_stopAt[g_nStop] = Now() + g_stopWithin; g_nStop++; }
}

void ScanOrders()
{
   string block = LocalBlock();
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      int t = OrderTicket(), type = OrderType();
      if(IsPending(type))
      {
         if(block != "") { OrderDelete(t); Print("PropsCopilot Guard: pending order removed: ", block); }
         continue;
      }
      if(Known(t)) continue;
      Remember(t);
      Judge(t);
      // Judge may have closed orders: start the scan again next second rather than walk a changed list
      return;
   }
}

void ScanClosed()
{
   int n = OrdersHistoryTotal();
   if(g_histCount < 0 || n < g_histCount) { g_histCount = n; return; }   // older history isn't news (or the History tab was narrowed)
   for(int i = g_histCount; i < n; i++)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY) || !IsEntry(OrderType())) continue;
      double offset = (double)(TimeCurrent() - TimeGMT());
      QueueEvent("{\"id\":\"c-" + IntegerToString(OrderTicket()) + "\",\"t\":" + DoubleToString((double)OrderCloseTime() - offset, 0) +
                 ",\"kind\":\"close\",\"symbol\":\"" + JsonEsc(OrderSymbol()) + "\",\"side\":\"" + (OrderType() == OP_BUY ? "sell" : "buy") +
                 "\",\"volume\":" + DoubleToString(OrderLots(), 2) + ",\"price\":" + DoubleToString(OrderClosePrice(), 6) +
                 ",\"pnl\":" + Fmt(OrderProfit() + OrderSwap() + OrderCommission()) + "}");
   }
   g_histCount = n;
}

//------------------------------------------------------------------ every second: the protection line and stops
void CheckLines()
{
   double eq = AccountEquity();
   if(eq > 0 && g_flattenAt > 0 && eq <= g_flattenAt && OpenCount() > 0) FlattenAll("equity reached your protection line");
   double now = Now();
   for(int i = g_nStop - 1; i >= 0; i--)
      if(now >= g_stopAt[i])
      {
         if(OrderSelect(g_stopTicket[i], SELECT_BY_TICKET, MODE_TRADES) && OrderCloseTime() == 0 && OrderStopLoss() <= 0)
         {
            CloseTicket(g_stopTicket[i]);
            Alert("PropsCopilot Guard closed ", OrderSymbol(), ": no stop loss after ", g_stopWithin, " s");
         }
         for(int j = i + 1; j < g_nStop; j++) { g_stopTicket[j - 1] = g_stopTicket[j]; g_stopAt[j - 1] = g_stopAt[j]; }
         g_nStop--;
      }
}

//------------------------------------------------------------------ check in with the cockpit
string BarsJson()
{
   string out = "";
   for(int i = 0; i < g_nBars; i++)
   {
      string p[];
      if(StringSplit(g_barsReq[i], '|', p) < 4) continue;
      string sym = p[1];
      double offset = (double)(TimeCurrent() - TimeGMT());
      datetime from = (datetime)(StringToDouble(p[2]) + offset), to = (datetime)(StringToDouble(p[3]) + offset);
      MqlRates r[];
      int n = CopyRates(sym, PERIOD_M1, from, to, r);
      double tv = MarketInfo(sym, MODE_TICKVALUE), ts = MarketInfo(sym, MODE_TICKSIZE);
      string item;
      if(n <= 0 || tv <= 0 || ts <= 0) item = "{\"id\":\"" + JsonEsc(p[0]) + "\",\"none\":true}";
      else
      {
         string h = "", l = "", c = "";
         for(int k = 0; k < n; k++)
         {
            string sep = k > 0 ? "," : "";
            h += sep + DoubleToString(r[k].high, 6); l += sep + DoubleToString(r[k].low, 6); c += sep + DoubleToString(r[k].close, 6);
         }
         item = "{\"id\":\"" + JsonEsc(p[0]) + "\",\"lot_value\":" + DoubleToString(tv / ts, 4) +
                ",\"h\":[" + h + "],\"l\":[" + l + "],\"c\":[" + c + "]}";
      }
      out += (out == "" ? "" : ",") + item;
   }
   return out;
}

void ApplyKv(string body)
{
   string lines[];
   int n = StringSplit(body, '\n', lines);
   g_nBars = 0;
   for(int i = 0; i < n; i++)
   {
      int e = StringFind(lines[i], "=");
      if(e <= 0) continue;
      string k = StringSubstr(lines[i], 0, e), v = StringSubstr(lines[i], e + 1);
      if(k == "label") g_label = v;
      else if(k == "entry_block") g_entryBlock = v;
      else if(k == "lock_until") g_lockEnds = StringToDouble(v);
      else if(k == "flatten_at") g_flattenAt = StringToDouble(v);
      else if(k == "stop_within") g_stopWithin = (int)StringToInteger(v);
      else if(k == "score") g_score = StringToDouble(v);
      else if(k == "state") g_state = v;
      else if(k == "room_left") g_roomLeft = StringToDouble(v);
      else if(k == "room_text") g_roomText = v;
      else if(k == "bars" && g_nBars < 5) g_barsReq[g_nBars++] = v;
      else if(k == "cmd")
      {
         string p[];
         if(StringSplit(v, '|', p) >= 2 && p[1] == "flatten")
         {
            FlattenAll("flatten from your cockpit");
            g_done += (g_done == "" ? "" : ",") + p[0];
         }
      }
   }
   SaveLocks();
}

void Sync()
{
   if(g_token == "") { if(!DoLink()) return; }
   int count = MathMin(g_nQ, 100);
   string ev = "[";
   for(int i = 0; i < count; i++) ev += (i > 0 ? "," : "") + g_q[i];
   ev += "]";
   bool algo = IsTradeAllowed() && TerminalInfoInteger(TERMINAL_TRADE_ALLOWED);
   string body = "{\"engine\":\"server\",\"login\":\"" + IntegerToString(g_login) + "\",\"server\":\"" + JsonEsc(AccountServer()) +
                 "\",\"currency\":\"" + AccountCurrency() + "\",\"equity\":" + Fmt(AccountEquity()) +
                 ",\"server_offset_s\":" + IntegerToString((int)(TimeCurrent() - TimeGMT())) + ",\"algo\":" + (algo ? "true" : "false") +
                 ",\"version\":\"" + GUARD_VERSION + "\",\"open_count\":" + IntegerToString(OpenCount()) +
                 ",\"done_commands\":[" + g_done + "],\"events\":" + ev + ",\"bars\":[" + BarsJson() + "]" + AccountFacts() + "}";
   string resp;
   int code = Http("/api/guard/v1/sync", body, resp, true, 5000);
   if(code == 200 && StringFind(resp, "ok=1") >= 0)
   {
      for(int i = count; i < g_nQ; i++) g_q[i - count] = g_q[i];
      g_nQ -= count;
      g_done = "";
      ApplyKv(resp);
      g_online = true; g_lastOk = TimeGMT(); g_lastErr = "";
   }
   else
   {
      g_online = false;
      if(code == 401) { g_token = ""; FileDelete(TokenFile(), FILE_COMMON); g_lastErr = "unlinked: check your guard key"; }
      else if(code > 0 && g_lastErr == "") g_lastErr = "server said " + IntegerToString(code);
   }
}

//------------------------------------------------------------------ the panel (bottom-left, clear of one-click trading)
#define HUD_X    10
#define HUD_Y    12
#define HUD_LINE 18

void Label(string name, int row, int rows, string text, color c, int size)
{
   string n = "pcg_" + name;
   if(ObjectFind(0, n) < 0)
   {
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_LOWER);
      ObjectSetInteger(0, n, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
      ObjectSetInteger(0, n, OBJPROP_XDISTANCE, HUD_X + 12);
      ObjectSetString(0, n, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, n, OBJPROP_BACK, false);
   }
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, HUD_Y + 10 + (rows - 1 - row) * HUD_LINE);
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, size);
   ObjectSetString(0, n, OBJPROP_TEXT, text == "" ? " " : text);
}

void Panel(int rows, int chars)
{
   string n = "pcg_bg";
   if(ObjectFind(0, n) < 0)
   {
      ObjectCreate(0, n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_LOWER);
      ObjectSetInteger(0, n, OBJPROP_BGCOLOR, C'12,12,20');
      ObjectSetInteger(0, n, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, n, OBJPROP_COLOR, C'60,62,90');
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, n, OBJPROP_BACK, false);
      ObjectSetInteger(0, n, OBJPROP_XDISTANCE, HUD_X);
   }
   int h = rows * HUD_LINE + 16;
   ObjectSetInteger(0, n, OBJPROP_XSIZE, MathMax(260, chars * 7 + 28));
   ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, HUD_Y + h);
}

string Distance(double money)
{
   double tv = MarketInfo(Symbol(), MODE_TICKVALUE), ts = MarketInfo(Symbol(), MODE_TICKSIZE);
   if(money <= 0 || tv <= 0 || ts <= 0) return "";
   double pts = money / (tv / ts * Point);
   if(Digits == 5 || Digits == 3) return " = " + DoubleToString(pts / 10.0, 0) + " pips on " + Symbol() + " at 1 lot";
   return " = " + DoubleToString(pts, 0) + " points on " + Symbol() + " at 1 lot";
}

void DrawHud()
{
   bool algo = IsTradeAllowed() && TerminalInfoInteger(TERMINAL_TRADE_ALLOWED);
   string st = g_state;
   StringToUpper(st);
   color sc = g_state == "calm" ? clrLimeGreen : g_state == "caution" ? clrGold : g_state == "pause" ? clrOrange : clrDeepPink;
   string t1 = "TILT GUARD" + (g_label != "" ? "  " + g_label : "");
   string t2 = algo ? (g_online ? "Online" : "Offline: obeying your last locks") : "AUTOTRADING IS OFF: nothing is enforced";
   string t3 = "TILT " + DoubleToString(g_score, 0) + "/100  " + st;
   string t4 = g_roomLeft < 0 ? "Room left: set a limit or your firm at propscopilot.com/guard" :
               "Room left $" + DoubleToString(g_roomLeft, 0) + " to " + g_roomText + Distance(g_roomLeft);
   string why = LocalBlock();
   string t5 = why == "" ? "Entries open. Exits always open." : "LOCKED: " + why;
   string t6 = g_lastErr;
   int rows = t6 == "" ? 5 : 6;
   int chars = MathMax(MathMax(StringLen(t1), StringLen(t2)), MathMax(StringLen(t4), MathMax(StringLen(t5), StringLen(t6))));
   Panel(rows, chars);
   Label("t", 0, rows, t1, clrWhite, 10);
   Label("o", 1, rows, t2, algo ? (g_online ? clrLimeGreen : clrGold) : clrRed, 9);
   Label("s", 2, rows, t3, sc, 9);
   Label("r", 3, rows, t4, clrDeepSkyBlue, 9);
   Label("l", 4, rows, t5, why == "" ? clrSilver : clrDeepPink, 9);
   if(rows == 6) Label("e", 5, rows, t6, clrGold, 9); else ObjectDelete(0, "pcg_e");
   ChartRedraw(0);
}

//------------------------------------------------------------------ lifecycle
int OnInit()
{
   g_login = AccountNumber();
   LoadState();
   g_nKnown = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)            // trades already open aren't judged again
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) Remember(OrderTicket());
   g_histCount = -1;
   ScanClosed();
   if(!IsTradeAllowed()) Alert("PropsCopilot Guard: AutoTrading is OFF - turn it on or nothing can be enforced");
   EventSetTimer(1);
   Sync();
   DrawHud();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0, "pcg_");
   Print("PropsCopilot Guard stopped (reason ", reason, "). Your locks stay on the server and apply when it runs again.");
}

void OnTimer()
{
   static int tick = 0;
   tick++;
   if(AccountNumber() != g_login) { OnDeinit(0); OnInit(); return; }
   ScanOrders();
   ScanClosed();
   CheckLines();
   int every = InpSyncSec < 2 ? 2 : InpSyncSec;
   if(tick % every == 0) Sync();
   DrawHud();
}

void OnTick() { }
//+------------------------------------------------------------------+

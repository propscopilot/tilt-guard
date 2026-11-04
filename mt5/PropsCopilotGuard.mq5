//+------------------------------------------------------------------+
//| PropsCopilotGuard.mq5 - Tilt Guard for MetaTrader 5              |
//|                                                                  |
//| A plain client for your PropsCopilot cockpit. It reports this   |
//| account to propscopilot.com and does what the cockpit says:      |
//| while entries are closed it closes new entries (or just the      |
//| added part) and removes pending entries, and it closes           |
//| everything if equity reaches the protection line the cockpit     |
//| gives it. It never opens a trade. Exits, stops and closing are   |
//| NEVER blocked. All decisions are made by the cockpit; if it      |
//| can't be reached, the last lock and protection line still apply. |
//|                                                                  |
//| Setup (2 minutes):                                               |
//|  1. Tools > Options > Expert Advisors: tick "Allow WebRequest    |
//|     for listed URL" and add https://propscopilot.com             |
//|  2. Drag this guard onto ONE chart. In Inputs, paste your guard  |
//|     key from propscopilot.com/guard. Tick "Allow Algo Trading".  |
//|  3. Keep Algo Trading on. The panel bottom-left shows the guard. |
//| No broker password is ever asked for or sent anywhere.           |
//+------------------------------------------------------------------+
#property copyright "PropsCopilot"
#property link      "https://propscopilot.com/guard"
#property version   "2.00"
#property description "Tilt Guard: a plain client for your PropsCopilot cockpit. Exits are never blocked."

#include <Trade/Trade.mqh>

input string InpLinkCode = "";                          // Your guard key from propscopilot.com/guard
input string InpApi      = "https://propscopilot.com";  // Server (leave as is)
input int    InpSyncSec  = 5;                           // How often to check in (seconds)

#define GUARD_VERSION "mt5-2.00"
#define MAX_EVENTS 300
#define MAX_STOP   64
#define MAX_BARS   5

CTrade   g_trade;
string   g_token = "", g_label = "", g_roomText = "", g_lastErr = "", g_entryBlock = "", g_state = "calm";
long     g_login = 0;
bool     g_online = false;
datetime g_lastOk = 0;
double   g_roomLeft = -1, g_score = 0, g_lockEnds = 0, g_flattenAt = 0;
int      g_stopWithin = 0;
string   g_q[MAX_EVENTS];  int g_nQ = 0;
string   g_done = "";
ulong    g_stopPos[MAX_STOP]; double g_stopAt[MAX_STOP]; int g_nStop = 0;
string   g_barsReq[MAX_BARS]; int g_nBars = 0;           // "id|symbol|from|to" the cockpit asked prices for

//------------------------------------------------------------------ small helpers
double Now() { return (double)TimeGMT(); }
string Fmt(double v) { return DoubleToString(v, 2); }

string JsonEsc(const string s)
{
   string o = s;
   StringReplace(o, "\\", "\\\\");
   StringReplace(o, "\"", "\\\"");
   StringReplace(o, "\n", " ");
   StringReplace(o, "\r", " ");
   return o;
}

string JsonField(const string json, const string key)
{
   int k = StringFind(json, "\"" + key + "\"");
   if(k < 0) return "";
   int c = StringFind(json, ":", k);
   int q1 = StringFind(json, "\"", c + 1);
   int q2 = StringFind(json, "\"", q1 + 1);
   if(c < 0 || q1 < 0 || q2 < 0) return "";
   return StringSubstr(json, q1 + 1, q2 - q1 - 1);
}

string KvField(const string body, const string key)
{
   string lines[];
   int n = StringSplit(body, '\n', lines);
   for(int i = 0; i < n; i++)
      if(StringFind(lines[i], key + "=") == 0) return StringSubstr(lines[i], StringLen(key) + 1);
   return "";
}

void QueueEvent(const string json)
{
   if(g_nQ >= MAX_EVENTS) { for(int i = 1; i < g_nQ; i++) g_q[i - 1] = g_q[i]; g_nQ--; }
   g_q[g_nQ++] = json;
}

string TokenFile() { return "pcguard_" + IntegerToString(g_login) + ".token"; }
string LockFile()  { return "pcguard_" + IntegerToString(g_login) + ".locks2"; }

void LoadState()
{
   int h = FileOpen(TokenFile(), FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h != INVALID_HANDLE) { g_token = FileReadString(h); FileClose(h); }
   StringTrimLeft(g_token); StringTrimRight(g_token);
   h = FileOpen(LockFile(), FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h != INVALID_HANDLE)
   {
      g_lockEnds = StringToDouble(FileReadString(h));
      g_flattenAt = StringToDouble(FileReadString(h));
      FileClose(h);
   }
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
   FileWriteString(h, DoubleToString(g_lockEnds, 0) + "\n" + DoubleToString(g_flattenAt, 2) + "\n");
   FileClose(h);
}

//------------------------------------------------------------------ HTTP
int Http(const string path, const string body, string &resp, const bool auth, const int timeoutMs)
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
      g_lastErr = (err == 4014) ? "Allow WebRequest for " + InpApi + " in Tools > Options > Expert Advisors"
                                : "no connection (" + IntegerToString(err) + ")";
      return -1;
   }
   resp = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   return code;
}

//------------------------------------------------------------------ what the account is (so the trader types nothing)
double g_firstDeposit = -1;
double FirstDeposit()
{
   if(g_firstDeposit >= 0) return g_firstDeposit;
   g_firstDeposit = 0;
   if(!HistorySelect(0, TimeCurrent() + 86400)) return 0;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if(HistoryDealGetInteger(d, DEAL_TYPE) == DEAL_TYPE_BALANCE && HistoryDealGetDouble(d, DEAL_PROFIT) > 0)
      { g_firstDeposit = HistoryDealGetDouble(d, DEAL_PROFIT); break; }
   }
   return g_firstDeposit;
}

string AccountFacts()
{
   long mode = AccountInfoInteger(ACCOUNT_TRADE_MODE);
   string tm = mode == ACCOUNT_TRADE_MODE_DEMO ? "demo" : mode == ACCOUNT_TRADE_MODE_CONTEST ? "contest" : "real";
   return ",\"company\":\"" + JsonEsc(AccountInfoString(ACCOUNT_COMPANY)) + "\",\"trade_mode\":\"" + tm +
          "\",\"first_deposit\":" + Fmt(FirstDeposit()) + ",\"balance\":" + Fmt(AccountInfoDouble(ACCOUNT_BALANCE));
}

bool DoLink()
{
   if(StringLen(InpLinkCode) < 6) { g_lastErr = "Paste your guard key from propscopilot.com/guard into Inputs"; return false; }
   string body = "{\"code\":\"" + JsonEsc(InpLinkCode) + "\",\"platform\":\"mt5\",\"login\":\"" + IntegerToString(g_login) +
                 "\",\"server\":\"" + JsonEsc(AccountInfoString(ACCOUNT_SERVER)) + "\",\"version\":\"" + GUARD_VERSION + "\"" +
                 AccountFacts() + "}";
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
string LocalBlock()
{
   double now = Now();
   if(g_lockEnds > now) return "locked until " + TimeToString((datetime)g_lockEnds, TIME_MINUTES) + " UTC";
   if(g_entryBlock != "" && now - (double)g_lastOk < 120) return g_entryBlock;
   return "";
}

string OpenPositionsJson(const ulong except, const double exceptVol)
{
   string s = "[";
   bool first = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      double v = PositionGetDouble(POSITION_VOLUME);
      if(t == except) v -= exceptVol;                       // the part held before this entry
      if(v <= 1e-9) continue;
      if(!first) s += ",";
      first = false;
      s += "{\"symbol\":\"" + JsonEsc(PositionGetString(POSITION_SYMBOL)) + "\",\"side\":\"" +
           (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "buy" : "sell") + "\",\"volume\":" + DoubleToString(v, 2) +
           ",\"profit\":" + Fmt(PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP)) + "}";
   }
   return s + "]";
}

//------------------------------------------------------------------ actions (exits only)
void FlattenAll(const string why)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong o = OrderGetTicket(i);
      if(o != 0) g_trade.OrderDelete(o);
   }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      g_trade.SetTypeFillingBySymbol(PositionGetString(POSITION_SYMBOL));
      if(!g_trade.PositionClose(t, 50))
         Print("PropsCopilot Guard: close #", t, " failed: ", g_trade.ResultRetcodeDescription(), " (retrying next second)");
   }
   QueueEvent("{\"id\":\"f-" + IntegerToString(g_login) + "-" + DoubleToString(Now(), 0) + "\",\"t\":" + DoubleToString(Now(), 0) +
              ",\"kind\":\"flatten\",\"reason\":\"" + JsonEsc(why) + "\"}");
   Print("PropsCopilot Guard: flattened (", why, ")");
}

bool CloseAdded(const ulong pos, const double added, const string symbol)
{
   if(!PositionSelectByTicket(pos)) return true;
   g_trade.SetTypeFillingBySymbol(symbol);
   double have = PositionGetDouble(POSITION_VOLUME);
   if(added > 0 && added < have - 1e-9) return g_trade.PositionClosePartial(pos, added, 50);
   return g_trade.PositionClose(pos, 50);
}

//------------------------------------------------------------------ each new entry: the cockpit decides
double StopRisk(const string symbol, const int dir, const double volume, const double price, const double sl)
{
   if(sl <= 0) return -1;
   double p = 0;
   if(!OrderCalcProfit(dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, symbol, volume, price, sl, p)) return -1;
   return MathAbs(MathMin(0.0, p));
}

void Judge(const ulong deal, const ulong pos, const string sym, const int dir, const double added, const double price)
{
   double sl = 0;
   if(PositionSelectByTicket(pos)) sl = PositionGetDouble(POSITION_SL);
   string why = LocalBlock();
   if(why == "" && g_token != "")
   {
      double risk = StopRisk(sym, dir, added, price, sl);
      string body = "{\"id\":\"" + IntegerToString(g_login) + "-" + IntegerToString((long)deal) + "\",\"symbol\":\"" + JsonEsc(sym) +
                    "\",\"side\":\"" + (dir > 0 ? "buy" : "sell") + "\",\"volume\":" + DoubleToString(added, 2) +
                    ",\"price\":" + DoubleToString(price, 6) + ",\"sl\":" + DoubleToString(sl, 6) +
                    (risk >= 0 ? ",\"sl_risk\":" + Fmt(risk) : ",\"stop_grace\":true") +
                    ",\"equity\":" + Fmt(AccountInfoDouble(ACCOUNT_EQUITY)) + ",\"balance\":" + Fmt(AccountInfoDouble(ACCOUNT_BALANCE)) +
                    ",\"open_positions\":" + OpenPositionsJson(pos, added) + "}";
      string resp;
      int code = Http("/api/guard/v1/check", body, resp, true, 3000);
      if(code == 200)
      {
         if(KvField(resp, "allow") == "0") why = KvField(resp, "why");
         g_score = StringToDouble(KvField(resp, "score"));
         g_state = KvField(resp, "state");
         double until = StringToDouble(KvField(resp, "until"));
         if(why != "" && until > g_lockEnds) { g_lockEnds = until; SaveLocks(); }
      }
      else
         Print("PropsCopilot Guard: couldn't reach the cockpit about this entry; your last lock still applies");
   }
   if(why != "")
   {
      bool ok = CloseAdded(pos, added, sym);
      Alert("PropsCopilot Guard blocked ", sym, ": ", why, ok ? "" : " (closing failed - retrying)");
      return;
   }
   if(g_stopWithin > 0 && sl <= 0 && g_nStop < MAX_STOP) { g_stopPos[g_nStop] = pos; g_stopAt[g_nStop] = Now() + g_stopWithin; g_nStop++; }
}

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &req, const MqlTradeResult &res)
{
   if(trans.type == TRADE_TRANSACTION_ORDER_ADD)
   {
      ENUM_ORDER_TYPE ot = trans.order_type;
      bool pending = (ot == ORDER_TYPE_BUY_LIMIT || ot == ORDER_TYPE_SELL_LIMIT || ot == ORDER_TYPE_BUY_STOP ||
                      ot == ORDER_TYPE_SELL_STOP || ot == ORDER_TYPE_BUY_STOP_LIMIT || ot == ORDER_TYPE_SELL_STOP_LIMIT);
      string why = LocalBlock();
      if(pending && why != "" && g_trade.OrderDelete(trans.order)) Print("PropsCopilot Guard: pending order removed: ", why);
      return;
   }
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || !HistoryDealSelect(trans.deal)) return;
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   long dtype = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   if(dtype != DEAL_TYPE_BUY && dtype != DEAL_TYPE_SELL) return;
   string sym = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
   double vol = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
   double price = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   ulong pos = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   int dir = (dtype == DEAL_TYPE_BUY) ? 1 : -1;
   if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
   {
      double pnl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
                   HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
      QueueEvent("{\"id\":\"c-" + IntegerToString((long)trans.deal) + "\",\"t\":" + DoubleToString(Now(), 0) +
                 ",\"kind\":\"close\",\"symbol\":\"" + JsonEsc(sym) + "\",\"side\":\"" + (dir > 0 ? "buy" : "sell") +
                 "\",\"volume\":" + DoubleToString(vol, 2) + ",\"price\":" + DoubleToString(price, 6) + ",\"pnl\":" + Fmt(pnl) + "}");
      return;                                               // exits always pass
   }
   if(entry != DEAL_ENTRY_IN && entry != DEAL_ENTRY_INOUT) return;
   double added = vol;
   if(entry == DEAL_ENTRY_INOUT && PositionSelectByTicket(pos)) added = PositionGetDouble(POSITION_VOLUME);
   Judge(trans.deal, pos, sym, dir, added, price);
}

//------------------------------------------------------------------ every second: the protection line and stops
void CheckLines()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > 0 && g_flattenAt > 0 && eq <= g_flattenAt && PositionsTotal() > 0) FlattenAll("equity reached your protection line");
   if(LocalBlock() != "")
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong o = OrderGetTicket(i);
         if(o == 0) continue;
         ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(ot != ORDER_TYPE_BUY && ot != ORDER_TYPE_SELL) g_trade.OrderDelete(o);
      }
   double now = Now();
   for(int i = g_nStop - 1; i >= 0; i--)
      if(now >= g_stopAt[i])
      {
         if(PositionSelectByTicket(g_stopPos[i]) && PositionGetDouble(POSITION_SL) <= 0)
         {
            string sym = PositionGetString(POSITION_SYMBOL);
            g_trade.SetTypeFillingBySymbol(sym);
            g_trade.PositionClose(g_stopPos[i], 50);
            Alert("PropsCopilot Guard closed ", sym, ": no stop loss after ", g_stopWithin, " s");
         }
         for(int j = i + 1; j < g_nStop; j++) { g_stopPos[j - 1] = g_stopPos[j]; g_stopAt[j - 1] = g_stopAt[j]; }
         g_nStop--;
      }
}

//------------------------------------------------------------------ prices the cockpit asked for (the hour after a blocked entry)
string BarsJson()
{
   string out = "";
   for(int i = 0; i < g_nBars; i++)
   {
      string p[];
      if(StringSplit(g_barsReq[i], '|', p) < 4) continue;
      string sym = p[1];
      double offset = (double)(TimeTradeServer() - TimeGMT());
      datetime from = (datetime)(StringToDouble(p[2]) + offset), to = (datetime)(StringToDouble(p[3]) + offset);
      MqlRates r[];
      int n = CopyRates(sym, PERIOD_M1, from, to, r);
      string item;
      if(n <= 0) item = "{\"id\":\"" + JsonEsc(p[0]) + "\",\"none\":true}";
      else
      {
         double v = 0, px = r[0].open;
         // money for a 1.0 price move at this entry's size is worked out by the cockpit from the value of 1 lot
         if(!OrderCalcProfit(ORDER_TYPE_BUY, sym, 1.0, px, px + 1.0, v)) v = 0;
         string h = "", l = "", c = "";
         for(int k = 0; k < n; k++)
         {
            string sep = k > 0 ? "," : "";
            h += sep + DoubleToString(r[k].high, 6); l += sep + DoubleToString(r[k].low, 6); c += sep + DoubleToString(r[k].close, 6);
         }
         item = "{\"id\":\"" + JsonEsc(p[0]) + "\",\"lot_value\":" + DoubleToString(v, 4) + ",\"h\":[" + h + "],\"l\":[" + l + "],\"c\":[" + c + "]}";
      }
      out += (out == "" ? "" : ",") + item;
   }
   return out;
}

//------------------------------------------------------------------ check in with the cockpit
void ApplyKv(const string body)
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
      else if(k == "bars" && g_nBars < MAX_BARS) g_barsReq[g_nBars++] = v;
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
   if(g_token == "" && !DoLink()) { g_online = false; return; }
   int count = MathMin(g_nQ, 100);
   string ev = "[";
   for(int i = 0; i < count; i++) ev += (i > 0 ? "," : "") + g_q[i];
   ev += "]";
   bool algo = TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) && MQLInfoInteger(MQL_TRADE_ALLOWED);
   string body = "{\"engine\":\"server\",\"login\":\"" + IntegerToString(g_login) + "\",\"server\":\"" +
                 JsonEsc(AccountInfoString(ACCOUNT_SERVER)) + "\",\"currency\":\"" + AccountInfoString(ACCOUNT_CURRENCY) +
                 "\",\"equity\":" + Fmt(AccountInfoDouble(ACCOUNT_EQUITY)) +
                 ",\"server_offset_s\":" + IntegerToString((long)(TimeTradeServer() - TimeGMT())) + ",\"algo\":" + (algo ? "true" : "false") +
                 ",\"version\":\"" + GUARD_VERSION + "\",\"open_count\":" + IntegerToString(PositionsTotal()) +
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
      else if(code > 0) g_lastErr = "server said " + IntegerToString(code);
   }
}

//------------------------------------------------------------------ the panel (bottom-left, clear of one-click trading)
#define HUD_X    10
#define HUD_Y    12
#define HUD_LINE 18

void Label(const string name, const int row, const int rows, const string text, const color c, const int size = 9)
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

void Panel(const int rows, const int chars)
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

string Distance(const double money)
{
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE), ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(money <= 0 || tv <= 0 || ts <= 0) return "";
   double pts = money / (tv / ts * _Point);
   int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(dg == 5 || dg == 3) return " = " + DoubleToString(pts / 10.0, 0) + " pips on " + _Symbol + " at 1 lot";
   return " = " + DoubleToString(pts, 0) + " points on " + _Symbol + " at 1 lot";
}

void DrawHud()
{
   bool algo = TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) && MQLInfoInteger(MQL_TRADE_ALLOWED);
   string st = g_state;
   StringToUpper(st);
   color sc = g_state == "calm" ? clrLimeGreen : g_state == "caution" ? clrGold : g_state == "pause" ? clrOrange : clrDeepPink;
   string t1 = "TILT GUARD" + (g_label != "" ? "  " + g_label : "");
   string t2 = algo ? (g_online ? "Online" : "Offline: obeying your last lock") : "ALGO TRADING IS OFF: nothing is enforced";
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
   Label("o", 1, rows, t2, algo ? (g_online ? clrLimeGreen : clrGold) : clrRed);
   Label("s", 2, rows, t3, sc);
   Label("r", 3, rows, t4, clrDeepSkyBlue);
   Label("l", 4, rows, t5, why == "" ? clrSilver : clrDeepPink);
   if(rows == 6) Label("e", 5, rows, t6, clrGold); else ObjectDelete(0, "pcg_e");
   ChartRedraw(0);
}

//------------------------------------------------------------------ lifecycle
int OnInit()
{
   g_login = AccountInfoInteger(ACCOUNT_LOGIN);
   if(g_login <= 0) Print("PropsCopilot Guard: waiting for the terminal to log in");
   g_trade.SetAsyncMode(false);
   g_trade.SetDeviationInPoints(50);
   LoadState();                          // obey the last lock and protection line before the first check-in
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) Alert("PropsCopilot Guard: Algo Trading is OFF - turn it on or nothing can be enforced");
   EventSetTimer(1);
   Sync();
   DrawHud();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectsDeleteAll(0, "pcg_");
   Print("PropsCopilot Guard stopped (reason ", reason, "). Your locks stay in your cockpit and apply when it runs again.");
}

void OnTimer()
{
   static int tick = 0;
   tick++;
   if(AccountInfoInteger(ACCOUNT_LOGIN) != g_login) { OnDeinit(0); OnInit(); return; }
   CheckLines();
   int every = InpSyncSec < 2 ? 2 : InpSyncSec;
   if(tick % every == 0) Sync();
   DrawHud();
}

void OnTick() { }
//+------------------------------------------------------------------+

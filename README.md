# Tilt Guard clients

The open, readable side of [PropsCopilot Tilt Guard](https://propscopilot.com/guard): the small programs that sit in
your trading platform and connect it to your PropsCopilot cockpit.

They are plain clients. Each one:

- reports the account to propscopilot.com (balance, equity, entries, exits);
- asks your cockpit about each new entry and obeys the answer;
- closes a refused entry, removes pending entries while entries are closed, and closes everything if equity reaches the
  protection line your cockpit gives it;
- shows a small panel with what your cockpit said.

Every decision is made by your cockpit, not here. The guards never open a trade, never block an exit, a stop or a close,
and never ask for or send a broker password. The only address they contact is `https://propscopilot.com`.

| Folder | Platform | How it acts |
|---|---|---|
| `mt5/` | MetaTrader 5 (Expert Advisor) | closes a refused entry the moment it appears |
| `mt4/` | MetaTrader 4 (Expert Advisor) | closes a refused entry the moment it appears |
| `ctrader/` | cTrader (cBot) | closes a refused position the moment it appears |
| `ninjatrader/` | NinjaTrader 8 (AddOn) | flattens a refused entry the moment it appears |
| `browser/` | Chrome, Edge, Brave (extension) for TradeLocker, Match-Trader, DXtrade, Tradovate, TopstepX, TradingView | holds a new order until your cockpit answers; a refused order is never sent |

## Install

Get the ready-built files and step-by-step setup at **[propscopilot.com/guard](https://propscopilot.com/guard)**. You'll
need a PropsCopilot account for the guard key.

Built files are published with each release here too, with their SHA-256, so you can check that what you downloaded is
built from this code. The cTrader cBot is built by the workflow in `.github/workflows` against the official
cTrader.Automate package; the MetaTrader files are built in MetaEditor.

## Before you use it

Try it on a demo account first, and check your prop firm allows a risk-management tool. It is a safety net, not a
guarantee: it works only while your platform (or the browser tab) is open and connected.

## Reporting a problem

Open an issue. For anything security-related, email info@propscopilot.com instead of opening a public issue.

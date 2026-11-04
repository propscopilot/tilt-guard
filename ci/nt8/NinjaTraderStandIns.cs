// Stand-ins for the parts of the NinjaTrader 8 API the guard uses (names and shapes as documented by NinjaTrader).
using System;
using System.Collections.Generic;

namespace NinjaTrader.Cbi
{
    public enum MarketPosition { Flat, Long, Short }
    public enum OrderState { Initialized, Submitted, Accepted, TriggerPending, Working, ChangePending, ChangeSubmitted, CancelPending, CancelSubmitted, Cancelled, Rejected, PartFilled, Filled, Unknown }
    public enum OrderAction { Buy, BuyToCover, Sell, SellShort }
    public enum ConnectionStatus { Connected, Connecting, ConnectionLost, Disconnected, Disconnecting }
    public enum Provider { Simulator, Rithmic, Tradovate, Cqg, Playback, Provider }
    public enum AccountItem { CashValue, NetLiquidation, RealizedProfitLoss, UnrealizedProfitLoss }
    public enum Currency { UsDollar }
    public enum PerformanceUnit { Currency, Percent, Pips, Points, Ticks }
    public enum LogLevel { Alert, Error, Information, Warning }
    public class Instrument { public string FullName { get; set; } }
    public class Order { public string Name { get; set; } public OrderState OrderState { get; set; } public OrderAction OrderAction { get; set; } public int Quantity { get; set; } public Instrument Instrument { get; set; } }
    public class Position { public Instrument Instrument { get; set; } public MarketPosition MarketPosition { get; set; } public int Quantity { get; set; } public double GetUnrealizedProfitLoss(PerformanceUnit unit, double price = double.MinValue) => 0; }
    public class ConnectOptions { public string Name { get; set; } }
    public class Connection { public ConnectOptions Options { get; set; } }
    public class OrderEventArgs : EventArgs { public Order Order { get; set; } public OrderState OrderState { get; set; } }
    public class PositionEventArgs : EventArgs { public Position Position { get; set; } public MarketPosition MarketPosition { get; set; } public int Quantity { get; set; } }
    public class AccountStatusEventArgs : EventArgs { public Account Account { get; set; } public ConnectionStatus Status { get; set; } }
    public class Account
    {
        public static List<Account> All = new List<Account>();
        public static event EventHandler<AccountStatusEventArgs> AccountStatusUpdate;
        public string Name { get; set; }
        public Provider Provider { get; set; }
        public Connection Connection { get; set; }
        public List<Position> Positions { get; } = new List<Position>();
        public List<Order> Orders { get; } = new List<Order>();
        public event EventHandler<OrderEventArgs> OrderUpdate;
        public event EventHandler<PositionEventArgs> PositionUpdate;
        public double Get(AccountItem item, Currency currency) => 0;
        public void Cancel(IEnumerable<Order> orders) { }
        public void Flatten(ICollection<Instrument> instruments) { }
        internal void Touch() { AccountStatusUpdate?.Invoke(this, null); OrderUpdate?.Invoke(this, null); PositionUpdate?.Invoke(this, null); }
    }
}

namespace NinjaTrader.NinjaScript
{
    public enum State { SetDefaults, Configure, Active, Terminated }
    public abstract class AddOnBase
    {
        public string Name { get; set; }
        public string Description { get; set; }
        public State State { get; set; }
        protected virtual void OnStateChange() { }
    }
    public static class NinjaScript { public static void Log(string message, NinjaTrader.Cbi.LogLevel level) { } }
    public enum PrintTo { OutputTab1, OutputTab2 }
}

namespace NinjaTrader.Code
{
    public static class Output { public static void Process(string message, NinjaTrader.NinjaScript.PrintTo to) { } }
}

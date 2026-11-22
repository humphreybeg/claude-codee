//+------------------------------------------------------------------+
//|                                    MA_RSI_Divergence_EA.mq5       |
//|  Strategy:                                                        |
//|   - Trend bias from price vs MA + MA slope                        |
//|   - RSI divergence acts as a veto filter against that bias        |
//|   - Fixed lot size, SL/TP in pips, optional trailing stop         |
//+------------------------------------------------------------------+
#property copyright "Custom EA - FTMO Configuration"
#property version   "1.03"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

enum ENUM_PROP_LOSS_TYPE
{
   PROP_LOSS_STATIC,   // % of initial balance (fixed) - e.g. FTMO Standard/Normal Challenge
   PROP_LOSS_TRAILING  // % of peak equity (moves up as account grows) - e.g. Aqua Funded, FTMO 1-Step
};

enum ENUM_RESET_TIMEZONE
{
   RESET_UTC,        // Reset at 00:00 UTC - e.g. Aqua Funded
   RESET_CET_PRAGUE  // Reset at 00:00 CET/CEST (Prague time, auto DST-adjusted) - e.g. FTMO
};

//---------------------- Inputs ---------------------------------------
input group "Symbol / Pip Configuration"
input double   InpManualPipSize   = 0;               // Override pip size in price terms (e.g. 0.10 for gold). 0 = auto-detect

input group "Moving Average"
input int      InpMAPeriod        = 50;            // MA period
input ENUM_MA_METHOD InpMAMethod  = MODE_SMA;       // MA method
input ENUM_APPLIED_PRICE InpMAPrice = PRICE_CLOSE;  // MA applied price
input int      InpSlopeLookback   = 5;              // Bars back to measure MA slope

input group "Multi-Timeframe Confirmation"
input bool             InpUseHTFConfirm   = true;             // Require higher-timeframe agreement
input ENUM_TIMEFRAMES  InpHTF             = PERIOD_H4;         // Higher timeframe to confirm against
input int              InpHTFMAPeriod     = 50;                // MA period on higher timeframe
input int              InpHTFSlopeLookback= 5;                 // Slope lookback bars on higher timeframe

input group "RSI"
input int      InpRSIPeriod       = 14;             // RSI period
input ENUM_APPLIED_PRICE InpRSIPrice = PRICE_CLOSE;  // RSI applied price

input group "Divergence Detection"
input int      InpDivLookback     = 30;             // Bars to scan for swing points
input int      InpSwingStrength   = 3;               // Bars on each side to confirm a swing high/low

input group "Risk / Trade Management"
input bool     InpUseRiskBasedSizing = true;         // Size positions by account risk % instead of fixed lot
input double   InpRiskPercent     = 1.0;             // Risk per trade (% of account balance)
input double   InpLotSize         = 0.10;            // Fixed lot size (used only if risk-based sizing is off)
input int      InpStopLossPips    = 150;             // Stop loss in pips (gold-scaled default; forex majors would use ~30)
input int      InpTakeProfitPips  = 300;              // Take profit in pips (2:1 R:R at gold scale)
input bool     InpUseTrailingStop = true;             // Enable trailing stop
input int      InpTrailingPips    = 50;               // Trailing stop distance in pips (gold-scaled default)
input int      InpMagicNumber     = 20260802;          // Magic number
input int      InpMaxSpreadPips   = 35;                // Max allowed spread (pips) to enter (gold standard-account default; verify against your live spread)

input group "News Filter"
input bool     InpUseNewsFilter      = true;               // Avoid trading around high-impact news
input int      InpNewsMinutesBefore  = 30;                  // Block trading X minutes before news
input int      InpNewsMinutesAfter   = 30;                  // Block trading X minutes after news
input ENUM_CALENDAR_EVENT_IMPORTANCE InpNewsMinImportance = CALENDAR_IMPORTANCE_HIGH; // Minimum importance to block on

input group "Scalping Module (independent of main strategy)"
input bool             InpEnableScalping    = false;             // Enable the scalping module
input ENUM_TIMEFRAMES  InpScalpTimeframe    = PERIOD_M1;         // Timeframe for scalp signals
input int              InpScalpFastMA       = 5;                 // Fast EMA period
input int              InpScalpSlowMA       = 20;                // Slow EMA period
input int              InpScalpStopLossPips = 50;                 // Scalp stop loss (pips) - gold scalps typically run 50-80 pips
input int              InpScalpTakeProfitPips = 80;               // Scalp take profit (pips)
input bool             InpScalpUseTrailing  = true;               // Enable trailing stop for scalp trades
input int              InpScalpTrailingPips = 30;                  // Scalp trailing stop distance (pips)
input int              InpScalpMaxSpreadPips = 20;                 // Max spread allowed for scalp entries (verify against your live spread - tighter accounts can lower this)
input bool             InpScalpUseRiskSizing = true;               // Use risk-based sizing for scalp trades too
input double           InpScalpRiskPercent  = 0.5;                // Risk % per scalp trade
input double           InpScalpLotSize      = 0.10;               // Fixed lot (used if risk-based sizing off)
input int              InpScalpMagicNumber  = 20260803;            // Separate magic number for scalp trades

input group "Prop Firm Account Protection - Configured for FTMO"
// NOTE: these defaults match the FTMO Standard/Normal Challenge (5% daily / 10%
// STATIC overall, both % of initial balance). If you're on FTMO's 1-Step account,
// switch InpMaxLossType to PROP_LOSS_TRAILING and InpMaxOverallLossPercent to ~8
// (real limit 10% trailing) - verify current numbers on your FTMO dashboard first.
input bool     InpEnablePropProtection   = true;               // Enable circuit-breaker protection
input double   InpAccountStartingBalance = 10000;             // Account's original starting balance ($10k funded account)
input double   InpDailyLossLimitPercent  = 4.0;                 // FTMO's real limit is 5.0% of initial balance - set below it for a buffer (default: 4.0%)
input ENUM_PROP_LOSS_TYPE InpMaxLossType = PROP_LOSS_STATIC;     // FTMO Standard/Normal = STATIC (10% of initial balance, does not trail). See note above for 1-Step.
input double   InpMaxOverallLossPercent  = 8.5;                  // FTMO's real limit is 10.0% static from initial balance - set below it for a buffer (default: 8.5%)
input ENUM_RESET_TIMEZONE InpResetTimezone = RESET_CET_PRAGUE;   // FTMO resets the daily loss window at 00:00 Prague time (CET/CEST) - auto DST-adjusted, do not change
input bool     InpCloseTradesOnBreach    = true;                 // Force-close all EA positions on this symbol if a limit is breached
input bool     InpEnableFridayCloseAll   = false;                 // Force-close all EA positions before the weekend (FTMO Normal allows weekend holding by default - only enable if you want to be flat anyway)
input int      InpFridayCloseHourServer  = 20;                    // Server-time hour on Friday to close everything if the above is enabled
input bool     InpResetOverallHalt       = false;                  // Set to true once, then back to false, to manually clear an overall-loss halt

input group "RANDOM-DIRECTION BASELINE (research test copy only)"
input bool     InpRandomDirection  = false;   // true = coin-flip direction, same entry timing and exits, divergence veto off
input int      InpRandomSeed       = 1;       // Random seed (use 1, 2, 3 ...)

//---------------------- Globals ---------------------------------------
int      maHandle;
int      rsiHandle;
int      htfMaHandle;
int      scalpFastHandle;
int      scalpSlowHandle;
double   pipSize;
datetime lastBarTime = 0;
datetime lastScalpBarTime = 0;

// Prop firm protection state
double   dailyStartEquity = 0;
double   peakEquity = 0;
int      currentTradingDay = -1;
bool     dailyHalted = false;    // cleared automatically on day rollover
bool     overallHalted = false;  // NEVER auto-cleared - requires manual reset (see ResetOverallHalt input)
bool     fridayCloseDone = false;
string   gvPrefix; // unique global-variable prefix so state persists across restarts, per symbol+magic

//+------------------------------------------------------------------+
int OnInit()
{
   maHandle  = iMA(_Symbol, PERIOD_CURRENT, InpMAPeriod, 0, InpMAMethod, InpMAPrice);
   rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, InpRSIPeriod, InpRSIPrice);

   htfMaHandle = INVALID_HANDLE;
   if(InpUseHTFConfirm)
      htfMaHandle = iMA(_Symbol, InpHTF, InpHTFMAPeriod, 0, InpMAMethod, InpMAPrice);

   scalpFastHandle = INVALID_HANDLE;
   scalpSlowHandle = INVALID_HANDLE;
   if(InpEnableScalping)
   {
      scalpFastHandle = iMA(_Symbol, InpScalpTimeframe, InpScalpFastMA, 0, MODE_EMA, PRICE_CLOSE);
      scalpSlowHandle = iMA(_Symbol, InpScalpTimeframe, InpScalpSlowMA, 0, MODE_EMA, PRICE_CLOSE);
   }

   if(maHandle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE ||
      (InpUseHTFConfirm && htfMaHandle == INVALID_HANDLE) ||
      (InpEnableScalping && (scalpFastHandle == INVALID_HANDLE || scalpSlowHandle == INVALID_HANDLE)))
   {
      Print("Failed to create indicator handle(s).");
      return(INIT_FAILED);
   }

   // Pip size: forex 3/5-digit convention doesn't apply to gold, so detect it
   // explicitly. Gold's conventional "pip" is a $0.10 price move regardless
   // of how many decimals the broker quotes (2 or 3 are both common).
   if(InpManualPipSize > 0)
   {
      pipSize = InpManualPipSize;
   }
   else
   {
      string symUpper = _Symbol;
      StringToUpper(symUpper);
      bool isGold = (StringFind(symUpper, "XAU") >= 0) || (StringFind(symUpper, "GOLD") >= 0);

      if(isGold)
      {
         pipSize = 0.10;
      }
      else
      {
         int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
         pipSize = (digits == 3 || digits == 5) ? _Point * 10 : _Point;
      }
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   MathSrand(InpRandomSeed);
   if(InpRandomDirection)
      Print("*** RANDOM-DIRECTION BASELINE MODE: direction is a coin flip, divergence veto off, seed ", InpRandomSeed, ". Research only. ***");
   Print("MA_RSI_Divergence_EA FTMO v1.03 (lot-sizing fix) loaded.");
   Print("EA initialized on ", _Symbol, " | Detected pip size: ", DoubleToString(pipSize, _Digits),
         " | Point: ", DoubleToString(_Point, _Digits), " | Verify this matches your broker's actual pip convention.");

   // Prop firm protection: load persisted state so a restart (VPS reboot, recompile,
   // terminal crash) doesn't silently forget a halt or lose the true equity peak.
   gvPrefix = "PropEA_" + _Symbol + "_" + IntegerToString(InpMagicNumber) + "_";

   if(GlobalVariableCheck(gvPrefix + "PeakEquity"))
      peakEquity = GlobalVariableGet(gvPrefix + "PeakEquity");
   else
      peakEquity = MathMax(InpAccountStartingBalance, AccountInfoDouble(ACCOUNT_EQUITY));

   if(GlobalVariableCheck(gvPrefix + "DailyStartEquity"))
      dailyStartEquity = GlobalVariableGet(gvPrefix + "DailyStartEquity");

   if(GlobalVariableCheck(gvPrefix + "TradingDay"))
      currentTradingDay = (int)GlobalVariableGet(gvPrefix + "TradingDay");

   if(GlobalVariableCheck(gvPrefix + "DailyHalted"))
      dailyHalted = (GlobalVariableGet(gvPrefix + "DailyHalted") != 0);

   if(GlobalVariableCheck(gvPrefix + "OverallHalted"))
      overallHalted = (GlobalVariableGet(gvPrefix + "OverallHalted") != 0);

   if(InpResetOverallHalt && overallHalted)
   {
      overallHalted = false;
      Print("Overall-loss halt manually cleared via InpResetOverallHalt. Remember to set that input back to false.");
   }

   PersistPropState();

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(maHandle);
   IndicatorRelease(rsiHandle);
   if(htfMaHandle != INVALID_HANDLE) IndicatorRelease(htfMaHandle);
   if(scalpFastHandle != INVALID_HANDLE) IndicatorRelease(scalpFastHandle);
   if(scalpSlowHandle != INVALID_HANDLE) IndicatorRelease(scalpSlowHandle);
   Comment("");
}

//+------------------------------------------------------------------+
// Logs the outcome of a trade request so failures are visible in the
// Experts log instead of failing silently.
//+------------------------------------------------------------------+
void LogTradeResult(bool success, string action)
{
   if(success)
   {
      Print(action, " succeeded. Ticket: ", trade.ResultOrder(), " Price: ", DoubleToString(trade.ResultPrice(), _Digits));
   }
   else
   {
      Print("*** ", action, " FAILED. Retcode: ", trade.ResultRetcode(),
            " (", trade.ResultRetcodeDescription(), ") Comment: ", trade.ResultComment());
   }
}

//+------------------------------------------------------------------+
// Finds the two most recent swing points in a series array (index 0 =
// most recent bar). A swing high at index i is a bar whose high is not
// exceeded by any of the `strength` bars on either side; swing lows are
// the mirror image. recent/previous receive the two indices found, with
// recent being the more recent one. Returns false if fewer than two exist.
//+------------------------------------------------------------------+
bool FindTwoRecentSwings(const double &arr[], bool wantHigh, int total, int strength,
                         int &recent, int &previous)
{
   recent   = -1;
   previous = -1;

   for(int i = strength; i < total - strength; i++)
   {
      bool isSwing = true;
      for(int j = 1; j <= strength; j++)
      {
         if(wantHigh)
         {
            if(arr[i] < arr[i-j] || arr[i] < arr[i+j]) { isSwing = false; break; }
         }
         else
         {
            if(arr[i] > arr[i-j] || arr[i] > arr[i+j]) { isSwing = false; break; }
         }
      }
      if(!isSwing) continue;

      if(recent < 0)
         recent = i;
      else
      {
         previous = i;
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
// Bearish divergence: price makes a higher high while RSI makes a
// lower high, using the two most recent swing highs. Uses closed bars
// only (starts at shift 1) so the signal does not repaint.
//+------------------------------------------------------------------+
bool HasBearishDivergence()
{
   int total = InpDivLookback + InpSwingStrength * 2;

   double highArr[];
   double rsiArr[];
   ArraySetAsSeries(highArr, true);
   ArraySetAsSeries(rsiArr, true);

   if(CopyHigh(_Symbol, PERIOD_CURRENT, 1, total, highArr) != total) return false;
   if(CopyBuffer(rsiHandle, 0, 1, total, rsiArr) != total) return false;

   int recent, previous;
   if(!FindTwoRecentSwings(highArr, true, total, InpSwingStrength, recent, previous))
      return false;

   bool priceHigherHigh = highArr[recent] > highArr[previous];
   bool rsiLowerHigh    = rsiArr[recent]  < rsiArr[previous];

   return(priceHigherHigh && rsiLowerHigh);
}

//+------------------------------------------------------------------+
// Bullish divergence: price makes a lower low while RSI makes a
// higher low, using the two most recent swing lows. Closed bars only.
//+------------------------------------------------------------------+
bool HasBullishDivergence()
{
   int total = InpDivLookback + InpSwingStrength * 2;

   double lowArr[];
   double rsiArr[];
   ArraySetAsSeries(lowArr, true);
   ArraySetAsSeries(rsiArr, true);

   if(CopyLow(_Symbol, PERIOD_CURRENT, 1, total, lowArr) != total) return false;
   if(CopyBuffer(rsiHandle, 0, 1, total, rsiArr) != total) return false;

   int recent, previous;
   if(!FindTwoRecentSwings(lowArr, false, total, InpSwingStrength, recent, previous))
      return false;

   bool priceLowerLow = lowArr[recent] < lowArr[previous];
   bool rsiHigherLow  = rsiArr[recent] > rsiArr[previous];

   return(priceLowerLow && rsiHigherLow);
}

//+------------------------------------------------------------------+
// Determines trend bias: 1 = bullish, -1 = bearish, 0 = none
//+------------------------------------------------------------------+
int GetTrendBias()
{
   double maNow[], maPast[];
   ArraySetAsSeries(maNow, true);
   ArraySetAsSeries(maPast, true);

   // Use the last CLOSED bar's MA value (shift 1), not the still-forming bar 0,
   // so the trend read doesn't shift as the current bar's price keeps moving.
   // Live bid is still used for the price comparison itself - that's intentional,
   // since we want to react to current price against a stable MA reference.
   if(CopyBuffer(maHandle, 0, 1, 1, maNow) <= 0) return 0;
   if(CopyBuffer(maHandle, 0, 1 + InpSlopeLookback, 1, maPast) <= 0) return 0;

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double maVal = maNow[0];
   bool slopeUp   = maNow[0] > maPast[0];
   bool slopeDown = maNow[0] < maPast[0];

   if(price > maVal && slopeUp)   return 1;
   if(price < maVal && slopeDown) return -1;
   return 0;
}

//+------------------------------------------------------------------+
// Determines trend bias on the higher timeframe using the same
// price-vs-MA + slope logic. Returns 1 = bullish, -1 = bearish, 0 = none
//+------------------------------------------------------------------+
int GetHTFTrendBias()
{
   if(!InpUseHTFConfirm) return 0; // unused when confirmation is off

   double maNow[], maPast[];
   ArraySetAsSeries(maNow, true);
   ArraySetAsSeries(maPast, true);

   if(CopyBuffer(htfMaHandle, 0, 1, 1, maNow) <= 0) return 0;
   if(CopyBuffer(htfMaHandle, 0, 1 + InpHTFSlopeLookback, 1, maPast) <= 0) return 0;

   double htfPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID); // current price vs HTF MA
   bool slopeUp   = maNow[0] > maPast[0];
   bool slopeDown = maNow[0] < maPast[0];

   if(htfPrice > maNow[0] && slopeUp)   return 1;
   if(htfPrice < maNow[0] && slopeDown) return -1;
   return 0;
}

//+------------------------------------------------------------------+
// Calculates lot size so that a stop-loss hit risks InpRiskPercent%
// of the current account balance. Falls back to InpLotSize if
// risk-based sizing is off or inputs can't be resolved.
//+------------------------------------------------------------------+
double CalculateLotSize(int slPips, bool useRiskSizing, double riskPercent, double fallbackLot)
{
   if(!useRiskSizing) return fallbackLot;

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * (riskPercent / 100.0);

   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep <= 0) lotStep = 0.01;

   // Ask the platform what a stop-out of this size would cost for 1.0 lot.
   // This uses the broker's real contract specification (contract size,
   // currency conversion), so it does not depend on tick-value assumptions.
   double entry   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double slDist  = slPips * pipSize;
   double profit  = 0;
   if(!OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, 1.0, entry, entry - slDist, profit) || profit == 0)
   {
      Print("WARNING: could not calculate loss per lot (error ", GetLastError(),
            "). Using the minimum lot size for safety.");
      return minLot;
   }
   double lossPerLot = MathAbs(profit);

   double rawLots = riskMoney / lossPerLot;
   double lots = MathFloor(rawLots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));

   int lotDigits = (int)MathMax(0, MathRound(-MathLog10(lotStep)));
   lots = NormalizeDouble(lots, lotDigits);

   double actualRisk    = lots * lossPerLot;
   double actualRiskPct = (balance > 0) ? (actualRisk / balance) * 100.0 : 0;

   Print("Lot sizing: stop ", slPips, " pips (price distance ", DoubleToString(slDist, 2),
         "), loss per 1.0 lot = ", DoubleToString(lossPerLot, 2),
         " | intended risk ", DoubleToString(riskMoney, 2),
         " -> ", DoubleToString(lots, lotDigits), " lots (actual risk ~",
         DoubleToString(actualRisk, 2), ", ", DoubleToString(actualRiskPct, 2), "% of balance)");

   if(rawLots < minLot)
   {
      Print("WARNING: intended risk (", DoubleToString(riskPercent, 2),
            "%) is below what the broker's minimum lot (", DoubleToString(minLot, 2),
            ") would risk. Using minimum lot - actual risk is ~",
            DoubleToString(actualRiskPct, 2), "% of balance.");
   }

   return lots;
}

//+------------------------------------------------------------------+
// Checks MT5's built-in economic calendar for high-impact events on
// the symbol's base/quote currencies within the blackout window.
//+------------------------------------------------------------------+
bool IsNewsBlackout()
{
   if(!InpUseNewsFilter) return false;

   string base  = StringSubstr(_Symbol, 0, 3);
   string quote = StringSubstr(_Symbol, 3, 3);

   int bufferMinutes = MathMax(InpNewsMinutesBefore, InpNewsMinutesAfter) + 5;
   datetime searchFrom = TimeCurrent() - bufferMinutes * 60;
   datetime searchTo   = TimeCurrent() + bufferMinutes * 60;

   string currencies[2];
   currencies[0] = base;
   currencies[1] = quote;

   for(int c = 0; c < 2; c++)
   {
      MqlCalendarValue values[];
      int count = CalendarValueHistory(values, searchFrom, searchTo, NULL, currencies[c]);
      if(count <= 0) continue;

      for(int i = 0; i < count; i++)
      {
         MqlCalendarEvent evt;
         if(!CalendarEventById(values[i].event_id, evt)) continue;
         if(evt.importance < InpNewsMinImportance) continue;

         datetime evtTime = values[i].time;
         datetime blackoutStart = evtTime - InpNewsMinutesBefore * 60;
         datetime blackoutEnd   = evtTime + InpNewsMinutesAfter * 60;

         if(TimeCurrent() >= blackoutStart && TimeCurrent() <= blackoutEnd)
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
// Detects a fresh fast/slow EMA crossover on the scalp timeframe.
// Returns 1 = bullish cross just happened, -1 = bearish cross, 0 = none
//+------------------------------------------------------------------+
int GetScalpCrossSignal()
{
   double fastNow[], fastPrev[], slowNow[], slowPrev[];
   ArraySetAsSeries(fastNow, true);
   ArraySetAsSeries(fastPrev, true);
   ArraySetAsSeries(slowNow, true);
   ArraySetAsSeries(slowPrev, true);

   // shift 1 = last fully closed bar, shift 2 = bar before that
   if(CopyBuffer(scalpFastHandle, 0, 1, 1, fastNow) <= 0) return 0;
   if(CopyBuffer(scalpFastHandle, 0, 2, 1, fastPrev) <= 0) return 0;
   if(CopyBuffer(scalpSlowHandle, 0, 1, 1, slowNow) <= 0) return 0;
   if(CopyBuffer(scalpSlowHandle, 0, 2, 1, slowPrev) <= 0) return 0;

   bool wasBelow = fastPrev[0] <= slowPrev[0];
   bool nowAbove = fastNow[0]  >  slowNow[0];
   bool wasAbove = fastPrev[0] >= slowPrev[0];
   bool nowBelow = fastNow[0]  <  slowNow[0];

   if(wasBelow && nowAbove) return 1;   // bullish cross
   if(wasAbove && nowBelow) return -1;  // bearish cross
   return 0;
}

//+------------------------------------------------------------------+
// Independent scalping module: fast/slow EMA crossover entries with
// tight SL/TP, its own magic number, and its own trailing stop.
//+------------------------------------------------------------------+
void CheckScalpEntry()
{
   if(!InpEnableScalping) return;

   datetime currentScalpBarTime = iTime(_Symbol, InpScalpTimeframe, 0);
   if(currentScalpBarTime == lastScalpBarTime) return;
   lastScalpBarTime = currentScalpBarTime;

   if(HasOpenPosition(InpScalpMagicNumber)) return;

   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / pipSize;
   if(spread > InpScalpMaxSpreadPips) return;

   if(IsNewsBlackout()) return; // scalping is especially vulnerable to news spikes

   int signal = GetScalpCrossSignal();
   if(signal == 0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lots = CalculateLotSize(InpScalpStopLossPips, InpScalpUseRiskSizing, InpScalpRiskPercent, InpScalpLotSize);

   trade.SetExpertMagicNumber(InpScalpMagicNumber);

   if(signal == 1)
   {
      double sl = ask - InpScalpStopLossPips * pipSize;
      double tp = ask + InpScalpTakeProfitPips * pipSize;
      trade.Buy(lots, _Symbol, ask, sl, tp, "Scalp EA");
      LogTradeResult(trade.ResultRetcode() == TRADE_RETCODE_DONE, "Scalp BUY");
   }
   else if(signal == -1)
   {
      double sl = bid + InpScalpStopLossPips * pipSize;
      double tp = bid - InpScalpTakeProfitPips * pipSize;
      trade.Sell(lots, _Symbol, bid, sl, tp, "Scalp EA");
      LogTradeResult(trade.ResultRetcode() == TRADE_RETCODE_DONE, "Scalp SELL");
   }

   trade.SetExpertMagicNumber(InpMagicNumber); // restore default magic for the main strategy
}

//+------------------------------------------------------------------+
// Closes every EA-owned position on this symbol (both magic numbers).
//+------------------------------------------------------------------+
void CloseAllEAPositions(string reason)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long magic = PositionGetInteger(POSITION_MAGIC);
      if(magic != InpMagicNumber && magic != InpScalpMagicNumber) continue;

      bool closed = trade.PositionClose(ticket);
      LogTradeResult(closed, "Force-close ticket " + IntegerToString(ticket));
   }
   Print("Prop protection: closed all EA positions. Reason: ", reason);
}

//+------------------------------------------------------------------+
// Returns true if the given UTC time falls within EU summer time
// (CEST, UTC+2). EU DST runs from the last Sunday of March 01:00 UTC
// to the last Sunday of October 01:00 UTC - the same rule every year.
//+------------------------------------------------------------------+
bool IsEUSummerTime(datetime utcTime)
{
   MqlDateTime dt;
   TimeToStruct(utcTime, dt);
   int year = dt.year;

   // Find last Sunday of March for this year
   datetime marchLast = StringToTime(StringFormat("%04d.03.31 01:00:00", year));
   MqlDateTime mdt; TimeToStruct(marchLast, mdt);
   datetime dstStart = marchLast - (mdt.day_of_week) * 86400; // walk back to Sunday

   // Find last Sunday of October for this year
   datetime octLast = StringToTime(StringFormat("%04d.10.31 01:00:00", year));
   MqlDateTime odt; TimeToStruct(octLast, odt);
   datetime dstEnd = octLast - (odt.day_of_week) * 86400;

   return (utcTime >= dstStart && utcTime < dstEnd);
}

//+------------------------------------------------------------------+
// Converts true UTC time (from TimeGMT()) into the "reset clock" time
// used to determine trading-day boundaries, per InpResetTimezone.
//+------------------------------------------------------------------+
datetime GetResetClockTime()
{
   datetime utcNow = TimeGMT();

   if(InpResetTimezone == RESET_CET_PRAGUE)
   {
      int offsetHours = IsEUSummerTime(utcNow) ? 2 : 1; // CEST = UTC+2, CET = UTC+1
      return utcNow + offsetHours * 3600;
   }

   return utcNow; // RESET_UTC
}

//+------------------------------------------------------------------+
// Writes prop-protection state to MT5 global variables so it survives
// EA restarts, terminal restarts, and VPS reboots.
//+------------------------------------------------------------------+
void PersistPropState()
{
   GlobalVariableSet(gvPrefix + "PeakEquity", peakEquity);
   GlobalVariableSet(gvPrefix + "DailyStartEquity", dailyStartEquity);
   GlobalVariableSet(gvPrefix + "TradingDay", currentTradingDay);
   GlobalVariableSet(gvPrefix + "DailyHalted", dailyHalted ? 1 : 0);
   GlobalVariableSet(gvPrefix + "OverallHalted", overallHalted ? 1 : 0);
}

//+------------------------------------------------------------------+
// Tracks daily/trailing equity and halts trading if configured loss
// limits are breached. Call once per tick, before any entry logic.
// Returns true if trading should be blocked this tick.
//+------------------------------------------------------------------+
bool UpdatePropProtection()
{
   if(!InpEnablePropProtection) return false;

   datetime resetClock = GetResetClockTime();
   MqlDateTime dt;
   TimeToStruct(resetClock, dt);

   // Trading day rolls over at midnight in the reset timezone (UTC or CET/CEST).
   int adjustedDay = dt.day_of_year + dt.year * 1000; // unique across year boundaries too

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   bool stateChanged = false;

   if(adjustedDay != currentTradingDay)
   {
      currentTradingDay = adjustedDay;
      dailyStartEquity = equity;
      fridayCloseDone = false;
      if(dailyHalted)
      {
         dailyHalted = false; // a new day clears a daily-loss halt only
         Print("New trading day: daily-loss halt cleared. Overall-loss halt (if any) remains in effect.");
      }
      stateChanged = true;
   }

   if(equity > peakEquity)
   {
      peakEquity = equity;
      stateChanged = true;
   }

   // Both Aqua Funded and FTMO define the daily loss limit as a % of your
   // INITIAL balance (a fixed dollar amount), not a % of today's starting
   // equity - so the denominator here is deliberately the starting balance,
   // while the numerator still measures the drop from today's opening equity.
   double dailyLossPct = (dailyStartEquity - equity) / InpAccountStartingBalance * 100.0;

   double overallLossBasis = (InpMaxLossType == PROP_LOSS_STATIC) ? InpAccountStartingBalance : peakEquity;
   double overallLossPct = (overallLossBasis - equity) / overallLossBasis * 100.0;

   bool overallBreach = overallLossPct >= InpMaxOverallLossPercent;
   bool dailyBreach    = dailyLossPct >= InpDailyLossLimitPercent;

   if(overallBreach && !overallHalted)
   {
      overallHalted = true;
      stateChanged = true;
      string basisLabel = (InpMaxLossType == PROP_LOSS_STATIC) ? "static, from initial balance" : "trailing, from peak equity";
      Print("*** PROP PROTECTION TRIGGERED: overall loss limit reached (", basisLabel, "). Overall loss: ",
            DoubleToString(overallLossPct,2), "%. This halt persists across restarts until manually cleared.");
      if(InpCloseTradesOnBreach) CloseAllEAPositions("overall loss limit");
   }
   else if(dailyBreach && !dailyHalted)
   {
      dailyHalted = true;
      stateChanged = true;
      Print("*** PROP PROTECTION TRIGGERED: daily loss limit reached. Daily loss: ",
            DoubleToString(dailyLossPct,2), "% of initial balance. Trading resumes next trading day.");
      if(InpCloseTradesOnBreach) CloseAllEAPositions("daily loss limit");
   }

   // Optional: flatten everything ahead of the weekend (uses broker server time,
   // since this is about being flat before the market closes, not a firm rule reset)
   MqlDateTime serverDt;
   TimeToStruct(TimeTradeServer(), serverDt);
   if(InpEnableFridayCloseAll && serverDt.day_of_week == 5 && serverDt.hour >= InpFridayCloseHourServer && !fridayCloseDone)
   {
      CloseAllEAPositions("Friday weekend close");
      fridayCloseDone = true;
   }

   if(stateChanged) PersistPropState();

   bool halted = dailyHalted || overallHalted;
   string basisTag = (InpMaxLossType == PROP_LOSS_STATIC) ? "static" : "trailing";

   Comment(StringFormat(
      "Prop Protection | Daily loss: %.2f%% / %.2f%%   Overall loss (%s): %.2f%% / %.2f%%   %s",
      dailyLossPct, InpDailyLossLimitPercent, basisTag, overallLossPct, InpMaxOverallLossPercent,
      overallHalted ? "OVERALL HALT (manual reset required)" : (dailyHalted ? "DAILY HALT (resumes next day)" : "OK")));

   return halted;
}

//+------------------------------------------------------------------+
bool SpreadOK()
{
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / pipSize;
   return spread <= InpMaxSpreadPips;
}

//+------------------------------------------------------------------+
bool HasOpenPosition(int magic)
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == magic)
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
void ManageTrailingStop(int magic, bool useTrailing, int trailingPips)
{
   if(!useTrailing) return;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double trailDist = trailingPips * pipSize;

      if(type == POSITION_TYPE_BUY)
      {
         double newSL = bid - trailDist;
         if(newSL > openPrice && (curSL == 0 || newSL > curSL))
         {
            if(!trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP)))
               LogTradeResult(false, "Trail modify ticket " + IntegerToString(ticket));
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double newSL = ask + trailDist;
         if(newSL < openPrice && (curSL == 0 || newSL < curSL))
         {
            if(!trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP)))
               LogTradeResult(false, "Trail modify ticket " + IntegerToString(ticket));
         }
      }
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   bool halted = UpdatePropProtection();

   ManageTrailingStop(InpMagicNumber, InpUseTrailingStop, InpTrailingPips);
   if(!halted) CheckScalpEntry();
   ManageTrailingStop(InpScalpMagicNumber, InpScalpUseTrailing, InpScalpTrailingPips);

   if(halted) return; // no new main-strategy entries either while halted

   // Only evaluate main-strategy entries once per new bar
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   if(HasOpenPosition(InpMagicNumber)) return;
   if(!SpreadOK()) return;
   if(IsNewsBlackout()) return;

   int bias = GetTrendBias();
   if(bias == 0) return;

   if(InpUseHTFConfirm)
   {
      int htfBias = GetHTFTrendBias();
      if(htfBias == 0 || htfBias != bias) return; // HTF disagrees or is flat -> skip trade
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lots = CalculateLotSize(InpStopLossPips, InpUseRiskBasedSizing, InpRiskPercent, InpLotSize);
   trade.SetExpertMagicNumber(InpMagicNumber);

   // Baseline test: same timing (trend and HTF gates passed), same exits and sizing, random direction
   if(InpRandomDirection)
      bias = (MathRand() % 2 == 0) ? 1 : -1;

   if(bias == 1) // bullish bias -> veto if bearish divergence present
   {
      if(!InpRandomDirection && HasBearishDivergence()) return;

      double sl = ask - InpStopLossPips * pipSize;
      double tp = ask + InpTakeProfitPips * pipSize;
      trade.Buy(lots, _Symbol, ask, sl, tp, "MA+RSI Div EA");
      LogTradeResult(trade.ResultRetcode() == TRADE_RETCODE_DONE, "Main strategy BUY");
   }
   else if(bias == -1) // bearish bias -> veto if bullish divergence present
   {
      if(!InpRandomDirection && HasBullishDivergence()) return;

      double sl = bid + InpStopLossPips * pipSize;
      double tp = bid - InpTakeProfitPips * pipSize;
      trade.Sell(lots, _Symbol, bid, sl, tp, "MA+RSI Div EA");
      LogTradeResult(trade.ResultRetcode() == TRADE_RETCODE_DONE, "Main strategy SELL");
   }
}
//+------------------------------------------------------------------+

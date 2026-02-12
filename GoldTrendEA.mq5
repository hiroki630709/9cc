//+------------------------------------------------------------------+
//|                                                  GoldTrendEA.mq5 |
//|                        Gold Mean Reversion EA for Exness MT5      |
//|                        XAUUSD M15 - v5.00 Pullback Strategy       |
//+------------------------------------------------------------------+
#property copyright "GoldTrendEA"
#property version   "5.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+

//--- トレンド判定（大きな方向性のみ）
input int      TrendEMA_Period   = 200;        // トレンド判定EMA期間

//--- RSIプルバック検出
input int      RSI_Period        = 14;         // RSI期間
input double   RSI_OversoldLevel = 30.0;       // 売られすぎ水準（この以下から回復で買い）
input double   RSI_OverboughtLevel = 70.0;     // 買われすぎ水準（この以上から下落で売り）

//--- ATRベース損切り・利確
input int      ATR_Period        = 14;         // ATR期間
input double   ATR_SL_Multi     = 1.5;        // SL = ATR × この倍率（押し目なので小さめ）
input double   RR_Ratio          = 1.5;        // リスクリワード比

//--- リスク管理（段階的・複利対応）
input double   Risk_Level1       = 10.0;       // 残高3万円未満: リスク%
input double   Risk_Level2       = 5.0;        // 残高3万〜10万円: リスク%
input double   Risk_Level3       = 3.0;        // 残高10万〜30万円: リスク%
input double   Risk_Level4       = 2.0;        // 残高30万円以上: リスク%
input double   Balance_Thresh2   = 30000.0;    // レベル2閾値（円）
input double   Balance_Thresh3   = 100000.0;   // レベル3閾値（円）
input double   Balance_Thresh4   = 300000.0;   // レベル4閾値（円）

//--- ロットサイズ
input double   MinLot            = 0.01;       // 最小ロット
input double   MaxLot            = 10.0;       // 最大ロット

//--- ブレイクイーブン
input bool     UseBreakeven      = true;       // ブレイクイーブン使用
input double   BE_ActivateRR     = 0.8;        // 含み益がSL幅×この倍率でBE発動
input double   BE_LockPips       = 0.20;       // BE時にエントリー+この$分を確保

//--- 時間フィルター（サーバー時間）
input bool     UseTimeFilter     = true;       // 時間フィルター使用
input int      TradeStartHour    = 8;          // 取引開始時
input int      TradeEndHour      = 21;         // 取引終了時

//--- その他
input int      MaxSpreadPoints   = 500;        // 最大スプレッド（ポイント）
input int      MagicNumber       = 20240101;   // マジックナンバー
input string   TradeComment      = "GoldMR";   // コメント

//+------------------------------------------------------------------+
//| Global Variables                                                   |
//+------------------------------------------------------------------+
CTrade         trade;
int            handleTrendEMA;
int            handleRSI;
int            handleATR;

double         bufTrendEMA[];
double         bufRSI[];
double         bufATR[];

datetime       lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   handleTrendEMA = iMA(_Symbol, PERIOD_CURRENT, TrendEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   handleRSI      = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   handleATR      = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   if(handleTrendEMA == INVALID_HANDLE || handleRSI == INVALID_HANDLE ||
      handleATR == INVALID_HANDLE)
   {
      Print("インジケータの初期化に失敗しました");
      return INIT_FAILED;
   }

   ArraySetAsSeries(bufTrendEMA, true);
   ArraySetAsSeries(bufRSI, true);
   ArraySetAsSeries(bufATR, true);

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   Print("GoldTrendEA v5.00 Mean Reversion 初期化完了");
   Print("戦略: トレンド内の押し目/戻り売りを狙う");
   Print("エクイティ: ", AccountInfoDouble(ACCOUNT_EQUITY), " ", AccountInfoString(ACCOUNT_CURRENCY));
   Print("リスク率: ", GetCurrentRiskPercent(), "%");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                    |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(handleTrendEMA != INVALID_HANDLE) IndicatorRelease(handleTrendEMA);
   if(handleRSI      != INVALID_HANDLE) IndicatorRelease(handleRSI);
   if(handleATR      != INVALID_HANDLE) IndicatorRelease(handleATR);

   Print("GoldTrendEA 終了");
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- ブレイクイーブン管理（毎ティック）
   if(UseBreakeven)
      ManageBreakeven();

   //--- 新しい足の確定時のみシグナル判定
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == lastBarTime)
      return;
   lastBarTime = currentBarTime;

   //--- インジケータデータ取得
   if(!GetIndicatorData())
      return;

   //--- 時間フィルター
   if(UseTimeFilter && !IsTradeTime())
      return;

   //--- スプレッドチェック
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpreadPoints)
      return;

   //--- 既存ポジションがあればスキップ
   if(HasOpenPosition())
      return;

   //--- エントリーシグナル判定
   int signal = GetTradeSignal();
   if(signal != 0)
      ExecuteTrade(signal);
}

//+------------------------------------------------------------------+
//| 取引時間帯チェック                                                  |
//+------------------------------------------------------------------+
bool IsTradeTime()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   int hour = dt.hour;

   if(TradeStartHour < TradeEndHour)
      return (hour >= TradeStartHour && hour < TradeEndHour);
   else
      return (hour >= TradeStartHour || hour < TradeEndHour);
}

//+------------------------------------------------------------------+
//| インジケータデータ取得                                              |
//+------------------------------------------------------------------+
bool GetIndicatorData()
{
   if(CopyBuffer(handleTrendEMA, 0, 0, 3, bufTrendEMA) < 3)  return false;
   if(CopyBuffer(handleRSI, 0, 0, 3, bufRSI) < 3)            return false;
   if(CopyBuffer(handleATR, 0, 0, 3, bufATR) < 3)            return false;

   return true;
}

//+------------------------------------------------------------------+
//| 売買シグナル判定（ミーンリバージョン）                                |
//|                                                                    |
//| 考え方:                                                            |
//|   上昇トレンド中にRSIが売られすぎ → 一時的な押し目 → 買いチャンス    |
//|   下降トレンド中にRSIが買われすぎ → 一時的な戻り → 売りチャンス     |
//|                                                                    |
//| シグナル条件:                                                       |
//|   RSIが極端な領域に入った後「回復」した瞬間にエントリー               |
//|   → 反転の確認を待つことで精度向上                                   |
//|                                                                    |
//| 戻り値: +1=買い, -1=売り, 0=シグナルなし                            |
//+------------------------------------------------------------------+
int GetTradeSignal()
{
   //--- 確定足データ（[1]=直前確定足, [2]=その前の足）
   double closePrice  = iClose(_Symbol, PERIOD_CURRENT, 1);
   double trendEMA    = bufTrendEMA[1];
   double rsi_curr    = bufRSI[1];    // 直前確定足のRSI
   double rsi_prev    = bufRSI[2];    // その前の足のRSI

   //--- 買いシグナル: 上昇トレンド中の押し目買い
   //    1. 価格がEMA200の上（上昇トレンド）
   //    2. 前の足でRSIが30以下だった（売られすぎ = 一時的な押し目）
   //    3. 現在の足でRSIが30を超えて回復した（反転確認）
   bool buySignal = (closePrice > trendEMA) &&
                    (rsi_prev <= RSI_OversoldLevel) &&
                    (rsi_curr > RSI_OversoldLevel);

   //--- 売りシグナル: 下降トレンド中の戻り売り
   //    1. 価格がEMA200の下（下降トレンド）
   //    2. 前の足でRSIが70以上だった（買われすぎ = 一時的な戻り）
   //    3. 現在の足でRSIが70を下回った（反転確認）
   bool sellSignal = (closePrice < trendEMA) &&
                     (rsi_prev >= RSI_OverboughtLevel) &&
                     (rsi_curr < RSI_OverboughtLevel);

   if(buySignal)
   {
      Print("押し目買いシグナル: RSI ", NormalizeDouble(rsi_prev,1),
            " -> ", NormalizeDouble(rsi_curr,1),
            " Price=", closePrice, " EMA200=", NormalizeDouble(trendEMA,2));
      return +1;
   }
   if(sellSignal)
   {
      Print("戻り売りシグナル: RSI ", NormalizeDouble(rsi_prev,1),
            " -> ", NormalizeDouble(rsi_curr,1),
            " Price=", closePrice, " EMA200=", NormalizeDouble(trendEMA,2));
      return -1;
   }

   return 0;
}

//+------------------------------------------------------------------+
//| 段階的リスク率の取得（エクイティベースで複利）                        |
//+------------------------------------------------------------------+
double GetCurrentRiskPercent()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(equity >= Balance_Thresh4) return Risk_Level4;
   if(equity >= Balance_Thresh3) return Risk_Level3;
   if(equity >= Balance_Thresh2) return Risk_Level2;

   return Risk_Level1;
}

//+------------------------------------------------------------------+
//| ロットサイズ計算（エクイティベース複利）                              |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
   if(slDistance <= 0) return MinLot;

   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskPct    = GetCurrentRiskPercent() / 100.0;
   double riskAmount = equity * riskPct;

   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0) return MinLot;

   double slTicks    = slDistance / tickSize;
   double lossPerLot = slTicks * tickValue;

   if(lossPerLot <= 0) return MinLot;

   double lots = riskAmount / lossPerLot;

   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep <= 0) lotStep = 0.01;
   lots = MathFloor(lots / lotStep) * lotStep;

   double brokerMinLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double brokerMaxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lots = MathMax(lots, MathMax(MinLot, brokerMinLot));
   lots = MathMin(lots, MathMin(MaxLot, brokerMaxLot));

   //--- 証拠金チェック
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double marginRequired = 0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lots, SymbolInfoDouble(_Symbol, SYMBOL_ASK), marginRequired))
   {
      if(marginRequired > freeMargin * 0.8)
      {
         double safeLots = lots * (freeMargin * 0.8) / marginRequired;
         safeLots = MathFloor(safeLots / lotStep) * lotStep;
         safeLots = MathMax(safeLots, brokerMinLot);

         if(safeLots < brokerMinLot)
         {
            Print("証拠金不足");
            return 0;
         }
         lots = safeLots;
      }
   }

   return lots;
}

//+------------------------------------------------------------------+
//| トレード実行                                                       |
//+------------------------------------------------------------------+
void ExecuteTrade(int signal)
{
   double atr = bufATR[1];
   if(atr <= 0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double slDistance = NormalizeDouble(atr * ATR_SL_Multi, digits);
   double tpDistance = NormalizeDouble(slDistance * RR_Ratio, digits);

   double lots = CalculateLotSize(slDistance);
   if(lots <= 0) return;

   if(signal == +1)
   {
      double sl = NormalizeDouble(ask - slDistance, digits);
      double tp = NormalizeDouble(ask + tpDistance, digits);

      Print("BUY: ", ask, " SL=", sl, " TP=", tp,
            " Lots=", lots, " Eq=", NormalizeDouble(AccountInfoDouble(ACCOUNT_EQUITY),2));

      if(!trade.Buy(lots, _Symbol, ask, sl, tp, TradeComment))
         Print("買い失敗: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }
   else if(signal == -1)
   {
      double sl = NormalizeDouble(bid + slDistance, digits);
      double tp = NormalizeDouble(bid - tpDistance, digits);

      Print("SELL: ", bid, " SL=", sl, " TP=", tp,
            " Lots=", lots, " Eq=", NormalizeDouble(AccountInfoDouble(ACCOUNT_EQUITY),2));

      if(!trade.Sell(lots, _Symbol, bid, sl, tp, TradeComment))
         Print("売り失敗: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| 自分のポジションがあるか確認                                         |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| ブレイクイーブン管理                                                |
//| ミーンリバージョンではTPに到達しやすいためトレーリング不要             |
//| BEのみで損失削減に集中                                              |
//+------------------------------------------------------------------+
void ManageBreakeven()
{
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(handleATR, 0, 0, 2, atrBuf) < 2) return;
   if(atrBuf[1] <= 0) return;

   double slWidth    = atrBuf[1] * ATR_SL_Multi;
   double beActivate = slWidth * BE_ActivateRR;
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      long posType     = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      if(posType == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(bid - openPrice >= beActivate)
         {
            double beSL = NormalizeDouble(openPrice + BE_LockPips, digits);
            if(currentSL < beSL)
               trade.PositionModify(ticket, beSL, currentTP);
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(openPrice - ask >= beActivate)
         {
            double beSL = NormalizeDouble(openPrice - BE_LockPips, digits);
            if(currentSL == 0 || currentSL > beSL)
               trade.PositionModify(ticket, beSL, currentTP);
         }
      }
   }
}

//+------------------------------------------------------------------+

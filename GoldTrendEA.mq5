//+------------------------------------------------------------------+
//|                                                  GoldTrendEA.mq5 |
//|                        Gold Trend Following EA for Exness MT5     |
//|                        XAUUSD M15 - v4.00 Optimized Exits        |
//+------------------------------------------------------------------+
#property copyright "GoldTrendEA"
#property version   "4.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+

//--- トレンド検出パラメータ（v2.00実績ベース）
input int      FastEMA_Period    = 20;         // 短期EMA期間
input int      SlowEMA_Period    = 50;         // 長期EMA期間
input int      TrendEMA_Period   = 200;        // 長期トレンド判定EMA

//--- ADXトレンド強度フィルター
input int      ADX_Period        = 14;         // ADX期間
input double   ADX_MinLevel      = 20.0;       // ADX最低値

//--- RSIフィルター
input int      RSI_Period        = 14;         // RSI期間
input double   RSI_BuyMax        = 70.0;       // RSI買い上限
input double   RSI_SellMin       = 30.0;       // RSI売り下限

//--- ATRベース損切り・利確
input int      ATR_Period        = 14;         // ATR期間
input double   ATR_SL_Multi     = 2.0;        // SL = ATR × この倍率
input double   RR_Ratio          = 2.0;        // リスクリワード比

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

//--- ブレイクイーブン（損失を減らすための核心機能）
input bool     UseBreakeven      = true;       // ブレイクイーブン使用
input double   BE_ActivateRR     = 1.0;        // 含み益がSL幅×この倍率でBE発動
input double   BE_LockPips       = 0.30;       // BE時にエントリー+この$分を確保

//--- トレーリングストップ（利益を伸ばすための機能）
input bool     UseTrailingStop   = true;       // トレーリングストップ使用
input double   TrailActivateRR   = 1.5;        // 含み益がSL幅×この倍率で開始
input double   TrailATR_Multi    = 1.5;        // トレーリング幅 = ATR × 倍率

//--- 時間フィルター（サーバー時間）
input bool     UseTimeFilter     = true;       // 時間フィルター使用
input int      TradeStartHour    = 8;          // 取引開始時
input int      TradeEndHour      = 21;         // 取引終了時

//--- その他
input int      MaxSpreadPoints   = 500;        // 最大スプレッド（ポイント）
input int      MagicNumber       = 20240101;   // マジックナンバー
input string   TradeComment      = "GoldTrend"; // コメント

//+------------------------------------------------------------------+
//| Global Variables                                                   |
//+------------------------------------------------------------------+
CTrade         trade;
int            handleFastEMA;
int            handleSlowEMA;
int            handleTrendEMA;
int            handleRSI;
int            handleATR;
int            handleADX;

double         bufFastEMA[];
double         bufSlowEMA[];
double         bufTrendEMA[];
double         bufRSI[];
double         bufATR[];
double         bufADX[];
double         bufPlusDI[];
double         bufMinusDI[];

datetime       lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- インジケータハンドル作成（M15チャートベース）
   handleFastEMA  = iMA(_Symbol, PERIOD_CURRENT, FastEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   handleSlowEMA  = iMA(_Symbol, PERIOD_CURRENT, SlowEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   handleTrendEMA = iMA(_Symbol, PERIOD_CURRENT, TrendEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   handleRSI      = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   handleATR      = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
   handleADX      = iADX(_Symbol, PERIOD_CURRENT, ADX_Period);

   if(handleFastEMA == INVALID_HANDLE || handleSlowEMA == INVALID_HANDLE ||
      handleTrendEMA == INVALID_HANDLE || handleRSI == INVALID_HANDLE ||
      handleATR == INVALID_HANDLE || handleADX == INVALID_HANDLE)
   {
      Print("インジケータの初期化に失敗しました");
      return INIT_FAILED;
   }

   //--- バッファ設定
   ArraySetAsSeries(bufFastEMA, true);
   ArraySetAsSeries(bufSlowEMA, true);
   ArraySetAsSeries(bufTrendEMA, true);
   ArraySetAsSeries(bufRSI, true);
   ArraySetAsSeries(bufATR, true);
   ArraySetAsSeries(bufADX, true);
   ArraySetAsSeries(bufPlusDI, true);
   ArraySetAsSeries(bufMinusDI, true);

   //--- トレード設定
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   Print("GoldTrendEA v4.00 初期化完了");
   Print("口座エクイティ: ", AccountInfoDouble(ACCOUNT_EQUITY), " ", AccountInfoString(ACCOUNT_CURRENCY));
   Print("リスク率: ", GetCurrentRiskPercent(), "%");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                    |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(handleFastEMA  != INVALID_HANDLE) IndicatorRelease(handleFastEMA);
   if(handleSlowEMA  != INVALID_HANDLE) IndicatorRelease(handleSlowEMA);
   if(handleTrendEMA != INVALID_HANDLE) IndicatorRelease(handleTrendEMA);
   if(handleRSI      != INVALID_HANDLE) IndicatorRelease(handleRSI);
   if(handleATR      != INVALID_HANDLE) IndicatorRelease(handleATR);
   if(handleADX      != INVALID_HANDLE) IndicatorRelease(handleADX);

   Print("GoldTrendEA 終了");
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- ブレイクイーブン・トレーリングは毎ティック処理
   ManageOpenPositions();

   //--- 新しいM15足が確定した時のみシグナル判定
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
   if(CopyBuffer(handleFastEMA, 0, 0, 3, bufFastEMA) < 3)   return false;
   if(CopyBuffer(handleSlowEMA, 0, 0, 3, bufSlowEMA) < 3)   return false;
   if(CopyBuffer(handleTrendEMA, 0, 0, 3, bufTrendEMA) < 3)  return false;
   if(CopyBuffer(handleRSI, 0, 0, 3, bufRSI) < 3)            return false;
   if(CopyBuffer(handleATR, 0, 0, 3, bufATR) < 3)            return false;
   if(CopyBuffer(handleADX, 0, 0, 3, bufADX) < 3)            return false;
   if(CopyBuffer(handleADX, 1, 0, 3, bufPlusDI) < 3)         return false;
   if(CopyBuffer(handleADX, 2, 0, 3, bufMinusDI) < 3)        return false;

   return true;
}

//+------------------------------------------------------------------+
//| 売買シグナル判定（v2.00実績ベース）                                  |
//| 戻り値: +1=買い, -1=売り, 0=シグナルなし                            |
//+------------------------------------------------------------------+
int GetTradeSignal()
{
   double fastEMA_curr  = bufFastEMA[1];
   double fastEMA_prev  = bufFastEMA[2];
   double slowEMA_curr  = bufSlowEMA[1];
   double slowEMA_prev  = bufSlowEMA[2];
   double trendEMA      = bufTrendEMA[1];
   double rsi           = bufRSI[1];
   double adx           = bufADX[1];
   double plusDI         = bufPlusDI[1];
   double minusDI       = bufMinusDI[1];
   double closePrice    = iClose(_Symbol, PERIOD_CURRENT, 1);

   //--- ADXフィルター
   if(adx < ADX_MinLevel)
      return 0;

   //--- 買いシグナル: ゴールデンクロス + 上昇トレンド + RSI非過買い + DI方向
   bool buySignal = (fastEMA_prev <= slowEMA_prev) &&
                    (fastEMA_curr > slowEMA_curr) &&
                    (closePrice > trendEMA) &&
                    (rsi < RSI_BuyMax) &&
                    (plusDI > minusDI);

   //--- 売りシグナル: デッドクロス + 下降トレンド + RSI非過売り + DI方向
   bool sellSignal = (fastEMA_prev >= slowEMA_prev) &&
                     (fastEMA_curr < slowEMA_curr) &&
                     (closePrice < trendEMA) &&
                     (rsi > RSI_SellMin) &&
                     (minusDI > plusDI);

   if(buySignal)  return +1;
   if(sellSignal) return -1;

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

   //--- エクイティベースで複利効果
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

   //--- ロットサイズ正規化
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep <= 0) lotStep = 0.01;
   lots = MathFloor(lots / lotStep) * lotStep;

   //--- ブローカー制限
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

      Print("BUY: ", ask, " SL=", sl, " TP=", tp, " Lots=", lots,
            " ATR=", NormalizeDouble(atr,2), " Eq=", NormalizeDouble(AccountInfoDouble(ACCOUNT_EQUITY),2));

      if(!trade.Buy(lots, _Symbol, ask, sl, tp, TradeComment))
         Print("買い失敗: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }
   else if(signal == -1)
   {
      double sl = NormalizeDouble(bid + slDistance, digits);
      double tp = NormalizeDouble(bid - tpDistance, digits);

      Print("SELL: ", bid, " SL=", sl, " TP=", tp, " Lots=", lots,
            " ATR=", NormalizeDouble(atr,2), " Eq=", NormalizeDouble(AccountInfoDouble(ACCOUNT_EQUITY),2));

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
//| ポジション管理（ブレイクイーブン＋トレーリング）                       |
//| v2.00の「平均損失>平均利益」問題を解決する核心部分                    |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   //--- ATRデータ取得
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(handleATR, 0, 0, 2, atrBuf) < 2) return;
   if(atrBuf[1] <= 0) return;

   double currentATR    = atrBuf[1];
   double slWidth       = currentATR * ATR_SL_Multi;
   double trailDistance  = currentATR * TrailATR_Multi;
   double beActivate    = slWidth * BE_ActivateRR;
   double trailActivate = slWidth * TrailActivateRR;
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
         double unrealizedProfit = bid - openPrice;

         //--- Phase 1: ブレイクイーブン
         //--- 含み益が1R以上 → SLをエントリー+0.30$に引き上げ
         //--- 効果: 反転時の損失をゼロ〜微利益に変換
         if(UseBreakeven && unrealizedProfit >= beActivate)
         {
            double beSL = NormalizeDouble(openPrice + BE_LockPips, digits);
            if(currentSL < beSL)
            {
               if(trade.PositionModify(ticket, beSL, currentTP))
                  currentSL = beSL;
            }
         }

         //--- Phase 2: トレーリングストップ
         //--- 含み益が1.5R以上 → 1.5ATR幅でSLを追従
         //--- 効果: 大きな利益を逃さず確保
         if(UseTrailingStop && unrealizedProfit >= trailActivate)
         {
            double newSL = NormalizeDouble(bid - trailDistance, digits);
            if(newSL > currentSL)
            {
               if(!trade.PositionModify(ticket, newSL, currentTP))
                  Print("Trail(BUY)失敗: ", trade.ResultRetcode());
            }
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double unrealizedProfit = openPrice - ask;

         //--- Phase 1: ブレイクイーブン
         if(UseBreakeven && unrealizedProfit >= beActivate)
         {
            double beSL = NormalizeDouble(openPrice - BE_LockPips, digits);
            if(currentSL == 0 || currentSL > beSL)
            {
               if(trade.PositionModify(ticket, beSL, currentTP))
                  currentSL = beSL;
            }
         }

         //--- Phase 2: トレーリングストップ
         if(UseTrailingStop && unrealizedProfit >= trailActivate)
         {
            double newSL = NormalizeDouble(ask + trailDistance, digits);
            if(currentSL == 0 || newSL < currentSL)
            {
               if(!trade.PositionModify(ticket, newSL, currentTP))
                  Print("Trail(SELL)失敗: ", trade.ResultRetcode());
            }
         }
      }
   }
}

//+------------------------------------------------------------------+

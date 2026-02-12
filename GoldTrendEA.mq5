//+------------------------------------------------------------------+
//|                                                  GoldTrendEA.mq5 |
//|                        Gold Trend Following EA for Exness MT5     |
//|                        XAUUSD M15 - Dynamic Risk Management       |
//+------------------------------------------------------------------+
#property copyright "GoldTrendEA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+

//--- トレンド検出パラメータ
input int      FastEMA_Period    = 20;         // 短期EMA期間
input int      SlowEMA_Period    = 50;         // 長期EMA期間
input int      TrendEMA_Period   = 200;        // 長期トレンド判定EMA

//--- RSIフィルター
input int      RSI_Period        = 14;         // RSI期間
input double   RSI_BuyMax        = 70.0;       // RSI買い上限（過買い回避）
input double   RSI_SellMin       = 30.0;       // RSI売り下限（過売り回避）

//--- ATRベース損切り・利確
input int      ATR_Period        = 14;         // ATR期間
input double   ATR_SL_Multi     = 1.5;        // SL = ATR × この倍率
input double   RR_Ratio          = 2.0;        // リスクリワード比（TP = SL × この値）

//--- リスク管理（段階的）
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

//--- トレーリングストップ
input bool     UseTrailingStop   = true;       // トレーリングストップ使用
input double   TrailATR_Multi    = 1.0;        // トレーリング幅 = ATR × 倍率

//--- その他
input int      MaxSpreadPoints   = 500;        // 最大スプレッド（ポイント）※XAUUSD標準: 200-400
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

double         bufFastEMA[];
double         bufSlowEMA[];
double         bufTrendEMA[];
double         bufRSI[];
double         bufATR[];

datetime       lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- インジケータハンドル作成
   handleFastEMA  = iMA(_Symbol, PERIOD_CURRENT, FastEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   handleSlowEMA  = iMA(_Symbol, PERIOD_CURRENT, SlowEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   handleTrendEMA = iMA(_Symbol, PERIOD_CURRENT, TrendEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   handleRSI      = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
   handleATR      = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);

   if(handleFastEMA == INVALID_HANDLE || handleSlowEMA == INVALID_HANDLE ||
      handleTrendEMA == INVALID_HANDLE || handleRSI == INVALID_HANDLE ||
      handleATR == INVALID_HANDLE)
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

   //--- トレード設定
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   Print("GoldTrendEA 初期化完了");
   Print("口座残高: ", AccountInfoDouble(ACCOUNT_BALANCE), " ", AccountInfoString(ACCOUNT_CURRENCY));
   Print("現在のリスク率: ", GetCurrentRiskPercent(), "%");

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

   Print("GoldTrendEA 終了");
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- 新しい足が確定した時のみ処理（M15の足確定時）
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == lastBarTime)
   {
      //--- トレーリングストップは毎ティック処理
      if(UseTrailingStop)
         ManageTrailingStop();
      return;
   }
   lastBarTime = currentBarTime;

   //--- インジケータデータ取得
   if(!GetIndicatorData())
      return;

   //--- スプレッドチェック
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpreadPoints)
   {
      Print("スプレッドが広すぎます: ", spread, " points");
      return;
   }

   //--- 既存ポジションの確認
   bool hasPosition = HasOpenPosition();

   //--- エントリーシグナル判定
   if(!hasPosition)
   {
      int signal = GetTradeSignal();
      if(signal != 0)
         ExecuteTrade(signal);
   }
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

   return true;
}

//+------------------------------------------------------------------+
//| 売買シグナル判定                                                    |
//| 戻り値: +1=買い, -1=売り, 0=シグナルなし                            |
//+------------------------------------------------------------------+
int GetTradeSignal()
{
   //--- 確定足のデータ（インデックス1 = 直前確定足, 2 = その前の足）
   double fastEMA_curr  = bufFastEMA[1];
   double fastEMA_prev  = bufFastEMA[2];
   double slowEMA_curr  = bufSlowEMA[1];
   double slowEMA_prev  = bufSlowEMA[2];
   double trendEMA      = bufTrendEMA[1];
   double rsi           = bufRSI[1];
   double closePrice    = iClose(_Symbol, PERIOD_CURRENT, 1);

   //--- 買いシグナル条件
   //    1. 短期EMAが長期EMAを上抜け（ゴールデンクロス）
   //    2. 価格が200EMAの上（上昇トレンド）
   //    3. RSIが過買い圏に入っていない
   bool buySignal = (fastEMA_prev <= slowEMA_prev) &&
                    (fastEMA_curr > slowEMA_curr) &&
                    (closePrice > trendEMA) &&
                    (rsi < RSI_BuyMax);

   //--- 売りシグナル条件
   //    1. 短期EMAが長期EMAを下抜け（デッドクロス）
   //    2. 価格が200EMAの下（下降トレンド）
   //    3. RSIが過売り圏に入っていない
   bool sellSignal = (fastEMA_prev >= slowEMA_prev) &&
                     (fastEMA_curr < slowEMA_curr) &&
                     (closePrice < trendEMA) &&
                     (rsi > RSI_SellMin);

   if(buySignal)  return +1;
   if(sellSignal) return -1;

   return 0;
}

//+------------------------------------------------------------------+
//| 段階的リスク率の取得                                                |
//+------------------------------------------------------------------+
double GetCurrentRiskPercent()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(balance >= Balance_Thresh4) return Risk_Level4;
   if(balance >= Balance_Thresh3) return Risk_Level3;
   if(balance >= Balance_Thresh2) return Risk_Level2;

   return Risk_Level1;
}

//+------------------------------------------------------------------+
//| ロットサイズ計算（リスクベース）                                      |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
   if(slDistance <= 0) return MinLot;

   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskPct    = GetCurrentRiskPercent() / 100.0;
   double riskAmount = balance * riskPct;

   //--- 1ロットあたりの1ポイント価値を取得
   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0 || tickSize <= 0) return MinLot;

   //--- slDistanceは価格差（ドル単位）
   //--- SL幅をtick数に変換してからtickValueで金額化
   double slTicks    = slDistance / tickSize;
   double lossPerLot = slTicks * tickValue;

   if(lossPerLot <= 0) return MinLot;

   double lots = riskAmount / lossPerLot;

   //--- ロットサイズを正規化
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lots = MathFloor(lots / lotStep) * lotStep;

   //--- 範囲内に制限
   lots = MathMax(lots, MinLot);
   lots = MathMin(lots, MaxLot);

   //--- ブローカーの制限もチェック
   double brokerMinLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double brokerMaxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lots = MathMax(lots, brokerMinLot);
   lots = MathMin(lots, brokerMaxLot);

   //--- 証拠金チェック（レバレッジ100倍対応）
   //--- 注文に必要な証拠金が余剰証拠金の80%を超えないようにする
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double marginRequired = 0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lots, SymbolInfoDouble(_Symbol, SYMBOL_ASK), marginRequired))
   {
      if(marginRequired > freeMargin * 0.8)
      {
         //--- 余剰証拠金の80%以内に収まるロットに縮小
         double safeLots = lots * (freeMargin * 0.8) / marginRequired;
         safeLots = MathFloor(safeLots / lotStep) * lotStep;
         safeLots = MathMax(safeLots, brokerMinLot);

         if(safeLots < brokerMinLot)
         {
            Print("証拠金不足: 必要=", marginRequired, " 余剰=", freeMargin);
            return 0;
         }

         Print("証拠金制限によりロット縮小: ", lots, " -> ", safeLots,
               " (必要証拠金=", marginRequired, " 余剰=", freeMargin, ")");
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
   if(atr <= 0)
   {
      Print("ATR無効: ", atr);
      return;
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double slDistance = NormalizeDouble(atr * ATR_SL_Multi, digits);
   double tpDistance = NormalizeDouble(slDistance * RR_Ratio, digits);

   double lots = CalculateLotSize(slDistance);

   if(lots <= 0)
   {
      Print("ロットサイズ計算失敗（証拠金不足の可能性）");
      return;
   }

   if(signal == +1) // 買い
   {
      double entryPrice = ask;
      double sl = NormalizeDouble(entryPrice - slDistance, digits);
      double tp = NormalizeDouble(entryPrice + tpDistance, digits);

      Print("買いエントリー: Price=", entryPrice, " SL=", sl, " TP=", tp,
            " Lots=", lots, " ATR=", atr, " Risk=", GetCurrentRiskPercent(), "%");

      if(!trade.Buy(lots, _Symbol, entryPrice, sl, tp, TradeComment))
      {
         Print("買い注文失敗: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
      }
   }
   else if(signal == -1) // 売り
   {
      double entryPrice = bid;
      double sl = NormalizeDouble(entryPrice + slDistance, digits);
      double tp = NormalizeDouble(entryPrice - tpDistance, digits);

      Print("売りエントリー: Price=", entryPrice, " SL=", sl, " TP=", tp,
            " Lots=", lots, " ATR=", atr, " Risk=", GetCurrentRiskPercent(), "%");

      if(!trade.Sell(lots, _Symbol, entryPrice, sl, tp, TradeComment))
      {
         Print("売り注文失敗: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
      }
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
      {
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| トレーリングストップ管理                                             |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   if(bufATR[1] <= 0) return;

   double trailDistance = bufATR[1] * TrailATR_Multi;
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      long posType    = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      if(posType == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double newSL = NormalizeDouble(bid - trailDistance, digits);

         //--- 新SLが現SLより高く、かつエントリー価格以上の場合のみ移動
         if(newSL > currentSL && newSL >= openPrice)
         {
            if(!trade.PositionModify(ticket, newSL, currentTP))
            {
               Print("トレーリング（買い）失敗: ", trade.ResultRetcode());
            }
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double newSL = NormalizeDouble(ask + trailDistance, digits);

         //--- 新SLが現SLより低く、かつエントリー価格以下の場合のみ移動
         if((currentSL == 0 || newSL < currentSL) && newSL <= openPrice)
         {
            if(!trade.PositionModify(ticket, newSL, currentTP))
            {
               Print("トレーリング（売り）失敗: ", trade.ResultRetcode());
            }
         }
      }
   }
}

//+------------------------------------------------------------------+

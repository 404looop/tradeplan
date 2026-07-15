//+------------------------------------------------------------------+
//|                                         TradePlanSyncService.mq5 |
//|  ارسال خودکار پوزیشن‌های بسته‌شده به ژورنال TradePlan               |
//|  «نسخه‌ی سرویس» — بدون چارت، در پس‌زمینه‌ی خود متاتریدر اجرا می‌شود  |
//|  و با هیچ اکسپرت دیگری (مدیریت سرمایه، پراپ و…) تداخل ندارد        |
//|                                                                  |
//|  نصب:                                                            |
//|   1) این فایل را در MetaEditor باز و Compile کن (F7)              |
//|      (فایل باید در پوشه‌ی MQL5\Services باشد، نه Experts)          |
//|   2) در متاتریدر: Tools > Options > Expert Advisors               |
//|      تیک "Allow WebRequest for listed URL" را بزن و این آدرس     |
//|      را اضافه کن:  https://lrcsbamzdoldopjklnqh.supabase.co      |
//|   3) در پنجره‌ی Navigator بخش Services روی TradePlanSyncService   |
//|      راست‌کلیک کن > Add service                                   |
//|   4) توکن اتصال را از صفحه‌ی تنظیمات برنامه کپی و در ورودی        |
//|      InpToken جای‌گذاری کن — فقط بار اول! توکن ذخیره می‌شود و     |
//|      دفعات بعد (ری‌استارت، نصب مجدد) خودکار لود می‌شود            |
//|      (اگر قبلاً اکسپرت TradePlanSync را با توکن راه انداخته‌ای،    |
//|      همان توکن خودکار پیدا می‌شود و می‌توانی ورودی را خالی بگذاری) |
//|   5) نه چارت لازم دارد، نه دکمه‌ی Algo Trading                    |
//+------------------------------------------------------------------+
#property service
#property copyright "TradePlan"
#property version   "1.30"
#property description "Auto-sync closed positions + account balance to the TradePlan journal (chart-free background service)"

input string InpToken     = "";   // توکن اتصال (فقط بار اول لازم است؛ ذخیره می‌شود)
input int    InpFirstDays = 60;   // در اولین اجرا چند روزِ گذشته ارسال شود
input int    InpDeepDays  = 60;   // با هر شروع سرویس، این چند روزِ اخیر دوباره ارسال و تصحیح شود
input int    InpTimerSec  = 30;   // بازه‌ی بررسی (ثانیه)

const string TP_HOST   = "https://lrcsbamzdoldopjklnqh.supabase.co";
const string TP_URL    = TP_HOST + "/rest/v1/rpc/mt5_ingest";
const string TP_APIKEY = "sb_publishable_mAeK0Je17QOT5YVX9qkAxA_SdIbwRSp";
const int    TP_BATCH  = 100;     // حداکثر ترید در هر ارسال (سرور تا 200 می‌پذیرد)

bool   g_needSync      = false;
bool   g_deepSync      = false; // در شروع سرویس: کل بازه‌ی InpDeepDays دوباره ارسال می‌شود
string g_token         = "";
double g_sentBalance   = -1;   // آخرین بالانسی که با موفقیت ارسال شد
long   g_lastDeal      = -1;   // آخرین دیل دیده‌شده — جایگزین OnTradeTransaction که در سرویس نیست
long   g_login         = 0;    // برای تشخیص عوض شدن حساب در ترمینال

//--- نام متغیر سراسری ترمینال که زمان آخرین سینک موفق را نگه می‌دارد
string GVarName()
  {
   return "TPSYNC_" + IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN));
  }

//--- ذخیره‌ی دائمی توکن: همان فایل مشترک اکسپرت TradePlanSync، بنابراین
//--- اگر یکی از دو نسخه (اکسپرت/سرویس) قبلاً توکن گرفته باشد، دیگری هم دارد
string TokenFile() { return "TradePlanSync\\token.txt"; }

string LoadSavedToken()
  {
   int h = FileOpen(TokenFile(), FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE) return "";
   string t = FileReadString(h);
   FileClose(h);
   StringTrimLeft(t);
   StringTrimRight(t);
   return t;
  }

void SaveToken(const string t)
  {
   int h = FileOpen(TokenFile(), FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE) { Print("TradePlanSyncService: could not save token, error ", GetLastError()); return; }
   FileWriteString(h, t);
   FileClose(h);
  }

//+------------------------------------------------------------------+
//| بدنه‌ی سرویس: سرویس چارت و تایمر و OnTradeTransaction ندارد،       |
//| پس یک حلقه‌ی پس‌زمینه هر InpTimerSec ثانیه تغییرات را چک می‌کند     |
//+------------------------------------------------------------------+
void OnStart()
  {
   g_token = InpToken;
   StringTrimLeft(g_token);
   StringTrimRight(g_token);

   if(StringLen(g_token) < 8)
      g_token = LoadSavedToken(); // ورودی خالی است؛ توکن ذخیره‌شده از قبل (اکسپرت یا سرویس)

   if(StringLen(g_token) < 8)
     {
      Alert("TradePlanSyncService: توکن اتصال را در تنظیمات سرویس وارد کن (صفحه تنظیمات برنامه > اتصال متاتریدر). فقط بار اول لازم است.");
      Print("TradePlanSyncService: no token — right-click the service in Navigator > Properties and paste the token");
      return;
     }

   SaveToken(g_token); // برای دفعات بعد ذخیره شود

   int sleepMs = MathMax(10, InpTimerSec) * 1000;

   // ممکن است سرویس قبل از لاگین حساب بالا بیاید؛ صبر تا حساب آماده شود
   while(!IsStopped() && (long)AccountInfoInteger(ACCOUNT_LOGIN) == 0)
      Sleep(1000);
   if(IsStopped()) return;

   g_login    = (long)AccountInfoInteger(ACCOUNT_LOGIN);
   g_needSync = true; // در شروع، تریدهای جامانده از آخرین سینک هم ارسال می‌شوند
   g_deepSync = true; // و کل InpDeepDays روزِ اخیر دوباره ارسال می‌شود تا تریدهای
                      // موبایل و اصلاحات بروکر هم در ژورنال دقیق و تصحیح شوند
   Print("TradePlanSyncService: started for account ", g_login);

   while(!IsStopped())
     {
      if((long)AccountInfoInteger(ACCOUNT_LOGIN) == 0)
        { Sleep(1000); continue; } // بین دو حساب / قطع اتصال

      // اگر کاربر در همین ترمینال حساب را عوض کند، سینک عمیق حساب جدید انجام می‌شود
      long login = (long)AccountInfoInteger(ACCOUNT_LOGIN);
      if(login != g_login)
        {
         g_login = login;
         g_needSync = true; g_deepSync = true;
         g_sentBalance = -1; g_lastDeal = -1;
         Print("TradePlanSyncService: account changed, now syncing ", g_login);
        }

      // هر تغییر بالانس (بستن ترید، واریز، برداشت) یا دیلِ تازه => سینک
      double bal      = AccountInfoDouble(ACCOUNT_BALANCE);
      long   lastDeal = LatestDealTicket();
      if(bal != g_sentBalance || lastDeal != g_lastDeal)
         g_needSync = true;

      if(g_needSync && SyncClosedPositions())
        {
         g_needSync    = false; // در صورت خطا، فلگ می‌ماند و دور بعدی دوباره تلاش می‌کند
         g_deepSync    = false; // سینک عمیقِ شروع با موفقیت انجام شد
         g_sentBalance = bal;
         g_lastDeal    = lastDeal;
        }

      Sleep(sleepMs);
     }
  }

//+------------------------------------------------------------------+
//| تیکت آخرین دیلِ هیستوری اخیر — تشخیص ترید تازه حتی با سود صفر      |
//+------------------------------------------------------------------+
long LatestDealTicket()
  {
   if(!HistorySelect(TimeCurrent() - 259200, TimeCurrent() + 86400))
      return g_lastDeal;
   int n = HistoryDealsTotal();
   if(n <= 0) return 0;
   return (long)HistoryDealGetTicket(n - 1);
  }

//+------------------------------------------------------------------+
//| وضعیت حساب: بالانس لحظه‌ای + سرمایه‌ی اولیه (اولین واریز حساب)     |
//+------------------------------------------------------------------+
double GetInitialDeposit()
  {
   if(!HistorySelect(0, TimeCurrent() + 86400))
      return 0.0;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      if((ENUM_DEAL_TYPE)HistoryDealGetInteger(deal, DEAL_TYPE) == DEAL_TYPE_BALANCE)
         return HistoryDealGetDouble(deal, DEAL_PROFIT); // اولین تراکنش balance = واریز اولیه
     }
   return 0.0;
  }

string BuildAccountJson()
  {
   return "{"
        + "\"account\":\""  + IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN)) + "\""
        + ",\"balance\":"   + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2)
        + ",\"deposit\":"   + DoubleToString(GetInitialDeposit(), 2)
        + ",\"currency\":\""+ JsonEscape(AccountInfoString(ACCOUNT_CURRENCY)) + "\""
        + "}";
  }

//+------------------------------------------------------------------+
//| جمع‌آوری پوزیشن‌های کاملاً بسته‌شده از هیستوری و ارسال دسته‌ای       |
//+------------------------------------------------------------------+
bool SyncClosedPositions()
  {
   // وضعیت حساب قبل از انتخاب هیستوریِ تریدها ساخته می‌شود
   // (GetInitialDeposit خودش HistorySelect را عوض می‌کند)
   string acct = BuildAccountJson();

   datetime last = 0;
   if(GlobalVariableCheck(GVarName()))
      last = (datetime)(long)GlobalVariableGet(GVarName());

   // دو روز هم‌پوشانی؛ ارسال تکراری سمت سرور فقط آپدیت می‌شود (بی‌ضرر)
   datetime from = (last == 0) ? TimeCurrent() - (datetime)InpFirstDays * 86400
                               : last - 172800;

   // سینک عمیق در شروع سرویس: کل بازه‌ی InpDeepDays دوباره ارسال می‌شود تا
   // پوزیشن‌های گرفته‌شده با موبایل و هر مغایرت قدیمی هم آپدیت/تصحیح شود
   if(g_deepSync)
     {
      datetime deepFrom = TimeCurrent() - (datetime)MathMax(1, InpDeepDays) * 86400;
      if(deepFrom < from) from = deepFrom;
     }

   if(!HistorySelect(from, TimeCurrent() + 86400))
      return false;

   // پاس ۱: شناسه‌ی پوزیشن‌هایی که در این بازه دیلِ خروج دارند
   long posIds[];
   int  total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT && entry != DEAL_ENTRY_OUT_BY)
         continue;
      long pid = (long)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      if(pid == 0) continue;
      bool seen = false;
      for(int k = 0; k < ArraySize(posIds); k++)
         if(posIds[k] == pid) { seen = true; break; }
      if(!seen)
        {
         int n = ArraySize(posIds);
         ArrayResize(posIds, n + 1);
         posIds[n] = pid;
        }
     }

   if(ArraySize(posIds) == 0)
     {
      // ترید جدیدی نیست ولی وضعیت حساب (بالانس/واریز/برداشت) ارسال می‌شود
      if(!SendBatch("", acct)) return false;
      if(last == 0) GlobalVariableSet(GVarName(), (double)TimeCurrent());
      return true;
     }

   // پاس ۲: ساخت JSON هر پوزیشن و ارسال دسته‌ای
   string   items    = "";
   int      count    = 0;
   datetime maxClose = last;

   for(int i = 0; i < ArraySize(posIds); i++)
     {
      string   json  = "";
      datetime tClose = 0;
      if(!BuildTradeJson(posIds[i], tClose, json))
         continue; // پوزیشن هنوز کامل بسته نشده
      items += (count > 0 ? "," : "") + json;
      count++;
      if(tClose > maxClose) maxClose = tClose;
      if(count >= TP_BATCH)
        {
         if(!SendBatch(items, acct)) return false;
         items = ""; count = 0;
        }
     }

   if(count > 0 && !SendBatch(items, acct))
      return false;

   GlobalVariableSet(GVarName(), (double)maxClose);
   return true;
  }

//+------------------------------------------------------------------+
//| جمع‌بندی تمام دیل‌های یک پوزیشن => یک آبجکت JSON                    |
//| فقط اگر پوزیشن کاملاً بسته شده باشد true برمی‌گرداند                |
//+------------------------------------------------------------------+
bool BuildTradeJson(const long posId, datetime &closeTime, string &json)
  {
   if(!HistorySelectByPosition((ulong)posId))
      return false;

   double volIn = 0, volOut = 0, inPV = 0, outPV = 0;
   double profit = 0, comm = 0, swap = 0, sl = 0, tp = 0;
   datetime tOpen = 0, tClose = 0;
   string symbol = "";
   long   inType = -1;
   int    digits = 5;

   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      double   v = HistoryDealGetDouble(deal, DEAL_VOLUME);
      double   p = HistoryDealGetDouble(deal, DEAL_PRICE);
      datetime t = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);

      profit += HistoryDealGetDouble(deal, DEAL_PROFIT);
      comm   += HistoryDealGetDouble(deal, DEAL_COMMISSION);
      swap   += HistoryDealGetDouble(deal, DEAL_SWAP);

      if(symbol == "")
        {
         symbol = HistoryDealGetString(deal, DEAL_SYMBOL);
         digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
         if(digits <= 0) digits = 5;
        }

      if(entry == DEAL_ENTRY_IN)
        {
         volIn += v; inPV += v * p;
         if(tOpen == 0 || t < tOpen) tOpen = t;
         if(inType == -1) inType = HistoryDealGetInteger(deal, DEAL_TYPE);
        }
      else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT || entry == DEAL_ENTRY_OUT_BY)
        {
         volOut += v; outPV += v * p;
         if(t > tClose) tClose = t;
         double dsl = HistoryDealGetDouble(deal, DEAL_SL);
         double dtp = HistoryDealGetDouble(deal, DEAL_TP);
         if(dsl > 0) sl = dsl;
         if(dtp > 0) tp = dtp;
        }
     }

   // فقط پوزیشن کاملاً بسته‌شده ارسال می‌شود
   if(volIn <= 0 || volOut < volIn - 0.0000001)
      return false;

   closeTime = tClose;

   string type      = (inType == DEAL_TYPE_BUY) ? "buy" : "sell";
   double openPrice = inPV / volIn;
   double closePrice= (volOut > 0) ? outPV / volOut : 0;

   json = "{"
        + "\"ticket\":"       + IntegerToString(posId)
        + ",\"account\":\""   + IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN)) + "\""
        + ",\"symbol\":\""    + JsonEscape(symbol) + "\""
        + ",\"type\":\""      + type + "\""
        + ",\"volume\":"      + DoubleToString(volIn, 2)
        + ",\"open_price\":"  + DoubleToString(openPrice, digits)
        + ",\"close_price\":" + DoubleToString(closePrice, digits)
        + ",\"sl\":"          + (sl > 0 ? DoubleToString(sl, digits) : "null")
        + ",\"tp\":"          + (tp > 0 ? DoubleToString(tp, digits) : "null")
        + ",\"profit\":"      + DoubleToString(profit, 2)
        + ",\"commission\":"  + DoubleToString(comm, 2)
        + ",\"swap\":"        + DoubleToString(swap, 2)
        + ",\"open_time\":\"" + TimeToString(tOpen, TIME_DATE|TIME_SECONDS) + "\""
        + ",\"close_time\":\""+ TimeToString(tClose, TIME_DATE|TIME_SECONDS) + "\""
        + "}";
   return true;
  }

//+------------------------------------------------------------------+
string JsonEscape(string s)
  {
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   return s;
  }

//+------------------------------------------------------------------+
//| ارسال یک دسته ترید + وضعیت حساب به سرور                           |
//+------------------------------------------------------------------+
bool SendBatch(const string items, const string acct)
  {
   string payload = "{\"p_token\":\"" + g_token + "\",\"p_trades\":[" + items + "]"
                  + ",\"p_account\":" + acct + "}";

   char data[];
   int len = StringToCharArray(payload, data, 0, WHOLE_ARRAY, CP_UTF8) - 1; // بدون null پایانی
   if(len < 0) len = 0;
   ArrayResize(data, len);

   char   result[];
   string resHeaders;
   string headers = "Content-Type: application/json\r\napikey: " + TP_APIKEY + "\r\n";

   ResetLastError();
   int status = WebRequest("POST", TP_URL, headers, 10000, data, result, resHeaders);

   if(status == -1)
     {
      int err = GetLastError();
      if(err == 4014)
         Alert("TradePlanSyncService: آدرس زیر را در Tools > Options > Expert Advisors > Allow WebRequest اضافه کن:\n", TP_HOST);
      else
         Print("TradePlanSyncService: WebRequest failed, error ", err);
      return false;
     }

   string body = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);

   if(status != 200)
     {
      Print("TradePlanSyncService: server HTTP ", status, " — ", body);
      return false;
     }
   if(StringFind(body, "invalid_token") >= 0)
     {
      // توکن ذخیره‌شده دیگر معتبر نیست (در برنامه توکن جدید ساخته شده) —
      // فایل پاک می‌شود تا دفعه‌ی بعد توکن کهنه دوباره لود نشود
      FileDelete(TokenFile(), FILE_COMMON);
      Alert("TradePlanSyncService: توکن اتصال نامعتبر است. توکن جدید را از تنظیمات برنامه کپی کن و یک بار در تنظیمات سرویس بگذار.");
      return false;
     }
   if(StringFind(body, "\"ok\": true") < 0 && StringFind(body, "\"ok\":true") < 0 && StringFind(body, "\"ok\" : true") < 0)
     {
      Print("TradePlanSyncService: unexpected response — ", body);
      return false;
     }

   Print("TradePlanSyncService: batch sent OK");
   return true;
  }
//+------------------------------------------------------------------+

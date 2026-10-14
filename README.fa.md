# AI Prime Cursor Manager برای ویندوز — نسخه آزمایشی — Copyright © 2026 secocyber

**Copyright © 2026 secocyber. All rights reserved.**

دانلود ویندوز: [AIPrimeCursorManager-Windows.zip](https://github.com/omid-cyber/ai-prime-cursor-manager/releases/download/v1.8.0-experimental/AIPrimeCursorManager-Windows.zip). فایل ZIP را باز کنید و `AIPrimeCursorManager.exe` را اجرا کنید.

[English](README.md) | [Eesti](README.et.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | فارسی

**وضعیت: آزمایشی (Alpha).** این پروژه یک ابزار ویندوزی برای مدیریت یک Bridge محلی و احراز هویت‌شده بین Cursor و API سایت AI Prime Tech است. تست‌های Bridge و تست‌های ایستای Tunnel در محیط توسعه موفق بوده‌اند، اما رابط WPF و تونل واقعی Cloudflare هنوز روی یک ویندوز تمیز به‌صورت end-to-end تأیید نشده‌اند. این نسخه را محصول پایدار یا آماده استفاده حساس در نظر نگیرید.

## امکانات

- رابط PowerShell/WPF برای تست API Key و دریافت شناسه مدل‌های قابل دسترس برای همان کلید.
- Bridge محلی Node.js که فقط روی `127.0.0.1` گوش می‌دهد و درخواست‌های OpenAI-compatible را با شناسه مدل واقعی به AI Prime Tech می‌فرستد.
- احراز هویت Bearer بین Cursor و Bridge؛ کلید Cursor باید کلید محلی Bridge باشد، نه کلید اصلی AI Prime Tech.
- کنترل Bridge، لاگ‌ها، مقادیر آماده Cursor، انتخاب مدل و مدیریت آزمایشی Cloudflare Quick Tunnel.
- تست‌های آفلاین با upstream آزمایشی که نیازی به API Key واقعی ندارند.

## زبان‌های رابط کاربری

رابط WPF دارای انتخاب‌گر زبان در گوشه بالای سمت راست است. زبان‌های پشتیبانی‌شده عبارت‌اند از **انگلیسی (پیش‌فرض)، استونیایی، فرانسوی و آلمانی**. با تغییر زبان، برچسب‌ها، تب‌ها، دکمه‌ها، راهنماها، پیام امنیتی و پیام‌های وضعیت ترجمه می‌شوند. زبان انتخاب‌شده در تنظیمات کاربر ذخیره می‌شود و هنگام اجرای بعدی بازیابی می‌شود.

شناسه‌های فنی، شناسه مدل‌ها، URLها و پاسخ‌های ارائه‌دهنده به شکل اصلی باقی می‌مانند تا دقیق کپی شوند.

## محدودیت‌های مهم

- **محدودیت Explore داخلی Cursor:** این پروژه محدودیت‌های خود Cursor را دور نمی‌زند. بسته به نسخه و تنظیمات Cursor، ممکن است نتوان مدل BYOK را جداگانه برای Explore Subagent داخلی انتخاب کرد.
- **Cursor ریموت و localhost:** درخواست ریموت/ابری Cursor نمی‌تواند مستقیماً به `127.0.0.1` کامپیوتر تو وصل شود. تب Quick Tunnel آزمایشی یک HTTPS موقت برای تست ایجاد می‌کند. احراز هویت را حفظ کن و پس از آزمایش تونل را متوقف کن. از Bridge عمومی بدون احراز هویت استفاده نکن.
- **اعتبارسنجی ویندوز:** محیط توسعه فعلی امکان اجرای WPF را ندارد. اجرای واقعی GUI، Start/Stop Bridge، پیشرفت دانلود و Cloudflare Quick Tunnel باید روی ویندوز بررسی شود.
- فایل اجرایی ویندوز در [AIPrimeCursorManager-Windows.zip](https://github.com/omid-cyber/ai-prime-cursor-manager/releases/tag/v1.8.0-experimental) منتشر شده است. خود فایل `.exe` داخل درخت سورس نگهداری نمی‌شود.
- promptها و قطعات کدی که از Bridge عبور می‌کنند برای پردازش به AI Prime Tech ارسال می‌شوند. کد محرمانه را بدون مجوز ارسال نکن.

## پیش‌نیازها

- Windows 10/11
- Windows PowerShell 5.1 یا جدیدتر به همراه WPF
- Node.js نسخه 20 یا جدیدتر و قابل دسترس از PATH
- API Key فعال AI Prime Tech با مجوز مدل موردنظر

## اجرا از سورس

1. مخزن را Clone یا ZIP را دانلود و در یک پوشه معمولی استخراج کن؛ برنامه را مستقیماً داخل ZIP اجرا نکن.
2. فایل `Start-AI-Prime-Cursor-Manager.bat` را اجرا کن.
3. اگر رابط باز نشد، `Start-AI-Prime-Cursor-Manager-Diagnostics.bat` را اجرا کن. متن خطا را بدون کلیدها و URL تونل ارسال کن.
4. در Dashboard کلید AI Prime Tech را وارد کن و **Refresh model catalog** را بزن.
5. مدل را انتخاب کن و قبل از کار طولانی **Test selected model** را اجرا کن.
6. Bridge را روشن کن. در یک پروفایل جداگانه Cursor، گزینه‌های **Use OpenAI API Key** و **Override OpenAI Base URL** را طبق مقادیر تب Cursor Setup تنظیم کن. در Cursor فقط کلید محلی Bridge را وارد کن.

### اجرای تست‌های آفلاین

با Node.js 20 یا جدیدتر:

```powershell
npm test
npm run check
```

یا در ویندوز فایل `Run-Bridge-Smoke-Tests.bat` را اجرا کن. این تست‌ها از upstream آزمایشی استفاده می‌کنند و به API واقعی AI Prime Tech درخواست نمی‌فرستند.

## امنیت

- API Key، کلید Bridge، توکن‌ها، لاگ‌ها، تنظیمات و URL تونل را به GitHub Commit نکن.
- Bridge باید فقط روی `127.0.0.1` گوش دهد و endpointها باید کلید Bearer محلی را الزامی کنند.
- Bridge را مستقیماً در شبکه LAN یا اینترنت منتشر نکن. تونل عمومی موقت فقط برای تست کنترل‌شده است.
- هر کلیدی را که قبلاً در چت، اسکرین‌شات، issue یا لاگ منتشر شده، باطل و جایگزین کن.

## دریافت ZIP سورس اعتبارسنجی‌شده (نسخه آزمایشی)

یک Workflow دستی در GitHub Actions یک فایل ZIP فقط شامل سورس می‌سازد و قبل از ارائه، فایل ZIP استخراج‌شده را دوباره بررسی می‌کند:

1. صفحه [Actions برای بسته سورس](https://github.com/omid-cyber/ai-prime-cursor-manager/actions/workflows/package-alpha-source.yml) را باز کن.
2. Workflow با نام **Package Alpha Source Bundle** را انتخاب کن، روی شاخه `main` گزینه **Run workflow** را بزن و منتظر موفقیت اجرا بمان.
3. از اجرای موفق، Artifact با نام `ai-prime-cursor-manager-source-<commit>` را دانلود کن. این Artifact پس از ۱۴ روز منقضی می‌شود.
4. ZIP را کامل در یک پوشه معمولی استخراج کن و فایل `Start-AI-Prime-Cursor-Manager.bat` را اجرا کن.

Workflow بررسی‌های Node.js، تست‌های آفلاین Bridge/Tunnel و اعتبارسنجی PowerShell/XAML را اجرا می‌کند. سپس ZIP را در یک پوشه تازه استخراج کرده و تست‌ها را روی همان نسخه استخراج‌شده دوباره اجرا می‌کند.

**این بسته، ZIP سورس اعتبارسنجی‌شده است؛ فایل EXE کامپایل‌شده یا نسخه پایدار نیست.** رابط زنده WPF و تونل واقعی Cloudflare هنوز باید به‌صورت دستی روی Windows 10/11 آزمایش شوند. هنوز مجوزی برای بازتوزیع انتخاب نشده است؛ فایل `LICENSE-DECISION.md` را ببین.

## بلوغ فعلی پروژه

این کد چند اصلاح تاریخی پس از خطاهای اجرای ویندوز داشته است؛ تست سورس جایگزین تست کامل GUI روی ویندوز نیست. گزارش تست و راهنمای انتشار را ببین: [TEST-REPORT.md](TEST-REPORT.md) و [docs/RELEASING.md](docs/RELEASING.md).

## مجوز

هنوز مجوزی از سوی مالک پروژه انتخاب نشده است. تا افزودن فایل لایسنس، تمام حقوق محفوظ فرض شود؛ بازتوزیع یا ساخت آثار مشتق‌شده را مجاز فرض نکن. پیش از معرفی پروژه به‌عنوان متن‌باز، نوع مجوز باید تعیین شود.

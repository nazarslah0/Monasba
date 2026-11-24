// ===== إعدادات يغيّرها المطوّر فقط =====

/// رابط مجلد المحتوى على الاستضافة بدون "/" في آخره، مثال:
/// 'https://USERNAME.github.io/qiraati-content'
/// اتركه فارغًا لتعطيل السحابة (يعمل التطبيق بالمحتوى المدمج فقط).
const String kCloudBase = 'https://github.com/nazarslah0/qiraati-content.git';

/// عدد الصفحات التي تُحمَّل أصواتها مسبقًا بعد الصفحة الحالية.
const int kPrefetch = 5;

/// الرقم السري للقائمة المخفية (استيراد المحتوى / التحديث).
const String kAdminPin = '1234';

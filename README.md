# قراءتي (Flutter)

## بناء APK والويب بدون تثبيت Flutter (GitHub Actions)
1) أنشئ مستودعًا جديدًا على github.com وارفع كل محتويات هذا المجلد (بما فيها المجلد المخفي .github).
2) افتح تبويب Actions ← Build APK ← Run workflow (أو يبدأ تلقائيًا عند الرفع على main).
3) بعد النجاح (بضع دقائق) افتح التشغيل وحمّل qiraati-apk من Artifacts وثبّت app-release.apk على الهاتف.
4) نسخة الويب: مرة واحدة فقط من Settings ← Pages اجعل Source = GitHub Actions، ثم أعد التشغيل، فيظهر رابط الموقع في خطوة deploy (https://اسمك.github.io/اسم-المستودع/). كما تجد ملفاتها في Artifacts باسم qiraati-web لرفعها على أي استضافة (ابنِها بنفسك مع --base-href المناسب إن لم تستخدم GitHub Pages).

## التشغيل المحلي
flutter create --platforms=android . ثم أضف داخل <manifest> في android/app/src/main/AndroidManifest.xml:
<queries><intent><action android:name="android.intent.action.TTS_SERVICE"/></intent></queries>
ثم flutter pub get و flutter run.

## تعديل البيانات
من المطوّر فقط: عدّل assets/content.json (أو صدّره من dashboard.html وضعه مكانه). لا يوجد تعديل داخل التطبيق.

## الأصوات
- كل عنصر في content.json يقبل الحقل "audio". إن كان اسم ملف داخل assets/audio (بدون .mp3) مثل "04_tha_kasra" يُشغَّل الملف.
- أو أضف الصوت للعنصر من dashboard.html (🎵 إضافة صوت أو الاستوديو) ثم صدّر content.json: الأصوات تُدمج فيه وتعمل مباشرة.
- إن لم يوجد صوت للعنصر يعود التطبيق إلى النطق الآلي.

## الرسم والتحقق (✏️)
- زر ✏️ في كل صفحة يفتح الرسم بالإصبع (ألوان، تراجع، مسح) ويُحفظ رسم الطفل لكل صفحة.
- للأنشطة التي لها إجابة (مثل: ارسم دائرة حول المختلف) أضف للصفحة في content.json الحقل "targets": [{"x":..,"y":..,"w":..,"h":..}] بالنسب المئوية من الصفحة (مثال جاهز في الصفحة 8). دائرة الطفل حول الهدف = ⭐ أحسنت، وحول مكان خاطئ = ❌ حاول مرة أخرى وتُمسح.

ملاحظة: أهداف التحقق (targets) صارت في assets/targets.json (مفتاحها معرّف الصفحة مثل p8) حتى لا تضيع عند استبدال content.json بملف مصدّر من اللوحة. وassets/ratios.json لنسب الصور.

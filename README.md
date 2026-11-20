# قراءتي (Flutter)
1) `flutter create qiraati` ثم انسخ فوقه: lib/ و assets/ و pubspec.yaml من هذا المجلد.
2) في android/app/src/main/AndroidManifest.xml أضف داخل <manifest> (قبل <application>):
   <queries><intent><action android:name="android.intent.action.TTS_SERVICE"/></intent></queries>
3) `flutter pub get` ثم `flutter run`.
تعديل البيانات: من المطوّر فقط — عدّل assets/content.json (أو صدّره من dashboard.html وضعه مكانه). لا يوجد أي تعديل داخل التطبيق.

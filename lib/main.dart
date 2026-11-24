import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'reader.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const QiraatiApp());
}

class QiraatiApp extends StatelessWidget {
  const QiraatiApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'قراءتي',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: kAccent),
        builder: (c, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
        home: const ReaderScreen(),
      );
}

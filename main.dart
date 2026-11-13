import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shamsi_date/shamsi_date.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

const navy = Color(0xFF20384B);
const green = Color(0xFF269B80);
const bg = Color(0xFFF6F8FA);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Intl.defaultLocale = 'fa';
  await Store.instance.init();
  runApp(const KharjNegarApp());
}

class KharjNegarApp extends StatelessWidget {
  const KharjNegarApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'خرج‌نگار',
    locale: const Locale('fa'),
    supportedLocales: const [Locale('fa'), Locale('en')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: bg,
      colorScheme: ColorScheme.fromSeed(seedColor: navy, brightness: Brightness.light),
      appBarTheme: const AppBarTheme(backgroundColor: bg, foregroundColor: navy, elevation: 0),
      cardTheme: CardThemeData(color: Colors.white, elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: bg,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      ),
    ),
    home: const Gate(),
  );
}

String faNum(Object value) {
  const en = '0123456789';
  const fa = '۰۱۲۳۴۵۶۷۸۹';
  return value.toString().replaceAllMapped(RegExp(r'[0-9]'), (m) => fa[en.indexOf(m[0]!)]);
}
String money(int n) => faNum(NumberFormat('#,###').format(n));
int? parseAmount(String raw) {
  const fa = '۰۱۲۳۴۵۶۷۸۹';
  const ar = '٠١٢٣٤٥٦٧٨٩';
  var normalized = raw.replaceAll(',', '').replaceAll('٬', '').replaceAll(' ', '');
  for (var i = 0; i < 10; i++) {
    normalized = normalized.replaceAll(fa[i], '$i').replaceAll(ar[i], '$i');
  }
  return int.tryParse(normalized);
}
String dayKey(DateTime d) => '${d.year.toString().padLeft(4,'0')}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';
String shamsi(DateTime d) {
  final j = Jalali.fromDateTime(d);
  return faNum('${j.year}/${j.month.toString().padLeft(2,'0')}/${j.day.toString().padLeft(2,'0')}');
}

class Store {
  Store._();
  static final instance = Store._();
  late Database db;

  Future<void> init() async {
    final path = p.join(await getDatabasesPath(), 'kharjnegar.db');
    db = await openDatabase(path, version: 1, onCreate: (d, v) async {
      await d.execute('CREATE TABLE categories(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE, active INTEGER NOT NULL DEFAULT 1)');
      await d.execute('CREATE TABLE expenses(id INTEGER PRIMARY KEY AUTOINCREMENT, amount INTEGER NOT NULL, category TEXT NOT NULL, note TEXT NOT NULL DEFAULT "", date TEXT NOT NULL, created_at TEXT NOT NULL)');
      for (final c in ['خوراک و غذا','خرید خانه','حمل‌ونقل','پوشاک','قبوض و شارژ','درمان و دارو','تفریح','آموزش','اجاره و مسکن','سایر مخارج']) {
        await d.insert('categories', {'name': c, 'active': 1});
      }
    });
  }

  Future<List<Map<String,Object?>>> categories({bool activeOnly = false}) =>
      db.query('categories', where: activeOnly ? 'active=1' : null, orderBy: 'id');
  Future<List<Map<String,Object?>>> expenses({String? date}) =>
      db.query('expenses', where: date == null ? null : 'date=?', whereArgs: date == null ? null : [date], orderBy: 'date DESC, id DESC');
  Future<int> addExpense(int amount, String category, String note, DateTime date) =>
      db.insert('expenses', {'amount': amount, 'category': category, 'note': note, 'date': dayKey(date), 'created_at': DateTime.now().toIso8601String()});
  Future<void> updateExpense(int id, int amount, String category, String note, DateTime date) async =>
      db.update('expenses', {'amount': amount, 'category': category, 'note': note, 'date': dayKey(date)}, where: 'id=?', whereArgs: [id]);
  Future<void> deleteExpense(int id) async => db.delete('expenses', where: 'id=?', whereArgs: [id]);
  Future<int> addCategory(String name) => db.insert('categories', {'name': name, 'active': 1});
  Future<void> renameCategory(int id, String oldName, String newName) async {
    await db.transaction((t) async {
      await t.update('categories', {'name': newName}, where: 'id=?', whereArgs: [id]);
      await t.update('expenses', {'category': newName}, where: 'category=?', whereArgs: [oldName]);
    });
  }
  Future<void> deactivateCategory(int id) async => db.update('categories', {'active': 0}, where: 'id=?', whereArgs: [id]);

  Future<Map<String,dynamic>> exportData() async => {
    'format': 'kharjnegar-backup',
    'version': 1,
    'createdAt': DateTime.now().toIso8601String(),
    'categories': await db.query('categories'),
    'expenses': await db.query('expenses'),
  };

  Future<void> importData(Map<String,dynamic> data) async {
    if (data['format'] != 'kharjnegar-backup' || data['version'] != 1 ||
        data['categories'] is! List || data['expenses'] is! List) {
      throw Exception('ساختار فایل پشتیبان معتبر نیست یا پشتیبانی نمی‌شود.');
    }
    await db.transaction((t) async {
      await t.delete('expenses');
      await t.delete('categories');
      for (final row in (data['categories'] as List)) {
        await t.insert('categories', Map<String,Object?>.from(row as Map), conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final row in (data['expenses'] as List)) {
        await t.insert('expenses', Map<String,Object?>.from(row as Map), conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }
}

class Auth {
  static const _enabled = 'lock_enabled';
  static const _salt = 'lock_salt';
  static const _hash = 'lock_hash';
  static final _pbkdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 120000, bits: 256);

  static Future<bool> enabled() async => (await SharedPreferences.getInstance()).getBool(_enabled) ?? false;

  static Future<void> setPassword(String password) async {
    final prefs = await SharedPreferences.getInstance();
    final salt = _randomBytes(16);
    final key = await _pbkdf.deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
    await prefs.setString(_salt, base64Encode(salt));
    await prefs.setString(_hash, base64Encode(await key.extractBytes()));
    await prefs.setBool(_enabled, true);
  }

  static Future<bool> verify(String password) async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_salt), h = prefs.getString(_hash);
    if (s == null || h == null) return false;
    final key = await _pbkdf.deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: base64Decode(s));
    return _constantTimeEquals(await key.extractBytes(), base64Decode(h));
  }

  static Future<void> disable() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_enabled, false);
    await p.remove(_salt); await p.remove(_hash);
  }

  static Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }
  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var x = 0; for (var i=0;i<a.length;i++) { x |= a[i] ^ b[i]; }
    return x == 0;
  }
}

class Backup {
  static final _aes = AesGcm.with256bits();
  static final _pbkdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 200000, bits: 256);

  static Uint8List _random(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }

  static Future<Uint8List> encrypt(String password) async {
    final salt = _random(16);
    final nonce = _random(12);
    final key = await _pbkdf.deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
    final clear = utf8.encode(jsonEncode(await Store.instance.exportData()));
    final box = await _aes.encrypt(clear, secretKey: key, nonce: nonce);
    final payload = {
      'format': 'KharjNegarEncryptedBackup',
      'version': 1,
      'salt': base64Encode(salt),
      'nonce': base64Encode(nonce),
      'ciphertext': base64Encode(box.cipherText),
      'mac': base64Encode(box.mac.bytes),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(payload)));
  }

  static Future<Map<String,dynamic>> decrypt(Uint8List bytes, String password) async {
    final p = jsonDecode(utf8.decode(bytes)) as Map<String,dynamic>;
    if (p['format'] != 'KharjNegarEncryptedBackup' || p['version'] != 1) {
      throw Exception('این فایل، پشتیبان معتبر خرج‌نگار نیست.');
    }
    final salt = base64Decode(p['salt']);
    final nonce = base64Decode(p['nonce']);
    final key = await _pbkdf.deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
    final box = SecretBox(base64Decode(p['ciphertext']), nonce: nonce, mac: Mac(base64Decode(p['mac'])));
    final clear = await _aes.decrypt(box, secretKey: key);
    return jsonDecode(utf8.decode(clear)) as Map<String,dynamic>;
  }
}

class Gate extends StatefulWidget {
  const Gate({super.key});
  @override State<Gate> createState() => _GateState();
}
class _GateState extends State<Gate> {
  bool? locked;
  @override void initState() { super.initState(); Auth.enabled().then((v) { if(mounted) setState(()=>locked=v); }); }
  @override Widget build(BuildContext context) {
    if (locked == null) return const Scaffold(body: Center(child:CircularProgressIndicator()));
    if (locked!) return LockScreen(onSuccess: () => setState(()=>locked=false));
    return const MainShell();
  }
}

class LockScreen extends StatefulWidget {
  final VoidCallback onSuccess;
  const LockScreen({super.key, required this.onSuccess});
  @override State<LockScreen> createState()=>_LockScreenState();
}
class _LockScreenState extends State<LockScreen> {
  final ctrl=TextEditingController(); String? error; bool busy=false;
  @override Widget build(BuildContext context)=>Scaffold(body: Center(child:ConstrainedBox(
    constraints: const BoxConstraints(maxWidth:360),
    child: Padding(padding:const EdgeInsets.all(24),child:Column(mainAxisSize:MainAxisSize.min,children:[
      const Icon(Icons.lock_outline,size:56,color:navy), const SizedBox(height:16),
      const Text('خرج‌نگار',style:TextStyle(fontSize:26,fontWeight:FontWeight.bold)),
      const SizedBox(height:8), const Text('برای ورود رمز عبور را وارد کنید'),
      const SizedBox(height:20),
      TextField(controller:ctrl, obscureText:true, keyboardType:TextInputType.number, decoration:InputDecoration(labelText:'رمز عبور',errorText:error)),
      const SizedBox(height:12), FilledButton(onPressed:busy?null:() async { setState(()=>busy=true); final ok=await Auth.verify(ctrl.text); if(!mounted)return; setState(()=>busy=false); if(ok) widget.onSuccess(); else setState(()=>error='رمز عبور اشتباه است'); }, child:const Text('ورود')),
    ])))));
}

class MainShell extends StatefulWidget { const MainShell({super.key}); @override State<MainShell> createState()=>_MainShellState(); }
class _MainShellState extends State<MainShell> {
  int tab=0;
  final pages = const [HomePage(), HistoryPage(), ReportsPage(), SettingsPage()];
  @override Widget build(BuildContext context)=>Scaffold(
    body: SafeArea(child: IndexedStack(index:tab,children:pages)),
    bottomNavigationBar: NavigationBar(selectedIndex:tab,onDestinationSelected:(v)=>setState(()=>tab=v), destinations:const [
      NavigationDestination(icon:Icon(Icons.home_outlined),selectedIcon:Icon(Icons.home),label:'خانه'),
      NavigationDestination(icon:Icon(Icons.history),label:'سوابق'),
      NavigationDestination(icon:Icon(Icons.bar_chart),label:'گزارش‌ها'),
      NavigationDestination(icon:Icon(Icons.settings_outlined),label:'تنظیمات'),
    ]),
  );
}

class HomePage extends StatefulWidget { const HomePage({super.key}); @override State<HomePage> createState()=>_HomePageState(); }
class _HomePageState extends State<HomePage> {
  final amount=TextEditingController(); final note=TextEditingController();
  String? category; DateTime date=DateTime.now();
  List<Map<String,Object?>> cats=[]; List<Map<String,Object?>> rows=[];
  @override void initState(){super.initState();refresh();}
  Future<void> refresh() async {
    cats=await Store.instance.categories(activeOnly:true);
    rows=await Store.instance.expenses(date:dayKey(DateTime.now()));
    if(mounted)setState((){});
  }
  int get total=>rows.fold(0,(s,e)=>s+(e['amount'] as int));
  Future<void> save() async {
    final n=parseAmount(amount.text);
    if(n==null || n<=0 || category==null){ ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('مبلغ معتبر و دسته‌بندی را انتخاب کنید'))); return; }
    await Store.instance.addExpense(n,category!,note.text.trim(),date);
    amount.clear();note.clear();date=DateTime.now();await refresh();
    if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('هزینه ثبت شد')));
  }
  @override Widget build(BuildContext context)=>RefreshIndicator(onRefresh:refresh,child:ListView(padding:const EdgeInsets.all(16),children:[
    Row(mainAxisAlignment:MainAxisAlignment.spaceBetween,children:[const Text('خرج‌نگار',style:TextStyle(fontSize:24,fontWeight:FontWeight.bold,color:navy)),Text(shamsi(DateTime.now()),style:const TextStyle(color:Colors.black54))]),
    const SizedBox(height:16),
    Container(padding:const EdgeInsets.all(20),decoration:BoxDecoration(color:navy,borderRadius:BorderRadius.circular(22)),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      const Text('مجموع مخارج امروز',style:TextStyle(color:Colors.white70)),
      const SizedBox(height:8),Text('${money(total)} تومان',style:const TextStyle(color:Colors.white,fontSize:28,fontWeight:FontWeight.bold)),
      Text('${faNum(rows.length)} مورد هزینه',style:const TextStyle(color:Colors.white70)),
    ])),
    const SizedBox(height:20), const Text('ثبت هزینه جدید',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),
    const SizedBox(height:10),
    TextField(controller:amount,keyboardType:const TextInputType.numberWithOptions(decimal:false,signed:false),inputFormatters:[DigitsOnlyFormatter()],decoration:const InputDecoration(labelText:'مبلغ به تومان',hintText:'مثلاً ۲۵۰۰۰۰')),
    const SizedBox(height:10),
    DropdownButtonFormField<String>(value:category,decoration:const InputDecoration(labelText:'دسته‌بندی'),items:cats.map((c)=>DropdownMenuItem(value:c['name'] as String,child:Text(c['name'] as String))).toList(),onChanged:(v)=>setState(()=>category=v)),
    const SizedBox(height:10),
    TextField(controller:note,decoration:const InputDecoration(labelText:'توضیحات (اختیاری)')),
    const SizedBox(height:10),
    OutlinedButton.icon(onPressed:() async { final d=await showDatePicker(context:context,initialDate:date,firstDate:DateTime(2000),lastDate:DateTime(2100)); if(d!=null)setState(()=>date=d); },icon:const Icon(Icons.calendar_month),label:Text('تاریخ هزینه: ${shamsi(date)}')),
    const SizedBox(height:10),
    FilledButton.icon(onPressed:save,icon:const Icon(Icons.add),label:const Text('ثبت هزینه')),
    const SizedBox(height:24),const Text('مخارج ۷ روز اخیر',style:TextStyle(fontSize:18,fontWeight:FontWeight.bold)),
    const SizedBox(height:12),SizedBox(height:190,child:FutureBuilder<List<Map<String,Object?>>>(future:Store.instance.expenses(),builder:(context,s){
      final all=s.data??[]; final now=DateTime.now(); final vals=<int>[];
      for(int i=6;i>=0;i--){final d=DateTime(now.year,now.month,now.day).subtract(Duration(days:i)); vals.add(all.where((e)=>e['date']==dayKey(d)).fold(0,(a,e)=>a+(e['amount'] as int)));}
      if(s.connectionState!=ConnectionState.done)return const Center(child:CircularProgressIndicator());
      return BarChart(BarChartData(
        alignment:BarChartAlignment.spaceAround,
        titlesData:FlTitlesData(leftTitles:const AxisTitles(sideTitles:SideTitles(showTitles:false)),topTitles:const AxisTitles(sideTitles:SideTitles(showTitles:false)),rightTitles:const AxisTitles(sideTitles:SideTitles(showTitles:false)),
          bottomTitles:AxisTitles(sideTitles:SideTitles(showTitles:true,getTitlesWidget:(v,m)=>Padding(padding:const EdgeInsets.only(top:6),child:Text(faNum(Jalali.fromDateTime(now.subtract(Duration(days:6-v.toInt()))).day),style:const TextStyle(fontSize:10)))))),
        borderData:FlBorderData(show:false),gridData:const FlGridData(show:false),
        barGroups:List.generate(7,(i)=>BarChartGroupData(x:i,barRods:[BarChartRodData(toY:vals[i].toDouble(),color:green,width:16,borderRadius:const BorderRadius.vertical(top:Radius.circular(5)))])),
      ));
    })),
  ]));
}

class DigitsOnlyFormatter extends TextInputFormatter {
  @override TextEditingValue formatEditUpdate(TextEditingValue oldValue,TextEditingValue newValue) {
    final v=newValue.text.replaceAll(RegExp(r'[^0-9۰-۹٠-٩]'),'');
    return TextEditingValue(text:v,selection:TextSelection.collapsed(offset:v.length));
  }
}

class HistoryPage extends StatefulWidget { const HistoryPage({super.key}); @override State<HistoryPage> createState()=>_HistoryPageState(); }
class _HistoryPageState extends State<HistoryPage> {
  DateTime selected=DateTime.now(); List<Map<String,Object?>> rows=[];
  @override void initState(){super.initState();load();}
  Future<void> load() async {rows=await Store.instance.expenses(date:dayKey(selected));if(mounted)setState((){});}
  Future<void> edit(Map<String,Object?> e) async {
    final amount=TextEditingController(text:'${e['amount']}');final note=TextEditingController(text:'${e['note']}');
    final cats=await Store.instance.categories();
    String cat=e['category'] as String; DateTime d=DateTime.parse(e['date'] as String);
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(title:const Text('ویرایش هزینه'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
      TextField(controller:amount,keyboardType:TextInputType.number,inputFormatters:[DigitsOnlyFormatter()],decoration:const InputDecoration(labelText:'مبلغ تومان')),
      DropdownButtonFormField<String>(value:cats.any((c)=>c['name']==cat)?cat:null,items:cats.map((c)=>DropdownMenuItem(value:c['name'] as String,child:Text(c['name'] as String))).toList(),onChanged:(v){if(v!=null)cat=v;}),
      TextField(controller:note,decoration:const InputDecoration(labelText:'توضیحات')),
      TextButton(onPressed:() async {final x=await showDatePicker(context:ctx,initialDate:d,firstDate:DateTime(2000),lastDate:DateTime(2100));if(x!=null)d=x;},child:Text('تاریخ: ${shamsi(d)}')),
    ])),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('انصراف')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('ذخیره'))]));
    if(ok==true){final n=parseAmount(amount.text);if(n!=null&&n>0)await Store.instance.updateExpense(e['id'] as int,n,cat,note.text,d);await load();}
  }
  @override Widget build(BuildContext context)=>Column(children:[
    Padding(padding:const EdgeInsets.all(16),child:Row(children:[const Expanded(child:Text('سوابق مخارج',style:TextStyle(fontSize:23,fontWeight:FontWeight.bold))),TextButton.icon(onPressed:()async{final d=await showDatePicker(context:context,initialDate:selected,firstDate:DateTime(2000),lastDate:DateTime(2100));if(d!=null){selected=d;load();}},icon:const Icon(Icons.calendar_month),label:Text(shamsi(selected)))])),
    Expanded(child:rows.isEmpty?const Center(child:Text('برای این روز هزینه‌ای ثبت نشده است')):ListView.builder(itemCount:rows.length,itemBuilder:(ctx,i){
      final e=rows[i];return Card(margin:const EdgeInsets.symmetric(horizontal:12,vertical:5),child:ListTile(
        title:Text('${money(e['amount'] as int)} تومان',style:const TextStyle(fontWeight:FontWeight.bold)),
        subtitle:Text('${e['category']}  ${e['note']}'.trim()),
        trailing:Wrap(spacing:0,children:[
          IconButton(icon:const Icon(Icons.edit_outlined),onPressed:()=>edit(e)),
          IconButton(icon:const Icon(Icons.delete_outline,color:Colors.red),onPressed:()async{final yes=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(title:const Text('حذف هزینه'),content:const Text('این هزینه حذف شود؟'),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('انصراف')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('حذف'))]));if(yes==true){await Store.instance.deleteExpense(e['id'] as int);await load();}}),
        ]),
      ));
    })),
  ]);
}

class ReportsPage extends StatefulWidget { const ReportsPage({super.key}); @override State<ReportsPage> createState()=>_ReportsPageState(); }
class _ReportsPageState extends State<ReportsPage> {
  int mode=0;
  @override Widget build(BuildContext context)=>FutureBuilder<List<Map<String,Object?>>>(future:Store.instance.expenses(),builder:(ctx,s){
    final rows=s.data??[];final now=DateTime.now();final days=mode==0?7:mode==1?30:90;
    final start=DateTime(now.year,now.month,now.day).subtract(Duration(days:days-1));
    final selected=rows.where((e){final d=DateTime.parse(e['date'] as String);return !d.isBefore(start);}).toList();
    final total=selected.fold(0,(a,e)=>a+(e['amount'] as int));
    final byCat=<String,int>{};for(final e in selected){final c=e['category'] as String;byCat[c]=(byCat[c]??0)+(e['amount'] as int);}
    return ListView(padding:const EdgeInsets.all(16),children:[
      const Text('گزارش مخارج',style:TextStyle(fontSize:23,fontWeight:FontWeight.bold)),
      const SizedBox(height:14),
      SegmentedButton<int>(segments:const [ButtonSegment(value:0,label:Text('۷ روز')),ButtonSegment(value:1,label:Text('۳۰ روز')),ButtonSegment(value:2,label:Text('۹۰ روز'))],selected:{mode},onSelectionChanged:(v)=>setState(()=>mode=v.first)),
      const SizedBox(height:16),Card(child:Padding(padding:const EdgeInsets.all(18),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[const Text('مجموع مخارج این بازه'),const SizedBox(height:8),Text('${money(total)} تومان',style:const TextStyle(fontSize:25,fontWeight:FontWeight.bold,color:navy))]))),
      const SizedBox(height:16),const Text('تفکیک بر اساس دسته‌بندی',style:TextStyle(fontSize:17,fontWeight:FontWeight.bold)),
      if(byCat.isEmpty) const Padding(padding:EdgeInsets.all(20),child:Text('هنوز داده‌ای برای گزارش وجود ندارد')),
      for(final e in (byCat.entries.toList()..sort((a,b)=>b.value.compareTo(a.value))))
        Card(child:ListTile(title:Text(e.key),trailing:Text('${money(e.value)} تومان'))),
    ]);
  });
}

class SettingsPage extends StatefulWidget { const SettingsPage({super.key}); @override State<SettingsPage> createState()=>_SettingsPageState(); }
class _SettingsPageState extends State<SettingsPage> {
  bool lock=false; List<Map<String,Object?>> cats=[];
  @override void initState(){super.initState();refresh();}
  Future<void> refresh()async{lock=await Auth.enabled();cats=await Store.instance.categories();if(mounted)setState((){});}
  Future<String?> askPassword({String title='رمز عبور'})async{
    final c=TextEditingController();return showDialog<String>(context:context,builder:(ctx)=>AlertDialog(title:Text(title),content:TextField(controller:c,obscureText:true,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'رمز (حداقل ۶ رقم)')),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('انصراف')),FilledButton(onPressed:()=>Navigator.pop(ctx,c.text),child:const Text('تأیید'))]));
  }
  Future<void> manageLock()async{
    if(!lock){final a=await askPassword(title:'تعیین رمز جدید');if(a==null)return;if(a.length<6){msg('رمز باید حداقل ۶ رقم باشد');return;}final b=await askPassword(title:'تکرار رمز');if(a!=b){msg('رمزها یکسان نیستند');return;}await Auth.setPassword(a);}
    else{final a=await askPassword(title:'برای غیرفعال‌کردن رمز، رمز فعلی را وارد کنید');if(a==null)return;if(!await Auth.verify(a)){msg('رمز اشتباه است');return;}await Auth.disable();}
    await refresh();msg('تنظیمات امنیت ذخیره شد');
  }
  void msg(String s)=>ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(s)));
  Future<void> backup()async{
    final pass=await askPassword(title:'رمزگذاری فایل پشتیبان');if(pass==null)return;if(pass.length<6){msg('رمز باید حداقل ۶ رقم باشد');return;}
    try{final bytes=await Backup.encrypt(pass);final path=await FilePicker.platform.saveFile(fileName:'KharjNegar_Backup_${Jalali.now().year}.backup',bytes:bytes);if(path!=null)msg('فایل پشتیبان ذخیره شد');}catch(e){msg('خطا در پشتیبان‌گیری: $e');}
  }
  Future<void> restore()async{
    final file=await FilePicker.platform.pickFiles(type:FileType.custom,allowedExtensions:['backup'],withData:true);if(file==null||file.files.single.bytes==null)return;
    final pass=await askPassword(title:'رمز فایل پشتیبان');if(pass==null)return;
    try{
      final data=await Backup.decrypt(file.files.single.bytes!,pass);
      final yes=await showDialog<bool>(context:context,builder:(c)=>AlertDialog(title:const Text('جایگزینی اطلاعات فعلی'),content:Text('تعداد هزینه‌ها: ${(data['expenses'] as List).length}\nتمام اطلاعات فعلی با اطلاعات فایل جایگزین می‌شوند.'),actions:[TextButton(onPressed:()=>Navigator.pop(c,false),child:const Text('انصراف')),FilledButton(onPressed:()=>Navigator.pop(c,true),child:const Text('بازیابی'))]));
      if(yes==true){await Store.instance.importData(data);await refresh();msg('بازیابی با موفقیت انجام شد');}
    }catch(e){msg('رمز اشتباه است یا فایل معتبر نیست');}
  }
  Future<void> categoriesDialog()async{
    final name=TextEditingController();
    await showDialog(context:context,builder:(ctx)=>AlertDialog(title:const Text('مدیریت دسته‌بندی‌ها'),content:SizedBox(width:340,child:Column(mainAxisSize:MainAxisSize.min,children:[
      Row(children:[Expanded(child:TextField(controller:name,decoration:const InputDecoration(hintText:'نام دسته‌بندی جدید'))),IconButton(onPressed:()async{if(name.text.trim().isNotEmpty){try{await Store.instance.addCategory(name.text.trim());name.clear();await refresh();}catch(_){msg('این دسته‌بندی از قبل وجود دارد');}}},icon:const Icon(Icons.add_circle,color:green))]),
      const SizedBox(height:8),SizedBox(height:300,child:ListView(children:cats.map((c)=>ListTile(title:Text(c['name'] as String),subtitle:Text((c['active'] as int)==1?'فعال':'غیرفعال'),trailing:IconButton(icon:const Icon(Icons.delete_outline,color:Colors.red),onPressed:()async{await Store.instance.deactivateCategory(c['id'] as int);await refresh();Navigator.pop(ctx);await categoriesDialog();}))).toList())),
    ])),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('بستن'))]));
  }
  @override Widget build(BuildContext context)=>ListView(padding:const EdgeInsets.all(16),children:[
    const Text('تنظیمات',style:TextStyle(fontSize:23,fontWeight:FontWeight.bold)),
    const SizedBox(height:12),
    Card(child:ListTile(leading:const Icon(Icons.category_outlined),title:const Text('مدیریت دسته‌بندی‌ها'),trailing:const Icon(Icons.chevron_left),onTap:categoriesDialog)),
    Card(child:SwitchListTile(secondary:const Icon(Icons.lock_outline),title:const Text('قفل ورود با رمز'),subtitle:Text(lock?'فعال':'غیرفعال'),value:lock,onChanged:(_)=>manageLock())),
    Card(child:ListTile(leading:const Icon(Icons.backup_outlined),title:const Text('پشتیبان‌گیری رمزگذاری‌شده'),subtitle:const Text('ذخیره تمام اطلاعات در یک فایل امن'),trailing:const Icon(Icons.chevron_left),onTap:backup)),
    Card(child:ListTile(leading:const Icon(Icons.restore),title:const Text('بازیابی اطلاعات'),subtitle:const Text('انتخاب فایل پشتیبان از حافظه گوشی'),trailing:const Icon(Icons.chevron_left),onTap:restore)),
    const SizedBox(height:20),const Center(child:Text('خرج‌نگار · نسخه ۱.۰.۰',style:TextStyle(color:Colors.black45))),
  ]);
}

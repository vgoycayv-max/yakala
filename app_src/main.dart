import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Config.load();
  runApp(const YakalaApp());
}

class YakalaApp extends StatelessWidget {
  const YakalaApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Yakala',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
        home: const BrowserPage(),
      );
}

// ---------- Ayarlar (kisayollar + ceviri dili) ----------
class Config {
  static List<Map<String, String>> sites = [
    {'n': 'Archive.org', 'u': 'https://archive.org/'},
    {'n': 'Gutenberg', 'u': 'https://www.gutenberg.org/'},
    {'n': 'LibreTexts', 'u': 'https://libretexts.org/'},
    {'n': 'bdebooks', 'u': 'https://bdebooks.com/'},
  ];
  static String lang = 'tr';

  static Future<File> _f() async =>
      File('${(await getApplicationDocumentsDirectory()).path}/yakala_config.json');

  static Future<void> load() async {
    try {
      final f = await _f();
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        sites = (j['sites'] as List)
            .map((e) => {'n': e['n'].toString(), 'u': e['u'].toString()})
            .toList();
        lang = (j['lang'] ?? 'tr').toString();
      }
    } catch (_) {}
  }

  static Future<void> save() async {
    try {
      await (await _f()).writeAsString(jsonEncode({'sites': sites, 'lang': lang}));
    } catch (_) {}
  }
}

const Map<String, String> langs = {
  'tr': 'Turkce',
  'en': 'English',
  'ar': 'Arapca',
  'ru': 'Rusca',
  'de': 'Almanca',
  'fr': 'Fransizca',
  'es': 'Ispanyolca',
};

// Google Translate'in site proxy adresi: ornek-com.translate.goog
String translateUrl(String u, String lang) {
  final uri = Uri.parse(u);
  if (uri.host.endsWith('.translate.goog')) return u;
  final h = '${uri.host.replaceAll('-', '--').replaceAll('.', '-')}.translate.goog';
  final q = Map<String, String>.of(uri.queryParameters)
    ..addAll({'_x_tr_sl': 'auto', '_x_tr_tl': lang, '_x_tr_hl': lang, '_x_tr_pto': 'wapp'});
  return Uri(scheme: 'https', host: h, path: uri.path.isEmpty ? '/' : uri.path, queryParameters: q).toString();
}

String originalUrl(String u) {
  final uri = Uri.parse(u);
  if (!uri.host.endsWith('.translate.goog')) return u;
  var h = uri.host.substring(0, uri.host.length - '.translate.goog'.length);
  h = h.replaceAll('--', '\u0000').replaceAll('-', '.').replaceAll('\u0000', '-');
  final q = Map<String, String>.of(uri.queryParameters)
    ..removeWhere((k, _) => k.startsWith('_x_tr_'));
  return Uri(scheme: 'https', host: h, path: uri.path, queryParameters: q.isEmpty ? null : q).toString();
}

// ---------- Ortak ----------
const Map<String, List<String>> formats = {
  'epub': ['epub'],
  'pdf': ['pdf'],
  'txt': ['txt'],
  'csv': ['csv'],
  'mobi/azw': ['mobi', 'azw', 'azw3'],
  'djvu': ['djvu'],
  'zip/rar': ['zip', 'rar', '7z'],
  'doc': ['doc', 'docx', 'rtf'],
};

class FileItem {
  final String url;
  final String name;
  final String text;
  final bool isLink;
  bool selected;
  double progress = 0;
  String status = ''; // '', indiriliyor, bitti, hata
  String error = '';
  FileItem(this.url, this.name, this.text, {this.isLink = false})
      : selected = !isLink;
}

String nameOf(String url) {
  try {
    final u = Uri.parse(url);
    var n = u.pathSegments.isNotEmpty ? u.pathSegments.last : '';
    n = Uri.decodeComponent(n);
    return n.isEmpty ? 'dosya' : n;
  } catch (_) {
    return 'dosya';
  }
}

class Downloader {
  static final Dio _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 90)));
  static Directory? _dir;
  static String? _ua;

  static Future<Directory> dir() async {
    if (_dir != null) return _dir!;
    try {
      if (Platform.isAndroid) {
        final st = await Permission.manageExternalStorage.request();
        if (st.isGranted) {
          final d = Directory('/storage/emulated/0/Download/Yakala');
          await d.create(recursive: true);
          _dir = d;
          return d;
        }
      }
    } catch (_) {}
    final ext = await getExternalStorageDirectory();
    final d = Directory('${ext!.path}/Yakala');
    await d.create(recursive: true);
    _dir = d;
    return d;
  }

  static String clean(String n) => n.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

  static String uniquePath(Directory d, String name) {
    var path = '${d.path}/${clean(name)}';
    if (File(path).existsSync()) {
      final dot = path.lastIndexOf('.');
      final hasExt = dot > d.path.length;
      final base = hasExt ? path.substring(0, dot) : path;
      final ext = hasExt ? path.substring(dot) : '';
      var i = 1;
      while (File('$base ($i)$ext').existsSync()) {
        i++;
      }
      path = '$base ($i)$ext';
    }
    return path;
  }

  static Future<Map<String, String>> _headers(String url, String referer) async {
    final h = <String, String>{};
    try {
      final cookies = await CookieManager.instance().getCookies(url: WebUri(url));
      final ck = cookies.map((e) => '${e.name}=${e.value}').join('; ');
      if (ck.isNotEmpty) h['Cookie'] = ck;
    } catch (_) {}
    h['User-Agent'] = _ua ??
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';
    if (referer.isNotEmpty) h['Referer'] = referer;
    return h;
  }

  static String _describe(Object e) {
    if (e is DioException) {
      return e.message ?? e.type.name;
    }
    return e.toString();
  }

  static Future<void> download(FileItem it, InAppWebViewController? c,
      String referer, VoidCallback onUpdate,
      {Directory? into}) async {
    it.status = 'indiriliyor';
    it.error = '';
    it.progress = 0;
    onUpdate();
    String? path;
    try {
      final d = into ?? await dir();
      path = uniquePath(d, it.name);
      if (_ua == null && c != null) {
        try {
          _ua = (await c.evaluateJavascript(source: 'navigator.userAgent'))?.toString();
        } catch (_) {}
      }
      await _fetch(it, referer, path, onUpdate);
      it.progress = 1;
      it.status = 'bitti';
    } catch (e) {
      it.status = 'hata';
      it.error = _describe(e);
      try {
        if (path != null && File(path).existsSync()) File(path).deleteSync();
      } catch (_) {}
    }
    onUpdate();
  }

  static Future<void> _fetch(
      FileItem it, String referer, String path, VoidCallback onUpdate) async {
    for (var attempt = 0; attempt < 4; attempt++) {
      var cur = it.url;
      Response<ResponseBody>? resp;
      for (var hop = 0; hop < 8; hop++) {
        final h = await _headers(cur, referer);
        resp = await _dio.get<ResponseBody>(cur,
            options: Options(
                responseType: ResponseType.stream,
                followRedirects: false,
                validateStatus: (_) => true,
                headers: h));
        final s = resp.statusCode ?? 0;
        if (s >= 300 && s < 400) {
          final loc = resp.headers.value('location');
          try {
            await resp.data!.stream.drain();
          } catch (_) {}
          if (loc == null) break;
          cur = Uri.parse(cur).resolve(loc).toString();
          continue;
        }
        break;
      }
      final s = resp!.statusCode ?? 0;
      if (s == 429 || s == 502 || s == 503 || s == 504) {
        try {
          await resp.data!.stream.drain();
        } catch (_) {}
        await Future.delayed(Duration(seconds: 3 * (attempt + 1)));
        continue;
      }
      if (s < 200 || s >= 300) {
        throw 'HTTP $s';
      }
      final ct = (resp.headers.value('content-type') ?? '').toLowerCase();
      if (ct.contains('text/html') &&
          !RegExp(r'\.(html?|xhtml)$', caseSensitive: false).hasMatch(it.name)) {
        throw 'Dosya yerine web sayfasi geldi (giris/koruma olabilir). Sag taraftaki "tarayicida ac" ile dene.';
      }
      final total = int.tryParse(resp.headers.value('content-length') ?? '') ?? 0;
      final sink = File(path).openWrite();
      var got = 0;
      try {
        await for (final chunk in resp.data!.stream) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) {
            it.progress = got / total;
            onUpdate();
          }
        }
      } finally {
        await sink.close();
      }
      return;
    }
    throw 'Sunucu mesgul, biraz sonra tekrar dene';
  }

  static Future<void> many(List<FileItem> list, InAppWebViewController? c,
      String referer, VoidCallback onUpdate) async {
    await dir();
    final queue = List<FileItem>.of(list);
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final it = queue.removeAt(0);
        await download(it, c, referer, onUpdate);
      }
    }

    await Future.wait(List.generate(2, (_) => worker()));
  }
}

// ---------- Tarayici ----------
class TabData {
  final int id;
  InAppWebViewController? c;
  String url;
  String title = '';
  double progress = 0;
  TabData(this.id, this.url);
}

class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key});
  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  final List<TabData> tabs = [];
  int cur = 0;
  int nextId = 1;
  final urlCtl = TextEditingController();

  TabData get tab => tabs[cur];

  @override
  void initState() {
    super.initState();
    tabs.add(TabData(nextId++, Config.sites.isNotEmpty ? Config.sites.first['u']! : 'https://archive.org'));
    urlCtl.text = tabs.first.url;
  }

  void _addTab({String url = ''}) {
    setState(() {
      tabs.add(TabData(nextId++, url));
      cur = tabs.length - 1;
      urlCtl.text = url;
    });
  }

  void _closeTab(int i) {
    if (tabs.length == 1) return;
    setState(() {
      tabs.removeAt(i);
      if (cur >= tabs.length) cur = tabs.length - 1;
      if (i < cur) cur--;
      urlCtl.text = tab.url;
    });
  }

  void _go(String text) {
    var t = text.trim();
    if (t.isEmpty) return;
    if (!t.startsWith('http')) {
      t = t.contains('.') && !t.contains(' ')
          ? 'https://$t'
          : 'https://www.google.com/search?q=${Uri.encodeComponent(t)}';
    }
    if (tab.c == null) {
      setState(() => tab.url = t);
    } else {
      tab.c!.loadUrl(urlRequest: URLRequest(url: WebUri(t)));
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _addSite() async {
    final u = tab.url;
    if (!u.startsWith('http')) return;
    final uri = Uri.parse(originalUrl(u));
    final root = '${uri.scheme}://${uri.host}/';
    if (Config.sites.any((s) => s['u'] == root)) {
      _snack('Zaten kisayolda');
      return;
    }
    setState(() => Config.sites.add({
          'n': uri.host.replaceFirst('www.', ''),
          'u': root,
        }));
    await Config.save();
    _snack('Kisayol eklendi (silmek icin uzun bas)');
  }

  Future<void> _deleteSite(Map<String, String> s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('"${s['n']}" kisayolu silinsin mi?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Hayir')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sil')),
        ],
      ),
    );
    if (ok == true) {
      setState(() => Config.sites.remove(s));
      await Config.save();
    }
  }

  Future<void> _pickLang() async {
    final l = await showDialog<String>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('Ceviri dili'),
        children: langs.entries
            .map((e) => SimpleDialogOption(
                onPressed: () => Navigator.pop(context, e.key), child: Text(e.value)))
            .toList(),
      ),
    );
    if (l != null) {
      Config.lang = l;
      await Config.save();
      _snack('Dil: ${langs[l]}');
    }
  }

  // Uzun ekran goruntusu: sayfayi kaydirip parca parca cekip birlestirir
  Future<void> _longShot() async {
    final c = tab.c;
    if (c == null) return;
    final note = ValueNotifier<String>('Hazirlaniyor...');
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: ValueListenableBuilder<String>(
          valueListenable: note,
          builder: (_, v, __) => Row(children: [
            const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 16),
            Expanded(child: Text(v)),
          ]),
        ),
      ),
    );
    final frames = <_Frame>[];
    double startY = 0;
    try {
      final info = jsonDecode((await c.evaluateJavascript(
              source:
                  'JSON.stringify({h:Math.max(document.documentElement.scrollHeight,document.body?document.body.scrollHeight:0),vh:window.innerHeight,vw:window.innerWidth,y:window.scrollY})'))
          .toString());
      final h = (info['h'] as num).toDouble();
      final vh = (info['vh'] as num).toDouble();
      final vw = (info['vw'] as num).toDouble();
      startY = (info['y'] as num).toDouble();
      var n = (h / vh).ceil();
      if (n > 80) n = 80;
      for (var i = 0; i < n; i++) {
        var target = i * vh;
        if (i == n - 1) target = (h - vh) < 0 ? 0 : h - vh;
        await c.evaluateJavascript(source: 'window.scrollTo(0,$target)');
        await Future.delayed(const Duration(milliseconds: 500));
        final ay = double.tryParse((await c.evaluateJavascript(source: 'window.scrollY')).toString()) ?? target;
        final bytes = await c.takeScreenshot();
        if (bytes == null) continue;
        final codec = await ui.instantiateImageCodec(bytes);
        final fi = await codec.getNextFrame();
        final scale = fi.image.width / vw;
        frames.add(_Frame(bytes, ay * scale, fi.image.width, fi.image.height));
        fi.image.dispose();
        note.value = 'Cekiliyor ${i + 1}/$n';
      }
      await c.evaluateJavascript(source: 'window.scrollTo(0,$startY)');
      if (frames.isEmpty) throw 'Goruntu alinamadi';
      final w = frames.first.w;
      var total = 0.0;
      for (final f in frames) {
        if (f.dy + f.h > total) total = f.dy + f.h;
      }
      const chunk = 7000.0;
      final parts = (total / chunk).ceil();
      final d = await Downloader.dir();
      final host = Uri.parse(tab.url).host.replaceAll('.', '_');
      final stamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      for (var p = 0; p < parts; p++) {
        note.value = 'Birlestiriliyor ${p + 1}/$parts';
        final cs = p * chunk;
        final ch = (total - cs) < chunk ? (total - cs) : chunk;
        final rec = ui.PictureRecorder();
        final canvas = Canvas(rec);
        canvas.drawColor(Colors.white, BlendMode.src);
        for (final f in frames) {
          if (f.dy < cs + ch && f.dy + f.h > cs) {
            final cd = await ui.instantiateImageCodec(f.bytes);
            final img = (await cd.getNextFrame()).image;
            canvas.drawImage(img, Offset(0, f.dy - cs), Paint());
            img.dispose();
          }
        }
        final out = await rec.endRecording().toImage(w, ch.ceil());
        final bd = await out.toByteData(format: ui.ImageByteFormat.png);
        out.dispose();
        final name = parts == 1 ? 'ekran_${host}_$stamp.png' : 'ekran_${host}_${stamp}_${p + 1}.png';
        await File('${d.path}/$name').writeAsBytes(bd!.buffer.asUint8List());
      }
      if (mounted) Navigator.pop(context);
      _snack('Kaydedildi: Download/Yakala (ekran_$host...)');
    } catch (e) {
      try {
        await c.evaluateJavascript(source: 'window.scrollTo(0,$startY)');
      } catch (_) {}
      if (mounted) Navigator.pop(context);
      _snack('Hata: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = tab;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (t.c != null && await t.c!.canGoBack()) {
          t.c!.goBack();
        } else if (tabs.length > 1) {
          _closeTab(cur);
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(children: [
            Row(children: [
              IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => t.c?.goBack()),
              Expanded(
                child: TextField(
                  controller: urlCtl,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  onSubmitted: _go,
                  decoration: const InputDecoration(
                      isDense: true, border: OutlineInputBorder(), hintText: 'Adres veya arama'),
                ),
              ),
              IconButton(icon: const Icon(Icons.refresh), onPressed: () => t.c?.reload()),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'tr') {
                    _go(translateUrl(originalUrl(t.url), Config.lang));
                  } else if (v == 'orig') {
                    _go(originalUrl(t.url));
                  } else if (v == 'lang') {
                    _pickLang();
                  } else if (v == 'shot') {
                    _longShot();
                  } else if (v == 'print') {
                    t.c?.printCurrentPage();
                  } else if (v == 'fav') {
                    _addSite();
                  } else if (v == 'torrent') {
                    if (t.c != null) {
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => TorrentPage(controller: t.c!, getUrl: () => t.url)));
                    }
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'tr', child: Text('Cevir (${langs[Config.lang]})')),
                  const PopupMenuItem(value: 'orig', child: Text('Orijinal sayfa')),
                  const PopupMenuItem(value: 'lang', child: Text('Ceviri dilini sec')),
                  const PopupMenuDivider(),
                  const PopupMenuItem(value: 'shot', child: Text('Uzun ekran goruntusu')),
                  const PopupMenuItem(value: 'print', child: Text('PDF yap (tam sayfa)')),
                  const PopupMenuDivider(),
                  const PopupMenuItem(value: 'fav', child: Text('Siteyi kisayola ekle')),
                  const PopupMenuItem(value: 'torrent', child: Text('Forum: magnet/torrent topla')),
                ],
              ),
            ]),
            // Sekmeler
            SizedBox(
              height: 40,
              child: Row(children: [
                Expanded(
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: tabs.length,
                    itemBuilder: (_, i) {
                      final x = tabs[i];
                      var label = x.title.isNotEmpty
                          ? x.title
                          : (x.url.isEmpty ? 'Yeni sekme' : Uri.tryParse(x.url)?.host ?? x.url);
                      if (label.length > 14) label = '${label.substring(0, 14)}...';
                      return Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: InputChip(
                          label: Text(label),
                          selected: i == cur,
                          onPressed: () => setState(() {
                            cur = i;
                            urlCtl.text = tabs[i].url;
                          }),
                          onDeleted: tabs.length > 1 ? () => _closeTab(i) : null,
                        ),
                      );
                    },
                  ),
                ),
                IconButton(icon: const Icon(Icons.add), onPressed: () => _addTab()),
              ]),
            ),
            // Kisayollar
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                children: Config.sites
                    .map((s) => Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: GestureDetector(
                            onLongPress: () => _deleteSite(s),
                            child: ActionChip(
                              avatar: const Icon(Icons.star, size: 16),
                              label: Text(s['n']!),
                              onPressed: () {
                                urlCtl.text = s['u']!;
                                _go(s['u']!);
                              },
                            ),
                          ),
                        ))
                    .toList(),
              ),
            ),
            if (t.progress < 1 && t.progress > 0) LinearProgressIndicator(value: t.progress),
            Expanded(
              child: IndexedStack(
                index: cur,
                children: tabs.map((x) => _webview(x)).toList(),
              ),
            ),
          ]),
        ),
        floatingActionButton: FloatingActionButton.extended(
          icon: const Icon(Icons.download_for_offline),
          label: const Text('Yakala'),
          onPressed: () {
            if (tab.c == null) return;
            Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => CapturePage(
                          controller: tab.c!,
                          getUrl: () => tab.url,
                          onOpen: (u) => _addTab(url: u),
                        )));
          },
        ),
      ),
    );
  }

  Widget _webview(TabData x) {
    return InAppWebView(
      key: ValueKey(x.id),
      initialUrlRequest: x.url.isEmpty ? null : URLRequest(url: WebUri(x.url)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        useOnDownloadStart: true,
        thirdPartyCookiesEnabled: true,
        supportZoom: true,
      ),
      onWebViewCreated: (c) => x.c = c,
      onProgressChanged: (c, p) => setState(() => x.progress = p / 100),
      onTitleChanged: (c, title) => setState(() => x.title = title ?? ''),
      onUpdateVisitedHistory: (c, url, _) {
        x.url = url?.toString() ?? x.url;
        if (tabs.isNotEmpty && identical(tab, x)) urlCtl.text = x.url;
      },
      onDownloadStartRequest: (c, req) async {
        final u = req.url.toString();
        var name = req.suggestedFilename ?? '';
        if (name.isEmpty) name = nameOf(u);
        final it = FileItem(u, name, '');
        _snack('Indiriliyor: $name');
        await Downloader.download(it, c, x.url, () {});
        if (!mounted) return;
        _snack(it.status == 'bitti' ? 'Bitti: $name' : 'Hata: $name (${it.error})');
      },
    );
  }
}

class _Frame {
  final Uint8List bytes;
  final double dy;
  final int w;
  final int h;
  _Frame(this.bytes, this.dy, this.w, this.h);
}

// ---------- Yakala sayfasi ----------
const String _scanJs = r'''
const re = exts.length ? new RegExp('\\.(' + exts.join('|') + ')\\d*(?:[.?#]|$)', 'i') : /(?!)/;
const linkRe = /download|indir|ডাউনলোড|\/dl\b|\bget\b/i;
const found = new Map();
window.__ykStatus = '';
async function getDoc(url) {
  const r = await fetch(url, { credentials: 'include' });
  const buf = await r.arrayBuffer();
  let cs = ((r.headers.get('content-type') || '').match(/charset=([^;]+)/i) || [])[1];
  if (!cs) {
    const head = new TextDecoder('latin1').decode(buf.slice(0, 3000));
    const m = head.match(/charset=["']?([\w-]+)/i);
    cs = m ? m[1] : 'utf-8';
  }
  let txt;
  try { txt = new TextDecoder(cs.trim()).decode(buf); } catch (e) { txt = new TextDecoder('utf-8').decode(buf); }
  return new DOMParser().parseFromString(txt, 'text/html');
}
function allEls(root, sel, out) {
  root.querySelectorAll(sel).forEach(e => out.push(e));
  root.querySelectorAll('*').forEach(e => { if (e.shadowRoot) allEls(e.shadowRoot, sel, out); });
  return out;
}
function grab(doc, base, title, once, shadow) {
  const els = shadow ? allEls(doc, 'a[href], source[src], embed[src]', []) : Array.from(doc.querySelectorAll('a[href], source[src], embed[src]'));
  const seenExt = new Set();
  els.forEach(el => {
    const raw = el.getAttribute('href') || el.getAttribute('src');
    if (!raw) return;
    let u;
    try { u = new URL(raw, base); } catch (e) { return; }
    if (!/^https?:$/.test(u.protocol)) return;
    const m = re.exec(u.pathname + u.search);
    let kind = 'file', ext = '';
    const own = (el.textContent || '').trim().replace(/\s+/g, ' ');
    if (m) { ext = m[1].toLowerCase(); }
    else {
      if (!wantLinks || el.tagName !== 'A') return;
      if (!linkRe.test(own + ' ' + (el.getAttribute('title') || '')) && !linkRe.test(u.pathname)) return;
      kind = 'link'; ext = 'link';
    }
    if (once && kind === 'file' && seenExt.has(ext)) return;
    u.hash = '';
    const s = u.href;
    if (found.has(s)) return;
    seenExt.add(ext);
    const t = kind === 'link' ? (own || title || '').slice(0, 160) : ((title || '') + ' ' + own).trim().replace(/\s+/g, ' ').slice(0, 160);
    found.set(s, { t: t, k: kind });
  });
}
async function archiveItem(url, once) {
  try {
    const u = new URL(url, location.href);
    const mm = u.pathname.match(/^\/details\/([^\/?#]+)/);
    if (!mm || !u.hostname.endsWith('archive.org')) return false;
    const id = mm[1];
    const r = await fetch('https://' + u.hostname + '/metadata/' + encodeURIComponent(id), { credentials: 'include' });
    const j = await r.json();
    const title = (j.metadata && j.metadata.title) ? String(j.metadata.title) : id;
    const seenExt = new Set();
    (j.files || []).forEach(f => {
      const name = f.name || '';
      const m = re.exec('/' + name);
      if (!m) return;
      const ext = m[1].toLowerCase();
      if (once && seenExt.has(ext)) return;
      seenExt.add(ext);
      const s = 'https://' + u.hostname + '/download/' + encodeURIComponent(id) + '/' + name.split('/').map(encodeURIComponent).join('/');
      found.set(s, { t: title.slice(0, 160), k: 'file' });
    });
    return true;
  } catch (e) { return false; }
}
const origin = location.origin;
const skip = /\.(jpg|jpeg|png|gif|webp|svg|css|js|ico|mp3|mp4|woff2?|ttf|xml|json)$/i;
function pageLinks(doc, base, shadow) {
  const els = shadow ? allEls(doc, 'a[href]', []) : Array.from(doc.querySelectorAll('a[href]'));
  const out = [];
  els.forEach(a => {
    if (a.closest && a.closest('nav, header, footer')) return;
    try {
      const u = new URL(a.getAttribute('href'), base);
      u.hash = '';
      if (/^https?:$/.test(u.protocol) && u.origin === origin && !re.test(u.pathname + u.search) && !skip.test(u.pathname)) out.push(u.href);
    } catch (e) {}
  });
  return out;
}
grab(document, location.href, document.title, false, true);
await archiveItem(location.href, once);
if (depth > 0) {
  const seen = new Set([location.href.split('#')[0]]);
  let level = [];
  const add = (links, arr) => links.forEach(l => { if (!seen.has(l)) { seen.add(l); arr.push(l); } });
  add(pageLinks(document, location.href, true), level);
  let n = 0;
  for (let d = 1; d <= depth && level.length && n < maxPages; d++) {
    const nextLevel = [];
    while (level.length && n < maxPages) {
      const batch = level.splice(0, Math.min(4, maxPages - n));
      n += batch.length;
      window.__ykStatus = n + ' sayfa tarandi, ' + found.size + ' dosya bulundu';
      await Promise.all(batch.map(async next => {
        try {
          if (await archiveItem(next, once)) return;
          const doc = await getDoc(next);
          grab(doc, next, doc.title, once, false);
          if (d < depth) add(pageLinks(doc, next, false), nextLevel);
        } catch (e) {}
      }));
    }
    level = nextLevel;
  }
}
return Array.from(found.entries()).map(([u, o]) => ({ url: u, text: o.t, kind: o.k }));
''';

class CapturePage extends StatefulWidget {
  final InAppWebViewController controller;
  final String Function() getUrl;
  final void Function(String) onOpen;
  const CapturePage(
      {super.key, required this.controller, required this.getUrl, required this.onOpen});
  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  final Set<String> selFormats = {'epub', 'pdf'};
  final extraCtl = TextEditingController();
  final keyCtl = TextEditingController();
  int depth = 1;
  bool once = true;
  bool wantLinks = false;
  int maxPages = 100;
  Timer? poll;
  bool scanning = false;
  String msg = 'Format sec, sonra Yakala\'ya bas.';
  List<FileItem> items = [];

  void _upd() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    poll?.cancel();
    super.dispose();
  }

  Future<void> _scan() async {
    final exts = <String>{};
    for (final f in selFormats) {
      exts.addAll(formats[f]!);
    }
    for (final e in extraCtl.text.split(RegExp(r'[,\s]+'))) {
      final t = e.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (t.isNotEmpty) exts.add(t);
    }
    if (exts.isEmpty && !wantLinks) {
      setState(() => msg = 'En az bir format sec.');
      return;
    }
    setState(() {
      scanning = true;
      items = [];
      msg = 'Taraniyor, biraz surebilir...';
    });
    poll?.cancel();
    poll = Timer.periodic(const Duration(milliseconds: 1500), (_) async {
      try {
        final r = await widget.controller.evaluateJavascript(source: 'window.__ykStatus');
        final t = r?.toString() ?? '';
        if (mounted && scanning && t.isNotEmpty && t != 'null') setState(() => msg = t);
      } catch (_) {}
    });
    try {
      final res = await widget.controller.callAsyncJavaScript(
        functionBody: _scanJs,
        arguments: {
          'exts': exts.toList(),
          'depth': depth,
          'once': once,
          'maxPages': maxPages,
          'wantLinks': wantLinks,
        },
      );
      if (res?.error != null) throw res!.error!;
      final raw = (res?.value as List?) ?? [];
      final words = keyCtl.text
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty)
          .toList();
      final list = <FileItem>[];
      for (final m in raw) {
        final url = m['url'].toString();
        final text = (m['text'] ?? '').toString();
        final isLink = m['kind'] == 'link';
        String dec = url;
        try {
          dec = Uri.decodeFull(url);
        } catch (_) {}
        final hay = '$dec $text'.toLowerCase();
        if (!words.every((w) => hay.contains(w))) continue;
        var name = isLink ? (text.isNotEmpty ? text : nameOf(url)) : nameOf(url);
        if (!isLink) {
          for (final e in exts) {
            final mt = RegExp('\\.$e\\d*(?:\\.|\$)', caseSensitive: false).firstMatch(name);
            if (mt != null && !name.toLowerCase().endsWith('.$e')) {
              name = '${name.substring(0, mt.start)}.$e';
              break;
            }
          }
        }
        list.add(FileItem(url, name, text, isLink: isLink));
      }
      setState(() {
        items = list;
        msg = list.isEmpty ? 'Hicbir dosya bulunamadi.' : '${list.length} sonuc bulundu.';
      });
    } catch (e) {
      setState(() => msg = 'Tarama hatasi: $e');
    }
    poll?.cancel();
    if (mounted) setState(() => scanning = false);
  }

  Future<void> _downloadSelected() async {
    final sel = items.where((i) => i.selected && i.status != 'bitti').toList();
    if (sel.isEmpty) return;
    await Downloader.many(sel, widget.controller, widget.getUrl(), _upd);
    if (mounted) {
      final ok = sel.where((i) => i.status == 'bitti').length;
      setState(() => msg = 'Bitti: $ok/${sel.length} indirildi. Klasor: Download/Yakala');
    }
  }

  @override
  Widget build(BuildContext context) {
    final selCount = items.where((i) => i.selected).length;
    return Scaffold(
      appBar: AppBar(title: const Text('Yakala')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(
            spacing: 6,
            children: [
              ...formats.keys.map((f) => FilterChip(
                    label: Text(f),
                    selected: selFormats.contains(f),
                    onSelected: (v) =>
                        setState(() => v ? selFormats.add(f) : selFormats.remove(f)),
                  )),
              FilterChip(
                label: const Text('indirme baglantilari'),
                selected: wantLinks,
                onSelected: (v) => setState(() => wantLinks = v),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: extraCtl,
                decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    labelText: 'Diger uzantilar (fb2, lit)'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: keyCtl,
                decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    labelText: 'Kelime filtresi (chemistry)'),
              ),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 0, label: Text('Bu sayfa')),
                ButtonSegment(value: 1, label: Text('Kitap sayfalari')),
                ButtonSegment(value: 2, label: Text('Derin')),
              ],
              selected: {depth},
              onSelectionChanged: (s) => setState(() => depth = s.first),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Text(
            depth == 0
                ? 'Sadece ekrandaki sayfadaki baglantilar.'
                : depth == 1
                    ? 'Listedeki her kitabin sayfasina girip dosyalari bulur.'
                    : 'Kitap sayfalarina ve onlarin bagli sayfalarina da girer (yavas).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        if (depth > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              const Text('En fazla sayfa: '),
              DropdownButton<int>(
                value: maxPages,
                items: [30, 100, 300, 1000]
                    .map((n) => DropdownMenuItem(value: n, child: Text('$n')))
                    .toList(),
                onChanged: (v) => setState(() => maxPages = v ?? 100),
              ),
            ]),
          ),
        SwitchListTile(
          dense: true,
          title: const Text('Her kitaptan her formatin tek dosyasi'),
          value: once,
          onChanged: (v) => setState(() => once = v),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: scanning
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.search),
              label: const Text('Yakala'),
              onPressed: scanning ? null : _scan,
            ),
          ),
        ),
        Row(children: [
          Expanded(
              child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(msg, style: Theme.of(context).textTheme.bodySmall))),
          if (items.isNotEmpty)
            TextButton(
              onPressed: () => setState(() {
                final all = items.every((i) => i.selected);
                for (final i in items) {
                  i.selected = !all;
                }
              }),
              child: const Text('Hepsini sec/kaldir'),
            ),
        ]),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: items.length,
            itemBuilder: (_, k) {
              final it = items[k];
              return CheckboxListTile(
                dense: true,
                value: it.selected,
                onChanged: (v) => setState(() => it.selected = v ?? false),
                title: Text(it.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (it.text.isNotEmpty && it.text != it.name)
                    Text(it.text, maxLines: 1, overflow: TextOverflow.ellipsis),
                  if (it.status == 'indiriliyor')
                    LinearProgressIndicator(value: it.progress > 0 ? it.progress : null),
                  if (it.status == 'hata')
                    Text('Hata: ${it.error}',
                        maxLines: 3,
                        style: const TextStyle(color: Colors.red, fontSize: 12)),
                ]),
                secondary: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    tooltip: 'Tarayicida ac',
                    icon: const Icon(Icons.open_in_new),
                    onPressed: () {
                      widget.onOpen(it.url);
                      Navigator.pop(context);
                    },
                  ),
                  IconButton(
                    icon: Icon(it.status == 'bitti' ? Icons.check_circle : Icons.download),
                    color: it.status == 'bitti' ? Colors.green : null,
                    onPressed: it.status == 'indiriliyor'
                        ? null
                        : () => Downloader.download(it, widget.controller, widget.getUrl(), _upd),
                  ),
                ]),
              );
            },
          ),
        ),
        if (items.isNotEmpty)
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.download_for_offline),
                  label: Text('Secilenleri indir ($selCount)'),
                  onPressed: selCount == 0 ? null : _downloadSelected,
                ),
              ),
            ),
          ),
      ]),
    );
  }
}


// ---------- Forum: magnet / torrent toplama ----------
const String _topicJs = r"""
const origin = location.origin;
window.__ykStatus = '';
async function getDoc(url) {
  const r = await fetch(url, { credentials: 'include' });
  const buf = await r.arrayBuffer();
  let cs = ((r.headers.get('content-type') || '').match(/charset=([^;]+)/i) || [])[1];
  if (!cs) {
    const head = new TextDecoder('latin1').decode(buf.slice(0, 3000));
    const m = head.match(/charset=["']?([\w-]+)/i);
    cs = m ? m[1] : 'utf-8';
  }
  let txt;
  try { txt = new TextDecoder(cs.trim()).decode(buf); } catch (e) { txt = new TextDecoder('utf-8').decode(buf); }
  return new DOMParser().parseFromString(txt, 'text/html');
}
function topicLinks(doc, base) {
  const out = new Map();
  doc.querySelectorAll('a[href]').forEach(a => {
    if (a.closest && a.closest('nav, header, footer')) return;
    let u;
    try { u = new URL(a.getAttribute('href'), base); } catch (e) { return; }
    if (u.origin !== origin) return;
    if (!/viewtopic|showthread|topic|thread|\/t\//i.test(u.pathname + u.search)) return;
    if (u.searchParams.has('start')) return;
    u.hash = '';
    const txt = (a.textContent || '').trim().replace(/\s+/g, ' ');
    if (!txt || /^\d+$/.test(txt)) return;
    const key = u.searchParams.get('t') ? u.origin + u.pathname + '?t=' + u.searchParams.get('t') : u.href;
    if (!out.has(key) || out.get(key).length < txt.length) out.set(key, txt);
  });
  return out;
}
const here = new URL(location.href);
const topics = topicLinks(document, location.href);
const starts = [];
document.querySelectorAll('a[href]').forEach(a => {
  try {
    const u = new URL(a.getAttribute('href'), location.href);
    if (u.origin === origin && u.pathname === here.pathname) {
      const s = parseInt(u.searchParams.get('start') || '0');
      if (s > 0) starts.push(s);
    }
  } catch (e) {}
});
const step = starts.length ? Math.min.apply(null, starts) : 0;
const curStart = parseInt(here.searchParams.get('start') || '0');
if (listPages > 1 && step > 0) {
  for (let i = 1; i < listPages; i++) {
    const u = new URL(location.href);
    u.searchParams.set('start', curStart + step * i);
    window.__ykStatus = 'Liste sayfasi ' + (i + 1) + '/' + listPages;
    try {
      const doc = await getDoc(u.href);
      const m = topicLinks(doc, u.href);
      if (m.size === 0) break;
      m.forEach((v, k) => { if (!topics.has(k)) topics.set(k, v); });
    } catch (e) { break; }
  }
}
const list = Array.from(topics.entries())
  .filter(([k, t]) => words.every(w => t.toLowerCase().includes(w)))
  .slice(0, maxTopics);
const res = [];
let done = 0;
for (let i = 0; i < list.length; i += 4) {
  await Promise.all(list.slice(i, i + 4).map(async ([u, t]) => {
    try {
      const doc = await getDoc(u);
      const h1 = doc.querySelector('h1, #topic-title, .maintitle');
      const title = ((h1 && h1.textContent) || t || doc.title || '').trim().replace(/\s+/g, ' ');
      const body = doc.querySelector('.post_body, .post-body, .postbody, .message, article');
      const desc = (body ? body.textContent : '').replace(/[ \t]+/g, ' ').replace(/\n\s*\n+/g, '\n').trim().slice(0, 8000);
      const mags = new Set(), tors = new Set();
      doc.querySelectorAll('a[href]').forEach(a => {
        const h = a.getAttribute('href') || '';
        if (h.startsWith('magnet:')) { mags.add(h); return; }
        try {
          const x = new URL(h, u);
          if (x.origin === origin && (/\.torrent(\?|$)/i.test(x.pathname + x.search) || /dl\.php/i.test(x.pathname))) tors.add(x.href);
        } catch (e) {}
      });
      res.push({ url: u, title: title, desc: desc, magnets: Array.from(mags), torrents: Array.from(tors) });
    } catch (e) {}
    done++;
    window.__ykStatus = done + '/' + list.length + ' konu tarandi';
  }));
}
return res;
""";

class TopicItem {
  final String url;
  final String title;
  final String desc;
  final List<String> magnets;
  final List<String> torrents;
  bool selected;
  String status = '';
  String error = '';
  TopicItem(this.url, this.title, this.desc, this.magnets, this.torrents)
      : selected = magnets.isNotEmpty || torrents.isNotEmpty;
}

class TorrentPage extends StatefulWidget {
  final InAppWebViewController controller;
  final String Function() getUrl;
  const TorrentPage({super.key, required this.controller, required this.getUrl});
  @override
  State<TorrentPage> createState() => _TorrentPageState();
}

class _TorrentPageState extends State<TorrentPage> {
  int listPages = 1;
  int maxTopics = 100;
  final keyCtl = TextEditingController();
  Timer? poll;
  bool busy = false;
  String msg = 'Forum konu listesi acikken Tara\'ya bas.';
  List<TopicItem> items = [];

  @override
  void dispose() {
    poll?.cancel();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      busy = true;
      items = [];
      msg = 'Taraniyor, biraz surebilir...';
    });
    poll?.cancel();
    poll = Timer.periodic(const Duration(milliseconds: 1500), (_) async {
      try {
        final r = await widget.controller.evaluateJavascript(source: 'window.__ykStatus');
        final t = r?.toString() ?? '';
        if (mounted && busy && t.isNotEmpty && t != 'null') setState(() => msg = t);
      } catch (_) {}
    });
    try {
      final words = keyCtl.text
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty)
          .toList();
      final res = await widget.controller.callAsyncJavaScript(
        functionBody: _topicJs,
        arguments: {'listPages': listPages, 'maxTopics': maxTopics, 'words': words},
      );
      if (res?.error != null) throw res!.error!;
      final raw = (res?.value as List?) ?? [];
      final list = raw
          .map((m) => TopicItem(
                m['url'].toString(),
                m['title'].toString(),
                m['desc'].toString(),
                (m['magnets'] as List).map((e) => e.toString()).toList(),
                (m['torrents'] as List).map((e) => e.toString()).toList(),
              ))
          .toList();
      final withLinks = list.where((e) => e.magnets.isNotEmpty || e.torrents.isNotEmpty).length;
      setState(() {
        items = list;
        msg = list.isEmpty
            ? 'Konu bulunamadi.'
            : '${list.length} konu, ${withLinks} tanesinde magnet/torrent var.' +
                (withLinks == 0 ? ' (Giris yapman gerekebilir.)' : '');
      });
    } catch (e) {
      setState(() => msg = 'Tarama hatasi: $e');
    }
    poll?.cancel();
    if (mounted) setState(() => busy = false);
  }

  String _short(String t) {
    var c = Downloader.clean(t).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (c.length > 80) c = c.substring(0, 80).trim();
    while (c.endsWith('.')) {
      c = c.substring(0, c.length - 1);
    }
    return c.isEmpty ? 'konu' : c;
  }

  Future<void> _saveOne(TopicItem t) async {
    t.status = 'kaydediliyor';
    t.error = '';
    if (mounted) setState(() {});
    try {
      final base = await Downloader.dir();
      final id = Uri.tryParse(t.url)?.queryParameters['t'] ?? '';
      final name = id.isEmpty ? _short(t.title) : '${_short(t.title)} [$id]';
      var folder = Directory('${base.path}/Torrent/$name');
      var k = 1;
      while (folder.existsSync()) {
        k++;
        folder = Directory('${base.path}/Torrent/$name ($k)');
      }
      await folder.create(recursive: true);
      await File('${folder.path}/aciklama.txt').writeAsString(
          'Baslik: ${t.title}\nSayfa: ${t.url}\n\nAciklama:\n${t.desc}\n');
      for (var i = 0; i < t.magnets.length; i++) {
        final n = t.magnets.length == 1 ? 'magnet.txt' : 'magnet_${i + 1}.txt';
        await File('${folder.path}/$n').writeAsString('${t.magnets[i]}\n');
      }
      final errs = <String>[];
      for (var i = 0; i < t.torrents.length; i++) {
        final fn = t.torrents.length == 1 ? '${_short(t.title)}.torrent' : '${_short(t.title)}_${i + 1}.torrent';
        final it = FileItem(t.torrents[i], fn, '');
        await Downloader.download(it, widget.controller, widget.getUrl(), () {}, into: folder);
        if (it.status != 'bitti') errs.add(it.error);
      }
      t.status = errs.isEmpty ? 'bitti' : 'hata';
      t.error = errs.isEmpty ? '' : 'torrent inmedi: ${errs.first} (magnet ve aciklama kaydedildi)';
    } catch (e) {
      t.status = 'hata';
      t.error = e.toString();
    }
    if (mounted) setState(() {});
  }

  Future<void> _saveSelected() async {
    final sel = items.where((i) => i.selected && i.status != 'bitti').toList();
    for (final t in sel) {
      await _saveOne(t);
    }
    if (mounted) {
      final ok = sel.where((i) => i.status == 'bitti').length;
      setState(() => msg = 'Bitti: $ok/${sel.length} konu kaydedildi. Klasor: Download/Yakala/Torrent');
    }
  }

  @override
  Widget build(BuildContext context) {
    final selCount = items.where((i) => i.selected).length;
    return Scaffold(
      appBar: AppBar(title: const Text('Magnet / Torrent')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(children: [
            const Text('Liste sayfasi: '),
            DropdownButton<int>(
              value: listPages,
              items: [1, 2, 3, 5, 10, 30]
                  .map((n) => DropdownMenuItem(value: n, child: Text('$n')))
                  .toList(),
              onChanged: (v) => setState(() => listPages = v ?? 1),
            ),
            const SizedBox(width: 16),
            const Text('Konu: '),
            DropdownButton<int>(
              value: maxTopics,
              items: [30, 100, 300, 1000]
                  .map((n) => DropdownMenuItem(value: n, child: Text('$n')))
                  .toList(),
              onChanged: (v) => setState(() => maxTopics = v ?? 100),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: TextField(
            controller: keyCtl,
            decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                labelText: 'Baslikta kelime filtresi (istege bagli)'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: busy
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.search),
              label: const Text('Tara'),
              onPressed: busy ? null : _scan,
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(msg, style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: items.length,
            itemBuilder: (_, k) {
              final t = items[k];
              final has = t.magnets.isNotEmpty || t.torrents.isNotEmpty;
              return CheckboxListTile(
                dense: true,
                value: t.selected,
                onChanged: has ? (v) => setState(() => t.selected = v ?? false) : null,
                title: Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${t.magnets.length} magnet, ${t.torrents.length} torrent'),
                  if (t.status == 'kaydediliyor') const LinearProgressIndicator(),
                  if (t.status == 'bitti')
                    const Text('Kaydedildi', style: TextStyle(color: Colors.green)),
                  if (t.status == 'hata')
                    Text(t.error,
                        maxLines: 3, style: const TextStyle(color: Colors.red, fontSize: 12)),
                ]),
              );
            },
          ),
        ),
        if (items.isNotEmpty)
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.save_alt),
                  label: Text('Secilenleri klasore kaydet ($selCount)'),
                  onPressed: selCount == 0 ? null : _saveSelected,
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

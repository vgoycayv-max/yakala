import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const YakalaApp());

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
  bool selected = true;
  double progress = 0;
  String status = ''; // '', indiriliyor, bitti, hata
  FileItem(this.url, this.name, this.text);
}

class Downloader {
  static final Dio _dio = Dio();
  static Directory? _dir;

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

  static Future<void> download(FileItem it, InAppWebViewController? c,
      String referer, VoidCallback onUpdate) async {
    it.status = 'indiriliyor';
    onUpdate();
    try {
      final d = await dir();
      var path = '${d.path}/${clean(it.name)}';
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
      final cookies =
          await CookieManager.instance().getCookies(url: WebUri(it.url));
      final cookie = cookies.map((e) => '${e.name}=${e.value}').join('; ');
      String ua = '';
      if (c != null) {
        final r = await c.evaluateJavascript(source: 'navigator.userAgent');
        ua = r?.toString() ?? '';
      }
      final headers = <String, String>{};
      if (cookie.isNotEmpty) headers['Cookie'] = cookie;
      if (ua.isNotEmpty) headers['User-Agent'] = ua;
      if (referer.isNotEmpty) headers['Referer'] = referer;
      await _dio.download(it.url, path,
          options: Options(headers: headers, followRedirects: true),
          onReceiveProgress: (r, t) {
        if (t > 0) {
          it.progress = r / t;
          onUpdate();
        }
      });
      it.progress = 1;
      it.status = 'bitti';
    } catch (e) {
      it.status = 'hata';
    }
    onUpdate();
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

    await Future.wait(List.generate(3, (_) => worker()));
  }
}

// ---------- Tarayici ----------
class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key});
  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  InAppWebViewController? controller;
  final urlCtl = TextEditingController(text: 'https://archive.org');
  String currentUrl = '';
  double progress = 0;

  static const sites = {
    'bdebooks': 'https://bdebooks.com/',
    'Archive.org': 'https://archive.org/',
    'Gutenberg': 'https://www.gutenberg.org/',
  };

  void _go(String text) {
    var t = text.trim();
    if (t.isEmpty) return;
    if (!t.startsWith('http')) {
      t = t.contains('.') && !t.contains(' ')
          ? 'https://$t'
          : 'https://www.google.com/search?q=${Uri.encodeComponent(t)}';
    }
    controller?.loadUrl(urlRequest: URLRequest(url: WebUri(t)));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (controller != null && await controller!.canGoBack()) {
          controller!.goBack();
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(children: [
            Row(children: [
              IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => controller?.goBack()),
              Expanded(
                child: TextField(
                  controller: urlCtl,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  onSubmitted: _go,
                  decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      hintText: 'Adres veya arama'),
                ),
              ),
              IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: () => controller?.reload()),
            ]),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                children: sites.entries
                    .map((e) => Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ActionChip(
                              label: Text(e.key),
                              onPressed: () {
                                urlCtl.text = e.value;
                                _go(e.value);
                              }),
                        ))
                    .toList(),
              ),
            ),
            if (progress < 1) LinearProgressIndicator(value: progress),
            Expanded(
              child: InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(urlCtl.text)),
                initialSettings: InAppWebViewSettings(
                  javaScriptEnabled: true,
                  domStorageEnabled: true,
                  useOnDownloadStart: true,
                  thirdPartyCookiesEnabled: true,
                  supportZoom: true,
                ),
                onWebViewCreated: (c) => controller = c,
                onProgressChanged: (c, p) => setState(() => progress = p / 100),
                onLoadStop: (c, url) {
                  currentUrl = url?.toString() ?? '';
                  urlCtl.text = currentUrl;
                },
                onUpdateVisitedHistory: (c, url, _) {
                  currentUrl = url?.toString() ?? currentUrl;
                  urlCtl.text = currentUrl;
                },
                onDownloadStartRequest: (c, req) async {
                  final u = req.url.toString();
                  var name = req.suggestedFilename ?? '';
                  if (name.isEmpty) name = nameOf(u);
                  final it = FileItem(u, name, '');
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Indiriliyor: $name')));
                  await Downloader.download(it, c, currentUrl, () {});
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(it.status == 'bitti'
                          ? 'Bitti: $name'
                          : 'Hata: $name')));
                },
              ),
            ),
          ]),
        ),
        floatingActionButton: FloatingActionButton.extended(
          icon: const Icon(Icons.download_for_offline),
          label: const Text('Yakala'),
          onPressed: () {
            if (controller == null) return;
            Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => CapturePage(
                        controller: controller!, getUrl: () => currentUrl)));
          },
        ),
      ),
    );
  }
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

// ---------- Yakala sayfasi ----------
const String _scanJs = r'''
const re = new RegExp('\\.(' + exts.join('|') + ')\\d*(?:[.?#]|$)', 'i');
const found = new Map();
function grab(doc, base) {
  doc.querySelectorAll('a[href], source[src], embed[src], link[href]').forEach(el => {
    const raw = el.getAttribute('href') || el.getAttribute('src');
    if (!raw) return;
    let u;
    try { u = new URL(raw, base); } catch (e) { return; }
    if (!re.test(u.pathname + u.search)) return;
    u.hash = '';
    const s = u.href;
    const t = (el.textContent || el.getAttribute('title') || '').trim().replace(/\s+/g, ' ').slice(0, 120);
    if (!found.has(s) || (!found.get(s) && t)) found.set(s, t);
  });
}
grab(document, location.href);
if (deep) {
  const origin = location.origin;
  const seen = new Set([location.href.split('#')[0]]);
  const queue = [];
  const skip = /\.(jpg|jpeg|png|gif|webp|svg|css|js|ico|mp3|mp4|woff2?|ttf)$/i;
  const addLinks = (doc, base) => {
    doc.querySelectorAll('a[href]').forEach(a => {
      try {
        const u = new URL(a.getAttribute('href'), base);
        u.hash = '';
        if (u.origin === origin && !re.test(u.pathname + u.search) && !skip.test(u.pathname)) {
          const s = u.href;
          if (!seen.has(s)) { seen.add(s); queue.push(s); }
        }
      } catch (e) {}
    });
  };
  addLinks(document, location.href);
  let n = 0;
  while (queue.length && n < maxPages) {
    const batch = queue.splice(0, Math.min(4, maxPages - n));
    n += batch.length;
    await Promise.all(batch.map(async next => {
      try {
        const r = await fetch(next, { credentials: 'include' });
        const ct = r.headers.get('content-type') || '';
        if (!ct.includes('text/html')) return;
        const html = await r.text();
        const doc = new DOMParser().parseFromString(html, 'text/html');
        grab(doc, next);
        addLinks(doc, next);
      } catch (e) {}
    }));
  }
}
return Array.from(found.entries()).map(([u, t]) => ({ url: u, text: t }));
''';

class CapturePage extends StatefulWidget {
  final InAppWebViewController controller;
  final String Function() getUrl;
  const CapturePage({super.key, required this.controller, required this.getUrl});
  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  final Set<String> selFormats = {'epub', 'pdf'};
  final extraCtl = TextEditingController();
  final keyCtl = TextEditingController();
  bool deep = false;
  int maxPages = 30;
  bool scanning = false;
  String msg = 'Format sec, sonra Yakala\'ya bas.';
  List<FileItem> items = [];

  void _upd() {
    if (mounted) setState(() {});
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
    if (exts.isEmpty) {
      setState(() => msg = 'En az bir format sec.');
      return;
    }
    setState(() {
      scanning = true;
      items = [];
      msg = deep ? 'Site taraniyor, biraz surebilir...' : 'Sayfa taraniyor...';
    });
    try {
      final res = await widget.controller.callAsyncJavaScript(
        functionBody: _scanJs,
        arguments: {'exts': exts.toList(), 'deep': deep, 'maxPages': maxPages},
      );
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
        String dec = url;
        try {
          dec = Uri.decodeFull(url);
        } catch (_) {}
        final hay = '$dec $text'.toLowerCase();
        if (!words.every((w) => hay.contains(w))) continue;
        var name = nameOf(url);
        for (final e in exts) {
          final mt = RegExp('\\.$e\\d*(?:\\.|\$)', caseSensitive: false)
              .firstMatch(name);
          if (mt != null && !name.toLowerCase().endsWith('.$e')) {
            name = '${name.substring(0, mt.start)}.$e';
            break;
          }
        }
        list.add(FileItem(url, name, text));
      }
      setState(() {
        items = list;
        msg = list.isEmpty ? 'Hicbir dosya bulunamadi.' : '${list.length} dosya bulundu.';
      });
    } catch (e) {
      setState(() => msg = 'Tarama hatasi: $e');
    }
    setState(() => scanning = false);
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
            children: formats.keys
                .map((f) => FilterChip(
                      label: Text(f),
                      selected: selFormats.contains(f),
                      onSelected: (v) => setState(
                          () => v ? selFormats.add(f) : selFormats.remove(f)),
                    ))
                .toList(),
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
        SwitchListTile(
          dense: true,
          title: const Text('Tum siteyi tara (sayfa sayfa gez)'),
          value: deep,
          onChanged: (v) => setState(() => deep = v),
        ),
        if (deep)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              const Text('En fazla sayfa: '),
              DropdownButton<int>(
                value: maxPages,
                items: [10, 30, 100, 300]
                    .map((n) => DropdownMenuItem(value: n, child: Text('$n')))
                    .toList(),
                onChanged: (v) => setState(() => maxPages = v ?? 30),
              ),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: scanning
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
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
                    const Text('Hata', style: TextStyle(color: Colors.red)),
                ]),
                secondary: IconButton(
                  icon: Icon(it.status == 'bitti' ? Icons.check_circle : Icons.download),
                  color: it.status == 'bitti' ? Colors.green : null,
                  onPressed: it.status == 'indiriliyor'
                      ? null
                      : () => Downloader.download(it, widget.controller, widget.getUrl(), _upd),
                ),
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

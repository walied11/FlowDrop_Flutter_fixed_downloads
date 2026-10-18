import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/utils.dart';
import 'cobalt_service.dart';

/// مستخرِج الروابط المدمج (منقول من MainActivity.java).
/// يعمل بدون Cobalt وبدون مفتاح API: يجلب صفحة المنصة أو يستعمل واجهات
/// خارجية (tikwm / mobifb / snapfb) ويُرجع رابط ملف الفيديو المباشر.
class NativeExtractor {
  static const String _ua =
      'Mozilla/5.0 (Linux; Android 13; SM-G991B) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36';

  static const Map<String, String> _headers = {
    'User-Agent': _ua,
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'en-US,en;q=0.9,ar;q=0.8',
    'sec-ch-ua': '"Chromium";v="124", "Google Chrome";v="124"',
    'sec-ch-ua-mobile': '?1',
    'sec-ch-ua-platform': '"Android"',
    'Sec-Fetch-Dest': 'document',
    'Sec-Fetch-Mode': 'navigate',
    'Sec-Fetch-Site': 'none',
    'Upgrade-Insecure-Requests': '1',
  };

  /// يُرجع null إذا فشل الاستخراج.
  static Future<CobaltResult?> resolve(String url) async {
    String? direct;
    try {
      direct = await _extract(url.trim());
    } catch (_) {
      direct = null;
    }
    if (direct == null || direct.isEmpty || !direct.startsWith('http')) return null;
    return CobaltResult(
      isPicker: false,
      native: true,
      items: [CobaltPickerItem(url: direct, type: 'video')],
    );
  }

  static Future<String?> _extract(String url) async {
    switch (platformOf(url)) {
      case 'facebook':
        return _facebook(url);
      case 'tiktok':
        return _tiktok(url);
      case 'youtube':
        return _youtube(url);
      case 'reddit':
        return _reddit(url);
      case 'x':
      case 'instagram':
      case 'threads':
      case 'pinterest':
      case 'snapchat':
        return ogVideo(await _fetchHtml(url));
      default:
        return null;
    }
  }

  // ───────────────────────── شبكة ─────────────────────────

  static Future<String> _fetchHtml(String url, {int timeoutSec = 15}) async {
    try {
      final res = await http
          .get(Uri.parse(url), headers: _headers)
          .timeout(Duration(seconds: timeoutSec));
      return utf8.decode(res.bodyBytes, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  /// يتتبع التحويلات يدويًا ويُرجع آخر رابط.
  static Future<String> _followRedirects(String url, {int maxHops = 10}) async {
    var current = url;
    final client = http.Client();
    try {
      for (var i = 0; i < maxHops; i++) {
        final req = http.Request('GET', Uri.parse(current))
          ..followRedirects = false
          ..headers.addAll(_headers);
        final res = await client.send(req).timeout(const Duration(seconds: 10));
        await res.stream.drain();
        final code = res.statusCode;
        if (code == 301 || code == 302 || code == 303 || code == 307 || code == 308) {
          var loc = res.headers['location'];
          if (loc == null || loc.isEmpty) break;
          if (loc.startsWith('/')) {
            final u = Uri.parse(current);
            loc = '${u.scheme}://${u.host}$loc';
          }
          current = loc;
        } else {
          break;
        }
      }
    } catch (_) {
      // نكتفي بآخر رابط وصلنا إليه.
    } finally {
      client.close();
    }
    return current;
  }

  // ───────────────────────── Facebook ─────────────────────────

  static Future<String?> _facebook(String raw) async {
    var url = raw;
    if (url.contains('/share/') || url.contains('fb.watch')) {
      var resolved = await _followRedirects(url);
      resolved = resolved.split('?').first;
      final m = RegExp(r'facebook\.com/(reel|videos|watch|story|photo\.php)/[^/?]+')
          .firstMatch(resolved);
      url = m != null ? 'https://www.facebook.com/${m.group(0)!.replaceFirst('facebook.com/', '')}' : resolved;
    }

    // 1) من صفحة الفيديو مباشرة
    final html = await _fetchHtml(url);
    final fromPage = _bestFacebookUrl(html);
    if (fromPage != null) return fromPage;

    // 2) واجهات خارجية
    final enc = Uri.encodeComponent(url);
    var json = await _fetchHtml('https://mobifb.org/api/convert?url=$enc', timeoutSec: 12);
    for (final k in const ['hd', 'sd', 'url']) {
      final v = jsonKey(json, k);
      if (v != null && v.startsWith('http')) return v;
    }
    json = await _fetchHtml('https://api.snapfb.com/api/convert?url=$enc', timeoutSec: 12);
    final v2 = jsonKey(json, 'url');
    if (v2 != null && v2.startsWith('http')) return v2;

    // 3) tikwm كحل أخير
    json = await _fetchHtml('https://www.tikwm.com/api/?url=$enc&hd=1', timeoutSec: 12);
    final v3 = jsonKey(json, 'hdplay');
    if (v3 != null && v3.startsWith('http')) return v3;
    return null;
  }

  static String? _bestFacebookUrl(String html) {
    if (html.isEmpty) return null;
    final clean = html
        .replaceAll(r'\/', '/')
        .replaceAll(r'\u0026', '&')
        .replaceAll(r'\u0025', '%')
        .replaceAll('&amp;', '&');
    for (final key in const [
      'browser_native_hd_url',
      'playable_url_quality_hd',
      'hd_src',
      'browser_native_sd_url',
      'playable_url',
      'sd_src',
    ]) {
      final m = RegExp('"$key"\\s*:\\s*"(https:[^"]+)"').firstMatch(clean);
      if (m != null) return m.group(1);
    }
    return findMp4(clean) ?? ogVideo(clean);
  }

  /// منقولة من findMp4 في Java: تبحث عن أول رابط .mp4 وتفضّل HD.
  static String? findMp4(String html) {
    if (html.isEmpty) return null;
    String? best;
    String? bestHd;
    var from = 0;
    while (true) {
      final idx = html.indexOf('.mp4', from);
      if (idx < 0) break;
      final hIdx = html.lastIndexOf('https://', idx);
      if (hIdx >= 0 && idx - hIdx < 800) {
        var en = idx + 4;
        while (en < html.length) {
          final ch = html[en];
          if (ch == '"' || ch == "'" || ch == ')' || ch == '<' || ch == ' ' || ch == '\n') break;
          en++;
        }
        final cand = html.substring(hIdx, en).replaceAll('&amp;', '&');
        if (cand.startsWith('https://') && cand.contains('.mp4')) {
          final is1080 = cand.contains('1080') || cand.contains('fhd');
          final isHd = is1080 ||
              cand.contains('720') ||
              cand.contains('hd') ||
              cand.contains('high') ||
              cand.contains('HD');
          if (is1080) return cand;
          if (isHd && bestHd == null) bestHd = cand;
          best ??= cand;
        }
      }
      from = idx + 4;
    }
    return bestHd ?? best;
  }

  // ───────────────────────── TikTok ─────────────────────────

  static Future<String?> _tiktok(String url) async {
    final enc = Uri.encodeComponent(url);
    final json = await _fetchHtml('https://www.tikwm.com/api/?url=$enc&hd=1', timeoutSec: 14);
    for (final k in const ['hdplay', 'play']) {
      final v = jsonKey(json, k);
      if (v != null && v.isNotEmpty) return _normalizeTik(v);
    }
    return null;
  }

  static String _normalizeTik(String v) {
    if (v.startsWith('http')) return v;
    if (v.startsWith('//')) return 'https:$v';
    if (v.startsWith('/')) return 'https://www.tikwm.com$v';
    return v;
  }

  // ───────────────────────── YouTube ─────────────────────────

  static String? _youtubeId(String url) {
    for (final p in [
      RegExp(r'youtu\.be/([a-zA-Z0-9_-]{6,})'),
      RegExp(r'[?&]v=([a-zA-Z0-9_-]{6,})'),
      RegExp(r'/shorts/([a-zA-Z0-9_-]{6,})'),
    ]) {
      final m = p.firstMatch(url);
      if (m != null) return m.group(1);
    }
    return null;
  }

  static Future<String?> _youtube(String url) async {
    final vid = _youtubeId(url);
    if (vid == null) return null;
    final html = await _fetchHtml('https://www.youtube.com/watch?v=$vid&hl=en&has_verified=1');
    final player = _between(html, 'ytInitialPlayerResponse = ', '</script>');
    if (player == null) return null;
    try {
      final data = jsonDecode(player) as Map<String, dynamic>;
      final sd = data['streamingData'];
      if (sd is! Map) return null;
      for (final key in const ['formats', 'adaptiveFormats']) {
        final list = sd[key];
        if (list is! List) continue;
        for (final f in list) {
          if (f is! Map) continue;
          final mime = (f['mimeType'] ?? '').toString();
          final u = (f['url'] ?? '').toString();
          if (mime.startsWith('video') && u.contains('googlevideo.com')) return u;
        }
      }
    } catch (_) {}
    return null;
  }

  static String? _between(String text, String start, String end) {
    final s = text.indexOf(start);
    if (s < 0) return null;
    final from = s + start.length;
    final e = text.indexOf(end, from);
    if (e < 0) return null;
    var chunk = text.substring(from, e).trim();
    if (chunk.endsWith(';')) chunk = chunk.substring(0, chunk.length - 1);
    return chunk;
  }

  // ───────────────────────── Reddit ─────────────────────────

  static Future<String?> _reddit(String url) async {
    var clean = url.split('?').first;
    if (!clean.endsWith('.json')) clean = '$clean.json';
    final json = await _fetchHtml(clean, timeoutSec: 12);
    final fb = jsonKey(json, 'fallback_url');
    if (fb != null && fb.startsWith('http')) return fb.replaceAll('&amp;', '&');
    final od = jsonKey(json, 'url_overridden_by_dest');
    if (od != null && (od.endsWith('.mp4') || od.contains('v.redd.it'))) return od;
    return ogVideo(await _fetchHtml(url));
  }

  // ───────────────────────── أدوات ─────────────────────────

  static String? ogVideo(String html) {
    if (html.isEmpty) return null;
    final h = html.replaceAll('&amp;', '&');
    for (final marker in const [
      'property="og:video:secure_url" content="',
      'property="og:video" content="',
      'property="og:video:url" content="',
    ]) {
      final idx = h.indexOf(marker);
      if (idx >= 0) {
        final s = idx + marker.length;
        final e = h.indexOf('"', s);
        if (e > s) return h.substring(s, e);
      }
    }
    return null;
  }

  /// منقولة من extractJson في Java (استخراج قيمة مفتاح بدون تحليل كامل).
  static String? jsonKey(String json, String key) {
    if (json.isEmpty) return null;
    final pat = '"$key"';
    final idx = json.indexOf(pat);
    if (idx < 0) return null;
    final colon = json.indexOf(':', idx + pat.length);
    if (colon < 0) return null;
    var i = colon + 1;
    while (i < json.length && (json[i] == ' ' || json[i] == '\n')) {
      i++;
    }
    final quoted = i < json.length && json[i] == '"';
    if (quoted) i++;
    final start = i;
    var end = start;
    if (quoted) {
      end = json.indexOf('"', start);
    } else {
      while (end < json.length && json[end] != ',' && json[end] != '}' && json[end] != ']') {
        end++;
      }
    }
    if (end < start) return null;
    return json.substring(start, end).replaceAll(r'\/', '/').replaceAll(r'\u0026', '&').trim();
  }
}

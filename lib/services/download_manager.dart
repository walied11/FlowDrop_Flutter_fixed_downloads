import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../core/utils.dart';
import '../models/download_item.dart';
import 'history_store.dart';
import 'native_bridge.dart';
import 'settings_store.dart';

class DownloadEvent {
  final bool success;
  final String name;
  final bool exported;
  const DownloadEvent({required this.success, required this.name, this.exported = false});
}

/// مدير التحميلات: تحميل متدفق إلى ملف .part مع إيقاف مؤقت/استئناف (Range) وإلغاء.
class DownloadManager extends ChangeNotifier {
  DownloadManager._();
  static final DownloadManager instance = DownloadManager._();

  static const int maxActive = 3;
  static const String _ua =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/124.0 Mobile Safari/537.36';

  late AppSettings settings;

  final List<DownloadItem> active = [];
  int doneCounter = 0;

  final StreamController<DownloadEvent> _events = StreamController<DownloadEvent>.broadcast();
  Stream<DownloadEvent> get events => _events.stream;

  final Map<int, http.Client> _clients = {};
  final Stopwatch _clock = Stopwatch()..start();
  int _lastNotifyMs = 0;

  bool get canStart => active.length < maxActive;

  /// مجلد التحميلات الخاص بالتطبيق (يظهر في تبويب الملفات).
  Future<Directory> downloadsDir() async {
    Directory? base;
    try {
      base = await getExternalStorageDirectory();
    } catch (_) {}
    base ??= await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/FlowDrop');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<DownloadItem> start({
    required String directUrl,
    required String sourceUrl,
    required bool isAudio,
    required String quality,
    String? suggestedName,
  }) async {
    var id = DateTime.now().millisecondsSinceEpoch;
    while (active.any((e) => e.id == id)) {
      id++;
    }
    final platform = platformOf(sourceUrl);

    String? ext = (suggestedName != null ? extensionOf(suggestedName) : null) ??
        extensionOf(Uri.tryParse(directUrl)?.path ?? '');
    ext ??= isAudio ? 'mp3' : 'mp4';
    if (isAudio && !isAudioExt(ext)) ext = 'mp3';

    final stem = suggestedName != null && suggestedName.trim().isNotEmpty
        ? sanitizeFileName(stripExtension(suggestedName))
        : 'FlowDrop_${platform}_${isAudio ? 'audio' : quality}_$id';

    final dir = await downloadsDir();
    final item = DownloadItem(
      id: id,
      sourceUrl: sourceUrl,
      directUrl: directUrl,
      stem: stem,
      ext: ext,
      isAudio: isAudio,
      platform: platform,
      partPath: '${dir.path}/$id.part',
    );
    active.add(item);
    notifyListeners();
    unawaited(_run(item));
    return item;
  }

  void pause(DownloadItem it) {
    if (it.status != DownloadStatus.downloading) return;
    it.pauseRequested = true;
    _clients[it.id]?.close();
  }

  void resume(DownloadItem it) {
    if (it.status == DownloadStatus.downloading) return;
    it.pauseRequested = false;
    it.error = null;
    it.status = DownloadStatus.downloading;
    notifyListeners();
    unawaited(_run(it));
  }

  Future<void> cancel(DownloadItem it) async {
    it.cancelRequested = true;
    _clients[it.id]?.close();
    if (it.status != DownloadStatus.downloading) {
      // لا توجد مهمة نشطة، نحذف مباشرة.
      await _discard(it);
    }
  }

  Future<void> _discard(DownloadItem it) async {
    try {
      final f = File(it.partPath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    active.remove(it);
    _clients.remove(it.id);
    notifyListeners();
  }

  void _notifyThrottled() {
    final now = _clock.elapsedMilliseconds;
    if (now - _lastNotifyMs >= 250) {
      _lastNotifyMs = now;
      notifyListeners();
    }
  }

  Future<void> _run(DownloadItem it) async {
    final client = http.Client();
    _clients[it.id] = client;
    IOSink? sink;
    try {
      final part = File(it.partPath);
      var start = await part.exists() ? await part.length() : 0;

      final req = http.Request('GET', Uri.parse(it.directUrl));
      req.headers['User-Agent'] = _ua;
      req.headers['Accept'] = '*/*';
      if (start > 0) req.headers['Range'] = 'bytes=$start-';

      final res = await client.send(req).timeout(const Duration(seconds: 20));

      if (res.statusCode == 416 && start > 0) {
        // الملف مكتمل بالفعل على الجهاز.
        await _finalize(it);
        return;
      }
      if (res.statusCode >= 400) {
        throw HttpException('HTTP ${res.statusCode}');
      }

      final resumed = res.statusCode == 206;
      final len = res.contentLength ?? -1;
      if (!resumed && start > 0) {
        start = 0;
        if (await part.exists()) await part.delete();
      }
      it.downloaded = start;
      it.total = len > 0 ? (resumed ? start + len : len) : -1;

      sink = part.openWrite(mode: resumed ? FileMode.append : FileMode.write);
      var stopped = false;
      await for (final chunk in res.stream.timeout(const Duration(seconds: 30))) {
        if (it.cancelRequested || it.pauseRequested) {
          stopped = true;
          break;
        }
        sink.add(chunk);
        it.downloaded += chunk.length;
        _notifyThrottled();
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (it.cancelRequested) {
        await _discard(it);
        return;
      }
      if (stopped || it.pauseRequested) {
        it.status = DownloadStatus.paused;
        notifyListeners();
        return;
      }
      await _finalize(it);
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      if (it.cancelRequested) {
        await _discard(it);
      } else if (it.pauseRequested) {
        // أُغلق الاتصال عمدًا للإيقاف المؤقت.
        it.status = DownloadStatus.paused;
        notifyListeners();
      } else {
        it.status = DownloadStatus.failed;
        it.error = e.toString();
        notifyListeners();
        _events.add(DownloadEvent(success: false, name: it.fileName));
      }
    } finally {
      _clients.remove(it.id)?.close();
    }
  }

  Future<void> _finalize(DownloadItem it) async {
    final part = File(it.partPath);
    final dir = part.parent;

    var name = it.fileName;
    var target = File('${dir.path}/$name');
    var n = 1;
    while (await target.exists()) {
      name = '${it.stem}_$n.${it.ext}';
      target = File('${dir.path}/$name');
      n++;
    }
    await part.rename(target.path);
    final size = await target.length();

    var exported = false;
    if (settings.autoSave) {
      exported = await NativeBridge.instance.saveToDownloads(target.path, name, mimeForExt(it.ext));
    }

    await HistoryStore.instance.add(HistoryEntry(
      id: it.id,
      fileName: name,
      sourceUrl: it.sourceUrl,
      filePath: target.path,
      platform: it.platform,
      isAudio: it.isAudio,
      sizeBytes: size,
      dateMs: DateTime.now().millisecondsSinceEpoch,
    ));

    active.remove(it);
    doneCounter++;
    notifyListeners();
    _events.add(DownloadEvent(success: true, name: name, exported: exported));
  }
}

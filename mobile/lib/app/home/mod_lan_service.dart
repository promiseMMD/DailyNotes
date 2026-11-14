// Moodiary 3.0 LAN workspace W1 — read-only authenticated transport milestone.
// No writes are exposed until Tiptap-compatible edit operations and the
// month/block revision model are available; this is intentional P0 protection.
// HTTP on trusted WLAN is NOT encrypted; pairing cannot prevent interception.
import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:moodiary_data/moodiary_data.dart';
import 'package:moodiary_di/moodiary_di.dart';
import 'package:moodiary_files/moodiary_files.dart';
import 'package:moodiary_models/moodiary_models.dart';

import 'mod_continuous.dart' show ModDiary;
import 'mod_monthly_index.dart';
import 'mod_lan_events.dart';
import 'mod_lan_write.dart';
import 'mod_month_store.dart';
import 'mod_lan_month_http.dart';
import 'mod_month_updates.dart';
import 'mod_lan_image_staging.dart';
import 'mod_lan_image_decoder.dart';
import 'mod_lan_image_policy.dart';
import 'mod_lan_image_attach.dart';
import 'mod_lan_rich.dart';

String modLanRandomHex([int bytes = 24]) {
  final random = Random.secure();
  return List<int>.generate(bytes, (_) => random.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class ModLanPairingRequest {
  final String id;
  final String code;
  final String address;
  final String userAgent;
  final DateTime expiresAt;
  const ModLanPairingRequest({required this.id, required this.code,
    required this.address, required this.userAgent, required this.expiresAt});
}

class _PairState {
  final ModLanPairingRequest request;
  bool approved = false;
  bool rejected = false;
  _LanSession? granted;
  _PairState(this.request);
}

class _LanSession {
  final String id;
  final String csrf;
  final DateTime created;
  DateTime active;
  _LanSession(this.id, this.csrf, DateTime now)
    : created = now, active = now;

  bool expired(DateTime now) =>
      now.difference(created) > const Duration(hours: 12) ||
      now.difference(active) > const Duration(minutes: 45);
}

class ModLanPolicy {
  static bool isWlanInterfaceName(String name) {
    final lower = name.toLowerCase();
    return lower.startsWith('wlan') || lower.startsWith('wifi');
  }

  static bool isPrivateIPv4(String text) {
    final parts = text.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((v) => v == null || v < 0 || v > 255)) {
      return false;
    }
    final a = parts[0]!;
    final b = parts[1]!;
    return a == 10 || (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168);
  }

  static bool validSameOrigin({required String host, required String? origin,
    required String authority, required bool mutation}) {
    if (host != authority) return false;
    if (!mutation) return origin == null || origin == 'http://$authority';
    return origin == 'http://$authority';
  }
}

/// Runs on the same Flutter engine as DiaryRepository. A native foreground
/// service retains the process during ordinary lock-screen use; this is NOT
/// a claim of survival after a system force-stop or engine termination.
class ModLanServer {
  ModLanServer._();
  static final instance = ModLanServer._();
  static const _serviceChannel = MethodChannel('moodiary.mod/lan_foreground');
  static const int _port = 11220;

  final ValueNotifier<bool> running = ValueNotifier(false);
  final ValueNotifier<ModLanPairingRequest?> pendingPair = ValueNotifier(null);
  final ValueNotifier<int> connections = ValueNotifier(0);
  HttpServer? _server;
  String? _localIp;
  final Map<String, _PairState> _pairs = {};
  final Map<String, _LanSession> _sessions = {};
  ModLanImageStaging? _imageStaging;

  // Only app-private cache is used, never phone public Downloads/Photos.
  static String get _imageStagingCache =>
      AppFiles.getCachePath('moodiary-v3-lan-stage');
  final Map<String, List<DateTime>> _attempts = {};
  bool _stopping = false;
  ModLanEventHub _hub = ModLanEventHub();
  StreamSubscription<DiaryEvent>? _diaryEventsSubscription;
  final Map<WebSocket, String> _webSockets = {};
  ModLanWriteService get _writer => ModLanWriteService(getIt<DiaryRepository>());
  ModLanRichWriter get _richWriter => ModLanRichWriter(getIt<DiaryRepository>());

  // Called only after a successful SQLite commit. Notification failure cannot
  // turn an already saved block into an apparent failed write.
  void notifyMonthCommitted(String topicId) {
    ModMonthUpdates.publish(topicId);
    if (_server != null && !_stopping) {
      try { _hub.publish(kind: 'updated', id: topicId, source: 'local'); }
      catch (_) { /* A disconnect does not roll back a committed record. */ }
    }
  }

  void _publishDiaryEvent(DiaryEvent event) {
    switch (event) {
      case DiaryCreated(:final diary, :final fromSync):
        _hub.publish(kind: 'created', id: diary.id,
            source: fromSync ? 'cloud' : 'local');
      case DiaryUpdated(:final diary, :final fromSync):
        _hub.publish(kind: 'updated', id: diary.id,
            source: fromSync ? 'cloud' : 'local');
      case DiaryDeleted(:final id, :final fromSync):
        _hub.publish(kind: 'deleted', id: id,
            source: fromSync ? 'cloud' : 'local');
    }
  }

  void _closeWebSockets() {
    for (final socket in _webSockets.keys.toList()) {
      unawaited(socket.close(WebSocketStatus.policyViolation, 'session revoked'));
    }
    _webSockets.clear();
  }

  String? get address => _localIp == null ? null : 'http://$_localIp:$_port';
  bool get isRunning => _server != null;

  static Future<InternetAddress> _wifiAddress() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4, includeLoopback: false);
    for (final nic in interfaces) {
      if (!ModLanPolicy.isWlanInterfaceName(nic.name)) continue;
      for (final addr in nic.addresses) {
        if (ModLanPolicy.isPrivateIPv4(addr.address)) return addr;
      }
    }
    throw StateError('未检测到可信的 Wi-Fi IPv4 接口；不会监听所有网络接口');
  }

  Future<String> start() async {
    if (_server != null) return address!;
    final ip = await _wifiAddress();
    // The user pressed Start in the visible app; background starts are blocked.
    await _serviceChannel.invokeMethod<void>('start');
    try {
      final root = Directory(_imageStagingCache);
      // A previous force-stop may leave temporary bytes on disk; no staged
      // IDs are persisted across server restarts. Clean this dedicated
      // workspace before accepting new connections.
      if (await root.exists()) await root.delete(recursive: true);
      await root.create(recursive: true);
      _imageStaging = ModLanImageStaging(
        privateCacheRoot: root,
        verifyDecodedImage: modLanVerifyDecodedImage,
      );
      final server = await HttpServer.bind(ip, _port, shared: false);
      _server = server;
      _localIp = ip.address;
      _stopping = false;
      _hub = ModLanEventHub();
      _diaryEventsSubscription = getIt<DiaryRepository>()
          .diaryEvents.listen(_publishDiaryEvent);
      running.value = true;
      unawaited(_accept(server));
      return address!;
    } catch (_) {
      _imageStaging = null;
      try { await _serviceChannel.invokeMethod<void>('stop'); } catch (_) {}
      rethrow;
    }
  }

  Future<void> stop() async {
    if (_stopping) return;
    _stopping = true;
    running.value = false;
    final server = _server;
    _server = null;
    _localIp = null;
    _pairs.clear();
    _closeWebSockets();
    _sessions.clear();
    final imageStaging = _imageStaging;
    _imageStaging = null;
    _attempts.clear();
    connections.value = 0;
    pendingPair.value = null;
    await _diaryEventsSubscription?.cancel();
    _diaryEventsSubscription = null;
    await server?.close(force: true);
    // In-flight interrupted requests are rejected by the revoked session.
    // The staging service deletes its pending files; a new start also
    // removes orphaned bytes left by abrupt process death.
    if (imageStaging != null) {
      try {
        await imageStaging.close();
      } on ModLanImagePolicyException {
        // A request is still finishing; its stream owns temporary cleanup.
        // Do not delete a directory while a stream may still write into it.
      }
    }
    await _hub.close();
    try { await _serviceChannel.invokeMethod<void>('stop'); } catch (_) {}
    _stopping = false;
  }

  void approve(String id) {
    final pair = _pairs[id];
    if (pair == null || DateTime.now().isAfter(pair.request.expiresAt)) return;
    _closeWebSockets();
    final oldSessionIds = _sessions.keys.toList(growable: false);
    for (final oldId in oldSessionIds) {
      unawaited(_imageStaging?.revokeSession(oldId).catchError((Object _) {}) ??
          Future<void>.value());
    }
    _sessions.clear(); // Only one authorized browser at a time.
    final now = DateTime.now();
    final sess = _LanSession(modLanRandomHex(), modLanRandomHex(), now);
    pair.granted = sess;
    pair.approved = true;
    _sessions[sess.id] = sess;
    connections.value = _sessions.length;
    pendingPair.value = null;
  }

  void reject(String id) {
    final pair = _pairs[id];
    if (pair == null) return;
    pair.rejected = true;
    pendingPair.value = null;
  }

  void revokeAll() {
    _closeWebSockets();
    for (final oldId in _sessions.keys.toList()) {
      unawaited(_imageStaging?.revokeSession(oldId).catchError((Object _) {}) ??
          Future<void>.value());
    }
    _sessions.clear();
    connections.value = 0;
  }

  Future<void> _accept(HttpServer server) async {
    try {
      await for (final request in server) {
        unawaited(_handle(request).catchError((Object _) async {
          try {
            request.response.statusCode = HttpStatus.internalServerError;
            await request.response.close();
          } catch (_) {}
        }));
      }
    } catch (_) {
      if (!_stopping && identical(server, _server)) await stop();
    }
  }

  bool _originAllowed(HttpRequest r) => ModLanPolicy.validSameOrigin(
    host: r.headers.value(HttpHeaders.hostHeader) ?? '',
    origin: r.headers.value('origin'),
    authority: '${_localIp ?? ''}:$_port',
    mutation: r.method != 'GET' && r.method != 'HEAD');

  _LanSession? _session(HttpRequest r) {
    final cookie = r.cookies.where((c) => c.name == 'moodiary_lan').firstOrNull;
    if (cookie == null) return null;
    final s = _sessions[cookie.value];
    if (s == null) return null;
    if (s.expired(DateTime.now())) {
      _sessions.remove(cookie.value);
      connections.value = _sessions.length;
      return null;
    }
    s.active = DateTime.now();
    return s;
  }

  void _headers(HttpResponse res) {
    res.headers.set(HttpHeaders.cacheControlHeader, 'no-store, max-age=0');
    res.headers.set('X-Content-Type-Options', 'nosniff');
    res.headers.set('Referrer-Policy', 'no-referrer');
    res.headers.set('X-Frame-Options', 'DENY');
    res.headers.set('Cross-Origin-Resource-Policy', 'same-origin');
    res.headers.set('Content-Security-Policy',
      "default-src 'none'; script-src 'self'; style-src 'self'; "
      "connect-src 'self' ws://${_localIp ?? '127.0.0.1'}:$_port; "
      "img-src 'self'; base-uri 'none'; "
      "form-action 'none'; frame-ancestors 'none'");
  }

  Future<void> _json(HttpRequest req, int status, Object data, {String? cookie}) async {
    final res = req.response;
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    if (cookie != null) res.headers.set('Set-Cookie', cookie);
    res.write(jsonEncode(data));
    await res.close();
  }

  Future<void> _asset(HttpRequest req, String text, String type) async {
    req.response.headers.contentType = ContentType.parse(type);
    req.response.write(text);
    await req.response.close();
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest r) async {
    if (r.headers.contentType?.mimeType != 'application/json') {
      throw const ModLanWriteException(415, 'json_content_type_required');
    }
    final builder = BytesBuilder(copy: false);
    var count = 0;
    await for (final chunk in r) {
      count += chunk.length;
      if (count > 262144) {
        throw const ModLanWriteException(413, 'request_too_large');
      }
      builder.add(chunk);
    }
    try {
      final decoded = jsonDecode(utf8.decode(builder.takeBytes()));
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      throw const ModLanWriteException(400, 'bad_json');
    }
    throw const ModLanWriteException(400, 'bad_json');
  }

  Map<String, Object> _diaryDto(Diary d) => {
    'id': d.id,
    'title': d.title,
    'text': d.contentText,
    'revision': ModLanWriteSafety.revision(d),
    'editable': ModLanWriteSafety.canEdit(d) && !ModDiary.isTopic(d) && !ModDiary.isChild(d),
    'lastModified': d.lastModified.toIso8601String(),
  };

  Map<String, Object?> _richDto(Diary d) {
    final safe = ModLanRichDocument.canEdit(d);
    return {
      'id': d.id, 'title': d.title, 'text': d.contentText,
      'revision': ModLanWriteSafety.revision(d),
      'editable': safe,
      'document': safe ? ModLanRichDocument.editableDocument(d) : null,
      'lastModified': d.lastModified.toIso8601String(),
    };
  }

  Future<void> _handle(HttpRequest r) async {
    _headers(r.response);
    if (!_originAllowed(r)) {
      await _json(r, HttpStatus.forbidden, {'error': 'unsafe_origin'});
      return;
    }
    final path = r.uri.path;
    if (r.method == 'GET' && path == '/') {
      await _asset(r, _page, 'text/html; charset=utf-8');
      return;
    }
    if (r.method == 'GET' && path == '/app.js') {
      await _asset(r, _script, 'application/javascript; charset=utf-8');
      return;
    }
    if (r.method == 'GET' && path == '/style.css') {
      await _asset(r, _css, 'text/css; charset=utf-8');
      return;
    }
    if (r.method == 'POST' && path == '/api/pair/request') {
      if (!_rateAllowed(r.connectionInfo?.remoteAddress.address ?? 'unknown')) {
        await _json(r, 429, {'error': 'too_many_requests'});
        return;
      }
      final now = DateTime.now();
      if (pendingPair.value != null && now.isBefore(pendingPair.value!.expiresAt)) {
        await _json(r, 429, {'error': 'pairing_pending'});
        return;
      }
      final code = (Random.secure().nextInt(900000) + 100000).toString();
      final id = modLanRandomHex(16);
      final request = ModLanPairingRequest(
        id: id, code: code,
        address: r.connectionInfo?.remoteAddress.address ?? 'unknown',
        userAgent: (r.headers.value('user-agent') ?? '未知浏览器').substring(
          0, min((r.headers.value('user-agent') ?? '未知浏览器').length, 100)),
        expiresAt: now.add(const Duration(seconds: 60)));
      _pairs.removeWhere((_, value) => now.isAfter(value.request.expiresAt));
      _pairs[id] = _PairState(request);
      pendingPair.value = request;
      await _json(r, HttpStatus.accepted, {'id': id, 'code': code});
      return;
    }
    if (r.method == 'GET' && path == '/api/pair/status') {
      final id = r.uri.queryParameters['id'];
      final state = _pairs[id];
      // Pairing grants must only be claimed by the requesting client.
      // HTTP does not defend against on-path impersonation; this prevents
      // unrelated LAN guests from redeeming a leaked pending request ID.
      if (state != null &&
          (state.request.address != r.connectionInfo?.remoteAddress.address ||
           state.request.userAgent != (r.headers.value('user-agent') ?? '未知浏览器')
               .substring(0, min((r.headers.value('user-agent') ?? '未知浏览器').length, 100)))) {
        await _json(r, HttpStatus.forbidden, {'error': 'pair_request_mismatch'});
        return;
      }
      if (state == null || DateTime.now().isAfter(state.request.expiresAt)) {
        await _json(r, 410, {'state': 'expired'});
        return;
      }
      if (state.rejected) {
        _pairs.remove(id);
        await _json(r, 403, {'state': 'rejected'});
        return;
      }
      if (!state.approved || state.granted == null) {
        await _json(r, 200, {'state': 'waiting'});
        return;
      }
      final session = state.granted!;
      _pairs.remove(id);
      await _json(r, 200, {'state': 'approved'},
        cookie: 'moodiary_lan=${session.id}; Path=/; HttpOnly; SameSite=Strict; Max-Age=43200');
      return;
    }
    final session = _session(r);
    if (r.method == 'GET' && path == '/api/session') {
      await _json(r, 200, session == null ? {'authorized': false} :
          {'authorized': true, 'csrf': session.csrf, 'mode': 'w6_rich_json_api_with_safe_text_editor'});
      return;
    }
    if (session == null) {
      await _json(r, HttpStatus.unauthorized, {'error': 'pairing_required'});
      return;
    }
    // Static Tiptap app files are *only* served after phone pairing.
    // Restrict names; never construct an arbitrary filesystem path from a URL.
    if (r.method == 'GET' && path == '/lan-editor') {
      r.response.headers.set(HttpHeaders.locationHeader, '/lan-editor/');
      r.response.statusCode = HttpStatus.found;
      await r.response.close();
      return;
    }
    if (r.method == 'GET' && path == '/lan-editor/') {
      await _asset(r, await rootBundle.loadString('assets/lan/index.html'),
          'text/html; charset=utf-8');
      return;
    }
    if (r.method == 'GET' && (path == '/lan-editor/lan.js' ||
        path == '/lan-editor/lan.css' ||
        RegExp(r'^/lan-editor/lan-chunk-[a-zA-Z0-9_-]+\.js$').hasMatch(path))) {
      final name = path.split('/').last;
      await _asset(r, await rootBundle.loadString('assets/lan/$name'),
          name.endsWith('.css') ? 'text/css; charset=utf-8'
              : 'application/javascript; charset=utf-8');
      return;
    }
    if (path == ModLanMonthHttp.topicsPath ||
        path.startsWith(ModLanMonthHttp.prefix)) {
      final months = ModLanMonthHttp(
        store: ModMonthStore(getIt<MoodiaryDatabase>()),
        repository: getIt<DiaryRepository>(),
        onCommitted: notifyMonthCommitted,
      );
      await months.tryHandle(r,
        authority: '${_localIp ?? ''}:$_port',
        csrfToken: session.csrf,
        isSessionActive: () => _sessions[session.id] == session &&
            !session.expired(DateTime.now()) && isRunning,
      );
      return;
    }
    if (r.method == 'GET' && path == '/api/events') {
      await _serveEvents(r, session);
      return;
    }
    if (r.method == 'POST' && path.startsWith('/api/media/attach/') &&
        r.uri.pathSegments.length == 4) {
      // Same-origin and phone session approval were already verified.
      if (r.headers.value('x-moodiary-csrf') != session.csrf) {
        await _json(r, HttpStatus.forbidden, {'error': 'csrf_required'});
        return;
      }
      final staging = _imageStaging;
      if (staging == null) {
        await _json(r, HttpStatus.serviceUnavailable,
            {'error': 'upload_service_stopped'});
        return;
      }
      try {
        final input = await _readJson(r);
        final stageId = input['stagingId'];
        final revision = input['revision'];
        if (stageId is! String || revision is! String) {
          throw const ModLanImagePolicyException(
            422, 'invalid_image_attach_request',
          );
        }
        // This check is necessary after request-body parsing; the phone may
        // have revoked the session while the network request was in flight.
        if (_sessions[session.id] != session || staging != _imageStaging) {
          throw const ModLanImagePolicyException(403, 'session_revoked');
        }
        final writer = ModLanImageAttach(
          repository: getIt<DiaryRepository>(),
          staging: staging,
          isSessionActive: () =>
              _sessions[session.id] == session && _imageStaging == staging,
        );
        final updated = await writer.appendStagedImage(
          diaryId: r.uri.pathSegments[3],
          stageId: stageId,
          ownerSession: session.id,
          revision: revision,
        );
        // Only now can the browser report 'saved to phone'.
        await _json(r, HttpStatus.ok, {
          'state': 'saved_on_phone',
          'diaryId': updated.id,
          'revision': ModLanWriteSafety.revision(updated),
          'imageName': updated.imageName.last,
        });
      } on ModLanWriteException catch (e) {
        await _json(r, e.status, {'error': e.code});
      } on ModLanImagePolicyException catch (e) {
        await _json(r, e.status, {'error': e.code});
      } catch (_) {
        await _json(r, HttpStatus.internalServerError,
            {'error': 'image_attach_failed'});
      }
      return;
    }
    if (r.method == 'POST' && path == '/api/media/staged') {
      // Auth and same-origin were required above. Uploads additionally
      // require the SAME anti-CSRF proof as diary writes.
      if (r.headers.value('x-moodiary-csrf') != session.csrf) {
        await _json(r, HttpStatus.forbidden, {'error': 'csrf_required'});
        return;
      }
      final staging = _imageStaging;
      if (staging == null) {
        await _json(r, HttpStatus.serviceUnavailable,
            {'error': 'upload_service_stopped'});
        return;
      }
      try {
        final length = r.headers.contentLength;
        final uploaded = await staging.accept(
          ownerSession: session.id,
          contentType: r.headers.value(HttpHeaders.contentTypeHeader) ?? '',
          contentLength: length > 0 ? length : null,
          body: r.timeout(const Duration(seconds: 30)),
        );
        if (_sessions[session.id] != session || _imageStaging != staging) {
          await staging.revokeSession(session.id);
          await _json(r, HttpStatus.forbidden, {'error': 'session_revoked'});
          return;
        }
        // This acknowledges TEMPORARY STAGING ONLY, never a diary commit.
        await _json(r, HttpStatus.created, {
          'state': 'staged_not_attached',
          'stagingId': uploaded.id,
          'sha256': uploaded.sha256Hex,
          'size': uploaded.size,
          'mime': uploaded.mime,
          'expiresAt': uploaded.expiresAt.toIso8601String(),
        });
      } on ModLanImagePolicyException catch (error) {
        await _json(r, error.status, {'error': error.code});
      } on TimeoutException {
        await _json(r, HttpStatus.requestTimeout, {'error': 'image_timeout'});
      } catch (_) {
        await _json(r, HttpStatus.badRequest,
            {'error': 'image_upload_failed_no_ack'});
      }
      return;
    }
    if (r.method == 'GET' && path.startsWith('/api/rich/diaries/') &&
        r.uri.pathSegments.length == 4) {
      try {
        final diary = await _richWriter.load(r.uri.pathSegments[3]);
        if (ModDiary.isTopic(diary) || ModDiary.isChild(diary)) {
          throw const ModLanWriteException(409, 'long_record_write_not_ready');
        }
        await _json(r, HttpStatus.ok, _richDto(diary));
      } on ModLanWriteException catch (e) {
        await _json(r, e.status, {'error': e.code});
      }
      return;
    }
    if (r.method == 'POST' || r.method == 'PUT' || r.method == 'DELETE' || r.method == 'PATCH') {
      if (r.headers.value('x-moodiary-csrf') != session.csrf) {
        await _json(r, HttpStatus.forbidden, {'error': 'csrf_required'});
        return;
      }
      try {
        if (r.method == 'POST' && path == '/api/rich/diaries') {
          final diary = await _richWriter.create(await _readJson(r));
          await _json(r, HttpStatus.ok, _richDto(diary));
        } else if (r.method == 'PUT' && path.startsWith('/api/rich/diaries/') &&
            r.uri.pathSegments.length == 4) {
          final diary = await _richWriter.load(r.uri.pathSegments[3]);
          if (ModDiary.isTopic(diary) || ModDiary.isChild(diary)) {
            throw const ModLanWriteException(409, 'long_record_write_not_ready');
          }
          final updated = await _richWriter.update(diary.id, await _readJson(r));
          await _json(r, HttpStatus.ok, _richDto(updated));
        } else if (r.method == 'POST' && path == '/api/diaries') {
          final doc = await _writer.create(await _readJson(r));
          await _json(r, HttpStatus.ok, _diaryDto(doc));
        } else if (r.method == 'PUT' && path.startsWith('/api/diaries/') &&
            r.uri.pathSegments.length == 3) {
          final id = r.uri.pathSegments[2];
          final existing = await _writer.load(id);
          if (ModDiary.isTopic(existing) || ModDiary.isChild(existing)) {
            throw const ModLanWriteException(409, 'long_record_write_not_ready');
          }
          final updated = await _writer.update(id, await _readJson(r));
          await _json(r, HttpStatus.ok, _diaryDto(updated));
        } else {
          await _json(r, HttpStatus.methodNotAllowed, {'error': 'operation_not_ready'});
        }
      } on ModLanWriteException catch (e) {
        await _json(r, e.status, {'error': e.code});
      } on FormatException {
        await _json(r, HttpStatus.badRequest, {'error': 'invalid_payload'});
      } catch (_) {
        await _json(r, HttpStatus.internalServerError, {'error': 'write_failed_no_ack'});
      }
      return;
    }
    if (r.method == 'GET' && path.startsWith('/api/diaries/') &&
        r.uri.pathSegments.length == 3) {
      try {
        final diary = await _writer.load(r.uri.pathSegments[2]);
        if (ModDiary.isTopic(diary) || ModDiary.isChild(diary)) {
          throw const ModLanWriteException(409, 'long_record_write_not_ready');
        }
        await _json(r, HttpStatus.ok, _diaryDto(diary));
      } on ModLanWriteException catch (e) {
        await _json(r, e.status, {'error': e.code});
      }
      return;
    }
    if (r.method == 'GET' && path == '/api/diaries') {
      final all = await getIt<DiaryRepository>().getAllDiaries();
      final diaries = all.where((d) => d.show && !ModDiary.isTopic(d) &&
          !ModDiary.isChild(d)).toList()
        ..sort((a, b) => b.time.compareTo(a.time));
      await _json(r, 200, {'items': [for (final d in diaries.take(200)) {
        'id': d.id, 'title': d.title, 'preview': d.contentText,
        'date': d.time.toIso8601String(), 'lastModified': d.lastModified.toIso8601String(),
      }]});
      return;
    }
    if (r.method == 'GET' && path == '/api/months') {
      final all = await getIt<DiaryRepository>().getAllDiaries();
      final topics = all.where((d) => d.show && ModDiary.isTopic(d)).toList();
      final children = all.where((d) => d.show && ModDiary.isChild(d)).toList();
      await _json(r, 200, {'topics': [for (final topic in topics) {
        'id': topic.id, 'title': topic.title,
        'months': [for (final m in ModMonthlyIndex.fromChildDiaries(
            children.where((d) => ModDiary.topicIdOf(d) == topic.id))) {
          'month': m.key, 'days': m.recordedDays, 'count': m.recordCount,
          'preview': [for (final d in m.latestPreview) {
            'time': d.time.toIso8601String(), 'text': d.contentText,
          }],
        }],
      }]});
      return;
    }
    await _json(r, HttpStatus.notFound, {'error': 'not_found'});
  }

  Future<void> _serveEvents(HttpRequest r, _LanSession session) async {
    // A browser WebSocket sends an Origin header, unlike a normal GET.
    // Refuse cross-origin upgrades even when a session Cookie is present.
    if (r.headers.value('origin') != address ||
        !WebSocketTransformer.isUpgradeRequest(r)) {
      await _json(r, HttpStatus.forbidden, {'error': 'unsafe_websocket'});
      return;
    }
    final socket = await WebSocketTransformer.upgrade(r);
    _webSockets[socket] = session.id;
    final hub = _hub;
    final subscription = hub.changes.listen((change) {
      if (_sessions[session.id] != session || socket.readyState != WebSocket.open) {
        unawaited(socket.close(WebSocketStatus.policyViolation, 'authorization expired'));
        return;
      }
      socket.add(jsonEncode(change.toJson()));
    });
    try {
      socket.add(jsonEncode({
        'type': 'welcome', 'epoch': hub.epoch, 'sequence': hub.sequence,
      }));
      final since = int.tryParse(r.uri.queryParameters['since'] ?? '');
      final epoch = r.uri.queryParameters['epoch'];
      if (since == null || epoch != hub.epoch) {
        socket.add(jsonEncode({'type': 'reset', 'epoch': hub.epoch,
          'sequence': hub.sequence, 'reason': 'new_or_unknown_cursor'}));
      } else {
        final replay = hub.replayAfter(since);
        if (replay == null) {
          socket.add(jsonEncode({'type': 'reset', 'epoch': hub.epoch,
            'sequence': hub.sequence, 'reason': 'replay_window_expired'}));
        } else {
          for (final event in replay) {
            socket.add(jsonEncode(event.toJson()));
          }
        }
      }
      // Heartbeat refreshes the idle session; it is not a security token.
      final incoming = socket.listen((message) {
        if (message == 'ping') {
          if (_sessions[session.id] != session || session.expired(DateTime.now())) {
            unawaited(socket.close(WebSocketStatus.policyViolation, 'session expired'));
          } else {
            session.active = DateTime.now();
            socket.add(jsonEncode({'type': 'pong'}));
          }
        }
      });
      await incoming.asFuture<void>();
    } finally {
      await subscription.cancel();
      _webSockets.remove(socket);
      await socket.close();
    }
  }

  bool _rateAllowed(String ip) {
    final now = DateTime.now();
    final recent = _attempts.putIfAbsent(ip, () => []);
    recent.removeWhere((time) => now.difference(time) >= const Duration(minutes: 1));
    if (recent.length >= 3) return false;
    recent.add(now);
    return true;
  }
}

const _page = '''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Moodiary Web — W4 安全文本编辑</title><link rel="stylesheet" href="/style.css"></head>
<body><main><header><h1>Moodiary Web</h1><small>W4 · 实时双向简单文本编辑测试版</small></header>
<section id="pair"><h2>连接手机</h2><p>请在手机 Moodiary 里确认本次配对。</p>
<button id="pairButton">请求连接</button><p id="pairState"></p></section>
<section id="workspace" hidden><p id="conn">已连接手机</p><p><a href="/lan-editor/">打开日记与长期记录工作台</a></p><p id="lastSync" class="notice">准备建立实时连接…</p><nav>
<button data-view="diaries">普通日记</button><button data-view="months">长期记录（只读）</button></nav>
<section id="editZone"><h2 id="editHeading">新建普通日记</h2>
<label>标题<input id="editTitle" maxlength="200" autocomplete="off"></label>
<label>正文（本阶段仅支持无格式文本）<textarea id="editText" rows="9" maxlength="200000"></textarea></label>
<div><button id="newEntry">新建</button><button id="saveEntry">保存到手机</button>
<span id="editStatus" class="notice">新建或选择普通日记编辑</span></div></section>
<div id="records"></div><p class="notice">W4：简单无格式文本可安全新建和编辑；含图片、格式或其它节点的旧日记保持只读。完整 Tiptap 与图片上传尚未开放。</p></section>
<p class="notice">仅在可信私人局域网使用。HTTP 无传输加密，不能防止同网段流量窃听或篡改。</p></main>
<script src="/app.js" defer></script></body></html>''';

const _css = '''*{box-sizing:border-box}body{margin:0;background:#f6f7f8;color:#1b2734;font:16px system-ui,-apple-system,sans-serif}main{max-width:1000px;margin:4vh auto;padding:24px}header{display:flex;gap:24px;align-items:center;justify-content:space-between}h1{margin:0}section{background:white;border:1px solid #e2e7eb;border-radius:16px;padding:22px;margin:18px 0}button{border:1px solid #ccd5db;background:white;border-radius:10px;padding:12px 18px;font:inherit;cursor:pointer;margin:4px}button:hover{background:#edf5ff}.notice,small{color:#63727d;font-size:13px}.entry{padding:16px;border-bottom:1px solid #eee}.entry strong{display:block;margin-bottom:5px}.entry p{white-space:pre-wrap;word-break:break-word;color:#3c4b58}.entry time{color:#7a8893;font-size:12px}nav{margin:10px 0}#pairState{white-space:pre-wrap}label{display:block;margin:10px 0}input,textarea{display:block;width:100%;padding:10px;margin-top:5px;border:1px solid #ccd5db;border-radius:8px;font:inherit}#editZone[hidden]{display:none}button:disabled{opacity:.5;cursor:not-allowed}''';

const _script = r'''(() => {
const q = id => document.getElementById(id);
const records = q('records');
let currentView='diaries', generation=0, authorized=false;
let socket=null, reconnectTimer=null, heartbeat=null, retryDelay=1000;
let epoch=null, cursor=0, refreshTimer=null;
let csrf='', openedId=null, openedRevision=null, pendingCreateId=null, loaded=false, dirty=false, writeBusy=false;
let editorReadOnly=false, draftSerial=0, openSerial=0, autoSaveTimer=null;
const editorZone=q('editZone'), editTitle=q('editTitle'),editText=q('editText'),editStatus=q('editStatus');
function updateEditor(text){editStatus.textContent=text}
function setReadOnly(lock){editorReadOnly=lock;editTitle.disabled=lock;editText.disabled=lock;q('saveEntry').disabled=lock||writeBusy}
function makeUuid(){
 const random=()=>Math.floor(Math.random()*16);
 const pieces='xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx';
 // This is an idempotency identifier, never an authentication token.
 return pieces.replace(/[xy]/g,c=>{const r=random();return(c==='x'?r:((r&3)|8)).toString(16)});
}
async function openEntry(id){
 if(writeBusy){updateEditor('正在保存，请先完成保存后再切换日记');return}
 const load=++openSerial;
 try{
  const previous=openedId;
  const d=await api('/api/diaries/'+encodeURIComponent(id));
  if(load!==openSerial)return;
  if((previous===id || openedId===id) && dirty){
    updateEditor('另一端可能已更改此日记，当前草稿仍保留，请比较后保存');
    return;
  }
  openedId=d.id;openedRevision=d.revision;loaded=true;dirty=false;
  editTitle.value=d.title;editText.value=d.text;
  q('editHeading').textContent='编辑普通日记';
  setReadOnly(!d.editable);
  updateEditor(d.editable?'已载入 · 可安全编辑文字':'此日记包含富文本/图片等复杂内容，W4 为保护原始格式禁止编辑');
 }catch(e){updateEditor('打开失败：'+e.message)}
}
function newEntry(){
 if(writeBusy){updateEditor('正在保存，请先完成保存后再新建');return}
 ++openSerial;clearTimeout(autoSaveTimer);
 openedId=null;openedRevision=null;pendingCreateId=null;loaded=true;dirty=false;
 editTitle.value='';editText.value='';q('editHeading').textContent='新建普通日记';
 setReadOnly(false);updateEditor('请输入内容，然后保存到手机');
}
async function saveEntry(){
 if(writeBusy || !loaded || editorReadOnly)return;
 clearTimeout(autoSaveTimer);
 const savingSerial=draftSerial;
 writeBusy=true;q('saveEntry').disabled=true;
 const existing=!!openedId;const id=openedId||(pendingCreateId||(pendingCreateId=makeUuid()));
 const input={title:editTitle.value,text:editText.value};
 if(existing)input.revision=openedRevision;else input.id=id;
 updateEditor('正在保存到手机…');
 try{
  const result=await api('/api/diaries'+(existing?'/'+encodeURIComponent(id):''),{
   method:existing?'PUT':'POST',headers:{'content-type':'application/json','x-moodiary-csrf':csrf},
   body:JSON.stringify(input),
  });
  openedId=result.id;openedRevision=result.revision;pendingCreateId=null;
  const newerInput=draftSerial!==savingSerial;
  dirty=newerInput;loaded=true;
  updateEditor(newerInput?'已保存此前内容；保存期间的新输入仍待保存':'已保存至手机 · WebDAV 将独立同步');
  if(newerInput)queueAutoSave();
  scheduleRefresh();
 }catch(e){
  dirty=true; // Unacknowledged edits remain unsaved.
  updateEditor(e.message==='stale_revision'?
    '编辑冲突：手机已修改这篇日记。当前电脑输入仍保留，请复制草稿或重新打开；不会覆盖手机内容。':
    '保存失败，当前内容仍在网页中：'+e.message);
 }finally{writeBusy=false;q('saveEntry').disabled=editorReadOnly}
}
function queueAutoSave(){
 clearTimeout(autoSaveTimer);
 if(!editorReadOnly&&loaded&&dirty){
  autoSaveTimer=setTimeout(()=>{if(!writeBusy&&dirty)saveEntry();else if(dirty)queueAutoSave()},2000);
 }
}
function markChanged(){
 dirty=true;++draftSerial;updateEditor('未保存的修改');queueAutoSave();
}
editTitle.addEventListener('input',markChanged);
editText.addEventListener('input',markChanged);
q('newEntry').addEventListener('click',()=>{if(dirty&&!confirm('有未保存的修改，确定放弃吗？'))return;newEntry()});
q('saveEntry').addEventListener('click',saveEntry);
window.addEventListener('keydown',e=>{if((e.ctrlKey||e.metaKey)&&e.key==='s'){
 e.preventDefault();if(!q('saveEntry').disabled)saveEntry();
}});

function clear(node){while(node.firstChild)node.removeChild(node.firstChild)}
function paragraph(text,parent,tag='p'){const el=document.createElement(tag);el.textContent=String(text??'');parent.append(el);return el}
async function api(url,opts){const r=await fetch(url,{cache:'no-store',credentials:'same-origin',...opts});const j=await r.json();if(!r.ok)throw Error(j.error||String(r.status));return j}
function scheduleRefresh(){clearTimeout(refreshTimer);refreshTimer=setTimeout(()=>show(currentView),150)}
function closeConnection(){
  clearTimeout(autoSaveTimer);
  if(socket){const s=socket;socket=null;s.onclose=null;s.close()}
  clearInterval(heartbeat);clearTimeout(reconnectTimer);
}
async function status(){
 try {
  const s=await api('/api/session');authorized=!!s.authorized;csrf=s.csrf||'';
  q('pair').hidden=authorized;q('workspace').hidden=!authorized;
  if(authorized){await show(currentView);if(!socket)connectEvents()}
  else closeConnection();
 }catch(e){q('pairState').textContent='连接失败：'+e.message}
}
async function pair(){
 q('pairButton').disabled=true;
 try {
  const p=await api('/api/pair/request',{method:'POST'});
  q('pairState').textContent='请在手机核对并允许：'+p.code;
  for(let i=0;i<30;i++){
   await new Promise(r=>setTimeout(r,2000));
   const check=await fetch('/api/pair/status?id='+encodeURIComponent(p.id),{cache:'no-store'});
   const body=await check.json();
   if(body.state==='approved'){await status();return}
   if(body.state==='rejected'||body.state==='expired')throw Error(body.state);
  }
  throw Error('timeout');
 }catch(e){q('pairState').textContent='配对未完成：'+e.message}
 finally{q('pairButton').disabled=false}
}
function connectEvents(){
 if(!authorized||socket)return;
 const args=new URLSearchParams({epoch:epoch||'',since:String(cursor)});
 const ws=new WebSocket('ws://'+location.host+'/api/events?'+args.toString());
 socket=ws;
 q('lastSync').textContent='连接实时同步通道…';
 ws.onopen=()=>{
  retryDelay=1000;
  q('lastSync').textContent='已连接实时同步通道';
  heartbeat=setInterval(()=>{if(ws.readyState===WebSocket.OPEN)ws.send('ping')},15000);
 };
 ws.onmessage=event=>{
  let payload;
  try{payload=JSON.parse(event.data)}catch{return}
  if(payload.type==='welcome'){
   if(epoch!==payload.epoch){epoch=payload.epoch;cursor=Number(payload.sequence)||0;scheduleRefresh()}
  }else if(payload.type==='reset'){
   epoch=payload.epoch;cursor=Math.max(cursor,Number(payload.sequence)||0);scheduleRefresh();
  }else if(payload.type==='invalidate'){
   if(payload.epoch!==epoch){epoch=payload.epoch;cursor=0;scheduleRefresh()}
   cursor=Math.max(cursor,Number(payload.sequence)||0);
   scheduleRefresh();
   if(openedId===payload.id && !writeBusy){
     if(payload.kind==='deleted'){
       setReadOnly(true);updateEditor('此日记已在手机端删除，电脑草稿不会自动覆盖恢复');
     }else if(dirty){
       updateEditor('手机端有新的修改，当前电脑草稿保留；保存时将进行版本检查');
     }else{
       openEntry(openedId);
     }
   }
  }
 };
 ws.onclose=async()=>{
  clearInterval(heartbeat);
  if(socket!==ws)return;
  socket=null;
  q('lastSync').textContent='实时连接中断，正在尝试重新连接…';
  try{
   const session=await api('/api/session');
   if(!session.authorized){authorized=false;q('pair').hidden=false;q('workspace').hidden=true;return}
  }catch(e){}
  reconnectTimer=setTimeout(connectEvents,retryDelay);
  retryDelay=Math.min(retryDelay*2,10000);
 };
 ws.onerror=()=>{ws.close()};
}
async function show(which){
 currentView=which;editorZone.hidden=(which!=='diaries');
 const token=++generation;
 try{
  const data=await api(which==='months'?'/api/months':'/api/diaries');
  if(token!==generation)return;
  clear(records);
  if(which==='diaries'){
   for(const d of data.items){const div=document.createElement('article');div.className='entry';paragraph(d.title||'无标题',div,'strong');paragraph(d.preview||'',div);paragraph(d.date||'',div,'time');div.style.cursor='pointer';div.addEventListener('click',()=>{if(writeBusy){updateEditor('正在保存，请先完成保存后再切换');return}if(dirty&&!confirm('有未保存的编辑，确定放弃吗？'))return;dirty=false;openEntry(d.id)});records.append(div)}
  }else{
   for(const t of data.topics){const top=document.createElement('section');paragraph(t.title,top,'h2');for(const m of t.months){const row=document.createElement('article');row.className='entry';paragraph(m.month+' · '+m.days+'天 · '+m.count+'条',row,'strong');for(const p of m.preview)paragraph(p.time+' '+p.text,row);top.append(row)}records.append(top)}
  }
  q('lastSync').textContent='已连接手机 · 内容已刷新 '+new Date().toLocaleTimeString();
 }catch(e){if(token===generation){clear(records);paragraph('读取失败：'+e.message,records)}}
}
q('pairButton').addEventListener('click',pair);newEntry();
for(const b of document.querySelectorAll('button[data-view]'))b.addEventListener('click',()=>show(b.dataset.view));
window.addEventListener('pagehide',closeConnection);
status();
})();''';

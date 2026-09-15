/// Local IPC client for the persistent SysAI OS runtime.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/capability.dart';
import '../models/model_info.dart';

class BridgeException implements Exception {
  final String message;
  final String? code;
  const BridgeException(this.message, {this.code});
  @override
  String toString() => 'BridgeException: $message';
}

/// Connection state exposed to the UI. Legacy names remain for compatibility.
enum BridgeStatus {
  disconnected,
  starting,
  connecting,
  connected,
  reconnecting,
  offline,
  incompatible,
  sysaiUnavailable,
  failed,
}

/// A reconnecting Unix-domain-socket client. The runtime process is never
/// killed by [stop] or [dispose]; those methods close this UI connection only.
class BridgeService {
  Socket? _socket;
  Process? _runtimeProcess;
  StreamSubscription<String>? _socketSubscription;
  Timer? _reconnectTimer;
  bool _closing = false;
  bool _ready = false;
  bool _available = false;
  String? _sysaiVersion;
  String? _sysaiPath;
  String? _runtimeVersion;
  String? _protocolVersion;
  int? _runtimePid;
  String? _bridgeError;
  BridgeStatus _status = BridgeStatus.disconnected;
  String? _runtimeSocket;
  String? _runtimeScript;
  String? _databasePath;
  int _reconnectAttempt = 0;

  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};
  final Map<String, StreamController<Map<String, dynamic>>> _streamingRequests =
      {};
  final StreamController<Map<String, dynamic>> _eventController =
      StreamController.broadcast();
  final StreamController<BridgeStatus> _statusController =
      StreamController.broadcast();
  int _idCounter = 0;

  bool get isReady => _ready;
  bool get sysaiAvailable => _available;
  String? get sysaiVersion => _sysaiVersion;
  String? get sysaiPath => _sysaiPath;
  String? get runtimeVersion => _runtimeVersion;
  String? get protocolVersion => _protocolVersion;
  int? get runtimePid => _runtimePid;
  String? get bridgeError => _bridgeError;
  BridgeStatus get status => _status;
  String? get socketPath => _runtimeSocket;
  /// Non-null for the desktop client using the canonical application DB.
  /// Legacy direct callers omit this and retain the pre-registration behavior.
  String? get databasePath => _databasePath;
  Stream<Map<String, dynamic>> get events => _eventController.stream;
  Stream<BridgeStatus> get statusChanges => _statusController.stream;

  Future<void> start(
    String bridgeScript,
    String sysaiPath, {
    String? databasePath,
  }) async {
    if (_ready) return;
    _closing = false;
    _bridgeError = null;
    _runtimeScript = p.join(p.dirname(bridgeScript), 'sysai_os_runtime.py');
    _databasePath = databasePath;
    _runtimeSocket = _socketPath();
    _setStatus(BridgeStatus.starting);

    if (await _connectOnce()) return;
    try {
      final env = Map<String, String>.from(Platform.environment)
        ..['SYSAI_PATH'] = sysaiPath
        ..['PYTHONUNBUFFERED'] = '1';
      final args = <String>[_runtimeScript!, '--socket', _runtimeSocket!];
      if (_databasePath != null) args.addAll(['--db', _databasePath!]);
      _runtimeProcess = await Process.start(
        'python3',
        args,
        environment: env,
        mode: ProcessStartMode.detachedWithStdio,
      );
      _runtimeProcess!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.trim().isNotEmpty && !_eventController.isClosed) {
              _eventController.add({'type': 'runtime_stderr', 'message': line});
            }
          }, onError: (_) {});
    } catch (e) {
      _bridgeError = 'Failed to start SysAI OS runtime: $e';
      _setStatus(BridgeStatus.failed);
      throw BridgeException(_bridgeError!);
    }
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (await _connectOnce()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    _bridgeError = 'Runtime socket did not become available within 10s.';
    _setStatus(BridgeStatus.failed);
    throw BridgeException(_bridgeError!);
  }

  Future<bool> _connectOnce() async {
    final path = _runtimeSocket;
    if (path == null) return false;
    _setStatus(
      _reconnectAttempt == 0
          ? BridgeStatus.connecting
          : BridgeStatus.reconnecting,
    );
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
        timeout: const Duration(milliseconds: 500),
      );
    } catch (_) {
      return false;
    }
    _socket = socket;
    final ready = Completer<void>();
    _socketSubscription = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            final json = _parseJsonSafe(line.trim());
            if (json != null && !ready.isCompleted && json['type'] == 'ready') {
              _applyReadyMessage(json);
              ready.complete();
            } else if (json != null) {
              _handleLine(json);
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!ready.isCompleted) {
              ready.completeError(
                BridgeException('Runtime socket error: $error'),
                stack,
              );
            }
            _connectionLost('Runtime socket error: $error');
          },
          onDone: () {
            if (!ready.isCompleted) {
              ready.completeError(
                const BridgeException('Runtime closed before ready.'),
              );
            }
            _connectionLost('Runtime connection closed.');
          },
          cancelOnError: false,
        );
    try {
      await ready.future.timeout(const Duration(seconds: 3));
      _reconnectAttempt = 0;
      return true;
    } catch (_) {
      await _socketSubscription?.cancel();
      _socketSubscription = null;
      socket.destroy();
      return false;
    }
  }

  /// Disconnects the UI only. Use [shutdownRuntime] for an explicit service stop.
  Future<void> stop() async {
    _closing = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _ready = false;
    _available = false;
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    _socket?.destroy();
    _socket = null;
    _failAllPending('Runtime client disconnected.');
    _closeAllStreaming('Runtime client disconnected.');
    _setStatus(BridgeStatus.disconnected);
  }

  Future<bool> shutdownRuntime() async {
    if (!_ready) return false;
    try {
      final response = await call('runtime.shutdown');
      await stop();
      return response['shutting_down'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> dispose() async {
    await stop();
    await _eventController.close();
    await _statusController.close();
  }

  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!_ready || _socket == null) {
      throw const BridgeException('Runtime is not connected.', code: 'OFFLINE');
    }
    final id = _nextId();
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[id] = completer;
    _sendRequest({'id': id, 'method': method, 'params': params ?? {}});
    try {
      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          _pendingRequests.remove(id);
          throw BridgeException(
            'Request "$method" (id: $id) timed out.',
            code: 'TIMEOUT',
          );
        },
      );
    } catch (_) {
      _pendingRequests.remove(id);
      rethrow;
    }
  }

  Stream<Map<String, dynamic>> callStreaming(
    String method, {
    Map<String, dynamic>? params,
  }) {
    if (!_ready || _socket == null) {
      return Stream.error(
        const BridgeException('Runtime is not connected.', code: 'OFFLINE'),
      );
    }
    final id = _nextId();
    final requestParams = Map<String, dynamic>.from(params ?? const {});
    final controller = StreamController<Map<String, dynamic>>(
      onCancel: () {
        _streamingRequests.remove(id);
        try {
          _sendRequest({
            'id': id,
            'method': 'events.unsubscribe',
            'params': {
              if (requestParams['run_id'] != null) 'run_id': requestParams['run_id'],
            },
          });
        } catch (_) {}
      },
    );
    _streamingRequests[id] = controller;
    _sendRequest({'id': id, 'method': method, 'params': requestParams});
    return controller.stream;
  }

  Future<List<Capability>> listCapabilities() async {
    final res = await call('list_capabilities');
    return (res['capabilities'] as List<dynamic>? ?? [])
        .map((c) => Capability.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  Future<bool> resolveApproval(String requestId, bool approved) async =>
      (await call(
            'resolve_approval',
            params: {'request_id': requestId, 'approved': approved},
          ))['resolved']
          as bool? ??
      false;
  Future<bool> reportComputerActionResult(
    String requestId,
    Map<String, dynamic> result,
  ) async =>
      (await call(
            'report_computer_action_result',
            params: {'request_id': requestId, 'result': result},
          ))['resolved']
          as bool? ??
      false;
  Future<bool> pauseRun(String runId) async =>
      (await call('pause_run', params: {'run_id': runId}))['paused'] as bool? ??
      false;
  Future<bool> resumeRun(String runId) async =>
      (await call('resume_run', params: {'run_id': runId}))['resumed']
          as bool? ??
      false;
  Future<bool> cancelRun(String runId) async =>
      (await call('cancel_run', params: {'run_id': runId}))['cancelled']
          as bool? ??
      false;
  Future<List<Map<String, dynamic>>> listWorkspaceFiles({String? path}) async {
    final res = await call('list_workspace_files', params: {'path': ?path});
    return (res['entries'] as List<dynamic>? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<Map<String, dynamic>> readWorkspaceFile(String path) =>
      call('read_workspace_file', params: {'path': path});
  Future<List<ProviderInfo>> listProviders() async {
    final res = await call('list_providers');
    return (res['providers'] as List<dynamic>? ?? [])
        .map((v) => ProviderInfo.fromJson(v as Map<String, dynamic>))
        .toList();
  }

  Future<List<ModelInfo>> listModels() async {
    final res = await call('list_models');
    return (res['models'] as List<dynamic>? ?? [])
        .map((v) => ModelInfo.fromJson(v as Map<String, dynamic>))
        .toList();
  }

  Future<Map<String, dynamic>> checkModelAvailability(
    String provider,
    String model,
  ) => call(
    'check_model_availability',
    params: {'provider': provider, 'model': model},
  );
  Future<Map<String, dynamic>> runtimeStatus() => call('runtime.status');
  Future<bool> registerComputerTarget(
    String targetId, {
    Map<String, dynamic> capabilities = const {},
    Map<String, dynamic> metadata = const {},
  }) async =>
      (await call(
        'computer.target.register',
        params: {
          'target_id': targetId,
          'capabilities': capabilities,
          'metadata': metadata,
        },
      ))['registered'] ==
      true;
  Future<bool> unregisterComputerTarget(String targetId) async =>
      (await call(
        'computer.target.unregister',
        params: {'target_id': targetId},
      ))['registered'] ==
      false;

  void _handleLine(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    final type = json['type'] as String?;
    final isDone = json['done'] == true || type == 'done' || type == 'complete';
    if (id != null && _streamingRequests.containsKey(id)) {
      final ctrl = _streamingRequests[id]!;
      if (json['ok'] == false || type == 'error') {
        ctrl.addError(
          BridgeException(_extractError(json), code: json['code'] as String?),
        );
        _streamingRequests.remove(id);
        ctrl.close();
        return;
      }
      if (json['event'] is Map) {
        ctrl.add(Map<String, dynamic>.from(json['event'] as Map));
      }
      if (isDone) {
        if (json['result'] is Map) {
          ctrl.add({
            '_final_result': true,
            ...Map<String, dynamic>.from(json['result'] as Map),
          });
        }
        _streamingRequests.remove(id);
        ctrl.close();
      }
      return;
    }
    if (id != null && _pendingRequests.containsKey(id)) {
      final completer = _pendingRequests.remove(id)!;
      if (json['ok'] == false || type == 'error') {
        completer.completeError(
          BridgeException(_extractError(json), code: json['code'] as String?),
        );
      } else {
        completer.complete(
          json['result'] is Map
              ? Map<String, dynamic>.from(json['result'] as Map)
              : json,
        );
      }
      return;
    }
    _eventController.add(json);
  }

  void _sendRequest(Map<String, dynamic> request) {
    final encoded = jsonEncode(request);
    if (utf8.encode(encoded).length > 1024 * 1024) {
      throw const BridgeException(
        'Request exceeds 1 MiB limit.',
        code: 'MESSAGE_TOO_LARGE',
      );
    }
    try {
      _socket?.writeln(encoded);
    } catch (e) {
      throw BridgeException('Failed to write to runtime socket: $e');
    }
  }

  void _connectionLost(String reason) {
    if (_socket == null && !_ready) return;
    _socket = null;
    _ready = false;
    _available = false;
    _failAllPending(reason);
    _closeAllStreaming(reason);
    if (!_closing) {
      _setStatus(BridgeStatus.reconnecting);
      _reconnectAttempt++;
      final shift = _reconnectAttempt.clamp(0, 5);
      final delay = Duration(
        milliseconds: (250 * (1 << shift)).clamp(250, 8000),
      );
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(delay, () async {
        if (!_closing && !await _connectOnce()) {
          _connectionLost('Runtime reconnect failed.');
        }
      });
    } else {
      _setStatus(BridgeStatus.offline);
    }
  }

  String _socketPath() {
    final explicit = Platform.environment['SYSAI_RUNTIME_SOCKET'];
    if (explicit != null && explicit.trim().isNotEmpty) return explicit.trim();
    final runtimeDir = Platform.environment['XDG_RUNTIME_DIR'];
    if (runtimeDir != null && runtimeDir.isNotEmpty) {
      return p.join(runtimeDir, 'sysai-os', 'runtime.sock');
    }
    final state = Platform.environment['XDG_STATE_HOME'];
    final base = state != null && state.isNotEmpty
        ? state
        : p.join(
            Platform.environment['HOME'] ?? Directory.current.path,
            '.local',
            'state',
          );
    return p.join(base, 'sysai-os', 'runtime', 'runtime.sock');
  }

  String _nextId() => 'req-${++_idCounter}';
  void _setStatus(BridgeStatus status) {
    _status = status;
    if (!_statusController.isClosed) _statusController.add(status);
  }

  void _applyReadyMessage(Map<String, dynamic> json) {
    _protocolVersion = json['protocol_version'] as String?;
    _runtimeVersion = json['runtime_version'] as String?;
    _runtimePid = json['pid'] as int?;
    _available = json['sysai_available'] == true;
    _sysaiVersion = json['sysai_version'] as String?;
    _sysaiPath = json['sysai_path'] as String?;
    if (_protocolVersion != null && _protocolVersion != '1') {
      _ready = false;
      _setStatus(BridgeStatus.incompatible);
      return;
    }
    _ready = true;
    _setStatus(
      _available ? BridgeStatus.connected : BridgeStatus.sysaiUnavailable,
    );
  }

  void _failAllPending(String reason) {
    for (final c in _pendingRequests.values) {
      if (!c.isCompleted) {
        c.completeError(BridgeException(reason, code: 'OFFLINE'));
      }
    }
    _pendingRequests.clear();
  }

  void _closeAllStreaming(String reason) {
    for (final c in _streamingRequests.values) {
      c.addError(BridgeException(reason, code: 'OFFLINE'));
      c.close();
    }
    _streamingRequests.clear();
  }

  String _extractError(Map<String, dynamic> json) => json['error'] is String
      ? json['error'] as String
      : json['message'] as String? ?? 'Unknown runtime error';
  Map<String, dynamic>? _parseJsonSafe(String line) {
    try {
      final value = jsonDecode(line);
      return value is Map ? Map<String, dynamic>.from(value) : null;
    } catch (_) {
      _eventController.add({'type': 'runtime_raw', 'data': line});
      return null;
    }
  }
}

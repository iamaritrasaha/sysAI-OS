/// Python bridge service — manages the sysai_bridge.py subprocess.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/capability.dart';
import '../models/model_info.dart';

/// Thrown when the Python bridge returns an error response or the subprocess
/// fails unexpectedly.
class BridgeException implements Exception {
  final String message;
  final String? code;

  const BridgeException(this.message, {this.code});

  @override
  String toString() => 'BridgeException: $message';
}

/// Status of the bridge connection.
enum BridgeStatus {
  disconnected,
  starting,
  connected,
  sysaiUnavailable,
  failed,
}

/// Manages the Python bridge subprocess that executes the SysAI engine.
///
/// Communication is newline-delimited JSON over the subprocess stdin/stdout.
/// Each request carries a unique `id`; responses carry the same `id` so they
/// are routed back to the correct caller.
class BridgeService {
  Process? _process;
  bool _ready = false;
  bool _available = false;
  String? _sysaiVersion;
  String? _sysaiPath;
  String? _bridgeError;
  BridgeStatus _status = BridgeStatus.disconnected;

  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;

  /// Pending one-shot requests keyed by request ID.
  final Map<String, Completer<Map<String, dynamic>>> _pendingRequests = {};

  /// Active streaming requests keyed by request ID.
  final Map<String, StreamController<Map<String, dynamic>>>
      _streamingRequests = {};

  /// Broadcast stream of non-request events.
  final StreamController<Map<String, dynamic>> _eventController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Status change notifications.
  final StreamController<BridgeStatus> _statusController =
      StreamController<BridgeStatus>.broadcast();

  int _idCounter = 0;

  // -------------------------------------------------------------------------
  // Public getters
  // -------------------------------------------------------------------------

  bool get isReady => _ready;
  bool get sysaiAvailable => _available;
  String? get sysaiVersion => _sysaiVersion;
  String? get sysaiPath => _sysaiPath;
  String? get bridgeError => _bridgeError;
  BridgeStatus get status => _status;

  Stream<Map<String, dynamic>> get events => _eventController.stream;
  Stream<BridgeStatus> get statusChanges => _statusController.stream;

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  Future<void> start(String bridgeScript, String sysaiPath) async {
    _setStatus(BridgeStatus.starting);
    _bridgeError = null;

    final env = Map<String, String>.from(Platform.environment)
      ..['SYSAI_PATH'] = sysaiPath;

    try {
      _process = await Process.start(
        'python3',
        [bridgeScript],
        environment: env,
        mode: ProcessStartMode.normal,
      );
    } catch (e) {
      _bridgeError = 'Failed to start bridge subprocess: $e';
      _setStatus(BridgeStatus.failed);
      throw BridgeException(_bridgeError!);
    }

    final readyCompleter = Completer<void>();

    _stderrSubscription = _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.trim().isEmpty) return;
            _eventController.add({
              'type': 'bridge_stderr',
              'message': line,
              'timestamp': DateTime.now().toIso8601String(),
            });
          },
          onError: (_) {},
          cancelOnError: false,
        );

    _stdoutSubscription = _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            final trimmed = line.trim();
            if (trimmed.isEmpty) return;

            final json = _parseJsonSafe(trimmed);
            if (!readyCompleter.isCompleted && _isReadyMessage(json)) {
              _applyReadyMessage(json!);
              readyCompleter.complete();
              return;
            }

            _handleLine(trimmed, json);
          },
          onError: (Object error, StackTrace stack) {
            _markUnavailable();
            _setStatus(BridgeStatus.failed);
            if (!readyCompleter.isCompleted) {
              readyCompleter.completeError(
                BridgeException('Bridge stdout error: $error'),
                stack,
              );
            }
            _failAllPending('Bridge stdout error: $error');
          },
          onDone: () {
            _markUnavailable();
            if (_status != BridgeStatus.failed) {
              _setStatus(BridgeStatus.disconnected);
            }
            if (!readyCompleter.isCompleted) {
              readyCompleter.completeError(
                const BridgeException(
                    'Bridge process exited before sending ready handshake.'),
              );
            }
            _failAllPending('Bridge process exited unexpectedly.');
            _closeAllStreaming('Bridge process exited unexpectedly.');
          },
          cancelOnError: false,
        );

    _process!.exitCode.then((code) {
      _markUnavailable();
      if (!readyCompleter.isCompleted) {
        readyCompleter.completeError(
          BridgeException('Bridge process exited with code $code before ready.'),
        );
      }
      _failAllPending('Bridge process exited with code $code.');
      _closeAllStreaming('Bridge process exited with code $code.');
    });

    try {
      await readyCompleter.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      _bridgeError = 'Bridge ready handshake timed out after 10s.';
      _setStatus(BridgeStatus.failed);
      throw BridgeException(_bridgeError!);
    }
  }

  Future<void> stop() async {
    _ready = false;
    _available = false;
    _setStatus(BridgeStatus.disconnected);

    await _stdoutSubscription?.cancel();
    _stdoutSubscription = null;
    await _stderrSubscription?.cancel();
    _stderrSubscription = null;

    _process?.kill();
    await _process?.exitCode.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        _process?.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    _process = null;

    _failAllPending('BridgeService stopped.');
    _closeAllStreaming('BridgeService stopped.');
  }

  Future<void> dispose() async {
    await stop();
    await _eventController.close();
    await _statusController.close();
  }

  // -------------------------------------------------------------------------
  // Request / Response
  // -------------------------------------------------------------------------

  Future<Map<String, dynamic>> call(
    String method, {
    Map<String, dynamic>? params,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!_ready) {
      throw const BridgeException('Bridge is not ready. Call start() first.');
    }

    final id = _nextId();
    final completer = Completer<Map<String, dynamic>>();
    _pendingRequests[id] = completer;

    _sendRequest({
      'id': id,
      'method': method,
      'params': params ?? {},
    });

    try {
      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          _pendingRequests.remove(id);
          throw BridgeException(
            'Request "$method" (id: $id) timed out after ${timeout.inSeconds}s.',
            code: 'TIMEOUT',
          );
        },
      );
    } catch (e) {
      _pendingRequests.remove(id);
      rethrow;
    }
  }

  Stream<Map<String, dynamic>> callStreaming(
    String method, {
    Map<String, dynamic>? params,
  }) {
    if (!_ready) {
      return Stream.error(
        const BridgeException('Bridge is not ready. Call start() first.'),
      );
    }

    final id = _nextId();
    final controller = StreamController<Map<String, dynamic>>(
      onCancel: () {
        _streamingRequests.remove(id);
        try {
          _sendRequest({'id': id, 'method': 'cancel', 'params': {}});
        } catch (_) {}
      },
    );

    _streamingRequests[id] = controller;
    _sendRequest({
      'id': id,
      'method': method,
      'params': params ?? {},
    });

    return controller.stream;
  }

  /// Fetches all capabilities from the Capability Registry.
  Future<List<Capability>> listCapabilities() async {
    final res = await call('list_capabilities');
    final caps = res['capabilities'] as List<dynamic>? ?? [];
    return caps
        .map((c) => Capability.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  /// Resolves an interactive approval request.
  Future<bool> resolveApproval(String requestId, bool approved) async {
    final res = await call('resolve_approval', params: {
      'request_id': requestId,
      'approved': approved,
    });
    return res['resolved'] as bool? ?? false;
  }

  /// Reports the real result of a Controlled Computer Use action back to
  /// the bridge — mirrors [resolveApproval]: the Python capability handler
  /// is blocked in `ComputerActionManager.wait_for_result()` on the other
  /// end, and this call is what unblocks it.
  Future<bool> reportComputerActionResult(String requestId, Map<String, dynamic> result) async {
    final res = await call('report_computer_action_result', params: {
      'request_id': requestId,
      'result': result,
    });
    return res['resolved'] as bool? ?? false;
  }

  /// Pauses an active run cooperatively.
  Future<bool> pauseRun(String runId) async {
    final res = await call('pause_run', params: {'run_id': runId});
    return res['paused'] as bool? ?? false;
  }

  /// Resumes a paused run.
  Future<bool> resumeRun(String runId) async {
    final res = await call('resume_run', params: {'run_id': runId});
    return res['resumed'] as bool? ?? false;
  }

  /// Cancels an active run and terminates any running child subprocesses.
  Future<bool> cancelRun(String runId) async {
    final res = await call('cancel_run', params: {'run_id': runId});
    return res['cancelled'] as bool? ?? false;
  }

  /// Lists workspace entries using the filesystem.list capability.
  Future<List<Map<String, dynamic>>> listWorkspaceFiles({String? path}) async {
    final res = await call('list_workspace_files', params: {
      'path': ?path,
    });
    final entries = res['entries'] as List<dynamic>? ?? [];
    return entries.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Reads a workspace file using the filesystem.read capability.
  Future<Map<String, dynamic>> readWorkspaceFile(String path) async {
    return await call('read_workspace_file', params: {'path': path});
  }

  /// Discovers available providers from the SysAI integration layer.
  Future<List<ProviderInfo>> listProviders() async {
    final res = await call('list_providers');
    final providers = res['providers'] as List<dynamic>? ?? [];
    return providers
        .map((p) => ProviderInfo.fromJson(p as Map<String, dynamic>))
        .toList();
  }

  /// Discovers available models from SysAI providers.
  Future<List<ModelInfo>> listModels() async {
    final res = await call('list_models');
    final models = res['models'] as List<dynamic>? ?? [];
    return models
        .map((m) => ModelInfo.fromJson(m as Map<String, dynamic>))
        .toList();
  }

  /// Verifies whether a specific provider/model is genuinely available.
  Future<Map<String, dynamic>> checkModelAvailability(
      String provider, String model) async {
    return await call('check_model_availability', params: {
      'provider': provider,
      'model': model,
    });
  }

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  void _setStatus(BridgeStatus s) {
    _status = s;
    if (!_statusController.isClosed) {
      _statusController.add(s);
    }
  }

  void _handleLine(String line, Map<String, dynamic>? json) {
    if (json == null) {
      _eventController.add({
        'type': 'bridge_raw',
        'data': line,
        'timestamp': DateTime.now().toIso8601String(),
      });
      return;
    }

    final id = json['id'] as String?;
    final type = json['type'] as String?;
    final isDone = json['done'] == true || type == 'done' || type == 'complete';

    // Streaming handler
    if (id != null && _streamingRequests.containsKey(id)) {
      final ctrl = _streamingRequests[id]!;
      if (json['ok'] == false || type == 'error') {
        final errMsg = _extractError(json);
        ctrl.addError(BridgeException(errMsg, code: json['code'] as String?));
        _streamingRequests.remove(id);
        ctrl.close();
        return;
      }

      if (json.containsKey('event')) {
        ctrl.add(json['event'] as Map<String, dynamic>);
      } else {
        ctrl.add(json);
      }

      if (isDone) {
        if (json.containsKey('result')) {
          ctrl.add({'_final_result': true, ...(json['result'] as Map<String, dynamic>)});
        }
        _streamingRequests.remove(id);
        ctrl.close();
      }
      return;
    }

    // One-shot handler
    if (id != null && _pendingRequests.containsKey(id)) {
      final completer = _pendingRequests.remove(id)!;
      if (json['ok'] == false || type == 'error') {
        final errMsg = _extractError(json);
        completer.completeError(BridgeException(errMsg, code: json['code'] as String?));
        return;
      }
      final result = json['result'] is Map<String, dynamic>
          ? json['result'] as Map<String, dynamic>
          : json;
      completer.complete(result);
      return;
    }

    // Unsolicited event
    _eventController.add(json);
  }

  void _sendRequest(Map<String, dynamic> request) {
    try {
      _process?.stdin.writeln(jsonEncode(request));
    } catch (e) {
      throw BridgeException('Failed to write to bridge stdin: $e');
    }
  }

  String _nextId() => 'req-${++_idCounter}';

  bool _isReadyMessage(Map<String, dynamic>? json) =>
      json != null && json['type'] == 'ready';

  void _applyReadyMessage(Map<String, dynamic> json) {
    _ready = true;
    _available = json['sysai_available'] == true;
    _sysaiVersion = json['sysai_version'] as String?;
    _sysaiPath = json['sysai_path'] as String?;
    _setStatus(
        _available ? BridgeStatus.connected : BridgeStatus.sysaiUnavailable);
  }

  void _markUnavailable() {
    _ready = false;
    _available = false;
  }

  void _failAllPending(String reason) {
    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(BridgeException(reason));
      }
    }
    _pendingRequests.clear();
  }

  void _closeAllStreaming(String reason) {
    for (final ctrl in _streamingRequests.values) {
      ctrl.addError(BridgeException(reason));
      ctrl.close();
    }
    _streamingRequests.clear();
  }

  String _extractError(Map<String, dynamic> json) {
    final err = json['error'];
    if (err is String) return err;
    if (err is Map<String, dynamic>) {
      return err['message'] as String? ?? err.toString();
    }
    return json['message'] as String? ?? 'Unknown error';
  }

  Map<String, dynamic>? _parseJsonSafe(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return null;
  }
}

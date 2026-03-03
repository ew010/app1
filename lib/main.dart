import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

void main() {
  runApp(const AndroidControllerApp());
}

class AndroidControllerApp extends StatelessWidget {
  const AndroidControllerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ADB Controller',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF155EEF)),
        useMaterial3: true,
      ),
      home: const ControllerPage(),
    );
  }
}

class AndroidDevice {
  const AndroidDevice({
    required this.serial,
    required this.state,
    required this.model,
  });

  final String serial;
  final String state;
  final String model;

  bool get online => state == 'device';
}

class ControllerPage extends StatefulWidget {
  const ControllerPage({super.key, this.autoRefresh = true});

  final bool autoRefresh;

  @override
  State<ControllerPage> createState() => _ControllerPageState();
}

class _ControllerPageState extends State<ControllerPage> {
  final TextEditingController _connectAddressController =
      TextEditingController();
  final TextEditingController _textInputController = TextEditingController();

  final List<String> _logs = <String>[];

  List<AndroidDevice> _devices = <AndroidDevice>[];
  String? _selectedSerial;
  Process? _scrcpyProcess;
  StreamSubscription<String>? _scrcpyStdoutSub;
  StreamSubscription<String>? _scrcpyStderrSub;

  bool _busy = false;
  String _adbPath = 'adb';
  String _scrcpyPath = 'scrcpy';
  bool get _supportsHostControl =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  @override
  void initState() {
    super.initState();
    _initializeToolPaths();
    if (widget.autoRefresh) {
      unawaited(_refreshDevices());
    }
  }

  @override
  void dispose() {
    _scrcpyStdoutSub?.cancel();
    _scrcpyStderrSub?.cancel();
    _scrcpyProcess?.kill(ProcessSignal.sigterm);

    _connectAddressController.dispose();
    _textInputController.dispose();
    super.dispose();
  }

  void _addLog(String message) {
    final String timestamp = DateTime.now().toIso8601String();
    setState(() {
      _logs.add('[$timestamp] $message');
      if (_logs.length > 300) {
        _logs.removeRange(0, _logs.length - 300);
      }
    });
  }

  Future<ProcessResult> _runProcess(String executable, List<String> args) {
    return Process.run(
      executable,
      args,
      runInShell: true,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
  }

  void _initializeToolPaths() {
    _adbPath = _defaultAdbPath();
    _scrcpyPath = _defaultScrcpyPath();
  }

  String _defaultAdbPath() {
    return _findToolBinary(<String>[
          Platform.isWindows ? 'adb.exe' : 'adb',
          'platform-tools/${Platform.isWindows ? 'adb.exe' : 'adb'}',
        ]) ??
        'adb';
  }

  String _defaultScrcpyPath() {
    return _findToolBinary(<String>[
          Platform.isWindows ? 'scrcpy.exe' : 'scrcpy',
          'scrcpy/${Platform.isWindows ? 'scrcpy.exe' : 'scrcpy'}',
        ]) ??
        'scrcpy';
  }

  String? _findToolBinary(List<String> relativeCandidates) {
    for (final String toolsRoot in _toolRootDirectories()) {
      for (final String relativePath in relativeCandidates) {
        final File candidate = File('$toolsRoot/$relativePath');
        if (candidate.existsSync()) {
          return candidate.path;
        }
      }
    }
    return null;
  }

  List<String> _toolRootDirectories() {
    final String executableDir = File(Platform.resolvedExecutable).parent.path;
    final List<String> candidates = <String>[
      '$executableDir/tools',
      '${Directory.current.path}/tools',
    ];
    if (Platform.isMacOS) {
      final String resourcesDir =
          '${Directory(executableDir).parent.path}/Resources';
      candidates.insert(0, '$resourcesDir/tools');
    }
    return candidates.toSet().toList();
  }

  String? _workingDirectoryForExecutable(String executablePath) {
    final File executable = File(executablePath);
    if (!executable.existsSync()) {
      return null;
    }
    return executable.parent.path;
  }

  Future<void> _refreshDevices() async {
    if (!_supportsHostControl) {
      return;
    }
    setState(() => _busy = true);
    try {
      final ProcessResult result = await _runProcess(_adbPath, <String>[
        'devices',
        '-l',
      ]);
      if (result.exitCode != 0) {
        _addLog('adb devices failed: ${result.stderr}'.trim());
        return;
      }

      final List<AndroidDevice> parsed = _parseDevices(result.stdout as String);
      setState(() {
        _devices = parsed;
        if (_selectedSerial != null &&
            !_devices.any((AndroidDevice d) => d.serial == _selectedSerial)) {
          _selectedSerial = null;
        }
      });
      _addLog('Found ${parsed.length} device(s).');
    } catch (error) {
      _addLog('Failed to refresh devices: $error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  List<AndroidDevice> _parseDevices(String raw) {
    final List<AndroidDevice> devices = <AndroidDevice>[];
    final List<String> lines = raw
        .split('\n')
        .map((String e) => e.trim())
        .where((String e) => e.isNotEmpty)
        .toList();

    for (final String line in lines) {
      if (line.startsWith('List of devices attached')) {
        continue;
      }
      final List<String> tokens = line.split(RegExp(r'\s+'));
      if (tokens.length < 2) {
        continue;
      }

      final String serial = tokens[0];
      final String state = tokens[1];
      String model = 'unknown';
      for (final String token in tokens.skip(2)) {
        if (token.startsWith('model:')) {
          model = token.substring('model:'.length);
          break;
        }
      }
      devices.add(AndroidDevice(serial: serial, state: state, model: model));
    }

    return devices;
  }

  Future<void> _connectOverTcp() async {
    if (!_supportsHostControl) {
      _addLog('ADB/scrcpy control is only supported on desktop builds.');
      return;
    }
    final String address = _connectAddressController.text.trim();
    if (address.isEmpty) {
      _addLog('Please enter device address, e.g. 192.168.1.100:5555');
      return;
    }

    setState(() => _busy = true);
    try {
      final ProcessResult result = await _runProcess(_adbPath, <String>[
        'connect',
        address,
      ]);
      final String output = '${result.stdout}\n${result.stderr}'.trim();
      _addLog('adb connect $address => $output');
      await _refreshDevices();
    } catch (error) {
      _addLog('Failed to connect: $error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _disconnectSelected() async {
    if (!_supportsHostControl) {
      _addLog('ADB/scrcpy control is only supported on desktop builds.');
      return;
    }
    if (_selectedSerial == null) {
      _addLog('Please select a device first.');
      return;
    }

    setState(() => _busy = true);
    try {
      final ProcessResult result = await _runProcess(_adbPath, <String>[
        'disconnect',
        _selectedSerial!,
      ]);
      final String output = '${result.stdout}\n${result.stderr}'.trim();
      _addLog('adb disconnect ${_selectedSerial!} => $output');
      await _refreshDevices();
    } catch (error) {
      _addLog('Failed to disconnect: $error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _startScrcpy() async {
    if (!_supportsHostControl) {
      _addLog('ADB/scrcpy control is only supported on desktop builds.');
      return;
    }
    if (_selectedSerial == null) {
      _addLog('Please select a device first.');
      return;
    }
    if (_scrcpyProcess != null) {
      _addLog('scrcpy is already running.');
      return;
    }

    try {
      final Process process = await Process.start(
        _scrcpyPath,
        <String>['-s', _selectedSerial!, '--stay-awake'],
        runInShell: true,
        workingDirectory: _workingDirectoryForExecutable(_scrcpyPath),
        environment: <String, String>{'ADB': _adbPath},
      );

      _scrcpyProcess = process;
      _scrcpyStdoutSub = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((String line) => _addLog('scrcpy: $line'));
      _scrcpyStderrSub = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((String line) => _addLog('scrcpy err: $line'));

      unawaited(
        process.exitCode.then((int code) {
          _addLog('scrcpy exited with code $code');
          _scrcpyStdoutSub?.cancel();
          _scrcpyStderrSub?.cancel();
          if (mounted) {
            setState(() => _scrcpyProcess = null);
          }
        }),
      );

      setState(() {});
      _addLog('scrcpy started for device ${_selectedSerial!}');
    } catch (error) {
      _addLog('Failed to start scrcpy: $error');
    }
  }

  Future<void> _stopScrcpy() async {
    if (_scrcpyProcess == null) {
      _addLog('scrcpy is not running.');
      return;
    }
    _scrcpyProcess?.kill(ProcessSignal.sigterm);
    _addLog('Sent stop signal to scrcpy.');
    setState(() => _scrcpyProcess = null);
  }

  Future<void> _sendKeyEvent(String keyCode) async {
    if (!_supportsHostControl) {
      _addLog('ADB/scrcpy control is only supported on desktop builds.');
      return;
    }
    if (_selectedSerial == null) {
      _addLog('Please select a device first.');
      return;
    }

    try {
      final ProcessResult result = await _runProcess(_adbPath, <String>[
        '-s',
        _selectedSerial!,
        'shell',
        'input',
        'keyevent',
        keyCode,
      ]);
      if (result.exitCode == 0) {
        _addLog('Sent keyevent $keyCode');
      } else {
        _addLog('Failed keyevent $keyCode: ${result.stderr}'.trim());
      }
    } catch (error) {
      _addLog('Failed keyevent $keyCode: $error');
    }
  }

  Future<void> _sendText() async {
    if (!_supportsHostControl) {
      _addLog('ADB/scrcpy control is only supported on desktop builds.');
      return;
    }
    if (_selectedSerial == null) {
      _addLog('Please select a device first.');
      return;
    }

    final String text = _textInputController.text.trim();
    if (text.isEmpty) {
      _addLog('Text is empty.');
      return;
    }

    final String encodedText = text.replaceAll(' ', '%s');
    try {
      final ProcessResult result = await _runProcess(_adbPath, <String>[
        '-s',
        _selectedSerial!,
        'shell',
        'input',
        'text',
        encodedText,
      ]);
      if (result.exitCode == 0) {
        _addLog('Sent text: $text');
      } else {
        _addLog('Failed sending text: ${result.stderr}'.trim());
      }
    } catch (error) {
      _addLog('Failed sending text: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Android Controller (adb + scrcpy)')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: <Widget>[
            if (!_supportsHostControl) _buildPlatformWarning(),
            if (!_supportsHostControl) const SizedBox(height: 12),
            _buildDeviceSection(),
            const SizedBox(height: 12),
            _buildActionSection(),
            const SizedBox(height: 12),
            _buildLogsSection(),
          ],
        ),
      ),
    );
  }

  Widget _buildPlatformWarning() {
    return Card(
      color: const Color(0xFFFFF4E5),
      child: const Padding(
        padding: EdgeInsets.all(12),
        child: Text(
          'This build is running on Android. adb/scrcpy remote control '
          'requires a desktop host (macOS/Windows/Linux).',
        ),
      ),
    );
  }

  Widget _buildDeviceSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _connectAddressController,
                    decoration: const InputDecoration(
                      labelText: 'Device IP:PORT (e.g. 192.168.1.10:5555)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : _connectOverTcp,
                  child: const Text('Connect'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _busy ? null : _refreshDevices,
                  child: const Text('Refresh'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _busy ? null : _disconnectSelected,
                  child: const Text('Disconnect'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 120,
              child: _devices.isEmpty
                  ? const Center(child: Text('No devices found.'))
                  : ListView.builder(
                      itemCount: _devices.length,
                      itemBuilder: (BuildContext context, int index) {
                        final AndroidDevice device = _devices[index];
                        final String label =
                            '${device.serial} | ${device.model} | ${device.state}';
                        return ListTile(
                          selected: _selectedSerial == device.serial,
                          title: Text(label),
                          subtitle: Text(
                            device.online ? 'online' : 'not ready',
                          ),
                          trailing: _selectedSerial == device.serial
                              ? const Icon(Icons.check_circle)
                              : const Icon(Icons.circle_outlined),
                          onTap: () =>
                              setState(() => _selectedSerial = device.serial),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionSection() {
    const List<MapEntry<String, String>> keyButtons =
        <MapEntry<String, String>>[
          MapEntry<String, String>('HOME', 'KEYCODE_HOME'),
          MapEntry<String, String>('BACK', 'KEYCODE_BACK'),
          MapEntry<String, String>('APP_SWITCH', 'KEYCODE_APP_SWITCH'),
          MapEntry<String, String>('POWER', 'KEYCODE_POWER'),
          MapEntry<String, String>('VOL_UP', 'KEYCODE_VOLUME_UP'),
          MapEntry<String, String>('VOL_DOWN', 'KEYCODE_VOLUME_DOWN'),
        ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                FilledButton(
                  onPressed: _startScrcpy,
                  child: Text(
                    _scrcpyProcess == null ? 'Start scrcpy' : 'Running...',
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _stopScrcpy,
                  child: const Text('Stop scrcpy'),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextField(
                    controller: _textInputController,
                    decoration: const InputDecoration(
                      labelText: 'Send text via adb input text',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _sendText,
                  child: const Text('Send Text'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: keyButtons
                  .map(
                    (MapEntry<String, String> e) => ElevatedButton(
                      onPressed: () => _sendKeyEvent(e.value),
                      child: Text(e.key),
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogsSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SizedBox(
          height: 260,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text('Logs', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.all(8),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _logs.isEmpty ? 'No logs yet.' : _logs.join('\n'),
                      style: const TextStyle(
                        color: Colors.greenAccent,
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

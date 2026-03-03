import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _profilesPrefsKey = 'car_link_profiles_v1';
const String _selectedProfilePrefsKey = 'car_link_selected_profile_v1';

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

class CarLinkProfile {
  const CarLinkProfile({
    required this.id,
    required this.name,
    required this.ip,
    required this.pairPort,
    required this.connectPort,
    required this.pairCode,
    required this.packageName,
  });

  final String id;
  final String name;
  final String ip;
  final String pairPort;
  final String connectPort;
  final String pairCode;
  final String packageName;

  factory CarLinkProfile.initial() {
    final String ts = DateTime.now().millisecondsSinceEpoch.toString();
    return CarLinkProfile(
      id: 'profile_$ts',
      name: '我的手机',
      ip: '',
      pairPort: '37099',
      connectPort: '5555',
      pairCode: '',
      packageName: 'com.android.settings',
    );
  }

  factory CarLinkProfile.fromJson(String raw) {
    final Map<String, dynamic> json = jsonDecode(raw) as Map<String, dynamic>;
    return CarLinkProfile(
      id: json['id'] as String,
      name: json['name'] as String? ?? '未命名设备',
      ip: json['ip'] as String? ?? '',
      pairPort: json['pair_port'] as String? ?? '37099',
      connectPort: json['connect_port'] as String? ?? '5555',
      pairCode: json['pair_code'] as String? ?? '',
      packageName: json['package_name'] as String? ?? 'com.android.settings',
    );
  }

  String toJson() {
    return jsonEncode(<String, String>{
      'id': id,
      'name': name,
      'ip': ip,
      'pair_port': pairPort,
      'connect_port': connectPort,
      'pair_code': pairCode,
      'package_name': packageName,
    });
  }

  CarLinkProfile copyWith({
    String? id,
    String? name,
    String? ip,
    String? pairPort,
    String? connectPort,
    String? pairCode,
    String? packageName,
  }) {
    return CarLinkProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      ip: ip ?? this.ip,
      pairPort: pairPort ?? this.pairPort,
      connectPort: connectPort ?? this.connectPort,
      pairCode: pairCode ?? this.pairCode,
      packageName: packageName ?? this.packageName,
    );
  }
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

  final TextEditingController _profileNameController = TextEditingController();
  final TextEditingController _assistantIpController = TextEditingController();
  final TextEditingController _assistantPairPortController =
      TextEditingController(text: '37099');
  final TextEditingController _assistantConnectPortController =
      TextEditingController(text: '5555');
  final TextEditingController _assistantPairCodeController =
      TextEditingController();
  final TextEditingController _assistantPackageController =
      TextEditingController(text: 'com.android.settings');

  final List<String> _logs = <String>[];

  List<AndroidDevice> _devices = <AndroidDevice>[];
  String? _selectedSerial;
  Process? _scrcpyProcess;
  StreamSubscription<String>? _scrcpyStdoutSub;
  StreamSubscription<String>? _scrcpyStderrSub;

  List<CarLinkProfile> _profiles = <CarLinkProfile>[];
  String? _selectedProfileId;
  bool _profilesReady = false;

  bool _busy = false;
  String _adbPath = 'adb';
  String _scrcpyPath = 'scrcpy';

  bool get _supportsHostControl =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  bool get _isAndroidAssistant => Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    _initializeToolPaths();
    if (_isAndroidAssistant) {
      unawaited(_loadProfiles());
    }
    if (widget.autoRefresh && _supportsHostControl) {
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

    _profileNameController.dispose();
    _assistantIpController.dispose();
    _assistantPairPortController.dispose();
    _assistantConnectPortController.dispose();
    _assistantPairCodeController.dispose();
    _assistantPackageController.dispose();

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

  Future<void> _loadProfiles() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<String> rawList =
          prefs.getStringList(_profilesPrefsKey) ?? <String>[];
      final List<CarLinkProfile> loaded = <CarLinkProfile>[];
      for (final String raw in rawList) {
        try {
          loaded.add(CarLinkProfile.fromJson(raw));
        } catch (_) {
          // Ignore broken profile row.
        }
      }
      if (loaded.isEmpty) {
        loaded.add(CarLinkProfile.initial());
      }

      final String? selected = prefs.getString(_selectedProfilePrefsKey);
      final String selectedId =
          loaded.any((CarLinkProfile p) => p.id == selected)
          ? selected!
          : loaded.first.id;

      if (!mounted) {
        return;
      }
      setState(() {
        _profiles = loaded;
        _selectedProfileId = selectedId;
        _profilesReady = true;
      });
      _applyProfileToForm(_selectedProfile ?? loaded.first);
      _addLog('已加载 ${loaded.length} 个设备档案');
    } catch (error) {
      _addLog('加载档案失败: $error');
      if (mounted) {
        setState(() => _profilesReady = true);
      }
    }
  }

  Future<void> _persistProfiles() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _profilesPrefsKey,
      _profiles.map((CarLinkProfile p) => p.toJson()).toList(),
    );
    if (_selectedProfileId != null) {
      await prefs.setString(_selectedProfilePrefsKey, _selectedProfileId!);
    }
  }

  CarLinkProfile get _draftProfile {
    final String id =
        _selectedProfileId ??
        'profile_${DateTime.now().millisecondsSinceEpoch}';
    return CarLinkProfile(
      id: id,
      name: _profileNameController.text.trim(),
      ip: _assistantIpController.text.trim(),
      pairPort: _assistantPairPortController.text.trim().isEmpty
          ? '37099'
          : _assistantPairPortController.text.trim(),
      connectPort: _assistantConnectPortController.text.trim().isEmpty
          ? '5555'
          : _assistantConnectPortController.text.trim(),
      pairCode: _assistantPairCodeController.text.trim(),
      packageName: _assistantPackageController.text.trim().isEmpty
          ? 'com.android.settings'
          : _assistantPackageController.text.trim(),
    );
  }

  CarLinkProfile? get _selectedProfile {
    if (_selectedProfileId == null) {
      return null;
    }
    for (final CarLinkProfile profile in _profiles) {
      if (profile.id == _selectedProfileId) {
        return profile;
      }
    }
    return null;
  }

  String? _validateProfile(CarLinkProfile profile) {
    if (profile.name.isEmpty) {
      return '请填写设备名称';
    }
    if (profile.ip.isEmpty) {
      return '请填写设备IP';
    }
    return null;
  }

  void _applyProfileToForm(CarLinkProfile profile) {
    _profileNameController.text = profile.name;
    _assistantIpController.text = profile.ip;
    _assistantPairPortController.text = profile.pairPort;
    _assistantConnectPortController.text = profile.connectPort;
    _assistantPairCodeController.text = profile.pairCode;
    _assistantPackageController.text = profile.packageName;
  }

  Future<void> _saveProfile() async {
    final CarLinkProfile profile = _draftProfile;
    final String? validation = _validateProfile(profile);
    if (validation != null) {
      _addLog(validation);
      return;
    }

    final int idx = _profiles.indexWhere(
      (CarLinkProfile p) => p.id == profile.id,
    );
    setState(() {
      if (idx >= 0) {
        _profiles[idx] = profile;
      } else {
        _profiles.add(profile);
      }
      _selectedProfileId = profile.id;
    });
    await _persistProfiles();
    _addLog('已保存档案: ${profile.name}');
  }

  Future<void> _newProfile() async {
    final CarLinkProfile profile = CarLinkProfile.initial();
    setState(() {
      _selectedProfileId = profile.id;
      _profiles.add(profile);
    });
    _applyProfileToForm(profile);
    await _persistProfiles();
    _addLog('已创建新档案');
  }

  Future<void> _deleteSelectedProfile() async {
    if (_selectedProfileId == null) {
      return;
    }
    if (_profiles.length == 1) {
      _addLog('至少保留一个档案');
      return;
    }

    setState(() {
      _profiles.removeWhere((CarLinkProfile p) => p.id == _selectedProfileId);
      _selectedProfileId = _profiles.first.id;
    });
    _applyProfileToForm(_profiles.first);
    await _persistProfiles();
    _addLog('已删除当前档案');
  }

  Future<void> _selectProfile(CarLinkProfile profile) async {
    setState(() => _selectedProfileId = profile.id);
    _applyProfileToForm(profile);
    await _persistProfiles();
  }

  List<MapEntry<String, String>> _assistantCommands() {
    final CarLinkProfile profile = _draftProfile;
    if (profile.ip.isEmpty) {
      return const <MapEntry<String, String>>[
        MapEntry<String, String>('提示', '请先填写设备IP，再生成命令'),
      ];
    }

    final String address = '${profile.ip}:${profile.connectPort}';
    final List<MapEntry<String, String>> rows = <MapEntry<String, String>>[
      MapEntry<String, String>(
        '配对',
        profile.pairCode.isEmpty
            ? '请先填写 Pair Code'
            : 'adb pair ${profile.ip}:${profile.pairPort} ${profile.pairCode}',
      ),
      MapEntry<String, String>('连接', 'adb connect $address'),
      MapEntry<String, String>(
        'HOME 键',
        'adb -s $address shell input keyevent KEYCODE_HOME',
      ),
      MapEntry<String, String>(
        '返回键',
        'adb -s $address shell input keyevent KEYCODE_BACK',
      ),
      MapEntry<String, String>(
        '任务键',
        'adb -s $address shell input keyevent KEYCODE_APP_SWITCH',
      ),
      MapEntry<String, String>(
        '启动应用',
        'adb -s $address shell monkey -p ${profile.packageName} -c android.intent.category.LAUNCHER 1',
      ),
    ];
    return rows;
  }

  Future<void> _copyCommand(String command, String label) async {
    if (command.startsWith('请先')) {
      _addLog(command);
      return;
    }
    await Clipboard.setData(ClipboardData(text: command));
    _addLog('已复制命令: $label');
  }

  Future<void> _copyAllCommands() async {
    final List<String> commands = _assistantCommands()
        .map((MapEntry<String, String> e) => e.value)
        .where((String cmd) => !cmd.startsWith('请先'))
        .toList();
    if (commands.isEmpty) {
      _addLog('没有可复制的命令');
      return;
    }
    await Clipboard.setData(ClipboardData(text: commands.join('\n')));
    _addLog('已复制全部命令');
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
      appBar: AppBar(
        title: Text(
          _isAndroidAssistant
              ? '车机互联 (ADB Assistant V1)'
              : 'Android Controller (adb + scrcpy)',
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: <Widget>[
            if (_isAndroidAssistant) ...<Widget>[
              _buildAndroidAssistantIntro(),
              const SizedBox(height: 12),
              _buildProfileEditor(),
              const SizedBox(height: 12),
              _buildProfileList(),
              const SizedBox(height: 12),
              _buildAndroidAssistantCommands(),
            ] else ...<Widget>[
              _buildDeviceSection(),
              const SizedBox(height: 12),
              _buildActionSection(),
            ],
            const SizedBox(height: 12),
            _buildLogsSection(),
          ],
        ),
      ),
    );
  }

  Widget _buildAndroidAssistantIntro() {
    return Card(
      color: const Color(0xFFFFF4E5),
      child: const Padding(
        padding: EdgeInsets.all(12),
        child: Text(
          '目标：在车机上管理手机互联配置，生成并复制 ADB 无线调试命令。\n'
          '说明：完整屏幕镜像控制（scrcpy）仍建议在桌面端使用。',
        ),
      ),
    );
  }

  Widget _buildProfileEditor() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('设备档案', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _profileNameController,
              decoration: const InputDecoration(
                labelText: '设备名称（例如：小米15）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _assistantIpController,
              decoration: const InputDecoration(
                labelText: '设备 IP（例如：192.168.1.88）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _assistantPairPortController,
                    decoration: const InputDecoration(
                      labelText: 'Pair 端口',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _assistantConnectPortController,
                    decoration: const InputDecoration(
                      labelText: 'Connect 端口',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _assistantPairCodeController,
              decoration: const InputDecoration(
                labelText: 'Pair Code',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _assistantPackageController,
              decoration: const InputDecoration(
                labelText: '默认启动包名（可选）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton(
                  onPressed: _saveProfile,
                  child: const Text('保存档案'),
                ),
                OutlinedButton(
                  onPressed: _newProfile,
                  child: const Text('新建档案'),
                ),
                OutlinedButton(
                  onPressed: _deleteSelectedProfile,
                  child: const Text('删除当前档案'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileList() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('档案列表', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (!_profilesReady)
              const SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              )
            else
              SizedBox(
                height: 180,
                child: ListView.builder(
                  itemCount: _profiles.length,
                  itemBuilder: (BuildContext context, int index) {
                    final CarLinkProfile profile = _profiles[index];
                    return ListTile(
                      dense: true,
                      selected: profile.id == _selectedProfileId,
                      title: Text(profile.name),
                      subtitle: Text(
                        profile.ip.isEmpty
                            ? '未填写IP'
                            : '${profile.ip}:${profile.connectPort}',
                      ),
                      trailing: profile.id == _selectedProfileId
                          ? const Icon(Icons.check_circle)
                          : const Icon(Icons.circle_outlined),
                      onTap: () => _selectProfile(profile),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAndroidAssistantCommands() {
    final List<MapEntry<String, String>> commands = _assistantCommands();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Expanded(
                  child: Text(
                    '快捷命令',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                FilledButton(
                  onPressed: _copyAllCommands,
                  child: const Text('复制全部'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...commands.map(
              (MapEntry<String, String> row) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _buildCommandRow(row.key, row.value),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCommandRow(String label, String command) {
    final bool copyable = !command.startsWith('请先');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFD8D8D8)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          SelectableText(
            command,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          const SizedBox(height: 6),
          FilledButton.tonal(
            onPressed: copyable ? () => _copyCommand(command, label) : null,
            child: Text('复制 $label'),
          ),
        ],
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

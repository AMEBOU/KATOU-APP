// Application de contrôle des billets KATOU – Billetterie Togo.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String kApiBase = String.fromEnvironment('API_BASE', defaultValue: 'http://10.0.2.2:3000');

const _offlineMsg = 'Le serveur ne répond pas. Vérifiez la connexion internet (Wi-Fi ou données mobiles).';
final _hashRe = RegExp(r'^[a-f0-9]{64}$');
const _cooldown = Duration(seconds: 4);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const ScanApp());
}

// ───────────────────────────── API ─────────────────────────────

enum Outcome { valid, used, invalid, error, unauthorized }

class ScanResult {
  const ScanResult(this.outcome, this.headline, {this.lines = const [], this.retry = false});
  final Outcome outcome;
  final String headline;
  final List<String> lines;
  final bool retry;
}

class ApiException implements Exception {
  ApiException(this.message);
  final String message;
}

class Api {
  static const _timeout = Duration(seconds: 8);

  static Map<String, String> _headers([String? token]) =>
      {'Content-Type': 'application/json', if (token != null) 'Authorization': 'Bearer $token'};

  static Map<String, dynamic> _json(String s) {
    try {
      final d = jsonDecode(s);
      return d is Map<String, dynamic> ? d : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static bool _isNetwork(Object e) =>
      e is TimeoutException || e is SocketException || e is HandshakeException || e is http.ClientException;

  static String _time(String? iso) {
    final d = DateTime.tryParse(iso ?? '')?.toLocal();
    if (d == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    final now = DateTime.now();
    final hm = '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
    final today = d.year == now.year && d.month == now.month && d.day == now.day;
    return today ? hm : '${two(d.day)}/${two(d.month)} à $hm';
  }

  static Future<Map<String, dynamic>> login(String phone, String password) async {
    try {
      final res = await http
          .post(Uri.parse('$kApiBase/api/auth/login'),
              headers: _headers(), body: jsonEncode({'phone': phone, 'password': password}))
          .timeout(_timeout);
      final body = _json(res.body);
      if (res.statusCode == 200) return body;
      final err = body['error'];
      throw ApiException(err is Map && err['message'] != null ? '${err['message']}' : 'Connexion refusée (${res.statusCode})');
    } catch (e) {
      if (e is ApiException) rethrow;
      if (_isNetwork(e)) throw ApiException(_offlineMsg);
      throw ApiException('Erreur inattendue : $e');
    }
  }

  static Future<ScanResult> scan(String token, String hash) async {
    try {
      final res = await http
          .post(Uri.parse('$kApiBase/api/tickets/scan'), headers: _headers(token), body: jsonEncode({'qr_hash': hash}))
          .timeout(_timeout);
      final body = _json(res.body);

      if (res.statusCode == 200 && body['valid'] == true) {
        final t = body['ticket'] is Map ? Map<String, dynamic>.from(body['ticket'] as Map) : <String, dynamic>{};
        return ScanResult(Outcome.valid, 'VALIDE',
            lines: ['${t['ticket_type'] ?? ''}', '${t['event_title'] ?? ''}'].where((s) => s.isNotEmpty).toList());
      }
      if (res.statusCode == 401 || res.statusCode == 403) {
        return const ScanResult(Outcome.unauthorized, 'SESSION EXPIRÉE',
            lines: ['Reconnectez-vous pour continuer à scanner.']);
      }
      if (res.statusCode == 429) {
        return const ScanResult(Outcome.error, 'TROP RAPIDE',
            lines: ['Patientez quelques secondes puis réessayez.'], retry: true);
      }

      final err = body['error'] is Map ? Map<String, dynamic>.from(body['error'] as Map) : <String, dynamic>{};
      final details = err['details'] is Map ? Map<String, dynamic>.from(err['details'] as Map) : <String, dynamic>{};
      switch (err['code']) {
        case 'DEJA_UTILISE':
          return ScanResult(Outcome.used, 'DÉJÀ UTILISÉ', lines: ['1er scan : ${_time(details['scanned_at'] as String?)}']);
        case 'BILLET_INCONNU':
          return const ScanResult(Outcome.invalid, 'FAUX BILLET', lines: ['Billet inconnu ou d\'un autre événement']);
        case 'BILLET_ANNULE':
          return const ScanResult(Outcome.invalid, 'BILLET ANNULÉ');
        case 'EVENEMENT_NON_ACTIF':
          return const ScanResult(Outcome.invalid, 'ÉVÉNEMENT NON ACTIF', lines: ["Ce billet n'est pas valable ici."]);
      }
      return ScanResult(Outcome.error, 'ERREUR SERVEUR (${res.statusCode})',
          lines: ['Réessayez dans un instant.'], retry: true);
    } catch (e) {
      if (_isNetwork(e)) return const ScanResult(Outcome.error, 'PAS DE CONNEXION', lines: [_offlineMsg], retry: true);
      return ScanResult(Outcome.error, 'ERREUR', lines: ['$e'], retry: true);
    }
  }
}

// ───────────────────────────── Application KATOU ─────────────────────────────

class ScanApp extends StatelessWidget {
  const ScanApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'KATOU',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true, brightness: Brightness.dark, colorSchemeSeed: const Color(0xFF0B4F3A)),
        home: const Root(),
      );
}

class Root extends StatefulWidget {
  const Root({super.key});
  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> {
  SharedPreferences? _prefs;
  String? _token;
  String _name = '';

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) => setState(() {
          _prefs = p;
          _token = p.getString('token');
          _name = p.getString('name') ?? '';
        }));
  }

  Future<void> _onLogin(String token, String name) async {
    await _prefs!.setString('token', token);
    await _prefs!.setString('name', name);
    setState(() {
      _token = token;
      _name = name;
    });
  }

  Future<void> _logout() async {
    await _prefs?.remove('token');
    setState(() => _token = null);
  }

  @override
  Widget build(BuildContext context) {
    if (_prefs == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_token == null) return LoginPage(onLogin: _onLogin);
    return ScannerPage(key: ValueKey(_token), token: _token!, name: _name, onLogout: _logout);
  }
}

// ───────────────────────────── Connexion ─────────────────────────────

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.onLogin});
  final Future<void> Function(String token, String name) onLogin;
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _phone = TextEditingController();
  final _pass = TextEditingController();
  bool _loading = false;
  String? _error;

  Future<void> _submit() async {
    if (_phone.text.trim().isEmpty || _pass.text.isEmpty) {
      setState(() => _error = 'Saisissez votre téléphone et votre mot de passe.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await Api.login(_phone.text.trim(), _pass.text);
      final user = Map<String, dynamic>.from(r['user'] as Map);
      if (!['SCANNER', 'ORGANIZER', 'ADMIN'].contains(user['role'])) {
        throw ApiException("Ce compte n'est pas autorisé à contrôler les billets.");
      }
      await widget.onLogin('${r['token']}', '${user['full_name']}');
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _phone.dispose();
    _pass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Icon(Icons.qr_code_scanner, size: 72),
                  const SizedBox(height: 12),
                  const Text('KATOU',
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900)),
                  const Text('Contrôle des billets',
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 18, color: Colors.grey)),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    autofillHints: const [AutofillHints.telephoneNumber],
                    decoration: const InputDecoration(labelText: 'Téléphone', hintText: '90 12 34 56', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _pass,
                    obscureText: true,
                    onSubmitted: (_) => _submit(),
                    decoration: const InputDecoration(labelText: 'Mot de passe', border: OutlineInputBorder()),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 16)),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    height: 52,
                    child: FilledButton(
                      onPressed: _loading ? null : _submit,
                      child: _loading
                          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Se connecter', style: TextStyle(fontSize: 18)),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
}

// ───────────────────────────── Scanner ─────────────────────────────

class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key, required this.token, required this.name, required this.onLogout});
  final String token;
  final String name;
  final Future<void> Function() onLogout;
  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _busy = false;
  bool _torch = false;
  int _validated = 0;
  ScanResult? _result;
  String? _pending;
  String? _lastHash;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _auto;

  @override
  void dispose() {
    _auto?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_busy || capture.barcodes.isEmpty) return;
    final raw = capture.barcodes.first.rawValue;
    if (raw == null) return;
    final hash = raw.trim().toLowerCase();
    if (hash == _lastHash && DateTime.now().difference(_lastAt) < _cooldown) return;
    _lastHash = hash;
    _lastAt = DateTime.now();
    _check(hash);
  }

  Future<void> _check(String hash) async {
    setState(() {
      _busy = true;
      _result = null;
    });
    final ScanResult r = _hashRe.hasMatch(hash)
        ? await Api.scan(widget.token, hash)
        : const ScanResult(Outcome.invalid, 'FAUX BILLET', lines: ["Ce QR code n'est pas un billet"]);
    if (!mounted) return;
    _pending = r.retry ? hash : null;
    switch (r.outcome) {
      case Outcome.valid:
        HapticFeedback.mediumImpact();
        _validated++;
        _auto = Timer(const Duration(seconds: 2), _reset);
      case Outcome.used:
        HapticFeedback.heavyImpact();
      case Outcome.invalid:
      case Outcome.error:
      case Outcome.unauthorized:
        HapticFeedback.vibrate();
    }
    setState(() => _result = r);
  }

  void _reset() {
    _auto?.cancel();
    if (!mounted) return;
    setState(() {
      _result = null;
      _busy = false;
      _pending = null;
      _lastAt = DateTime.now();
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        MobileScanner(
          controller: _controller,
          onDetect: _onDetect,
          errorBuilder: (context, error, child) => const Center(
              child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text("Caméra indisponible.\nAutorisez l'accès à la caméra dans les réglages du téléphone.",
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 18)))),
        ),
        IgnorePointer(
          child: Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 3), borderRadius: BorderRadius.circular(24)),
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(children: [
              Chip(avatar: const Icon(Icons.check_circle, color: Colors.green), label: Text('KATOU : $_validated validés')),
              const Spacer(),
              IconButton(
                tooltip: 'Lampe',
                icon: Icon(_torch ? Icons.flash_on : Icons.flash_off),
                onPressed: () async {
                  await _controller.toggleTorch();
                  setState(() => _torch = !_torch);
                },
              ),
              IconButton(tooltip: 'Déconnexion', icon: const Icon(Icons.logout), onPressed: widget.onLogout),
            ]),
          ),
        ),
        const Positioned(
          left: 0,
          right: 0,
          bottom: 48,
          child: IgnorePointer(
              child: Text('Placez le QR code dans le cadre',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 18, shadows: [Shadow(blurRadius: 6)]))),
        ),
        if (_busy && r == null)
          const Center(child: Card(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator()))),
        if (r != null)
          Positioned.fill(
            child: ResultView(
              result: r,
              onNext: r.outcome == Outcome.unauthorized ? widget.onLogout : _reset,
              onRetry: _pending == null ? null : () => _check(_pending!),
            ),
          ),
      ]),
    );
  }
}

// ───────────────────────────── Écran de résultat ─────────────────────────────

class ResultView extends StatelessWidget {
  const ResultView({super.key, required this.result, required this.onNext, this.onRetry});
  final ScanResult result;
  final VoidCallback onNext;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final color = switch (result.outcome) {
      Outcome.valid => const Color(0xFF1B8F3A),
      Outcome.used => const Color(0xFFEF7C00),
      Outcome.invalid => const Color(0xFFC62828),
      Outcome.error || Outcome.unauthorized => const Color(0xFF37474F),
    };
    final icon = switch (result.outcome) {
      Outcome.valid => Icons.check_circle_outline,
      Outcome.used => Icons.warning_amber_rounded,
      Outcome.invalid => Icons.cancel_outlined,
      Outcome.error => Icons.wifi_off_rounded,
      Outcome.unauthorized => Icons.lock_outline,
    };
    final nextLabel = result.outcome == Outcome.unauthorized ? 'SE RECONNECTER' : 'SPECTATEUR SUIVANT';

    return Material(
      color: color,
      child: InkWell(
        onTap: onNext,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Spacer(),
              Icon(icon, size: 128, color: Colors.white),
              const SizedBox(height: 16),
              Text(result.headline,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w900, color: Colors.white)),
              const SizedBox(height: 12),
              for (final l in result.lines)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(l, textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, color: Colors.white)),
                ),
              const Spacer(),
              if (onRetry != null) ...[
                SizedBox(
                  height: 60,
                  child: OutlinedButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('RÉESSAYER', style: TextStyle(fontSize: 20)),
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white, width: 2)),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              SizedBox(
                height: 76,
                child: FilledButton(
                  onPressed: onNext,
                  style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: color),
                  child: Text(nextLabel, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

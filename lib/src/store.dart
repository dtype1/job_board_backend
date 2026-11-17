import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Persistenza minimale: tutti i dati vivono in memoria e a ogni modifica
/// vengono riscritti su `data/db.json`. I curriculum sono salvati come file
/// in `data/uploads/`. Alla ripartenza del server lo stato viene ricaricato.
class Store {
  Store(this.dataDir)
      : _dbFile = File(p.join(dataDir, 'db.json')),
        uploadsDir = Directory(p.join(dataDir, 'uploads'));

  final String dataDir;
  final File _dbFile;
  final Directory uploadsDir;

  final _random = Random.secure();

  List<Map<String, dynamic>> companies = [];
  List<Map<String, dynamic>> jobs = [];
  List<Map<String, dynamic>> applications = [];

  /// token -> companyId
  Map<String, String> sessions = {};

  /// Le scritture vengono serializzate per evitare file corrotti.
  Future<void> _pendingWrite = Future.value();

  Future<void> load() async {
    await uploadsDir.create(recursive: true);
    if (!await _dbFile.exists()) {
      await save();
      return;
    }
    final data = jsonDecode(await _dbFile.readAsString()) as Map<String, dynamic>;
    companies = _list(data['companies']);
    jobs = _list(data['jobs']);
    applications = _list(data['applications']);
    sessions = Map<String, String>.from(data['sessions'] as Map? ?? {});
  }

  static List<Map<String, dynamic>> _list(Object? raw) =>
      (raw as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  Future<void> save() {
    final json = const JsonEncoder.withIndent('  ').convert({
      'companies': companies,
      'jobs': jobs,
      'applications': applications,
      'sessions': sessions,
    });
    _pendingWrite = _pendingWrite.then((_) async {
      // Scrittura atomica: file temporaneo + rename.
      final tmp = File('${_dbFile.path}.tmp');
      await tmp.writeAsString(json, flush: true);
      await tmp.rename(_dbFile.path);
    });
    return _pendingWrite;
  }

  String newId() => _randomHex(8);

  String newToken() => _randomHex(32);

  String _randomHex(int bytes) =>
      List.generate(bytes, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

  // ---------- Password ----------

  String newSalt() => _randomHex(16);

  /// PBKDF2 semplificato: SHA-256 iterato con salt.
  String hashPassword(String password, String salt) {
    List<int> digest = utf8.encode('$salt:$password');
    for (var i = 0; i < 10000; i++) {
      digest = sha256.convert([...digest, ...utf8.encode(salt)]).bytes;
    }
    return base64Encode(digest);
  }

  // ---------- Query helpers ----------

  Map<String, dynamic>? companyById(String id) =>
      companies.where((c) => c['id'] == id).firstOrNull;

  Map<String, dynamic>? companyByEmail(String email) =>
      companies.where((c) => c['email'] == email).firstOrNull;

  Map<String, dynamic>? jobById(String id) => jobs.where((j) => j['id'] == id).firstOrNull;

  Map<String, dynamic>? applicationById(String id) =>
      applications.where((a) => a['id'] == id).firstOrNull;

  List<Map<String, dynamic>> applicationsForJob(String jobId) =>
      applications.where((a) => a['jobId'] == jobId).toList();
}

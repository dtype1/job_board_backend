import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'store.dart';

const _maxCvBytes = 10 * 1024 * 1024; // 10 MB
const _allowedCvExtensions = {'.pdf', '.doc', '.docx'};
final _emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// Definisce tutti gli endpoint REST dell'applicazione.
class Api {
  Api(this.store);

  final Store store;

  Router get router {
    final r = Router();

    r.get('/api/health', (Request _) => _json({'status': 'ok'}));

    // ----- Autenticazione aziende (R1, R2, R3) -----
    r.post('/api/auth/register', _register);
    r.post('/api/auth/login', _login);
    r.post('/api/auth/logout', _logout);
    r.get('/api/auth/me', _me);

    // ----- Bacheca pubblica (R5) -----
    r.get('/api/jobs', _listJobs);
    r.get('/api/jobs/<id>', _getJob);

    // ----- Candidatura pubblica (R6) -----
    r.post('/api/jobs/<id>/applications', _apply);

    // ----- Area riservata azienda (R4, R7) -----
    r.post('/api/jobs', _createJob);
    r.get('/api/company/jobs', _myJobs);
    r.get('/api/company/jobs/<id>/applications', _jobApplications);
    r.get('/api/company/applications/<id>', _getApplication);
    r.get('/api/company/applications/<id>/cv', _downloadCv);

    return r;
  }

  // ======================= Auth =======================

  Future<Response> _register(Request req) async {
    final body = await _readJson(req);
    if (body == null) return _error(400, 'JSON non valido');

    final name = (body['name'] as String? ?? '').trim();
    final email = (body['email'] as String? ?? '').trim().toLowerCase();
    final password = body['password'] as String? ?? '';

    if (name.isEmpty) return _error(400, 'Il nome dell\'azienda è obbligatorio');
    if (!_emailRegex.hasMatch(email)) return _error(400, 'Email non valida');
    if (password.length < 6) {
      return _error(400, 'La password deve contenere almeno 6 caratteri');
    }
    if (store.companyByEmail(email) != null) {
      return _error(409, 'Esiste già un account con questa email');
    }

    final salt = store.newSalt();
    final company = {
      'id': store.newId(),
      'name': name,
      'email': email,
      'description': (body['description'] as String? ?? '').trim(),
      'passwordSalt': salt,
      'passwordHash': store.hashPassword(password, salt),
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };
    store.companies.add(company);
    await store.save();
    return _json(_publicCompany(company), status: 201);
  }

  Future<Response> _login(Request req) async {
    final body = await _readJson(req);
    if (body == null) return _error(400, 'JSON non valido');

    final email = (body['email'] as String? ?? '').trim().toLowerCase();
    final password = body['password'] as String? ?? '';
    final company = store.companyByEmail(email);

    if (company == null ||
        store.hashPassword(password, company['passwordSalt'] as String) !=
            company['passwordHash']) {
      return _error(401, 'Email o password errati');
    }

    final token = store.newToken();
    store.sessions[token] = company['id'] as String;
    await store.save();
    return _json({'token': token, 'company': _publicCompany(company)});
  }

  Future<Response> _logout(Request req) async {
    final token = _bearerToken(req);
    if (token != null && store.sessions.remove(token) != null) {
      await store.save();
    }
    return Response(204);
  }

  Response _me(Request req) {
    final company = _authenticate(req);
    if (company == null) return _unauthorized();
    return _json(_publicCompany(company));
  }

  // ======================= Annunci =======================

  Response _listJobs(Request req) {
    final list = [...store.jobs]..sort(
        (a, b) => (b['createdAt'] as String).compareTo(a['createdAt'] as String));
    return _json(list.map(_publicJob).toList());
  }

  Response _getJob(Request req, String id) {
    final job = store.jobById(id);
    if (job == null) return _error(404, 'Annuncio non trovato');
    return _json(_publicJob(job));
  }

  Future<Response> _createJob(Request req) async {
    final company = _authenticate(req);
    if (company == null) return _unauthorized();

    final body = await _readJson(req);
    if (body == null) return _error(400, 'JSON non valido');

    final title = (body['title'] as String? ?? '').trim();
    final description = (body['description'] as String? ?? '').trim();
    if (title.isEmpty) return _error(400, 'Il titolo è obbligatorio');
    if (description.isEmpty) return _error(400, 'La descrizione è obbligatoria');

    final job = {
      'id': store.newId(),
      'companyId': company['id'],
      'title': title,
      'description': description,
      'location': (body['location'] as String? ?? '').trim(),
      'contractType': (body['contractType'] as String? ?? '').trim(),
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };
    store.jobs.add(job);
    await store.save();
    return _json(_publicJob(job), status: 201);
  }

  Response _myJobs(Request req) {
    final company = _authenticate(req);
    if (company == null) return _unauthorized();

    final mine = store.jobs.where((j) => j['companyId'] == company['id']).toList()
      ..sort((a, b) => (b['createdAt'] as String).compareTo(a['createdAt'] as String));

    return _json(mine
        .map((j) => {
              ..._publicJob(j),
              'applicationsCount': store.applicationsForJob(j['id'] as String).length,
            })
        .toList());
  }

  // ======================= Candidature =======================

  Future<Response> _apply(Request req, String jobId) async {
    final job = store.jobById(jobId);
    if (job == null) return _error(404, 'Annuncio non trovato');

    final contentType = req.headers['content-type'];
    if (contentType == null || !contentType.startsWith('multipart/form-data')) {
      return _error(400, 'Attesa una richiesta multipart/form-data');
    }
    final boundary = HeaderValue.parse(contentType).parameters['boundary'];
    if (boundary == null) return _error(400, 'Boundary multipart mancante');

    final fields = <String, String>{};
    String? cvFileName;
    Uint8List? cvBytes;

    try {
      await for (final part in MimeMultipartTransformer(boundary).bind(req.read())) {
        final disposition = HeaderValue.parse(
          part.headers['content-disposition'] ?? '',
          preserveBackslash: true,
        );
        final name = disposition.parameters['name'];
        final filename = disposition.parameters['filename'];

        final builder = BytesBuilder(copy: false);
        await for (final chunk in part) {
          builder.add(chunk);
          if (builder.length > _maxCvBytes) {
            return _error(413, 'Il curriculum supera la dimensione massima di 10 MB');
          }
        }

        if (name == 'cv' && filename != null) {
          cvFileName = p.basename(filename);
          cvBytes = builder.takeBytes();
        } else if (name != null) {
          fields[name] = utf8.decode(builder.takeBytes()).trim();
        }
      }
    } on Object {
      return _error(400, 'Richiesta multipart non valida');
    }

    final firstName = fields['firstName'] ?? '';
    final lastName = fields['lastName'] ?? '';
    final email = (fields['email'] ?? '').toLowerCase();

    if (firstName.isEmpty) return _error(400, 'Il nome è obbligatorio');
    if (lastName.isEmpty) return _error(400, 'Il cognome è obbligatorio');
    if (!_emailRegex.hasMatch(email)) return _error(400, 'Email non valida');
    if (cvBytes == null || cvBytes.isEmpty || cvFileName == null) {
      return _error(400, 'Il curriculum è obbligatorio');
    }
    final ext = p.extension(cvFileName).toLowerCase();
    if (!_allowedCvExtensions.contains(ext)) {
      return _error(400, 'Formato curriculum non supportato (usa PDF, DOC o DOCX)');
    }

    final id = store.newId();
    final storedName = '$id$ext';
    await File(p.join(store.uploadsDir.path, storedName)).writeAsBytes(cvBytes, flush: true);

    final application = {
      'id': id,
      'jobId': jobId,
      'firstName': firstName,
      'lastName': lastName,
      'email': email,
      'phone': fields['phone'] ?? '',
      'message': fields['message'] ?? '',
      'cvFileName': cvFileName,
      'cvStoredName': storedName,
      'cvSize': cvBytes.length,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };
    store.applications.add(application);
    await store.save();
    return _json(_publicApplication(application), status: 201);
  }

  Response _jobApplications(Request req, String jobId) {
    final company = _authenticate(req);
    if (company == null) return _unauthorized();

    final job = store.jobById(jobId);
    if (job == null || job['companyId'] != company['id']) {
      return _error(404, 'Annuncio non trovato');
    }
    final list = store.applicationsForJob(jobId)
      ..sort((a, b) => (b['createdAt'] as String).compareTo(a['createdAt'] as String));
    return _json(list.map(_publicApplication).toList());
  }

  Response _getApplication(Request req, String id) {
    final company = _authenticate(req);
    if (company == null) return _unauthorized();

    final application = _ownedApplication(company, id);
    if (application == null) return _error(404, 'Candidatura non trovata');
    return _json(_publicApplication(application));
  }

  Future<Response> _downloadCv(Request req, String id) async {
    final company = _authenticate(req);
    if (company == null) return _unauthorized();

    final application = _ownedApplication(company, id);
    if (application == null) return _error(404, 'Candidatura non trovata');

    final file = File(p.join(store.uploadsDir.path, application['cvStoredName'] as String));
    if (!await file.exists()) return _error(404, 'File non trovato');

    final fileName = application['cvFileName'] as String;
    return Response.ok(
      file.openRead(),
      headers: {
        'content-type': lookupMimeType(fileName) ?? 'application/octet-stream',
        'content-length': '${await file.length()}',
        'content-disposition': 'inline; filename="${fileName.replaceAll('"', '')}"',
      },
    );
  }

  /// Restituisce la candidatura solo se appartiene a un annuncio dell'azienda.
  Map<String, dynamic>? _ownedApplication(Map<String, dynamic> company, String id) {
    final application = store.applicationById(id);
    if (application == null) return null;
    final job = store.jobById(application['jobId'] as String);
    if (job == null || job['companyId'] != company['id']) return null;
    return application;
  }

  // ======================= Helpers =======================

  String? _bearerToken(Request req) {
    final header = req.headers['authorization'];
    if (header == null || !header.startsWith('Bearer ')) return null;
    return header.substring(7).trim();
  }

  Map<String, dynamic>? _authenticate(Request req) {
    final token = _bearerToken(req);
    if (token == null) return null;
    final companyId = store.sessions[token];
    return companyId == null ? null : store.companyById(companyId);
  }

  Map<String, dynamic> _publicCompany(Map<String, dynamic> c) => {
        'id': c['id'],
        'name': c['name'],
        'email': c['email'],
        'description': c['description'] ?? '',
      };

  Map<String, dynamic> _publicJob(Map<String, dynamic> j) => {
        'id': j['id'],
        'companyId': j['companyId'],
        'companyName': store.companyById(j['companyId'] as String)?['name'] ?? '',
        'title': j['title'],
        'description': j['description'],
        'location': j['location'] ?? '',
        'contractType': j['contractType'] ?? '',
        'createdAt': j['createdAt'],
      };

  Map<String, dynamic> _publicApplication(Map<String, dynamic> a) => {
        'id': a['id'],
        'jobId': a['jobId'],
        'jobTitle': store.jobById(a['jobId'] as String)?['title'] ?? '',
        'firstName': a['firstName'],
        'lastName': a['lastName'],
        'email': a['email'],
        'phone': a['phone'] ?? '',
        'message': a['message'] ?? '',
        'cvFileName': a['cvFileName'],
        'cvSize': a['cvSize'],
        'createdAt': a['createdAt'],
      };

  Future<Map<String, dynamic>?> _readJson(Request req) async {
    try {
      final decoded = jsonDecode(await req.readAsString());
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  Response _json(Object data, {int status = 200}) => Response(
        status,
        body: jsonEncode(data),
        headers: {'content-type': 'application/json; charset=utf-8'},
      );

  Response _error(int status, String message) => _json({'error': message}, status: status);

  Response _unauthorized() => _error(401, 'Autenticazione richiesta');
}

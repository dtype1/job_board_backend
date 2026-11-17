import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:job_board_backend/job_board_backend.dart';
import 'package:shelf/shelf_io.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late HttpServer server;
  late String base;

  Future<void> startServer() async {
    final store = Store(tmp.path);
    await store.load();
    server = await serve(Api(store).router.call, InternetAddress.loopbackIPv4, 0);
    base = 'http://localhost:${server.port}';
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('job_board_test');
    await startServer();
  });

  tearDown(() async {
    await server.close(force: true);
    await tmp.delete(recursive: true);
  });

  Map<String, String> jsonHeaders([String? token]) => {
        'content-type': 'application/json',
        if (token != null) 'authorization': 'Bearer $token',
      };

  test('scenari S1, S2, S3 completi + persistenza', () async {
    // ---- S1: registrazione, login, pubblicazione ----
    var res = await http.post(Uri.parse('$base/api/auth/register'),
        headers: jsonHeaders(),
        body: jsonEncode({'name': 'Acme', 'email': 'hr@acme.it', 'password': 'segreta1'}));
    expect(res.statusCode, 201);

    res = await http.post(Uri.parse('$base/api/auth/register'),
        headers: jsonHeaders(),
        body: jsonEncode({'name': 'Acme', 'email': 'hr@acme.it', 'password': 'segreta1'}));
    expect(res.statusCode, 409);

    res = await http.post(Uri.parse('$base/api/auth/login'),
        headers: jsonHeaders(), body: jsonEncode({'email': 'hr@acme.it', 'password': 'sbagliata'}));
    expect(res.statusCode, 401);

    res = await http.post(Uri.parse('$base/api/auth/login'),
        headers: jsonHeaders(), body: jsonEncode({'email': 'hr@acme.it', 'password': 'segreta1'}));
    expect(res.statusCode, 200);
    final token = jsonDecode(res.body)['token'] as String;

    res = await http.post(Uri.parse('$base/api/jobs'),
        headers: jsonHeaders(), body: jsonEncode({'title': 'X', 'description': 'Y'}));
    expect(res.statusCode, 401, reason: 'pubblicare richiede login');

    res = await http.post(Uri.parse('$base/api/jobs'),
        headers: jsonHeaders(token),
        body: jsonEncode({'title': 'Flutter Developer', 'description': 'Sviluppo app', 'location': 'Roma'}));
    expect(res.statusCode, 201);
    final jobId = jsonDecode(res.body)['id'] as String;

    // ---- S2: bacheca pubblica e candidatura ----
    res = await http.get(Uri.parse('$base/api/jobs'));
    final jobs = jsonDecode(res.body) as List;
    expect(jobs.single['title'], 'Flutter Developer');
    expect(jobs.single['companyName'], 'Acme');

    final pdf = utf8.encode('%PDF-1.4 finto curriculum');
    final multipart = http.MultipartRequest('POST', Uri.parse('$base/api/jobs/$jobId/applications'))
      ..fields.addAll({'firstName': 'Mario', 'lastName': 'Rossi', 'email': 'mario@rossi.it'})
      ..files.add(http.MultipartFile.fromBytes('cv', pdf, filename: 'cv mario.pdf'));
    res = await http.Response.fromStream(await multipart.send());
    expect(res.statusCode, 201, reason: res.body);
    final appId = jsonDecode(res.body)['id'] as String;

    // ---- Persistenza: riavvio del server ----
    await server.close(force: true);
    await startServer();

    // ---- S3: consultazione candidature, CV, logout ----
    res = await http.get(Uri.parse('$base/api/company/jobs'), headers: jsonHeaders(token));
    expect((jsonDecode(res.body) as List).single['applicationsCount'], 1);

    res = await http.get(Uri.parse('$base/api/company/jobs/$jobId/applications'),
        headers: jsonHeaders(token));
    expect((jsonDecode(res.body) as List).single['lastName'], 'Rossi');

    res = await http.get(Uri.parse('$base/api/company/applications/$appId/cv'),
        headers: jsonHeaders(token));
    expect(res.statusCode, 200);
    expect(res.bodyBytes, pdf);
    expect(res.headers['content-type'], 'application/pdf');

    res = await http.post(Uri.parse('$base/api/auth/logout'), headers: jsonHeaders(token));
    expect(res.statusCode, 204);

    res = await http.get(Uri.parse('$base/api/company/jobs'), headers: jsonHeaders(token));
    expect(res.statusCode, 401, reason: 'dopo il logout l\'area riservata non è accessibile');
  });

  test('un\'azienda non vede le candidature di un\'altra', () async {
    Future<String> registerAndLogin(String email) async {
      await http.post(Uri.parse('$base/api/auth/register'),
          headers: jsonHeaders(), body: jsonEncode({'name': email, 'email': email, 'password': 'password'}));
      final res = await http.post(Uri.parse('$base/api/auth/login'),
          headers: jsonHeaders(), body: jsonEncode({'email': email, 'password': 'password'}));
      return jsonDecode(res.body)['token'] as String;
    }

    final a = await registerAndLogin('a@a.it');
    final b = await registerAndLogin('b@b.it');
    final res = await http.post(Uri.parse('$base/api/jobs'),
        headers: jsonHeaders(a), body: jsonEncode({'title': 'T', 'description': 'D'}));
    final jobId = jsonDecode(res.body)['id'];

    final other = await http.get(Uri.parse('$base/api/company/jobs/$jobId/applications'),
        headers: jsonHeaders(b));
    expect(other.statusCode, 404);
  });
}

import 'dart:io';

import 'package:job_board_backend/job_board_backend.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart';

Future<void> main(List<String> args) async {
  final port = int.parse(Platform.environment['PORT'] ?? '8080');
  final dataDir = Platform.environment['DATA_DIR'] ?? 'data';

  final store = Store(dataDir);
  await store.load();

  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addHandler(Api(store).router.call);

  // 0.0.0.0: il server è raggiungibile anche dallo smartphone sulla stessa rete Wi-Fi.
  final server = await serve(handler, InternetAddress.anyIPv4, port);
  server.autoCompress = true;

  stdout.writeln('Server in ascolto sulla porta ${server.port}');
  stdout.writeln('Dati salvati in: ${Directory(dataDir).absolute.path}');
  stdout.writeln('Indirizzi utilizzabili dallo smartphone:');
  for (final iface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final addr in iface.addresses) {
      stdout.writeln('  http://${addr.address}:${server.port}   (${iface.name})');
    }
  }
}

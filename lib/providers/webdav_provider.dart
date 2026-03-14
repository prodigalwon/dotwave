import 'dart:typed_data';
import 'package:webdav_client/webdav_client.dart' as webdav;
import '../cloud_backup.dart';

class WebDavProvider implements CloudBackupProvider {
  final String serverUrl;
  final String username;
  final String password;

  webdav.Client? _client;

  WebDavProvider({
    required this.serverUrl,
    required this.username,
    required this.password,
  });

  @override
  String get name => 'WebDAV';

  @override
  String get icon => 'assets/icons/webdav.png';

  @override
  Future<bool> signIn() async {
    try {
      _client = webdav.newClient(
        serverUrl,
        user: username,
        password: password,
        debug: false,
      );
      await _client!.ping();
      return true;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<void> signOut() async {
    _client = null;
  }

  @override
  Future<void> upload(String filename, Uint8List data) async {
    if (_client == null) throw Exception('Not connected');
    await _client!.write('/$filename', data);
  }

  @override
  Future<Uint8List?> download(String filename) async {
    if (_client == null) throw Exception('Not connected');
    try {
      final bytes = await _client!.read('/$filename');
      return Uint8List.fromList(bytes);
    } catch (e) {
      return null;
    }
  }

  @override
  Future<bool> fileExists(String filename) async {
    if (_client == null) return false;
    try {
      await _client!.read('/$filename');
      return true;
    } catch (e) {
      return false;
    }
  }
}

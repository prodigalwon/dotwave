import 'dart:typed_data';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../cloud_backup.dart';

class OneDriveProvider implements CloudBackupProvider {
  static const _clientId = 'YOUR_MICROSOFT_CLIENT_ID';
  static const _redirectUri = 'msauth://com.dotwave.dotwave/callback';
  static const _scopes = 'Files.ReadWrite offline_access';

  String? _accessToken;

  @override
  String get name => 'OneDrive';

  @override
  String get icon => 'assets/icons/onedrive.png';

  @override
  Future<bool> signIn() async {
    // TODO: implement Microsoft OAuth flow
    // Requires Microsoft Azure app registration
    // Placeholder until OAuth is wired up
    return false;
  }

  @override
  Future<void> signOut() async {
    _accessToken = null;
  }

  @override
  Future<void> upload(String filename, Uint8List data) async {
    if (_accessToken == null) throw Exception('Not signed in');
    final response = await http.put(
      Uri.parse('https://graph.microsoft.com/v1.0/me/approot:/$filename:/content'),
      headers: {
        'Authorization': 'Bearer $_accessToken',
        'Content-Type': 'application/octet-stream',
      },
      body: data,
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('Upload failed: ${response.statusCode}');
    }
  }

  @override
  Future<Uint8List?> download(String filename) async {
    if (_accessToken == null) throw Exception('Not signed in');
    final response = await http.get(
      Uri.parse('https://graph.microsoft.com/v1.0/me/approot:/$filename:/content'),
      headers: {'Authorization': 'Bearer $_accessToken'},
    );
    if (response.statusCode == 404) return null;
    if (response.statusCode != 200) throw Exception('Download failed: ${response.statusCode}');
    return response.bodyBytes;
  }

  @override
  Future<bool> fileExists(String filename) async {
    if (_accessToken == null) return false;
    final response = await http.get(
      Uri.parse('https://graph.microsoft.com/v1.0/me/approot:/$filename'),
      headers: {'Authorization': 'Bearer $_accessToken'},
    );
    return response.statusCode == 200;
  }
}

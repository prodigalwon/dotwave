import 'dart:typed_data';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import '../cloud_backup.dart';

class GoogleAuthClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _client = http.Client();

  GoogleAuthClient(this._headers);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _client.send(request..headers.addAll(_headers));
  }
}

class GoogleDriveProvider implements CloudBackupProvider {
  static const _scopes = [drive.DriveApi.driveAppdataScope];

  GoogleSignInAccount? _account;

  @override
  String get name => 'Google Drive';

  @override
  String get icon => 'assets/icons/google_drive.png';

  @override
  Future<bool> signIn() async {
    try {
      await GoogleSignIn.instance.initialize();
      await GoogleSignIn.instance.authenticate();

      GoogleSignIn.instance.authenticationEvents.listen((event) {
        if (event is GoogleSignInAuthenticationEventSignIn) {
          _account = event.user;
        } else if (event is GoogleSignInAuthenticationEventSignOut) {
          _account = null;
        }
      });

      // Wait briefly for the event to fire
      await Future.delayed(const Duration(milliseconds: 500));
      return _account != null;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<void> signOut() async {
    _account = null;
  }

  Future<drive.DriveApi> _getDriveApi() async {
    if (_account == null) throw Exception('Not signed in');
    final authz = await _account!.authorizationClient.authorizeScopes(_scopes);
    final headers = {'Authorization': 'Bearer ${authz.accessToken}'};
    return drive.DriveApi(GoogleAuthClient(headers));
  }

  @override
  Future<void> upload(String filename, Uint8List data) async {
    final api = await _getDriveApi();
    final file = drive.File()
      ..name = filename
      ..parents = ['appDataFolder'];

    final existing = await _findFile(api, filename);
    if (existing != null) {
      await api.files.update(
        drive.File(),
        existing,
        uploadMedia: drive.Media(Stream.value(data), data.length),
      );
    } else {
      await api.files.create(
        file,
        uploadMedia: drive.Media(Stream.value(data), data.length),
      );
    }
  }

  @override
  Future<Uint8List?> download(String filename) async {
    final api = await _getDriveApi();
    final fileId = await _findFile(api, filename);
    if (fileId == null) return null;

    final response = await api.files.get(
      fileId,
      downloadOptions: drive.DownloadOptions.fullMedia,
    ) as drive.Media;

    final bytes = <int>[];
    await for (final chunk in response.stream) {
      bytes.addAll(chunk);
    }
    return Uint8List.fromList(bytes);
  }

  @override
  Future<bool> fileExists(String filename) async {
    final api = await _getDriveApi();
    return await _findFile(api, filename) != null;
  }

  Future<String?> _findFile(drive.DriveApi api, String filename) async {
    final result = await api.files.list(
      spaces: 'appDataFolder',
      q: "name = '$filename'",
    );
    return result.files?.firstOrNull?.id;
  }
}
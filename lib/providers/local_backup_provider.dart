import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import '../cloud_backup.dart';

class LocalBackupProvider implements CloudBackupProvider {
  @override
  String get name => 'Save to Device';

  @override
  String get icon => 'assets/icons/local.png';

  @override
  Future<bool> signIn() async => true;

  @override
  Future<void> upload(String filename, Uint8List data) async {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save Dotwave Backup',
      fileName: filename,
      bytes: data,
    );
    if (path == null) throw Exception('Save cancelled');
  }

  @override
  Future<Uint8List?> download(String filename) async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Select Dotwave Backup File',
      type: FileType.any,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    return result.files.first.bytes;
  }

  @override
  Future<bool> fileExists(String filename) async => false;

  @override
  Future<void> signOut() async {}
}
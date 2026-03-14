import 'dart:typed_data';

abstract class CloudBackupProvider {
  String get name;
  String get icon;
  
  Future<bool> signIn();
  Future<void> upload(String filename, Uint8List data);
  Future<Uint8List?> download(String filename);
  Future<bool> fileExists(String filename);
  Future<void> signOut();
}

const String kBackupFilename = 'dotwave_backup.dwb';

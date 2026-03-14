import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

class ReceiveScreen extends StatelessWidget {
  final String address;
  const ReceiveScreen({super.key, required this.address});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D0D0D),
        title: const Text('Receive DOT'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: QrImageView(
                  data: address,
                  version: QrVersions.auto,
                  size: 220,
                  backgroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: 32),
              const Text(
                'Your Address',
                style: TextStyle(color: Colors.white60, fontSize: 14),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0xFFE6007A).withOpacity(0.3),
                  ),
                ),
                child: Text(
                  address,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    color: Colors.white,
                    height: 1.6,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: address));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Address copied to clipboard')),
                  );
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy Address'),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE6007A),
                  minimumSize: const Size(double.infinity, 52),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
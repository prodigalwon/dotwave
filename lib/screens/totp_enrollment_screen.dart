import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:dotwave/theme.dart';
import 'package:dotwave/services/totp_enrollment_service.dart';

enum EnrollmentState {
  checkingHardware,
  generatingSeed,
  displayQr,
  verifyOtp,
  generatingIdentity,
  complete,
  hardwareError,
}

class TotpEnrollmentScreen extends StatefulWidget {
  final String username;
  final VoidCallback onComplete;

  const TotpEnrollmentScreen({
    super.key,
    required this.username,
    required this.onComplete,
  });

  @override
  State<TotpEnrollmentScreen> createState() => _TotpEnrollmentScreenState();
}

class _TotpEnrollmentScreenState extends State<TotpEnrollmentScreen> {
  final _service = TotpEnrollmentService();
  final _otpController = TextEditingController();

  EnrollmentState _state = EnrollmentState.checkingHardware;
  String? _otpauthUri;
  String? _errorMessage;
  int _otpAttempts = 0;
  Timer? _reminderTimer;

  @override
  void initState() {
    super.initState();
    _checkHardware();
  }

  @override
  void dispose() {
    _otpController.dispose();
    _reminderTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkHardware() async {
    final available = await _service.isStrongBoxAvailable();
    if (!mounted) return;
    if (available) {
      setState(() => _state = EnrollmentState.generatingSeed);
      _generateSeed();
    } else {
      setState(() {
        _state = EnrollmentState.hardwareError;
        _errorMessage = 'This device does not support the required security '
            'hardware for dotwave identity enrollment. StrongBox is required.';
      });
    }
  }

  Future<void> _generateSeed() async {
    try {
      final uri = await _service.generateAndDisplaySeed(widget.username);
      if (!mounted) return;
      setState(() {
        _otpauthUri = uri;
        _state = EnrollmentState.displayQr;
      });
      // Gentle reminder after 5 minutes
      _reminderTimer = Timer(const Duration(minutes: 5), () {
        if (mounted && _state == EnrollmentState.displayQr) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Remember to save the code before continuing.')),
          );
        }
      });
    } on TotpEnrollmentException catch (e) {
      if (!mounted) return;
      setState(() {
        _state = EnrollmentState.hardwareError;
        // Show the actual reason from the platform (e.g. "No biometric
        // is enrolled on this device. Open Android Settings ...") rather
        // than a generic "Failed, try again" that leaves the user
        // guessing.
        _errorMessage = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _state = EnrollmentState.hardwareError;
        _errorMessage = 'Unexpected error during TOTP setup: $e';
      });
    }
  }

  Future<void> _verifyOtp() async {
    final code = _otpController.text.trim();
    if (code.length != 6) return;

    // Initialize StrongBox Mac for biometric auth
    final macReady = await _service.initMacForBiometric();
    if (!macReady) {
      _showError('Failed to access security hardware.');
      return;
    }

    // BiometricPrompt is triggered by the StrongBox Mac init — the OS handles the UI.
    // After biometric success, verify the OTP.
    final valid = await _service.verifyOtpAfterBiometric(code);

    if (!mounted) return;
    if (valid) {
      setState(() => _state = EnrollmentState.generatingIdentity);
      _generateIdentityKey();
    } else {
      _otpAttempts++;
      if (_otpAttempts >= 3) {
        _showError('Code incorrect. Wait for the next code to appear in your authenticator app, then try again.');
      } else {
        _showError('Code incorrect. Try again.');
      }
    }
  }

  Future<void> _generateIdentityKey() async {
    final pubkey = await _service.generateIdentityKeyPair();
    if (!mounted) return;
    if (pubkey != null) {
      setState(() => _state = EnrollmentState.complete);
    } else {
      setState(() {
        _state = EnrollmentState.hardwareError;
        _errorMessage = 'Failed to generate identity key in secure hardware.';
      });
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppTheme.error),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: const Text('Identity Enrollment'),
        backgroundColor: AppTheme.bg,
        foregroundColor: AppTheme.textPrimary,
        elevation: 0,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: _buildContent(),
        ),
      ),
    );
  }

  Widget _buildContent() {
    switch (_state) {
      case EnrollmentState.checkingHardware:
      case EnrollmentState.generatingSeed:
        return _buildLoading(
          _state == EnrollmentState.checkingHardware
              ? 'Checking security hardware...'
              : 'Setting up your identity...',
        );

      case EnrollmentState.displayQr:
        return _buildQrDisplay();

      case EnrollmentState.verifyOtp:
        return _buildOtpVerification();

      case EnrollmentState.generatingIdentity:
        return _buildLoading('Generating identity key in secure hardware...');

      case EnrollmentState.complete:
        return _buildComplete();

      case EnrollmentState.hardwareError:
        return _buildError();
    }
  }

  Widget _buildLoading(String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: AppTheme.accent),
          const SizedBox(height: 24),
          Text(message, style: const TextStyle(color: AppTheme.textSecondary, fontSize: 16)),
        ],
      ),
    );
  }

  Widget _buildQrDisplay() {
    return SingleChildScrollView(
      child: Column(
        children: [
          const SizedBox(height: 24),
          const Text(
            'Scan this QR code with your authenticator app',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text(
            'Google Authenticator, Authy, or any TOTP-compatible app',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: QrImageView(
              data: _otpauthUri!,
              version: QrVersions.auto,
              size: 220,
            ),
          ),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _otpauthUri!));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied to clipboard')),
              );
            },
            icon: Icon(Icons.copy, color: AppTheme.accent, size: 18),
            label: Text('Copy URI', style: TextStyle(color: AppTheme.accent)),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.warning.withAlpha(25),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.warning.withAlpha(77)),
            ),
            child: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: AppTheme.warning, size: 24),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Save this code now. You will not be able to see it again.',
                    style: TextStyle(color: AppTheme.warning, fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: () {
                _reminderTimer?.cancel();
                setState(() => _state = EnrollmentState.verifyOtp);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text("I've saved it, continue", style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildOtpVerification() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Enter the 6-digit code now showing in your authenticator app',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: 200,
            child: TextField(
              controller: _otpController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 32, letterSpacing: 8),
              decoration: InputDecoration(
                counterText: '',
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: AppTheme.borderMid),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AppTheme.accent),
                ),
              ),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            ),
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _verifyOtp,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Verify', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComplete() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.verified_user, color: AppTheme.success, size: 64),
          const SizedBox(height: 24),
          const Text(
            'Identity enrolled',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 22, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            'Your hardware-bound identity key is ready. Every transaction will require your biometric and authenticator code.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: widget.onComplete,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('Continue', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: AppTheme.error, size: 64),
          const SizedBox(height: 24),
          Text(
            _errorMessage ?? 'An error occurred.',
            style: const TextStyle(color: AppTheme.textPrimary, fontSize: 16),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          TextButton(
            onPressed: () {
              setState(() {
                _state = EnrollmentState.checkingHardware;
                _errorMessage = null;
              });
              _checkHardware();
            },
            child: Text('Try again', style: TextStyle(color: AppTheme.accent)),
          ),
        ],
      ),
    );
  }
}

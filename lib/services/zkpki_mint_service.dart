import 'dart:typed_data';

import '../bridge/bridge_generated.dart/core.dart' as bridge;
import 'zkpki_ceremony_service.dart';

/// Production mint-cert flow. Orchestrates the three steps the pallet's
/// `mint_cert` extrinsic depends on, in order:
///
/// 1. Fetch the 32-byte offer nonce from the ZK-PKI pallet's
///    `ContractOffers` storage for the `(user, issuer)` pair.
/// 2. Run the StrongBox ceremony with that nonce as the attestation
///    challenge — both EC keys call `setAttestationChallenge(nonce)`.
/// 3. Return the full bundle of artifacts needed to construct an
///    `AttestationPayloadV3` for submission.
///
/// This service is deliberately separate from [`ZkPkiCeremonyService`],
/// which remains a pure ceremony wrapper used by the smoke-test screen.
/// The smoke test keeps its random-challenge path (no user/issuer
/// context) so the hardware ceremony can be exercised standalone. The
/// production flow below is what will hang off a real mint UI when the
/// pallet is deployed.
///
/// # State of wiring
///
/// The offer-nonce fetch is currently stubbed to `[0u8; 32]` in
/// `rust_core/src/core.rs` — see the `fetch_zkpki_offer_nonce` doc
/// comment for the exact subxt-storage pattern that replaces it once
/// the ZK-PKI pallet is deployed and its metadata is embedded. Until
/// then, this service runs end-to-end against the stub, which is fine
/// for exercising the flow but cannot produce a cert that the
/// production pallet would accept.
class ZkPkiMintService {
  final ZkPkiCeremonyService _ceremony;

  ZkPkiMintService({ZkPkiCeremonyService? ceremony})
      : _ceremony = ceremony ?? ZkPkiCeremonyService();

  /// Fetch offer nonce for `(userAddress, issuerAddress)` from the
  /// ZK-PKI pallet at `rpcUrl`, then run the StrongBox ceremony using
  /// that nonce as the attestation challenge.
  ///
  /// Throws [`ZkPkiMintException`] if the fetched nonce is not 32
  /// bytes (defensive check against a drifted stub / malformed
  /// storage). Ceremony failures propagate as
  /// [`ZkPkiCeremonyException`].
  Future<ZkPkiMintBundle> startMintFlow({
    required String userAddress,
    required String issuerAddress,
    required String rpcUrl,
  }) async {
    final challenge = await bridge.fetchZkpkiOfferNonce(
      user: userAddress,
      issuer: issuerAddress,
      rpcUrl: rpcUrl,
    );
    if (challenge.length != 32) {
      throw ZkPkiMintException(
        'INVALID_NONCE_LEN',
        'offer nonce must be 32 bytes, got ${challenge.length}',
      );
    }

    final ceremony = await _ceremony.runCeremony(challenge);

    return ZkPkiMintBundle(
      userAddress: userAddress,
      issuerAddress: issuerAddress,
      challenge: challenge,
      ceremony: ceremony,
    );
  }
}

/// Everything the caller needs to build an `AttestationPayloadV3` and
/// submit a `mint_cert` extrinsic. The challenge here is the offer nonce
/// — the same bytes the Kotlin ceremony fed to
/// `setAttestationChallenge` on both EC keys, and the same bytes the
/// pallet's `mint_cert` call receives as its `contract_nonce` argument.
class ZkPkiMintBundle {
  final String userAddress;
  final String issuerAddress;
  final Uint8List challenge;
  final ZkPkiCeremonyResult ceremony;

  ZkPkiMintBundle({
    required this.userAddress,
    required this.issuerAddress,
    required this.challenge,
    required this.ceremony,
  });
}

class ZkPkiMintException implements Exception {
  final String code;
  final String message;
  ZkPkiMintException(this.code, this.message);

  @override
  String toString() => 'ZkPkiMintException($code): $message';
}

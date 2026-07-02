# dotwave membership-auth client plan

Wire the anonymous membership-auth (witnessed-spend) gate into the dotwave phone
app so a chat send is authorized by an on-device ZK proof of membership, not by
the legacy per-drop cert signature. Target flow:

  mint hardware zkpki cert (enrolls a membership leaf)
    -> fetch the leaf's Merkle witness from the chain
    -> prove membership on-device (Groth16)
    -> chat_authenticateMembership -> node-local session (witnessed spend)
    -> send the onion drop signed by the session key

Written 2026-07-02 as the handoff for a separate clean thread. Do the build
there. Nothing here is committed code; each phase below carries its own gate and
the whole thing lands only after the hardware E2E in the last section passes.

---

## Current state (verified 2026-07-02, this session)

### Chain (Rostro `chat-spend-witness` worktree / gemini-runtime; membership + witnessed spend already merged to rostro-main `4a97c2b747`)

- `mint_cert(origin, contract_nonce, attestation_payload, offer_created_at_block,
  hip_proof_at_genesis: Option, commitment_c: Option, ec_key_pub_claimed: Option,
  chat_enrollment: Option<ChatEnrollment>)` at `substrate/frame/zkpki-pallet/src/lib.rs:1769`.
  When `chat_enrollment` is `Some`, it runs `verify_chat_enrollment`, derives the
  leaf, inserts the membership leaf and sets initial freshness
  (`lib.rs:1846-1876`, `lib.rs:2143-2152`). This is what puts you in the trie.
- `ChatEnrollment { id_commitment: [u8;32], id_binding_signature: Vec<u8> }` at
  `substrate/utils/zkpki-tpm/src/chat_enrollment.rs:41`.
  - `id_commitment = Poseidon(s)` for a member secret `s`.
  - `id_binding_signature` = the attested `attest_ec` key signing
    `blake2_256(ID_BINDING_CONTEXT || id_commitment || challenge)`, where
    `challenge` is the offer nonce (`verify_chat_enrollment`, `:63`). It ties the
    commitment to the same silicon that produced the attestation.
- `membership_witness(thumbprint) -> Option<MembershipWitnessData>` at
  `lib.rs:493` (cert-keyed): returns the Merkle authentication path, leaf index,
  roots, and freshness for the cert's enrolled leaf. `membership_root()` at
  `lib.rs:464`.
- Guard: `chat_authenticateMembership` verifies the Groth16 proof, runs the
  witnessed-spend committee, and issues a node-local session; drops within the
  session ride a cheap Ed25519 session key (`chat_send_onion` accepts
  `session_cert_thumbprint_hex` + `session_sig_hex`). Round-robin across guards
  is blocked cross-node ("nullifier already spent this epoch"), proven from the
  desktop via labtool this session.

### dotwave (`chat-spend-witness-labtool-v0`)

- On-device prover is already present: `libark_circom-*.so` bundled in
  `android/app/src/main/jniLibs/*`, the `membership_prover` bin, and the
  `rostro-membership-circuit` / `rostro-membership-tree` / `rostro-poseidon-bn254`
  deps in `rust_core`.
- `lab_authenticate_membership` (`rust_core/src/core.rs`) already implements the
  handshake (build `MembershipCircuit` -> `groth16::prove` -> POST
  `chat_authenticateMembership`), BUT it is `#[frb(ignore)]` (labtool only) and
  builds a single-leaf tree as a SHORTCUT instead of the real chain witness.
- `submit_mint_cert_strongbox` (`core.rs:2121`) passes only 6 args and NO
  `chat_enrollment`; its pinned typed signature is stale versus the live 7-arg
  `mint_cert`, so it would be rejected like `set_record` was.
- The send path `chat_send_onion_2hop` (`rust_core/src/chat.rs:890`) authorizes
  with the per-drop cert (`auth_cert_thumbprint_hex` / `auth_cert_seed_hex`), NOT
  a membership session.
- App onboarding does register + set CHAT/MESSAGE only; it mints no cert.

### Metadata drift (decide the strategy in M0)

The runtime added `RecordType::NODE` and `mint_cert`'s `chat_enrollment` param, so
the pinned `polkadot_metadata.scale` typed `set_record` and `mint_cert` carry
stale per-call validation hashes and are rejected. `set_record` was converted to
`subxt::dynamic::tx` + `Composite` this session (the dotwave dynamic idiom, see
`chat_publish_identity`). `mint_cert` still needs the same treatment or a
metadata refresh.

---

## Gaps to close on the phone

1. Member secret `s`: derive and persist it securely so `id_commitment = Poseidon(s)`
   is stable across epochs (needed to re-prove membership).
2. Mint enrollment: extend the StrongBox ceremony to sign `id_commitment` with
   `attest_ec` (produce `id_binding_signature`), build `ChatEnrollment`, and pass
   it as `mint_cert`'s 7th arg (fixing the stale typed call).
3. Witness retrieval: an FRB/RPC call to `membership_witness(thumbprint)` for the
   real Merkle path, replacing the single-leaf shortcut in
   `lab_authenticate_membership`.
4. Handshake client: promote the handshake to a real FRB function using the real
   witness, freshness, and best-head anchor/epoch; prove on-device; mint a
   per-session Ed25519 key.
5. Send routing: authorize `chat_send_onion(_2hop)` with the session
   (`session_cert_thumbprint_hex` + `session_sig_hex`); handle session TTL and
   epoch rollover (re-handshake).

---

## Decisions to resolve first (M0, in the clean thread)

- `s` derivation and storage: StrongBox-backed or a dedicated persisted secret,
  and reinstall behavior (losing `s` means re-minting to re-enroll).
- Metadata strategy: refresh the pinned `polkadot_metadata.scale` from the
  current runtime (typed calls byte-exact again) versus per-call dynamic
  (`set_record` already went dynamic). Recommendation: refresh so the build is
  coherent, keep dynamic only for calls absent from the pinned metadata.
- UX: the mint's `attest_ec` signing is one biometric crossing; the handshake
  proof is pure compute (no secure element), so it can be silent/background like
  `ensureCert`. Confirm.
- Freshness lifecycle: initial window is granted at enrollment; when it lapses,
  re-attest (HIP continuity bump). Decide if that is in scope now or deferred.
- Send auth: membership session primary; keep the cert-gate path compiled as a
  fallback, or fully replace it. Recommendation: primary session, keep cert path.
- Branch/worktree: propose `/home/coder/Rostro-membership-client` on
  `membership-client-v0` (dotwave side on a matching branch), per the
  new-workstream convention.

---

## Build plan (phased; each phase has a gate)

- M0, decisions + branch. Resolve the above; stand up the worktree/branch.
- M1, secret + enrollment binding. Derive/persist `s`; extend the StrongBox
  ceremony to emit `id_binding_signature`; assemble `ChatEnrollment`.
  Gate: `id_binding_signature` verifies via `verify_chat_enrollment` against the
  ceremony's `attest_ec` pubkey and the offer challenge.
- M2, mint with enrollment. Fix `submit_mint_cert_strongbox` (refreshed-typed or
  dynamic) to pass `chat_enrollment`.
  Gate: mint from the phone, then labtool confirms the membership leaf is
  enrolled and `membership_witness(thumbprint)` returns a path whose recomputed
  root equals `membership_root()`.
- M3, witness FRB. Expose `membership_witness(thumbprint)` to Dart via FRB.
  Gate: the phone fetches its witness and reconstructs the chain
  `membership_root` locally.
- M4, handshake FRB. A real membership-auth FRB call: prove with the real
  witness + freshness + best-head anchor/epoch, POST
  `chat_authenticateMembership`, return the session + session key.
  Gate: the phone authenticates and a session is issued; the guard log shows the
  Groth16 verify plus the witnessed-spend committee co-sign.
- M5, send via session. Route `chat_send_onion_2hop` through the session
  signature; add session lifecycle (re-handshake on TTL/epoch rollover).
  Gate: a phone send is admitted by the session key, not the cert-gate.

---

## End-to-end hardware test (run before any commit)

Rig prep (desktop):
1. `scripts/run-spend-rig.sh` (fresh chain, 2 validators + 3 non-validator guards,
   `--chat-membership-vk`, guards `--rpc-external`).
2. Enroll the 3 guards' NODE records: `labtool enroll-node <name> <nodekey> //Bob`
   (and //Charlie, //Dave; NOT //Alice, which is sudo/root and owns `.rst`).
3. `labtool ferdie-setup ws://127.0.0.1:9944` (recipient identity).
4. `labtool fund <phone_ss58>` and `labtool resolve ferdie ws://127.0.0.1:9954`
   to confirm the recipient.
5. `adb reverse tcp:9954 tcp:9954` (and 9955, 9944).

Phone E2E:
1. Onboard: register name + set CHAT/MESSAGE (dynamic `set_record`, already working).
2. Mint the hardware cert WITH `chat_enrollment` -> membership leaf enrolled.
   Verify: labtool confirms the leaf and `membership_witness` root matches.
3. Membership handshake -> session (guard log: Groth16 verify + committee co-sign
   + session issued).
4. Send to Ferdie under the session key (2-hop onion).
5. Verify delivery: `labtool ferdie-read ws://127.0.0.1:9954` decrypts the phone's
   message.
6. Round-robin: force a second handshake at a different guard in the same epoch
   -> rejected "nullifier already spent this epoch".
7. Freshness lapse behavior, only if M4/M5 put it in scope.

Green criteria: the message decrypts on the Ferdie side; the guard logs show the
membership + witnessed-spend path (not the cert-gate); round-robin is blocked
cross-node. Commit only after this passes (per Tony), as one coherent commit
covering the dotwave client plus any node/labtool support, then propose the merge.

---

## References

- Chain: `mint_cert` `zkpki-pallet/src/lib.rs:1769`; `ChatEnrollment`
  `zkpki-tpm/src/chat_enrollment.rs:41`; `verify_chat_enrollment` `:63`;
  `membership_witness` `lib.rs:493`; `membership_root` `lib.rs:464`;
  test-harness `test_enroll_membership` (shortcut, gemini-only).
- Guard: `chat_authenticateMembership` + session store in
  `gemini-node/src/chat_rpc.rs`; witnessed spend in `chat_spend_protocol.rs` /
  `spend_committee.rs`.
- dotwave: `lab_authenticate_membership`, `submit_mint_cert_strongbox`,
  `chat_publish_identity` (dynamic set_record example) in `rust_core/src/core.rs`;
  `chat_send_onion_2hop` `rust_core/src/chat.rs:890`; `membership_prover` bin;
  labtool subcommands `auth` / `test-enroll` / `enroll-node` / `ferdie-*` /
  `resolve`.
- Keys: membership `pk`/`vk` at
  `/home/coder/rostro-testnet-lab/binaries/membership-keys/`.
- Rig: `/home/coder/Rostro-chat-spend-witness/scripts/run-spend-rig.sh`.
- Related memory: `chat_spend_witness_workstream`, `chat_anon_membership_auth_workstream`,
  `dotwave_chat_send_e2e`, `dotwave_rostro_port`.

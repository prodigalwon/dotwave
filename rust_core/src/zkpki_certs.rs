//! Cert-management reads for the ZK-PKI area (Explore → ZK-PKI → My Certs).
//!
//! Thin phone-side face over two `ZkPkiApi` runtime-API methods:
//! `certs_by_user` (the My Certs list) and `cert_status` (the detail
//! screen). SCALE mirrors are hand-pinned to
//! `zkpki-primitives/src/runtime_api.rs` field order, same convention as
//! `MembershipWitnessDataScale` in `membership.rs` — mirrored instead of
//! imported so the phone `.so` doesn't pull `sp-api`.
//!
//! Enums cross the FRB bridge as display strings ("Active", "Tpm", …):
//! the Dart side only renders them, it never branches on chain semantics
//! beyond active/not-active, which `is_active` carries explicitly.

use std::str::FromStr;

use parity_scale_codec::{Decode, Encode};
use subxt::utils::AccountId32;

use crate::membership::zkpki_state_call;

// ── SCALE mirrors (field/variant order pinned to zkpki-primitives) ──────

#[derive(Decode)]
enum OcspStatusScale {
    Good,
    Revoked,
    Unknown,
}

#[derive(Decode)]
enum RevocationReasonScale {
    Suspended,
    Invalidated,
    Expired,
}

#[derive(Decode, Clone, Copy)]
enum CertStateScale {
    Active,
    Suspended,
    Expired,
    Purged,
}

#[derive(Decode)]
enum EntityStateScale {
    Active,
    Challenge,
    Compromised,
}

#[derive(Decode)]
enum AttestationTypeScale {
    Tpm,
    Packed,
    None,
}

#[derive(Decode)]
enum PopRequirementScale {
    Required,
    NotRequired,
}

#[derive(Decode, PartialEq)]
enum EkuScale {
    ServerAuth,
    ClientAuth,
    CodeSigning,
    EmailProtection,
    ProofOfPersonhood,
    BlockchainSigning,
    IdentityAssertion,
    IssuerCert,
    RootCert,
    SmartContractIssuer,
    ChatAuth,
}

#[derive(Decode)]
struct CertSummaryScale {
    thumbprint: [u8; 32],
    cert_state: CertStateScale,
    expiry_block: u64,
    mint_block: u64,
    attestation_type: AttestationTypeScale,
    manufacturer_verified: bool,
    ekus: Vec<EkuScale>,
}

// Unread fields still decode: SCALE is positional, the full struct must
// be mirrored to reach the fields the UI does use.
#[allow(dead_code)]
#[derive(Decode)]
struct CertStatusResponseScale {
    status: OcspStatusScale,
    this_update: u64,
    next_update: u64,
    revocation_time: Option<u64>,
    revocation_reason: Option<RevocationReasonScale>,
    thumbprint: [u8; 32],
    cert_state: CertStateScale,
    expiry_block: u64,
    mint_block: u64,
    issuer: [u8; 32],
    issuer_status: EntityStateScale,
    issuer_compromised_at_block: Option<u64>,
    root: [u8; 32],
    root_status: EntityStateScale,
    root_compromised_at_block: Option<u64>,
    attestation_type: AttestationTypeScale,
    manufacturer_verified: bool,
    ek_hash: Option<[u8; 32]>,
    template_name: Vec<u8>,
    template_pop_requirement: Option<PopRequirementScale>,
    ekus: Vec<EkuScale>,
}

impl CertStateScale {
    fn label(self) -> String {
        match self {
            CertStateScale::Active => "Active",
            CertStateScale::Suspended => "Suspended",
            CertStateScale::Expired => "Expired",
            CertStateScale::Purged => "Purged",
        }
        .to_string()
    }
}

impl EntityStateScale {
    fn label(&self) -> String {
        match self {
            EntityStateScale::Active => "Active",
            EntityStateScale::Challenge => "Challenged",
            EntityStateScale::Compromised => "Compromised",
        }
        .to_string()
    }
}

impl AttestationTypeScale {
    fn label(&self) -> String {
        match self {
            AttestationTypeScale::Tpm => "Hardware (secure element)",
            AttestationTypeScale::Packed => "Software TPM",
            AttestationTypeScale::None => "Self-attested",
        }
        .to_string()
    }
}

impl EkuScale {
    fn label(&self) -> &'static str {
        match self {
            EkuScale::ServerAuth => "Server auth",
            EkuScale::ClientAuth => "Client auth",
            EkuScale::CodeSigning => "Code signing",
            EkuScale::EmailProtection => "Email protection",
            EkuScale::ProofOfPersonhood => "Proof of personhood",
            EkuScale::BlockchainSigning => "Blockchain signing",
            EkuScale::IdentityAssertion => "Identity assertion",
            EkuScale::IssuerCert => "Issuer",
            EkuScale::RootCert => "Root",
            EkuScale::SmartContractIssuer => "Smart-contract issuer",
            EkuScale::ChatAuth => "Chat auth",
        }
    }
}

/// The full EKU catalog in enum order — the detail screen renders every
/// entry as a read-only checkbox, checked when the cert holds it.
const EKU_CATALOG: [EkuScale; 11] = [
    EkuScale::ServerAuth,
    EkuScale::ClientAuth,
    EkuScale::CodeSigning,
    EkuScale::EmailProtection,
    EkuScale::ProofOfPersonhood,
    EkuScale::BlockchainSigning,
    EkuScale::IdentityAssertion,
    EkuScale::IssuerCert,
    EkuScale::RootCert,
    EkuScale::SmartContractIssuer,
    EkuScale::ChatAuth,
];

// ── FRB-facing types ─────────────────────────────────────────────────────

/// One row of the My Certs list.
pub struct CertSummaryFfi {
    pub thumbprint_hex: String,
    /// "Active" | "Suspended" | "Expired" | "Purged" (display string).
    pub state: String,
    pub is_active: bool,
    pub expiry_block: u64,
    pub mint_block: u64,
    pub attestation_type: String,
    pub manufacturer_verified: bool,
    /// Cert carries the ChatAuth EKU — the declared (EKU ⇔ leaf)
    /// form of "may authenticate to chat guards". Replaces the old
    /// per-cert membership_witness probe for list badging.
    pub chat_auth: bool,
}

/// The My Certs list plus the best block it was read at, so the UI can
/// render expiry countdowns without a second round trip.
pub struct CertListFfi {
    pub best_block: u64,
    pub certs: Vec<CertSummaryFfi>,
}

/// One entry of the full EKU catalog: `held` marks capabilities this
/// cert actually carries (rendered as read-only checked boxes).
pub struct EkuFlagFfi {
    pub label: String,
    pub held: bool,
}

/// Full detail for one cert (detail screen).
pub struct CertStatusFfi {
    pub thumbprint_hex: String,
    /// "Good" | "Revoked" (OCSP layer).
    pub ocsp_status: String,
    /// Current block at response time.
    pub this_update: u64,
    pub revocation_time: Option<u64>,
    pub revocation_reason: Option<String>,
    pub state: String,
    pub is_active: bool,
    pub expiry_block: u64,
    pub mint_block: u64,
    pub issuer_ss58: String,
    pub issuer_status: String,
    pub root_ss58: String,
    pub root_status: String,
    pub attestation_type: String,
    pub manufacturer_verified: bool,
    pub template_name: String,
    pub pop_required: Option<bool>,
    /// The complete EKU catalog with per-entry `held` flags.
    pub ekus: Vec<EkuFlagFfi>,
    /// True iff the cert holds the ProofOfPersonhood EKU — a PoP
    /// *credential*, distinct from the template's mint-time PoP
    /// mechanism requirement (`pop_required`).
    pub has_personhood: bool,
    /// True iff the cert holds the ChatAuth EKU (⇔ a live membership
    /// leaf, by the mint-time stamping invariant).
    pub has_chat_auth: bool,
}

fn block_on<F: std::future::Future>(fut: F) -> Result<F::Output, String> {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| e.to_string())?;
    Ok(rt.block_on(fut))
}

async fn connect(chain_rpc: &str) -> Result<subxt::rpcs::RpcClient, String> {
    subxt::rpcs::RpcClient::from_insecure_url(chain_rpc)
        .await
        .map_err(|e| format!("connecting to {chain_rpc}: {e}"))
}

async fn best_block(rpc: &subxt::rpcs::RpcClient) -> Result<u64, String> {
    let header: serde_json::Value = rpc
        .request("chain_getHeader", subxt::rpcs::rpc_params![])
        .await
        .map_err(|e| e.to_string())?;
    let num = header
        .get("number")
        .and_then(|v| v.as_str())
        .ok_or("header.number missing")?;
    u64::from_str_radix(num.trim_start_matches("0x"), 16)
        .map_err(|e| format!("parse block number: {e}"))
}

fn summary_to_ffi(s: CertSummaryScale) -> CertSummaryFfi {
    CertSummaryFfi {
        thumbprint_hex: hex::encode(s.thumbprint),
        state: s.cert_state.label(),
        is_active: matches!(s.cert_state, CertStateScale::Active),
        expiry_block: s.expiry_block,
        mint_block: s.mint_block,
        attestation_type: s.attestation_type.label(),
        manufacturer_verified: s.manufacturer_verified,
        chat_auth: s.ekus.contains(&EkuScale::ChatAuth),
    }
}

/// All certs bound to `address` (any issuer, any template), newest mint
/// first, plus the best block for countdown rendering.
pub fn zkpki_certs_by_user(chain_rpc: String, address: String) -> Result<CertListFfi, String> {
    let account =
        AccountId32::from_str(&address).map_err(|e| format!("Invalid address: {e}"))?;
    let (raw, best) = block_on(async {
        let rpc = connect(&chain_rpc).await?;
        let raw =
            zkpki_state_call(&rpc, "ZkPkiApi_certs_by_user", &account.encode()).await?;
        let best = best_block(&rpc).await?;
        Ok::<_, String>((raw, best))
    })??;
    let mut certs = Vec::<CertSummaryScale>::decode(&mut &raw[..])
        .map_err(|e| format!("certs_by_user decode: {e}"))?;
    certs.sort_by(|a, b| b.mint_block.cmp(&a.mint_block));
    Ok(CertListFfi {
        best_block: best,
        certs: certs.into_iter().map(summary_to_ffi).collect(),
    })
}

/// Full trust-context status for one cert. Errors with "cert not found"
/// when the chain has no record of the thumbprint (purged / never existed).
pub fn zkpki_cert_status(
    chain_rpc: String,
    thumbprint_hex: String,
) -> Result<CertStatusFfi, String> {
    let tp_bytes = hex::decode(thumbprint_hex.trim_start_matches("0x"))
        .map_err(|e| format!("thumbprint hex: {e}"))?;
    let thumbprint: [u8; 32] = tp_bytes
        .try_into()
        .map_err(|_| "thumbprint must be 32 bytes".to_string())?;
    let raw = block_on(async {
        let rpc = connect(&chain_rpc).await?;
        zkpki_state_call(&rpc, "ZkPkiApi_cert_status", &thumbprint.encode()).await
    })??;
    let status = Option::<CertStatusResponseScale>::decode(&mut &raw[..])
        .map_err(|e| format!("cert_status decode: {e}"))?
        .ok_or("cert not found")?;
    Ok(CertStatusFfi {
        thumbprint_hex: hex::encode(status.thumbprint),
        ocsp_status: match status.status {
            OcspStatusScale::Good => "Good",
            OcspStatusScale::Revoked => "Revoked",
            OcspStatusScale::Unknown => "Unknown",
        }
        .to_string(),
        this_update: status.this_update,
        revocation_time: status.revocation_time,
        revocation_reason: status.revocation_reason.map(|r| {
            match r {
                RevocationReasonScale::Suspended => "Suspended by issuer",
                RevocationReasonScale::Invalidated => "Invalidated by issuer",
                RevocationReasonScale::Expired => "Expired",
            }
            .to_string()
        }),
        state: status.cert_state.label(),
        is_active: matches!(status.cert_state, CertStateScale::Active),
        expiry_block: status.expiry_block,
        mint_block: status.mint_block,
        issuer_ss58: AccountId32::from(status.issuer).to_string(),
        issuer_status: status.issuer_status.label(),
        root_ss58: AccountId32::from(status.root).to_string(),
        root_status: status.root_status.label(),
        attestation_type: status.attestation_type.label(),
        manufacturer_verified: status.manufacturer_verified,
        template_name: String::from_utf8_lossy(&status.template_name).into_owned(),
        pop_required: status
            .template_pop_requirement
            .map(|p| matches!(p, PopRequirementScale::Required)),
        ekus: {
            let held: Vec<&str> = status.ekus.iter().map(EkuScale::label).collect();
            EKU_CATALOG
                .iter()
                .map(|e| EkuFlagFfi {
                    label: e.label().to_string(),
                    held: held.contains(&e.label()),
                })
                .collect()
        },
        has_personhood: status
            .ekus
            .iter()
            .any(|e| matches!(e, EkuScale::ProofOfPersonhood)),
        has_chat_auth: status.ekus.contains(&EkuScale::ChatAuth),
    })
}

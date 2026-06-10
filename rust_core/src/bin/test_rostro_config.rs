//! Standalone smoke test for RostroConfig (mirrored from
//! src/rostro_config.rs to avoid the cdylib-vs-bin lib-link issue).
//!
//! Submits `balances.transfer_keep_alive(//Bob, 1 UNIT)` signed by `//Alice`
//! and waits for tx-pool acceptance. If the wedge is closed, this returns
//! a tx hash. If still wedged, this hangs or returns `BadProof`.
//!
//! Run with: `cargo run --bin test_rostro_config`

use scale_info::PortableRegistry;
use sp_core::{sr25519, Pair};
use std::sync::Arc;
use subxt::config::transaction_extensions::{
    ChargeTransactionPaymentParams, CheckMortalityParams, CheckNonceParams,
};
use subxt::tx::Signer as _;
use subxt::backend::{LegacyBackend, LegacyBackendBuilder};
use subxt::config::{
    transaction_extensions::{
        ChargeTransactionPayment, CheckGenesis, CheckMetadataHash, CheckMortality, CheckNonce,
        CheckSpecVersion, CheckTxVersion,
    },
    Config, Hasher,
};
use subxt::ext::frame_decode;
use subxt::utils::{AccountId32, MultiAddress, MultiSignature};
use subxt::{OnlineClient};

#[derive(Clone, Debug, Default)]
pub struct RostroConfig;

impl Config for RostroConfig {
    type AccountId = AccountId32;
    type Address = MultiAddress<AccountId32, ()>;
    type Signature = MultiSignature;
    type Hasher = subxt::config::substrate::BlakeTwo256;
    type Header = subxt::config::substrate::SubstrateHeader<<Self::Hasher as Hasher>::Hash>;
    type AssetId = u32;
    type TransactionExtensions = (
        AuthorizeCallShim,
        CheckNonZeroSenderShim,
        CheckSpecVersion,
        CheckTxVersion,
        CheckGenesis<Self>,
        CheckMortality<Self>,
        CheckNonce,
        CheckWeightShim,
        ChargeTransactionPayment,
        CheckMetadataHash,
        WeightReclaimShim,
    );
}

macro_rules! empty_shim {
    ($struct_name:ident, $on_chain_name:literal) => {
        #[derive(Clone, Debug)]
        pub struct $struct_name;

        impl<T: Config> subxt::config::TransactionExtension<T> for $struct_name {
            type Decoded = ();
            type Params = ();
            fn new(
                _client: &subxt::config::ClientState<T>,
                _params: (),
            ) -> Result<Self, subxt::error::TransactionExtensionError> {
                Ok($struct_name)
            }
        }
        impl frame_decode::extrinsics::TransactionExtension<PortableRegistry> for $struct_name {
            const NAME: &'static str = $on_chain_name;
            fn encode_value_to(
                &self,
                _type_id: u32,
                _resolver: &PortableRegistry,
                _out: &mut Vec<u8>,
            ) -> Result<(), frame_decode::extrinsics::TransactionExtensionError> {
                Ok(())
            }
            fn encode_implicit_to(
                &self,
                _type_id: u32,
                _resolver: &PortableRegistry,
                _out: &mut Vec<u8>,
            ) -> Result<(), frame_decode::extrinsics::TransactionExtensionError> {
                Ok(())
            }
        }
    };
}
empty_shim!(AuthorizeCallShim, "AuthorizeCall");
empty_shim!(CheckNonZeroSenderShim, "CheckNonZeroSender");
empty_shim!(CheckWeightShim, "CheckWeight");
empty_shim!(WeightReclaimShim, "WeightReclaim");

#[subxt::subxt(runtime_metadata_path = "src/polkadot_metadata.scale")]
pub mod polkadot {}

struct Sr25519Signer(sr25519::Pair);

impl subxt::tx::Signer<RostroConfig> for Sr25519Signer {
    fn account_id(&self) -> <RostroConfig as Config>::AccountId {
        AccountId32::from(self.0.public().0)
    }
    fn sign(&self, payload: &[u8]) -> <RostroConfig as Config>::Signature {
        let sig = <sr25519::Pair as Pair>::sign(&self.0, payload);
        MultiSignature::Sr25519(sig.0)
    }
}

/// Hit `system_accountNextIndex` JSON-RPC directly to read the account's
/// nonce at the BEST block. Bypasses subxt's `at_current_block` which uses
/// the stuck finalized head on this dev node.
async fn fetch_nonce_at_best(
    rpc: &subxt::rpcs::RpcClient,
    account: &AccountId32,
) -> Result<u64, Box<dyn std::error::Error>> {
    let ss58 = format!("{account}");
    let nonce: u64 = rpc.request("system_accountNextIndex", subxt::rpcs::rpc_params![ss58]).await?;
    Ok(nonce)
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    use std::io::Write;
    let url = "ws://127.0.0.1:9944";
    eprintln!("[1] connecting to {url} via Legacy backend...");
    std::io::stderr().flush().ok();
    let rpc_client = subxt::rpcs::RpcClient::from_insecure_url(url).await?;
    let backend: LegacyBackend<RostroConfig> =
        LegacyBackendBuilder::new().build(rpc_client.clone());
    let api: OnlineClient<RostroConfig> =
        OnlineClient::from_backend(Arc::new(backend)).await?;
    eprintln!("[2] connected");

    let alice = sr25519::Pair::from_string("//Alice", None)?;
    let bob_pub = sr25519::Pair::from_string("//Bob", None)?.public();
    let bob: AccountId32 = AccountId32::from(bob_pub.0);
    let signer = Sr25519Signer(alice);

    let tx = polkadot::tx()
        .balances()
        .transfer_keep_alive(MultiAddress::Id(bob), 1_000_000_000_000);

    eprintln!("[3] building tx client...");
    let tx_client = api.tx().await?;
    // Fetch nonce at BEST block (not finalized) — this dev node has stalled
    // GRANDPA finality so subxt's default at-finalized fetch returns 0.
    eprintln!("[4a] fetching nonce at best block...");
    let nonce = fetch_nonce_at_best(&rpc_client, &signer.account_id()).await?;
    eprintln!("    Alice nonce = {nonce}");

    eprintln!("[4b] creating signable (immortal, explicit nonce)...");
    let params = (
        (), // AuthorizeCallShim
        (), // CheckNonZeroSenderShim
        (), // CheckSpecVersion
        (), // CheckTxVersion
        (), // CheckGenesis
        CheckMortalityParams::<RostroConfig>::immortal(),
        CheckNonceParams::with_nonce(nonce),
        (), // CheckWeightShim
        ChargeTransactionPaymentParams::no_tip(),
        (), // CheckMetadataHash
        (), // WeightReclaimShim
    );
    let mut signable = tx_client
        .create_signable(&tx, &signer.account_id(), params)
        .await?;
    eprintln!("[5] signing...");
    let signed = signable.sign(&signer)?;
    eprintln!("[6] encoded length: {}", signed.encoded().len());
    eprintln!("    bytes (hex): 0x");
    for b in signed.encoded() { eprint!("{b:02x}"); } eprintln!();
    eprintln!("[7] submitting...");
    let hash = signed.submit().await?;
    eprintln!("[8] ✅ submitted. Tx hash: {hash:?}");
    println!("RostroConfig wedge is CLOSED — extrinsic accepted by chain.");
    Ok(())
}

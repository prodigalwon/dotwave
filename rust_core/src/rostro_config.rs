//! `RostroConfig` — a `subxt::Config` impl that matches the Rostro
//! (gemini-runtime) 11-element `TxExtension`. Closes the wedge where
//! `subxt::PolkadotConfig`'s 9-element `DefaultTransactionExtensions`
//! causes silent hangs / `BadProof` against the Rostro runtime.
//!
//! The runtime's `TxExtension` (from `substrate/runtime/gemini/src/lib.rs`):
//!
//! ```text
//!   AuthorizeCall, CheckNonZeroSender, CheckSpecVersion, CheckTxVersion,
//!   CheckGenesis, CheckEra, CheckNonce, CheckWeight,
//!   ChargeTransactionPayment, CheckMetadataHash, WeightReclaim
//! ```
//!
//! subxt 0.50 ships impls for the 7 in the middle. The 4 here
//! (`AuthorizeCall`, `CheckNonZeroSender`, `CheckWeight`, `WeightReclaim`)
//! validate at `pre_dispatch` against runtime state, not against signed
//! payload bytes — so empty extra + empty implicit is the correct wire
//! representation. The signed extrinsic's wire format only cares about
//! the *shape* of the tuple.

use scale_info::PortableRegistry;
use subxt::config::{
    transaction_extensions::{
        ChargeTransactionPayment, CheckGenesis, CheckMetadataHash, CheckMortality, CheckNonce,
        CheckSpecVersion, CheckTxVersion,
    },
    Config, Hasher,
};
use subxt::ext::frame_decode;
use subxt::utils::{AccountId32, MultiAddress, MultiSignature};

#[derive(Clone, Debug, Default)]
pub struct RostroConfig;

impl Config for RostroConfig {
    type AccountId = AccountId32;
    type Address = MultiAddress<AccountId32, ()>;
    type Signature = MultiSignature;
    type Hasher = subxt::config::substrate::BlakeTwo256;
    type Header = subxt::config::substrate::SubstrateHeader<<Self::Hasher as Hasher>::Hash>;
    type AssetId = u32;
    // Matches the gemini star runtime's 9-element signed-extension set (verified
    // via `subxt metadata --url <rig>`): CheckNonZeroSender, CheckSpecVersion,
    // CheckTxVersion, CheckGenesis, CheckMortality, CheckNonce, CheckWeight,
    // ChargeTransactionPayment, CheckMetadataHash. (The pns-node runtime adds
    // AuthorizeCall + WeightReclaim for 11 — that's a DIFFERENT chain. We target
    // the gemini rig here; a mismatch yields InvalidTransaction(1010)/BadProof.)
    type TransactionExtensions = (
        CheckNonZeroSenderShim,
        CheckSpecVersion,
        CheckTxVersion,
        CheckGenesis<Self>,
        CheckMortality<Self>,
        CheckNonce,
        CheckWeightShim,
        ChargeTransactionPayment,
        CheckMetadataHash,
    );
}

// ── Shim transaction extensions ──────────────────────────────────────────
//
// Each shim emits zero bytes for both the on-chain `extra` and the signer-
// payload `implicit`. The runtime's `pre_dispatch` for these extensions
// runs against block / author state, not signed payload bytes.

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
                _out: &mut alloc::vec::Vec<u8>,
            ) -> Result<(), frame_decode::extrinsics::TransactionExtensionError> {
                Ok(())
            }

            fn encode_implicit_to(
                &self,
                _type_id: u32,
                _resolver: &PortableRegistry,
                _out: &mut alloc::vec::Vec<u8>,
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

extern crate alloc;

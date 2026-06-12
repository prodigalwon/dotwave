// R1 verification: confirm the RNS registry is initialized at genesis.
//
// Before R1, RnsRegistry::Official was None (genesis only seeded the
// reserved list), so `register` failed OfficialNotInitiated → NotExist.
// R1 wires `official` + `baseNode` into the chain_spec genesis, which
// runs `migration::Initialize::initial_registry` (sets Official, creates
// the root NFT class, mints the base node). This test confirms Official
// is set on a freshly-booted node carrying the R1 genesis.
//
// Note: a clean boot to #0 already proves initial_registry's
// `.expect(...)` mints succeeded (a failure panics genesis-build). Since
// `official` and `baseNode` deserialize from the same `rnsRegistry`
// block, Official being Some confirms the whole block applied and the
// base node was minted.
//
// Prereq: a fresh gemini-node (R1 build) on ws://127.0.0.1:9954.
// Run:  cargo test --test rns_genesis -- --nocapture --ignored

use rust_core::rostro_client::{account_to_ss58, as_account_id, at, connect};

#[test]
#[ignore = "requires a fresh R1 gemini-node on 9954"]
fn rns_registry_official_set_at_genesis() {
    let rpc = std::env::var("RNS_VERIFY_RPC").unwrap_or_else(|_| "ws://127.0.0.1:9954".into());
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("tokio runtime");
    rt.block_on(async {
        let (client, metadata) = connect(&rpc).await.expect("connect to node");
        let official = client
            .fetch_storage(&metadata, "RnsRegistry", "Official", &[])
            .await
            .expect("fetch RnsRegistry::Official");
        match official {
            None => panic!(
                "❌ RnsRegistry::Official is None — R1 genesis init did NOT run \
                 (register would still fail OfficialNotInitiated)"
            ),
            Some(v) => {
                // Official IS set (not None) — that's the R1 confirmation.
                // AccountId32 decodes as a newtype, so unwrap one level if
                // the flat shape doesn't match.
                let acct = as_account_id(&v)
                    .or_else(|| at(&v, 0).and_then(as_account_id))
                    .unwrap_or_else(|| panic!("Official set but unexpected shape: {:?}", v.value));
                println!("✅ RnsRegistry::Official = {}", account_to_ss58(&acct));
                println!("   → genesis registry init ran (Official set + base node minted). R1 CONFIRMED.");
            }
        }
    });
}

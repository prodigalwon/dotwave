//! Print the names in the chain's TxExtension list by reading the saved scale file.

use subxt::Metadata;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let bytes = std::fs::read("src/polkadot_metadata.scale")?;
    let metadata = Metadata::decode_from(&bytes[..])?;
    let extrinsic = metadata.extrinsic();
    println!("Supported extrinsic versions: {:?}", extrinsic.supported_versions());
    println!("Encoding extension version: {}", extrinsic.transaction_extension_version_to_use_for_encoding());
    println!("Decoding extension version: {}", extrinsic.transaction_extension_version_to_use_for_decoding());
    println!();
    let types = metadata.types();

    for v in 0..3u8 {
        if let Some(iter) = extrinsic.transaction_extensions_by_version(v) {
            println!("Version {v}:");
            for (i, ext) in iter.enumerate() {
                let extra_ty = types.resolve(ext.extra_ty()).unwrap();
                let imp_ty = types.resolve(ext.additional_ty()).unwrap();
                println!("  [{i:>2}] {} extra={:?}/{:?} implicit={:?}/{:?}",
                    ext.identifier(),
                    extra_ty.path.segments.last().map(|s| s.as_str()).unwrap_or("?"),
                    extra_ty.type_def,
                    imp_ty.path.segments.last().map(|s| s.as_str()).unwrap_or("?"),
                    imp_ty.type_def);
            }
        }
    }
    Ok(())
}

//! Native Rostro client adapter. Replaces subxt for the read-side of
//! dotwave's chain interaction (storage reads + runtime API calls).
//!
//! Connection cost: opening a `RostroClient` does a websocket handshake
//! and a `metadata_at_version(15)` runtime call. Cache the
//! `(client, metadata)` pair for the lifetime of a screen if you make
//! multiple reads.

use frame_metadata::RuntimeMetadata;
use rostro_client::RostroClient;
use scale_value::{Composite, Primitive, Value, ValueDef};

/// Open a websocket connection to a Rostro node and fetch its V15
/// metadata. Caller drives subsequent reads against this pair.
pub async fn connect(rpc_url: &str) -> Result<(RostroClient, RuntimeMetadata), String> {
	let client = RostroClient::connect(rpc_url).await.map_err(|e| e.to_string())?;
	let metadata = client.metadata().await.map_err(|e| e.to_string())?;
	Ok((client, metadata))
}

/// Walk a named-composite value and return the named field, or `None`
/// if the shape doesn't match. Used to navigate AccountInfo, Listing,
/// AccountDashboard, etc.
pub fn field<'a>(value: &'a Value<()>, name: &str) -> Option<&'a Value<()>> {
	let ValueDef::Composite(Composite::Named(fields)) = &value.value else {
		return None;
	};
	fields.iter().find(|(n, _)| n == name).map(|(_, v)| v)
}

/// Index into an unnamed composite (a SCALE-encoded array or tuple).
pub fn at(value: &Value<()>, idx: usize) -> Option<&Value<()>> {
	let ValueDef::Composite(Composite::Unnamed(items)) = &value.value else {
		return None;
	};
	items.get(idx)
}

/// Extract a u128 primitive. scale_value widens all unsigned ints to
/// U128 at decode time, so this also handles u8/u16/u32/u64 sources.
pub fn as_u128(value: &Value<()>) -> Option<u128> {
	match &value.value {
		ValueDef::Primitive(Primitive::U128(n)) => Some(*n),
		_ => None,
	}
}

/// Extract a u32 primitive (narrow from U128 if the value fits).
pub fn as_u32(value: &Value<()>) -> Option<u32> {
	let n = as_u128(value)?;
	(n <= u32::MAX as u128).then_some(n as u32)
}

/// Extract a bool primitive.
pub fn as_bool(value: &Value<()>) -> Option<bool> {
	match &value.value {
		ValueDef::Primitive(Primitive::Bool(b)) => Some(*b),
		_ => None,
	}
}

/// Extract a byte vector from an unnamed composite of u8 primitives.
/// scale_value widens u8 → U128, so each item must be a U128 in 0..=255.
///
/// Fixed-size byte newtypes (`H256`/`DomainHash`, `AccountId32`, and often
/// `BoundedVec<u8, _>`) decode newtype-wrapped: `Unnamed([ Unnamed([N u8s]) ])`.
/// So if the flat read fails on a single-element unnamed composite, unwrap one
/// level and retry. This is safe for a genuine `Vec<u8>`: a byte vec only fails
/// the flat read when its lone element is itself a composite (never a u8), so
/// unwrapping can't corrupt a real byte sequence.
pub fn as_bytes(value: &Value<()>) -> Option<Vec<u8>> {
	let mut v = value;
	loop {
		let ValueDef::Composite(Composite::Unnamed(items)) = &v.value else {
			return None;
		};
		let mut out = Vec::with_capacity(items.len());
		let mut flat = true;
		for item in items {
			match as_u128(item) {
				Some(n) if n <= 0xff => out.push(n as u8),
				_ => { flat = false; break; }
			}
		}
		if flat {
			return Some(out);
		}
		// Not a flat byte sequence — unwrap a single-element newtype wrapper and
		// retry; anything else isn't byte-shaped.
		if items.len() == 1 {
			v = &items[0];
			continue;
		}
		return None;
	}
}

/// Extract a 32-byte AccountId. `AccountId32([u8; 32])` decodes newtype-wrapped;
/// [`as_bytes`] handles the unwrapping, so this is just a length-checked view.
pub fn as_account_id(value: &Value<()>) -> Option<[u8; 32]> {
	as_bytes(value)?.try_into().ok()
}

/// Returns `Some(inner)` if the value is `Option::Some(_)`, `None` if `Option::None`,
/// `Err` if the value isn't an Option-shaped variant.
pub fn as_option<'a>(value: &'a Value<()>) -> Result<Option<&'a Value<()>>, String> {
	let ValueDef::Variant(var) = &value.value else {
		return Err(format!("expected Option variant, got {:?}", value.value));
	};
	match var.name.as_str() {
		"None" => Ok(None),
		"Some" => match &var.values {
			Composite::Unnamed(items) if items.len() == 1 => Ok(Some(&items[0])),
			Composite::Named(fields) if fields.len() == 1 => Ok(Some(&fields[0].1)),
			_ => Err(format!("Some variant has unexpected payload: {:?}", var.values)),
		},
		other => Err(format!("expected None|Some, got {}", other)),
	}
}

/// Format a 32-byte AccountId32 as the canonical SS58 string for
/// Substrate (no chain prefix specified — uses the default).
pub fn account_to_ss58(bytes: &[u8; 32]) -> String {
	use sp_core::crypto::{AccountId32, Ss58Codec};
	AccountId32::from(*bytes).to_ss58check()
}

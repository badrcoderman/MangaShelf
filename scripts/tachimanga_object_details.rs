//! Bounded static metadata query for the pinned external dae checkout.
//! This program parses a snapshot; it never invokes specimen code.
use dae::{parse_platform, parse_sdk, Analyzer};
use dae::engine::snapshot::{FieldVal, PoolKind};
use serde_json::{json, Value};
use std::{env, fs};

fn describe(a: &Analyzer, reference: u64, depth: usize) -> Value {
    let mut out = json!({"reference": format!("{reference:#x}"), "cid": a.cid_of_obj(reference)});
    let snap = if reference <= a.num_base { &a.vm } else { &a.iso };
    if let Some(s) = a.sref_str(reference) { out["string"] = json!(s); }
    if let Some(n) = snap.mint_values.get(&reference) { out["integer"] = json!(n); }
    if let Some(f) = snap.fields.get(&reference) {
        out["field_name"] = json!(a.sref_str(f.name_ref));
        out["field_offset_or_id"] = json!(snap.mint_values.get(&f.offset_or_id));
    }
    if depth >= 3 { out["depth_limit"] = json!(true); return out; }
    if let Some((_, items)) = snap.array_elements.get(&reference) {
        out["length"] = json!(items.len());
        if items.len() <= 512 {
            out["elements"] = json!(items.iter().map(|r| describe(a, *r, depth + 1)).collect::<Vec<_>>());
        } else { out["element_limit"] = json!(true); }
    }
    if let Some((_, data, used)) = snap.map_data.get(&reference) {
        out["map_data"] = describe(a, *data, depth + 1);
        out["map_used"] = describe(a, *used, depth + 1);
    }
    if let Some((cid, fields)) = snap.instance_fields.get(&reference) {
        out["instance_cid"] = json!(cid);
        if fields.len() <= 32 {
            out["fields"] = json!(fields.iter().map(|field| match field {
                FieldVal::Ref { v, slot } => json!({"slot": slot, "value": describe(a, *v, depth + 1)}),
                FieldVal::Unboxed { v, slot } => json!({"slot": slot, "unboxed_bits": format!("{v:#018x}")}),
            }).collect::<Vec<_>>());
        } else { out["field_limit"] = json!(true); }
    }
    out
}

fn main() -> Result<(), String> {
    let args: Vec<String> = env::args().collect();
    if args.len() < 5 || args.len() > 68 {
        return Err("usage: object_details APP SDK_PROFILE PLATFORM_PROFILE PP_OFFSET... (at most 64)".into());
    }
    if fs::metadata(&args[1]).map_err(|e| e.to_string())?.len() > 512 * 1024 * 1024 {
        return Err("Input exceeds size bound".into());
    }
    let data = fs::read(&args[1]).map_err(|e| e.to_string())?;
    if data.get(..4) != Some(&[0xcf, 0xfa, 0xed, 0xfe]) { return Err("Expected thin Mach-O".into()); }
    let sdk = parse_sdk(&fs::read_to_string(&args[2]).map_err(|e| e.to_string())?)?;
    let platform = parse_platform(&fs::read_to_string(&args[3]).map_err(|e| e.to_string())?)?;
    if sdk.abi != "dart/3.6.1" || sdk.word_size != 8 || sdk.compressed_pointers {
        return Err("Expected reviewed Dart 3.6.1 w64 profile".into());
    }
    let a = Analyzer::new(&data, &sdk, &platform)?;
    if a.fingerprint.as_ref().ok_or("Missing fingerprint")?.version_hash != "f956f595844a2f845a55707faaaa51e4" {
        return Err("Wrong snapshot fingerprint".into());
    }
    let pool = a.iso.objectpool_entries.as_ref().ok_or("Missing pool")?;
    let mut entries = Vec::new();
    for offset in &args[4..] {
        let n = u64::from_str_radix(offset.trim_start_matches("0x"),16).map_err(|e| e.to_string())?;
        if n < 16 || (n-16)%8 != 0 { return Err("Unaligned pool offset".into()); }
        let entry = pool.get(((n-16)/8) as usize).ok_or("Pool offset out of bounds")?;
        if entry.typ != PoolKind::Obj { return Err("Requested slot is not an object".into()); }
        entries.push(json!({"offset": format!("{n:#x}"), "value": describe(&a,
            entry.value.ok_or("Missing reference")? as u64, 0)}));
    }
    println!("{}", serde_json::to_string_pretty(&json!({
        "format": 1, "target_executed": false, "warnings": a.warnings,
        "pool_entries": pool.len(), "iso_function_count": a.iso.functions.len(), "entries": entries
    })).map_err(|e| e.to_string())?);
    Ok(())
}

//! Analysis helper for the reviewed external dae v0.1.13 checkout.
//! Reads the supplied snapshot as data. No specimen code is invoked or linked.
use dae::{parse_platform, parse_sdk, Analyzer};
use dae::engine::snapshot::PoolKind;
use serde_json::{json, Value};
use std::{env, fs};

fn describe(a: &Analyzer, reference: u64, depth: usize) -> Value {
    let cid = a.cid_of_obj(reference);
    let kind = cid.and_then(|c| a.profile.class_id_names.get(&c.to_string())).cloned();
    let mut value = json!({"reference": format!("{reference:#x}"), "cid": cid, "kind": kind});
    if depth >= 6 {
        value["depth_limit"] = json!(true);
        return value;
    }
    let snapshot = if reference <= a.num_base { &a.vm } else { &a.iso };
    if let Some(text) = a.sref_str(reference) {
        value["string"] = json!(text);
    }
    if let Some(number) = snapshot.mint_values.get(&reference) {
        value["integer"] = json!(number);
    }
    if let Some((bits, begin, end)) = snapshot.double_bits.get(&reference) {
        let number = f64::from_bits(*bits);
        value["double_bits"] = json!(format!("{bits:#018x}"));
        value["double"] = if number.is_finite() { json!(number) } else { json!(number.to_string()) };
        value["serialized_range"] = json!([begin, end]);
        value["serialized_hex"] = json!(a.data[*begin..*end].iter().map(|b| format!("{b:02x}")).collect::<String>());
    }
    if let Some((type_arguments, items)) = snapshot.array_elements.get(&reference) {
        value["type_arguments"] = json!(format!("{type_arguments:#x}"));
        value["length"] = json!(items.len());
        if items.len() <= 128 {
            value["elements"] = json!(items.iter().map(|r| describe(a, *r, depth + 1)).collect::<Vec<_>>());
        } else {
            value["element_limit"] = json!(true);
        }
    }
    if let Some(function) = snapshot.functions.get(&reference) {
        value["function_name"] = json!(a.sref_str(function.name_ref));
        if let Some(owner) = a.class_of(function.owner_ref) {
            value["owner_class"] = json!(a.sref_str(owner.name_ref));
            if let Some((_, url)) = a.lib_of(owner.library_ref) {
                value["library"] = json!(a.sref_str(url));
            }
        }
        if let Some((entry, _)) = a.func_eps.get(&reference) {
            value["entry"] = json!(format!("{entry:#x}"));
        }
    }
    if let Some(field) = snapshot.fields.get(&reference) {
        value["field_name"] = json!(a.sref_str(field.name_ref));
        value["field_kind_bits"] = json!(field.kind_bits);
        value["offset_or_id_reference"] = json!(format!("{:#x}", field.offset_or_id));
    }
    value
}

fn main() -> Result<(), String> {
    let args: Vec<String> = env::args().collect();
    if args.len() < 5 {
        return Err("usage: pool_audit APP SDK_PROFILE PLATFORM_PROFILE PP_OFFSET...".into());
    }
    let data = fs::read(&args[1]).map_err(|e| e.to_string())?;
    if data.len() > 512 * 1024 * 1024 || data.get(..4) != Some(&[0xcf, 0xfa, 0xed, 0xfe]) {
        return Err("Expected bounded thin Mach-O input".into());
    }
    let sdk = parse_sdk(&fs::read_to_string(&args[2]).map_err(|e| e.to_string())?)?;
    let platform = parse_platform(&fs::read_to_string(&args[3]).map_err(|e| e.to_string())?)?;
    if sdk.abi != "dart/3.6.1" || sdk.word_size != 8 || sdk.compressed_pointers {
        return Err("Expected reviewed Dart 3.6.1 w64 no-compressed profile".into());
    }
    let a = Analyzer::new(&data, &sdk, &platform)?;
    let fingerprint = a.fingerprint.as_ref().ok_or("Missing snapshot fingerprint")?;
    if fingerprint.version_hash != "f956f595844a2f845a55707faaaa51e4" {
        return Err("Wrong snapshot fingerprint".into());
    }
    let pool = a.iso.objectpool_entries.as_ref().ok_or("Missing pool")?;
    let mut entries = Vec::new();
    for text in &args[4..] {
        let offset = u64::from_str_radix(text.trim_start_matches("0x"), 16).map_err(|e| e.to_string())?;
        if offset < 0x10 || (offset - 0x10) % 8 != 0 { return Err("Unaligned pool offset".into()); }
        let entry = pool.get(((offset - 0x10) / 8) as usize).ok_or("Pool offset out of range")?;
        let details = if entry.typ == PoolKind::Obj {
            describe(&a, entry.value.ok_or("Missing object reference")? as u64, 0)
        } else { json!({"slot_kind": format!("{:?}", entry.typ), "raw_value": entry.value}) };
        entries.push(json!({"offset": format!("{offset:#x}"), "value": details}));
    }
    println!("{}", serde_json::to_string_pretty(&json!({
        "format": 1, "target_executed": false,
        "snapshot_hash": fingerprint.version_hash, "features": fingerprint.features,
        "warnings": a.warnings, "iso_function_count": a.iso.functions.len(),
        "pool_entries": pool.len(), "double_values_captured": a.iso.double_bits.len(),
        "entries": entries
    })).map_err(|e| e.to_string())?);
    Ok(())
}

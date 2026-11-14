//! Native Swift host for Breeze's unmodified QuickJS runtime.
#[path = "../../Vendor/Breeze/rust/src/decode/mod.rs"]
mod decode;
mod config_store;
mod opencc;

use base64::{Engine, engine::general_purpose::STANDARD};
use rquickjs_playground::{AsyncHostRuntime, register_bridge_route_sync_handler};
use serde_json::{Value, json};
use std::{collections::HashMap, ffi::{CStr, CString, c_char}, io::Read, path::PathBuf, sync::{Arc, Mutex, OnceLock}, time::Duration};

struct Host {
    executor: tokio::runtime::Runtime,
    runtimes: Mutex<HashMap<String, Arc<AsyncHostRuntime>>>,
}
static HOST: OnceLock<Host> = OnceLock::new();
static CONFIG_STORE: OnceLock<config_store::ConfigStore> = OnceLock::new();
static LOCALE: OnceLock<Value> = OnceLock::new();
static NOTICES: Mutex<Vec<Value>> = Mutex::new(Vec::new());
static CONFIG: Mutex<Option<Value>> = Mutex::new(None);
static CACHE: OnceLock<Mutex<HashMap<(String, String), Value>>> = OnceLock::new();

fn decode_value(value: &Value) -> Value {
    value.as_str().and_then(|s| serde_json::from_str(s).ok()).unwrap_or_else(|| value.clone())
}

fn setup(root: &str, key: &[u8]) -> Result<(), String> {
    let path = PathBuf::from(root);
    std::fs::create_dir_all(&path).map_err(|e| e.to_string())?;
    if HOST.get().is_some() { return Ok(()); }
    let store = config_store::ConfigStore::new(&path, key).map_err(|e| e.to_string())?;
    let saved = store.load().map_err(|e| e.to_string())?;
    CONFIG_STORE.set(store).map_err(|_| "Config store initialized twice".to_string())?;
    *CONFIG.lock().map_err(|e| e.to_string())? = Some(saved);
    for route in ["load_plugin_config", "save_plugin_config"] {
        register_bridge_route_sync_handler(route, move |scope, args| {
            let key = args.first().and_then(Value::as_str).unwrap_or("");
            let mut config = CONFIG.lock().map_err(|_| anyhow::anyhow!("Config lock poisoned"))?;
            let all = config.as_mut().ok_or_else(|| anyhow::anyhow!("Host not configured"))?;
            if route == "save_plugin_config" {
                let mut updated = all.clone();
                if updated.get(&scope).is_none() { updated[&scope] = json!({}); }
                updated[&scope][key] = decode_value(args.get(1).unwrap_or(&Value::Null));
                CONFIG_STORE.get().ok_or_else(|| anyhow::anyhow!("Missing storage"))?.save(&updated)?;
                *all = updated;
                Ok(Value::String(json!({"ok":true}).to_string()))
            } else {
                let fallback = decode_value(args.get(1).unwrap_or(&Value::Null));
                let value = if key.is_empty() { all.get(&scope).cloned().unwrap_or(json!({})) }
                    else { all.get(&scope).and_then(|v| v.get(key)).cloned().unwrap_or(fallback) };
                Ok(Value::String(json!({"ok":true,"value":value}).to_string()))
            }
        }).map_err(|e| e.to_string())?;
    }
    for route in ["cache.get", "cache.get.sync", "cache.set", "cache.set.sync", "cache.delete", "cache.set_if_absent", "cache.compare_and_set"] {
        register_bridge_route_sync_handler(route, move |scope, args| {
            let key = args.first().and_then(Value::as_str).ok_or_else(|| anyhow::anyhow!("Missing cache key"))?;
            let mut cache = CACHE.get_or_init(|| Mutex::new(HashMap::new())).lock().map_err(|_| anyhow::anyhow!("Cache lock poisoned"))?;
            let key = (scope, key.to_string());
            let value = args.get(1).cloned().unwrap_or(Value::Null);
            match route {
                "cache.get" | "cache.get.sync" => Ok(cache.get(&key).cloned().unwrap_or(value)),
                "cache.delete" => Ok(json!(cache.remove(&key).is_some())),
                "cache.set_if_absent" if cache.contains_key(&key) => Ok(json!(false)),
                "cache.compare_and_set" => {
                    if cache.get(&key).unwrap_or(&Value::Null) != &value { return Ok(json!(false)); }
                    cache.insert(key, args.get(2).cloned().unwrap_or(Value::Null)); Ok(json!(true))
                },
                _ => { if value.to_string().len() > 512_000 { return Ok(json!(false)); }
                    cache.insert(key, value); Ok(json!(true)) }
            }
        }).map_err(|e| e.to_string())?;
    }
    register_bridge_route_sync_handler("runtime.is_task_group_cancelled", |_, _| Ok(json!(false))).map_err(|e| e.to_string())?;
    register_bridge_route_sync_handler("dart.getAppVersion", |_, _| Ok(json!("3.0.38"))).map_err(|e| e.to_string())?;
    rquickjs_playground::register_bridge_route_blocking_handler("opencc.convert", |_, args| {
        opencc::convert(args.first().ok_or_else(|| anyhow::anyhow!("Missing OpenCC argument"))?).map(Value::String)
    }).map_err(|e| e.to_string())?;
    rquickjs_playground::register_bridge_route_blocking_handler("image.crop_by_regions", |_, args| {
        let bytes: Vec<u8> = serde_json::from_value(args.first().cloned().ok_or_else(|| anyhow::anyhow!("Missing image"))?)?;
        let regions: Vec<decode::ImageCropRegion> = serde_json::from_value(args.get(1).cloned().ok_or_else(|| anyhow::anyhow!("Missing regions"))?)?;
        if bytes.len() > 32 * 1024 * 1024 || regions.len() > 256 { return Err(anyhow::anyhow!("Image crop request too large")); }
        Ok(serde_json::to_value(decode::crop_image_by_regions(bytes, regions)?)?)
    }).map_err(|e| e.to_string())?;
    register_bridge_route_sync_handler("dart.getLocaleInfo", |_, _| Ok(Value::String(LOCALE.get().cloned().unwrap_or(json!({"language":"en","locale":"en-US"})).to_string()))).map_err(|e| e.to_string())?;
    register_bridge_route_sync_handler("flutter.showToast", |_, args| {
        if let Some(value) = args.first() {
            let mut notices = NOTICES.lock().map_err(|_| anyhow::anyhow!("Notice lock poisoned"))?;
            if notices.len() < 20 { notices.push(decode_value(value)); }
        }
        Ok(Value::String(String::new()))
    }).map_err(|e| e.to_string())?;
    let executor = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().map_err(|e| e.to_string())?;
    HOST.set(Host { executor, runtimes: Mutex::new(HashMap::new()) }).map_err(|_| "Host initialized twice".to_string())?;
    Ok(())
}

fn execute(request: Value) -> Result<Value, String> {
    let op = request["op"].as_str().unwrap_or("");
    if op == "setup" { LOCALE.get_or_init(|| request["locale"].clone()); setup(request["root"].as_str().ok_or("Missing root")?, &STANDARD.decode(request["configKey"].as_str().ok_or("Missing configuration key")?).map_err(|_| "Invalid configuration key".to_string())?)?; return Ok(Value::Null); }
    if op == "decompress" {
        let bytes = STANDARD.decode(request["data"].as_str().ok_or("Missing data")?).map_err(|e| e.to_string())?;
        let mut out = Vec::new();
        brotli::Decompressor::new(bytes.as_slice(), 4096).take(16 * 1024 * 1024 + 1).read_to_end(&mut out).map_err(|e| e.to_string())?;
        if out.len() > 16 * 1024 * 1024 { return Err("Plugin exceeds size limit".into()); }
        return String::from_utf8(out).map(Value::String).map_err(|e| e.to_string());
    }
    let host = HOST.get().ok_or("Host not configured")?;
    let id = request["id"].as_str().ok_or("Missing plugin ID")?;
    if op == "unload" { host.runtimes.lock().map_err(|e| e.to_string())?.remove(id); return Ok(Value::Null); }
    let runtime = {
        let mut runtimes = host.runtimes.lock().map_err(|e| e.to_string())?;
        if let Some(runtime) = runtimes.get(id) { Arc::clone(runtime) } else {
            let runtime = Arc::new(AsyncHostRuntime::builder(id).filesystem(false).build()?);
            runtimes.insert(id.to_string(), Arc::clone(&runtime)); runtime
        }
    };
    host.executor.block_on(async {
        match op {
            "load" => { runtime.bundle_load(id, request["source"].as_str().ok_or("Missing source")?).await?; Ok(Value::Null) }
            "call" | "bytes" => {
                let path = request["function"].as_str().ok_or("Missing function")?;
                let args = json!([request.get("args").cloned().unwrap_or(json!({}))]);
                let task = runtime.bundle_call_start(id, path, &args).await?;
                let task_id = task.id();
                if op == "bytes" {
                    match tokio::time::timeout(Duration::from_secs(60), task.wait_bytes_async()).await {
                        Ok(result) => result.map(|bytes| Value::String(STANDARD.encode(bytes))),
                        Err(_) => { runtime.cancel(task_id); Err("Plugin call timed out".into()) }
                    }
                } else {
                    match tokio::time::timeout(Duration::from_secs(60), task.wait_async()).await {
                        Ok(result) => {
                            let raw = result?;
                            let envelope: Value = serde_json::from_str(&raw).map_err(|e| e.to_string())?;
                            if envelope["ok"] == true { Ok(envelope["data"].clone()) }
                            else { Err(envelope["error"].as_str().unwrap_or("Plugin failed").to_string()) }
                        },
                        Err(_) => { runtime.cancel(task_id); Err("Plugin call timed out".into()) }
                    }
                }
            }
            _ => Err("Unknown operation".into())
        }
    })
}

/// Input is a UTF-8 JSON C string; returned memory must be released with willow_free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn willow_request(input: *const c_char) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        if input.is_null() { return Err("Null input".to_string()); }
        let text = unsafe { CStr::from_ptr(input) }.to_str().map_err(|e| e.to_string())?;
        execute(serde_json::from_str(text).map_err(|e| e.to_string())?)
    }).unwrap_or_else(|_| Err("Runtime panic".to_string()));
    let mut response = match result { Ok(data) => json!({"ok":true,"data":data}), Err(error) => json!({"ok":false,"error":error}) };
    response["notices"] = NOTICES.lock().map(|mut notices| json!(std::mem::take(&mut *notices))).unwrap_or(json!([]));
    CString::new(response.to_string()).expect("JSON has no NUL").into_raw()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn willow_free(value: *mut c_char) {
    if !value.is_null() { drop(unsafe { CString::from_raw(value) }); }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_contract() {
        let root = std::env::temp_dir().join("willow-bridge-test");
        execute(json!({"op":"setup","root":root,"configKey":STANDARD.encode([9; 32])})).unwrap();
        execute(json!({"op":"load","id":"test","source":"module.exports={getInfo:()=>({uuid:'test',name:'Test'}), echo:x=>x, image:()=>new Uint8Array([1,2,3])}"})).unwrap();
        let result = execute(json!({"op":"call","id":"test","function":"echo","args":{"comicId":"42"}})).unwrap();
        assert_eq!(result["comicId"], "42");
        assert!(execute(json!({"op":"call","id":"test","function":"missing"})).is_err());
        let result = execute(json!({"op":"bytes","id":"test","function":"image"})).unwrap();
        assert_eq!(result, "AQID");
        execute(json!({"op":"load","id":"opencc-contract","source":"module.exports={convert:arg=>bridge.call('opencc.convert',arg)}"})).unwrap();
        let converted = execute(json!({"op":"call","id":"opencc-contract","function":"convert","args":{"text":"漫畫閱讀","config":"t2s.json"}})).unwrap();
        assert_eq!(converted, "漫画阅读");
        assert!(execute(json!({"op":"call","id":"opencc-contract","function":"convert","args":{"text":"test","config":"invalid.json"}})).is_err());
        if let Ok(path) = std::env::var("WILLOW_TEST_PLUGIN") {
            let source = std::fs::read_to_string(path).unwrap();
            execute(json!({"op":"load","id":"real-plugin","source":source})).unwrap();
            let info = execute(json!({"op":"call","id":"real-plugin","function":"getInfo"})).unwrap();
            assert!(!info["uuid"].as_str().unwrap().is_empty());
            let settings = execute(json!({"op":"call","id":"real-plugin","function":"getSettingsBundle"})).unwrap();
            assert!(settings["scheme"].is_object());
        }
    }
}

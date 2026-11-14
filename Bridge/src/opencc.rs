use anyhow::{Result, anyhow};
use ferrous_opencc::{OpenCC, config::BuiltinConfig};
use serde_json::Value;
use std::{collections::HashMap, sync::{Arc, Mutex, OnceLock}};

// 与 Breeze 使用相同的转换库和内置配置；仅供插件协议调用。
pub fn convert(argument: &Value) -> Result<String> {
    let text = argument.get("text").and_then(Value::as_str)
        .ok_or_else(|| anyhow!("Missing OpenCC text"))?;
    let config = argument.get("config").and_then(Value::as_str)
        .ok_or_else(|| anyhow!("Missing OpenCC config"))?;
    if !config.ends_with(".json") { return Err(anyhow!("Invalid OpenCC config filename")); }
    static CONVERTERS: OnceLock<Mutex<HashMap<String, Arc<OpenCC>>>> = OnceLock::new();
    let converter = {
        let mut converters = CONVERTERS.get_or_init(Default::default).lock()
            .map_err(|_| anyhow!("OpenCC cache unavailable"))?;
        if let Some(converter) = converters.get(config) {
            converter.clone()
        } else {
            let converter = Arc::new(OpenCC::from_config(BuiltinConfig::from_filename(config)?)?);
            converters.insert(config.to_owned(), converter.clone());
            converter
        }
    };
    Ok(converter.convert(text))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn converts_and_validates_plugin_arguments() {
        assert_eq!(convert(&json!({"text":"漫畫閱讀","config":"t2s.json"})).unwrap(), "漫画阅读");
        assert_eq!(convert(&json!({"text":"漫画阅读","config":"s2t.json"})).unwrap(), "漫畫閱讀");
        assert_eq!(convert(&json!({"text":"","config":"t2s.json"})).unwrap(), "");
        assert!(convert(&json!({"text":"test","config":"missing.json"})).is_err());
        assert!(convert(&json!({"text":12,"config":"t2s.json"})).is_err());
        assert!(convert(&json!({"text":"test"})).is_err());
    }
}

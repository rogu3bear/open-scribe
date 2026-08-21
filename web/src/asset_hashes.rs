pub const JS_HASH: &str = match option_env!("OPEN_SCRIBE_WEB_JS_HASH") {
    Some(hash) => hash,
    None => "",
};
pub const WASM_HASH: &str = match option_env!("OPEN_SCRIBE_WEB_WASM_HASH") {
    Some(hash) => hash,
    None => "",
};
pub const CSS_HASH: &str = match option_env!("OPEN_SCRIBE_WEB_CSS_HASH") {
    Some(hash) => hash,
    None => "",
};

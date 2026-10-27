pub const CSS_HASH: &str = match option_env!("OPEN_SCRIBE_WEB_CSS_HASH") {
    Some(hash) => hash,
    None => "",
};

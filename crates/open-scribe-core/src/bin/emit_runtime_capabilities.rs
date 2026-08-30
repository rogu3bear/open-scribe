fn main() -> Result<(), Box<dyn std::error::Error>> {
    use std::io::Write as _;
    std::io::stdout().write_all(open_scribe_core::RUNTIME_CAPABILITY_MANIFEST_JSON.as_bytes())?;
    Ok(())
}

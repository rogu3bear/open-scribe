use std::path::PathBuf;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let output = std::env::args_os()
        .nth(1)
        .map(PathBuf::from)
        .ok_or("usage: render-web-ssr <output-path>")?;

    if let Some(parent) = output.parent() {
        std::fs::create_dir_all(parent)?;
    }

    std::fs::write(&output, open_scribe_web::render_ssr_snapshot())?;
    println!("SSR_HTML_WRITTEN={}", output.display());
    Ok(())
}

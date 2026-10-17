use std::path::PathBuf;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut arguments = std::env::args_os().skip(1);
    let output = arguments
        .next()
        .map(PathBuf::from)
        .ok_or("usage: render-web-ssr <output-path> [/route-path]")?;
    let route = arguments
        .next()
        .map(|value| value.into_string().map_err(|_| "route must be UTF-8"))
        .transpose()?
        .unwrap_or_else(|| "/".to_owned());
    if arguments.next().is_some() || !route.starts_with('/') || route.starts_with("//") {
        return Err("usage: render-web-ssr <output-path> [/route-path]".into());
    }

    if let Some(parent) = output.parent() {
        std::fs::create_dir_all(parent)?;
    }

    std::fs::write(&output, open_scribe_web::render_ssr_snapshot_at(&route))?;
    println!("SSR_HTML_WRITTEN={} route={route}", output.display());
    Ok(())
}

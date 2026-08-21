#[cfg(any(feature = "hydrate", feature = "ssr"))]
mod app;
#[cfg(feature = "ssr")]
mod asset_hashes;

#[cfg(feature = "ssr")]
pub use app::render_ssr_snapshot;

#[cfg(feature = "hydrate")]
#[wasm_bindgen::prelude::wasm_bindgen]
pub fn hydrate() {
    console_error_panic_hook::set_once();
    leptos::mount::hydrate_body(app::App);
}

#[cfg(feature = "ssr")]
#[derive(Clone)]
struct AppState {
    leptos_options: leptos::prelude::LeptosOptions,
}

#[cfg(feature = "ssr")]
impl axum::extract::FromRef<AppState> for leptos::prelude::LeptosOptions {
    fn from_ref(state: &AppState) -> Self {
        state.leptos_options.clone()
    }
}

#[cfg(feature = "ssr")]
#[worker::event(fetch)]
async fn fetch(
    req: worker::HttpRequest,
    _env: worker::Env,
    _ctx: worker::Context,
) -> worker::Result<axum::http::Response<axum::body::Body>> {
    use axum::Router;
    use leptos::prelude::*;
    use leptos_axum::{LeptosRoutes, generate_route_list};
    use tower_service::Service;

    let conf =
        get_configuration(None).map_err(|error| worker::Error::RustError(error.to_string()))?;
    let leptos_options = conf.leptos_options;
    let content_security_policy = content_security_policy(&leptos_options)?;
    let state = AppState {
        leptos_options: leptos_options.clone(),
    };
    let routes = generate_route_list(app::App);

    let mut router = Router::new()
        .leptos_routes_with_context(&state, routes, || {}, {
            let leptos_options = leptos_options.clone();
            move || app::shell(leptos_options.clone())
        })
        .with_state(state);

    let mut response = router.call(req).await?;
    apply_response_headers(&mut response, &content_security_policy);
    Ok(response)
}

#[cfg(feature = "ssr")]
fn apply_response_headers(
    response: &mut axum::http::Response<axum::body::Body>,
    content_security_policy: &axum::http::header::HeaderValue,
) {
    use axum::http::header::{
        CACHE_CONTROL, CONTENT_SECURITY_POLICY, REFERRER_POLICY, X_CONTENT_TYPE_OPTIONS,
    };
    use axum::http::{HeaderName, HeaderValue};

    let headers = response.headers_mut();
    headers.insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(X_CONTENT_TYPE_OPTIONS, HeaderValue::from_static("nosniff"));
    headers.insert(
        REFERRER_POLICY,
        HeaderValue::from_static("strict-origin-when-cross-origin"),
    );
    headers.insert(CONTENT_SECURITY_POLICY, content_security_policy.clone());
    headers.insert(
        HeaderName::from_static("x-frame-options"),
        HeaderValue::from_static("DENY"),
    );
}

#[cfg(feature = "ssr")]
fn content_security_policy(
    options: &leptos::prelude::LeptosOptions,
) -> worker::Result<axum::http::header::HeaderValue> {
    let script_sources = if cfg!(debug_assertions) {
        "'self' 'unsafe-inline' 'wasm-unsafe-eval'".to_string()
    } else {
        format!(
            "'self' 'sha256-{}' 'wasm-unsafe-eval'",
            hydration_script_hash(options)
        )
    };
    let value = format!(
        "default-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'self'; img-src 'self' data:; connect-src 'self'; style-src 'self'; script-src {script_sources};"
    );

    axum::http::header::HeaderValue::from_str(&value)
        .map_err(|error| worker::Error::RustError(error.to_string()))
}

#[cfg(feature = "ssr")]
fn hydration_script_hash(options: &leptos::prelude::LeptosOptions) -> String {
    use base64::Engine;
    use sha2::{Digest, Sha256};

    let digest = Sha256::digest(hydration_script(options).as_bytes());
    base64::engine::general_purpose::STANDARD.encode(digest)
}

#[cfg(feature = "ssr")]
fn hydration_script(options: &leptos::prelude::LeptosOptions) -> String {
    let js_href = asset_href(options, "js", asset_hashes::JS_HASH);
    let wasm_href = asset_href(options, "wasm", asset_hashes::WASM_HASH);
    format!(
        "import({js_href:?}).then(mod => {{ mod.default({{ module_or_path: {wasm_href:?} }}).then(() => {{ mod.hydrate(); }}); }});"
    )
}

#[cfg(feature = "ssr")]
fn asset_href(options: &leptos::prelude::LeptosOptions, extension: &str, hash: &str) -> String {
    let output_name = options.output_name.as_ref();
    let output_name = if output_name.is_empty() {
        env!("CARGO_PKG_NAME")
    } else {
        output_name
    };
    let pkg_dir = options.site_pkg_dir.as_ref();

    if hash.is_empty() {
        format!("/{pkg_dir}/{output_name}.{extension}")
    } else {
        format!("/{pkg_dir}/{output_name}.{hash}.{extension}")
    }
}

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

/// ADR 0015's exact Worker SSR policy. Hydration boots from a hashed
/// same-origin module, so no inline script is admitted.
#[cfg(feature = "ssr")]
const CONTENT_SECURITY_POLICY: &str = "default-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'; object-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self'; img-src 'self' data:; connect-src 'self'; font-src 'none'; media-src 'none'; manifest-src 'self'; upgrade-insecure-requests";

/// An unhashed development build has no boot module and hydrates inline.
#[cfg(feature = "ssr")]
const DEVELOPMENT_CONTENT_SECURITY_POLICY: &str = "default-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'none'; img-src 'self' data:; connect-src 'self'; style-src 'self'; script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'";

/// Denies camera, microphone, display capture, geolocation, and other unused
/// device and sensor features (ADR 0015).
#[cfg(feature = "ssr")]
const PERMISSIONS_POLICY: &str = "accelerometer=(), bluetooth=(), camera=(), display-capture=(), geolocation=(), gyroscope=(), hid=(), magnetometer=(), microphone=(), midi=(), payment=(), serial=(), usb=()";

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
    let state = AppState {
        leptos_options: leptos_options.clone(),
    };
    let routes = generate_route_list(app::App);
    let host = req
        .headers()
        .get(axum::http::header::HOST)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned)
        .or_else(|| req.uri().host().map(str::to_owned));

    let mut router = Router::new()
        .leptos_routes_with_context(&state, routes, || {}, {
            let leptos_options = leptos_options.clone();
            move || app::shell(leptos_options.clone())
        })
        .with_state(state);

    let mut response = router.call(req).await?;
    apply_response_headers(&mut response, content_security_policy(), host.as_deref());
    Ok(response)
}

#[cfg(feature = "ssr")]
fn content_security_policy() -> &'static str {
    if asset_hashes::BOOT_HASH.is_empty() {
        DEVELOPMENT_CONTENT_SECURITY_POLICY
    } else {
        CONTENT_SECURITY_POLICY
    }
}

#[cfg(feature = "ssr")]
fn apply_response_headers(
    response: &mut axum::http::Response<axum::body::Body>,
    content_security_policy: &'static str,
    host: Option<&str>,
) {
    use axum::http::header::{
        CACHE_CONTROL, CONTENT_SECURITY_POLICY, REFERRER_POLICY, X_CONTENT_TYPE_OPTIONS,
    };
    use axum::http::{HeaderName, HeaderValue};

    let headers = response.headers_mut();
    headers.insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(X_CONTENT_TYPE_OPTIONS, HeaderValue::from_static("nosniff"));
    headers.insert(REFERRER_POLICY, HeaderValue::from_static("strict-origin"));
    headers.insert(
        CONTENT_SECURITY_POLICY,
        HeaderValue::from_static(content_security_policy),
    );
    headers.insert(
        HeaderName::from_static("x-frame-options"),
        HeaderValue::from_static("DENY"),
    );
    headers.insert(
        HeaderName::from_static("cross-origin-opener-policy"),
        HeaderValue::from_static("same-origin"),
    );
    headers.insert(
        HeaderName::from_static("cross-origin-resource-policy"),
        HeaderValue::from_static("same-origin"),
    );
    headers.insert(
        HeaderName::from_static("permissions-policy"),
        HeaderValue::from_static(PERMISSIONS_POLICY),
    );
    let preview = host
        .map(|host| host.split(':').next().unwrap_or(host))
        .is_some_and(|host| host.ends_with(".workers.dev"));
    if preview {
        headers.insert(
            HeaderName::from_static("x-robots-tag"),
            HeaderValue::from_static("noindex"),
        );
    }
}

#[cfg(all(test, feature = "ssr"))]
mod tests {
    use super::*;

    #[test]
    fn production_policy_is_adr_0015_exactly() {
        assert_eq!(
            CONTENT_SECURITY_POLICY,
            "default-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'; \
             object-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self'; \
             img-src 'self' data:; connect-src 'self'; font-src 'none'; media-src 'none'; \
             manifest-src 'self'; upgrade-insecure-requests"
        );
        assert!(!CONTENT_SECURITY_POLICY.contains("unsafe-inline"));
    }

    #[test]
    fn responses_carry_the_adr_headers_and_previews_are_not_indexed() {
        let header = |response: &axum::http::Response<axum::body::Body>, name: &str| {
            response
                .headers()
                .get(name)
                .map(|value| value.to_str().unwrap().to_owned())
        };
        let mut public = axum::http::Response::new(axum::body::Body::empty());
        apply_response_headers(
            &mut public,
            CONTENT_SECURITY_POLICY,
            Some("open-scribe.app"),
        );
        for (name, expected) in [
            ("cache-control", "no-store"),
            ("x-content-type-options", "nosniff"),
            ("referrer-policy", "strict-origin"),
            ("content-security-policy", CONTENT_SECURITY_POLICY),
            ("cross-origin-opener-policy", "same-origin"),
            ("cross-origin-resource-policy", "same-origin"),
            ("permissions-policy", PERMISSIONS_POLICY),
        ] {
            assert_eq!(header(&public, name).as_deref(), Some(expected), "{name}");
        }
        for feature in [
            "camera=()",
            "microphone=()",
            "display-capture=()",
            "geolocation=()",
        ] {
            assert!(PERMISSIONS_POLICY.contains(feature), "{feature}");
        }
        assert_eq!(header(&public, "x-robots-tag"), None);

        let mut preview = axum::http::Response::new(axum::body::Body::empty());
        apply_response_headers(
            &mut preview,
            CONTENT_SECURITY_POLICY,
            Some("abc123-open-scribe-web.example.workers.dev:443"),
        );
        assert_eq!(header(&preview, "x-robots-tag").as_deref(), Some("noindex"));
    }
}

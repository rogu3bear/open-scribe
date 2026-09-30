use leptos::prelude::*;
#[cfg(feature = "ssr")]
use leptos_meta::MetaTags;
use leptos_meta::{Link, Meta, Title, provide_meta_context};
use leptos_router::{
    SsrMode, StaticSegment, WildcardSegment,
    components::{Route, Router, Routes},
};

const CANONICAL_ORIGIN: &str = "https://open-scribe.app";
/// GitHub is an external canonical link, not a site route (ADR 0015).
const REPOSITORY: &str = "https://github.com/rogu3bear/open-scribe";
const PRIVACY_NOTICE: &str = include_str!("../../docs/legal/privacy.md");
const TERMS: &str = include_str!("../../docs/legal/terms.md");
const SECURITY_POLICY: &str = include_str!("../../SECURITY.md");
/// The checked capability-claim authority (ADR 0015). Capability status on
/// this site is rendered from it, never restated in page prose.
const CAPABILITY_MANIFEST: &str = include_str!("../../docs/capabilities/manifest.v1.json");

#[cfg(feature = "ssr")]
pub fn shell(options: LeptosOptions) -> impl IntoView {
    view! {
        <!DOCTYPE html>
        <html lang="en">
            <head>
                <meta charset="utf-8"/>
                <meta name="viewport" content="width=device-width, initial-scale=1"/>
                <meta name="theme-color" content="#ffffff"/>
                <AutoReload options=options.clone()/>
                <HashedStylesheet options=options.clone()/>
                <EdgeHydrationScripts options=options/>
                <MetaTags/>
            </head>
            <body><App/></body>
        </html>
    }
}

#[component]
pub fn App() -> impl IntoView {
    provide_meta_context();

    view! {
        <Title text="Open Scribe — local evidence for important conversations"/>
        <Meta
            name="description"
            content="Open Scribe is an early-stage, local-first macOS project for preserving conversations as inspectable evidence."
        />
        <Meta property="og:title" content="Open Scribe"/>
        <Meta
            property="og:description"
            content="An early-stage local-first macOS project. No public download or recording capability exists yet."
        />
        <Meta property="og:type" content="website"/>
        <Meta property="og:url" content=CANONICAL_ORIGIN/>
        <Link rel="canonical" href=CANONICAL_ORIGIN/>

        <Router>
            <Routes fallback=|| view! { <NotFoundPage/> }.into_view()>
                <Route path=StaticSegment("") view=HomePage ssr=SsrMode::OutOfOrder/>
                <Route path=StaticSegment("product") view=ProductPage ssr=SsrMode::OutOfOrder/>
                <Route path=StaticSegment("record") view=RecordPage ssr=SsrMode::OutOfOrder/>
                <Route path=StaticSegment("meeting") view=MeetingPage ssr=SsrMode::OutOfOrder/>
                <Route path=StaticSegment("privacy") view=PrivacyPage ssr=SsrMode::OutOfOrder/>
                <Route path=StaticSegment("how-it-works") view=HowItWorksPage ssr=SsrMode::OutOfOrder/>
                <Route path=StaticSegment("download") view=DownloadPage ssr=SsrMode::OutOfOrder/>
                <Route path=StaticSegment("documentation") view=DocumentationPage ssr=SsrMode::OutOfOrder/>
                <Route path=StaticSegment("terms") view=TermsPage ssr=SsrMode::OutOfOrder/>
                <Route path=StaticSegment("security") view=SecurityPage ssr=SsrMode::OutOfOrder/>
                <Route path=WildcardSegment("any") view=NotFoundPage ssr=SsrMode::OutOfOrder/>
            </Routes>
        </Router>
    }
}

#[component]
fn SiteLayout(children: Children) -> impl IntoView {
    view! {
        <header class="site-header">
            <a class="wordmark" href="/">"Open Scribe"</a>
            <nav aria-label="Primary">
                <a href="/product">"Product"</a>
                <a href="/how-it-works">"How It Works"</a>
                <a href="/privacy">"Privacy"</a>
                <a href="/documentation">"Documentation"</a>
                <a href="/download">"Download"</a>
            </nav>
        </header>
        {children()}
        <footer>
            <p>"Open Scribe is an unreleased open-source project."</p>
            <nav aria-label="Project">
                <a href="/terms">"Terms"</a>
                <a href="/security">"Security"</a>
                <a href=REPOSITORY>"GitHub"</a>
            </nav>
        </footer>
    }
}

#[component]
pub fn HomePage() -> impl IntoView {
    view! {
        <SiteLayout>
            <main id="main-content">
                <section class="intro" aria-labelledby="home-title">
                    <p class="status">"Development build — no public release"</p>
                    <h1 id="home-title">"Local evidence for important conversations."</h1>
                    <p class="lede">
                        "Open Scribe is being built for Mac operators who need recoverable conversation records and a clear line between source evidence and derived interpretation."
                    </p>
                    <p class="notice">
                        "There is no public download or service. Capability status below is generated from the checked capability manifest; development fixtures are not available to users."
                    </p>
                </section>
                <section aria-labelledby="principles-title">
                    <h2 id="principles-title">"What the project intends to protect"</h2>
                    <ul>
                        <li>"Deliberate, visible recording authority."</li>
                        <li>"Recoverable local media before derived intelligence."</li>
                        <li>"Source-linked review that does not present model output as fact."</li>
                    </ul>
                </section>
                <CapabilityStatus/>
            </main>
        </SiteLayout>
    }
}

/// One `(terminology, maturity label)` row per manifest capability, in
/// manifest order. A malformed manifest renders no claims rather than
/// inventing them.
fn capability_rows() -> Vec<(String, &'static str)> {
    let Ok(manifest) = serde_json::from_str::<serde_json::Value>(CAPABILITY_MANIFEST) else {
        return Vec::new();
    };
    manifest["capabilities"]
        .as_array()
        .map(|capabilities| {
            capabilities
                .iter()
                .filter_map(|capability| {
                    let terminology = capability["terminology"].as_str()?;
                    let maturity = match capability["maturity"].as_str()? {
                        "Available" => "Available",
                        "Fixture" => "Development fixture — not available to users",
                        _ => "Unavailable",
                    };
                    Some((terminology.to_owned(), maturity))
                })
                .collect()
        })
        .unwrap_or_default()
}

#[component]
fn CapabilityStatus() -> impl IntoView {
    view! {
        <section aria-labelledby="capabilities-title">
            <h2 id="capabilities-title">"Current capability status"</h2>
            <ul class="capabilities">
                {capability_rows()
                    .into_iter()
                    .map(|(terminology, maturity)| view! { <li>{terminology}" — "{maturity}</li> })
                    .collect_view()}
            </ul>
        </section>
    }
}

#[component]
fn ProductPage() -> impl IntoView {
    view! {
        <SiteLayout>
            <main id="main-content">
                <p class="status">"Intended capability"</p>
                <h1>"Product"</h1>
                <p class="lede">"The intended macOS product preserves conversations locally, then supports evidence-linked review. These capabilities are not implemented in the current milestone."</p>
                <nav aria-label="Product modes">
                    <ul>
                        <li><a href="/record">"Record mode"</a></li>
                        <li><a href="/meeting">"Meeting mode"</a></li>
                    </ul>
                </nav>
            </main>
        </SiteLayout>
    }
}

#[component]
fn RecordPage() -> impl IntoView {
    view! { <IntentPage title="Record mode" summary="Intended behavior: explicit source selection, unmistakable active-state feedback, and recoverable local media. Recording exists only as a development fixture and is not available to users."/> }
}

#[component]
fn MeetingPage() -> impl IntoView {
    view! { <IntentPage title="Meeting mode" summary="Intended behavior: prepare, preserve, and review a conversation without a meeting bot or required cloud account. Meeting mode is not implemented."/> }
}

#[component]
fn HowItWorksPage() -> impl IntoView {
    view! {
        <SiteLayout>
            <main id="main-content">
                <p class="status">"Intended system, not implemented behavior"</p>
                <h1>"How it works"</h1>
                <ol>
                    <li>"The operator deliberately chooses what to record."</li>
                    <li>"Durable local media and recovery state come first."</li>
                    <li>"Transcript and context remain linked to source evidence."</li>
                    <li>"Derived interpretation stays distinguishable from observed material."</li>
                </ol>
            </main>
        </SiteLayout>
    }
}

#[component]
fn DownloadPage() -> impl IntoView {
    view! {
        <SiteLayout>
            <main id="main-content">
                <h1>"Download"</h1>
                <p class="lede">"No public release is available."</p>
                <p>"Source compilation and development receipts are not signing, notarization, distribution, or release proof."</p>
            </main>
        </SiteLayout>
    }
}

#[component]
fn DocumentationPage() -> impl IntoView {
    view! {
        <SiteLayout>
            <main id="main-content">
                <h1>"Documentation"</h1>
                <p>"Founding product, architecture, privacy, and security documents live with the source so their status can be reviewed with the code."</p>
                <p><a href=format!("{REPOSITORY}/tree/main/docs")>"Read repository documentation"</a></p>
            </main>
        </SiteLayout>
    }
}

#[component]
fn PrivacyPage() -> impl IntoView {
    view! { <CanonicalDocument title="Privacy" source=PRIVACY_NOTICE/> }
}

#[component]
fn TermsPage() -> impl IntoView {
    view! { <CanonicalDocument title="Terms" source=TERMS/> }
}

#[component]
fn SecurityPage() -> impl IntoView {
    view! { <CanonicalDocument title="Security" source=SECURITY_POLICY/> }
}

#[component]
fn CanonicalDocument(title: &'static str, source: &'static str) -> impl IntoView {
    view! {
        <SiteLayout>
            <main id="main-content">
                <h1>{title}</h1>
                <p class="status">"Canonical repository text; draft status is preserved verbatim."</p>
                <pre class="canonical-document">{source}</pre>
            </main>
        </SiteLayout>
    }
}

#[component]
fn IntentPage(title: &'static str, summary: &'static str) -> impl IntoView {
    view! {
        <SiteLayout>
            <main id="main-content">
                <p class="status">"Intended capability"</p>
                <h1>{title}</h1>
                <p class="lede">{summary}</p>
            </main>
        </SiteLayout>
    }
}

#[component]
fn NotFoundPage() -> impl IntoView {
    view! {
        <SiteLayout>
            <main id="main-content">
                <h1>"Page not found"</h1>
                <p><a href="/">"Return to Open Scribe"</a></p>
            </main>
        </SiteLayout>
    }
}

#[component]
#[cfg(feature = "ssr")]
fn HashedStylesheet(options: LeptosOptions) -> impl IntoView {
    view! { <link id="leptos" rel="stylesheet" href=asset_href(&options, "css", crate::asset_hashes::CSS_HASH)/> }
}

/// A hashed build boots from the same-origin module that `hash_assets.mjs`
/// emits, so the exact ADR 0015 CSP needs no inline script. Only an unhashed
/// development build hydrates inline.
#[component]
#[cfg(feature = "ssr")]
fn EdgeHydrationScripts(options: LeptosOptions) -> impl IntoView {
    let js_href = asset_href(&options, "js", crate::asset_hashes::JS_HASH);
    let wasm_href = asset_href(&options, "wasm", crate::asset_hashes::WASM_HASH);
    let boot = if crate::asset_hashes::BOOT_HASH.is_empty() {
        let hydration_script = format!(
            "import({js_href:?}).then(mod => {{ mod.default({{ module_or_path: {wasm_href:?} }}).then(() => {{ mod.hydrate(); }}); }});"
        );
        view! { <script type="module">{hydration_script}</script> }.into_any()
    } else {
        let boot_href = asset_href(&options, "boot.js", crate::asset_hashes::BOOT_HASH);
        view! { <script type="module" src=boot_href></script> }.into_any()
    };

    view! {
        <link rel="modulepreload" href=js_href/>
        <link rel="preload" href=wasm_href r#as="fetch" r#type="application/wasm"/>
        {boot}
    }
}

#[cfg(feature = "ssr")]
fn asset_href(options: &LeptosOptions, extension: &str, hash: &str) -> String {
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

#[cfg(feature = "ssr")]
pub fn render_ssr_snapshot() -> String {
    let body = view! { <HomePage/> }.to_html();
    format!(
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>Open Scribe — local evidence for important conversations</title><link rel=\"canonical\" href=\"{CANONICAL_ORIGIN}\"></head><body>{body}</body></html>"
    )
}

#[cfg(all(test, feature = "ssr"))]
mod tests {
    use super::render_ssr_snapshot;

    #[test]
    fn ssr_is_useful_without_hydration() {
        let html = render_ssr_snapshot();

        for required in [
            "<!doctype html>",
            "<main",
            "Local evidence for important conversations.",
            "There is no public download or service.",
            "https://open-scribe.app",
            "/privacy",
            "/download",
            "Current capability status",
        ] {
            assert!(html.contains(required), "SSR output omitted {required:?}");
        }
        assert!(!html.contains("not implemented"));
        let rows = super::capability_rows();
        assert_eq!(rows.len(), 8);
        for (terminology, maturity) in rows {
            assert!(
                html.contains(&terminology),
                "SSR output omitted {terminology:?}"
            );
            assert!(html.contains(maturity), "SSR output omitted {maturity:?}");
        }
    }

    #[test]
    fn routes_and_navigation_follow_adr_0015() {
        use leptos::prelude::*;

        let html = view! { <super::ProductPage/> }.to_html();
        for primary in [
            "href=\"/product\">Product<",
            "href=\"/how-it-works\">How It Works<",
            "href=\"/privacy\">Privacy<",
            "href=\"/documentation\">Documentation<",
            "href=\"/download\">Download<",
            "href=\"/record\"",
            "href=\"/meeting\"",
            "href=\"/terms\"",
            "href=\"/security\"",
            "href=\"https://github.com/rogu3bear/open-scribe\"",
        ] {
            assert!(html.contains(primary), "ProductPage omitted {primary:?}");
        }
        for retired in ["href=\"/docs\"", "href=\"/github\""] {
            assert!(!html.contains(retired), "ProductPage retained {retired:?}");
        }

        let download = view! { <super::DownloadPage/> }.to_html();
        assert!(download.contains("No public release is available."));
        assert!(!download.contains("<button"));
    }

    #[test]
    fn hashed_builds_boot_without_inline_script() {
        use leptos::prelude::*;

        let options = LeptosOptions::builder()
            .output_name("open-scribe-web")
            .build();
        let html = view! { <super::EdgeHydrationScripts options=options/> }.to_html();
        let boot = crate::asset_hashes::BOOT_HASH;
        if boot.is_empty() {
            assert!(html.contains("<script type=\"module\">import("));
        } else {
            let src = format!(
                "<script type=\"module\" src=\"/pkg/open-scribe-web.{boot}.boot.js\"></script>"
            );
            assert!(html.contains(&src), "hashed build omitted {src:?}");
            assert!(
                !html.contains("import("),
                "hashed build emitted inline script"
            );
        }
    }
}

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
                <meta name="theme-color" content="#f7f7f5" media="(prefers-color-scheme: light)"/>
                <meta name="theme-color" content="#11110f" media="(prefers-color-scheme: dark)"/>
                <HashedStylesheet options=options.clone()/>
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
        <Meta
            name="description"
            content="Open Scribe is an early-stage, local-first macOS project for preserving conversations as inspectable evidence."
        />
        <Meta
            property="og:description"
            content="An early-stage local-first macOS project. No public download or recording capability exists yet."
        />
        <Meta property="og:type" content="website"/>

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
fn SiteLayout(
    title: &'static str,
    path: Option<&'static str>,
    children: Children,
) -> impl IntoView {
    let title = if path == Some("/") {
        "Open Scribe — local evidence for important conversations".to_owned()
    } else {
        format!("{title} — Open Scribe")
    };
    let canonical = path.map(|path| format!("{CANONICAL_ORIGIN}{path}"));
    view! {
        <Title text=title.clone()/>
        <Meta property="og:title" content=title/>
        {canonical.map(|url| view! {
            <Meta property="og:url" content=url.clone()/>
            <Link rel="canonical" href=url/>
        })}
        {path.is_none().then(|| view! { <Meta name="robots" content="noindex"/> })}
        <a class="skip-link" href="#main-content">"Skip to content"</a>
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
        <main id="main-content" tabindex="-1">{children()}</main>
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
        <SiteLayout title="Home" path=Some("/")>
            <section class="intro" aria-labelledby="home-title">
                <h1 id="home-title">"Return to what was said."</h1>
                <p class="lede">
                    "Open Scribe is being built for one task: review a conversation against its original audio, and keep the corrections that matter."
                </p>
                <p class="notice">
                    "There is no public download or service. "
                    <a href=format!("{REPOSITORY}/blob/main/CONTRIBUTING.md")>"Build from source"</a>
                    " or "
                    <a href=format!("{REPOSITORY}/blob/main/docs/REVIEW_GUIDE.md")>"read the review guide"</a>"."
                </p>
            </section>
            <section aria-labelledby="principles-title">
                <h2 id="principles-title">"The intended review workflow"</h2>
                <ol class="review-steps">
                    <li><strong>"Keep the source."</strong>" Deliberately record or import a conversation, keeping its audio on the Mac."</li>
                    <li><strong>"Check the words."</strong>" Find a passage, hear its source, and correct the transcript or speaker name."</li>
                    <li><strong>"Use the result."</strong>" Export reviewed text and source audio. Return to the saved conversation when you need it."</li>
                </ol>
            </section>
            <details id="development-status" class="development-status">
                <summary>"Development status"</summary>
                <p>"The checked capability manifest records what has been qualified. Development fixtures are not available to users."</p>
                <CapabilityStatus/>
            </details>
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
            <table class="capabilities" aria-labelledby="capabilities-title">
                <thead><tr><th scope="col">"Capability"</th><th scope="col">"Status"</th></tr></thead>
                <tbody>
                    {capability_rows()
                        .into_iter()
                        .map(|(terminology, maturity)| view! { <tr><th scope="row">{terminology}</th><td>{maturity}</td></tr> })
                        .collect_view()}
                </tbody>
            </table>
        </section>
    }
}

#[component]
fn ProductPage() -> impl IntoView {
    view! {
        <SiteLayout title="Product" path=Some("/product")>
            <h1>"One conversation, kept together."</h1>
            <p class="lede">"The intended Mac workflow brings original audio, reviewed text, and human corrections into one local record."</p>
            <p>"Open Scribe is a developer preview. The public product is not available; "<a href="/#development-status">"see development status"</a>"."</p>
            <nav aria-label="Product modes">
                <ul>
                    <li><a href="/record">"Record mode"</a></li>
                    <li><a href="/meeting">"Meeting mode"</a></li>
                </ul>
            </nav>
        </SiteLayout>
    }
}

#[component]
fn RecordPage() -> impl IntoView {
    view! { <IntentPage path="/record" title="Record mode" summary="Choose what to record. The intended mode keeps microphone and selected computer audio as recoverable local evidence, then supports transcript review. Recording remains a development fixture, not a public capability."/> }
}

#[component]
fn MeetingPage() -> impl IntoView {
    view! { <IntentPage path="/meeting" title="Meeting mode" summary="Start with the conversation. The intended mode adds optional screen context only after you authorize its scope. Source evidence stays distinct from interpretation. Meeting mode is not available."/> }
}

#[component]
fn HowItWorksPage() -> impl IntoView {
    view! {
        <SiteLayout title="How It Works" path=Some("/how-it-works")>
            <h1>"How it works"</h1>
            <p>"This is the intended workflow. Open Scribe remains a developer preview."</p>
            <ol>
                <li>"Choose the microphone and any computer audio to record."</li>
                <li>"Keep the original audio and its recovery state on the Mac."</li>
                <li>"Review timed text against the audio. Correct words and speaker names."</li>
                <li>"Add context or interpretation only when wanted, with a clear link to the source."</li>
            </ol>
        </SiteLayout>
    }
}

#[component]
fn DownloadPage() -> impl IntoView {
    view! {
        <SiteLayout title="Download" path=Some("/download")>
            <h1>"Download"</h1>
            <p class="lede">"No public release is available."</p>
            <p>"Source compilation and development receipts are not signing, notarization, distribution, or release proof."</p>
            <p><a href=format!("{REPOSITORY}/blob/main/CONTRIBUTING.md")>"Contributor build instructions"</a></p>
        </SiteLayout>
    }
}

#[component]
fn DocumentationPage() -> impl IntoView {
    view! {
        <SiteLayout title="Documentation" path=Some("/documentation")>
            <h1>"Documentation"</h1>
            <ul>
                <li><a href=format!("{REPOSITORY}/blob/main/docs/REVIEW_GUIDE.md")>"Review a conversation"</a>" — recording, playback, corrections, search, and export."</li>
                <li><a href=format!("{REPOSITORY}/blob/main/CONTRIBUTING.md")>"Build from source"</a>" — the contributor workflow."</li>
                <li><a href=format!("{REPOSITORY}/blob/main/docs/TESTING.md")>"Verification limits"</a>" — what the development evidence establishes."</li>
            </ul>
            <p><a href=format!("{REPOSITORY}/tree/main/docs")>"All repository documentation"</a></p>
        </SiteLayout>
    }
}

#[component]
fn PrivacyPage() -> impl IntoView {
    view! { <CanonicalDocument title="Privacy" path="/privacy" source=PRIVACY_NOTICE/> }
}

#[component]
fn TermsPage() -> impl IntoView {
    view! { <CanonicalDocument title="Terms" path="/terms" source=TERMS/> }
}

#[component]
fn SecurityPage() -> impl IntoView {
    view! { <CanonicalDocument title="Security" path="/security" source=SECURITY_POLICY/> }
}

#[component]
fn CanonicalDocument(
    title: &'static str,
    path: &'static str,
    source: &'static str,
) -> impl IntoView {
    view! {
        <SiteLayout title=title path=Some(path)>
            <h1>{title}</h1>
            <p class="status">"Canonical repository text; draft status is preserved verbatim."</p>
            <pre class="canonical-document">{source}</pre>
        </SiteLayout>
    }
}

#[component]
fn IntentPage(path: &'static str, title: &'static str, summary: &'static str) -> impl IntoView {
    view! {
        <SiteLayout title=title path=Some(path)>
            <h1>{title}</h1>
            <p class="lede">{summary}</p>
            <p><a href="/how-it-works">"Follow the intended workflow"</a>" or "<a href="/#development-status">"check development status"</a>"."</p>
        </SiteLayout>
    }
}

#[component]
fn NotFoundPage() -> impl IntoView {
    view! {
        <SiteLayout title="Page not found" path=None>
            <h1>"Page not found"</h1>
            <p><a href="/">"Return to Open Scribe"</a></p>
        </SiteLayout>
    }
}

#[component]
#[cfg(feature = "ssr")]
fn HashedStylesheet(options: LeptosOptions) -> impl IntoView {
    view! { <link id="leptos" rel="stylesheet" href=asset_href(&options, "css", crate::asset_hashes::CSS_HASH)/> }
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
    render_ssr_snapshot_at("/")
}

/// Render through the same App/Router used by the Worker, without opening a
/// server or making a request. This proves route composition, not edge delivery.
#[cfg(feature = "ssr")]
pub fn render_ssr_snapshot_at(path: &str) -> String {
    use futures::{StreamExt, executor::block_on, stream};

    let _ = any_spawner::Executor::init_futures_executor();
    let owner = Owner::new();
    owner.with(|| {
        provide_context(leptos_router::location::RequestUrl::new(path));
        let (server_meta, metadata) = leptos_meta::ServerMetaContext::new();
        provide_context(server_meta);
        let options = LeptosOptions::builder()
            .output_name("open-scribe-web")
            .build();
        let html = shell(options).to_html();
        // Use the production metadata collector, including route-specific titles.
        block_on(async {
            metadata
                .inject_meta_context(stream::iter([html]))
                .await
                .collect::<String>()
                .await
        })
    })
}

#[cfg(all(test, feature = "ssr"))]
mod tests {
    use super::render_ssr_snapshot;

    #[test]
    fn ssr_is_useful_without_hydration() {
        let html = render_ssr_snapshot();
        assert!(html.to_ascii_lowercase().starts_with("<!doctype html>"));

        for required in [
            "<main",
            "Return to what was said.",
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
    fn router_snapshots_preserve_canonical_legal_text_and_unknown_routes() {
        for path in [
            "/",
            "/product",
            "/record",
            "/meeting",
            "/how-it-works",
            "/download",
            "/documentation",
            "/privacy",
            "/terms",
            "/security",
            "/qualification-nonexistent",
        ] {
            let html = super::render_ssr_snapshot_at(path);
            assert_eq!(
                html.matches("<main id=\"main-content\" tabindex=\"-1\">")
                    .count(),
                1,
                "{path}"
            );
            assert_eq!(html.matches("</main>").count(), 1, "{path}");
            assert!(
                html.contains("href=\"#main-content\" class=\"skip-link\""),
                "{path}"
            );
            assert!(html.find("</header>").unwrap() < html.find("<main").unwrap());
            assert!(html.find("</main>").unwrap() < html.find("<footer").unwrap());
        }
        for (path, heading, source) in [
            ("/privacy", "Privacy", super::PRIVACY_NOTICE),
            ("/terms", "Terms", super::TERMS),
            ("/security", "Security", super::SECURITY_POLICY),
        ] {
            let html = super::render_ssr_snapshot_at(path);
            assert!(html.contains(&format!("<h1>{heading}</h1>")));
            let escaped = source
                .replace('&', "&amp;")
                .replace('<', "&lt;")
                .replace('>', "&gt;");
            assert!(html.contains(&escaped), "{path} changed canonical text");
        }
        let unknown = super::render_ssr_snapshot_at("/qualification-nonexistent");
        assert!(unknown.contains("<h1>Page not found</h1>"));
        assert!(!unknown.contains("Return to what was said."));
    }

    #[test]
    fn static_routes_have_specific_metadata_and_no_hydration_request() {
        for (path, title) in [
            (
                "/",
                "Open Scribe — local evidence for important conversations",
            ),
            ("/product", "Product — Open Scribe"),
            ("/record", "Record mode — Open Scribe"),
            ("/meeting", "Meeting mode — Open Scribe"),
            ("/how-it-works", "How It Works — Open Scribe"),
            ("/download", "Download — Open Scribe"),
            ("/documentation", "Documentation — Open Scribe"),
            ("/privacy", "Privacy — Open Scribe"),
            ("/terms", "Terms — Open Scribe"),
            ("/security", "Security — Open Scribe"),
        ] {
            let html = super::render_ssr_snapshot_at(path);
            assert!(html.contains(&format!("<title>{title}</title>")), "{path}");
            assert!(
                html.contains(&format!("href=\"{}{path}\"", super::CANONICAL_ORIGIN)),
                "{path}"
            );
            assert!(!html.contains("<script"), "{path} booted a script");
            assert!(
                !html.contains("modulepreload"),
                "{path} preloaded JavaScript"
            );
            assert!(!html.contains("application/wasm"), "{path} preloaded Wasm");
        }
        let missing = super::render_ssr_snapshot_at("/not-a-page");
        assert!(missing.contains("<title>Page not found — Open Scribe</title>"));
        assert!(missing.contains("name=\"robots\" content=\"noindex\""));
        assert!(!missing.contains("rel=\"canonical\""));
    }
}

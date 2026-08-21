use leptos::prelude::*;
#[cfg(feature = "ssr")]
use leptos_meta::MetaTags;
use leptos_meta::{Link, Meta, Title, provide_meta_context};
use leptos_router::{
    SsrMode, StaticSegment, WildcardSegment,
    components::{Route, Router, Routes},
};

const CANONICAL_ORIGIN: &str = "https://open-scribe.app";
const PRIVACY_NOTICE: &str = include_str!("../../docs/legal/privacy.md");
const TERMS: &str = include_str!("../../docs/legal/terms.md");
const SECURITY_POLICY: &str = include_str!("../../SECURITY.md");

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
                <Route path=StaticSegment("github") view=GitHubPage ssr=SsrMode::OutOfOrder/>
                <Route path=StaticSegment("docs") view=DocumentationPage ssr=SsrMode::OutOfOrder/>
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
                <a href="/how-it-works">"How it works"</a>
                <a href="/privacy">"Privacy"</a>
                <a href="/download">"Download"</a>
            </nav>
        </header>
        {children()}
        <footer>
            <p>"Open Scribe is an unreleased open-source project."</p>
            <nav aria-label="Project">
                <a href="/github">"GitHub"</a>
                <a href="/docs">"Documentation"</a>
                <a href="/terms">"Terms"</a>
                <a href="/security">"Security"</a>
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
                    <p class="status">"Milestone 0 development foundation"</p>
                    <h1 id="home-title">"Local evidence for important conversations."</h1>
                    <p class="lede">
                        "Open Scribe is being built for Mac operators who need recoverable conversation records and a clear line between source evidence and derived interpretation."
                    </p>
                    <p class="notice">
                        "There is no public download or service. Recording, persistence, transcription, signing, and release are not implemented."
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
            </main>
        </SiteLayout>
    }
}

#[component]
fn ProductPage() -> impl IntoView {
    view! { <IntentPage title="Product" summary="The intended macOS product preserves conversations locally, then supports evidence-linked review. These capabilities are not implemented in the current milestone."/> }
}

#[component]
fn RecordPage() -> impl IntoView {
    view! { <IntentPage title="Record mode" summary="Intended behavior: explicit source selection, unmistakable active-state feedback, and recoverable local media. The current development proof does not record media."/> }
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
    view! { <IntentPage title="Download" summary="No supported build is available. Source compilation and Milestone 0 development receipts are not signing, notarization, distribution, or release proof."/> }
}

#[component]
fn GitHubPage() -> impl IntoView {
    view! {
        <SiteLayout>
            <main id="main-content">
                <h1>"GitHub"</h1>
                <p>"The project source is public. Repository status, not this page, is the authority for implemented capability."</p>
                <p><a href="https://github.com/rogu3bear/open-scribe">"Open the Open Scribe repository"</a></p>
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
                <p><a href="https://github.com/rogu3bear/open-scribe/tree/main/docs">"Read repository documentation"</a></p>
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

#[component]
#[cfg(feature = "ssr")]
fn EdgeHydrationScripts(options: LeptosOptions) -> impl IntoView {
    let js_href = asset_href(&options, "js", crate::asset_hashes::JS_HASH);
    let wasm_href = asset_href(&options, "wasm", crate::asset_hashes::WASM_HASH);
    let hydration_script = format!(
        "import({js_href:?}).then(mod => {{ mod.default({{ module_or_path: {wasm_href:?} }}).then(() => {{ mod.hydrate(); }}); }});"
    );

    view! {
        <link rel="modulepreload" href=js_href/>
        <link rel="preload" href=wasm_href r#as="fetch" r#type="application/wasm"/>
        <script type="module">{hydration_script}</script>
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
        ] {
            assert!(html.contains(required), "SSR output omitted {required:?}");
        }
    }
}

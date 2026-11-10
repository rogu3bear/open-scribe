/// Words a public surface may show for a capability maturity.
/// `Available` is reserved for a signed release that proved the capability.
/// Every other value stays visibly excluded.
#[must_use]
pub fn public_capability_label(maturity: &str) -> &'static str {
    match maturity {
        "Available" => "Available",
        "Fixture" => "Development fixture — not available to users",
        _ => "Unavailable",
    }
}

#[cfg(test)]
mod tests {
    use super::public_capability_label;

    #[test]
    fn unproved_maturities_stay_excluded() {
        assert_eq!(public_capability_label("Available"), "Available");
        assert_eq!(
            public_capability_label("Fixture"),
            "Development fixture — not available to users"
        );
        assert_eq!(public_capability_label("Unavailable"), "Unavailable");
        assert_eq!(public_capability_label("anything-else"), "Unavailable");
    }
}

use crate::ApiError;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

pub const DEFAULT_DNS_JSON: &str =
    r#"{"managed":true,"global_resolvers":[],"split":[],"search_domains":[],"records":[]}"#;
const MAX_GLOBAL_RESOLVERS: usize = 8;
const MAX_SPLIT_ROUTES: usize = 32;
const MAX_RESOLVERS_PER_SPLIT: usize = 4;
const MAX_SEARCH_DOMAINS: usize = 6;
const MAX_RECORDS: usize = 64;
const MAX_DOMAIN_LEN: usize = 253;
const MAX_LABEL_LEN: usize = 63;

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OrgDnsSettings {
    #[serde(default = "default_managed")]
    pub managed: bool,
    #[serde(default)]
    pub global_resolvers: Vec<String>,
    #[serde(default)]
    pub split: Vec<SplitDnsRoute>,
    #[serde(default)]
    pub search_domains: Vec<String>,
    #[serde(default)]
    pub records: Vec<DnsRecord>,
}

fn default_managed() -> bool {
    true
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SplitDnsRoute {
    pub suffix: String,
    pub resolvers: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DnsRecord {
    pub name: String,
    #[serde(rename = "type")]
    pub record_type: DnsRecordType,
    pub value: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "UPPERCASE")]
pub enum DnsRecordType {
    A,
    Aaaa,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrgDnsAgentView {
    pub revision: i64,
    pub managed: bool,
    pub magic_dns_suffix: String,
    pub global_resolvers: Vec<String>,
    pub split: Vec<SplitDnsRoute>,
    pub search_domains: Vec<String>,
    pub records: Vec<DnsRecord>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OrgDnsResponse {
    pub revision: i64,
    pub etag: String,
    pub has_previous: bool,
    pub magic_dns_suffix: String,
    pub dns: OrgDnsSettings,
}

#[derive(Debug, Serialize)]
pub struct DnsCheckReport {
    pub managed: bool,
    pub global_resolvers: usize,
    pub split: usize,
    pub search_domains: usize,
    pub records: usize,
}

pub fn check_dns_document(document: &str) -> Result<DnsCheckReport, String> {
    let settings: OrgDnsSettings =
        serde_json::from_str(document).map_err(|error| error.to_string())?;
    settings.validate().map_err(|error| error.to_string())?;
    Ok(DnsCheckReport {
        managed: settings.managed,
        global_resolvers: settings.global_resolvers.len(),
        split: settings.split.len(),
        search_domains: settings.search_domains.len(),
        records: settings.records.len(),
    })
}

pub fn default_settings() -> OrgDnsSettings {
    serde_json::from_str(DEFAULT_DNS_JSON).expect("default DNS JSON is valid")
}

pub fn organisation_magic_dns_suffix(org_id: &str) -> String {
    let prefix: String = org_id
        .chars()
        .filter(|character| character.is_ascii_hexdigit())
        .take(8)
        .collect();
    let prefix = if prefix.len() == 8 {
        prefix
    } else {
        crate::hash(org_id)[..8].into()
    };
    format!("{prefix}.blaktail")
}

impl OrgDnsSettings {
    pub fn validate(&self) -> Result<(), ApiError> {
        self.clone().canonicalise()?;
        Ok(())
    }

    pub fn canonicalise(self) -> Result<Self, ApiError> {
        if self.global_resolvers.len() > MAX_GLOBAL_RESOLVERS {
            return Err(ApiError::BadRequest(format!(
                "global resolvers are limited to {MAX_GLOBAL_RESOLVERS}"
            )));
        }
        if self.split.len() > MAX_SPLIT_ROUTES {
            return Err(ApiError::BadRequest(format!(
                "split DNS routes are limited to {MAX_SPLIT_ROUTES}"
            )));
        }
        if self.search_domains.len() > MAX_SEARCH_DOMAINS {
            return Err(ApiError::BadRequest(format!(
                "search domains are limited to {MAX_SEARCH_DOMAINS}"
            )));
        }
        if self.records.len() > MAX_RECORDS {
            return Err(ApiError::BadRequest(format!(
                "extra records are limited to {MAX_RECORDS}"
            )));
        }

        let mut canonical = OrgDnsSettings {
            managed: self.managed,
            global_resolvers: self
                .global_resolvers
                .iter()
                .map(|resolver| parse_resolver(resolver))
                .collect::<Result<Vec<_>, _>>()?,
            split: Vec::new(),
            search_domains: Vec::new(),
            records: Vec::new(),
        };
        let mut seen_suffixes = BTreeSet::new();
        canonical.split = self
            .split
            .iter()
            .map(|route| {
                if route.resolvers.is_empty() {
                    return Err(ApiError::BadRequest(format!(
                        "split suffix {} must list at least one resolver",
                        route.suffix
                    )));
                }
                if route.resolvers.len() > MAX_RESOLVERS_PER_SPLIT {
                    return Err(ApiError::BadRequest(format!(
                        "split suffix {} is limited to {MAX_RESOLVERS_PER_SPLIT} resolvers",
                        route.suffix
                    )));
                }
                let suffix = canonicalize_domain(&route.suffix)?;
                reject_private_suffix(&suffix)?;
                if !seen_suffixes.insert(suffix.clone()) {
                    return Err(ApiError::BadRequest(format!(
                        "duplicate split suffix {suffix}"
                    )));
                }
                Ok(SplitDnsRoute {
                    suffix,
                    resolvers: route
                        .resolvers
                        .iter()
                        .map(|resolver| parse_resolver(resolver))
                        .collect::<Result<Vec<_>, _>>()?,
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        canonical.search_domains = self
            .search_domains
            .iter()
            .map(|domain| -> Result<String, ApiError> {
                let domain = canonicalize_domain(domain)?;
                reject_private_suffix(&domain)?;
                Ok(domain)
            })
            .collect::<Result<Vec<_>, _>>()?;
        if unique_count(&canonical.search_domains) != canonical.search_domains.len() {
            return Err(ApiError::BadRequest(
                "search domains must be unique after canonicalisation".into(),
            ));
        }
        let approved_zones = approved_zones(&canonical);
        canonical.records = self
            .records
            .iter()
            .map(|record| {
                let name = canonicalize_domain(&record.name)?;
                reject_private_suffix(&name)?;
                if !zone_contains(&approved_zones, &name) {
                    return Err(ApiError::BadRequest(format!(
                        "record {name} must sit under a configured split suffix or search domain"
                    )));
                }
                let value = match record.record_type {
                    DnsRecordType::A => parse_ipv4(&record.value)?,
                    DnsRecordType::Aaaa => parse_ipv6(&record.value)?,
                };
                Ok(DnsRecord {
                    name,
                    record_type: record.record_type,
                    value,
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        let mut seen_records = BTreeSet::new();
        for record in &canonical.records {
            if !seen_records.insert((
                record.name.clone(),
                record.record_type,
                record.value.clone(),
            )) {
                return Err(ApiError::BadRequest(format!(
                    "duplicate {} record for {}",
                    record_type_name(record.record_type),
                    record.name
                )));
            }
        }
        Ok(canonical)
    }

    pub fn agent_view(&self, org_id: &str, revision: i64) -> OrgDnsAgentView {
        OrgDnsAgentView {
            revision,
            managed: self.managed,
            magic_dns_suffix: organisation_magic_dns_suffix(org_id),
            global_resolvers: self.global_resolvers.clone(),
            split: self.split.clone(),
            search_domains: self.search_domains.clone(),
            records: self.records.clone(),
        }
    }
}

pub fn longest_split_match<'a>(
    name: &str,
    routes: &'a [SplitDnsRoute],
) -> Result<Option<&'a SplitDnsRoute>, ApiError> {
    let name = canonicalize_domain(name)?;
    Ok(routes
        .iter()
        .filter(|route| name == route.suffix || name.ends_with(&format!(".{}", route.suffix)))
        .max_by_key(|route| route.suffix.len()))
}

pub fn parse_settings(json: &str) -> Result<OrgDnsSettings, ApiError> {
    if json.trim().is_empty() {
        return Ok(default_settings());
    }
    let settings: OrgDnsSettings = serde_json::from_str(json)
        .map_err(|error| ApiError::BadRequest(format!("invalid DNS settings: {error}")))?;
    settings.canonicalise()
}

fn parse_resolver(value: &str) -> Result<String, ApiError> {
    let trimmed = value.trim();
    let address: IpAddr = trimmed.parse().map_err(|_| {
        ApiError::BadRequest(format!(
            "resolver {trimmed:?} must be an IPv4 or IPv6 address"
        ))
    })?;
    match address {
        IpAddr::V4(ip) => Ok(ip.to_string()),
        IpAddr::V6(ip) => Ok(ip.to_string()),
    }
}

fn parse_ipv4(value: &str) -> Result<String, ApiError> {
    let ip: Ipv4Addr = value.trim().parse().map_err(|_| {
        ApiError::BadRequest(format!("A record value {value:?} must be an IPv4 address"))
    })?;
    Ok(ip.to_string())
}

fn parse_ipv6(value: &str) -> Result<String, ApiError> {
    let ip: Ipv6Addr = value.trim().parse().map_err(|_| {
        ApiError::BadRequest(format!(
            "AAAA record value {value:?} must be an IPv6 address"
        ))
    })?;
    Ok(ip.to_string())
}

fn canonicalize_domain(input: &str) -> Result<String, ApiError> {
    let trimmed = input.trim().trim_end_matches('.');
    if trimmed.is_empty() || trimmed == "." {
        return Err(ApiError::BadRequest(
            "root and empty DNS names are not allowed".into(),
        ));
    }
    if trimmed.contains('*') {
        return Err(ApiError::BadRequest(
            "wildcard DNS names are not allowed".into(),
        ));
    }
    let ascii = idna::domain_to_ascii(trimmed).map_err(|_| {
        ApiError::BadRequest(format!("DNS name {trimmed:?} failed IDNA canonicalisation"))
    })?;
    if ascii.len() > MAX_DOMAIN_LEN {
        return Err(ApiError::BadRequest(format!(
            "DNS name {ascii} exceeds {MAX_DOMAIN_LEN} characters"
        )));
    }
    if ascii.starts_with('.') || ascii.ends_with('.') || ascii.contains("..") {
        return Err(ApiError::BadRequest(format!(
            "DNS name {ascii} has an empty label"
        )));
    }
    let unicode = idna::domain_to_unicode(&ascii).0;
    if mixed_scripts(&unicode) {
        return Err(ApiError::BadRequest(format!(
            "DNS name {trimmed:?} mixes Latin with another letter script"
        )));
    }
    for label in ascii.split('.') {
        if label.is_empty() || label.len() > MAX_LABEL_LEN {
            return Err(ApiError::BadRequest(format!(
                "DNS label {label:?} must be 1-{MAX_LABEL_LEN} characters"
            )));
        }
        if label.starts_with('-') || label.ends_with('-') {
            return Err(ApiError::BadRequest(format!(
                "DNS label {label:?} cannot start or end with a hyphen"
            )));
        }
    }
    Ok(ascii)
}

fn reject_private_suffix(domain: &str) -> Result<(), ApiError> {
    if domain == "blaktail" || domain.ends_with(".blaktail") {
        return Err(ApiError::BadRequest(
            "organisation MagicDNS suffixes stay coordinator-authoritative and cannot be forwarded or impersonated".into(),
        ));
    }
    Ok(())
}

fn approved_zones(settings: &OrgDnsSettings) -> Vec<String> {
    settings
        .split
        .iter()
        .map(|route| route.suffix.clone())
        .chain(settings.search_domains.iter().cloned())
        .collect()
}

fn zone_contains(zones: &[String], name: &str) -> bool {
    zones
        .iter()
        .any(|zone| name == zone || name.ends_with(&format!(".{zone}")))
}

fn unique_count(values: &[String]) -> usize {
    values.iter().collect::<BTreeSet<_>>().len()
}

fn mixed_scripts(name: &str) -> bool {
    let mut latin = false;
    let mut other_letters = false;
    for character in name.chars() {
        if character.is_ascii_alphabetic() {
            latin = true;
        } else if character.is_alphabetic() {
            other_letters = true;
        }
    }
    latin && other_letters
}

fn record_type_name(record_type: DnsRecordType) -> &'static str {
    match record_type {
        DnsRecordType::A => "A",
        DnsRecordType::Aaaa => "AAAA",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_settings() -> OrgDnsSettings {
        serde_json::from_str(
            r#"{
                "managed": true,
                "global_resolvers": ["1.1.1.1", "2606:4700:4700::1111"],
                "split": [{"suffix": "internal.example.", "resolvers": ["10.0.0.53"]}],
                "search_domains": ["Internal.example"],
                "records": [
                    {"name": "wiki.internal.example", "type": "A", "value": "10.0.0.10"},
                    {"name": "wiki.internal.example", "type": "AAAA", "value": "fd00::10"}
                ]
            }"#,
        )
        .unwrap()
    }

    #[test]
    fn accepts_canonical_split_search_and_records() {
        let report =
            check_dns_document(&serde_json::to_string(&valid_settings()).unwrap()).unwrap();
        assert!(report.managed);
        assert_eq!(report.split, 1);
        assert_eq!(report.records, 2);
        let canonical = valid_settings().canonicalise().unwrap();
        assert_eq!(canonical.split[0].suffix, "internal.example");
        assert_eq!(canonical.search_domains[0], "internal.example");
        assert_eq!(
            longest_split_match("wiki.internal.example", &canonical.split)
                .unwrap()
                .unwrap()
                .suffix,
            "internal.example"
        );
        assert_eq!(
            longest_split_match("nested.corp.internal.example", &canonical.split)
                .unwrap()
                .unwrap()
                .suffix,
            "internal.example"
        );
    }

    #[test]
    fn longest_suffix_wins_for_nested_zones() {
        let settings: OrgDnsSettings = serde_json::from_str(
            r#"{
                "split": [
                    {"suffix": "example", "resolvers": ["10.0.0.53"]},
                    {"suffix": "corp.example", "resolvers": ["10.0.0.54"]}
                ]
            }"#,
        )
        .unwrap();
        let canonical = settings.canonicalise().unwrap();
        assert_eq!(
            longest_split_match("db.corp.example", &canonical.split)
                .unwrap()
                .unwrap()
                .resolvers[0],
            "10.0.0.54"
        );
        assert_eq!(
            longest_split_match("www.example", &canonical.split)
                .unwrap()
                .unwrap()
                .resolvers[0],
            "10.0.0.53"
        );
        assert!(longest_split_match("other.test", &canonical.split)
            .unwrap()
            .is_none());
    }

    #[test]
    fn rejects_private_suffix_leaks_and_wrong_families() {
        for document in [
            r#"{"split":[{"suffix":"abc.blaktail","resolvers":["1.1.1.1"]}]}"#,
            r#"{"search_domains":["blaktail"]}"#,
            r#"{"records":[{"name":"node.12345678.blaktail","type":"A","value":"10.0.0.1"}]}"#,
            r#"{"global_resolvers":["resolver.example"]}"#,
            r#"{"split":[{"suffix":"internal.example","resolvers":["10.0.0.53"]}],"records":[{"name":"wiki.internal.example","type":"A","value":"fd00::1"}]}"#,
            r#"{"split":[{"suffix":"internal.example","resolvers":["10.0.0.53"]}],"records":[{"name":"wiki.internal.example","type":"AAAA","value":"10.0.0.1"}]}"#,
            r#"{"records":[{"name":"orphan.example","type":"A","value":"10.0.0.1"}]}"#,
            r#"{"split":[{"suffix":"*","resolvers":["1.1.1.1"]}]}"#,
            r#"{"search_domains":["."]}"#,
            r#"{"split":[{"suffix":"internal.example","resolvers":["10.0.0.53"]},{"suffix":"INTERNAL.example.","resolvers":["10.0.0.54"]}]}"#,
        ] {
            assert!(
                check_dns_document(document).is_err(),
                "expected rejection for {document}"
            );
        }
    }

    #[test]
    fn rejects_mixed_script_confusable_labels() {
        assert!(check_dns_document(
            r#"{"search_domains":["exаmple"]}"# // Cyrillic а
        )
        .is_err());
    }
}

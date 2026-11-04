use anyhow::{bail, Context, Result};
use rocket::figment::providers::Serialized;
use rocket::http::{Header, Status};
use rocket::request::{FromRequest, Outcome};
use rocket::response::Responder;
use rocket::response::Response;
use rocket::{get, routes, Request, State};
use std::collections::HashSet;
use tracing::{debug, info, warn};
use x509_parser::der_parser::Oid;
use x509_parser::prelude::X509Certificate;

use crate::dstack::get_app_id;

/// OID of the app-info certificate extension (dstack `ra-tls/src/oids.rs`, `PHALA_RATLS_APP_INFO`).
const PHALA_RATLS_APP_INFO: &[u64] = &[1, 3, 6, 1, 4, 1, 62397, 1, 9];

/// Index of `compose_hash` in the msgpack array written for the extension.
///
/// Before dstack v0.6.0 the extension is `rmp_serde::to_vec(&AppInfo)` (dstack
/// `ra-tls/src/cert.rs`), a positional array in the field order of `AppInfo`
/// (`dstack-attest/src/attestation.rs`, v0.5.9): 0 app_id, 1 compose_hash, 2 instance_id,
/// 3 device_id, 4 mr_system, 5 mr_aggregated, 6 os_image_hash, 7 key_provider_info.
/// From v0.6.0 it is `rmp_serde::to_vec_named`, a map keyed by field name. Each field is a
/// msgpack bin.
const APP_INFO_COMPOSE_HASH_INDEX: usize = 1;
const APP_INFO_COMPOSE_HASH_KEY: &str = "compose_hash";
const COMPOSE_HASH_LEN: usize = 32;

/// How the auth service treats the compose hash in the client certificate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CertPolicy {
    Off,
    Warn,
    Enforce,
}

/// Result of checking a certificate against the policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PolicyDecision {
    Allow,
    WarnMissing,
    WarnDenied,
    RejectMissing,
    RejectDenied,
}

/// Certificate policy read once at startup.
#[derive(Debug, Clone)]
pub(crate) struct CertPolicyConfig {
    pub policy: CertPolicy,
    pub denied: HashSet<String>,
}

impl CertPolicyConfig {
    pub(crate) fn from_env() -> Result<Self> {
        Self::from_values(
            std::env::var("MESH_CERT_POLICY").ok().as_deref(),
            std::env::var("MESH_DENIED_COMPOSE_HASHES").ok().as_deref(),
        )
    }

    /// The denied list is only parsed when the policy is not `off`, so a malformed list
    /// cannot stop a service that has the policy disabled.
    pub(crate) fn from_values(policy: Option<&str>, denied: Option<&str>) -> Result<Self> {
        let policy = parse_cert_policy(policy)?;
        let denied = if policy == CertPolicy::Off {
            if denied.is_some_and(|v| !v.trim().is_empty()) {
                warn!("MESH_DENIED_COMPOSE_HASHES is set but MESH_CERT_POLICY is off; the list is ignored");
            }
            HashSet::new()
        } else {
            parse_denied_hashes(denied)?
        };
        Ok(Self { policy, denied })
    }
}

fn parse_cert_policy(value: Option<&str>) -> Result<CertPolicy> {
    match value.map(str::trim).unwrap_or("") {
        "" | "off" => Ok(CertPolicy::Off),
        "warn" => Ok(CertPolicy::Warn),
        "enforce" => Ok(CertPolicy::Enforce),
        other => bail!("invalid MESH_CERT_POLICY {other:?}: expected off, warn or enforce"),
    }
}

/// Normalise a compose hash to 64 lowercase hex characters, stripping an optional `0x`.
fn normalize_hash(raw: &str) -> Result<String> {
    let trimmed = raw.trim();
    let hex_part = trimmed
        .strip_prefix("0x")
        .or_else(|| trimmed.strip_prefix("0X"))
        .unwrap_or(trimmed);
    if hex_part.len() != COMPOSE_HASH_LEN * 2 || !hex_part.bytes().all(|b| b.is_ascii_hexdigit()) {
        bail!("expected {} hex characters", COMPOSE_HASH_LEN * 2);
    }
    Ok(hex_part.to_ascii_lowercase())
}

/// Parse a comma-separated hash list; empty entries are skipped.
fn parse_denied_hashes(value: Option<&str>) -> Result<HashSet<String>> {
    let mut denied = HashSet::new();
    for entry in value.unwrap_or("").split(',') {
        if entry.trim().is_empty() {
            continue;
        }
        let hash = normalize_hash(entry)
            .with_context(|| format!("invalid entry in MESH_DENIED_COMPOSE_HASHES: {entry:?}"))?;
        denied.insert(hash);
    }
    Ok(denied)
}

/// Decide what to do with a certificate. `compose_hash` is the normalised hash from the
/// app-info extension, or `None` if the extension is absent or undecodable.
pub(crate) fn evaluate_cert_policy(
    policy: CertPolicy,
    compose_hash: Option<&str>,
    denied: &HashSet<String>,
) -> PolicyDecision {
    match (policy, compose_hash) {
        (CertPolicy::Off, _) => PolicyDecision::Allow,
        (CertPolicy::Warn, None) => PolicyDecision::WarnMissing,
        (CertPolicy::Enforce, None) => PolicyDecision::RejectMissing,
        (CertPolicy::Warn, Some(h)) if denied.contains(h) => PolicyDecision::WarnDenied,
        (CertPolicy::Enforce, Some(h)) if denied.contains(h) => PolicyDecision::RejectDenied,
        (_, Some(_)) => PolicyDecision::Allow,
    }
}

/// Extract the compose hash from the raw app-info extension value.
///
/// Accepts the positional array (before dstack v0.6.0) and the map keyed by field name
/// (v0.6.0 and later). The value must be a bin of exactly 32 bytes; a map must hold exactly
/// one `compose_hash` key. Anything else is treated as undecodable.
fn decode_compose_hash(ext: &[u8]) -> Option<String> {
    let mut reader = ext;
    let value = rmpv::decode::read_value(&mut reader).ok()?;
    if !reader.is_empty() {
        return None;
    }
    let field = match &value {
        rmpv::Value::Array(items) => items.get(APP_INFO_COMPOSE_HASH_INDEX)?,
        rmpv::Value::Map(entries) => {
            let mut matches = entries
                .iter()
                .filter(|(key, _)| key.as_str() == Some(APP_INFO_COMPOSE_HASH_KEY));
            let (_, field) = matches.next()?;
            if matches.next().is_some() {
                return None;
            }
            field
        }
        _ => return None,
    };
    match field {
        rmpv::Value::Binary(bytes) if bytes.len() == COMPOSE_HASH_LEN => Some(hex::encode(bytes)),
        _ => None,
    }
}

/// Compose hash from the certificate's app-info extension. A missing, duplicated or
/// undecodable extension gives `None`.
fn cert_compose_hash(cert: &X509Certificate<'_>) -> Option<String> {
    let oid = Oid::from(PHALA_RATLS_APP_INFO).ok()?;
    let ext = cert.get_extension_unique(&oid).ok()??;
    decode_compose_hash(ext.value)
}

fn short(hash: &str) -> &str {
    &hash[..hash.len().min(12)]
}

/// Custom responder that returns status with headers
pub struct AuthSuccessResponse {
    app_id: String,
}

impl<'r> Responder<'r, 'static> for AuthSuccessResponse {
    fn respond_to(self, _: &'r rocket::Request<'_>) -> rocket::response::Result<'static> {
        Response::build()
            .status(Status::Ok)
            .header(Header::new("x-dstack-app-id", self.app_id))
            .ok()
    }
}

/// Custom request guard for server auth headers
pub struct AuthHeaders {
    pub client_cert: Option<String>,
    pub client_verify: Option<String>,
}

#[rocket::async_trait]
impl<'r> FromRequest<'r> for AuthHeaders {
    type Error = ();

    async fn from_request(request: &'r Request<'_>) -> Outcome<Self, Self::Error> {
        let headers = request.headers();
        let client_cert = headers.get_one("x-client-cert").map(|s| s.to_string());
        let client_verify = headers.get_one("x-client-verify").map(|s| s.to_string());

        Outcome::Success(AuthHeaders {
            client_cert,
            client_verify,
        })
    }
}

/// Auth endpoint for nginx auth_request integration
#[get("/auth")]
async fn auth_handler(
    headers: AuthHeaders,
    policy: &State<CertPolicyConfig>,
) -> Result<AuthSuccessResponse, Status> {
    // Extract client certificate from headers (passed by nginx)
    let cert_header = headers.client_cert.as_ref();
    let verify_header = headers.client_verify.as_ref();

    let Some(verify) = verify_header else {
        warn!("Missing verify header");
        return Err(Status::Unauthorized);
    };
    if verify != "SUCCESS" {
        warn!("Verify header is not SUCCESS");
        return Err(Status::Unauthorized);
    }
    let Some(cert_pem) = cert_header else {
        warn!("Missing cert header");
        return Err(Status::Unauthorized);
    };
    // Parse and verify certificate
    match parse_and_verify_cert(cert_pem, policy).await {
        Ok(app_id) => {
            debug!("Auth successful for app_id: {app_id}");
            Ok(AuthSuccessResponse { app_id })
        }
        Err(e) => {
            warn!("Auth failed: {e}");
            Err(Status::Unauthorized)
        }
    }
}

async fn parse_and_verify_cert(cert_pem: &str, policy: &CertPolicyConfig) -> Result<String> {
    let decoded = urlencoding::decode(cert_pem).context("Failed to decode certificate")?;
    let (_, ca_pem) =
        x509_parser::pem::parse_x509_pem(decoded.as_bytes()).context("Failed to parse ca cert")?;
    let cert = ca_pem.parse_x509().context("Failed to parse ca cert")?;
    let Some(app_id_bytes) = get_app_id(&cert).context("Failed to get app_id from client cert")?
    else {
        bail!("No app_id found in client cert");
    };
    let app_id = hex::encode(app_id_bytes);
    if policy.policy == CertPolicy::Off {
        return Ok(app_id);
    }
    let compose_hash = cert_compose_hash(&cert);
    let decision = evaluate_cert_policy(policy.policy, compose_hash.as_deref(), &policy.denied);
    let prefix = compose_hash.as_deref().map(short).unwrap_or("none");
    match decision {
        PolicyDecision::Allow => {
            if policy.policy == CertPolicy::Warn {
                info!("Cert policy: compose hash {prefix} not denied, app_id: {app_id}");
            }
        }
        PolicyDecision::WarnMissing => {
            warn!("Cert policy: no usable app-info extension, app_id: {app_id}");
        }
        PolicyDecision::WarnDenied => {
            warn!("Cert policy: denied compose hash {prefix}, app_id: {app_id}");
        }
        PolicyDecision::RejectMissing => {
            bail!("no usable app-info extension in client cert, app_id: {app_id}");
        }
        PolicyDecision::RejectDenied => {
            bail!("denied compose hash {prefix} in client cert, app_id: {app_id}");
        }
    }
    Ok(app_id)
}

/// Health check endpoint
#[get("/health")]
fn health_handler() -> Status {
    Status::Ok
}

/// Run auth service with configuration from main figment
pub(crate) async fn run_auth_service(main_figment: &rocket::figment::Figment) -> Result<()> {
    // Validate the certificate policy before launching so a bad value stops the process
    let cert_policy = CertPolicyConfig::from_env()?;
    info!(
        "client certificate policy: mode={:?}, denied compose hashes={}",
        cert_policy.policy,
        cert_policy.denied.len()
    );
    // Create Rocket figment for auth service using the auth section
    let figment = rocket::figment::Figment::new()
        .merge(rocket::Config::default())
        .merge(Serialized::defaults(
            main_figment
                .find_value("auth")
                .context("auth section not found")?,
        ));

    let _rocket = rocket::custom(figment)
        .manage(cert_policy)
        .mount("/", routes![auth_handler, health_handler])
        .launch()
        .await
        .map_err(|e| anyhow::anyhow!("Rocket launch error: {}", e))?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const H1: &str = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
    const H2: &str = "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100";

    fn set(items: &[&str]) -> HashSet<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    /// Extension bytes laid out like upstream `AppInfo` (dstack v0.5.9,
    /// `dstack-attest/src/attestation.rs`): an 8-element msgpack array of bin values in the
    /// order app_id(20), compose_hash(32), instance_id(20), device_id(32), mr_system(32),
    /// mr_aggregated(32), os_image_hash(32), key_provider_info(variable).
    fn app_info_bytes(compose_hash: &[u8]) -> Vec<u8> {
        use rmpv::Value::{Array, Binary};
        let value = Array(vec![
            Binary(vec![1; 20]),
            Binary(compose_hash.to_vec()),
            Binary(vec![3; 20]),
            Binary(vec![4; 32]),
            Binary(vec![5; 32]),
            Binary(vec![6; 32]),
            Binary(vec![7; 32]),
            Binary(b"{\"name\":\"kms\"}".to_vec()),
        ]);
        let mut out = Vec::new();
        rmpv::encode::write_value(&mut out, &value).unwrap();
        out
    }

    #[test]
    fn policy_matrix() {
        use CertPolicy::*;
        use PolicyDecision::*;
        let denied = set(&[H1]);
        let empty = HashSet::new();
        let cases = [
            (Off, None, &denied, Allow),
            (Off, Some(H1), &denied, Allow),
            (Off, Some(H2), &denied, Allow),
            (Warn, None, &denied, WarnMissing),
            (Warn, Some(H1), &denied, WarnDenied),
            (Warn, Some(H2), &denied, Allow),
            (Warn, Some(H1), &empty, Allow),
            (Enforce, None, &denied, RejectMissing),
            (Enforce, None, &empty, RejectMissing),
            (Enforce, Some(H1), &denied, RejectDenied),
            (Enforce, Some(H2), &denied, Allow),
            (Enforce, Some(H1), &empty, Allow),
        ];
        for (policy, hash, denied, expected) in cases {
            assert_eq!(
                evaluate_cert_policy(policy, hash, denied),
                expected,
                "{policy:?} {hash:?} {denied:?}"
            );
        }
    }

    #[test]
    fn decodes_compose_hash() {
        let bytes = app_info_bytes(&hex::decode(H1).unwrap());
        assert_eq!(decode_compose_hash(&bytes).as_deref(), Some(H1));
    }

    #[test]
    fn decodes_with_appended_fields() {
        use rmpv::Value::{Array, Binary};
        let value = Array(vec![
            Binary(vec![1; 20]),
            Binary(hex::decode(H2).unwrap()),
            Binary(vec![3; 20]),
            Binary(vec![9; 4]),
        ]);
        let mut out = Vec::new();
        rmpv::encode::write_value(&mut out, &value).unwrap();
        assert_eq!(decode_compose_hash(&out).as_deref(), Some(H2));
    }

    fn named_app_info_bytes(entries: &[(&str, &[u8])]) -> Vec<u8> {
        use rmpv::Value::{Binary, Map, String as Str};
        let value = Map(entries
            .iter()
            .map(|(k, v)| (Str((*k).into()), Binary(v.to_vec())))
            .collect());
        let mut out = Vec::new();
        rmpv::encode::write_value(&mut out, &value).unwrap();
        out
    }

    #[test]
    fn decodes_named_map_form() {
        let hash = hex::decode(H2).unwrap();
        let bytes = named_app_info_bytes(&[
            ("app_id", &[1; 20]),
            ("compose_hash", &hash),
            ("instance_id", &[3; 20]),
            ("future_field", &[9; 4]),
        ]);
        assert_eq!(decode_compose_hash(&bytes).as_deref(), Some(H2));
    }

    #[test]
    fn rejects_bad_named_map_form() {
        let hash = hex::decode(H1).unwrap();
        // duplicate key, even when both values are valid
        let dup = named_app_info_bytes(&[("compose_hash", &hash), ("compose_hash", &hash)]);
        assert_eq!(decode_compose_hash(&dup), None);
        // wrong size
        for len in [31, 33] {
            let bytes = named_app_info_bytes(&[("compose_hash", &vec![1; len])]);
            assert_eq!(decode_compose_hash(&bytes), None);
        }
        // map without the key
        let bytes = named_app_info_bytes(&[("app_id", &[1; 20]), ("instance_id", &hash)]);
        assert_eq!(decode_compose_hash(&bytes), None);
        // empty map
        assert_eq!(decode_compose_hash(&named_app_info_bytes(&[])), None);
    }

    #[test]
    fn rejects_undecodable_extension() {
        use rmpv::Value::{Array, Binary, Integer, String as Str};
        let enc = |v: rmpv::Value| {
            let mut out = Vec::new();
            rmpv::encode::write_value(&mut out, &v).unwrap();
            out
        };
        // wrong hash length
        assert_eq!(decode_compose_hash(&app_info_bytes(&[1; 31])), None);
        assert_eq!(decode_compose_hash(&app_info_bytes(&[1; 33])), None);
        // not an array
        assert_eq!(decode_compose_hash(&enc(Binary(vec![1; 32]))), None);
        // array too short
        assert_eq!(
            decode_compose_hash(&enc(Array(vec![Binary(vec![1; 20])]))),
            None
        );
        // element is not bin (hex string, integer)
        assert_eq!(
            decode_compose_hash(&enc(Array(vec![Binary(vec![1; 20]), Str(H1.into())]))),
            None
        );
        assert_eq!(
            decode_compose_hash(&enc(Array(vec![Binary(vec![1; 20]), Integer(1.into())]))),
            None
        );
        // empty, garbage, truncated, trailing bytes
        assert_eq!(decode_compose_hash(&[]), None);
        assert_eq!(decode_compose_hash(&[0xc1, 0xff]), None);
        let good = app_info_bytes(&[1; 32]);
        assert_eq!(decode_compose_hash(&good[..good.len() - 3]), None);
        let mut trailing = good.clone();
        trailing.push(0);
        assert_eq!(decode_compose_hash(&trailing), None);
    }

    #[test]
    fn normalizes_hashes() {
        assert_eq!(normalize_hash(H1).unwrap(), H1);
        assert_eq!(normalize_hash(&H1.to_uppercase()).unwrap(), H1);
        assert_eq!(normalize_hash(&format!("0x{H1}")).unwrap(), H1);
        assert_eq!(
            normalize_hash(&format!(" 0x{} ", H1.to_uppercase())).unwrap(),
            H1
        );
        assert!(normalize_hash("").is_err());
        assert!(normalize_hash("0x").is_err());
        assert!(normalize_hash(&H1[..62]).is_err());
        assert!(normalize_hash(&format!("{H1}00")).is_err());
        assert!(normalize_hash(&format!("{}zz", &H1[..62])).is_err());
    }

    #[test]
    fn parses_denied_list() {
        let list = format!("{},0x{}, {} ,", H1.to_uppercase(), H2, H1);
        assert_eq!(parse_denied_hashes(Some(&list)).unwrap(), set(&[H1, H2]));
        assert!(parse_denied_hashes(None).unwrap().is_empty());
        assert!(parse_denied_hashes(Some("")).unwrap().is_empty());
        assert!(parse_denied_hashes(Some(&format!("{H1},nothex"))).is_err());
        assert!(parse_denied_hashes(Some("abcd")).is_err());
    }

    #[test]
    fn parses_policy_values() {
        assert_eq!(parse_cert_policy(None).unwrap(), CertPolicy::Off);
        assert_eq!(parse_cert_policy(Some("")).unwrap(), CertPolicy::Off);
        assert_eq!(parse_cert_policy(Some("off")).unwrap(), CertPolicy::Off);
        assert_eq!(parse_cert_policy(Some("warn")).unwrap(), CertPolicy::Warn);
        assert_eq!(
            parse_cert_policy(Some("enforce")).unwrap(),
            CertPolicy::Enforce
        );
        for bad in ["on", "Warn", "true", "enforced"] {
            assert!(parse_cert_policy(Some(bad)).is_err(), "{bad}");
        }
    }

    #[test]
    fn config_from_values() {
        let cfg = CertPolicyConfig::from_values(Some("enforce"), None).unwrap();
        assert_eq!(cfg.policy, CertPolicy::Enforce);
        assert!(cfg.denied.is_empty());
        assert!(CertPolicyConfig::from_values(Some("bogus"), None).is_err());
        assert!(CertPolicyConfig::from_values(Some("warn"), Some("zz")).is_err());
        assert!(CertPolicyConfig::from_values(Some("enforce"), Some("zz")).is_err());
        // with the policy off the list is not parsed, so a malformed one is ignored
        for policy in [None, Some("off")] {
            let cfg = CertPolicyConfig::from_values(policy, Some("zz")).unwrap();
            assert_eq!(cfg.policy, CertPolicy::Off);
            assert!(cfg.denied.is_empty());
        }
        let cfg = CertPolicyConfig::from_values(Some("warn"), Some(H1)).unwrap();
        assert_eq!(cfg.denied, set(&[H1]));
    }

    #[test]
    fn short_prefix_is_12_chars() {
        assert_eq!(
            short(H1),
            "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"[..12].to_string()
        );
        assert_eq!(short("abc"), "abc");
    }
}

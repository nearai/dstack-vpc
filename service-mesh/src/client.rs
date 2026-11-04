use anyhow::{bail, Context, Result};
use reqwest::redirect::Policy;
use reqwest::tls::TlsInfo;
use reqwest::Client;
use rocket::figment::providers::Serialized;
use rocket::figment::Figment;
use rocket::http::uri::fmt::Path;
use rocket::http::uri::Segments;
use rocket::http::Status;
use rocket::request::{self, FromRequest};
use rocket::response::{Responder, Response};
use rocket::tokio::io::AsyncRead;
use rocket::{get, post, routes, Data, Request, State};
use std::pin::Pin;
use std::task::{Context as TaskContext, Poll};
use tokio::io::AsyncReadExt;
use tracing::{debug, info, warn};

use crate::config::Config;
use crate::config::TargetInfo;
use crate::dstack::{dstack_agent_address, get_app_id};

pub struct ClientState {
    gateway_domain: String,
    http_client: Client,
    /// Optional shared-secret token. When set, the client proxy only serves
    /// callers that present a matching `x-dstack-mesh-token` header. When unset,
    /// the proxy behaves as before and requires no token.
    client_proxy_token: Option<String>,
}

pub struct ReqwestStreamReader {
    stream: Pin<
        Box<dyn futures_util::Stream<Item = Result<bytes::Bytes, reqwest::Error>> + Send + 'static>,
    >,
    current_chunk: Option<bytes::Bytes>,
    chunk_pos: usize,
}

impl ReqwestStreamReader {
    fn new(response: reqwest::Response) -> Self {
        let stream = response.bytes_stream();
        Self {
            stream: Box::pin(stream),
            current_chunk: None,
            chunk_pos: 0,
        }
    }
}

impl AsyncRead for ReqwestStreamReader {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        loop {
            // If we have a current chunk, try to read from it
            if let Some(chunk) = &self.current_chunk {
                if self.chunk_pos < chunk.len() {
                    let to_read = std::cmp::min(buf.remaining(), chunk.len() - self.chunk_pos);
                    let end_pos = self.chunk_pos + to_read;
                    buf.put_slice(&chunk[self.chunk_pos..end_pos]);
                    self.chunk_pos = end_pos;
                    return Poll::Ready(Ok(()));
                } else {
                    // Finished reading current chunk
                    self.current_chunk = None;
                    self.chunk_pos = 0;
                }
            }

            // Try to get next chunk
            match self.stream.as_mut().poll_next(cx) {
                Poll::Ready(Some(Ok(chunk))) => {
                    self.current_chunk = Some(chunk);
                    self.chunk_pos = 0;
                    // Continue loop to read from the new chunk
                }
                Poll::Ready(Some(Err(e))) => {
                    return Poll::Ready(Err(std::io::Error::other(e)));
                }
                Poll::Ready(None) => {
                    // End of stream
                    return Poll::Ready(Ok(()));
                }
                Poll::Pending => {
                    return Poll::Pending;
                }
            }
        }
    }
}

pub enum ProxyResponse {
    Stream(StreamingProxyResponse),
    Json(serde_json::Value),
}

pub struct StreamingProxyResponse {
    response: reqwest::Response,
}

impl<'r> Responder<'r, 'static> for ProxyResponse {
    fn respond_to(self, request: &'r rocket::Request<'_>) -> rocket::response::Result<'static> {
        match self {
            ProxyResponse::Stream(streaming) => streaming.respond_to(request),
            ProxyResponse::Json(json) => {
                let json_string = serde_json::to_string(&json).unwrap_or_default();
                Response::build()
                    .header(rocket::http::ContentType::JSON)
                    .sized_body(json_string.len(), std::io::Cursor::new(json_string))
                    .ok()
            }
        }
    }
}

impl<'r> Responder<'r, 'static> for StreamingProxyResponse {
    fn respond_to(self, _: &'r rocket::Request<'_>) -> rocket::response::Result<'static> {
        // Collect all headers before moving the response
        let headers: Vec<(String, String)> = self
            .response
            .headers()
            .iter()
            .filter_map(|(name, value)| {
                value
                    .to_str()
                    .ok()
                    .map(|v| (name.to_string(), v.to_string()))
            })
            .collect();
        let reader = ReqwestStreamReader::new(self.response);

        let mut response_builder = Response::build();

        // Add all headers from the upstream response
        for (name, value) in headers {
            response_builder.raw_header(name, value);
        }

        response_builder.streamed_body(reader).ok()
    }
}

/// Custom request guard for extracting request information we need
pub struct DstackRequest {
    pub target_app: Option<String>,
    pub target_port: Option<String>,
    pub target_instance: Option<String>,
    pub all_headers: Vec<(String, String)>,
    pub query_string: Option<String>,
    pub path: String,
    pub method: String,
    pub use_tls: bool,
}

#[rocket::async_trait]
impl<'r> FromRequest<'r> for DstackRequest {
    type Error = ();

    async fn from_request(request: &'r Request<'_>) -> request::Outcome<Self, Self::Error> {
        let headers = request.headers();
        let target_app = headers
            .get_one("x-dstack-target-app")
            .map(|s| s.to_string());
        let target_port = headers
            .get_one("x-dstack-target-port")
            .map(|s| s.to_string());
        let target_instance = headers
            .get_one("x-dstack-target-instance")
            .map(|s| s.to_string());
        let use_tls = headers
            .get_one("x-dstack-target-use-tls")
            .map(|s| s == "true" || s == "1")
            .unwrap_or(true);

        let all_headers = headers
            .iter()
            .map(|h| (h.name().to_string(), h.value().to_string()))
            .collect();

        let query_string = request.uri().query().map(|q| q.to_string());

        // Extract path from URI
        let path = request.uri().path().to_string();

        // Extract HTTP method
        let method = request.method().to_string();

        request::Outcome::Success(DstackRequest {
            target_app,
            target_port,
            target_instance,
            all_headers,
            query_string,
            path,
            method,
            use_tls,
        })
    }
}

/// Constant-time byte comparison, so a mismatched token does not leak its
/// correct prefix length through response timing.
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

/// Request guard enforcing the client-proxy access token.
///
/// When `ClientState.client_proxy_token` is set, a request must carry a matching
/// `x-dstack-mesh-token` header or it is rejected with 401. When the token is
/// unset the guard allows the request, preserving the proxy's prior behavior.
/// Health checks are not guarded.
pub struct AuthorizedCaller;

#[rocket::async_trait]
impl<'r> FromRequest<'r> for AuthorizedCaller {
    type Error = ();

    async fn from_request(request: &'r Request<'_>) -> request::Outcome<Self, Self::Error> {
        let Some(state) = request.rocket().state::<ClientState>() else {
            return request::Outcome::Error((Status::InternalServerError, ()));
        };

        let Some(expected) = state.client_proxy_token.as_deref() else {
            // No token configured: behave as before.
            return request::Outcome::Success(AuthorizedCaller);
        };

        let provided = request
            .headers()
            .get_one("x-dstack-mesh-token")
            .unwrap_or("");

        if constant_time_eq(expected.as_bytes(), provided.as_bytes()) {
            request::Outcome::Success(AuthorizedCaller)
        } else {
            warn!("Rejecting client-proxy request: missing or invalid x-dstack-mesh-token");
            request::Outcome::Error((Status::Unauthorized, ()))
        }
    }
}

/// Run client proxy with configuration from main figment
pub async fn run_client_proxy(main_figment: &Figment, config: &Config) -> Result<()> {
    // Create mTLS-enabled HTTP client
    let http_client = create_mtls_client(config).context("Failed to create mTLS HTTP client")?;

    // Optional access token for the client proxy. Sourced from the environment
    // so it can be provisioned per-CVM without changing the config files. When
    // unset, the proxy keeps its previous behavior (no token required).
    let client_proxy_token = std::env::var("MESH_CLIENT_PROXY_TOKEN")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    let token_enforced = client_proxy_token.is_some();

    let state = ClientState {
        gateway_domain: config.dstack.gateway_domain.clone(),
        http_client,
        client_proxy_token,
    };

    if token_enforced {
        info!("Client proxy starting with access-token enforcement enabled");
    } else {
        info!("Client proxy starting with Figment configuration (no access token set)");
    }

    // Create Rocket figment for client service using the client section
    let figment = Figment::new()
        .merge(rocket::Config::default())
        .merge(Serialized::defaults(
            main_figment
                .find_value("client")
                .context("client section not found")?,
        ));

    // Launch Rocket server
    let _rocket = rocket::custom(figment)
        .manage(state)
        .mount(
            "/",
            routes![
                proxy_get_handler,
                proxy_post_handler,
                proxy_put_handler,
                proxy_patch_handler,
                proxy_delete_handler,
                health_handler,
            ],
        )
        .launch()
        .await
        .map_err(|e| anyhow::anyhow!("Rocket launch error: {}", e))?;

    Ok(())
}

/// Handle GET requests
#[get("/<_path..>")]
async fn proxy_get_handler(
    _auth: AuthorizedCaller,
    _path: Segments<'_, Path>,
    request: DstackRequest,
    state: &State<ClientState>,
) -> Result<ProxyResponse, Status> {
    proxy_request(&request, state, None).await
}

/// Handle POST requests
#[post("/<_path..>", data = "<body>")]
async fn proxy_post_handler(
    _auth: AuthorizedCaller,
    _path: Segments<'_, Path>,
    request: DstackRequest,
    body: Data<'_>,
    state: &State<ClientState>,
) -> Result<ProxyResponse, Status> {
    proxy_request(&request, state, Some(body)).await
}

/// Handle PUT requests
#[rocket::put("/<_path..>", data = "<body>")]
async fn proxy_put_handler(
    _auth: AuthorizedCaller,
    _path: Segments<'_, Path>,
    request: DstackRequest,
    body: Data<'_>,
    state: &State<ClientState>,
) -> Result<ProxyResponse, Status> {
    proxy_request(&request, state, Some(body)).await
}

/// Handle PATCH requests
#[rocket::patch("/<_path..>", data = "<body>")]
async fn proxy_patch_handler(
    _auth: AuthorizedCaller,
    _path: Segments<'_, Path>,
    request: DstackRequest,
    body: Data<'_>,
    state: &State<ClientState>,
) -> Result<ProxyResponse, Status> {
    proxy_request(&request, state, Some(body)).await
}

/// Handle DELETE requests
#[rocket::delete("/<_path..>")]
async fn proxy_delete_handler(
    _auth: AuthorizedCaller,
    _path: Segments<'_, Path>,
    request: DstackRequest,
    state: &State<ClientState>,
) -> Result<ProxyResponse, Status> {
    proxy_request(&request, state, None).await
}

/// Health check endpoint
#[get("/health")]
fn health_handler() -> Status {
    Status::Ok
}

/// Map a request to the single dstack agent RPC that may be served locally.
/// Only `GET info` is allowed; the match is ASCII case-insensitive and ignores
/// leading slashes. Any other method or path returns `None`.
fn allowed_dstack_rpc(method: &str, path: &str) -> Option<&'static str> {
    if method == "GET" && path.trim_start_matches('/').eq_ignore_ascii_case("info") {
        Some("Info")
    } else {
        None
    }
}

/// Whether an inbound header is copied to the outbound request. Routing
/// headers (`x-dstack-target-*`) and the proxy access token are not forwarded.
fn should_forward_header(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    !(name.starts_with("x-dstack-target-") || name == "x-dstack-mesh-token")
}

/// Proxy request to dstack.sock when no target headers are present
async fn proxy_to_dstack_sock(
    request: &DstackRequest,
    state: &State<ClientState>,
) -> Result<ProxyResponse, Status> {
    let path = request.path.trim_start_matches('/');

    if path.trim_start_matches('/').eq_ignore_ascii_case("gateway") {
        let gateway_info = serde_json::json!({
            "gateway_domain": state.gateway_domain
        });
        return Ok(ProxyResponse::Json(gateway_info));
    }

    let Some(rpc) = allowed_dstack_rpc(&request.method, path) else {
        warn!(
            "Rejecting dstack agent request: method '{}' path '{}' is not allowed",
            request.method, request.path
        );
        return Err(Status::Forbidden);
    };

    let agent_address = dstack_agent_address();
    let agent_url;
    let agent_sock;

    if agent_address.starts_with("unix:") {
        agent_url = format!("http://localhost/{rpc}");
        agent_sock = Some(agent_address.trim_start_matches("unix:").to_string());
    } else {
        agent_url = agent_address;
        agent_sock = None;
    };

    let mut client_builder = Client::builder();

    if let Some(agent_sock) = agent_sock {
        client_builder = client_builder.unix_socket(agent_sock);
    }

    let client = client_builder
        .build()
        .map_err(|_| Status::InternalServerError)?;

    let request_builder = client.get(&agent_url);
    match request_builder.send().await {
        Ok(response) => Ok(ProxyResponse::Stream(StreamingProxyResponse { response })),
        Err(e) => {
            tracing::error!("Request to dstack.sock failed: {}", e);
            Err(Status::BadGateway)
        }
    }
}

async fn proxy_request(
    request: &DstackRequest,
    state: &State<ClientState>,
    body: Option<Data<'_>>,
) -> Result<ProxyResponse, Status> {
    // Extract target info from headers
    let target = match extract_target_info(request) {
        Some(t) => t,
        None => {
            debug!("Missing x-dstack-target-app header, delegating to dstack.sock");
            return proxy_to_dstack_sock(request, state).await;
        }
    };

    // Validate connection target before proceeding
    validate_connection_target(&target)?;

    // Build target URL
    let url = {
        let path = request.path.trim_start_matches('/');
        let full_path = match &request.query_string {
            Some(query) => format!("{}?{}", path, query),
            None => path.to_string(),
        };
        let gateway_domain = state.gateway_domain.trim_end_matches("/");

        if gateway_domain.starts_with("fixed/") {
            let domain = gateway_domain.trim_start_matches("fixed/");
            format!("https://{domain}/{full_path}")
        } else {
            let id = if target.instance_id.is_empty() {
                &target.app_id
            } else {
                &target.instance_id
            };
            let port = &target.port;
            if request.use_tls {
                format!("https://{id}-{port}s.{gateway_domain}/{full_path}")
            } else {
                format!("https://{id}-{port}.{gateway_domain}/{full_path}")
            }
        }
    };

    // Create HTTP client with TLS config
    // Note: For now using simple HTTP client, would need to configure mTLS properly
    let http_method = match reqwest::Method::from_bytes(request.method.as_bytes()) {
        Ok(m) => m,
        Err(_) => return Err(Status::MethodNotAllowed),
    };

    let mut request_builder = if request.use_tls {
        state.http_client.request(http_method, &url)
    } else {
        // For non-TLS, create a separate client without mTLS
        let non_tls_client = Client::builder()
            .use_rustls_tls()
            .https_only(false)
            .redirect(Policy::none())
            .build()
            .map_err(|_| Status::InternalServerError)?;
        non_tls_client.request(http_method, &url)
    };

    // Handle body for methods that support it with streaming
    if let Some(body_data) = body {
        // Use a reasonable limit to prevent OOM (100MB)
        const MAX_BODY_SIZE: u64 = 100 * 1024 * 1024;
        let mut reader = body_data.open(rocket::data::ByteUnit::Byte(MAX_BODY_SIZE));

        // Read in chunks to avoid OOM
        let mut buffer = Vec::new();
        const CHUNK_SIZE: usize = 64 * 1024; // 64KB chunks
        let mut chunk = vec![0u8; CHUNK_SIZE];

        loop {
            match reader.read(&mut chunk).await {
                Ok(0) => break, // EOF
                Ok(n) => {
                    buffer.extend_from_slice(&chunk[..n]);
                    // Check if we're getting too large
                    if buffer.len() > MAX_BODY_SIZE as usize {
                        return Err(Status::PayloadTooLarge);
                    }
                }
                Err(_) => return Err(Status::BadRequest),
            }
        }

        request_builder = request_builder.body(buffer);
    }

    // Copy relevant headers (excluding routing headers)
    for (name, value) in &request.all_headers {
        if should_forward_header(name) {
            request_builder = request_builder.header(name, value);
        }
    }

    debug!(
        "Proxying request to app_id '{}' at URL: {}",
        target.app_id, url
    );

    // Execute request
    match request_builder.send().await {
        Ok(response) => {
            if request.use_tls {
                // TODO: It should be verified before sending the request. But reqwest doesn't support it.
                if let Err(err) = verify_response_security(&response, &target)
                    .context("Failed to verify response security")
                {
                    warn!("Failed to verify response security: {err:?}");
                    return Err(Status::BadGateway);
                }
            }
            // Return the response directly for streaming - no buffering!
            Ok(ProxyResponse::Stream(StreamingProxyResponse { response }))
        }
        Err(e) => {
            tracing::error!("mTLS request to app_id '{}' failed: {}", target.app_id, e);
            Err(Status::BadGateway)
        }
    }
}

fn extract_target_info(request: &DstackRequest) -> Option<TargetInfo> {
    // Extract app_id (required)
    let app_id = request.target_app.as_ref()?.clone();

    // Extract port (optional, default 443)
    let port = request
        .target_port
        .as_ref()
        .and_then(|v| v.parse().ok())
        .unwrap_or(443);

    // Extract instance (optional)
    let instance = request.target_instance.clone().unwrap_or_default();

    Some(TargetInfo {
        app_id,
        instance_id: instance,
        port,
    })
}

/// Create an HTTP client configured with mTLS using certificates from files
fn create_mtls_client(config: &Config) -> Result<Client> {
    use fs_err as fs;
    let key_pem = fs::read_to_string(&config.tls.key_file).context("Failed to read key file")?;
    let cert_pem = fs::read_to_string(&config.tls.cert_file).context("Failed to read cert file")?;
    let ca_pem = fs::read_to_string(&config.tls.ca_file).context("Failed to read CA file")?;

    // Try using the full certificate chain instead of just the leaf certificate
    let identity_pem = format!("{}\n{}", cert_pem, key_pem);
    let identity = reqwest::Identity::from_pem(identity_pem.as_bytes())?;
    let ca = reqwest::Certificate::from_pem(ca_pem.as_bytes())?;
    let client = Client::builder()
        .tls_backend_rustls() // Force rustls backend
        .identity(identity)
        .tls_info(true)
        .https_only(true)
        .danger_accept_invalid_hostnames(true)
        .danger_accept_invalid_certs(false)
        .tls_certs_only([ca]) // Use only the CA we provided, disable built-in root certs
        .redirect(Policy::none())
        .build()
        .context("Failed to build mTLS HTTP client")?;
    Ok(client)
}

/// Validate that we should connect to the specified target
fn validate_connection_target(target: &TargetInfo) -> Result<(), Status> {
    // Ensure app_id is present and valid
    if target.app_id.is_empty() {
        tracing::error!("Target app_id cannot be empty");
        return Err(Status::BadRequest);
    }

    // Validate app_id format (should be hex string for dstack)
    if !target.app_id.chars().all(|c| c.is_ascii_hexdigit()) {
        warn!(
            "Target app_id '{}' is not in expected hex format",
            target.app_id
        );
    }
    debug!(
        "Validated mTLS connection target - app_id: {}, port: {}, instance: '{}'",
        target.app_id, target.port, target.instance_id
    );
    Ok(())
}

/// Verify response security and log connection info
fn verify_response_security(response: &reqwest::Response, target: &TargetInfo) -> Result<()> {
    debug!(
        "mTLS connection established successfully - app_id: {}, port: {}, status: {}",
        target.app_id,
        target.port,
        response.status()
    );

    let Some(tls_info) = response.extensions().get::<TlsInfo>() else {
        bail!("No TLS info in response");
    };
    let Some(cert) = tls_info.peer_certificate() else {
        bail!("No peer certificate in response");
    };

    let (_, parsed_cert) =
        x509_parser::parse_x509_certificate(cert).context("Failed to parse certificate")?;
    let app_id = get_app_id(&parsed_cert)
        .context("Failed to get app id")?
        .context("Missing app id in server certificate")?;
    let app_id = hex::encode(app_id);
    if app_id.to_lowercase() != target.app_id.to_lowercase() {
        bail!(
            "Server app_id mismatch: expected '{}', got '{}'",
            target.app_id,
            app_id
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allows_get_info() {
        for p in ["info", "/info", "INFO", "Info"] {
            assert_eq!(allowed_dstack_rpc("GET", p), Some("Info"), "{p}");
        }
    }

    #[test]
    fn rejects_other_rpcs() {
        assert_eq!(allowed_dstack_rpc("POST", "info"), None);
        for p in [
            "GetTlsKey",
            "get_tls_key",
            "GetKey",
            "GetQuote",
            "Sign",
            "Attest",
            "info/",
            "foo/info",
            "info/foo",
            "",
        ] {
            assert_eq!(allowed_dstack_rpc("GET", p), None, "{p}");
        }
    }

    #[test]
    fn header_forwarding() {
        for h in [
            "x-dstack-mesh-token",
            "X-Dstack-Mesh-Token",
            "x-dstack-target-app",
        ] {
            assert!(!should_forward_header(h), "{h}");
        }
        for h in ["content-type", "x-dstack-app-id"] {
            assert!(should_forward_header(h), "{h}");
        }
    }

    #[test]
    fn constant_time_eq_compares_bytes() {
        assert!(constant_time_eq(b"secret", b"secret"));
        assert!(constant_time_eq(b"", b""));
        assert!(!constant_time_eq(b"secret", b"secreT"));
        assert!(!constant_time_eq(b"secret", b"secre"));
    }
}

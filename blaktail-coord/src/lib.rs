mod metrics;

pub use metrics::CoordMetrics;

use axum::{
    extract::{MatchedPath, Path as UrlPath, Query, Request, State},
    http::{header::AUTHORIZATION, HeaderMap, Method, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{delete, get, post, put},
    Json, Router,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use chrono::Utc;
use hmac::{Hmac, Mac};
use rand::{rngs::OsRng, RngCore};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    net::{Ipv4Addr, SocketAddr},
    path::Path,
    sync::{Arc, Mutex},
    time::Instant,
};
use thiserror::Error;
use tracing::info;
use uuid::Uuid;

const SCHEMA: &str = include_str!("../schema.sql");
const DEFAULT_NODE_KEY_TTL_SECS: i64 = 90 * 24 * 60 * 60;
const MIN_NODE_KEY_TTL_SECS: i64 = 24 * 60 * 60;
const MAX_NODE_KEY_TTL_SECS: i64 = 365 * 24 * 60 * 60;
const DEVICE_AUTH_TTL_SECS: i64 = 10 * 60;
const DEVICE_AUTH_POLL_SECS: u64 = 2;
const MAX_PENDING_DEVICE_AUTHS: i64 = 1_000;
const DEFAULT_CONSOLE_URL: &str = "https://console.invalid";
#[derive(Clone)]
pub struct Store(Arc<Mutex<Connection>>);
impl Store {
    pub fn open(path: impl AsRef<Path>) -> Result<Self, rusqlite::Error> {
        let db = Connection::open(path)?;
        db.execute_batch("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL;")?;
        db.execute_batch(SCHEMA)?;
        // `CREATE TABLE IF NOT EXISTS` does not evolve databases created by an
        // earlier release. Keep the v1 SQLite schema forward-compatible.
        ensure_column(&db, "join_keys", "user_id", "TEXT NOT NULL DEFAULT ''")?;
        ensure_column(
            &db,
            "join_keys",
            "user_role",
            "TEXT NOT NULL DEFAULT 'owner'",
        )?;
        ensure_column(&db, "join_keys", "tags_json", "TEXT NOT NULL DEFAULT '[]'")?;
        ensure_column(&db, "nodes", "user_id", "TEXT NOT NULL DEFAULT ''")?;
        ensure_column(&db, "nodes", "user_role", "TEXT NOT NULL DEFAULT 'owner'")?;
        ensure_column(&db, "nodes", "tags_json", "TEXT NOT NULL DEFAULT '[]'")?;
        ensure_column(&db, "nodes", "dns_name", "TEXT NOT NULL DEFAULT ''")?;
        ensure_column(
            &db,
            "nodes",
            "advertised_routes_json",
            "TEXT NOT NULL DEFAULT '[]'",
        )?;
        ensure_column(
            &db,
            "nodes",
            "approved_routes_json",
            "TEXT NOT NULL DEFAULT '[]'",
        )?;
        ensure_column(&db, "nodes", "relay_endpoint", "TEXT")?;
        ensure_column(&db, "nodes", "relay_endpoint_updated_at", "INTEGER")?;
        ensure_column(
            &db,
            "orgs",
            "node_key_ttl_seconds",
            "INTEGER NOT NULL DEFAULT 7776000",
        )?;
        ensure_column(
            &db,
            "nodes",
            "credential_expires_at",
            "INTEGER NOT NULL DEFAULT 0",
        )?;
        db.execute(
            "UPDATE nodes SET credential_expires_at=CAST(created_at AS INTEGER)+(SELECT node_key_ttl_seconds FROM orgs WHERE orgs.id=nodes.org_id) WHERE credential_expires_at=0",
            [],
        )?;
        normalise_dns_names(&db)?;
        db.execute_batch(
            "CREATE UNIQUE INDEX IF NOT EXISTS nodes_dns_name_org_idx ON nodes(org_id,dns_name) WHERE dns_name<>''",
        )?;
        Ok(Self(Arc::new(Mutex::new(db))))
    }
    pub fn memory() -> Result<Self, rusqlite::Error> {
        Self::open(":memory:")
    }
}

fn normalise_dns_names(db: &Connection) -> Result<(), rusqlite::Error> {
    let rows = {
        let mut query =
            db.prepare("SELECT id,org_id,name,dns_name FROM nodes ORDER BY org_id,created_at,id")?;
        let collected = query
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        collected
    };
    let mut used = std::collections::HashSet::new();
    for (id, org_id, name, current) in rows {
        let base = magic_dns_name(&name, &org_id);
        let mut desired = base.clone();
        if used.contains(&(org_id.clone(), desired.clone())) {
            let id_hash = hash(&id);
            let suffix = format!("-{}", &id_hash[..8]);
            let (label, domain) = base.split_once('.').expect("generated DNS name has domain");
            let keep = 63usize.saturating_sub(suffix.len());
            desired = format!(
                "{}{}.{}",
                label
                    .chars()
                    .take(keep)
                    .collect::<String>()
                    .trim_end_matches('-'),
                suffix,
                domain
            );
        }
        used.insert((org_id, desired.clone()));
        if current != desired {
            db.execute(
                "UPDATE nodes SET dns_name=?1 WHERE id=?2",
                params![desired, id],
            )?;
        }
    }
    Ok(())
}
fn ensure_column(
    db: &Connection,
    table: &str,
    column: &str,
    definition: &str,
) -> Result<(), rusqlite::Error> {
    let mut statement = db.prepare(&format!("PRAGMA table_info({table})"))?;
    let names = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?;
    if !names.iter().any(|name| name == column) {
        db.execute_batch(&format!(
            "ALTER TABLE {table} ADD COLUMN {column} {definition}"
        ))?;
    }
    Ok(())
}
#[derive(Clone)]
struct AppState {
    store: Store,
    metrics: Arc<CoordMetrics>,
    region: String,
    auth_hmac_secret: Arc<[u8]>,
    relay_auth_secret: Arc<[u8]>,
    /// Advertised relay endpoints (host:port, UDP) handed to nodes.
    relays: Arc<Vec<String>>,
    console_url: Arc<String>,
}
pub fn app(store: Store, region: String, auth_hmac_secret: impl Into<Vec<u8>>) -> Router {
    app_with_relays_and_console(
        store,
        region,
        auth_hmac_secret,
        Vec::<u8>::new(),
        Vec::new(),
        DEFAULT_CONSOLE_URL.into(),
    )
}
pub fn app_with_relays(
    store: Store,
    region: String,
    auth_hmac_secret: impl Into<Vec<u8>>,
    relay_auth_secret: impl Into<Vec<u8>>,
    relays: Vec<String>,
) -> Router {
    app_with_relays_and_console(
        store,
        region,
        auth_hmac_secret,
        relay_auth_secret,
        relays,
        DEFAULT_CONSOLE_URL.into(),
    )
}
pub fn app_with_relays_and_console(
    store: Store,
    region: String,
    auth_hmac_secret: impl Into<Vec<u8>>,
    relay_auth_secret: impl Into<Vec<u8>>,
    relays: Vec<String>,
    console_url: String,
) -> Router {
    app_with_relays_console_and_metrics(
        store,
        region,
        auth_hmac_secret,
        relay_auth_secret,
        relays,
        console_url,
        Arc::new(CoordMetrics::default()),
    )
}

pub fn app_with_relays_console_and_metrics(
    store: Store,
    region: String,
    auth_hmac_secret: impl Into<Vec<u8>>,
    relay_auth_secret: impl Into<Vec<u8>>,
    relays: Vec<String>,
    console_url: String,
    metrics: Arc<CoordMetrics>,
) -> Router {
    let state = AppState {
        store,
        metrics,
        region,
        auth_hmac_secret: auth_hmac_secret.into().into(),
        relay_auth_secret: relay_auth_secret.into().into(),
        relays: Arc::new(relays),
        console_url: Arc::new(console_url.trim_end_matches('/').to_owned()),
    };
    Router::new()
        .route("/health", get(health))
        .route(
            "/v1/device-authorizations",
            post(create_device_authorization),
        )
        .route(
            "/v1/device-authorizations/:device_code",
            get(poll_device_authorization),
        )
        .route("/v1/orgs", post(create_org))
        .route("/v1/orgs/:org_id/join-keys", post(mint_join_key))
        .route(
            "/v1/orgs/:org_id/device-authorizations/:user_code",
            get(get_device_authorization).post(approve_device_authorization),
        )
        .route("/v1/orgs/:org_id/nodes", get(list_nodes))
        .route("/v1/orgs/:org_id/nodes/:node_id", delete(admin_revoke_node))
        .route(
            "/v1/orgs/:org_id/nodes/:node_id/routes",
            put(approve_node_routes),
        )
        .route("/v1/orgs/:org_id/acl", get(get_acl))
        .route("/v1/orgs/:org_id/acl", put(put_acl))
        .route("/v1/orgs/:org_id/security", get(get_security_policy))
        .route("/v1/orgs/:org_id/security", put(put_security_policy))
        .route("/v1/orgs/:org_id/audit", get(list_audit_events))
        .route("/v1/nodes/register", post(register_node))
        .route("/v1/nodes/:node_id/reauth", post(reauth_node))
        .route("/v1/nodes/:node_id/peers", get(list_peers))
        .route("/v1/nodes/:node_id/routes", put(update_advertised_routes))
        .route(
            "/v1/nodes/:node_id/relay-endpoint",
            put(update_relay_endpoint),
        )
        .route("/v1/nodes/:node_id", delete(revoke_node))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            record_metrics,
        ))
        .with_state(state)
}

#[derive(Clone)]
struct MetricsState {
    store: Store,
    metrics: Arc<CoordMetrics>,
}

pub fn metrics_app(store: Store, metrics: Arc<CoordMetrics>) -> Router {
    Router::new()
        .route("/metrics", get(prometheus_metrics))
        .with_state(MetricsState { store, metrics })
}

async fn prometheus_metrics(
    State(state): State<MetricsState>,
) -> Result<impl IntoResponse, ApiError> {
    let active_nodes: i64 = state.store.0.lock().unwrap().query_row(
        "SELECT COUNT(*) FROM nodes WHERE revoked_at IS NULL AND credential_expires_at>?1",
        params![now()],
        |row| row.get(0),
    )?;
    Ok((
        [("content-type", "text/plain; version=0.0.4; charset=utf-8")],
        state.metrics.render(active_nodes.max(0) as u64),
    ))
}

async fn record_metrics(State(state): State<AppState>, request: Request, next: Next) -> Response {
    let operation = request.extensions().get::<MatchedPath>().and_then(|path| {
        match (request.method(), path.as_str()) {
            (&Method::POST, "/v1/nodes/register") => Some(metrics::Operation::Register),
            (&Method::GET, "/v1/nodes/:node_id/peers") => Some(metrics::Operation::Peers),
            (&Method::DELETE, "/v1/nodes/:node_id")
            | (&Method::DELETE, "/v1/orgs/:org_id/nodes/:node_id") => {
                Some(metrics::Operation::Revoke)
            }
            _ => None,
        }
    });
    let started = Instant::now();
    let response = next.run(request).await;
    if let Some(operation) = operation {
        state
            .metrics
            .record(operation, response.status().as_u16(), started.elapsed());
    }
    response
}
#[derive(Debug, Error)]
enum ApiError {
    #[error("{0}")]
    BadRequest(String),
    #[error("authentication failed")]
    Unauthorized,
    #[error("node credential expired; run blaktaild reauth with a fresh join key")]
    CredentialExpired,
    #[error("permission denied")]
    Forbidden,
    #[error("resource not found")]
    NotFound,
    #[error("device authorization expired; run blaktaild up again")]
    Gone,
    #[error("too many pending device authorizations; try again later")]
    TooManyRequests,
    #[error("conflict: {0}")]
    Conflict(String),
    #[error("database error")]
    Database(#[from] rusqlite::Error),
}
impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let status = match self {
            Self::BadRequest(_) => StatusCode::BAD_REQUEST,
            Self::Unauthorized => StatusCode::UNAUTHORIZED,
            Self::CredentialExpired => StatusCode::UNAUTHORIZED,
            Self::Forbidden => StatusCode::FORBIDDEN,
            Self::NotFound => StatusCode::NOT_FOUND,
            Self::Gone => StatusCode::GONE,
            Self::TooManyRequests => StatusCode::TOO_MANY_REQUESTS,
            Self::Conflict(_) => StatusCode::CONFLICT,
            Self::Database(_) => StatusCode::INTERNAL_SERVER_ERROR,
        };
        (status, Json(serde_json::json!({"error":self.to_string()}))).into_response()
    }
}
#[derive(Serialize)]
struct Health {
    status: &'static str,
    region: String,
}
async fn health(State(s): State<AppState>) -> Json<Health> {
    Json(Health {
        status: "ok",
        region: s.region,
    })
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CreateDeviceAuthorization {
    name: String,
    wg_public_key: String,
}

#[derive(Serialize, Deserialize)]
struct DeviceAuthorizationResponse {
    device_code: String,
    user_code: String,
    verification_url: String,
    expires_at: i64,
    interval_seconds: u64,
}

#[derive(Serialize, Deserialize)]
struct DeviceAuthorizationStatus {
    status: String,
    expires_at: i64,
}

#[derive(Serialize, Deserialize)]
struct DeviceAuthorizationPreview {
    name: String,
    public_key_fingerprint: String,
    expires_at: i64,
    approved: bool,
}

struct DeviceAuthorizationPreviewRow {
    name: String,
    public_key: String,
    expires_at: i64,
    approved_at: Option<i64>,
    approved_org: Option<String>,
}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct ApproveDeviceAuthorization {
    #[serde(default)]
    tags: Vec<DeviceTag>,
}

#[derive(Serialize, Deserialize)]
struct DeviceAuthorizationApproval {
    status: String,
    expires_at: i64,
}

struct DeviceAuthorizationApprovalRow {
    id: String,
    device_code_hash: String,
    expires_at: i64,
    approved_at: Option<i64>,
    approved_org: Option<String>,
    approved_user: Option<String>,
}

async fn create_device_authorization(
    State(s): State<AppState>,
    Json(input): Json<CreateDeviceAuthorization>,
) -> Result<(StatusCode, Json<DeviceAuthorizationResponse>), ApiError> {
    let name = input.name.trim();
    let public_key = input.wg_public_key.trim();
    if name.is_empty() || public_key.is_empty() || name.chars().count() > 128 {
        return Err(ApiError::BadRequest(
            "name and wg_public_key are required; name must be at most 128 characters".into(),
        ));
    }

    let created_at = now();
    let expires_at = created_at + DEVICE_AUTH_TTL_SECS;
    let db = s.store.0.lock().unwrap();
    db.execute(
        "DELETE FROM device_authorizations WHERE expires_at<=?1",
        params![created_at],
    )?;
    let pending: i64 = db.query_row(
        "SELECT COUNT(*) FROM device_authorizations WHERE approved_at IS NULL AND expires_at>?1",
        params![created_at],
        |row| row.get(0),
    )?;
    if pending >= MAX_PENDING_DEVICE_AUTHS {
        return Err(ApiError::TooManyRequests);
    }

    for _ in 0..5 {
        let device_code = secret("btd");
        let user_code = user_code();
        let result = db.execute(
            "INSERT INTO device_authorizations(id,device_code_hash,user_code_hash,requested_name,wg_public_key,expires_at) VALUES(?1,?2,?3,?4,?5,?6)",
            params![
                Uuid::new_v4().to_string(),
                hash(&device_code),
                hash(&normalise_user_code(&user_code).expect("generated user code is valid")),
                name,
                public_key,
                expires_at,
            ],
        );
        match result {
            Ok(_) => {
                return Ok((
                    StatusCode::CREATED,
                    Json(DeviceAuthorizationResponse {
                        device_code,
                        user_code: user_code.clone(),
                        verification_url: format!("{}/enroll?code={user_code}", s.console_url),
                        expires_at,
                        interval_seconds: DEVICE_AUTH_POLL_SECS,
                    }),
                ));
            }
            Err(rusqlite::Error::SqliteFailure(ref code, _)) if code.extended_code == 2067 => {}
            Err(error) => return Err(ApiError::Database(error)),
        }
    }
    Err(ApiError::Conflict(
        "could not allocate a unique device authorization code".into(),
    ))
}

async fn poll_device_authorization(
    State(s): State<AppState>,
    UrlPath(device_code): UrlPath<String>,
) -> Result<Response, ApiError> {
    let db = s.store.0.lock().unwrap();
    let row: Option<(i64, Option<i64>, Option<i64>)> = db
        .query_row(
            "SELECT expires_at,approved_at,consumed_at FROM device_authorizations WHERE device_code_hash=?1",
            params![hash(device_code.trim())],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?;
    let (expires_at, approved_at, consumed_at) = row.ok_or(ApiError::Unauthorized)?;
    if expires_at <= now() || consumed_at.is_some() {
        return Err(ApiError::Gone);
    }
    let (status, state) = if approved_at.is_some() {
        (StatusCode::OK, "approved")
    } else {
        (StatusCode::ACCEPTED, "pending")
    };
    Ok((
        status,
        Json(DeviceAuthorizationStatus {
            status: state.into(),
            expires_at,
        }),
    )
        .into_response())
}

async fn get_device_authorization(
    State(s): State<AppState>,
    UrlPath((org_id, user_code)): UrlPath<(Uuid, String)>,
    headers: HeaderMap,
) -> Result<Json<DeviceAuthorizationPreview>, ApiError> {
    console_session(&s, &headers, org_id)?;
    let code = normalise_user_code(&user_code)
        .ok_or_else(|| ApiError::BadRequest("device code must contain eight characters".into()))?;
    let db = s.store.0.lock().unwrap();
    let row: Option<DeviceAuthorizationPreviewRow> = db
        .query_row(
            "SELECT requested_name,wg_public_key,expires_at,approved_at,org_id FROM device_authorizations WHERE user_code_hash=?1",
            params![hash(&code)],
            |row| {
                Ok(DeviceAuthorizationPreviewRow {
                    name: row.get(0)?,
                    public_key: row.get(1)?,
                    expires_at: row.get(2)?,
                    approved_at: row.get(3)?,
                    approved_org: row.get(4)?,
                })
            },
        )
        .optional()?;
    let row = row.ok_or(ApiError::NotFound)?;
    if row.expires_at <= now() {
        return Err(ApiError::Gone);
    }
    if row
        .approved_org
        .as_deref()
        .is_some_and(|id| id != org_id.to_string())
    {
        return Err(ApiError::NotFound);
    }
    Ok(Json(DeviceAuthorizationPreview {
        name: row.name,
        public_key_fingerprint: hash(&row.public_key)[..12].into(),
        expires_at: row.expires_at,
        approved: row.approved_at.is_some(),
    }))
}

async fn approve_device_authorization(
    State(s): State<AppState>,
    UrlPath((org_id, user_code)): UrlPath<(Uuid, String)>,
    headers: HeaderMap,
    Json(input): Json<ApproveDeviceAuthorization>,
) -> Result<Json<DeviceAuthorizationApproval>, ApiError> {
    let session = console_session(&s, &headers, org_id)?;
    let code = normalise_user_code(&user_code)
        .ok_or_else(|| ApiError::BadRequest("device code must contain eight characters".into()))?;
    let tags = if session.role == Role::Member {
        Vec::new()
    } else {
        canonical_tags(input.tags)
    };
    let mut db = s.store.0.lock().unwrap();
    let tx = db.transaction()?;
    let row: Option<DeviceAuthorizationApprovalRow> = tx
        .query_row(
            "SELECT id,device_code_hash,expires_at,approved_at,org_id,user_id FROM device_authorizations WHERE user_code_hash=?1",
            params![hash(&code)],
            |row| {
                Ok(DeviceAuthorizationApprovalRow {
                    id: row.get(0)?,
                    device_code_hash: row.get(1)?,
                    expires_at: row.get(2)?,
                    approved_at: row.get(3)?,
                    approved_org: row.get(4)?,
                    approved_user: row.get(5)?,
                })
            },
        )
        .optional()?;
    let row = row.ok_or(ApiError::NotFound)?;
    if row.expires_at <= now() {
        return Err(ApiError::Gone);
    }
    if row.approved_at.is_some() {
        if row.approved_org.as_deref() == Some(&org_id.to_string())
            && row.approved_user.as_deref() == Some(session.user_id.as_str())
        {
            return Ok(Json(DeviceAuthorizationApproval {
                status: "approved".into(),
                expires_at: row.expires_at,
            }));
        }
        return Err(ApiError::Conflict(
            "device authorization was already approved".into(),
        ));
    }
    let join_key_id = Uuid::new_v4();
    let tags_json = serde_json::to_string(&tags).unwrap();
    let inserted = tx
        .execute(
        "INSERT INTO join_keys(id,org_id,key_hash,expires_at,single_use,created_at,user_id,user_role,tags_json) SELECT ?1,id,?2,?3,1,?4,?5,?6,?7 FROM orgs WHERE id=?8",
        params![
            join_key_id.to_string(),
            row.device_code_hash,
            row.expires_at,
            now(),
            session.user_id,
            session.role.as_str(),
            tags_json,
            org_id.to_string(),
        ],
    )
        .map_err(conflict("device authorization was already approved"))?;
    if inserted != 1 {
        return Err(ApiError::NotFound);
    }
    let changed = tx.execute(
        "UPDATE device_authorizations SET approved_at=?1,org_id=?2,user_id=?3,user_role=?4,tags_json=?5 WHERE user_code_hash=?6 AND approved_at IS NULL",
        params![
            now(),
            org_id.to_string(),
            session.user_id,
            session.role.as_str(),
            serde_json::to_string(&tags).unwrap(),
            hash(&code),
        ],
    )?;
    if changed != 1 {
        return Err(ApiError::Conflict(
            "device authorization was already approved".into(),
        ));
    }
    append_audit(
        &tx,
        org_id,
        &session,
        "join_key.minted",
        "join_key",
        Some(&join_key_id.to_string()),
        &serde_json::json!({
            "expires_at": row.expires_at,
            "single_use": true,
            "source": "browser_enrollment",
            "tags": tags,
        }),
    )?;
    append_audit(
        &tx,
        org_id,
        &session,
        "device_authorization.approved",
        "device_authorization",
        Some(&row.id),
        &serde_json::json!({"join_key_id": join_key_id}),
    )?;
    tx.commit()?;
    info!(%org_id, user_id = %session.user_id, "device authorization approved");
    Ok(Json(DeviceAuthorizationApproval {
        status: "approved".into(),
        expires_at: row.expires_at,
    }))
}

#[derive(Deserialize)]
struct CreateOrg {
    name: String,
    #[serde(default = "default_acl")]
    acl: serde_json::Value,
    #[serde(default = "default_node_key_ttl")]
    node_key_ttl_seconds: i64,
}
fn default_acl() -> serde_json::Value {
    serde_json::json!({"rules":[]})
}
fn default_node_key_ttl() -> i64 {
    DEFAULT_NODE_KEY_TTL_SECS
}
#[derive(Serialize, Deserialize)]
struct OrgResponse {
    id: Uuid,
    name: String,
    node_key_ttl_seconds: i64,
}
async fn create_org(
    State(s): State<AppState>,
    Json(input): Json<CreateOrg>,
) -> Result<(StatusCode, Json<OrgResponse>), ApiError> {
    let name = input.name.trim();
    if name.is_empty() {
        return Err(ApiError::BadRequest("org name must not be empty".into()));
    }
    validate_node_key_ttl(input.node_key_ttl_seconds)?;
    let acl: Acl = serde_json::from_value(input.acl.clone())
        .map_err(|error| ApiError::BadRequest(format!("invalid ACL: {error}")))?;
    acl.validate()?;
    let id = Uuid::new_v4();
    s.store
        .0
        .lock()
        .unwrap()
        .execute(
            "INSERT INTO orgs(id,name,acl_json,created_at,node_key_ttl_seconds) VALUES(?1,?2,?3,?4,?5)",
            params![id.to_string(), name, input.acl.to_string(), now(), input.node_key_ttl_seconds],
        )
        .map_err(conflict("org name already exists"))?;
    Ok((
        StatusCode::CREATED,
        Json(OrgResponse {
            id,
            name: name.into(),
            node_key_ttl_seconds: input.node_key_ttl_seconds,
        }),
    ))
}

#[derive(Deserialize, Serialize)]
struct SecurityPolicy {
    node_key_ttl_seconds: i64,
}

fn validate_node_key_ttl(seconds: i64) -> Result<(), ApiError> {
    if !(MIN_NODE_KEY_TTL_SECS..=MAX_NODE_KEY_TTL_SECS).contains(&seconds) {
        return Err(ApiError::BadRequest(format!(
            "node_key_ttl_seconds must be between {MIN_NODE_KEY_TTL_SECS} and {MAX_NODE_KEY_TTL_SECS}"
        )));
    }
    Ok(())
}
fn conflict(message: &'static str) -> impl FnOnce(rusqlite::Error) -> ApiError {
    move |e| match e {
        rusqlite::Error::SqliteFailure(ref c, _) if c.extended_code == 2067 => {
            ApiError::Conflict(message.into())
        }
        other => ApiError::Database(other),
    }
}

#[derive(Deserialize)]
struct MintJoinKey {
    #[serde(default = "default_expiry")]
    expires_in_seconds: i64,
    #[serde(default = "yes")]
    single_use: bool,
    #[serde(default)]
    tags: Vec<DeviceTag>,
}
fn default_expiry() -> i64 {
    3600
}
fn yes() -> bool {
    true
}
#[derive(Serialize, Deserialize)]
struct JoinKeyResponse {
    id: Uuid,
    key: String,
    expires_at: i64,
    single_use: bool,
}
async fn mint_join_key(
    State(s): State<AppState>,
    UrlPath(org_id): UrlPath<Uuid>,
    headers: HeaderMap,
    Json(input): Json<MintJoinKey>,
) -> Result<(StatusCode, Json<JoinKeyResponse>), ApiError> {
    let session = console_session(&s, &headers, org_id)?;
    if session.role == Role::Member {
        return Err(ApiError::Forbidden);
    }
    if !(1..=2_592_000).contains(&input.expires_in_seconds) {
        return Err(ApiError::BadRequest(
            "expires_in_seconds must be between 1 and 2592000".into(),
        ));
    }
    let key = secret("btk");
    let id = Uuid::new_v4();
    let expires_at = now() + input.expires_in_seconds;
    let tags = canonical_tags(input.tags);
    let mut db = s.store.0.lock().unwrap();
    let tx = db.transaction()?;
    let changed=tx.execute("INSERT INTO join_keys(id,org_id,key_hash,expires_at,single_use,created_at,user_id,user_role,tags_json) SELECT ?1,id,?2,?3,?4,?5,?6,?7,?8 FROM orgs WHERE id=?9",params![id.to_string(),hash(&key),expires_at,input.single_use,now(),session.user_id,session.role.as_str(),serde_json::to_string(&tags).unwrap(),org_id.to_string()])?;
    if changed == 0 {
        return Err(ApiError::NotFound);
    }
    append_audit(
        &tx,
        org_id,
        &session,
        "join_key.minted",
        "join_key",
        Some(&id.to_string()),
        &serde_json::json!({
            "expires_at": expires_at,
            "single_use": input.single_use,
            "source": "console",
            "tags": tags,
        }),
    )?;
    tx.commit()?;
    Ok((
        StatusCode::CREATED,
        Json(JoinKeyResponse {
            id,
            key,
            expires_at,
            single_use: input.single_use,
        }),
    ))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RegisterNode {
    join_key: String,
    name: String,
    wg_public_key: String,
    #[serde(default)]
    endpoint: Option<String>,
    #[serde(default)]
    allowed_ips: Vec<String>,
    #[serde(default)]
    advertised_routes: Vec<String>,
}

struct RegistrationGrant {
    key_id: String,
    org_id: String,
    single_use: bool,
    used: bool,
    user_id: String,
    user_role: String,
    tags_json: String,
    node_key_ttl: i64,
    bound_name: Option<String>,
    bound_wg_public_key: Option<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Owner,
    Admin,
    Member,
}
impl Role {
    fn as_str(self) -> &'static str {
        match self {
            Self::Owner => "owner",
            Self::Admin => "admin",
            Self::Member => "member",
        }
    }
}
impl std::str::FromStr for Role {
    type Err = ();
    fn from_str(v: &str) -> Result<Self, ()> {
        match v {
            "owner" => Ok(Self::Owner),
            "admin" => Ok(Self::Admin),
            "member" => Ok(Self::Member),
            _ => Err(()),
        }
    }
}
#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "lowercase")]
enum DeviceTag {
    Office,
    Ranger,
    Store,
}
fn canonical_tags(mut tags: Vec<DeviceTag>) -> Vec<DeviceTag> {
    tags.sort();
    tags.dedup();
    tags
}
#[derive(Serialize, Deserialize)]
struct RegisterResponse {
    id: Uuid,
    org_id: Uuid,
    node_token: String,
    assigned_ip: String,
    dns_name: String,
    credential_expires_at: i64,
    /// Advertised relay endpoints plus a capability token for them.
    #[serde(default)]
    relays: Vec<String>,
    #[serde(default)]
    relay_token: String,
    #[serde(default)]
    relay_expires_at: u64,
}
async fn register_node(
    State(s): State<AppState>,
    Json(input): Json<RegisterNode>,
) -> Result<(StatusCode, Json<RegisterResponse>), ApiError> {
    if input.name.trim().is_empty() || input.wg_public_key.trim().is_empty() {
        return Err(ApiError::BadRequest(
            "name and wg_public_key are required".into(),
        ));
    }
    if !input.allowed_ips.is_empty() {
        return Err(ApiError::BadRequest(
            "allowed_ips are assigned by the coordinator".into(),
        ));
    }
    let advertised_routes = validate_advertised_routes(input.advertised_routes)?;
    let mut db = s.store.0.lock().unwrap();
    let tx = db.transaction()?;
    let input_key_hash = hash(&input.join_key);
    let grant: Option<RegistrationGrant> = tx.query_row("SELECT k.id,k.org_id,k.single_use,k.used_at IS NOT NULL,k.user_id,k.user_role,k.tags_json,o.node_key_ttl_seconds,d.requested_name,d.wg_public_key FROM join_keys k JOIN orgs o ON o.id=k.org_id LEFT JOIN device_authorizations d ON d.device_code_hash=k.key_hash WHERE k.key_hash=?1 AND k.revoked_at IS NULL AND k.expires_at>?2",params![input_key_hash,now()],|r|Ok(RegistrationGrant { key_id: r.get(0)?, org_id: r.get(1)?, single_use: r.get(2)?, used: r.get(3)?, user_id: r.get(4)?, user_role: r.get(5)?, tags_json: r.get(6)?, node_key_ttl: r.get(7)?, bound_name: r.get(8)?, bound_wg_public_key: r.get(9)? })).optional()?;
    let grant = grant.ok_or(ApiError::Unauthorized)?;
    if grant.single_use && grant.used {
        return Err(ApiError::Unauthorized);
    }
    if grant
        .bound_name
        .as_deref()
        .is_some_and(|name| name != input.name.trim())
        || grant
            .bound_wg_public_key
            .as_deref()
            .is_some_and(|key| key != input.wg_public_key.trim())
    {
        return Err(ApiError::BadRequest(
            "browser authorization is bound to another device identity; run blaktaild up again"
                .into(),
        ));
    }
    let id = Uuid::new_v4();
    let token = secret("btn");
    let allowed_ips = vec![allocate_ip(&tx, &grant.org_id)?];
    let assigned_ip = allowed_ips[0].clone();
    let dns_name = magic_dns_name(input.name.trim(), &grant.org_id);
    let registered_at = now();
    let credential_expires_at = registered_at + grant.node_key_ttl;
    tx.execute("INSERT INTO nodes(id,org_id,name,wg_public_key,endpoint,allowed_ips_json,token_hash,created_at,user_id,user_role,tags_json,dns_name,advertised_routes_json,approved_routes_json,credential_expires_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,'[]',?14)",params![id.to_string(),grant.org_id,input.name.trim(),input.wg_public_key.trim(),input.endpoint,serde_json::to_string(&allowed_ips).unwrap(),hash(&token),registered_at,grant.user_id,grant.user_role,grant.tags_json,dns_name,serde_json::to_string(&advertised_routes).unwrap(),credential_expires_at]).map_err(conflict("node name, DNS name, public key, or address already exists in org"))?;
    if grant.single_use {
        tx.execute(
            "UPDATE join_keys SET used_at=?1 WHERE id=?2",
            params![now(), grant.key_id],
        )?;
    }
    tx.execute(
        "UPDATE device_authorizations SET consumed_at=?1 WHERE device_code_hash=?2",
        params![now(), input_key_hash],
    )?;
    tx.commit()?;
    info!(node_id=%id, org_id=%grant.org_id, "node registered");
    let (relay_token, relay_expires_at) = relay_credentials(&s, id);
    Ok((
        StatusCode::CREATED,
        Json(RegisterResponse {
            id,
            org_id: Uuid::parse_str(&grant.org_id).unwrap(),
            node_token: token,
            assigned_ip,
            dns_name,
            credential_expires_at,
            relays: s.relays.as_ref().clone(),
            relay_token,
            relay_expires_at,
        }),
    ))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AdvertisedRoutesUpdate {
    advertised_routes: Vec<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ApprovedRoutesUpdate {
    approved_routes: Vec<String>,
}

async fn update_advertised_routes(
    State(s): State<AppState>,
    UrlPath(node_id): UrlPath<Uuid>,
    headers: HeaderMap,
    Json(input): Json<AdvertisedRoutesUpdate>,
) -> Result<StatusCode, ApiError> {
    let routes = validate_advertised_routes(input.advertised_routes)?;
    let token = bearer(&headers)?;
    let db = s.store.0.lock().unwrap();
    let row: Option<(i64, String)> = db
        .query_row(
            "SELECT credential_expires_at,approved_routes_json FROM nodes WHERE id=?1 AND token_hash=?2 AND revoked_at IS NULL",
            params![node_id.to_string(), token],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    let (credential_expires_at, approved_json) = row.ok_or(ApiError::Unauthorized)?;
    if credential_expires_at <= now() {
        return Err(ApiError::CredentialExpired);
    }
    let approved: Vec<String> = serde_json::from_str(&approved_json).unwrap_or_default();
    let retained_approvals: Vec<_> = approved
        .into_iter()
        .filter(|route| routes.contains(route))
        .collect();
    db.execute(
        "UPDATE nodes SET advertised_routes_json=?1,approved_routes_json=?2 WHERE id=?3",
        params![
            serde_json::to_string(&routes).unwrap(),
            serde_json::to_string(&retained_approvals).unwrap(),
            node_id.to_string(),
        ],
    )?;
    info!(%node_id, routes = routes.len(), "node route advertisements updated");
    Ok(StatusCode::NO_CONTENT)
}

async fn approve_node_routes(
    State(s): State<AppState>,
    UrlPath((org_id, node_id)): UrlPath<(Uuid, Uuid)>,
    headers: HeaderMap,
    Json(input): Json<ApprovedRoutesUpdate>,
) -> Result<StatusCode, ApiError> {
    let session = console_session(&s, &headers, org_id)?;
    if session.role == Role::Member {
        return Err(ApiError::Forbidden);
    }
    let approved = validate_advertised_routes(input.approved_routes)?;
    let approval_time = now();
    let mut db = s.store.0.lock().unwrap();
    let tx = db.transaction()?;
    let advertised_row: Option<(String, String, i64)> = tx
        .query_row(
            "SELECT advertised_routes_json,approved_routes_json,credential_expires_at FROM nodes WHERE id=?1 AND org_id=?2 AND revoked_at IS NULL",
            params![node_id.to_string(), org_id.to_string()],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?;
    let (advertised_json, current_approved_json, credential_expires_at) =
        advertised_row.ok_or(ApiError::NotFound)?;
    let current_approved: Vec<String> =
        serde_json::from_str(&current_approved_json).unwrap_or_default();
    if credential_expires_at <= approval_time
        && approved
            .iter()
            .any(|route| !current_approved.contains(route))
    {
        return Err(ApiError::Conflict(
            "cannot add route approvals to an expired node; renew it first".into(),
        ));
    }
    let advertised: Vec<String> = serde_json::from_str(&advertised_json).unwrap_or_default();
    if approved.iter().any(|route| !advertised.contains(route)) {
        return Err(ApiError::BadRequest(
            "approved routes must be a subset of the node's advertisements".into(),
        ));
    }
    let mut query = tx.prepare(
        "SELECT id,credential_expires_at,approved_routes_json FROM nodes WHERE org_id=?1 AND id!=?2 AND revoked_at IS NULL",
    )?;
    let other_nodes = query
        .query_map(params![org_id.to_string(), node_id.to_string()], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, String>(2)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let other_routes = other_nodes
        .iter()
        .filter(|(_, expires_at, _)| *expires_at > approval_time)
        .flat_map(|(_, _, json)| serde_json::from_str::<Vec<String>>(json).unwrap_or_default())
        .filter(|route| route != "0.0.0.0/0")
        .collect::<Vec<_>>();
    if let Some(route) = approved.iter().find(|route| {
        route.as_str() != "0.0.0.0/0"
            && other_routes
                .iter()
                .any(|other| ipv4_routes_overlap(route, other))
    }) {
        return Err(ApiError::Conflict(format!(
            "route {route} overlaps another approved subnet router"
        )));
    }
    drop(query);
    let approved_subnets: Vec<_> = approved
        .iter()
        .filter(|route| route.as_str() != "0.0.0.0/0")
        .collect();
    for (other_id, expires_at, routes_json) in other_nodes {
        if expires_at > approval_time {
            continue;
        }
        let mut routes: Vec<String> = serde_json::from_str(&routes_json).unwrap_or_default();
        let original_len = routes.len();
        routes.retain(|route| {
            route == "0.0.0.0/0"
                || !approved_subnets
                    .iter()
                    .any(|approved| ipv4_routes_overlap(route, approved))
        });
        if routes.len() != original_len {
            tx.execute(
                "UPDATE nodes SET approved_routes_json=?1 WHERE id=?2",
                params![serde_json::to_string(&routes).unwrap(), other_id],
            )?;
        }
    }
    tx.execute(
        "UPDATE nodes SET approved_routes_json=?1 WHERE id=?2 AND org_id=?3",
        params![
            serde_json::to_string(&approved).unwrap(),
            node_id.to_string(),
            org_id.to_string(),
        ],
    )?;
    append_audit(
        &tx,
        org_id,
        &session,
        "node.routes_updated",
        "node",
        Some(&node_id.to_string()),
        &serde_json::json!({"approved_routes": approved}),
    )?;
    tx.commit()?;
    info!(%node_id, %org_id, routes = approved.len(), "node routes approved");
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReauthNode {
    join_key: String,
}

#[derive(Deserialize, Serialize)]
struct ReauthResponse {
    node_token: String,
    credential_expires_at: i64,
}

async fn reauth_node(
    State(s): State<AppState>,
    UrlPath(node_id): UrlPath<Uuid>,
    headers: HeaderMap,
    Json(input): Json<ReauthNode>,
) -> Result<Json<ReauthResponse>, ApiError> {
    let old_token_hash = bearer(&headers)?;
    let mut db = s.store.0.lock().unwrap();
    let tx = db.transaction()?;
    let org_id: String = tx
        .query_row(
            "SELECT org_id FROM nodes WHERE id=?1 AND token_hash=?2 AND revoked_at IS NULL",
            params![node_id.to_string(), old_token_hash],
            |row| row.get(0),
        )
        .optional()?
        .ok_or(ApiError::Unauthorized)?;
    let join: Option<(String, bool, bool, String, String, String, i64)> = tx
        .query_row(
            "SELECT k.id,k.single_use,k.used_at IS NOT NULL,k.user_id,k.user_role,k.tags_json,o.node_key_ttl_seconds FROM join_keys k JOIN orgs o ON o.id=k.org_id WHERE k.key_hash=?1 AND k.org_id=?2 AND k.revoked_at IS NULL AND k.expires_at>?3 AND NOT EXISTS(SELECT 1 FROM device_authorizations d WHERE d.device_code_hash=k.key_hash)",
            params![hash(&input.join_key), org_id, now()],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?, row.get(5)?, row.get(6)?)),
        )
        .optional()?;
    let (join_id, single_use, used, user_id, user_role, tags_json, ttl) =
        join.ok_or(ApiError::Unauthorized)?;
    if single_use && used {
        return Err(ApiError::Unauthorized);
    }
    let node_token = secret("btn");
    let credential_expires_at = now() + ttl;
    tx.execute(
        "UPDATE nodes SET token_hash=?1,credential_expires_at=?2,user_id=?3,user_role=?4,tags_json=?5 WHERE id=?6",
        params![hash(&node_token), credential_expires_at, user_id, user_role, tags_json, node_id.to_string()],
    )?;
    if single_use {
        tx.execute(
            "UPDATE join_keys SET used_at=?1 WHERE id=?2",
            params![now(), join_id],
        )?;
    }
    tx.commit()?;
    info!(%node_id, "node credential renewed");
    Ok(Json(ReauthResponse {
        node_token,
        credential_expires_at,
    }))
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct Peer {
    id: Uuid,
    name: String,
    wg_public_key: String,
    endpoint: Option<String>,
    allowed_ips: Vec<String>,
    dns_name: String,
    tags: Vec<DeviceTag>,
    relay_endpoint: Option<String>,
}
#[derive(Serialize, Deserialize)]
struct PeersResponse {
    peers: Vec<Peer>,
    dns_name: String,
    credential_expires_at: i64,
    #[serde(default)]
    exit_node_active: bool,
    /// Advertised relay endpoints plus a refreshed capability token.
    #[serde(default)]
    relays: Vec<String>,
    #[serde(default)]
    relay_token: String,
    #[serde(default)]
    relay_expires_at: u64,
}

#[derive(Default, Deserialize)]
struct PeerSelection {
    #[serde(default)]
    exit_node: Option<String>,
}

async fn list_peers(
    State(s): State<AppState>,
    UrlPath(node_id): UrlPath<Uuid>,
    Query(selection): Query<PeerSelection>,
    headers: HeaderMap,
) -> Result<Json<PeersResponse>, ApiError> {
    let token = bearer(&headers)?;
    let db = s.store.0.lock().unwrap();
    let (org, source_role, source_tags, acl_json, credential_expires_at, dns_name): (String,String,String,String,i64,String) = db
        .query_row(
            "SELECT n.org_id,n.user_role,n.tags_json,o.acl_json,n.credential_expires_at,n.dns_name FROM nodes n JOIN orgs o ON o.id=n.org_id WHERE n.id=?1 AND n.token_hash=?2 AND n.revoked_at IS NULL",
            params![node_id.to_string(), token],
            |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?)),
        )
        .optional()?
        .ok_or(ApiError::Unauthorized)?;
    if credential_expires_at <= now() {
        return Err(ApiError::CredentialExpired);
    }
    let source = Subject {
        role: source_role
            .parse()
            .map_err(|_| ApiError::Database(rusqlite::Error::InvalidQuery))?,
        tags: serde_json::from_str(&source_tags).unwrap_or_default(),
    };
    let acl: Acl = serde_json::from_str(&acl_json)
        .map_err(|_| ApiError::Database(rusqlite::Error::InvalidQuery))?;
    let requested_exit = selection
        .exit_node
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty());
    let mut q=db.prepare("SELECT id,name,wg_public_key,endpoint,allowed_ips_json,dns_name,user_role,tags_json,CASE WHEN relay_endpoint_updated_at>?3 THEN relay_endpoint ELSE NULL END,approved_routes_json FROM nodes WHERE org_id=?1 AND id!=?2 AND revoked_at IS NULL AND credential_expires_at>?4 ORDER BY name")?;
    let candidates = q
        .query_map(
            params![
                org,
                node_id.to_string(),
                now() - RELAY_ENDPOINT_FRESH_SECS,
                now()
            ],
            |r| {
                let id: String = r.get(0)?;
                let ips: String = r.get(4)?;
                let tags: Vec<DeviceTag> =
                    serde_json::from_str(&r.get::<_, String>(7)?).unwrap_or_default();
                let approved: Vec<String> =
                    serde_json::from_str(&r.get::<_, String>(9)?).unwrap_or_default();
                Ok((
                    Peer {
                        id: Uuid::parse_str(&id).unwrap(),
                        name: r.get(1)?,
                        wg_public_key: r.get(2)?,
                        endpoint: r.get(3)?,
                        allowed_ips: serde_json::from_str(&ips).unwrap(),
                        dns_name: r.get(5)?,
                        tags: tags.clone(),
                        relay_endpoint: r.get(8)?,
                    },
                    Subject {
                        role: r.get::<_, String>(6)?.parse().unwrap(),
                        tags,
                    },
                    approved,
                ))
            },
        )?
        .collect::<Result<Vec<_>, _>>()?;
    let mut exit_node_active = false;
    let peers = candidates
        .into_iter()
        .filter_map(|(mut peer, destination, approved)| {
            if !acl.allows(&source, &destination) {
                return None;
            }
            let exit_matches = requested_exit.is_some_and(|requested| {
                requested == peer.id.to_string()
                    || requested == peer.name
                    || requested == peer.dns_name
            });
            for route in approved {
                if route == "0.0.0.0/0" {
                    if exit_matches {
                        peer.allowed_ips.push(route);
                        exit_node_active = true;
                    }
                } else {
                    peer.allowed_ips.push(route);
                }
            }
            Some(peer)
        })
        .collect();
    let (relay_token, relay_expires_at) = relay_credentials(&s, node_id);
    Ok(Json(PeersResponse {
        peers,
        dns_name,
        credential_expires_at,
        exit_node_active,
        relays: s.relays.as_ref().clone(),
        relay_token,
        relay_expires_at,
    }))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RelayEndpointUpdate {
    endpoint: String,
}

async fn update_relay_endpoint(
    State(s): State<AppState>,
    UrlPath(node_id): UrlPath<Uuid>,
    headers: HeaderMap,
    Json(input): Json<RelayEndpointUpdate>,
) -> Result<StatusCode, ApiError> {
    let endpoint: SocketAddr = input
        .endpoint
        .trim()
        .parse()
        .map_err(|_| ApiError::BadRequest("endpoint must be an IP socket address".into()))?;
    if endpoint.port() == 0 || endpoint.ip().is_unspecified() || endpoint.ip().is_multicast() {
        return Err(ApiError::BadRequest(
            "endpoint must use a unicast IP and non-zero port".into(),
        ));
    }
    let token = bearer(&headers)?;
    let db = s.store.0.lock().unwrap();
    let expires_at: i64 = db
        .query_row(
            "SELECT credential_expires_at FROM nodes WHERE id=?1 AND token_hash=?2 AND revoked_at IS NULL",
            params![node_id.to_string(), token],
            |row| row.get(0),
        )
        .optional()?
        .ok_or(ApiError::Unauthorized)?;
    if expires_at <= now() {
        return Err(ApiError::CredentialExpired);
    }
    db.execute(
        "UPDATE nodes SET relay_endpoint=?1,relay_endpoint_updated_at=?2 WHERE id=?3",
        params![endpoint.to_string(), now(), node_id.to_string()],
    )?;
    Ok(StatusCode::NO_CONTENT)
}

/// Capability token TTL for relay registration (7 days, refreshed each poll).
const RELAY_TOKEN_TTL_SECS: u64 = 604_800;
const RELAY_ENDPOINT_FRESH_SECS: i64 = 180;
fn relay_credentials(state: &AppState, node_id: Uuid) -> (String, u64) {
    if state.relays.is_empty() || state.relay_auth_secret.is_empty() {
        return (String::new(), 0);
    }
    let expires_at = (now() as u64) + RELAY_TOKEN_TTL_SECS;
    (
        relay_capability(&state.relay_auth_secret, node_id, expires_at),
        expires_at,
    )
}
/// HMAC-SHA256 capability binding a node id to an expiry, hex-encoded. Must
/// match blaktail-relay's REGISTER verification (id || expiry_be, big-endian).
fn relay_capability(secret: &[u8], node_id: Uuid, expires_at_unix: u64) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(secret).expect("hmac accepts any key length");
    mac.update(node_id.as_bytes());
    mac.update(&expires_at_unix.to_be_bytes());
    hex_encode(&mac.finalize().into_bytes())
}
fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
fn allocate_ip(tx: &rusqlite::Transaction<'_>, org_id: &str) -> Result<String, ApiError> {
    let mut used = std::collections::HashSet::new();
    let mut query = tx.prepare("SELECT allowed_ips_json FROM nodes WHERE org_id=?1")?;
    let rows = query.query_map([org_id], |row| row.get::<_, String>(0))?;
    for row in rows {
        for ip in serde_json::from_str::<Vec<String>>(&row?).unwrap_or_default() {
            used.insert(ip);
        }
    }
    (1..=254)
        .map(|host| format!("100.64.0.{host}/32"))
        .find(|ip| !used.contains(ip))
        .ok_or_else(|| ApiError::Conflict("tailnet address pool exhausted".into()))
}

fn validate_advertised_routes(routes: Vec<String>) -> Result<Vec<String>, ApiError> {
    if routes.len() > 32 {
        return Err(ApiError::BadRequest(
            "a node may advertise at most 32 routes".into(),
        ));
    }
    let mut canonical = routes
        .into_iter()
        .map(|route| canonical_ipv4_route(&route))
        .collect::<Result<Vec<_>, _>>()?;
    canonical.sort();
    canonical.dedup();
    for (index, route) in canonical.iter().enumerate() {
        if route != "0.0.0.0/0"
            && !["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
                .iter()
                .any(|private| ipv4_route_is_within(route, private))
        {
            return Err(ApiError::BadRequest(format!(
                "route {route} must be an RFC1918 private subnet or 0.0.0.0/0"
            )));
        }
        if route != "0.0.0.0/0" && ipv4_routes_overlap(route, "100.64.0.0/10") {
            return Err(ApiError::BadRequest(format!(
                "route {route} overlaps the BlakTail address pool"
            )));
        }
        if route != "0.0.0.0/0"
            && canonical[index + 1..]
                .iter()
                .any(|other| other != "0.0.0.0/0" && ipv4_routes_overlap(route, other))
        {
            return Err(ApiError::BadRequest(format!(
                "advertised route {route} overlaps another advertised route"
            )));
        }
    }
    Ok(canonical)
}

fn canonical_ipv4_route(route: &str) -> Result<String, ApiError> {
    let route = route.trim();
    let (address, prefix) = route
        .split_once('/')
        .ok_or_else(|| ApiError::BadRequest(format!("route {route} must use CIDR notation")))?;
    let address: Ipv4Addr = address
        .parse()
        .map_err(|_| ApiError::BadRequest(format!("route {route} must be IPv4 CIDR")))?;
    let prefix: u8 = prefix
        .parse()
        .ok()
        .filter(|prefix| *prefix <= 32)
        .ok_or_else(|| ApiError::BadRequest(format!("route {route} has an invalid prefix")))?;
    let mask = ipv4_mask(prefix);
    let raw = u32::from(address);
    if raw & !mask != 0 {
        return Err(ApiError::BadRequest(format!(
            "route {route} is not a network address"
        )));
    }
    if prefix != 0
        && (address.is_loopback()
            || address.is_link_local()
            || address.is_multicast()
            || address.is_broadcast())
    {
        return Err(ApiError::BadRequest(format!(
            "route {route} is not a routable network"
        )));
    }
    Ok(format!("{address}/{prefix}"))
}

fn ipv4_routes_overlap(left: &str, right: &str) -> bool {
    let parse = |route: &str| {
        let (address, prefix) = route.split_once('/').expect("validated CIDR");
        (
            u32::from(address.parse::<Ipv4Addr>().expect("validated IPv4")),
            prefix.parse::<u8>().expect("validated prefix"),
        )
    };
    let (left_address, left_prefix) = parse(left);
    let (right_address, right_prefix) = parse(right);
    let mask = ipv4_mask(left_prefix.min(right_prefix));
    left_address & mask == right_address & mask
}

fn ipv4_route_is_within(route: &str, container: &str) -> bool {
    let parse = |cidr: &str| {
        let (address, prefix) = cidr.split_once('/').expect("validated CIDR");
        (
            u32::from(address.parse::<Ipv4Addr>().expect("validated IPv4")),
            prefix.parse::<u8>().expect("validated prefix"),
        )
    };
    let (address, prefix) = parse(route);
    let (container_address, container_prefix) = parse(container);
    prefix >= container_prefix
        && address & ipv4_mask(container_prefix) == container_address & ipv4_mask(container_prefix)
}

fn ipv4_mask(prefix: u8) -> u32 {
    if prefix == 0 {
        0
    } else {
        u32::MAX << (32 - prefix)
    }
}
async fn revoke_node(
    State(s): State<AppState>,
    UrlPath(node_id): UrlPath<Uuid>,
    headers: HeaderMap,
) -> Result<StatusCode, ApiError> {
    let changed = s.store.0.lock().unwrap().execute(
        "UPDATE nodes SET revoked_at=?1 WHERE id=?2 AND token_hash=?3 AND revoked_at IS NULL",
        params![now(), node_id.to_string(), bearer(&headers)?],
    )?;
    if changed == 0 {
        return Err(ApiError::Unauthorized);
    }
    info!(%node_id,"node revoked");
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Serialize, Deserialize)]
struct NodeRow {
    id: Uuid,
    name: String,
    wg_public_key: String,
    endpoint: Option<String>,
    allowed_ips: Vec<String>,
    advertised_routes: Vec<String>,
    approved_routes: Vec<String>,
    dns_name: String,
    user_id: String,
    user_role: String,
    tags: Vec<DeviceTag>,
    created_at: i64,
    credential_expires_at: i64,
    expired: bool,
    expires_soon: bool,
    revoked: bool,
}

async fn list_nodes(
    State(s): State<AppState>,
    UrlPath(org_id): UrlPath<Uuid>,
    headers: HeaderMap,
) -> Result<Json<Vec<NodeRow>>, ApiError> {
    console_session(&s, &headers, org_id)?;
    let db = s.store.0.lock().unwrap();
    let mut query = db.prepare(
        "SELECT id,name,wg_public_key,endpoint,allowed_ips_json,dns_name,user_id,user_role,tags_json,created_at,credential_expires_at,credential_expires_at<=?2,credential_expires_at<=?3,revoked_at IS NOT NULL,advertised_routes_json,approved_routes_json FROM nodes WHERE org_id=?1 ORDER BY name",
    )?;
    let rows = query
        .query_map(
            params![org_id.to_string(), now(), now() + 14 * 24 * 60 * 60],
            |r| {
                let created_raw: String = r.get(9)?;
                Ok(NodeRow {
                    id: Uuid::parse_str(&r.get::<_, String>(0)?).unwrap(),
                    name: r.get(1)?,
                    wg_public_key: r.get(2)?,
                    endpoint: r.get(3)?,
                    allowed_ips: serde_json::from_str(&r.get::<_, String>(4)?).unwrap_or_default(),
                    advertised_routes: serde_json::from_str(&r.get::<_, String>(14)?)
                        .unwrap_or_default(),
                    approved_routes: serde_json::from_str(&r.get::<_, String>(15)?)
                        .unwrap_or_default(),
                    dns_name: r.get(5)?,
                    user_id: r.get(6)?,
                    user_role: r.get(7)?,
                    tags: serde_json::from_str(&r.get::<_, String>(8)?).unwrap_or_default(),
                    created_at: created_raw.parse::<i64>().unwrap_or(0),
                    credential_expires_at: r.get(10)?,
                    expired: r.get(11)?,
                    expires_soon: r.get(12)?,
                    revoked: r.get(13)?,
                })
            },
        )?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Json(rows))
}

async fn admin_revoke_node(
    State(s): State<AppState>,
    UrlPath((org_id, node_id)): UrlPath<(Uuid, Uuid)>,
    headers: HeaderMap,
) -> Result<StatusCode, ApiError> {
    let session = console_session(&s, &headers, org_id)?;
    if session.role == Role::Member {
        return Err(ApiError::Forbidden);
    }
    let mut db = s.store.0.lock().unwrap();
    let tx = db.transaction()?;
    let changed = tx.execute(
        "UPDATE nodes SET revoked_at=?1 WHERE id=?2 AND org_id=?3 AND revoked_at IS NULL",
        params![now(), node_id.to_string(), org_id.to_string()],
    )?;
    if changed == 0 {
        return Err(ApiError::NotFound);
    }
    append_audit(
        &tx,
        org_id,
        &session,
        "node.revoked",
        "node",
        Some(&node_id.to_string()),
        &serde_json::json!({}),
    )?;
    tx.commit()?;
    info!(%node_id, %org_id, "node revoked by console");
    Ok(StatusCode::NO_CONTENT)
}

async fn get_acl(
    State(s): State<AppState>,
    UrlPath(org_id): UrlPath<Uuid>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, ApiError> {
    console_session(&s, &headers, org_id)?;
    let acl: String = s
        .store
        .0
        .lock()
        .unwrap()
        .query_row(
            "SELECT acl_json FROM orgs WHERE id=?1",
            params![org_id.to_string()],
            |r| r.get(0),
        )
        .optional()?
        .ok_or(ApiError::NotFound)?;
    Ok(Json(serde_json::from_str(&acl).unwrap()))
}
async fn put_acl(
    State(s): State<AppState>,
    UrlPath(org_id): UrlPath<Uuid>,
    headers: HeaderMap,
    Json(value): Json<serde_json::Value>,
) -> Result<StatusCode, ApiError> {
    let session = console_session(&s, &headers, org_id)?;
    if session.role == Role::Member {
        return Err(ApiError::Forbidden);
    }
    let acl: Acl = serde_json::from_value(value.clone())
        .map_err(|e| ApiError::BadRequest(format!("invalid ACL: {e}")))?;
    acl.validate()?;
    let mut db = s.store.0.lock().unwrap();
    let tx = db.transaction()?;
    let changed = tx.execute(
        "UPDATE orgs SET acl_json=?1 WHERE id=?2",
        params![value.to_string(), org_id.to_string()],
    )?;
    if changed == 0 {
        return Err(ApiError::NotFound);
    }
    append_audit(
        &tx,
        org_id,
        &session,
        "acl.updated",
        "acl",
        Some(&org_id.to_string()),
        &serde_json::json!({
            "rule_count": acl.rules.len(),
            "sha256": hash(&value.to_string()),
        }),
    )?;
    tx.commit()?;
    Ok(StatusCode::NO_CONTENT)
}

async fn get_security_policy(
    State(s): State<AppState>,
    UrlPath(org_id): UrlPath<Uuid>,
    headers: HeaderMap,
) -> Result<Json<SecurityPolicy>, ApiError> {
    console_session(&s, &headers, org_id)?;
    let node_key_ttl_seconds = s
        .store
        .0
        .lock()
        .unwrap()
        .query_row(
            "SELECT node_key_ttl_seconds FROM orgs WHERE id=?1",
            params![org_id.to_string()],
            |row| row.get(0),
        )
        .optional()?
        .ok_or(ApiError::NotFound)?;
    Ok(Json(SecurityPolicy {
        node_key_ttl_seconds,
    }))
}

async fn put_security_policy(
    State(s): State<AppState>,
    UrlPath(org_id): UrlPath<Uuid>,
    headers: HeaderMap,
    Json(policy): Json<SecurityPolicy>,
) -> Result<StatusCode, ApiError> {
    let session = console_session(&s, &headers, org_id)?;
    if session.role == Role::Member {
        return Err(ApiError::Forbidden);
    }
    validate_node_key_ttl(policy.node_key_ttl_seconds)?;
    let mut db = s.store.0.lock().unwrap();
    let tx = db.transaction()?;
    let previous: Option<i64> = tx
        .query_row(
            "SELECT node_key_ttl_seconds FROM orgs WHERE id=?1",
            params![org_id.to_string()],
            |row| row.get(0),
        )
        .optional()?;
    let previous = previous.ok_or(ApiError::NotFound)?;
    let changed = tx.execute(
        "UPDATE orgs SET node_key_ttl_seconds=?1 WHERE id=?2",
        params![policy.node_key_ttl_seconds, org_id.to_string()],
    )?;
    if changed == 0 {
        return Err(ApiError::NotFound);
    }
    append_audit(
        &tx,
        org_id,
        &session,
        "security.updated",
        "security_policy",
        Some(&org_id.to_string()),
        &serde_json::json!({
            "node_key_ttl_seconds": policy.node_key_ttl_seconds,
            "previous_node_key_ttl_seconds": previous,
        }),
    )?;
    tx.commit()?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct AuditQuery {
    limit: Option<u16>,
}

#[derive(Deserialize, Serialize)]
struct AuditEvent {
    id: String,
    actor_user_id: String,
    actor_name: String,
    actor_email: String,
    actor_role: String,
    action: String,
    target_type: String,
    target_id: Option<String>,
    details: serde_json::Value,
    created_at: i64,
}

async fn list_audit_events(
    State(s): State<AppState>,
    UrlPath(org_id): UrlPath<Uuid>,
    headers: HeaderMap,
    Query(query): Query<AuditQuery>,
) -> Result<Json<Vec<AuditEvent>>, ApiError> {
    console_session(&s, &headers, org_id)?;
    let limit = i64::from(query.limit.unwrap_or(100).clamp(1, 200));
    let db = s.store.0.lock().unwrap();
    let mut statement = db.prepare(
        "SELECT id,actor_user_id,actor_name,actor_email,actor_role,action,target_type,target_id,details_json,created_at FROM audit_events WHERE org_id=?1 ORDER BY created_at DESC,id DESC LIMIT ?2",
    )?;
    let events = statement
        .query_map(params![org_id.to_string(), limit], |row| {
            let details_json: String = row.get(8)?;
            Ok(AuditEvent {
                id: row.get(0)?,
                actor_user_id: row.get(1)?,
                actor_name: row.get(2)?,
                actor_email: row.get(3)?,
                actor_role: row.get(4)?,
                action: row.get(5)?,
                target_type: row.get(6)?,
                target_id: row.get(7)?,
                details: serde_json::from_str(&details_json).unwrap_or_default(),
                created_at: row.get(9)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Json(events))
}

fn append_audit(
    db: &Connection,
    org_id: Uuid,
    session: &Session,
    action: &str,
    target_type: &str,
    target_id: Option<&str>,
    details: &serde_json::Value,
) -> Result<(), ApiError> {
    db.execute(
        "INSERT INTO audit_events(id,org_id,actor_user_id,actor_name,actor_email,actor_role,action,target_type,target_id,details_json,created_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
        params![
            Uuid::new_v4().to_string(),
            org_id.to_string(),
            session.user_id,
            session.name,
            session.email,
            session.role.as_str(),
            action,
            target_type,
            target_id,
            details.to_string(),
            now(),
        ],
    )?;
    Ok(())
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Session {
    #[serde(rename = "sub")]
    user_id: String,
    org_id: Uuid,
    role: Role,
    #[serde(default)]
    name: String,
    #[serde(default)]
    email: String,
    exp: i64,
}
fn console_session(
    state: &AppState,
    headers: &HeaderMap,
    org_id: Uuid,
) -> Result<Session, ApiError> {
    let token = bearer_value(headers)?;
    let (payload, signature) = token.split_once('.').ok_or(ApiError::Unauthorized)?;
    if signature.contains('.') {
        return Err(ApiError::Unauthorized);
    }
    let signature = URL_SAFE_NO_PAD
        .decode(signature)
        .map_err(|_| ApiError::Unauthorized)?;
    let mut mac = Hmac::<Sha256>::new_from_slice(&state.auth_hmac_secret)
        .map_err(|_| ApiError::Unauthorized)?;
    mac.update(payload.as_bytes());
    mac.verify_slice(&signature)
        .map_err(|_| ApiError::Unauthorized)?;
    let claims: Session = serde_json::from_slice(
        &URL_SAFE_NO_PAD
            .decode(payload)
            .map_err(|_| ApiError::Unauthorized)?,
    )
    .map_err(|_| ApiError::Unauthorized)?;
    if claims.exp <= now() || claims.org_id != org_id || claims.user_id.trim().is_empty() {
        return Err(ApiError::Unauthorized);
    }
    Ok(claims)
}

fn magic_dns_name(name: &str, org_id: &str) -> String {
    let prefix: String = org_id
        .chars()
        .filter(|character| character.is_ascii_hexdigit())
        .take(8)
        .collect();
    let prefix = if prefix.len() == 8 {
        prefix
    } else {
        hash(org_id)[..8].into()
    };
    format!("{}.{}.blaktail", dns_label(name), prefix)
}
fn dns_label(name: &str) -> String {
    let s: String = name
        .to_ascii_lowercase()
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' {
                c
            } else {
                '-'
            }
        })
        .collect();
    let truncated: String = s.trim_matches('-').chars().take(63).collect();
    let label = truncated.trim_matches('-');
    if label.is_empty() {
        "node".into()
    } else {
        label.into()
    }
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct Acl {
    #[serde(default)]
    rules: Vec<AclRule>,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct AclRule {
    action: Action,
    #[serde(default)]
    src_roles: Vec<Role>,
    #[serde(default)]
    src_tags: Vec<DeviceTag>,
    #[serde(default)]
    dst_roles: Vec<Role>,
    #[serde(default)]
    dst_tags: Vec<DeviceTag>,
}
#[derive(Clone, Copy, Debug, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
enum Action {
    Allow,
    Deny,
}
struct Subject {
    role: Role,
    tags: Vec<DeviceTag>,
}
impl Acl {
    fn validate(&self) -> Result<(), ApiError> {
        if self.rules.iter().any(|r| {
            r.src_roles.is_empty()
                && r.src_tags.is_empty()
                && r.dst_roles.is_empty()
                && r.dst_tags.is_empty()
        }) {
            return Err(ApiError::BadRequest(
                "ACL rules must select a source or destination".into(),
            ));
        }
        Ok(())
    }
    fn allows(&self, s: &Subject, d: &Subject) -> bool {
        let matching: Vec<_> = self
            .rules
            .iter()
            .filter(|r| {
                selector(&r.src_roles, &r.src_tags, s) && selector(&r.dst_roles, &r.dst_tags, d)
            })
            .collect();
        if matching.iter().any(|r| r.action == Action::Deny) {
            return false;
        }
        if matching.iter().any(|r| r.action == Action::Allow) {
            return true;
        }
        if s.tags.is_empty() && d.tags.is_empty() {
            return true;
        }
        s.tags.iter().any(|t| d.tags.contains(t))
    }
}
fn selector(roles: &[Role], tags: &[DeviceTag], s: &Subject) -> bool {
    (roles.is_empty() || roles.contains(&s.role))
        && (tags.is_empty() || tags.iter().any(|t| s.tags.contains(t)))
}
fn bearer(headers: &HeaderMap) -> Result<String, ApiError> {
    Ok(hash(bearer_value(headers)?))
}
fn bearer_value(headers: &HeaderMap) -> Result<&str, ApiError> {
    headers
        .get(AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .filter(|v| !v.is_empty())
        .ok_or(ApiError::Unauthorized)
}
fn now() -> i64 {
    Utc::now().timestamp()
}
fn hash(value: &str) -> String {
    format!("{:x}", Sha256::digest(value.as_bytes()))
}
fn secret(prefix: &str) -> String {
    let mut b = [0u8; 32];
    OsRng.fill_bytes(&mut b);
    format!("{prefix}_{}", URL_SAFE_NO_PAD.encode(b))
}

fn user_code() -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut random = [0u8; 8];
    OsRng.fill_bytes(&mut random);
    let characters: String = random
        .iter()
        .map(|byte| ALPHABET[*byte as usize % ALPHABET.len()] as char)
        .collect();
    format!("{}-{}", &characters[..4], &characters[4..])
}

fn normalise_user_code(value: &str) -> Option<String> {
    let code: String = value
        .chars()
        .filter(|character| character.is_ascii_alphanumeric())
        .map(|character| character.to_ascii_uppercase())
        .collect();
    (code.len() == 8).then_some(code)
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::{to_bytes, Body},
        http::{Method, Request},
    };
    use tower::ServiceExt;
    const TEST_SECRET: &[u8] = b"test-only-hmac-secret-at-least-32-bytes";
    const TEST_RELAY_SECRET: &[u8] = b"separate-test-relay-secret-32-bytes";

    #[test]
    fn relay_capability_matches_relay_protocol() {
        let node_id = Uuid::from_u128(0x00112233445566778899aabbccddeeff);
        let expires_at = 2_000_000_000;
        assert_eq!(
            relay_capability(TEST_RELAY_SECRET, node_id, expires_at),
            hex_encode(&blaktail_relay::mint_token(
                TEST_RELAY_SECRET,
                node_id.as_bytes(),
                expires_at,
            ))
        );
    }
    #[test]
    fn route_validation_rejects_host_bits_tailnet_and_overlap() {
        assert_eq!(
            validate_advertised_routes(vec![
                "10.2.0.0/16".into(),
                "0.0.0.0/0".into(),
                "10.2.0.0/16".into(),
            ])
            .unwrap(),
            vec!["0.0.0.0/0", "10.2.0.0/16"]
        );
        for invalid in [
            "10.2.0.1/16",
            "100.64.2.0/24",
            "128.0.0.0/1",
            "192.0.2.0/24",
            "224.0.0.0/4",
        ] {
            assert!(validate_advertised_routes(vec![invalid.into()]).is_err());
        }
        assert!(
            validate_advertised_routes(vec!["10.2.0.0/16".into(), "10.2.3.0/24".into(),]).is_err()
        );
    }
    fn signed_session(org_id: Uuid, user_id: &str, role: Role, exp: i64) -> String {
        let payload = URL_SAFE_NO_PAD.encode(
            serde_json::to_vec(&Session {
                user_id: user_id.into(),
                org_id,
                role,
                name: user_id.into(),
                email: format!("{user_id}@example.com"),
                exp,
            })
            .unwrap(),
        );
        let mut mac = Hmac::<Sha256>::new_from_slice(TEST_SECRET).unwrap();
        mac.update(payload.as_bytes());
        format!(
            "{payload}.{}",
            URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes())
        )
    }
    async fn call(
        r: &Router,
        m: Method,
        u: &str,
        b: serde_json::Value,
        t: Option<&str>,
    ) -> Response {
        let mut q = Request::builder()
            .method(m)
            .uri(u)
            .header("content-type", "application/json");
        if let Some(t) = t {
            q = q.header(AUTHORIZATION, format!("Bearer {t}"))
        }
        r.clone()
            .oneshot(q.body(Body::from(b.to_string())).unwrap())
            .await
            .unwrap()
    }
    async fn body<T: serde::de::DeserializeOwned>(r: Response) -> T {
        serde_json::from_slice(&to_bytes(r.into_body(), usize::MAX).await.unwrap()).unwrap()
    }

    async fn register_test_node(
        router: &Router,
        org_id: Uuid,
        session: &str,
        name: &str,
        public_key: &str,
        advertised_routes: &[&str],
    ) -> RegisterResponse {
        let key: JoinKeyResponse = body(
            call(
                router,
                Method::POST,
                &format!("/v1/orgs/{org_id}/join-keys"),
                serde_json::json!({"expires_in_seconds":60}),
                Some(session),
            )
            .await,
        )
        .await;
        let response = call(
            router,
            Method::POST,
            "/v1/nodes/register",
            serde_json::json!({
                "join_key":key.key,
                "name":name,
                "wg_public_key":public_key,
                "advertised_routes":advertised_routes,
            }),
            None,
        )
        .await;
        assert_eq!(response.status(), StatusCode::CREATED);
        body(response).await
    }

    #[tokio::test]
    async fn metrics_and_audit_cover_security_mutations() {
        let store = Store::memory().unwrap();
        let metrics = Arc::new(CoordMetrics::default());
        let router = app_with_relays_console_and_metrics(
            store.clone(),
            "ap-southeast-2".into(),
            TEST_SECRET,
            TEST_RELAY_SECRET,
            vec![],
            DEFAULT_CONSOLE_URL.into(),
            metrics.clone(),
        );
        let org: OrgResponse = body(
            call(
                &router,
                Method::POST,
                "/v1/orgs",
                serde_json::json!({"name":"observable-org"}),
                None,
            )
            .await,
        )
        .await;
        let owner = signed_session(org.id, "owner-1", Role::Owner, now() + 60);
        let node = register_test_node(
            &router,
            org.id,
            &owner,
            "router-one",
            "router-key",
            &["10.4.0.0/24"],
        )
        .await;

        assert_eq!(
            call(
                &router,
                Method::GET,
                &format!("/v1/nodes/{}/peers", node.id),
                serde_json::Value::Null,
                Some(&node.node_token),
            )
            .await
            .status(),
            StatusCode::OK
        );
        assert_eq!(
            call(
                &router,
                Method::PUT,
                &format!("/v1/orgs/{}/nodes/{}/routes", org.id, node.id),
                serde_json::json!({"approved_routes":["10.4.0.0/24"]}),
                Some(&owner),
            )
            .await
            .status(),
            StatusCode::NO_CONTENT
        );
        assert_eq!(
            call(
                &router,
                Method::PUT,
                &format!("/v1/orgs/{}/acl", org.id),
                serde_json::json!({"rules":[{"action":"allow","src_roles":["owner"]}]}),
                Some(&owner),
            )
            .await
            .status(),
            StatusCode::NO_CONTENT
        );
        assert_eq!(
            call(
                &router,
                Method::PUT,
                &format!("/v1/orgs/{}/security", org.id),
                serde_json::json!({"node_key_ttl_seconds":86400}),
                Some(&owner),
            )
            .await
            .status(),
            StatusCode::NO_CONTENT
        );
        assert_eq!(
            call(
                &router,
                Method::DELETE,
                &format!("/v1/orgs/{}/nodes/{}", org.id, node.id),
                serde_json::Value::Null,
                Some(&owner),
            )
            .await
            .status(),
            StatusCode::NO_CONTENT
        );

        let audit: Vec<AuditEvent> = body(
            call(
                &router,
                Method::GET,
                &format!("/v1/orgs/{}/audit", org.id),
                serde_json::Value::Null,
                Some(&owner),
            )
            .await,
        )
        .await;
        let actions = audit
            .iter()
            .map(|event| event.action.as_str())
            .collect::<Vec<_>>();
        for action in [
            "join_key.minted",
            "node.routes_updated",
            "acl.updated",
            "security.updated",
            "node.revoked",
        ] {
            assert!(actions.contains(&action), "missing audit action {action}");
        }
        assert!(audit
            .iter()
            .all(|event| event.actor_email == "owner-1@example.com"));
        assert!(!serde_json::to_string(&audit).unwrap().contains("btk_"));

        let metrics_response = metrics_app(store, metrics)
            .oneshot(
                Request::builder()
                    .uri("/metrics")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(metrics_response.status(), StatusCode::OK);
        let metrics_text = String::from_utf8(
            to_bytes(metrics_response.into_body(), usize::MAX)
                .await
                .unwrap()
                .to_vec(),
        )
        .unwrap();
        assert!(metrics_text.contains(
            "blaktail_coord_requests_total{operation=\"register\",result=\"success\"} 1"
        ));
        assert!(metrics_text
            .contains("blaktail_coord_requests_total{operation=\"peers\",result=\"success\"} 1"));
        assert!(metrics_text
            .contains("blaktail_coord_requests_total{operation=\"revoke\",result=\"success\"} 1"));
        assert!(metrics_text.contains("blaktail_coord_active_nodes 0"));
    }

    #[tokio::test]
    async fn only_approved_routes_are_distributed_and_exit_nodes_are_opt_in() {
        let store = Store::memory().unwrap();
        let router = app(store.clone(), "ap-southeast-2".into(), TEST_SECRET);
        let org: OrgResponse = body(
            call(
                &router,
                Method::POST,
                "/v1/orgs",
                serde_json::json!({"name":"routing-org"}),
                None,
            )
            .await,
        )
        .await;
        let owner = signed_session(org.id, "owner-1", Role::Owner, now() + 60);
        let member = signed_session(org.id, "member-1", Role::Member, now() + 60);
        let injection_key: JoinKeyResponse = body(
            call(
                &router,
                Method::POST,
                &format!("/v1/orgs/{}/join-keys", org.id),
                serde_json::json!({"expires_in_seconds":60}),
                Some(&owner),
            )
            .await,
        )
        .await;
        assert_eq!(
            call(
                &router,
                Method::POST,
                "/v1/nodes/register",
                serde_json::json!({
                    "join_key":injection_key.key,
                    "name":"address-injector",
                    "wg_public_key":"address-injector-key",
                    "allowed_ips":["10.0.0.1/32"],
                }),
                None,
            )
            .await
            .status(),
            StatusCode::BAD_REQUEST
        );
        let subnet_router = register_test_node(
            &router,
            org.id,
            &owner,
            "router-one",
            "router-key",
            &["10.1.0.0/24", "0.0.0.0/0"],
        )
        .await;
        let client =
            register_test_node(&router, org.id, &owner, "client-one", "client-key", &[]).await;

        let before: PeersResponse = body(
            call(
                &router,
                Method::GET,
                &format!("/v1/nodes/{}/peers", client.id),
                serde_json::Value::Null,
                Some(&client.node_token),
            )
            .await,
        )
        .await;
        assert_eq!(before.peers[0].allowed_ips, vec!["100.64.0.1/32"]);
        assert!(!before.exit_node_active);

        let nodes: Vec<NodeRow> = body(
            call(
                &router,
                Method::GET,
                &format!("/v1/orgs/{}/nodes", org.id),
                serde_json::Value::Null,
                Some(&owner),
            )
            .await,
        )
        .await;
        let listed_router = nodes
            .iter()
            .find(|node| node.id == subnet_router.id)
            .unwrap();
        assert_eq!(
            listed_router.advertised_routes,
            vec!["0.0.0.0/0", "10.1.0.0/24"]
        );
        assert!(listed_router.approved_routes.is_empty());

        let approval_path = format!("/v1/orgs/{}/nodes/{}/routes", org.id, subnet_router.id);
        assert_eq!(
            call(
                &router,
                Method::PUT,
                &approval_path,
                serde_json::json!({"approved_routes":["10.1.0.0/24"]}),
                Some(&member),
            )
            .await
            .status(),
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            call(
                &router,
                Method::PUT,
                &approval_path,
                serde_json::json!({"approved_routes":["10.1.0.0/24","0.0.0.0/0"]}),
                Some(&owner),
            )
            .await
            .status(),
            StatusCode::NO_CONTENT
        );

        let routed: PeersResponse = body(
            call(
                &router,
                Method::GET,
                &format!("/v1/nodes/{}/peers", client.id),
                serde_json::Value::Null,
                Some(&client.node_token),
            )
            .await,
        )
        .await;
        assert_eq!(
            routed.peers[0].allowed_ips,
            vec!["100.64.0.1/32", "10.1.0.0/24"]
        );
        assert!(!routed.exit_node_active);

        let exited: PeersResponse = body(
            call(
                &router,
                Method::GET,
                &format!("/v1/nodes/{}/peers?exit_node=router-one", client.id),
                serde_json::Value::Null,
                Some(&client.node_token),
            )
            .await,
        )
        .await;
        assert_eq!(
            exited.peers[0].allowed_ips,
            vec!["100.64.0.1/32", "0.0.0.0/0", "10.1.0.0/24"]
        );
        assert!(exited.exit_node_active);
        let missing_exit: PeersResponse = body(
            call(
                &router,
                Method::GET,
                &format!("/v1/nodes/{}/peers?exit_node=missing", client.id),
                serde_json::Value::Null,
                Some(&client.node_token),
            )
            .await,
        )
        .await;
        assert!(!missing_exit.exit_node_active);
        assert!(!missing_exit.peers[0]
            .allowed_ips
            .contains(&"0.0.0.0/0".into()));

        assert_eq!(
            call(
                &router,
                Method::PUT,
                &approval_path,
                serde_json::json!({"approved_routes":["10.2.0.0/24"]}),
                Some(&owner),
            )
            .await
            .status(),
            StatusCode::BAD_REQUEST
        );
        let overlapping = register_test_node(
            &router,
            org.id,
            &owner,
            "router-two",
            "router-key-two",
            &["10.1.0.0/25"],
        )
        .await;
        assert_eq!(
            call(
                &router,
                Method::PUT,
                &format!("/v1/orgs/{}/nodes/{}/routes", org.id, overlapping.id),
                serde_json::json!({"approved_routes":["10.1.0.0/25"]}),
                Some(&owner),
            )
            .await
            .status(),
            StatusCode::CONFLICT
        );

        assert_eq!(
            call(
                &router,
                Method::PUT,
                &approval_path,
                serde_json::json!({"approved_routes":["10.1.0.0/24"]}),
                Some(&owner),
            )
            .await
            .status(),
            StatusCode::NO_CONTENT
        );
        store
            .0
            .lock()
            .unwrap()
            .execute(
                "UPDATE nodes SET credential_expires_at=?1 WHERE id=?2",
                params![now() - 1, subnet_router.id.to_string()],
            )
            .unwrap();
        assert_eq!(
            call(
                &router,
                Method::PUT,
                &approval_path,
                serde_json::json!({"approved_routes":["10.1.0.0/24","0.0.0.0/0"]}),
                Some(&owner),
            )
            .await
            .status(),
            StatusCode::CONFLICT
        );
        assert_eq!(
            call(
                &router,
                Method::PUT,
                &format!("/v1/orgs/{}/nodes/{}/routes", org.id, overlapping.id),
                serde_json::json!({"approved_routes":["10.1.0.0/25"]}),
                Some(&owner),
            )
            .await
            .status(),
            StatusCode::NO_CONTENT
        );
        let expired_approvals: String = store
            .0
            .lock()
            .unwrap()
            .query_row(
                "SELECT approved_routes_json FROM nodes WHERE id=?1",
                [subnet_router.id.to_string()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(expired_approvals, "[]");
        store
            .0
            .lock()
            .unwrap()
            .execute(
                "UPDATE nodes SET credential_expires_at=?1 WHERE id=?2",
                params![now() + 60, subnet_router.id.to_string()],
            )
            .unwrap();

        assert_eq!(
            call(
                &router,
                Method::PUT,
                &format!("/v1/nodes/{}/routes", subnet_router.id),
                serde_json::json!({"advertised_routes":["10.2.0.0/24"]}),
                Some(&subnet_router.node_token),
            )
            .await
            .status(),
            StatusCode::NO_CONTENT
        );
        let after_update: Vec<NodeRow> = body(
            call(
                &router,
                Method::GET,
                &format!("/v1/orgs/{}/nodes", org.id),
                serde_json::Value::Null,
                Some(&owner),
            )
            .await,
        )
        .await;
        let listed_router = after_update
            .iter()
            .find(|node| node.id == subnet_router.id)
            .unwrap();
        assert_eq!(listed_router.advertised_routes, vec!["10.2.0.0/24"]);
        assert!(listed_router.approved_routes.is_empty());
    }

    #[tokio::test]
    async fn browser_enrollment_is_expiring_single_use_and_bound_to_device() {
        let store = Store::memory().unwrap();
        let r = app_with_relays_and_console(
            store.clone(),
            "ap-southeast-2".into(),
            TEST_SECRET,
            TEST_RELAY_SECRET,
            vec![],
            "https://console.example.org.au/".into(),
        );
        let org: OrgResponse = body(
            call(
                &r,
                Method::POST,
                "/v1/orgs",
                serde_json::json!({"name":"browser-org"}),
                None,
            )
            .await,
        )
        .await;
        let member = signed_session(org.id, "member-1", Role::Member, now() + 60);
        let owner = signed_session(org.id, "owner-1", Role::Owner, now() + 60);
        let existing_key: JoinKeyResponse = body(
            call(
                &r,
                Method::POST,
                &format!("/v1/orgs/{}/join-keys", org.id),
                serde_json::json!({"expires_in_seconds":60}),
                Some(&owner),
            )
            .await,
        )
        .await;
        let existing: RegisterResponse = body(
            call(
                &r,
                Method::POST,
                "/v1/nodes/register",
                serde_json::json!({
                    "join_key": existing_key.key,
                    "name": "existing-node",
                    "wg_public_key": "existing-public-key"
                }),
                None,
            )
            .await,
        )
        .await;
        let started_response = call(
            &r,
            Method::POST,
            "/v1/device-authorizations",
            serde_json::json!({"name":"ssh-node","wg_public_key":"browser-public-key"}),
            None,
        )
        .await;
        assert_eq!(started_response.status(), StatusCode::CREATED);
        let started: DeviceAuthorizationResponse = body(started_response).await;
        assert_eq!(
            started.verification_url,
            format!(
                "https://console.example.org.au/enroll?code={}",
                started.user_code
            )
        );
        assert_eq!(started.interval_seconds, DEVICE_AUTH_POLL_SECS);
        assert!(started.expires_at > now());

        assert_eq!(
            call(
                &r,
                Method::GET,
                &format!("/v1/device-authorizations/{}", started.device_code),
                serde_json::Value::Null,
                None,
            )
            .await
            .status(),
            StatusCode::ACCEPTED
        );
        let preview: DeviceAuthorizationPreview = body(
            call(
                &r,
                Method::GET,
                &format!(
                    "/v1/orgs/{}/device-authorizations/{}",
                    org.id, started.user_code
                ),
                serde_json::Value::Null,
                Some(&member),
            )
            .await,
        )
        .await;
        assert_eq!(preview.name, "ssh-node");
        assert_eq!(
            preview.public_key_fingerprint,
            &hash("browser-public-key")[..12]
        );
        assert!(!preview.approved);

        let approval: DeviceAuthorizationApproval = body(
            call(
                &r,
                Method::POST,
                &format!(
                    "/v1/orgs/{}/device-authorizations/{}",
                    org.id, started.user_code
                ),
                serde_json::json!({"tags":["office"]}),
                Some(&member),
            )
            .await,
        )
        .await;
        assert_eq!(approval.status, "approved");
        assert_eq!(approval.expires_at, started.expires_at);
        assert_eq!(
            call(
                &r,
                Method::POST,
                &format!("/v1/nodes/{}/reauth", existing.id),
                serde_json::json!({"join_key":started.device_code}),
                Some(&existing.node_token),
            )
            .await
            .status(),
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            call(
                &r,
                Method::GET,
                &format!("/v1/device-authorizations/{}", started.device_code),
                serde_json::Value::Null,
                None,
            )
            .await
            .status(),
            StatusCode::OK
        );

        let wrong_identity = call(
            &r,
            Method::POST,
            "/v1/nodes/register",
            serde_json::json!({
                "join_key": started.device_code,
                "name": "different-node",
                "wg_public_key": "browser-public-key"
            }),
            None,
        )
        .await;
        assert_eq!(wrong_identity.status(), StatusCode::BAD_REQUEST);
        let registered_response = call(
            &r,
            Method::POST,
            "/v1/nodes/register",
            serde_json::json!({
                "join_key": started.device_code,
                "name": "ssh-node",
                "wg_public_key": "browser-public-key"
            }),
            None,
        )
        .await;
        assert_eq!(registered_response.status(), StatusCode::CREATED);
        let registered: RegisterResponse = body(registered_response).await;
        assert_eq!(registered.assigned_ip, "100.64.0.2/32");
        assert_eq!(
            call(
                &r,
                Method::GET,
                &format!("/v1/device-authorizations/{}", started.device_code),
                serde_json::Value::Null,
                None,
            )
            .await
            .status(),
            StatusCode::GONE
        );
        assert_eq!(
            call(
                &r,
                Method::POST,
                "/v1/nodes/register",
                serde_json::json!({
                    "join_key": started.device_code,
                    "name": "ssh-node",
                    "wg_public_key": "browser-public-key"
                }),
                None,
            )
            .await
            .status(),
            StatusCode::UNAUTHORIZED
        );

        let db = store.0.lock().unwrap();
        let (role, tags): (String, String) = db
            .query_row(
                "SELECT user_role,tags_json FROM nodes WHERE id=?1",
                params![registered.id.to_string()],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(role, "member");
        assert_eq!(tags, "[]");
        let browser_audit = db
            .prepare("SELECT action FROM audit_events WHERE org_id=?1 ORDER BY action")
            .unwrap()
            .query_map(params![org.id.to_string()], |row| row.get::<_, String>(0))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert!(browser_audit.contains(&"device_authorization.approved".into()));
        assert!(browser_audit.contains(&"join_key.minted".into()));
        let raw_secrets: i64 = db
            .query_row(
                "SELECT COUNT(*) FROM device_authorizations d JOIN join_keys k ON k.key_hash=d.device_code_hash WHERE d.device_code_hash=?1 OR k.key_hash=?1",
                params![started.device_code],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(raw_secrets, 0);
    }

    #[tokio::test]
    async fn expired_browser_enrollment_cannot_be_polled_or_approved() {
        let store = Store::memory().unwrap();
        let r = app(store.clone(), "ap-southeast-2".into(), TEST_SECRET);
        let org: OrgResponse = body(
            call(
                &r,
                Method::POST,
                "/v1/orgs",
                serde_json::json!({"name":"expired-browser-org"}),
                None,
            )
            .await,
        )
        .await;
        let owner = signed_session(org.id, "owner-1", Role::Owner, now() + 60);
        let started: DeviceAuthorizationResponse = body(
            call(
                &r,
                Method::POST,
                "/v1/device-authorizations",
                serde_json::json!({"name":"late-node","wg_public_key":"late-key"}),
                None,
            )
            .await,
        )
        .await;
        store
            .0
            .lock()
            .unwrap()
            .execute(
                "UPDATE device_authorizations SET expires_at=?1 WHERE device_code_hash=?2",
                params![now() - 1, hash(&started.device_code)],
            )
            .unwrap();
        assert_eq!(
            call(
                &r,
                Method::GET,
                &format!("/v1/device-authorizations/{}", started.device_code),
                serde_json::Value::Null,
                None,
            )
            .await
            .status(),
            StatusCode::GONE
        );
        assert_eq!(
            call(
                &r,
                Method::POST,
                &format!(
                    "/v1/orgs/{}/device-authorizations/{}",
                    org.id, started.user_code
                ),
                serde_json::json!({}),
                Some(&owner),
            )
            .await
            .status(),
            StatusCode::GONE
        );
    }

    #[tokio::test]
    async fn two_nodes_and_revocation() {
        let store = Store::memory().unwrap();
        let r = app_with_relays(
            store.clone(),
            "ap-southeast-2".into(),
            TEST_SECRET,
            TEST_RELAY_SECRET,
            vec!["relay.example.org:3478".into()],
        );
        let o: OrgResponse = body(
            call(
                &r,
                Method::POST,
                "/v1/orgs",
                serde_json::json!({"name":"org"}),
                None,
            )
            .await,
        )
        .await;
        assert_eq!(o.node_key_ttl_seconds, DEFAULT_NODE_KEY_TTL_SECS);
        let token = signed_session(o.id, "owner-1", Role::Owner, now() + 60);
        let mut ns = vec![];
        for n in 1..=2 {
            let k: JoinKeyResponse = body(
                call(
                    &r,
                    Method::POST,
                    &format!("/v1/orgs/{}/join-keys", o.id),
                    serde_json::json!({"expires_in_seconds":60}),
                    Some(&token),
                )
                .await,
            )
            .await;
            let x=call(&r,Method::POST,"/v1/nodes/register",serde_json::json!({"join_key":k.key,"name":format!("node-{n}"),"wg_public_key":format!("key-{n}")}),None).await;
            assert_eq!(x.status(), StatusCode::CREATED);
            ns.push(body::<RegisterResponse>(x).await)
        }
        for node in &ns {
            assert!(node.credential_expires_at >= now() + DEFAULT_NODE_KEY_TTL_SECS - 1);
            assert!(node.dns_name.ends_with(".blaktail"));
            assert_eq!(node.relays, vec!["relay.example.org:3478"]);
            assert_eq!(
                node.relay_token,
                relay_capability(TEST_RELAY_SECRET, node.id, node.relay_expires_at)
            );
            assert_ne!(
                node.relay_token,
                relay_capability(TEST_SECRET, node.id, node.relay_expires_at)
            );
        }
        let collision_key: JoinKeyResponse = body(
            call(
                &r,
                Method::POST,
                &format!("/v1/orgs/{}/join-keys", o.id),
                serde_json::json!({"expires_in_seconds":60}),
                Some(&token),
            )
            .await,
        )
        .await;
        assert_eq!(
            call(
                &r,
                Method::POST,
                "/v1/nodes/register",
                serde_json::json!({
                    "join_key": collision_key.key,
                    "name": "node 1",
                    "wg_public_key": "distinct-key"
                }),
                None,
            )
            .await
            .status(),
            StatusCode::CONFLICT
        );
        assert_eq!(
            call(
                &r,
                Method::PUT,
                &format!("/v1/nodes/{}/relay-endpoint", ns[0].id),
                serde_json::json!({"endpoint":"198.51.100.1:40001"}),
                Some("wrong-node-token"),
            )
            .await
            .status(),
            StatusCode::UNAUTHORIZED
        );
        for endpoint in ["relay.example.org:3478", "0.0.0.0:3478", "224.0.0.1:3478"] {
            assert_eq!(
                call(
                    &r,
                    Method::PUT,
                    &format!("/v1/nodes/{}/relay-endpoint", ns[0].id),
                    serde_json::json!({"endpoint": endpoint}),
                    Some(&ns[0].node_token),
                )
                .await
                .status(),
                StatusCode::BAD_REQUEST
            );
        }
        for (index, node) in ns.iter().enumerate() {
            assert_eq!(
                call(
                    &r,
                    Method::PUT,
                    &format!("/v1/nodes/{}/relay-endpoint", node.id),
                    serde_json::json!({
                        "endpoint": format!("198.51.100.{}:{}", index + 1, 40_001 + index)
                    }),
                    Some(&node.node_token),
                )
                .await
                .status(),
                StatusCode::NO_CONTENT
            );
        }
        for (i, n) in ns.iter().enumerate() {
            let p: PeersResponse = body(
                call(
                    &r,
                    Method::GET,
                    &format!("/v1/nodes/{}/peers", n.id),
                    serde_json::Value::Null,
                    Some(&n.node_token),
                )
                .await,
            )
            .await;
            assert_eq!(p.peers[0].wg_public_key, format!("key-{}", 2 - i));
            assert_eq!(
                p.peers[0].allowed_ips,
                vec![format!("100.64.0.{}/32", 2 - i)]
            );
            assert_eq!(p.relays, vec!["relay.example.org:3478"]);
            assert_eq!(
                p.relay_token,
                relay_capability(TEST_RELAY_SECRET, n.id, p.relay_expires_at)
            );
            assert_eq!(
                p.peers[0].relay_endpoint,
                Some(format!("198.51.100.{}:{}", 2 - i, 40_002 - i))
            );
            assert_eq!(p.credential_expires_at, n.credential_expires_at);
            assert_eq!(p.dns_name, n.dns_name);
        }

        let policy: SecurityPolicy = body(
            call(
                &r,
                Method::GET,
                &format!("/v1/orgs/{}/security", o.id),
                serde_json::Value::Null,
                Some(&token),
            )
            .await,
        )
        .await;
        assert_eq!(policy.node_key_ttl_seconds, DEFAULT_NODE_KEY_TTL_SECS);
        assert_eq!(
            call(
                &r,
                Method::PUT,
                &format!("/v1/orgs/{}/security", o.id),
                serde_json::json!({"node_key_ttl_seconds": MIN_NODE_KEY_TTL_SECS}),
                Some(&token),
            )
            .await
            .status(),
            StatusCode::NO_CONTENT
        );

        store
            .0
            .lock()
            .unwrap()
            .execute(
                "UPDATE nodes SET credential_expires_at=?1 WHERE id=?2",
                params![now() - 1, ns[0].id.to_string()],
            )
            .unwrap();
        let expired = call(
            &r,
            Method::GET,
            &format!("/v1/nodes/{}/peers", ns[0].id),
            serde_json::Value::Null,
            Some(&ns[0].node_token),
        )
        .await;
        assert_eq!(expired.status(), StatusCode::UNAUTHORIZED);
        let expired_body: serde_json::Value = body(expired).await;
        assert!(expired_body["error"]
            .as_str()
            .unwrap()
            .contains("blaktaild reauth"));
        let peers_after_expiry: PeersResponse = body(
            call(
                &r,
                Method::GET,
                &format!("/v1/nodes/{}/peers", ns[1].id),
                serde_json::Value::Null,
                Some(&ns[1].node_token),
            )
            .await,
        )
        .await;
        assert!(peers_after_expiry.peers.is_empty());

        let renewal_key: JoinKeyResponse = body(
            call(
                &r,
                Method::POST,
                &format!("/v1/orgs/{}/join-keys", o.id),
                serde_json::json!({"expires_in_seconds":60}),
                Some(&token),
            )
            .await,
        )
        .await;
        let old_token = ns[0].node_token.clone();
        let renewed: ReauthResponse = body(
            call(
                &r,
                Method::POST,
                &format!("/v1/nodes/{}/reauth", ns[0].id),
                serde_json::json!({"join_key": renewal_key.key}),
                Some(&old_token),
            )
            .await,
        )
        .await;
        assert_ne!(renewed.node_token, old_token);
        assert!(renewed.credential_expires_at >= now() + MIN_NODE_KEY_TTL_SECS - 1);
        assert_eq!(
            call(
                &r,
                Method::GET,
                &format!("/v1/nodes/{}/peers", ns[0].id),
                serde_json::Value::Null,
                Some(&old_token),
            )
            .await
            .status(),
            StatusCode::UNAUTHORIZED
        );
        ns[0].node_token = renewed.node_token;
        ns[0].credential_expires_at = renewed.credential_expires_at;
        let peers_after_renewal: PeersResponse = body(
            call(
                &r,
                Method::GET,
                &format!("/v1/nodes/{}/peers", ns[1].id),
                serde_json::Value::Null,
                Some(&ns[1].node_token),
            )
            .await,
        )
        .await;
        assert_eq!(peers_after_renewal.peers[0].id, ns[0].id);
        let preserved_ip: String = store
            .0
            .lock()
            .unwrap()
            .query_row(
                "SELECT allowed_ips_json FROM nodes WHERE id=?1",
                params![ns[0].id.to_string()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            serde_json::from_str::<Vec<String>>(&preserved_ip).unwrap()[0],
            ns[0].assigned_ip
        );

        store
            .0
            .lock()
            .unwrap()
            .execute(
                "UPDATE nodes SET relay_endpoint_updated_at=?1 WHERE id=?2",
                params![now() - RELAY_ENDPOINT_FRESH_SECS - 1, ns[0].id.to_string()],
            )
            .unwrap();
        let stale: PeersResponse = body(
            call(
                &r,
                Method::GET,
                &format!("/v1/nodes/{}/peers", ns[1].id),
                serde_json::Value::Null,
                Some(&ns[1].node_token),
            )
            .await,
        )
        .await;
        assert_eq!(stale.peers[0].relay_endpoint, None);
        let n = &ns[1];
        assert_eq!(
            call(
                &r,
                Method::DELETE,
                &format!("/v1/nodes/{}", n.id),
                serde_json::Value::Null,
                Some(&n.node_token)
            )
            .await
            .status(),
            StatusCode::NO_CONTENT
        );
        let n = &ns[0];
        let p: PeersResponse = body(
            call(
                &r,
                Method::GET,
                &format!("/v1/nodes/{}/peers", n.id),
                serde_json::Value::Null,
                Some(&n.node_token),
            )
            .await,
        )
        .await;
        assert!(p.peers.is_empty())
    }
    #[tokio::test]
    async fn health_region() {
        let r = app(
            Store::memory().unwrap(),
            "ap-southeast-2".into(),
            TEST_SECRET,
        );
        let v: serde_json::Value =
            body(call(&r, Method::GET, "/health", serde_json::Value::Null, None).await).await;
        assert_eq!(
            v,
            serde_json::json!({"status":"ok","region":"ap-southeast-2"})
        )
    }

    #[test]
    fn role_and_tag_matrix_defaults_to_same_tag_only() {
        let acl = Acl::default();
        let roles = [Role::Owner, Role::Admin, Role::Member];
        let tags = [DeviceTag::Office, DeviceTag::Ranger, DeviceTag::Store];
        for source_role in roles {
            for source_tag in tags {
                for dest_role in roles {
                    for dest_tag in tags {
                        let source = Subject {
                            role: source_role,
                            tags: vec![source_tag],
                        };
                        let dest = Subject {
                            role: dest_role,
                            tags: vec![dest_tag],
                        };
                        assert_eq!(
                            acl.allows(&source, &dest),
                            source_tag == dest_tag,
                            "{source_role:?}/{source_tag:?} -> {dest_role:?}/{dest_tag:?}"
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn explicit_deny_wins_and_roles_can_allow_cross_tag() {
        let acl: Acl = serde_json::from_value(serde_json::json!({"rules":[
            {"action":"allow","src_roles":["owner","admin"],"dst_tags":["store"]},
            {"action":"deny","src_tags":["ranger"],"dst_tags":["store"]}
        ]}))
        .unwrap();
        let store = Subject {
            role: Role::Member,
            tags: vec![DeviceTag::Store],
        };
        assert!(acl.allows(
            &Subject {
                role: Role::Owner,
                tags: vec![DeviceTag::Office]
            },
            &store
        ));
        assert!(acl.allows(
            &Subject {
                role: Role::Admin,
                tags: vec![DeviceTag::Office]
            },
            &store
        ));
        assert!(!acl.allows(
            &Subject {
                role: Role::Owner,
                tags: vec![DeviceTag::Ranger]
            },
            &store
        ));
        assert!(!acl.allows(
            &Subject {
                role: Role::Member,
                tags: vec![DeviceTag::Office]
            },
            &store
        ));
    }

    #[tokio::test]
    async fn console_auth_fails_closed_for_missing_forged_and_expired_assertions() {
        let r = app(
            Store::memory().unwrap(),
            "ap-southeast-2".into(),
            TEST_SECRET,
        );
        let o: OrgResponse = body(
            call(
                &r,
                Method::POST,
                "/v1/orgs",
                serde_json::json!({"name":"auth-tests"}),
                None,
            )
            .await,
        )
        .await;
        let path = format!("/v1/orgs/{}/join-keys", o.id);
        assert_eq!(
            call(&r, Method::POST, &path, serde_json::json!({}), None)
                .await
                .status(),
            StatusCode::UNAUTHORIZED
        );
        let expired = signed_session(o.id, "owner-1", Role::Owner, now() - 1);
        assert_eq!(
            call(
                &r,
                Method::POST,
                &path,
                serde_json::json!({}),
                Some(&expired)
            )
            .await
            .status(),
            StatusCode::UNAUTHORIZED
        );
        let mut forged = signed_session(o.id, "owner-1", Role::Owner, now() + 60).into_bytes();
        let last = forged.len() - 1;
        forged[last] = if forged[last] == b'A' { b'B' } else { b'A' };
        let forged = String::from_utf8(forged).unwrap();
        assert_eq!(
            call(
                &r,
                Method::POST,
                &path,
                serde_json::json!({}),
                Some(&forged)
            )
            .await
            .status(),
            StatusCode::UNAUTHORIZED
        );
    }

    #[tokio::test]
    async fn member_cannot_mint_keys_or_edit_acl() {
        let store = Store::memory().unwrap();
        let r = app(store.clone(), "ap-southeast-2".into(), TEST_SECRET);
        let o: OrgResponse = body(
            call(
                &r,
                Method::POST,
                "/v1/orgs",
                serde_json::json!({"name":"roles"}),
                None,
            )
            .await,
        )
        .await;
        let token = signed_session(o.id, "member-1", Role::Member, now() + 60);
        for (method, path, value) in [
            (
                Method::POST,
                format!("/v1/orgs/{}/join-keys", o.id),
                serde_json::json!({}),
            ),
            (
                Method::PUT,
                format!("/v1/orgs/{}/acl", o.id),
                serde_json::json!({"rules":[]}),
            ),
            (
                Method::PUT,
                format!("/v1/orgs/{}/security", o.id),
                serde_json::json!({"node_key_ttl_seconds": MIN_NODE_KEY_TTL_SECS}),
            ),
            (
                Method::DELETE,
                format!("/v1/orgs/{}/nodes/{}", o.id, Uuid::new_v4()),
                serde_json::Value::Null,
            ),
        ] {
            assert_eq!(
                call(&r, method, &path, value, Some(&token)).await.status(),
                StatusCode::FORBIDDEN
            );
        }
    }

    #[tokio::test]
    async fn deny_rule_removes_matching_node_from_peer_response() {
        let store = Store::memory().unwrap();
        let r = app(store.clone(), "ap-southeast-2".into(), TEST_SECRET);
        let o: OrgResponse = body(
            call(
                &r,
                Method::POST,
                "/v1/orgs",
                serde_json::json!({"name":"filtered"}),
                None,
            )
            .await,
        )
        .await;
        let token = signed_session(o.id, "owner-1", Role::Owner, now() + 60);
        let mut nodes = vec![];
        for n in 1..=2 {
            let k: JoinKeyResponse = body(
                call(
                    &r,
                    Method::POST,
                    &format!("/v1/orgs/{}/join-keys", o.id),
                    serde_json::json!({"tags":["office"]}),
                    Some(&token),
                )
                .await,
            )
            .await;
            let response=call(&r,Method::POST,"/v1/nodes/register",serde_json::json!({"join_key":k.key,"name":format!("office-{n}"),"wg_public_key":format!("office-key-{n}")}),None).await;
            nodes.push(body::<RegisterResponse>(response).await);
        }
        assert_eq!(call(&r,Method::PUT,&format!("/v1/orgs/{}/acl",o.id),serde_json::json!({"rules":[{"action":"deny","src_tags":["office"],"dst_tags":["office"]}]}),Some(&token)).await.status(),StatusCode::NO_CONTENT);
        let peers: PeersResponse = body(
            call(
                &r,
                Method::GET,
                &format!("/v1/nodes/{}/peers", nodes[0].id),
                serde_json::Value::Null,
                Some(&nodes[0].node_token),
            )
            .await,
        )
        .await;
        assert!(peers.peers.is_empty());
    }

    #[tokio::test]
    async fn console_can_list_and_revoke_nodes() {
        let store = Store::memory().unwrap();
        let r = app(store.clone(), "ap-southeast-2".into(), TEST_SECRET);
        let o: OrgResponse = body(
            call(
                &r,
                Method::POST,
                "/v1/orgs",
                serde_json::json!({"name": "console-org"}),
                None,
            )
            .await,
        )
        .await;
        let token = signed_session(o.id, "owner-1", Role::Owner, now() + 60);
        let key: JoinKeyResponse = body(
            call(
                &r,
                Method::POST,
                &format!("/v1/orgs/{}/join-keys", o.id),
                serde_json::json!({}),
                Some(&token),
            )
            .await,
        )
        .await;
        let node: RegisterResponse = body(
            call(
                &r,
                Method::POST,
                "/v1/nodes/register",
                serde_json::json!({
                    "join_key": key.key,
                    "name": "laptop",
                    "wg_public_key": "wg-laptop"
                }),
                None,
            )
            .await,
        )
        .await;
        let listed: Vec<NodeRow> = body(
            call(
                &r,
                Method::GET,
                &format!("/v1/orgs/{}/nodes", o.id),
                serde_json::Value::Null,
                Some(&token),
            )
            .await,
        )
        .await;
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].name, "laptop");
        assert!(!listed[0].revoked);
        assert_eq!(
            call(
                &r,
                Method::DELETE,
                &format!("/v1/orgs/{}/nodes/{}", o.id, node.id),
                serde_json::Value::Null,
                Some(&token),
            )
            .await
            .status(),
            StatusCode::NO_CONTENT
        );
        let after: Vec<NodeRow> = body(
            call(
                &r,
                Method::GET,
                &format!("/v1/orgs/{}/nodes", o.id),
                serde_json::Value::Null,
                Some(&token),
            )
            .await,
        )
        .await;
        assert!(after[0].revoked);
        assert_eq!(
            call(
                &r,
                Method::DELETE,
                &format!("/v1/orgs/{}/nodes/{}", o.id, node.id),
                serde_json::Value::Null,
                None,
            )
            .await
            .status(),
            StatusCode::UNAUTHORIZED
        );
    }

    #[test]
    fn magic_dns_is_stable_and_safe() {
        assert_eq!(
            magic_dns_name("Alice's Laptop", "12345678-0000-0000-0000-000000000000"),
            "alice-s-laptop.12345678.blaktail"
        );
        assert_eq!(dns_label(&"a".repeat(100)).len(), 63);
        assert!(!dns_label(&format!("{}-suffix", "a".repeat(62))).ends_with('-'));
    }

    #[test]
    fn existing_database_gains_credential_expiry_without_losing_nodes() {
        let path =
            std::env::temp_dir().join(format!("blaktail-migration-{}.sqlite3", Uuid::new_v4()));
        let created_at = now() - 100;
        {
            let db = Connection::open(&path).unwrap();
            db.execute_batch(
                "CREATE TABLE orgs(id TEXT PRIMARY KEY,name TEXT NOT NULL UNIQUE,acl_json TEXT NOT NULL,created_at TEXT NOT NULL);
                 CREATE TABLE nodes(id TEXT PRIMARY KEY,org_id TEXT NOT NULL,name TEXT NOT NULL,wg_public_key TEXT NOT NULL,endpoint TEXT,allowed_ips_json TEXT NOT NULL,token_hash TEXT NOT NULL UNIQUE,created_at TEXT NOT NULL,revoked_at TEXT,UNIQUE(org_id,name),UNIQUE(org_id,wg_public_key));",
            )
            .unwrap();
            db.execute(
                "INSERT INTO orgs(id,name,acl_json,created_at) VALUES('org','Org','{\"rules\":[]}',?1)",
                params![created_at],
            )
            .unwrap();
            db.execute(
                "INSERT INTO nodes(id,org_id,name,wg_public_key,allowed_ips_json,token_hash,created_at) VALUES('node','org','Node','key','[\"100.64.0.1/32\"]','hash',?1)",
                params![created_at],
            )
            .unwrap();
            db.execute(
                "INSERT INTO nodes(id,org_id,name,wg_public_key,allowed_ips_json,token_hash,created_at) VALUES('node-2','org','Node@','key-2','[\"100.64.0.2/32\"]','hash-2',?1)",
                params![created_at + 1],
            )
            .unwrap();
        }
        let store = Store::open(&path).unwrap();
        let (ttl, expires): (i64, i64) = store
            .0
            .lock()
            .unwrap()
            .query_row(
                "SELECT o.node_key_ttl_seconds,n.credential_expires_at FROM orgs o JOIN nodes n ON n.org_id=o.id WHERE n.id='node'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(ttl, DEFAULT_NODE_KEY_TTL_SECS);
        assert_eq!(expires, created_at + DEFAULT_NODE_KEY_TTL_SECS);
        let dns_names = {
            let db = store.0.lock().unwrap();
            let mut query = db
                .prepare("SELECT dns_name FROM nodes ORDER BY id")
                .unwrap();
            let collected = query
                .query_map([], |row| row.get::<_, String>(0))
                .unwrap()
                .collect::<Result<Vec<_>, _>>()
                .unwrap();
            collected
        };
        assert_eq!(dns_names.len(), 2);
        assert!(dns_names.iter().all(|name| !name.is_empty()));
        assert_ne!(dns_names[0], dns_names[1]);
        drop(store);
        std::fs::remove_file(path).unwrap();
    }
}

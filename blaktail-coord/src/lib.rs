use axum::{
    extract::{Path as UrlPath, State},
    http::{header::AUTHORIZATION, HeaderMap, StatusCode},
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
    net::SocketAddr,
    path::Path,
    sync::{Arc, Mutex},
};
use thiserror::Error;
use tracing::info;
use uuid::Uuid;

const SCHEMA: &str = include_str!("../schema.sql");
const DEFAULT_NODE_KEY_TTL_SECS: i64 = 90 * 24 * 60 * 60;
const MIN_NODE_KEY_TTL_SECS: i64 = 24 * 60 * 60;
const MAX_NODE_KEY_TTL_SECS: i64 = 365 * 24 * 60 * 60;
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
    region: String,
    auth_hmac_secret: Arc<[u8]>,
    relay_auth_secret: Arc<[u8]>,
    /// Advertised relay endpoints (host:port, UDP) handed to nodes.
    relays: Arc<Vec<String>>,
}
pub fn app(store: Store, region: String, auth_hmac_secret: impl Into<Vec<u8>>) -> Router {
    app_with_relays(
        store,
        region,
        auth_hmac_secret,
        Vec::<u8>::new(),
        Vec::new(),
    )
}
pub fn app_with_relays(
    store: Store,
    region: String,
    auth_hmac_secret: impl Into<Vec<u8>>,
    relay_auth_secret: impl Into<Vec<u8>>,
    relays: Vec<String>,
) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/v1/orgs", post(create_org))
        .route("/v1/orgs/:org_id/join-keys", post(mint_join_key))
        .route("/v1/orgs/:org_id/nodes", get(list_nodes))
        .route("/v1/orgs/:org_id/nodes/:node_id", delete(admin_revoke_node))
        .route("/v1/orgs/:org_id/acl", get(get_acl))
        .route("/v1/orgs/:org_id/acl", put(put_acl))
        .route("/v1/orgs/:org_id/security", get(get_security_policy))
        .route("/v1/orgs/:org_id/security", put(put_security_policy))
        .route("/v1/nodes/register", post(register_node))
        .route("/v1/nodes/:node_id/reauth", post(reauth_node))
        .route("/v1/nodes/:node_id/peers", get(list_peers))
        .route(
            "/v1/nodes/:node_id/relay-endpoint",
            put(update_relay_endpoint),
        )
        .route("/v1/nodes/:node_id", delete(revoke_node))
        .with_state(AppState {
            store,
            region,
            auth_hmac_secret: auth_hmac_secret.into().into(),
            relay_auth_secret: relay_auth_secret.into().into(),
            relays: Arc::new(relays),
        })
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
    let changed=s.store.0.lock().unwrap().execute("INSERT INTO join_keys(id,org_id,key_hash,expires_at,single_use,created_at,user_id,user_role,tags_json) SELECT ?1,id,?2,?3,?4,?5,?6,?7,?8 FROM orgs WHERE id=?9",params![id.to_string(),hash(&key),expires_at,input.single_use,now(),session.user_id,session.role.as_str(),serde_json::to_string(&tags).unwrap(),org_id.to_string()])?;
    if changed == 0 {
        return Err(ApiError::NotFound);
    }
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
struct RegisterNode {
    join_key: String,
    name: String,
    wg_public_key: String,
    #[serde(default)]
    endpoint: Option<String>,
    #[serde(default)]
    allowed_ips: Vec<String>,
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
    if input.name.trim().is_empty()
        || input.wg_public_key.trim().is_empty()
        || input.allowed_ips.iter().any(|x| x.trim().is_empty())
    {
        return Err(ApiError::BadRequest(
            "name and wg_public_key are required".into(),
        ));
    }
    let mut db = s.store.0.lock().unwrap();
    let tx = db.transaction()?;
    let grant: Option<RegistrationGrant> = tx.query_row("SELECT k.id,k.org_id,k.single_use,k.used_at IS NOT NULL,k.user_id,k.user_role,k.tags_json,o.node_key_ttl_seconds FROM join_keys k JOIN orgs o ON o.id=k.org_id WHERE k.key_hash=?1 AND k.revoked_at IS NULL AND k.expires_at>?2",params![hash(&input.join_key),now()],|r|Ok(RegistrationGrant { key_id: r.get(0)?, org_id: r.get(1)?, single_use: r.get(2)?, used: r.get(3)?, user_id: r.get(4)?, user_role: r.get(5)?, tags_json: r.get(6)?, node_key_ttl: r.get(7)? })).optional()?;
    let grant = grant.ok_or(ApiError::Unauthorized)?;
    if grant.single_use && grant.used {
        return Err(ApiError::Unauthorized);
    }
    let id = Uuid::new_v4();
    let token = secret("btn");
    let allowed_ips = if input.allowed_ips.is_empty() {
        vec![allocate_ip(&tx, &grant.org_id)?]
    } else {
        input.allowed_ips
    };
    let assigned_ip = allowed_ips[0].clone();
    let dns_name = magic_dns_name(input.name.trim(), &grant.org_id);
    let registered_at = now();
    let credential_expires_at = registered_at + grant.node_key_ttl;
    tx.execute("INSERT INTO nodes(id,org_id,name,wg_public_key,endpoint,allowed_ips_json,token_hash,created_at,user_id,user_role,tags_json,dns_name,credential_expires_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)",params![id.to_string(),grant.org_id,input.name.trim(),input.wg_public_key.trim(),input.endpoint,serde_json::to_string(&allowed_ips).unwrap(),hash(&token),registered_at,grant.user_id,grant.user_role,grant.tags_json,dns_name,credential_expires_at]).map_err(conflict("node name, DNS name, public key, or address already exists in org"))?;
    if grant.single_use {
        tx.execute(
            "UPDATE join_keys SET used_at=?1 WHERE id=?2",
            params![now(), grant.key_id],
        )?;
    }
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
            "SELECT k.id,k.single_use,k.used_at IS NOT NULL,k.user_id,k.user_role,k.tags_json,o.node_key_ttl_seconds FROM join_keys k JOIN orgs o ON o.id=k.org_id WHERE k.key_hash=?1 AND k.org_id=?2 AND k.revoked_at IS NULL AND k.expires_at>?3",
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
    /// Advertised relay endpoints plus a refreshed capability token.
    #[serde(default)]
    relays: Vec<String>,
    #[serde(default)]
    relay_token: String,
    #[serde(default)]
    relay_expires_at: u64,
}
async fn list_peers(
    State(s): State<AppState>,
    UrlPath(node_id): UrlPath<Uuid>,
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
    let mut q=db.prepare("SELECT id,name,wg_public_key,endpoint,allowed_ips_json,dns_name,user_role,tags_json,CASE WHEN relay_endpoint_updated_at>?3 THEN relay_endpoint ELSE NULL END FROM nodes WHERE org_id=?1 AND id!=?2 AND revoked_at IS NULL AND credential_expires_at>?4 ORDER BY name")?;
    let peers = q
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
                ))
            },
        )?
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .filter_map(|(p, d)| acl.allows(&source, &d).then_some(p))
        .collect();
    let (relay_token, relay_expires_at) = relay_credentials(&s, node_id);
    Ok(Json(PeersResponse {
        peers,
        dns_name,
        credential_expires_at,
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
        "SELECT id,name,wg_public_key,endpoint,allowed_ips_json,dns_name,user_id,user_role,tags_json,created_at,credential_expires_at,credential_expires_at<=?2,credential_expires_at<=?3,revoked_at IS NOT NULL FROM nodes WHERE org_id=?1 ORDER BY name",
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
    let changed = s.store.0.lock().unwrap().execute(
        "UPDATE nodes SET revoked_at=?1 WHERE id=?2 AND org_id=?3 AND revoked_at IS NULL",
        params![now(), node_id.to_string(), org_id.to_string()],
    )?;
    if changed == 0 {
        return Err(ApiError::NotFound);
    }
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
    let changed = s.store.0.lock().unwrap().execute(
        "UPDATE orgs SET acl_json=?1 WHERE id=?2",
        params![value.to_string(), org_id.to_string()],
    )?;
    if changed == 0 {
        return Err(ApiError::NotFound);
    }
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
    let changed = s.store.0.lock().unwrap().execute(
        "UPDATE orgs SET node_key_ttl_seconds=?1 WHERE id=?2",
        params![policy.node_key_ttl_seconds, org_id.to_string()],
    )?;
    if changed == 0 {
        return Err(ApiError::NotFound);
    }
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Session {
    #[serde(rename = "sub")]
    user_id: String,
    org_id: Uuid,
    role: Role,
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
    fn signed_session(org_id: Uuid, user_id: &str, role: Role, exp: i64) -> String {
        let payload = URL_SAFE_NO_PAD.encode(
            serde_json::to_vec(&Session {
                user_id: user_id.into(),
                org_id,
                role,
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

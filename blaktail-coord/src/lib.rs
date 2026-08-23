use axum::{
    extract::{Path as UrlPath, State},
    http::{header::AUTHORIZATION, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{delete, get, post, put},
    Json, Router,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use chrono::Utc;
use rand::{rngs::OsRng, RngCore};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    path::Path,
    sync::{Arc, Mutex},
};
use thiserror::Error;
use tracing::info;
use uuid::Uuid;

const SCHEMA: &str = include_str!("../schema.sql");
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
        Ok(Self(Arc::new(Mutex::new(db))))
    }
    pub fn memory() -> Result<Self, rusqlite::Error> {
        Self::open(":memory:")
    }
    /// Imports a console-verified Better Auth session. The bearer token is only stored hashed.
    pub fn put_session(
        &self,
        token: &str,
        org_id: Uuid,
        user_id: &str,
        role: Role,
        expires_at: i64,
    ) -> Result<(), rusqlite::Error> {
        self.0.lock().unwrap().execute(
            "INSERT OR REPLACE INTO console_sessions(token_hash,org_id,user_id,role,expires_at) VALUES(?1,?2,?3,?4,?5)",
            params![hash(token), org_id.to_string(), user_id, role.as_str(), expires_at],
        )?;
        Ok(())
    }
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
}
pub fn app(store: Store, region: String) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/v1/orgs", post(create_org))
        .route("/v1/orgs/:org_id/join-keys", post(mint_join_key))
        .route("/v1/orgs/:org_id/nodes", get(list_nodes))
        .route("/v1/orgs/:org_id/nodes/:node_id", delete(admin_revoke_node))
        .route("/v1/orgs/:org_id/acl", get(get_acl))
        .route("/v1/orgs/:org_id/acl", put(put_acl))
        .route("/v1/console/sessions", post(import_console_session))
        .route("/v1/nodes/register", post(register_node))
        .route("/v1/nodes/:node_id/peers", get(list_peers))
        .route("/v1/nodes/:node_id", delete(revoke_node))
        .with_state(AppState { store, region })
}
#[derive(Debug, Error)]
enum ApiError {
    #[error("{0}")]
    BadRequest(String),
    #[error("authentication failed")]
    Unauthorized,
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
}
fn default_acl() -> serde_json::Value {
    serde_json::json!({"rules":[]})
}
#[derive(Serialize, Deserialize)]
struct OrgResponse {
    id: Uuid,
    name: String,
}
async fn create_org(
    State(s): State<AppState>,
    Json(input): Json<CreateOrg>,
) -> Result<(StatusCode, Json<OrgResponse>), ApiError> {
    let name = input.name.trim();
    if name.is_empty() {
        return Err(ApiError::BadRequest("org name must not be empty".into()));
    }
    let acl: Acl = serde_json::from_value(input.acl.clone())
        .map_err(|error| ApiError::BadRequest(format!("invalid ACL: {error}")))?;
    acl.validate()?;
    let id = Uuid::new_v4();
    s.store
        .0
        .lock()
        .unwrap()
        .execute(
            "INSERT INTO orgs(id,name,acl_json,created_at) VALUES(?1,?2,?3,?4)",
            params![id.to_string(), name, input.acl.to_string(), now()],
        )
        .map_err(conflict("org name already exists"))?;
    Ok((
        StatusCode::CREATED,
        Json(OrgResponse {
            id,
            name: name.into(),
        }),
    ))
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
    let session = console_session(&s.store, &headers, org_id)?;
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
    let row:Option<(String,String,bool,bool,String,String,String)>=tx.query_row("SELECT id,org_id,single_use,used_at IS NOT NULL,user_id,user_role,tags_json FROM join_keys WHERE key_hash=?1 AND revoked_at IS NULL AND expires_at>?2",params![hash(&input.join_key),now()],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?,r.get(6)?))).optional()?;
    let (key_id, org_id, single, use_done, user_id, user_role, tags_json) =
        row.ok_or(ApiError::Unauthorized)?;
    if single && use_done {
        return Err(ApiError::Unauthorized);
    }
    let id = Uuid::new_v4();
    let token = secret("btn");
    let allowed_ips = if input.allowed_ips.is_empty() {
        vec![allocate_ip(&tx, &org_id)?]
    } else {
        input.allowed_ips
    };
    let assigned_ip = allowed_ips[0].clone();
    let dns_name = magic_dns_name(input.name.trim(), &org_id);
    tx.execute("INSERT INTO nodes(id,org_id,name,wg_public_key,endpoint,allowed_ips_json,token_hash,created_at,user_id,user_role,tags_json,dns_name) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)",params![id.to_string(),org_id,input.name.trim(),input.wg_public_key.trim(),input.endpoint,serde_json::to_string(&allowed_ips).unwrap(),hash(&token),now(),user_id,user_role,tags_json,dns_name]).map_err(conflict("node name, public key, or address already exists in org"))?;
    if single {
        tx.execute(
            "UPDATE join_keys SET used_at=?1 WHERE id=?2",
            params![now(), key_id],
        )?;
    }
    tx.commit()?;
    info!(node_id=%id,org_id,"node registered");
    Ok((
        StatusCode::CREATED,
        Json(RegisterResponse {
            id,
            org_id: Uuid::parse_str(&org_id).unwrap(),
            node_token: token,
            assigned_ip,
        }),
    ))
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
}
#[derive(Serialize, Deserialize)]
struct PeersResponse {
    peers: Vec<Peer>,
}
async fn list_peers(
    State(s): State<AppState>,
    UrlPath(node_id): UrlPath<Uuid>,
    headers: HeaderMap,
) -> Result<Json<PeersResponse>, ApiError> {
    let token = bearer(&headers)?;
    let db = s.store.0.lock().unwrap();
    let (org, source_role, source_tags, acl_json): (String,String,String,String) = db
        .query_row(
            "SELECT n.org_id,n.user_role,n.tags_json,o.acl_json FROM nodes n JOIN orgs o ON o.id=n.org_id WHERE n.id=?1 AND n.token_hash=?2 AND n.revoked_at IS NULL",
            params![node_id.to_string(), token],
            |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?)),
        )
        .optional()?
        .ok_or(ApiError::Unauthorized)?;
    let source = Subject {
        role: source_role
            .parse()
            .map_err(|_| ApiError::Database(rusqlite::Error::InvalidQuery))?,
        tags: serde_json::from_str(&source_tags).unwrap_or_default(),
    };
    let acl: Acl = serde_json::from_str(&acl_json)
        .map_err(|_| ApiError::Database(rusqlite::Error::InvalidQuery))?;
    let mut q=db.prepare("SELECT id,name,wg_public_key,endpoint,allowed_ips_json,dns_name,user_role,tags_json FROM nodes WHERE org_id=?1 AND id!=?2 AND revoked_at IS NULL ORDER BY name")?;
    let peers = q
        .query_map(params![org, node_id.to_string()], |r| {
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
                },
                Subject {
                    role: r.get::<_, String>(6)?.parse().unwrap(),
                    tags,
                },
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .filter_map(|(p, d)| acl.allows(&source, &d).then_some(p))
        .collect();
    Ok(Json(PeersResponse { peers }))
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
    revoked: bool,
}

async fn list_nodes(
    State(s): State<AppState>,
    UrlPath(org_id): UrlPath<Uuid>,
    headers: HeaderMap,
) -> Result<Json<Vec<NodeRow>>, ApiError> {
    console_session(&s.store, &headers, org_id)?;
    let db = s.store.0.lock().unwrap();
    let mut query = db.prepare(
        "SELECT id,name,wg_public_key,endpoint,allowed_ips_json,dns_name,user_id,user_role,tags_json,created_at,revoked_at IS NOT NULL FROM nodes WHERE org_id=?1 ORDER BY name",
    )?;
    let rows = query
        .query_map(params![org_id.to_string()], |r| {
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
                revoked: r.get(10)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Json(rows))
}

async fn admin_revoke_node(
    State(s): State<AppState>,
    UrlPath((org_id, node_id)): UrlPath<(Uuid, Uuid)>,
    headers: HeaderMap,
) -> Result<StatusCode, ApiError> {
    let session = console_session(&s.store, &headers, org_id)?;
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

#[derive(Deserialize)]
struct ImportSession {
    token: String,
    org_id: Uuid,
    user_id: String,
    role: Role,
    expires_at: i64,
}

async fn import_console_session(
    State(s): State<AppState>,
    headers: HeaderMap,
    Json(input): Json<ImportSession>,
) -> Result<StatusCode, ApiError> {
    require_console_sync_secret(&headers)?;
    if input.token.is_empty() || input.user_id.trim().is_empty() {
        return Err(ApiError::BadRequest(
            "token and user_id must not be empty".into(),
        ));
    }
    if input.expires_at <= now() {
        return Err(ApiError::BadRequest("expires_at must be in the future".into()));
    }
    let exists: bool = s
        .store
        .0
        .lock()
        .unwrap()
        .query_row(
            "SELECT 1 FROM orgs WHERE id=?1",
            params![input.org_id.to_string()],
            |_| Ok(true),
        )
        .optional()?
        .unwrap_or(false);
    if !exists {
        return Err(ApiError::NotFound);
    }
    s.store.put_session(
        &input.token,
        input.org_id,
        input.user_id.trim(),
        input.role,
        input.expires_at,
    )?;
    Ok(StatusCode::NO_CONTENT)
}

fn require_console_sync_secret(headers: &HeaderMap) -> Result<(), ApiError> {
    let expected = std::env::var("BLAKTAIL_CONSOLE_SYNC_SECRET").unwrap_or_default();
    if expected.is_empty() {
        return Err(ApiError::Unauthorized);
    }
    let provided = headers
        .get("x-blaktail-console-secret")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    if provided.is_empty() || provided.as_bytes() != expected.as_bytes() {
        return Err(ApiError::Unauthorized);
    }
    Ok(())
}
async fn get_acl(
    State(s): State<AppState>,
    UrlPath(org_id): UrlPath<Uuid>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, ApiError> {
    console_session(&s.store, &headers, org_id)?;
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
    let session = console_session(&s.store, &headers, org_id)?;
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

struct Session {
    user_id: String,
    role: Role,
}
fn console_session(store: &Store, headers: &HeaderMap, org_id: Uuid) -> Result<Session, ApiError> {
    let token = bearer(headers)?;
    let db = store.0.lock().unwrap();
    let row:Option<(String,String)>=db.query_row("SELECT user_id,role FROM console_sessions WHERE token_hash=?1 AND org_id=?2 AND expires_at>?3",params![token,org_id.to_string(),now()],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
    let (user_id, role) = row.ok_or(ApiError::Unauthorized)?;
    Ok(Session {
        user_id,
        role: role.parse().map_err(|_| ApiError::Unauthorized)?,
    })
}

fn magic_dns_name(name: &str, org_id: &str) -> String {
    format!("{}.{}.blaktail", dns_label(name), &org_id[..8])
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
    let label = s.trim_matches('-');
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
    let v = headers
        .get(AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .filter(|v| !v.is_empty())
        .ok_or(ApiError::Unauthorized)?;
    Ok(hash(v))
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
        let r = app(store.clone(), "ap-southeast-2".into());
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
        store
            .put_session("owner-session", o.id, "owner-1", Role::Owner, now() + 60)
            .unwrap();
        let mut ns = vec![];
        for n in 1..=2 {
            let k: JoinKeyResponse = body(
                call(
                    &r,
                    Method::POST,
                    &format!("/v1/orgs/{}/join-keys", o.id),
                    serde_json::json!({"expires_in_seconds":60}),
                    Some("owner-session"),
                )
                .await,
            )
            .await;
            let x=call(&r,Method::POST,"/v1/nodes/register",serde_json::json!({"join_key":k.key,"name":format!("node-{n}"),"wg_public_key":format!("key-{n}")}),None).await;
            assert_eq!(x.status(), StatusCode::CREATED);
            ns.push(body::<RegisterResponse>(x).await)
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
            )
        }
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
        let r = app(Store::memory().unwrap(), "ap-southeast-2".into());
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
    async fn member_cannot_mint_keys_or_edit_acl() {
        let store = Store::memory().unwrap();
        let r = app(store.clone(), "ap-southeast-2".into());
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
        store
            .put_session("member-session", o.id, "member-1", Role::Member, now() + 60)
            .unwrap();
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
        ] {
            assert_eq!(
                call(&r, method, &path, value, Some("member-session"))
                    .await
                    .status(),
                StatusCode::FORBIDDEN
            );
        }
    }

    #[tokio::test]
    async fn deny_rule_removes_matching_node_from_peer_response() {
        let store = Store::memory().unwrap();
        let r = app(store.clone(), "ap-southeast-2".into());
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
        store
            .put_session("owner", o.id, "owner-1", Role::Owner, now() + 60)
            .unwrap();
        let mut nodes = vec![];
        for n in 1..=2 {
            let k: JoinKeyResponse = body(
                call(
                    &r,
                    Method::POST,
                    &format!("/v1/orgs/{}/join-keys", o.id),
                    serde_json::json!({"tags":["office"]}),
                    Some("owner"),
                )
                .await,
            )
            .await;
            let response=call(&r,Method::POST,"/v1/nodes/register",serde_json::json!({"join_key":k.key,"name":format!("office-{n}"),"wg_public_key":format!("office-key-{n}")}),None).await;
            nodes.push(body::<RegisterResponse>(response).await);
        }
        assert_eq!(call(&r,Method::PUT,&format!("/v1/orgs/{}/acl",o.id),serde_json::json!({"rules":[{"action":"deny","src_tags":["office"],"dst_tags":["office"]}]}),Some("owner")).await.status(),StatusCode::NO_CONTENT);
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
        let r = app(store.clone(), "ap-southeast-2".into());
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
        store
            .put_session("owner-session", o.id, "owner-1", Role::Owner, now() + 60)
            .unwrap();
        let key: JoinKeyResponse = body(
            call(
                &r,
                Method::POST,
                &format!("/v1/orgs/{}/join-keys", o.id),
                serde_json::json!({}),
                Some("owner-session"),
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
                Some("owner-session"),
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
                Some("owner-session"),
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
                Some("owner-session"),
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
    }
}

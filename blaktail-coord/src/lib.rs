use axum::{
    extract::{Path as UrlPath, State},
    http::{header::AUTHORIZATION, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{delete, get, post},
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
        Ok(Self(Arc::new(Mutex::new(db))))
    }
    pub fn memory() -> Result<Self, rusqlite::Error> {
        Self::open(":memory:")
    }
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
        .route("/v1/orgs/:org_id/acl", get(get_acl))
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
    if !input.acl.is_object() {
        return Err(ApiError::BadRequest("acl must be a JSON object".into()));
    }
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
    Json(input): Json<MintJoinKey>,
) -> Result<(StatusCode, Json<JoinKeyResponse>), ApiError> {
    if !(1..=2_592_000).contains(&input.expires_in_seconds) {
        return Err(ApiError::BadRequest(
            "expires_in_seconds must be between 1 and 2592000".into(),
        ));
    }
    let key = secret("btk");
    let id = Uuid::new_v4();
    let expires_at = now() + input.expires_in_seconds;
    let changed=s.store.0.lock().unwrap().execute("INSERT INTO join_keys(id,org_id,key_hash,expires_at,single_use,created_at) SELECT ?1,id,?2,?3,?4,?5 FROM orgs WHERE id=?6",params![id.to_string(),hash(&key),expires_at,input.single_use,now(),org_id.to_string()])?;
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
    allowed_ips: Vec<String>,
}
#[derive(Serialize, Deserialize)]
struct RegisterResponse {
    id: Uuid,
    org_id: Uuid,
    node_token: String,
}
async fn register_node(
    State(s): State<AppState>,
    Json(input): Json<RegisterNode>,
) -> Result<(StatusCode, Json<RegisterResponse>), ApiError> {
    if input.name.trim().is_empty()
        || input.wg_public_key.trim().is_empty()
        || input.allowed_ips.is_empty()
        || input.allowed_ips.iter().any(|x| x.trim().is_empty())
    {
        return Err(ApiError::BadRequest(
            "name, wg_public_key and allowed_ips are required".into(),
        ));
    }
    let mut db = s.store.0.lock().unwrap();
    let tx = db.transaction()?;
    let row:Option<(String,String,bool,bool)>=tx.query_row("SELECT id,org_id,single_use,used_at IS NOT NULL FROM join_keys WHERE key_hash=?1 AND revoked_at IS NULL AND expires_at>?2",params![hash(&input.join_key),now()],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional()?;
    let (key_id, org_id, single, use_done) = row.ok_or(ApiError::Unauthorized)?;
    if single && use_done {
        return Err(ApiError::Unauthorized);
    }
    let id = Uuid::new_v4();
    let token = secret("btn");
    tx.execute("INSERT INTO nodes(id,org_id,name,wg_public_key,allowed_ips_json,token_hash,created_at) VALUES(?1,?2,?3,?4,?5,?6,?7)",params![id.to_string(),org_id,input.name.trim(),input.wg_public_key.trim(),serde_json::to_string(&input.allowed_ips).unwrap(),hash(&token),now()]).map_err(conflict("node name or public key already exists in org"))?;
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
        }),
    ))
}

#[derive(Serialize, Deserialize, Debug, PartialEq)]
struct Peer {
    id: Uuid,
    name: String,
    wg_public_key: String,
    allowed_ips: Vec<String>,
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
    let org: String = db
        .query_row(
            "SELECT org_id FROM nodes WHERE id=?1 AND token_hash=?2 AND revoked_at IS NULL",
            params![node_id.to_string(), token],
            |r| r.get(0),
        )
        .optional()?
        .ok_or(ApiError::Unauthorized)?;
    let mut q=db.prepare("SELECT id,name,wg_public_key,allowed_ips_json FROM nodes WHERE org_id=?1 AND id!=?2 AND revoked_at IS NULL ORDER BY name")?;
    let peers = q
        .query_map(params![org, node_id.to_string()], |r| {
            let id: String = r.get(0)?;
            let ips: String = r.get(3)?;
            Ok(Peer {
                id: Uuid::parse_str(&id).unwrap(),
                name: r.get(1)?,
                wg_public_key: r.get(2)?,
                allowed_ips: serde_json::from_str(&ips).unwrap(),
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Json(PeersResponse { peers }))
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
async fn get_acl(
    State(s): State<AppState>,
    UrlPath(org_id): UrlPath<Uuid>,
) -> Result<Json<serde_json::Value>, ApiError> {
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
        let r = app(Store::memory().unwrap(), "ap-southeast-2".into());
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
        let mut ns = vec![];
        for n in 1..=2 {
            let k: JoinKeyResponse = body(
                call(
                    &r,
                    Method::POST,
                    &format!("/v1/orgs/{}/join-keys", o.id),
                    serde_json::json!({"expires_in_seconds":60}),
                    None,
                )
                .await,
            )
            .await;
            let x=call(&r,Method::POST,"/v1/nodes/register",serde_json::json!({"join_key":k.key,"name":format!("node-{n}"),"wg_public_key":format!("key-{n}"),"allowed_ips":[format!("100.64.0.{n}/32")]}),None).await;
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
}

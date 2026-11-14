use base64::Engine;
use clap::Parser;
use ssh_key::sha2::Digest;
use ssh_key::{Fingerprint, PublicKey, SshSig};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};
use uuid::Uuid;
use warp::http::StatusCode;
use warp::{Filter, Reply};

use crate::files_manager::FileManager;

mod files_manager;

const MAX_UPLOAD_BYTES: u64 = 100 * 1024 * 1024;
const MAX_SKEW_SECS: u64 = 60;
const SIGNATURE_NAMESPACE: &str = "cdn-upload";
const AUTH_HEADERS: [&str; 4] = ["x-timestamp", "x-nonce", "x-content-sha256", "x-signature"];

#[derive(Parser, Debug)]
#[command(name = "tiny-cdn", about = "Signed-upload file CDN.")]
struct Args {
    #[arg(short, help = "Path to the SSH public key that authorizes uploads")]
    public_key: String,

    #[arg(
        short,
        help = "Directory to store uploaded files",
        default_value = "./files"
    )]
    storage_dir: String,

    #[arg(long, help = "Address to bind", default_value = "127.0.0.1")]
    bind: std::net::Ipv4Addr,

    #[arg(long, help = "Port to listen on", default_value_t = 3030)]
    port: u16,
}

#[derive(Debug)]
struct AuthError(String);

impl AuthError {
    fn new(e: impl std::fmt::Display) -> Self {
        Self(e.to_string())
    }
}

impl warp::reject::Reject for AuthError {}

#[derive(Debug)]
struct StoreError;

impl warp::reject::Reject for StoreError {}

/// Raised by the catch-all route. warp's own not-found rejection is hidden inside the
/// combined rejection of an `or` chain, so it cannot be told apart from a method mismatch.
#[derive(Debug)]
struct RouteNotFound;

impl warp::reject::Reject for RouteNotFound {}

fn seen_nonces() -> &'static Mutex<HashMap<String, u64>> {
    static SEEN_NONCES: OnceLock<Mutex<HashMap<String, u64>>> = OnceLock::new();
    SEEN_NONCES.get_or_init(|| Mutex::new(HashMap::new()))
}

fn body_sha256(body: &bytes::Bytes) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";

    let digest = ssh_key::sha2::Sha256::digest(body);
    let mut hex = String::with_capacity(digest.len() * 2);
    for byte in digest {
        hex.push(HEX[usize::from(byte >> 4)] as char);
        hex.push(HEX[usize::from(byte & 0x0f)] as char);
    }
    hex
}

/// The bytes a client signs. Changing this breaks every client, so it is pinned by a test.
fn canonical_message(
    method: &str,
    path: &str,
    ts: u64,
    nonce: &str,
    content_sha256: &str,
    expire_secs: Option<u64>,
) -> String {
    let expire = expire_secs
        .map(|secs| secs.to_string())
        .unwrap_or_else(|| "-".to_string());
    format!("{method}\n{path}\n{ts}\n{nonce}\n{content_sha256}\n{expire}")
}

/// The parts of a request that the signature covers.
struct SignatureRequest<'a> {
    method: &'a str,
    path: &'a str,
    ts: u64,
    nonce: &'a str,
    content_sha256: &'a str,
    expire_secs: Option<u64>,
    signature_b64: &'a str,
}

/// What a verified request signature proves about its sender.
struct Signed {
    uploader: Fingerprint,
    content_sha256: String,
    expire_secs: Option<u64>,
}

fn verify_signature(
    public_key: &PublicKey,
    request: &SignatureRequest,
) -> Result<Fingerprint, warp::Rejection> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| warp::reject::custom(AuthError::new(e)))?
        .as_secs();
    if now.abs_diff(request.ts) > MAX_SKEW_SECS {
        return Err(warp::reject::custom(AuthError::new(
            "X-Timestamp outside the allowed window",
        )));
    }

    let message = canonical_message(
        request.method,
        request.path,
        request.ts,
        request.nonce,
        request.content_sha256,
        request.expire_secs,
    );
    let pem = base64::engine::general_purpose::STANDARD
        .decode(request.signature_b64)
        .map_err(|e| warp::reject::custom(AuthError::new(e)))?;
    let signature = SshSig::from_pem(&pem).map_err(|e| warp::reject::custom(AuthError::new(e)))?;

    public_key
        .verify(SIGNATURE_NAMESPACE, message.as_bytes(), &signature)
        .map_err(|e| warp::reject::custom(AuthError::new(e)))?;

    // Recorded only after the signature checks out, so unsigned requests can't burn nonces.
    let mut seen = seen_nonces()
        .lock()
        .map_err(|e| warp::reject::custom(AuthError::new(e)))?;
    seen.retain(|_, expires_at| *expires_at > now);
    if seen.contains_key(request.nonce) {
        return Err(warp::reject::custom(AuthError::new("X-Nonce already used")));
    }
    seen.insert(request.nonce.to_string(), now + MAX_SKEW_SECS);

    Ok(public_key.fingerprint(ssh_key::HashAlg::Sha256))
}

/// Gate a route behind a request signature. The body is never read, so GET and DELETE
/// cannot be used to make the process buffer an arbitrary payload.
fn signed_request(
    key: PublicKey,
) -> impl Filter<Extract = (Signed,), Error = warp::Rejection> + Clone {
    warp::method()
        .and(warp::path::full())
        .and(warp::header::<u64>("x-timestamp"))
        .and(warp::header::<String>("x-nonce"))
        .and(warp::header::<String>("x-content-sha256"))
        .and(warp::header::<String>("x-signature"))
        .and(warp::header::optional::<u64>("x-expire-seconds"))
        .and_then(
            move |method: warp::http::Method,
                  path: warp::path::FullPath,
                  ts: u64,
                  nonce: String,
                  content_sha256: String,
                  signature: String,
                  expire_secs: Option<u64>| {
                let key = key.clone();
                async move {
                    let uploader = verify_signature(
                        &key,
                        &SignatureRequest {
                            method: method.as_str(),
                            path: path.as_str(),
                            ts,
                            nonce: &nonce,
                            content_sha256: &content_sha256,
                            expire_secs,
                            signature_b64: &signature,
                        },
                    )?;
                    Ok::<_, warp::Rejection>(Signed {
                        uploader,
                        content_sha256,
                        expire_secs,
                    })
                }
            },
        )
}

/// `signed_request` plus the request body. The signature is checked before the body is
/// read, and the body is checked against the hash the client signed.
fn signed_upload(
    key: PublicKey,
) -> impl Filter<Extract = (Signed, bytes::Bytes), Error = warp::Rejection> + Clone {
    signed_request(key)
        .and(warp::body::content_length_limit(MAX_UPLOAD_BYTES))
        .and(warp::body::bytes())
        .and_then(|signed: Signed, body: bytes::Bytes| async move {
            if body_sha256(&body) != signed.content_sha256 {
                return Err(warp::reject::custom(AuthError::new(
                    "X-Content-SHA256 does not match the request body",
                )));
            }
            Ok::<_, warp::Rejection>((signed, body))
        })
        .untuple_one()
}

fn error_status(e: &std::io::Error) -> (StatusCode, &'static str) {
    match e.kind() {
        std::io::ErrorKind::NotFound => (StatusCode::NOT_FOUND, "file not found"),
        _ => (StatusCode::INTERNAL_SERVER_ERROR, "internal error"),
    }
}

fn content_disposition(name: &str, uuid: &str) -> String {
    let safe: String = name
        .chars()
        .filter(|c| !c.is_control() && *c != '"' && *c != '\\')
        .collect();
    let filename = if safe.trim().is_empty() { uuid } else { &safe };
    format!("attachment; filename=\"{filename}\"")
}

async fn handle_rejection(
    err: warp::Rejection,
) -> Result<warp::reply::Response, std::convert::Infallible> {
    let (status, message) = if let Some(AuthError(reason)) = err.find::<AuthError>() {
        eprintln!("auth rejected: {reason}");
        (StatusCode::UNAUTHORIZED, "unauthorized")
    } else if err
        .find::<warp::reject::MissingHeader>()
        .is_some_and(|missing| AUTH_HEADERS.contains(&missing.name()))
    {
        eprintln!("missing auth header");
        (StatusCode::UNAUTHORIZED, "unauthorized")
    } else if err.find::<StoreError>().is_some() {
        (StatusCode::INTERNAL_SERVER_ERROR, "internal error")
    } else if err.find::<warp::reject::PayloadTooLarge>().is_some() {
        (StatusCode::PAYLOAD_TOO_LARGE, "payload too large")
    } else if err.find::<warp::reject::LengthRequired>().is_some() {
        (StatusCode::LENGTH_REQUIRED, "content-length required")
    } else if err.find::<RouteNotFound>().is_some() {
        (StatusCode::NOT_FOUND, "not found")
    } else {
        (StatusCode::BAD_REQUEST, "bad request")
    };

    Ok(warp::reply::with_status(message.to_string(), status).into_response())
}

#[tokio::main]
async fn main() {
    let args = Args::parse();
    let address = args.bind;
    let port = args.port;

    let manager = Arc::new(
        FileManager::new(&args.storage_dir).expect("Failed to create the files directory"),
    );

    tokio::spawn({
        let manager = manager.clone();
        async move {
            let mut tick = tokio::time::interval(std::time::Duration::from_secs(300));
            loop {
                tick.tick().await;
                let manager = manager.clone();
                match tokio::task::spawn_blocking(move || manager.reconcile()).await {
                    Ok(Ok(())) => {}
                    Ok(Err(e)) => eprintln!("reconcile failed: {e}"),
                    Err(e) => eprintln!("reconcile panicked: {e}"),
                }
            }
        }
    });

    if !std::path::Path::new(&args.public_key).exists() {
        eprintln!("Error: The specified public key file does not exist.");
        std::process::exit(1);
    }

    let pub_key_content =
        std::fs::read_to_string(&args.public_key).expect("Failed to read the public key file");
    let key = match ssh_key::PublicKey::from_openssh(&pub_key_content) {
        Ok(k) => k,
        Err(e) => {
            eprintln!("Error: Failed to parse the public key: {}", e);
            std::process::exit(1);
        }
    };

    // --- gated behind ssh key

    // PUT /upload/<name> => 200 OK with the new uuid
    let upload = warp::put()
        .and(warp::path("upload"))
        .and(warp::path::param::<String>())
        .and(warp::path::end())
        .and(signed_upload(key.clone()))
        .and_then({
            let manager = manager.clone();
            move |name: String, signed: Signed, body: bytes::Bytes| {
                let manager = manager.clone();
                async move {
                    let uploader = signed.uploader.to_string();
                    let ttl_secs = signed.expire_secs;
                    let size = body.len();
                    let stored = tokio::task::spawn_blocking(move || {
                        manager.save(&name, body, &uploader, ttl_secs)
                    })
                    .await;

                    match stored {
                        Ok(Ok(uuid)) => {
                            println!("stored {uuid} ({size} bytes)");
                            Ok::<_, warp::Rejection>(
                                warp::reply::with_status(format!("{uuid}\n"), StatusCode::OK)
                                    .into_response(),
                            )
                        }
                        Ok(Err(e)) => {
                            eprintln!("save failed: {e}");
                            Err(warp::reject::custom(StoreError))
                        }
                        Err(e) => {
                            eprintln!("save panicked: {e}");
                            Err(warp::reject::custom(StoreError))
                        }
                    }
                }
            }
        });

    // DELETE /<uuid> => 200 OK
    let delete = warp::delete()
        .and(warp::path::param::<Uuid>())
        .and(warp::path::end())
        .and(signed_request(key.clone()))
        .and_then({
            let manager = manager.clone();
            move |uuid: Uuid, _signed: Signed| {
                let manager = manager.clone();
                async move {
                    match tokio::task::spawn_blocking(move || manager.delete(&uuid.to_string()))
                        .await
                    {
                        Ok(Ok(())) => {
                            println!("deleted {uuid}");
                            Ok::<_, warp::Rejection>(
                                warp::reply::with_status(format!("{uuid}\n"), StatusCode::OK)
                                    .into_response(),
                            )
                        }
                        Ok(Err(e)) => {
                            eprintln!("delete {uuid} failed: {e}");
                            let (status, message) = error_status(&e);
                            Ok(warp::reply::with_status(message.to_string(), status)
                                .into_response())
                        }
                        Err(e) => {
                            eprintln!("delete {uuid} panicked: {e}");
                            Err(warp::reject::custom(StoreError))
                        }
                    }
                }
            }
        });

    // GET /list => 200 OK with the live entries
    let list = warp::get()
        .and(warp::path("list"))
        .and(warp::path::end())
        .and(signed_request(key.clone()))
        .and_then({
            let manager = manager.clone();
            move |_signed: Signed| {
                let manager = manager.clone();
                async move {
                    match tokio::task::spawn_blocking(move || manager.list()).await {
                        Ok(Ok(files)) => {
                            Ok::<_, warp::Rejection>(warp::reply::json(&files).into_response())
                        }
                        Ok(Err(e)) => {
                            eprintln!("list failed: {e}");
                            Err(warp::reject::custom(StoreError))
                        }
                        Err(e) => {
                            eprintln!("list panicked: {e}");
                            Err(warp::reject::custom(StoreError))
                        }
                    }
                }
            }
        });

    // --- accessible to everyone with the link

    // GET /health => 200 OK
    let health = warp::get()
        .and(warp::path("health"))
        .and(warp::path::end())
        .map(|| warp::reply::with_status("ok", StatusCode::OK));

    // GET /<uuid> => 200 OK with the file content
    let access = warp::get()
        .and(warp::path::param::<Uuid>())
        .and(warp::path::end())
        .and_then(move |uuid: Uuid| {
            let manager = manager.clone();
            async move {
                let resolved =
                    tokio::task::spawn_blocking(move || manager.resolve(&uuid.to_string())).await;

                let (meta, path) = match resolved {
                    Ok(Ok(found)) => found,
                    Ok(Err(e)) => {
                        eprintln!("access {uuid} failed: {e}");
                        let (status, message) = error_status(&e);
                        return Ok::<_, warp::Rejection>(
                            warp::reply::with_status(message.to_string(), status).into_response(),
                        );
                    }
                    Err(e) => {
                        eprintln!("access {uuid} panicked: {e}");
                        return Err(warp::reject::custom(StoreError));
                    }
                };

                let file = match tokio::fs::File::open(&path).await {
                    Ok(file) => file,
                    Err(e) => {
                        eprintln!("access {uuid} failed: {e}");
                        let (status, message) = error_status(&e);
                        return Ok::<_, warp::Rejection>(
                            warp::reply::with_status(message.to_string(), status).into_response(),
                        );
                    }
                };

                let mut response =
                    warp::reply::stream(tokio_util::io::ReaderStream::new(file)).into_response();
                response.headers_mut().insert(
                    warp::http::header::CONTENT_TYPE,
                    warp::http::HeaderValue::from_static("application/octet-stream"),
                );
                if let Ok(value) = warp::http::HeaderValue::from_str(&content_disposition(
                    &meta.name,
                    &uuid.to_string(),
                )) {
                    response
                        .headers_mut()
                        .insert(warp::http::header::CONTENT_DISPOSITION, value);
                }
                Ok::<_, warp::Rejection>(response)
            }
        });

    println!("Server running at http://{}:{}", address, port);

    let routes = health
        .or(upload)
        .or(delete)
        .or(list)
        .or(access)
        .or(warp::any().and_then(|| async {
            Err::<(warp::reply::Response,), warp::Rejection>(warp::reject::custom(RouteNotFound))
        }))
        .recover(handle_rejection);
    warp::serve(routes).run((address, port)).await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn body_sha256_of_empty_body() {
        assert_eq!(
            body_sha256(&bytes::Bytes::new()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
    }

    #[test]
    fn body_sha256_of_abc() {
        assert_eq!(
            body_sha256(&bytes::Bytes::from_static(b"abc")),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn canonical_message_without_expiry() {
        assert_eq!(
            canonical_message("PUT", "/upload/a.txt", 1, "n", "h", None),
            "PUT\n/upload/a.txt\n1\nn\nh\n-"
        );
    }

    #[test]
    fn canonical_message_with_expiry() {
        assert_eq!(
            canonical_message("GET", "/list", 1, "n", "h", Some(60)),
            "GET\n/list\n1\nn\nh\n60"
        );
    }

    #[test]
    fn content_disposition_drops_quotes_backslashes_and_controls() {
        assert_eq!(
            content_disposition("a\"b\\c\nd.txt", "uuid"),
            "attachment; filename=\"abcd.txt\""
        );
    }

    #[test]
    fn content_disposition_falls_back_to_uuid() {
        assert_eq!(
            content_disposition("\"\"", "uuid"),
            "attachment; filename=\"uuid\""
        );
    }
}

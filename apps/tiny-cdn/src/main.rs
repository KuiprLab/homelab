use base64::Engine;
use clap::Parser;
use ssh_key::sha2::Digest;
use ssh_key::{Fingerprint, PublicKey, SshSig};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use warp::http::StatusCode;
use warp::{Filter, Reply};

use crate::files_manager::FileManager;
use crate::preview::{media_type, preview_html};

mod files_manager;
mod preview;

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

/// Falls through to the default rejection handler, which answers 400.
#[derive(Debug)]
struct BadRequest;

impl warp::reject::Reject for BadRequest {}

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

fn content_disposition(disposition: &str, name: &str, id: &str) -> String {
    let safe: String = name
        .chars()
        .filter(|c| !c.is_control() && *c != '"' && *c != '\\')
        .collect();
    let filename = if safe.trim().is_empty() { id } else { &safe };
    format!("{disposition}; filename=\"{filename}\"")
}

enum ByteRange {
    Full,
    Partial { start: u64, end: u64 },
    Unsatisfiable,
}

/// Single byte range only. Anything else falls back to the whole file, which is allowed.
fn parse_range(header: Option<&str>, size: u64) -> ByteRange {
    let Some(spec) = header.and_then(|value| value.strip_prefix("bytes=")) else {
        return ByteRange::Full;
    };
    let Some((start, end)) = spec.split_once('-') else {
        return ByteRange::Full;
    };
    if size == 0 {
        return ByteRange::Unsatisfiable;
    }

    let (start, end) = if start.is_empty() {
        let Ok(suffix) = end.parse::<u64>() else {
            return ByteRange::Full;
        };
        if suffix == 0 {
            return ByteRange::Unsatisfiable;
        }
        (size.saturating_sub(suffix), size - 1)
    } else {
        let Ok(start) = start.parse::<u64>() else {
            return ByteRange::Full;
        };
        let end = if end.is_empty() {
            size - 1
        } else {
            let Ok(end) = end.parse::<u64>() else {
                return ByteRange::Full;
            };
            end.min(size - 1)
        };
        (start, end)
    };

    if start > end || start >= size {
        return ByteRange::Unsatisfiable;
    }
    ByteRange::Partial { start, end }
}

/// Reverses `path_segment`. warp hands path parameters over still percent-encoded.
fn percent_decode(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let hex = value.get(index + 1..index + 3)?;
            decoded.push(u8::from_str_radix(hex, 16).ok()?);
            index += 3;
        } else {
            decoded.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(decoded).ok()
}

/// Resolves an id to its metadata and file path, logging and mapping store errors.
async fn resolve_entry(
    manager: Arc<FileManager>,
    id: &str,
) -> Result<(files_manager::Meta, std::path::PathBuf), (StatusCode, &'static str)> {
    let id_for_resolve = id.to_string();
    let resolved = tokio::task::spawn_blocking(move || manager.resolve(&id_for_resolve)).await;
    match resolved {
        Ok(Ok(found)) => Ok(found),
        Ok(Err(e)) => {
            eprintln!("access {id} failed: {e}");
            Err(error_status(&e))
        }
        Err(e) => {
            eprintln!("access {id} panicked: {e}");
            Err((StatusCode::INTERNAL_SERVER_ERROR, "internal error"))
        }
    }
}

/// Serves the stored bytes, honouring `Range`. `download` forces an attachment, which
/// is what a click on the shared link gets.
async fn serve_file(
    manager: Arc<FileManager>,
    id: String,
    range: Option<String>,
    download: bool,
) -> Result<warp::reply::Response, warp::Rejection> {
    let (meta, path) = match resolve_entry(manager, &id).await {
        Ok(entry) => entry,
        Err((status, message)) => {
            return Ok(warp::reply::with_status(message.to_string(), status).into_response());
        }
    };

    let mut file = match tokio::fs::File::open(&path).await {
        Ok(file) => file,
        Err(e) => {
            eprintln!("access {id} failed: {e}");
            let (status, message) = error_status(&e);
            return Ok(warp::reply::with_status(message.to_string(), status).into_response());
        }
    };

    let size = match file.metadata().await {
        Ok(metadata) => metadata.len(),
        Err(e) => {
            eprintln!("access {id} failed: {e}");
            let (status, message) = error_status(&e);
            return Ok(warp::reply::with_status(message.to_string(), status).into_response());
        }
    };

    let (status, length, content_range) = match parse_range(range.as_deref(), size) {
        ByteRange::Full => (StatusCode::OK, size, None),
        ByteRange::Partial { start, end } => {
            if let Err(e) = file.seek(std::io::SeekFrom::Start(start)).await {
                eprintln!("access {id} failed: {e}");
                let (status, message) = error_status(&e);
                return Ok(warp::reply::with_status(message.to_string(), status).into_response());
            }
            (
                StatusCode::PARTIAL_CONTENT,
                end - start + 1,
                Some(format!("bytes {start}-{end}/{size}")),
            )
        }
        ByteRange::Unsatisfiable => {
            return Ok(warp::reply::with_status(
                "range not satisfiable",
                StatusCode::RANGE_NOT_SATISFIABLE,
            )
            .into_response());
        }
    };

    let media_type = media_type(&meta.name);
    let inline = media_type.starts_with("image/") || media_type.starts_with("video/");
    let disposition = content_disposition(
        if inline && !download {
            "inline"
        } else {
            "attachment"
        },
        &meta.name,
        &id,
    );

    let mut response = warp::reply::with_status(
        warp::reply::stream(tokio_util::io::ReaderStream::new(file.take(length))),
        status,
    )
    .into_response();
    response.headers_mut().insert(
        warp::http::header::CONTENT_TYPE,
        warp::http::HeaderValue::from_static(media_type),
    );
    response.headers_mut().insert(
        warp::http::header::CONTENT_LENGTH,
        warp::http::HeaderValue::from(length),
    );
    response.headers_mut().insert(
        warp::http::header::ACCEPT_RANGES,
        warp::http::HeaderValue::from_static("bytes"),
    );
    response.headers_mut().insert(
        warp::http::header::CACHE_CONTROL,
        warp::http::HeaderValue::from_static("public, max-age=3600, immutable"),
    );
    if let Some(content_range) = content_range
        && let Ok(value) = warp::http::HeaderValue::from_str(&content_range)
    {
        response
            .headers_mut()
            .insert(warp::http::header::CONTENT_RANGE, value);
    }
    if let Ok(value) = warp::http::HeaderValue::from_str(&disposition) {
        response
            .headers_mut()
            .insert(warp::http::header::CONTENT_DISPOSITION, value);
    }
    Ok(response)
}

fn byte_route(
    prefix: &'static str,
    manager: Arc<FileManager>,
    download: bool,
) -> impl Filter<Extract = (warp::reply::Response,), Error = warp::Rejection> + Clone {
    warp::get()
        .or(warp::head())
        .unify()
        .and(warp::path(prefix))
        .and(warp::path::param::<String>())
        .and(warp::path::tail())
        .and(warp::header::optional::<String>("range"))
        .and_then(
            move |id: String, _tail: warp::path::Tail, range: Option<String>| {
                let manager = manager.clone();
                async move { serve_file(manager, id, range, download).await }
            },
        )
}

/// Unfurlers get the preview page, everything else gets the file.
fn is_unfurler(user_agent: &str) -> bool {
    const TOKENS: [&str; 12] = [
        "bot",
        "crawler",
        "spider",
        "preview",
        "embedly",
        "facebookexternalhit",
        "whatsapp",
        "slack",
        "telegram",
        "mastodon",
        "cardyb",
        "skype",
    ];
    let user_agent = user_agent.to_ascii_lowercase();
    TOKENS.iter().any(|token| user_agent.contains(token))
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

    // PUT /upload/<name> => 200 OK with the new nanoid
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
                    let Some(name) = percent_decode(&name) else {
                        eprintln!("rejecting upload, invalid percent-encoding: {name}");
                        return Err(warp::reject::custom(BadRequest));
                    };
                    let uploader = signed.uploader.to_string();
                    let ttl_secs = signed.expire_secs;
                    let size = body.len();
                    let stored = tokio::task::spawn_blocking(move || {
                        manager.save(&name, body, &uploader, ttl_secs)
                    })
                    .await;

                    match stored {
                        Ok(Ok(file)) => {
                            println!("stored {} ({} bytes)", file.id, size);
                            Ok::<_, warp::Rejection>(warp::reply::json(&file).into_response())
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

    // DELETE /<id> => 200 OK
    let delete = warp::delete()
        .and(warp::path::param())
        .and(warp::path::end())
        .and(signed_request(key.clone()))
        .and_then({
            let manager = manager.clone();
            move |id: String, _signed: Signed| {
                let manager = manager.clone();
                async move {
                    let id_for_delete = id.clone();
                    match tokio::task::spawn_blocking(move || manager.delete(&id_for_delete)).await
                    {
                        Ok(Ok(())) => {
                            println!("deleted {id}");
                            Ok::<_, warp::Rejection>(
                                warp::reply::with_status(format!("{id}\n"), StatusCode::OK)
                                    .into_response(),
                            )
                        }
                        Ok(Err(e)) => {
                            eprintln!("delete {id} failed: {e}");
                            let (status, message) = error_status(&e);
                            Ok(warp::reply::with_status(message.to_string(), status)
                                .into_response())
                        }
                        Err(e) => {
                            eprintln!("delete {id} panicked: {e}");
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

    // GET /favicon.ico => 204, so unfurlers stop logging a 404
    let favicon = warp::get()
        .and(warp::path("favicon.ico"))
        .and(warp::path::end())
        .map(|| StatusCode::NO_CONTENT);

    // GET|HEAD /raw/<id>[/<filename>] => 200 OK, or 206 for a byte range
    let raw = byte_route("raw", manager.clone(), false);

    // GET|HEAD /download/<id>[/<filename>] => 200 OK, always as an attachment
    let download = byte_route("download", manager.clone(), true);
    // GET /<id>[/<filename>] => the preview page for an unfurler, a download otherwise
    let access = warp::get()
        .and(warp::path::param::<String>())
        .and(warp::path::tail())
        .and(warp::header::optional::<String>("host"))
        .and(warp::header::optional::<String>("x-forwarded-proto"))
        .and(warp::header::optional::<String>("user-agent"))
        .and_then(
            move |id: String,
                  _tail: warp::path::Tail,
                  host: Option<String>,
                  forwarded_proto: Option<String>,
                  user_agent: Option<String>| {
                let manager = manager.clone();
                async move {
                    let Some(host) = host else {
                        eprintln!("access {id} without a Host header");
                        return Err(warp::reject::custom(BadRequest));
                    };
                    let base_url =
                        format!("{}://{host}", forwarded_proto.as_deref().unwrap_or("https"));

                    if !is_unfurler(user_agent.as_deref().unwrap_or_default()) {
                        let Ok(location) =
                            format!("{base_url}/download/{id}").parse::<warp::http::Uri>()
                        else {
                            eprintln!("access {id} cannot build a download location");
                            return Err(warp::reject::custom(BadRequest));
                        };
                        return Ok::<_, warp::Rejection>(
                            warp::redirect::found(location).into_response(),
                        );
                    }

                    let (meta, path) = match resolve_entry(manager, &id).await {
                        Ok(entry) => entry,
                        Err((status, message)) => {
                            return Ok::<_, warp::Rejection>(
                                warp::reply::with_status(message.to_string(), status)
                                    .into_response(),
                            );
                        }
                    };

                    let size = match tokio::fs::metadata(&path).await {
                        Ok(metadata) => metadata.len(),
                        Err(e) => {
                            eprintln!("access {id} failed: {e}");
                            let (status, message) = error_status(&e);
                            return Ok::<_, warp::Rejection>(
                                warp::reply::with_status(message.to_string(), status)
                                    .into_response(),
                            );
                        }
                    };

                    Ok::<_, warp::Rejection>(
                        warp::reply::html(preview_html(&meta, &id, size, &base_url))
                            .into_response(),
                    )
                }
            },
        );

    println!("Server running at http://{}:{}", address, port);

    let routes = health
        .or(favicon)
        .or(upload)
        .or(delete)
        .or(list)
        .or(raw)
        .or(download)
        .or(access)
        .or(warp::any().and_then(|| async {
            Err::<(warp::reply::Response,), warp::Rejection>(warp::reject::custom(RouteNotFound))
        }))
        .recover(handle_rejection)
        .with(warp::log::custom(|info| {
            println!(
                "{} {} {} {}",
                info.method(),
                info.path(),
                info.status(),
                info.user_agent().unwrap_or("-")
            );
        }));
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
            content_disposition("attachment", "a\"b\\c\nd.txt", "id"),
            "attachment; filename=\"abcd.txt\""
        );
    }

    #[test]
    fn content_disposition_falls_back_to_id() {
        assert_eq!(
            content_disposition("attachment", "\"\"", "id"),
            "attachment; filename=\"id\""
        );
    }

    #[test]
    fn is_unfurler_matches_crawlers_only() {
        assert!(is_unfurler(
            "Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)"
        ));
        assert!(is_unfurler("Twitterbot/1.0"));
        assert!(is_unfurler("facebookexternalhit/1.1"));
        assert!(is_unfurler("Slackbot-LinkExpanding 1.0"));
        assert!(is_unfurler("WhatsApp/2.23"));
        assert!(!is_unfurler(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15"
        ));
        assert!(!is_unfurler("curl/8.23.0"));
        assert!(!is_unfurler(""));
    }

    #[test]
    fn percent_decode_reverses_path_segment() {
        assert_eq!(percent_decode("a%20b%2Fc.png").unwrap(), "a b/c.png");
        assert_eq!(percent_decode("plain.toml").unwrap(), "plain.toml");
        assert!(percent_decode("bad%2").is_none());
        assert!(percent_decode("bad%zz").is_none());
        assert!(percent_decode("bad%ff").is_none());
    }

    #[test]
    fn parse_range_handles_the_usual_forms() {
        assert!(matches!(parse_range(None, 100), ByteRange::Full));
        assert!(matches!(
            parse_range(Some("bytes=0-9"), 100),
            ByteRange::Partial { start: 0, end: 9 }
        ));
        assert!(matches!(
            parse_range(Some("bytes=90-"), 100),
            ByteRange::Partial { start: 90, end: 99 }
        ));
        assert!(matches!(
            parse_range(Some("bytes=-10"), 100),
            ByteRange::Partial { start: 90, end: 99 }
        ));
        assert!(matches!(
            parse_range(Some("bytes=50-1000"), 100),
            ByteRange::Partial { start: 50, end: 99 }
        ));
        assert!(matches!(
            parse_range(Some("bytes=100-"), 100),
            ByteRange::Unsatisfiable
        ));
        assert!(matches!(
            parse_range(Some("bytes=5-1"), 100),
            ByteRange::Unsatisfiable
        ));
        assert!(matches!(
            parse_range(Some("bytes=-0"), 100),
            ByteRange::Unsatisfiable
        ));
        assert!(matches!(
            parse_range(Some("items=0-9"), 100),
            ByteRange::Full
        ));
        assert!(matches!(
            parse_range(Some("bytes=a-b"), 100),
            ByteRange::Full
        ));
    }
}

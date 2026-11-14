use base64::Engine;
use clap::Parser;
use ssh_key::sha2::Digest;
use ssh_key::{Fingerprint, PublicKey, SshSig};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};
use warp::{Filter, Reply};

use crate::files_manager::FileManager;

mod files_manager;

#[derive(Parser, Debug)]
#[command(
    name = "File Server",
    about = "A simple file server with upload, delete, list, and access endpoints."
)]
struct Args {
    #[arg(short, help = "Path to the SSH identity file for authentication")]
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

const MAX_SKEW_SECS: u64 = 60;

fn seen_nonces() -> &'static Mutex<HashMap<String, u64>> {
    static SEEN_NONCES: OnceLock<Mutex<HashMap<String, u64>>> = OnceLock::new();
    SEEN_NONCES.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Verify if http request is signed i.e. allowed to upload, delete, list files
fn verify_message(
    public_key: &PublicKey,
    method: &str,
    path: &str,
    ts: u64,
    nonce: &str,
    content_sha256: &str,
    expire_secs: Option<u64>,
    signature_b64: &str,
    body: &bytes::Bytes,
) -> Result<Fingerprint, warp::Rejection> {
    let namespace = "cdn-upload";

    let actual_sha256: String = ssh_key::sha2::Sha256::digest(body)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    if actual_sha256 != content_sha256 {
        return Err(warp::reject::custom(AuthError::new(
            "X-Content-SHA256 does not match the request body",
        )));
    }

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| warp::reject::custom(AuthError::new(e)))?
        .as_secs();
    if now.abs_diff(ts) > MAX_SKEW_SECS {
        return Err(warp::reject::custom(AuthError::new(
            "X-Timestamp outside the allowed window",
        )));
    }

    let expire = expire_secs
        .map(|secs| secs.to_string())
        .unwrap_or_else(|| "-".to_string());
    let message = format!("{method}\n{path}\n{ts}\n{nonce}\n{content_sha256}\n{expire}");

    let pem = base64::engine::general_purpose::STANDARD
        .decode(signature_b64)
        .map_err(|e| warp::reject::custom(AuthError::new(e)))?;

    let signature = SshSig::from_pem(&pem).map_err(|e| warp::reject::custom(AuthError::new(e)))?;

    public_key
        .verify(namespace, message.as_bytes(), &signature)
        .map_err(|e| warp::reject::custom(AuthError::new(e)))?;

    // Recorded only after the signature checks out, so unsigned requests can't burn nonces.
    let mut seen = seen_nonces()
        .lock()
        .map_err(|e| warp::reject::custom(AuthError::new(e)))?;
    seen.retain(|_, expires_at| *expires_at > now);
    if seen.contains_key(nonce) {
        return Err(warp::reject::custom(AuthError::new("X-Nonce already used")));
    }
    seen.insert(nonce.to_string(), now + MAX_SKEW_SECS);

    Ok(public_key.fingerprint(ssh_key::HashAlg::Sha256))
}

/// Gate a route behind a request signature. Yields the request body on success.
fn signed_request(
    key: PublicKey,
) -> impl Filter<Extract = (Fingerprint, bytes::Bytes), Error = warp::Rejection> + Clone {
    warp::method()
        .and(warp::path::full())
        .and(warp::header::<u64>("x-timestamp"))
        .and(warp::header::<String>("x-nonce"))
        .and(warp::header::<String>("x-content-sha256"))
        .and(warp::header::<String>("x-signature"))
        .and(warp::header::optional::<u64>("x-expire-seconds"))
        .and(warp::body::bytes())
        .and_then(
            move |method: warp::http::Method,
                  path: warp::path::FullPath,
                  ts: u64,
                  nonce: String,
                  content_sha256: String,
                  signature: String,
                  expire_secs: Option<u64>,
                  body: bytes::Bytes| {
                let key = key.clone();
                async move {
                    let uploader = verify_message(
                        &key,
                        method.as_str(),
                        path.as_str(),
                        ts,
                        &nonce,
                        &content_sha256,
                        expire_secs,
                        &signature,
                        &body,
                    )?;
                    Ok::<_, warp::Rejection>((uploader, body))
                }
            },
        )
        .untuple_one()
}

fn error_status(e: &std::io::Error) -> (warp::http::StatusCode, &'static str) {
    match e.kind() {
        std::io::ErrorKind::NotFound => (warp::http::StatusCode::NOT_FOUND, "file not found"),
        std::io::ErrorKind::InvalidInput => (warp::http::StatusCode::BAD_REQUEST, "invalid uuid"),
        _ => (
            warp::http::StatusCode::INTERNAL_SERVER_ERROR,
            "internal error",
        ),
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

const AUTH_HEADERS: [&str; 4] = ["x-timestamp", "x-nonce", "x-content-sha256", "x-signature"];

async fn handle_rejection(
    err: warp::Rejection,
) -> Result<impl warp::Reply, std::convert::Infallible> {
    if let Some(AuthError(reason)) = err.find::<AuthError>() {
        eprintln!("auth rejected: {reason}");
        return Ok(warp::reply::with_status(
            "unauthorized".to_string(),
            warp::http::StatusCode::UNAUTHORIZED,
        ));
    }

    if let Some(missing) = err.find::<warp::reject::MissingHeader>() {
        if AUTH_HEADERS.contains(&missing.name()) {
            eprintln!("missing auth header: {}", missing.name());
            return Ok(warp::reply::with_status(
                "unauthorized".to_string(),
                warp::http::StatusCode::UNAUTHORIZED,
            ));
        }
    }

    Ok(warp::reply::with_status(
        "bad request".to_string(),
        warp::http::StatusCode::BAD_REQUEST,
    ))
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

    // Verify if the passed argument is a valid file path and a valid ssh public key
    if !std::path::Path::new(&args.public_key).exists() {
        eprintln!("Error: The specified identity file does not exist.");
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
    // POST /upload => 200 OK with body "File uploaded!"
    let upload = warp::put()
        .and(warp::path("upload"))
        .and(warp::path::param::<String>())
        .and(warp::body::content_length_limit(100 * 1024 * 1024))
        .and(warp::header::optional::<u64>("x-expire-seconds"))
        .and(signed_request(key.clone()))
        .map({
            let manager = manager.clone();
            move |name: String, ttl_secs: Option<u64>, uploader: Fingerprint, body: bytes::Bytes| {
                println!("Received file {} of size: {}", name, body.len());
                match manager.save(&name, body, &uploader.to_string(), ttl_secs) {
                    Ok(uuid) => {
                        warp::reply::with_status(format!("{}\n", uuid), warp::http::StatusCode::OK)
                    }
                    Err(e) => {
                        eprintln!("save failed: {e}");
                        warp::reply::with_status(
                            "failed to store file".to_string(),
                            warp::http::StatusCode::INTERNAL_SERVER_ERROR,
                        )
                    }
                }
            }
        });

    // DELETE /<UUID> => 200 OK
    let delete = warp::delete()
        .and(warp::path::param::<String>())
        .and(signed_request(key.clone()))
        .map({
            let manager = manager.clone();
            move |uuid: String, _uploader: Fingerprint, _body: bytes::Bytes| match manager
                .delete(&uuid)
            {
                Ok(()) => {
                    println!("Deleted file with UUID: {}", uuid);
                    warp::reply::with_status(format!("{}\n", uuid), warp::http::StatusCode::OK)
                        .into_response()
                }
                Err(e) => {
                    eprintln!("delete {uuid} failed: {e}");
                    let (status, message) = error_status(&e);
                    warp::reply::with_status(message.to_string(), status).into_response()
                }
            }
        });

    // GET /list => 200 OK with list of files
    let list = warp::get()
        .and(warp::path("list"))
        .and(warp::path::end())
        .and(signed_request(key.clone()))
        .map({
            let manager = manager.clone();
            move |_uploader: Fingerprint, _body: bytes::Bytes| {
                println!("Received request to list files");
                match manager.list() {
                    Ok(files) => warp::reply::json(&files).into_response(),
                    Err(e) => {
                        eprintln!("list failed: {e}");
                        warp::reply::with_status(
                            "failed to list files".to_string(),
                            warp::http::StatusCode::INTERNAL_SERVER_ERROR,
                        )
                        .into_response()
                    }
                }
            }
        });

    // --- accessible to everyone with link

    // GET /<UUID> => 200 OK with file content
    let access = warp::get()
        .and(warp::path::param::<String>())
        .and(warp::path::end())
        .and_then(move |uuid: String| {
            let manager = manager.clone();
            async move {
                println!("Received request to access file with UUID: {}", uuid);
                if uuid == "list" {
                    return Err(warp::reject::not_found());
                }

                let (meta, path) = match manager.resolve(&uuid) {
                    Ok(found) => found,
                    Err(e) => {
                        eprintln!("access {uuid} failed: {e}");
                        let (status, message) = error_status(&e);
                        return Ok::<_, warp::Rejection>(
                            warp::reply::with_status(message.to_string(), status).into_response(),
                        );
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
                if let Ok(value) =
                    warp::http::HeaderValue::from_str(&content_disposition(&meta.name, &uuid))
                {
                    response
                        .headers_mut()
                        .insert(warp::http::header::CONTENT_DISPOSITION, value);
                }
                Ok::<_, warp::Rejection>(response)
            }
        });

    println!("Server running at http://{}:{}", address, port);

    // combine all routes
    let routes = upload
        .or(delete)
        .or(list)
        .or(access)
        .recover(handle_rejection);
    warp::serve(routes).run((address, port)).await;
}

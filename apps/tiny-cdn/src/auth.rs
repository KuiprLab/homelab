use base64::Engine;
use ssh_key::sha2::Digest;
use ssh_key::{Fingerprint, PublicKey, SshSig};
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};
use warp::Filter;

pub const AUTH_HEADERS: [&str; 4] = ["x-timestamp", "x-nonce", "x-content-sha256", "x-signature"];

const MAX_UPLOAD_BYTES: u64 = 100 * 1024 * 1024;
const MAX_SKEW_SECS: u64 = 60;
const SIGNATURE_NAMESPACE: &str = "cdn-upload";

#[derive(Debug)]
pub struct AuthError(pub String);

impl AuthError {
    fn new(e: impl std::fmt::Display) -> Self {
        Self(e.to_string())
    }
}

impl warp::reject::Reject for AuthError {}

/// What a verified request signature proves about its sender.
pub struct Signed {
    pub uploader: Fingerprint,
    pub content_sha256: String,
    pub expire_secs: Option<u64>,
}

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
pub fn signed_request(
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
pub fn signed_upload(
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
}

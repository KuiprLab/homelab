use clap::Parser;
use std::sync::Arc;
use warp::http::StatusCode;
use warp::{Filter, Reply};

use crate::auth::{AUTH_HEADERS, AuthError, Signed, signed_request, signed_upload};
use crate::files_manager::FileManager;
use crate::preview::preview_html;
use crate::transfer::{error_status, is_unfurler, resolve_entry, serve_file};

mod auth;
mod files_manager;
mod preview;
mod transfer;

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

#[derive(serde::Deserialize)]
struct AccessQuery {
    raw: Option<String>,
}

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

    // GET|HEAD /<id>[/<filename>] => the preview page for an unfurler, the bytes otherwise
    let access = warp::get()
        .or(warp::head())
        .unify()
        .and(warp::path::param::<String>())
        .and(warp::path::tail())
        .and(warp::header::optional::<String>("host"))
        .and(warp::header::optional::<String>("x-forwarded-proto"))
        .and(warp::header::optional::<String>("user-agent"))
        .and(warp::header::optional::<String>("range"))
        .and(warp::query::<AccessQuery>())
        .and(warp::method())
        .and_then(
            move |id: String,
                  _tail: warp::path::Tail,
                  host: Option<String>,
                  forwarded_proto: Option<String>,
                  user_agent: Option<String>,
                  range: Option<String>,
                  query: AccessQuery,
                  method: warp::http::Method| {
                let manager = manager.clone();
                async move {
                    let inline = query.raw.is_some();
                    let unfurler = is_unfurler(user_agent.as_deref().unwrap_or_default());
                    if inline || !unfurler || method == warp::http::Method::HEAD {
                        return serve_file(manager, id, range, !inline).await;
                    }

                    let Some(host) = host else {
                        eprintln!("access {id} without a Host header");
                        return Err(warp::reject::custom(BadRequest));
                    };
                    let base_url =
                        format!("{}://{host}", forwarded_proto.as_deref().unwrap_or("https"));

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
    fn percent_decode_reverses_path_segment() {
        assert_eq!(percent_decode("a%20b%2Fc.png").unwrap(), "a b/c.png");
        assert_eq!(percent_decode("plain.toml").unwrap(), "plain.toml");
        assert!(percent_decode("bad%2").is_none());
        assert!(percent_decode("bad%zz").is_none());
        assert!(percent_decode("bad%ff").is_none());
    }
}

use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use warp::Reply;
use warp::http::StatusCode;

use crate::files_manager::{self, FileManager};
use crate::preview::media_type;

pub fn error_status(e: &std::io::Error) -> (StatusCode, &'static str) {
    match e.kind() {
        std::io::ErrorKind::NotFound => (StatusCode::NOT_FOUND, "file not found"),
        std::io::ErrorKind::InvalidInput => (StatusCode::BAD_REQUEST, "bad request"),
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

/// Unfurlers get the preview page and inline media, everything else gets a download.
pub fn is_unfurler(user_agent: &str) -> bool {
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

/// Resolves an id to its metadata and file path, logging and mapping store errors.
pub async fn resolve_entry(
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

/// Serves the stored bytes, honouring `Range`. `download` forces an attachment.
pub async fn serve_file(
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

#[cfg(test)]
mod tests {
    use super::*;

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

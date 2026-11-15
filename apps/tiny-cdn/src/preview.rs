use crate::files_manager::Meta;

pub fn media_type(name: &str) -> &'static str {
    match std::path::Path::new(name)
        .extension()
        .and_then(|ext| ext.to_str())
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        Some("png") => "image/png",
        Some("gif") => "image/gif",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("webp") => "image/webp",
        Some("avif") => "image/avif",
        Some("mp4") => "video/mp4",
        Some("webm") => "video/webm",
        Some("mov") => "video/quicktime",
        _ => "application/octet-stream",
    }
}

fn escape_html(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

/// Percent-encodes a file name so it can be used as a single URL path segment.
fn path_segment(name: &str) -> String {
    let mut encoded = String::with_capacity(name.len());
    for byte in name.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            encoded.push(byte as char);
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    encoded
}

fn human_size(bytes: u64) -> String {
    const UNITS: [&str; 4] = ["KiB", "MiB", "GiB", "TiB"];
    if bytes < 1024 {
        return format!("{bytes} B");
    }
    let mut value = bytes as f64 / 1024.0;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    format!("{value:.1} {}", UNITS[unit])
}

/// Renders Unix seconds as `YYYY-MM-DD HH:MM UTC`. Civil date from days since the
/// epoch, so no time zone database is needed.
fn format_timestamp(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let seconds_of_day = secs % 86_400;
    let (year, month, day) = civil_from_days(days);
    let hour = seconds_of_day / 3600;
    let minute = seconds_of_day % 3600 / 60;
    format!("{year:04}-{month:02}-{day:02} {hour:02}:{minute:02} UTC")
}

fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let shifted = days + 719_468;
    let era = shifted.div_euclid(146_097);
    let day_of_era = shifted.rem_euclid(146_097);
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = (day_of_year - (153 * month_index + 2) / 5 + 1) as u32;
    let month = if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    } as u32;
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

/// The page unfurlers read. Metadata only, no styling: the tags have to be in the
/// served HTML, and Discord does not resolve a relative `og:image`.
pub fn preview_html(meta: &Meta, id: &str, size: u64, base_url: &str) -> String {
    let name = escape_html(&meta.name);
    let base_url = escape_html(base_url);
    let description = escape_html(&format!(
        "{} · expires on {}",
        human_size(size),
        format_timestamp(meta.expires_at)
    ));
    let media_type = media_type(&meta.name);
    let encoded_name = path_segment(&meta.name);
    let media = if media_type.starts_with("image/") {
        format!(
            "<meta property=\"og:image\" content=\"{base_url}/raw/{id}/{encoded_name}\">\n\
             <meta property=\"og:image:type\" content=\"{media_type}\">\n\
             <meta name=\"twitter:card\" content=\"summary_large_image\">"
        )
    } else {
        String::new()
    };

    format!(
        r##"<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{name}</title>
<meta property="og:site_name" content="tiny-cdn">
<meta property="og:title" content="{name}">
<meta property="og:description" content="{description}">
{media}
<meta name="theme-color" content="#5865F2">
</head>
<body>
<h1>{name}</h1>
<p>{description}</p>
</body>
</html>
"##
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn meta(name: &str) -> Meta {
        Meta {
            name: name.to_string(),
            uploader: "SHA256:test".to_string(),
            created_at: 0,
            expires_at: crate::files_manager::now_secs().unwrap() + 3600,
        }
    }

    #[test]
    fn preview_of_an_image_points_og_image_at_the_raw_route() {
        let html = preview_html(&meta("a b.png"), "id", 2048, "https://cdn.example");
        assert!(html.contains("content=\"https://cdn.example/raw/id/a%20b.png\""));
        assert!(html.contains("content=\"image/png\""));
        assert!(html.contains("summary_large_image"));
    }

    #[test]
    fn preview_of_a_plain_file_has_no_image() {
        let html = preview_html(&meta("Cargo.toml"), "id", 512, "https://cdn.example");
        assert!(!html.contains("og:image"));
        assert!(html.contains("content=\"512 B · expires on "));
    }

    #[test]
    fn preview_of_a_video_has_no_media_tags() {
        let html = preview_html(&meta("clip.mp4"), "id", 1024, "https://cdn.example");
        assert!(!html.contains("og:video"));
        assert!(!html.contains("og:image"));
    }

    #[test]
    fn preview_escapes_the_file_name() {
        let html = preview_html(&meta("<b>&\"x\"</b>.txt"), "id", 1, "https://cdn.example");
        assert!(html.contains("&lt;b&gt;&amp;&quot;x&quot;&lt;/b&gt;.txt"));
    }

    #[test]
    fn preview_escapes_the_base_url() {
        let html = preview_html(&meta("a.png"), "id", 1, "https://x\"><script>");
        assert!(!html.contains("<script>"));
    }

    #[test]
    fn format_timestamp_renders_utc() {
        assert_eq!(format_timestamp(0), "1970-01-01 00:00 UTC");
        assert_eq!(format_timestamp(1_700_000_000), "2023-11-14 22:13 UTC");
        assert_eq!(format_timestamp(1_767_225_599), "2025-12-31 23:59 UTC");
        assert_eq!(format_timestamp(1_767_225_600), "2026-01-01 00:00 UTC");
    }

    #[test]
    fn media_type_maps_known_extensions() {
        assert_eq!(media_type("a.PNG"), "image/png");
        assert_eq!(media_type("a.mp4"), "video/mp4");
        assert_eq!(media_type("a.toml"), "application/octet-stream");
        assert_eq!(media_type("no-extension"), "application/octet-stream");
    }
}

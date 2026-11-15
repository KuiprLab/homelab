# tiny-cdn

Small file host for uploading temporary files.

## Endpoints

| Method | Path | Auth | Result |
| --- | --- | --- | --- |
| `PUT` | `/upload/<name>` | signed | `200` and the new UUID |
| `GET` | `/list` | signed | `200` and a JSON array of live entries |
| `DELETE` | `/<uuid>` | signed | `200` |
| `GET` | `/<uuid>[/<filename>]` | none | `200` and the preview page for an unfurler, the file for a browser, `404` once expired |
| `GET` | `/<uuid>[/<filename>]?raw=1` | none | `200` and the file bytes inline, `404` once expired |
| `GET` | `/health` | none | `200` |
| `GET` | `/favicon.ico` | none | `204` |

`<name>` is percent-encoded in the path. Uploads are capped at 100 MiB. A file lives for one hour by default;

## Request signature

Uploading, listing, and deleting need to be authenticated. This happens by signing requests using the following headers:

| Header | Value |
| --- | --- |
| `X-Timestamp` | Unix seconds. Rejected when it differs from the server clock by more than 60 s. |
| `X-Nonce` | Random, single use. Replay within the 60 s window is rejected. |
| `X-Content-SHA256` | Lowercase hex SHA-256 of the request body. The empty body hashes to `e3b0c442…b855`. |
| `X-Signature` | Base64 of the SSH signature over the message below. |
| `X-Expire-Seconds` | Optional TTL. Absent means the default, and the message carries `-`. |

The signed message is six newline-separated fields with no trailing newline:

The signature is produced with namespace `cdn-upload`:

```
ssh-keygen -Y sign -f authorized.pub -n cdn-upload -
```

Signatures are checked before the body is read, and the body is then checked against
`X-Content-SHA256`, so a signed request cannot be replayed with a different payload.

## Link previews

The shared link serves an HTML page to unfurlers and the file to a browser, using
the `User-Agent` to detect  them. A user agent that contains `bot`, `crawler`, `spider`, `preview`,
`embedly`, `facebookexternalhit`, `whatsapp`, `slack`, `telegram`, `mastodon`, `cardyb`
or `skype` gets the html and everything else gets the file as an attachment.

`?raw=1` forces the bytes inline and skips the unfurler detection. Unfurlers read `og:title`, `og:description`,
`og:site_name` and `theme-color` from the page. The page is minimal and has no download link.

The byte response sets the content type from the file extension. It answers `HEAD` and
single byte ranges (`206` plus `Content-Range`) and sets `Cache-Control`. The
disposition follows the same rule: `?raw=1` and unfurlers get images and videos
`inline`, everything else gets `attachment`, so a click saves the file.

## Development

```
nix develop .#tiny-cdn
cargo test
cargo clippy
```


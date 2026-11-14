# tiny-cdn

File host for links that must be public but temporary. Uploads are authorized by an
SSH signature; downloads need only the UUID. Rust, built with Nix, run by podman on
sorbet behind pangolin at `cdn.ext.kuipr.de`.

## Layout

| File | Role |
| --- | --- |
| `flake-module.nix` | The only file import-tree picks up. Exposes the package, the dev shell, the vhost and the NixOS module. |
| `_package.nix` | How it is built. |
| `_module.nix` | How it is run on a host. |
| `src/main.rs` | HTTP routes and request verification. |
| `src/files_manager.rs` | Storage, expiry and the on-disk layout. |
| `scripts/upload.sh` | Reference client. |
| `authorized.pub` | The one key allowed to sign uploads. |

## Endpoints

| Method | Path | Auth | Result |
| --- | --- | --- | --- |
| `PUT` | `/upload/<name>` | signed | `200` and the new UUID |
| `GET` | `/list` | signed | `200` and a JSON array of live entries |
| `DELETE` | `/<uuid>` | signed | `200` |
| `GET` | `/<uuid>` | none | `200` and the file, `404` once expired |
| `GET` | `/health` | none | `200` |

Uploads are capped at 100 MiB. A file lives for one hour by default; `X-Expire-Seconds`
overrides that and is clamped to 30 days. Expired files are deleted when they are
requested, and a sweep every 300 s removes the rest.

## Request signature

Every signed request carries four headers, plus an optional fifth:

| Header | Value |
| --- | --- |
| `X-Timestamp` | Unix seconds. Rejected when it differs from the server clock by more than 60 s. |
| `X-Nonce` | Random, single use. Replay within the 60 s window is rejected. |
| `X-Content-SHA256` | Lowercase hex SHA-256 of the request body. The empty body hashes to `e3b0c442…b855`. |
| `X-Signature` | Base64 of the SSH signature over the message below. |
| `X-Expire-Seconds` | Optional TTL. Absent means the default, and the message carries `-`. |

The signed message is six newline-separated fields with no trailing newline:

```
<METHOD>
<path>
<X-Timestamp>
<X-Nonce>
<X-Content-SHA256>
<X-Expire-Seconds or ->
```

`<path>` is the request path without the query string, percent-encoded exactly as sent.
The signature is produced with namespace `cdn-upload`:

```
ssh-keygen -Y sign -f authorized.pub -n cdn-upload -
```

Signatures are checked before the body is read, and the body is then checked against
`X-Content-SHA256`, so a signed request cannot be replayed with a different payload.

## Client

```
scripts/upload.sh upload ./screenshot.png        # prints the UUID
scripts/upload.sh upload ./big.iso 86400         # one day
scripts/upload.sh list
scripts/upload.sh delete <uuid>
scripts/upload.sh get <uuid>
```

`BASE_URL` and `KEY` override the defaults. The private key is used through ssh-agent;
nothing reads it from disk.

## Development

```
nix develop .#tiny-cdn
cargo test
cargo clippy
```

The dev shell takes cargo and rustc from the same nixpkgs the package is built with, so
`cargo test` and `nix build .#tiny-cdn` cannot disagree about the toolchain.

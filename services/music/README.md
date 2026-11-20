# Last.fm migration

> [!WARNING]
> From 1st December, an API key will require Last.fm Pro.
> This applies to whoever owns the key in the app or service. If
> you use an app someone else built, you don’t need Pro,
> and the app keeps working while its developer is subscribed.

## Step 1

Affected:

| Service | Dependency | Consequence |
|---|---|---|
| Multi Scrobbler | last.fm source, own key | no input; its LB and Koito clients receive nothing |
| Navidrome | `ND_LASTFM_ENABLED`, `ND_LASTFM_APIKEY`, `ND_LASTFM_SECRET` | artist bios, similar artists and per-user scrobbling stop |
| lastfm-discord-now-playing | `LASTFM_API_KEY`, `LASTFM_USER` | fallback only; `MUSIC_SOURCE` starts with navidrome |
| Subtidal | `[lastfm]` in `secrets/sorbet/subtidal.toml` | Tidal scrobbles stop |
| Tidal app | built in, Tidal owns the key | nothing for us; it can only write to Last.fm |
| Aurral | none since 3.0.0 | nothing |

Not affected: Koito (no key, target only), beets (removed).

Home Assistant unverified: `secrets/sorbet/homeassistant/configuration` is encrypted.

## Step 2

ListenBrainz. It is the only protocol that all of them speak:

- Writers: Navidrome, Subtidal, Aurral, Multi Scrobbler.
- Reader: lastfm-discord-now-playing.
- Target: Koito, at `/apis/listenbrainz/1`.

Libre.fm is Multi Scrobbler only. Aurral dropped Last.fm in 3.0.0.

## Step 3

Migrate the history with Multi Scrobbler PR 792:
<https://github.com/FoxxMD/multi-scrobbler/pull/792>.

The image is pinned to `pr-792@sha256:97075e11...` in `multi-scrobbler.nix`. It is unmerged and it
runs five database migrations. Back up `/var/lib/multi-scrobbler` before the switch. A downgrade
needs that backup.

1. Import: create a job, import from the Last.fm source or a `lastfm.ghan.nl` file. This fills a
   mirror, one time range at a time, and skips ranges already covered.
2. Export: create a job from that mirror to the existing ListenBrainz client. Reuse the mirror to
   export again; plays the client already has are skipped.
3. Wait. The client sends one play at a time, about 1/s. Tens of thousands of plays take hours. The
   job is resumable.
4. Clean up the job and the mirror to reclaim the data directory.

Last.fm refuses plays older than about 14 days, so never export history back to Last.fm.

Then switch the services:

1. Navidrome: add the LB token per user, unlink Last.fm. Keep the metadata keys only if you want
   bios; they are a separate concern.
2. Subtidal: replace `[lastfm]` with `[listenbrainz] token`.
3. Aurral: connect ListenBrainz.
4. Multi Scrobbler: retires with its last.fm source.
5. Presence: `MUSIC_SOURCE=navidrome,listenbrainz`.
6. Koito: optional read-only mirror. It imports a ListenBrainz export. Not the sink.

One submitter per playback path. ListenBrainz drops a listen only on the same user, the same second
and the same MessyBrainz id. Two live submitters count twice.

The Tidal app cannot write to ListenBrainz. Use Subtidal, Pano Scrobbler or Web Scrobbler, or import
the app's Last.fm history in batches.

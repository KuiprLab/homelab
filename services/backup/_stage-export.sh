#!/usr/bin/env bash
set -euo pipefail

stage=/var/lib/backup-stage
navidrome_db=/var/lib/navidrome/navidrome.db
koito_db=/var/lib/koito/koito.db
aurral_dir=/media/data/aurral/config

rm -rf "$stage"
install -d -m 0700 "$stage/navidrome" "$stage/koito" "$stage/aurral" "$stage/manifest/playlists"

# VACUUM INTO folds the WAL in and yields a consistent copy, so -wal/-shm are never staged.
sqlite3 "$navidrome_db" "VACUUM INTO '$stage/navidrome/navidrome.db'"
sqlite3 "$koito_db" "VACUUM INTO '$stage/koito/koito.db'"
sqlite3 "$aurral_dir/aurral.db" "VACUUM INTO '$stage/aurral/aurral.db'"

navidrome="$stage/navidrome/navidrome.db"
aurral="$stage/aurral/aurral.db"

tracks=$(sqlite3 "$navidrome" "select count(*) from media_file")
if [ "$tracks" -eq 0 ]; then
  echo "navidrome.db staged zero tracks; refusing to write an empty manifest" >&2
  exit 1
fi

# Caches and queue rows rebuild on demand. jobs alone is 528 MB and changes nightly.
for table in \
  jobs job_locks job_schedules \
  metadata_response_cache metadata_request_state discovery_cache images_cache \
  deezer_mbid_cache musicbrainz_artist_mbid_cache \
  news_articles trending_charts trending_chart_days library_search_documents \
  sessions download_jobs download_provider_work download_cancellations \
  download_job_cancellations library_file_operations \
  weekly_flow_download_provider_work weekly_flow_download_job_cancellations \
  weekly_flow_download_cancellations; do
  if [ "$(sqlite3 "$aurral" "select count(*) from sqlite_master where type='table' and name='$table'")" != 0 ]; then
    sqlite3 "$aurral" "delete from \"$table\""
  fi
done

sqlite3 "$aurral" "VACUUM"
sqlite3 "$aurral" "PRAGMA quick_check" | grep -qx ok
if [ -z "$(sqlite3 "$aurral" "select value from settings where key='schemaVersion'")" ]; then
  echo "aurral backup lost settings.schemaVersion; it would be rejected on restore" >&2
  exit 1
fi

sqlite3 -json "$navidrome" "
  select path, title, album, artist, album_artist, disc_number, track_number, year,
         size, suffix, duration, bit_rate, genre,
         mbz_recording_id, mbz_release_track_id, mbz_album_id, mbz_artist_id
  from media_file
  order by album_artist, album, disc_number, track_number" >"$stage/manifest/tracks.json"

sqlite3 -csv -header "$navidrome" "
  select m.path, a.play_count, a.play_date, a.rating, a.rated_at, a.starred, a.starred_at, a.user_id
  from annotation a join media_file m on m.id = a.item_id
  where a.item_type = 'media_file'
  order by a.play_count desc" >"$stage/manifest/annotations-tracks.csv"

sqlite3 -csv -header "$navidrome" "
  select al.name, al.album_artist, al.mbz_album_id,
         a.play_count, a.play_date, a.rating, a.rated_at, a.starred, a.starred_at
  from annotation a join album al on al.id = a.item_id
  where a.item_type = 'album'
  order by a.play_count desc" >"$stage/manifest/annotations-albums.csv"

sqlite3 -csv -header "$navidrome" "
  select ar.name, ar.mbz_artist_id,
         a.play_count, a.play_date, a.rating, a.rated_at, a.starred, a.starred_at
  from annotation a join artist ar on ar.id = a.item_id
  where a.item_type = 'artist'
  order by a.play_count desc" >"$stage/manifest/annotations-artists.csv"

while IFS=$'\t' read -r playlist_id playlist_name; do
  safe_name=$(printf '%s' "$playlist_name" | tr -c 'A-Za-z0-9._ -' '_')
  {
    printf '#EXTM3U\n'
    sqlite3 "$navidrome" "
      select m.path
      from playlist_tracks pt join media_file m on m.id = pt.media_file_id
      where pt.playlist_id = '$playlist_id'
      order by pt.id"
  } >"$stage/manifest/playlists/${safe_name:-unnamed}.m3u8"
done < <(sqlite3 -separator $'\t' "$navidrome" "select id, name from playlist order by name")

playlist_count=$(find "$stage/manifest/playlists" -mindepth 1 -name '*.m3u8' | wc -l)
echo "staged $tracks tracks, $playlist_count playlists"

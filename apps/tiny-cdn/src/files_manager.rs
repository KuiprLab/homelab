use serde::{Deserialize, Serialize};
use std::io;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use uuid::Uuid;

const META_FILE: &str = ".meta.json";
const DEFAULT_TTL_SECS: u64 = 60 * 60;
const MAX_TTL_SECS: u64 = 60 * 60 * 24 * 30;
/// Uploads are staged under this prefix and renamed into place, so a directory named
/// like a uuid is always complete. Leftovers mean the process died mid-save.
const STAGING_PREFIX: &str = ".staging-";

#[derive(Debug, Serialize, Deserialize)]
pub struct Meta {
    pub name: String,
    pub uploader: String,
    pub created_at: u64,
    pub expires_at: u64,
}

#[derive(Debug, Serialize)]
pub struct FileEntry {
    pub uuid: String,
    #[serde(flatten)]
    pub meta: Meta,
}

pub struct FileManager {
    files_dir: PathBuf,
}

impl FileManager {
    pub fn new(files_dir: impl Into<PathBuf>) -> std::io::Result<Self> {
        let files_dir = files_dir.into();
        std::fs::create_dir_all(&files_dir)?;
        Ok(Self { files_dir })
    }

    pub fn reconcile(&self) -> std::io::Result<()> {
        let now = now_secs()?;
        for entry in std::fs::read_dir(&self.files_dir)? {
            let entry = entry?;
            if !entry.file_type()?.is_dir() {
                continue;
            }
            let uuid = entry.file_name().to_string_lossy().into_owned();

            if uuid.starts_with(STAGING_PREFIX) {
                println!("Removing abandoned upload: {uuid}");
                if let Err(e) = std::fs::remove_dir_all(entry.path()) {
                    eprintln!("failed to remove {uuid}: {e}");
                }
                continue;
            }

            match self.load_meta(&uuid) {
                Ok(meta) if meta.expires_at <= now => {
                    println!("Deleting expired file: {uuid}");
                    if let Err(e) = self.delete(&uuid) {
                        eprintln!("failed to delete {uuid}: {e}");
                    }
                }
                Ok(_) => {}
                Err(e) => eprintln!("skipping {uuid}: {e}"),
            }
        }
        Ok(())
    }

    pub fn list(&self) -> std::io::Result<Vec<FileEntry>> {
        let now = now_secs()?;
        Ok(self
            .scan()?
            .into_iter()
            .filter(|entry| entry.meta.expires_at > now)
            .collect())
    }

    fn scan(&self) -> std::io::Result<Vec<FileEntry>> {
        let mut files = Vec::new();
        for entry in std::fs::read_dir(&self.files_dir)? {
            let entry = entry?;
            if !entry.file_type()?.is_dir() {
                continue;
            }
            let uuid = entry.file_name().to_string_lossy().into_owned();
            if uuid.starts_with(STAGING_PREFIX) {
                continue;
            }
            match self.load_meta(&uuid) {
                Ok(meta) => files.push(FileEntry { uuid, meta }),
                Err(e) => eprintln!("skipping {uuid}: {e}"),
            }
        }
        Ok(files)
    }

    pub fn save(
        &self,
        original_name: &str,
        content: bytes::Bytes,
        uploader: &str,
        ttl_secs: Option<u64>,
    ) -> std::io::Result<String> {
        let name = Path::new(original_name)
            .file_name()
            .ok_or_else(|| io::Error::other("invalid file name"))?;
        let uuid = Uuid::new_v4();
        let staging = self.files_dir.join(format!("{STAGING_PREFIX}{uuid}"));
        let target = self.files_dir.join(uuid.to_string());

        std::fs::create_dir(&staging)?;
        let staged = (|| {
            std::fs::write(staging.join(name), &content)?;

            let now = now_secs()?;
            let ttl = ttl_secs.unwrap_or(DEFAULT_TTL_SECS).min(MAX_TTL_SECS);
            let meta = Meta {
                name: name.to_string_lossy().into_owned(),
                uploader: uploader.to_string(),
                created_at: now,
                expires_at: now.saturating_add(ttl),
            };
            let meta_json = serde_json::to_vec_pretty(&meta).map_err(io::Error::other)?;
            std::fs::write(staging.join(META_FILE), meta_json)?;

            std::fs::rename(&staging, &target)
        })();

        if staged.is_err() {
            let _ = std::fs::remove_dir_all(&staging);
        }
        staged.map(|()| uuid.to_string())
    }

    pub fn load_meta(&self, uuid: &str) -> std::io::Result<Meta> {
        let raw = std::fs::read(self.dir(uuid)?.join(META_FILE))?;
        serde_json::from_slice(&raw).map_err(io::Error::other)
    }

    /// Returns the metadata and the path of a file that is still alive,
    /// deleting it on the way out if it has expired.
    pub fn resolve(&self, uuid: &str) -> std::io::Result<(Meta, PathBuf)> {
        let meta = self.load_meta(uuid)?;
        if now_secs()? >= meta.expires_at {
            self.delete(uuid)?;
            return Err(io::Error::from(io::ErrorKind::NotFound));
        }

        let path = self.dir(uuid)?.join(&meta.name);
        Ok((meta, path))
    }

    pub fn delete(&self, uuid: &str) -> std::io::Result<()> {
        std::fs::remove_dir_all(self.dir(uuid)?)
    }

    /// Resolves a request-supplied uuid to its directory, rejecting anything
    /// that is not a canonical UUID so it cannot escape the files directory.
    fn dir(&self, uuid: &str) -> std::io::Result<PathBuf> {
        let parsed = Uuid::parse_str(uuid)
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid uuid"))?;
        Ok(self.files_dir.join(parsed.to_string()))
    }
}

fn now_secs() -> std::io::Result<u64> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(io::Error::other)?
        .as_secs())
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TempDir(PathBuf);

    impl TempDir {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("tiny-cdn-test-{}", Uuid::new_v4()));
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn manager() -> (TempDir, FileManager) {
        let dir = TempDir::new();
        let manager = FileManager::new(dir.0.join("files")).unwrap();
        (dir, manager)
    }

    fn body() -> bytes::Bytes {
        bytes::Bytes::from_static(b"hello")
    }

    #[test]
    fn save_uses_the_default_ttl() {
        let (_dir, manager) = manager();
        let uuid = manager.save("a.txt", body(), "SHA256:test", None).unwrap();
        let meta = manager.load_meta(&uuid).unwrap();
        assert_eq!(meta.expires_at - meta.created_at, DEFAULT_TTL_SECS);
    }

    #[test]
    fn save_clamps_an_oversized_ttl() {
        let (_dir, manager) = manager();
        let uuid = manager
            .save("a.txt", body(), "SHA256:test", Some(u64::MAX))
            .unwrap();
        let meta = manager.load_meta(&uuid).unwrap();
        assert_eq!(meta.expires_at - meta.created_at, MAX_TTL_SECS);
    }

    #[test]
    fn save_rejects_names_without_a_file_name() {
        let (_dir, manager) = manager();
        assert!(manager.save("..", body(), "u", None).is_err());
        assert!(manager.save("", body(), "u", None).is_err());
    }

    #[test]
    fn save_leaves_no_staging_directory() {
        let (dir, manager) = manager();
        manager.save("a.txt", body(), "u", None).unwrap();
        let leftovers = std::fs::read_dir(dir.0.join("files"))
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|name| name.starts_with(STAGING_PREFIX))
            .count();
        assert_eq!(leftovers, 0);
    }

    #[test]
    fn resolve_deletes_an_expired_file() {
        let (dir, manager) = manager();
        let uuid = manager.save("a.txt", body(), "u", Some(0)).unwrap();
        let err = manager.resolve(&uuid).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::NotFound);
        assert!(!dir.0.join("files").join(&uuid).exists());
    }

    #[test]
    fn list_hides_expired_files() {
        let (_dir, manager) = manager();
        manager.save("live.txt", body(), "u", Some(60)).unwrap();
        manager.save("dead.txt", body(), "u", Some(0)).unwrap();
        let listed = manager.list().unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].meta.name, "live.txt");
    }

    #[test]
    fn reconcile_removes_an_abandoned_staging_directory() {
        let (dir, manager) = manager();
        let abandoned = dir
            .0
            .join("files")
            .join(format!("{STAGING_PREFIX}{}", Uuid::new_v4()));
        std::fs::create_dir_all(&abandoned).unwrap();
        manager.reconcile().unwrap();
        assert!(!abandoned.exists());
    }

    #[test]
    fn dir_rejects_a_non_uuid() {
        let (_dir, manager) = manager();
        let err = manager.delete("../../etc").unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
    }
}

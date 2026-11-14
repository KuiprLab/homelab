use serde::{Deserialize, Serialize};
use std::io;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const META_FILE: &str = ".meta.json";
const MAX_FILE_AGE_SECS: u64 = 60 * 60; // 1 hour

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
        for entry in self.scan()? {
            if entry.meta.expires_at <= now {
                println!("Deleting expired file: {}", entry.uuid);
                if let Err(e) = self.delete(&entry.uuid) {
                    eprintln!("Failed to delete {}: {}", entry.uuid, e);
                }
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
        let uuid = uuid::Uuid::new_v4().to_string();
        let name = Path::new(original_name)
            .file_name()
            .ok_or_else(|| io::Error::other("invalid file name"))?;
        let dir = self.files_dir.join(&uuid);
        std::fs::create_dir_all(&dir)?;
        std::fs::write(dir.join(name), &content)?;

        let now = now_secs()?;
        let meta = Meta {
            name: name.to_string_lossy().into_owned(),
            uploader: uploader.to_string(),
            created_at: now,
            expires_at: now + ttl_secs.unwrap_or(MAX_FILE_AGE_SECS),
        };
        let meta_json = serde_json::to_vec_pretty(&meta).map_err(io::Error::other)?;
        std::fs::write(dir.join(META_FILE), meta_json)?;

        Ok(uuid)
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
        let parsed = uuid::Uuid::parse_str(uuid)
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

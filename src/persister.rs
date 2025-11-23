use std::fmt;
use std::fs::{self, OpenOptions, File, DirEntry};
use std::path::Path;
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::io::{self, ErrorKind};

use rand::{self, rngs::ThreadRng, distr::{SampleString, Alphanumeric}};
use memmap2::MmapMut;
use renamore::rename_exclusive;

use crate::funcs;
use crate::{log_call, log_err};
use crate::types::{StoreId, StoreIdRef, StoreIds, BlobId, BlobIdRef, BlobIds,
                   BlobFile, BlobStream, BlobSize, Status, Result, SaveStatus};


pub struct Persister {
    base_dir: Box<Path>,
    rng: ThreadRng,
}

impl fmt::Debug for Persister {
    fn fmt(&self, out: &mut fmt::Formatter) -> fmt::Result {
        out.debug_tuple("Persister")
           .field(&self.base_dir)
           .finish()
    }
}

macro_rules! error_to_status{($error:expr) => {
    match $error.kind() {
        ErrorKind::NotFound => Status::NotFound,
        ErrorKind::AlreadyExists => Status::Exists,
        _ => log_err!(map($error)),
    }
}}

impl Persister {
    pub fn create() -> Result<Persister> {
        let base_dir_str = funcs::env("BASE_DIR")?;
        let base_dir = Path::new(base_dir_str.as_ref());
        if !base_dir.is_dir() {
            eprintln!("Error: BASE_DIR={base_dir:?} is not a valid directory.");
            return Err(Status::InternalError);
        }
        Ok(Persister{
            base_dir: base_dir.into(),
            rng: rand::rng(),
        })
    }

    log_call!(
    pub fn store_list(&mut self) -> Result<StoreIds> {
        fn entry_to_name(entry_res: io::Result<DirEntry>) -> Result<StoreId> {
            let entry = log_err!(?entry_res);
            let name_result = entry.file_name().into_string();
            name_result.map_err(|name| {
                eprintln!("entry_to_name: non-unicode file name: {name:?}");
                Status::InternalError
            }).map(StoreId::from)
        }

        let dir_iter = log_err!(?fs::read_dir(&self.stores_path()));
        dir_iter.map(entry_to_name).collect()
    });

    log_call!(
    pub fn store_create(&self, store_id: StoreIdRef) -> Result<()> {
        let result = fs::create_dir(self.store_path(store_id));
        result.map_err(|error| match error.kind() {
            ErrorKind::AlreadyExists => Status::Exists,
            _ => log_err!(map(error)),
        })
    });

    log_call!(
    pub fn store_destroy(&self, store_id: StoreIdRef) -> Result<()> {
        let result = fs::remove_dir_all(self.store_path(store_id));
        result.map_err(|error| match error.kind() {
            ErrorKind::NotFound => Status::NotFound,
            _ => log_err!(map(error)),
        })
    });

    log_call!(
    pub fn blob_list(&self, store_id: StoreIdRef) -> Result<BlobIds> {
        fn entry_to_hash(entry_res: io::Result<DirEntry>) -> Result<BlobId> {
            let entry = log_err!(?entry_res);
            funcs::str_to_hash(entry.file_name().as_bytes())
        }

        let result = fs::read_dir(self.store_path(store_id));
        result.map_err(|error| match error.kind() {
            ErrorKind::NotFound => Status::NotFound,
            _ => log_err!(map(error)),
        }).and_then(|store_iter|
            store_iter.map(entry_to_hash).collect()
        )
    });

    log_call!(
    pub fn blob_info(&self, store_id: StoreIdRef, blob_id: BlobIdRef)
            -> Result<BlobSize> {
        let file = self.blob_open(store_id, blob_id)?;
        let metadata = log_err!(?file.metadata());
        Ok(metadata.len())
    });

    log_call!(
    pub fn blob_load(&self, store_id: StoreIdRef, blob_id: BlobIdRef)
            -> Result<BlobFile> {
        self.blob_open(store_id, blob_id)
    });

    log_call!(
    pub fn blob_save(&mut self, store_id: StoreIdRef, blob: &mut BlobStream)
            -> Result<(SaveStatus, BlobId)> {
        let mut tmp_file = TmpFile::create(self.tmp_blob_path(),
                                           blob.bytes_remain)?;
        let mut buf = log_err!(?unsafe{MmapMut::map_mut(&tmp_file.file)});
        let blob_id = funcs::hash_copy(blob, &mut *buf)?;
        let dst_path = self.blob_path(store_id, &blob_id);
        let result = tmp_file.link(&dst_path);
        match result {
            Ok(()) => Ok((SaveStatus::Created, blob_id)),
            Err(Status::Exists) => Ok((SaveStatus::Exists, blob_id)),
            Err(status) => Err(status),
        }
    });

    log_call!(
    pub fn blob_delete(&self, store_id: StoreIdRef, blob_id: BlobIdRef)
            -> Result<()> {
        let result = fs::remove_file(self.blob_path(store_id, blob_id));
        result.map_err(|error| match error.kind() {
            ErrorKind::NotFound => Status::NotFound,
            _ => log_err!(map(error)),
        })
    });

    fn blob_open(&self, store_id: StoreIdRef, blob_id: BlobIdRef)
            -> Result<File> {
        File::open(self.blob_path(store_id, blob_id))
            .map_err(|error| error_to_status!(error))
    }

    fn tmp_blob_path(&mut self) -> Box<Path> {
        const SIZE: usize = 16;
        let name = Alphanumeric.sample_string(&mut self.rng, SIZE);
        self.base_dir.join("tmp").join(name).into()
    }

    fn stores_path(&self) -> Box<Path> {
        self.base_dir.join("stores").into()
    }

    fn store_path(&self, store_id: StoreIdRef) -> Box<Path> {
        self.stores_path().join(store_id).into()
    }

    fn blob_path(&self, store_id: StoreIdRef, blob_id: BlobIdRef) -> Box<Path> {
        let blob_id_str = funcs::hash_to_str(blob_id);
        let file_name = OsStr::from_bytes(&blob_id_str);
        self.store_path(store_id).join(file_name).into()
    }
}


struct TmpFile {
    file: File,
    tmp_path: Option<Box<Path>>,
}

impl TmpFile {
    fn create(path: Box<Path>, size: usize) -> Result<Self> {
        let file = log_err!(?o_rw_excl().open(&path));
        let size_u64 = log_err!(?u64::try_from(size));
        log_err!(?file.set_len(size_u64));
        Ok(Self{file, tmp_path: Some(path)})
    }

    fn link(&mut self, dst_path: &Path) -> Result<()> {
        match &self.tmp_path {
            Some(src_path) => {
                rename_exclusive(src_path, dst_path)
                    .map_err(|error| error_to_status!(error))?;
                self.tmp_path = None;
                Ok(())
            }
            None => {
                eprintln!("TmpFile::link: already linked.");
                Err(Status::InternalError)
            }
        }
    }
}

impl Drop for TmpFile {
    fn drop(&mut self) {
        if let Some(path) = &self.tmp_path {
            let result = fs::remove_file(path);
            if let Err(error) = result {
                eprintln!("TmpFile::drop: failed to remove {path:?}: \
                           {error:?}: {error}");
            }
        }
    }
}

fn o_rw_excl() -> OpenOptions {
    fs::OpenOptions::new().read(true).write(true).create_new(true).clone()
}

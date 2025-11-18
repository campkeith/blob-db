use std::fmt;
use std::fs::{self, File, OpenOptions, DirEntry};
use std::path::Path;
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::io::{self, Read, Write, ErrorKind};

use crate::funcs;
use crate::{log_ret_err, log_err_ret_val, log_err, map_ret_err, log_call};
use crate::types::{StoreId, StoreIdRef, StoreIds, BlobId, BlobIdRef, BlobIds, Blob,
                   Status, Result};


/* Apparently setting option bits is so complicated
   that it requires a dedicated factory system...
*/
fn read_only() -> OpenOptions {
    File::options().read(true).clone()
}

fn create_exclusive() -> OpenOptions {
    File::options().write(true).create_new(true).clone()
}

pub struct Persister {
    base_dir: Box<Path>,
}

impl fmt::Debug for Persister {
    fn fmt(&self, out: &mut fmt::Formatter) -> fmt::Result {
        out.debug_tuple("Persister")
           .field(&self.base_dir)
           .finish()
    }
}

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
        })
    }

    pub fn store_list(&self) -> Result<StoreIds> {
        fn entry_to_name(entry_res: io::Result<DirEntry>) -> Result<StoreId> {
            let entry = log_ret_err!(entry_res);
            match entry.file_name().into_string() {
                Err(name) => {
                    eprintln!("entry_to_name: non-unicode file name: {name:?}");
                    Err(Status::InternalError)
                }
                Ok(name) => Ok(name.into()),
            }
        }

        log_call!(self.store_list() -> {
            let dir_iter = log_ret_err!(fs::read_dir(&self.base_dir));
            dir_iter.map(entry_to_name).collect()
        })
    }

    pub fn store_create(&self, store_id: StoreIdRef) -> Status {
        log_call!(self.store_create(store_id) -> {
            let result = fs::create_dir(self.store_path(store_id));
            map_ret_err!(result, ErrorKind::AlreadyExists, Status::AlreadyExists);
            log_err_ret_val!(result, Status::InternalError);
            Status::Okay
        })
    }

    pub fn store_destroy(&self, store_id: StoreIdRef) -> Status {
        log_call!(self.store_destroy(store_id) -> {
            let result = fs::remove_dir_all(self.store_path(store_id));
            map_ret_err!(result, ErrorKind::NotFound, Status::NotFound);
            log_err_ret_val!(result, Status::InternalError);
            Status::Okay
        })
    }

    pub fn blob_list(&self, store_id: StoreIdRef) -> Result<BlobIds> {
        fn entry_to_hash(entry_res: io::Result<DirEntry>) -> Result<BlobId> {
            let entry = log_ret_err!(entry_res);
            funcs::str_to_hash(entry.file_name().as_bytes())
        }

        log_call!(self.blob_list(store_id) -> {
            let store_iter = fs::read_dir(self.store_path(store_id));
            map_ret_err!(store_iter, ErrorKind::NotFound, Err(Status::NotFound));
            log_ret_err!(store_iter).map(entry_to_hash).collect()
        })
    }

    pub fn blob_info(&self, store_id: StoreIdRef, blob_id: BlobIdRef) -> Status {
        log_call!(self.blob_info(store_id, blob_id) -> {
            match self.blob_open(store_id, blob_id, read_only()) {
                Err(status) => status,
                Ok(_) => Status::Okay,
            }
        })
    }

    pub fn blob_load(&self, store_id: StoreIdRef, blob_id: BlobIdRef) -> Result<Blob> {
        log_call!(self.blob_load(store_id, blob_id) -> {
            let mut file = self.blob_open(store_id, blob_id, read_only())?;
            let metadata = log_ret_err!(file.metadata());
            let size = log_ret_err!(usize::try_from(metadata.len()));
            let buf_uninit = Box::new_uninit_slice(size);
            let mut buffer = unsafe {buf_uninit.assume_init()};
            log_ret_err!(file.read_exact(&mut buffer));
            Ok(Blob(buffer))
        })
    }

    pub fn blob_save(&self, store_id: StoreIdRef, blob: & Blob) -> (Status, BlobId) {
        let Blob(buf) = blob;
        let save = |mut file: File| {
            log_err_ret_val!(file.write_all(buf), Status::InternalError);
            Status::Okay
        };

        log_call!(self.blob_save(store_id, blob) -> {
            let blob_id = funcs::blob_hash(buf);
            let result = self.blob_open(store_id, &blob_id, create_exclusive());
            match result {
                Err(status) => (status, blob_id),
                Ok(file) => (save(file), blob_id),
            }
        })
    }

    pub fn blob_delete(&self, store_id: StoreIdRef, blob_id: BlobIdRef) -> Status {
        log_call!(self.blob_delete(store_id, blob_id) -> {
            let result = fs::remove_file(self.blob_path(store_id, blob_id));
            map_ret_err!(result, ErrorKind::NotFound, Status::NotFound);
            log_err_ret_val!(result, Status::InternalError);
            Status::Okay
        })
    }


    fn blob_open(&self, store_id: StoreIdRef, blob_id: BlobIdRef, options: OpenOptions)
            -> Result<File> {
        let result = options.open(self.blob_path(store_id, blob_id));
        result.or_else(|error| match error.kind() {
            ErrorKind::NotFound => Err(Status::NotFound),
            ErrorKind::AlreadyExists => Err(Status::AlreadyExists),
            _ => {
                log_err!(error);
                Err(Status::InternalError)
            },
        })
    }

    fn store_path(&self, store_id: StoreIdRef) -> Box<Path> {
        self.base_dir.join(store_id).into()
    }

    fn blob_path(&self, store_id: StoreIdRef, blob_id: BlobIdRef) -> Box<Path> {
        let blob_id_str = funcs::hash_to_str(blob_id);
        let file_name = OsStr::from_bytes(&blob_id_str);
        self.store_path(store_id).join(file_name).into()
    }
}

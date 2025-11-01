use std::env;
use std::ffi::OsStr;

use sha2::{Sha256, Digest};

use crate::types::{Hash, BlobRef, Status, Result};


pub fn env(name_in: impl AsRef<OsStr>) -> Result<Box<str>> {
    let name = name_in.as_ref();
    match env::var(name) {
        Ok(val) => Ok(val.into_boxed_str()),
        Err(_error) => {
            let name_str = name.to_string_lossy();
            eprintln!("Missing required environment variable: {name_str}");
            Err(Status::InternalError)
        },
    }
}

pub fn blob_hash(blob: BlobRef) -> Hash {
    Sha256::digest(blob).into()
}

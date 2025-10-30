use std::fs;
use std::fs::{File, OpenOptions, DirEntry};
use std::path::Path;
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::io;
use std::io::{Read, Write, ErrorKind};

use sha2::{Sha256, Digest};

use crate::{log_ret_err, log_err_ret_val, log_err, map_ret_err};
use crate::types::{Status, Result, Name, Names, Hash, Hashes, HashStr, Blob};


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

impl Persister {
    pub fn store_list(&self) -> Result<Names> {
        fn entry_to_name(entry_res: io::Result<DirEntry>) -> Result<Name> {
            let entry = log_ret_err!(entry_res);
            match entry.file_name().into_string() {
                Err(name) => {
                    eprintln!("entry_to_name: non-unicode file name: {name:?}");
                    Err(Status::InternalError)
                }
                Ok(name) => Ok(name.into_boxed_str()),
            }
        }

        let dir_iter = log_ret_err!(fs::read_dir(&self.base_dir));
        dir_iter.map(entry_to_name).collect()
    }

    pub fn store_create(&self, store_name: Name) -> Status {
        let result = fs::create_dir(self.store_path(store_name));
        map_ret_err!(result, ErrorKind::AlreadyExists, Status::AlreadyExists);
        log_err_ret_val!(result, Status::InternalError);
        Status::Okay
    }

    pub fn store_destroy(&self, store_name: Name) -> Status {
        let result = fs::remove_dir_all(self.store_path(store_name));
        map_ret_err!(result, ErrorKind::NotFound, Status::NotFound);
        log_err_ret_val!(result, Status::InternalError);
        Status::Okay
    }

    pub fn blob_hash(&self, blob: & Blob) -> Hash {
        Sha256::digest(blob).into()
    }


    pub fn blob_list(&self, store_name: Name) -> Result<Hashes> {
        fn entry_to_hash(entry_res: io::Result<DirEntry>) -> Result<Hash> {
            let entry = log_ret_err!(entry_res);
            str_to_hash(entry.file_name().as_bytes())
        }

        let store_iter = fs::read_dir(self.store_path(store_name));
        map_ret_err!(store_iter, ErrorKind::NotFound, Err(Status::NotFound));
        log_ret_err!(store_iter).map(entry_to_hash).collect()
    }

    pub fn blob_info(&self, store_name: Name, hash: Hash) -> Status {
        match self.blob_open(store_name, hash, read_only()) {
            Err(status) => status,
            Ok(_) => Status::Okay,
        }
    }

    pub fn blob_load(&self, store_name: Name, hash: Hash) -> Result<Blob> {
        let mut file = self.blob_open(store_name, hash, read_only())?;
        let metadata = log_ret_err!(file.metadata());
        let size = log_ret_err!(usize::try_from(metadata.len()));
        let buf_uninit = Box::new_uninit_slice(size);
        let mut buffer = unsafe {buf_uninit.assume_init()};
        log_ret_err!(file.read_exact(&mut buffer));
        Ok(buffer)
    }

    pub fn blob_save(&self, store_name: Name, blob: & Blob) -> (Status, Hash) {
        let save = |mut file: File| {
            log_err_ret_val!(file.write_all(blob), Status::InternalError);
            Status::Okay
        };

        let hash = self.blob_hash(blob);
        let result = self.blob_open(store_name, hash, create_exclusive());
        match result {
            Err(status) => (status, hash),
            Ok(file) => (save(file), hash),
        }
    }

    pub fn blob_delete(&self, store_name: Name, hash: Hash) -> Status {
        let result = fs::remove_file(self.blob_path(store_name, hash));
        map_ret_err!(result, ErrorKind::NotFound, Status::NotFound);
        log_err_ret_val!(result, Status::InternalError);
        Status::Okay
    }


    fn blob_open(&self, store_name: Name, hash: Hash, options: OpenOptions)
            -> Result<File> {
        let result = options.open(self.blob_path(store_name, hash));
        result.or_else(|error| match error.kind() {
            ErrorKind::NotFound => Err(Status::NotFound),
            ErrorKind::AlreadyExists => Err(Status::AlreadyExists),
            _ => {
                log_err!(error);
                Err(Status::InternalError)
            },
        })
    }

    fn store_path(&self, store_name: Name) -> Box<Path> {
        self.base_dir.join(String::from(store_name)).into_boxed_path()
    }

    fn blob_path(&self, store_name: Name, hash: Hash) -> Box<Path> {
        let hash_str = hash_to_str(hash);
        let file_name = OsStr::from_bytes(&hash_str);
        self.store_path(store_name).join(file_name).into_boxed_path()
    }
}

fn hash_to_str(hash: Hash) -> HashStr {
    fn byte_to_hex(byte: u8) -> [u8; 2] {
        [nibble_to_hex_digit(byte >> 4), nibble_to_hex_digit(byte & 0xf)]
    }

    fn nibble_to_hex_digit(nibble: u8) -> u8 {
        match nibble {
            0..10 => nibble + b'0',
            10..16 => nibble - 10 + b'a',
            _ => panic!("nibble_to_hex_digit: invalid nibble: {nibble}"),
        }
    }

    let mut hash_str = [0u8; 64];
    for index in 0..32 {
        [hash_str[2*index], hash_str[2*index + 1]] = byte_to_hex(hash[index]);
    }
    hash_str
}

fn str_to_hash(string: &[u8]) -> Result<Hash> {
    fn hex_to_byte(hex: [u8; 2]) -> Result<u8> {
        let [hi, lo] = hex;
        let byte = hex_digit_to_nibble(hi)? << 4 | hex_digit_to_nibble(lo)?;
        Ok(byte)
    }

    fn hex_digit_to_nibble(digit: u8) -> Result<u8> {
        match digit {
            b'0'..=b'9' => Ok(digit - b'0'),
            b'a'..=b'f' => Ok(digit - b'a' + 10),
            _ => {
                eprintln!("hex_digit_to_nibble: invalid hex digit '{digit}'");
                Err(Status::InternalError)
            },
        }
    }

    let hash_str = log_ret_err!(HashStr::try_from(string));
    let mut hash = [0u8; 32];
    for index in 0..32 {
        hash[index] = hex_to_byte([hash_str[2*index], hash_str[2*index + 1]])?;
    }
    Ok(hash)
}

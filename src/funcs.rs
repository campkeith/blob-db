use std::mem;
use std::env;
use std::ffi::OsStr;

use sha2::{Sha256, Digest};

use crate::types::{BlobId, BlobIdStr, BlobIdRef, BlobRef, Status, Result};
use crate::{log_err, log_ret_err, log_err_ret_val};


pub fn env(name_in: impl AsRef<OsStr>) -> Result<Box<str>> {
    let name = name_in.as_ref();
    match env::var(name) {
        Ok(val) => Ok(val.into()),
        Err(_error) => {
            let name_str = name.to_string_lossy();
            eprintln!("Missing required environment variable: {name_str}");
            Err(Status::InternalError)
        },
    }
}

pub fn blob_hash(blob: BlobRef) -> BlobId {
    BlobId(Sha256::digest(blob).into())
}

pub const fn code8(bytes: & [u8; 8]) -> u64 {
    u64::from_le_bytes(*bytes)
}

pub fn hash_to_str(blob_id: BlobIdRef) -> BlobIdStr {
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

    let BlobId(hash) = blob_id;
    unsafe {mem::transmute(hash.map(byte_to_hex))}
}

pub fn str_to_hash(string: &[u8]) -> Result<BlobId> {
    fn hex_to_byte([hi, lo]: [u8; 2]) -> Result<u8> {
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
    let hash_str = log_ret_err!(BlobIdStr::try_from(string));
    let hash_str_chunks: [[u8; 2]; _] = unsafe {mem::transmute(hash_str)};
    let hash = hash_str_chunks.try_map(hex_to_byte)?;
    Ok(BlobId(hash))
}

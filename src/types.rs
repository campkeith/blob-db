use std::result;

use num_enum::{TryFromPrimitive, IntoPrimitive};

use crate::code8;


pub enum Request {
    StoreList(),
    StoreCreate(StoreName),
    StoreDestroy(StoreName),
    BlobHash(Blob),

    BlobList(StoreName),
    BlobInfo(StoreName, Hash),
    BlobLoad(StoreName, Hash),
    BlobSave(StoreName, Blob),
    BlobDelete(StoreName, Hash),
}
type StoreName = Name;

#[derive(Debug)]
pub enum Response {
    Status(Status),
    StoreList(Names),
    BlobHash(Hash),
    BlobList(Hashes),
    BlobLoad(Blob),
    BlobSave((Status, Hash)),
}

#[repr(u64)]
#[derive(Debug, Copy, Clone, TryFromPrimitive, IntoPrimitive)]
pub enum Status {
    Okay = code8!(b"okay\0\0\0\0"),
    NotFound = code8!(b"notfound"),
    AlreadyExists = code8!(b"itexists"),
    BadArgument = code8!(b"badarg\0\0"),
    NoSpace = code8!(b"nospace\0"),
    InternalError = code8!(b"internal"),
}

pub type Name = Box<str>;
pub type Names = Box<[Name]>;
pub type Hash = [u8; 32];
pub type Hashes = Box<[Hash]>;
pub type HashStr = [u8; 64];
pub type Blob = Box<[u8]>;

pub type Code = u64;
pub type Result<Val> = result::Result<Val, Status>;

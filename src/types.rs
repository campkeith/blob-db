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

pub enum Response {
    Status(Status),
    StoreList(Names),
    BlobHash(Hash),
    BlobList(Hashes),
    BlobLoad(Blob),
    BlobSave(Status, Hash),
}

#[repr(u64)]
#[derive(TryFromPrimitive, IntoPrimitive)]
pub enum Status {
    Okay = code8!(b"okay\0\0\0\0"),
    NotFound = code8!(b"notfound"),
    AlreadyExists = code8!(b"itexists"),
    InvalidArgument = code8!(b"badarg\0\0"),
    NoSpace = code8!(b"nospace\0"),
    InternalError = code8!(b"internal"),
}

pub type Name = Box<str>;
pub type Names = Box<[Name]>;
pub type Hash = [u8; 32];
pub type Hashes = Box<[Hash]>;
pub type HashStr = [u8; 64];
pub type Blob = Box<[u8]>;

pub type Result<Val> = result::Result<Val, Status>;

use std::result;

use crate::funcs::code8;
use num_enum::{TryFromPrimitive, IntoPrimitive};


#[derive(Debug)]
pub enum Request {
    StoreList(),
    StoreCreate(StoreId),
    StoreDestroy(StoreId),
    BlobHash(Blob),

    BlobList(StoreId),
    BlobInfo(StoreId, BlobId),
    BlobLoad(StoreId, BlobId),
    BlobSave(StoreId, Blob),
    BlobDelete(StoreId, BlobId),
    Bye,
}

pub enum RequestRef<'a> {
    StoreList(),
    StoreCreate(StoreIdRef<'a>),
    StoreDestroy(StoreIdRef<'a>),
    BlobHash(BlobRef<'a>),

    BlobList(StoreIdRef<'a>),
    BlobInfo(StoreIdRef<'a>, BlobIdRef<'a>),
    BlobLoad(StoreIdRef<'a>, BlobIdRef<'a>),
    BlobSave(StoreIdRef<'a>, BlobRef<'a>),
    BlobDelete(StoreIdRef<'a>, BlobIdRef<'a>),
    Bye,
}

#[derive(Debug)]
pub enum Response {
    Status(Status),
    StoreList(StoreIds),
    BlobHash(BlobId),
    BlobList(BlobIds),
    BlobLoad(Blob),
    BlobSave((SaveStatus, BlobId)),
}

#[repr(u64)]
#[derive(Debug, Copy, Clone, PartialEq, TryFromPrimitive, IntoPrimitive)]
pub enum Status {
    Okay = code8(b"okaydoke"),
    NotFound = code8(b"notfound"),
    AlreadyExists = code8(b"itexists"),
    BadArgument = code8(b"invalarg"),
    NoSpace = code8(b"no-space"),
    InternalError = code8(b"internal"),
}

#[repr(u64)]
#[derive(Debug, Copy, Clone, PartialEq, TryFromPrimitive, IntoPrimitive)]
pub enum SaveStatus {
    Created = Status::Okay as u64,
    AlreadyExists = Status::AlreadyExists as u64,
}

pub type StoreId = Box<str>;
pub type StoreIds = Box<[StoreId]>;
#[derive(Copy, Clone, Eq, PartialEq, Hash)]
pub struct BlobId(pub [u8; 32]);
pub type BlobIdStr = [u8; 64];
pub type BlobIds = Box<[BlobId]>;
#[derive(Clone, PartialEq)]
pub struct Blob(pub Box<[u8]>);

pub type StoreIdRef<'a> = &'a str;
pub type StoreIdsRef<'a> = &'a [StoreId];
pub type BlobIdRef<'a> = &'a BlobId;
pub type BlobIdsRef<'a> = &'a [BlobId];
pub type BlobRef<'a> = &'a [u8];

pub type Code = u64;
pub type Result<Val> = result::Result<Val, Status>;


impl AsRef<[u8]> for Blob {
    fn as_ref(&self) -> &[u8] {
        let Blob(buf) = self;
        buf.as_ref()
    }
}

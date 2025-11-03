use std::result;

use num_enum::{TryFromPrimitive, IntoPrimitive};

use crate::code8;


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
    BlobSave((Status, BlobId)),
}

#[repr(u64)]
#[derive(Debug, Copy, Clone, PartialEq, TryFromPrimitive, IntoPrimitive)]
pub enum Status {
    Okay = code8!(b"okay\0\0\0\0"),
    NotFound = code8!(b"notfound"),
    AlreadyExists = code8!(b"itexists"),
    BadArgument = code8!(b"badarg\0\0"),
    NoSpace = code8!(b"nospace\0"),
    InternalError = code8!(b"internal"),
}

pub type StoreId = Box<str>;
pub type StoreIds = Box<[StoreId]>;
pub type BlobId = [u8; 32];
pub type BlobIds = Box<[BlobId]>;
pub type Blob = Box<[u8]>;

pub type StoreIdRef<'a> = &'a str;
pub type StoreIdsRef<'a> = &'a [StoreId];
pub type BlobIdRef<'a> = &'a BlobId;
pub type BlobIdsRef<'a> = &'a [BlobId];
pub type BlobRef<'a> = &'a [u8];

pub type Code = u64;
pub type Result<Val> = result::Result<Val, Status>;

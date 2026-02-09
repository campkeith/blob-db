use std::result;
use std::fs::File;
use std::io::Read;
use std::fmt::Debug;

use crate::funcs::code8;
use num_enum::{TryFromPrimitive, IntoPrimitive};


pub enum RequestOut<'a> {
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
pub enum RequestIn<'a> {
    StoreList(),
    StoreCreate(StoreId),
    StoreDestroy(StoreId),
    BlobHash(BlobStream<'a>),

    BlobList(StoreId),
    BlobInfo(StoreId, BlobId),
    BlobLoad(StoreId, BlobId),
    BlobSave(StoreId, BlobStream<'a>),
    BlobDelete(StoreId, BlobId),
    Bye,
}

#[derive(Debug)]
pub enum ResponseOut {
    Status(Status),
    StoreList(StoreIds),
    BlobHash(BlobId),
    BlobList(BlobIds),
    BlobInfo(BlobSize),
    BlobLoad(BlobFile),
    BlobSave((SaveStatus, BlobId)),
}

#[derive(Debug)]
pub enum ResponseIn<'a> {
    Status(Status),
    StoreList(StoreIds),
    BlobHash(BlobId),
    BlobList(BlobIds),
    BlobInfo(BlobSize),
    BlobLoad(BlobStream<'a>),
    BlobSave((SaveStatus, BlobId)),
}

#[repr(u64)]
#[derive(Debug, Copy, Clone, PartialEq, TryFromPrimitive, IntoPrimitive)]
pub enum Status {
    Okay = code8(b"okaydoke"),
    Exists = code8(b"itexists"),
    NotFound = code8(b"notfound"),
    NoSpace = code8(b"no-space"),
    BadArgument = code8(b"invalarg"),
    InternalError = code8(b"internal"),
}

#[repr(u64)]
#[derive(Debug, Copy, Clone, PartialEq, TryFromPrimitive, IntoPrimitive)]
pub enum SaveStatus {
    Created = Status::Okay as Code,
    Exists = Status::Exists as Code,
}


pub type StoreId = Box<str>;
pub type StoreIds = Box<[StoreId]>;
#[derive(Copy, Clone, Eq, PartialEq, Hash)]
pub struct BlobId(pub [u8; 32]);
pub type BlobIdStr = [u8; 64];
pub type BlobIds = Box<[BlobId]>;
pub type BlobFile = File;
pub struct BlobStream<'a> {
    pub bytes_remain: usize,
    pub stream: &'a mut dyn Read,
}

pub type StoreIdRef<'a> = &'a str;
pub type BlobIdRef<'a> = &'a BlobId;
pub type BlobRef<'a> = &'a [u8];

pub type Code = u64;
pub type BlobSize = u64;
pub type Result<Val> = result::Result<Val, Status>;

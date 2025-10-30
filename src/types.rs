use std::result;

use num_enum::{TryFromPrimitive, IntoPrimitive};

use crate::code8;


pub enum Request {
    StoreList(),
    StoreCreate(Name),
    StoreDestroy(Name),
    BlobHash(Blob),

    BlobList(Name),
    BlobInfo(Name, Hash),
    BlobLoad(Name, Hash),
    BlobSave(Name, Blob),
    BlobDelete(Name, Hash),
}

pub enum RequestRef<'a> {
    StoreList(),
    StoreCreate(NameRef<'a>),
    StoreDestroy(NameRef<'a>),
    BlobHash(BlobRef<'a>),

    BlobList(NameRef<'a>),
    BlobInfo(NameRef<'a>, HashRef<'a>),
    BlobLoad(NameRef<'a>, HashRef<'a>),
    BlobSave(NameRef<'a>, BlobRef<'a>),
    BlobDelete(NameRef<'a>, HashRef<'a>),
}

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
#[derive(Debug, Copy, Clone, PartialEq, TryFromPrimitive, IntoPrimitive)]
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
pub type Blob = Box<[u8]>;

pub type NameRef<'a> = &'a str;
pub type NamesRef<'a> = &'a [Name];
pub type HashRef<'a> = &'a Hash;
pub type HashesRef<'a> = &'a [Hash];
pub type BlobRef<'a> = &'a [u8];

pub type Code = u64;
pub type Result<Val> = result::Result<Val, Status>;

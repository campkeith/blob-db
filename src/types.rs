pub use num_enum::TryFromPrimitive;

#[macro_export]
macro_rules! code8 {
    ($byte_string: expr) => {u64::from_le_bytes(*$byte_string)}
}

pub type Name = Box<str>;
pub type StoreName = Name;
pub type Blob = Box<[u8]>;
pub type Hash = [u8; 32];
pub type Hashes = Box<[Hash]>;

#[derive(TryFromPrimitive)]
#[repr(u64)]
pub enum Status {
    Okay = code8!(b"okay\0\0\0\0"),
    NotFound = code8!(b"notfound"),
    AlreadyExists = code8!(b"itexists"),
    InvalidArgument = code8!(b"badarg\0\0"),
    NoSpace = code8!(b"nospace\0"),
}

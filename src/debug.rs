use std::io;
use std::net::SocketAddr;
use std::fmt::{self, Debug, Formatter};

use crate::types::{BlobId, BlobStream};
use crate::funcs;


impl Debug for BlobId {
    fn fmt(&self, out: &mut Formatter<'_>) -> fmt::Result {
        let id_str = funcs::hash_to_str(self);
        out.write_str(unsafe{str::from_utf8_unchecked(&id_str)})
    }
}

impl Debug for BlobStream<'_> {
    fn fmt(&self, out: &mut Formatter<'_>) -> fmt::Result {
        write!(out, "BlobStream{{size={}}}", self.bytes_remain)
    }
}

pub fn format_addr(result: io::Result<SocketAddr>) -> String {
    match result {
        Ok(addr) => format!("{}", addr),
        Err(_) => format!("???"),
    }
}

use std::io;
use std::net::SocketAddr;
use std::fmt::{self, Debug, Formatter};
use std::ascii::escape_default;

use crate::types::{BlobId, Blob};
use crate::funcs;


impl Debug for BlobId {
    fn fmt(&self, out: &mut Formatter<'_>) -> fmt::Result {
        let id_str = funcs::hash_to_str(self);
        out.write_str(unsafe{str::from_utf8_unchecked(&id_str)})
    }
}

impl Debug for Blob {
    fn fmt(&self, out: &mut Formatter<'_>) -> fmt::Result {
        const MAX_SIZE: usize = 16;
        let Blob(buf) = self;
        let size = buf.len();
        if size > MAX_SIZE {
            write!(out, "\"{}..[{}]", format_buf(&buf[0..MAX_SIZE]), size)
        } else {
            write!(out, "\"{}\"[{}]", format_buf(buf), size)
        }
    }
}

fn format_buf(buf: &[u8]) -> Box<str> {
    let format: Box<_> = buf.iter().cloned().map(escape_default)
                            .flatten().collect();
    unsafe {str::from_utf8_unchecked(&format)}.into()
}

pub fn format_addr(result: io::Result<SocketAddr>) -> String {
    match result {
        Ok(addr) => format!("{}", addr),
        Err(_) => format!("???"),
    }
}

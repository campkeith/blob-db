use std::ascii::escape_default;

use crate::types::{StoreId, StoreIds, BlobId, BlobIds, Blob, BlobRef,
                   Result, Status};
use crate::funcs;


pub trait Trace {
    fn trace(&self) -> String;
}

impl Trace for str {
    fn trace(&self) -> String {
        format!("{self:?}")
    }
}

impl Trace for StoreId {
    fn trace(&self) -> String {
        self.as_ref().trace()
    }
}

impl Trace for StoreIds {
    fn trace(&self) -> String {
        let id_strs: Vec<_> = self.into_iter().map(StoreId::trace).collect();
        format!("[{}]", id_strs.join(", "))
    }
}

impl Trace for BlobId {
    fn trace(&self) -> String {
        let id_str = funcs::hash_to_str(&self);
        unsafe {str::from_utf8_unchecked(&id_str).into()}
    }
}

impl Trace for BlobIds {
    fn trace(&self) -> String {
        let id_strs: Vec<_> = self.into_iter().map(BlobId::trace).collect();
        format!("[{}]", id_strs.join(", "))
    }
}

impl Trace for Blob {
    fn trace(&self) -> String {
        self.as_ref().trace()
    }
}

impl Trace for BlobRef<'_> {
    fn trace(&self) -> String {
        const MAX_SIZE: usize = 16;
        let size = self.len();
        if size > MAX_SIZE {
            format!("\"{}..\"[{}]", format_buf(&self[0..MAX_SIZE]), size)
        } else {
            format!("\"{}\"[{}]", format_buf(self), size)
        }
    }
}

impl<Val: Trace> Trace for Result<Val> {
    fn trace(&self) -> String {
        match self {
            Ok(val) => format!("Ok({})", val.trace()),
            Err(status) => format!("Err({})", status.trace()),
        }
    }
}

impl Trace for Status {
    fn trace(&self) -> String {
        format!("{self:?}")
    }
}

impl<A: Trace, B: Trace> Trace for (A, B) {
    fn trace(&self) -> String {
        let (a, b) = self;
        format!("({}, {})", a.trace(), b.trace())
    }
}

impl Trace for () {
    fn trace(&self) -> String {
        "()".into()
    }
}

fn format_buf(buf: &[u8]) -> String {
    let format = buf.iter().cloned().map(escape_default).flatten().collect();
    unsafe {String::from_utf8_unchecked(format)}
}

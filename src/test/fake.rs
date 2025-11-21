use std::cmp;
use std::fmt::Debug;
use std::ascii::escape_default;
use std::fmt::{self, Formatter};

use rand::Rng;
use rand::distr::{Alphanumeric, SampleString, Uniform};

use blob_db::types::{StoreId, BlobId};


pub fn store_id(rng: &mut impl Rng, max_size: usize) -> StoreId {
    let size = size_geometric(rng, max_size);
    Alphanumeric.sample_string(rng, size).into()
}

pub fn blob_id(rng: &mut impl Rng) -> BlobId {
    let mut hash = Default::default();
    rng.fill(&mut hash);
    BlobId(hash)
}

pub fn blob(rng: &mut impl Rng, max_size: usize) -> Blob {
    let size = size_geometric(rng, max_size);
    let mut buf = unsafe {Box::new_uninit_slice(size).assume_init()};
    rng.fill(buf.as_mut());
    Blob(buf)
}

pub fn size_geometric(rng: &mut impl Rng, max_size: usize) -> usize {
    let max_f64 = (max_size + 1) as f64;
    let dist = Uniform::new(0f64, max_f64.ln()).unwrap();
    let log_val = rng.sample(dist);
    cmp::min(log_val.exp() as usize, max_size)
}


#[derive(Clone, PartialEq)]
pub struct Blob(pub Box<[u8]>);

impl AsRef<[u8]> for Blob {
    fn as_ref(&self) -> &[u8] {
        let Blob(buf) = self;
        buf.as_ref()
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

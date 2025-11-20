use std::cmp;

use rand::Rng;
use rand::distr::{Alphanumeric, SampleString, Uniform};

use blob_db::types::{StoreId, BlobId, Blob};


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
    let mut bytes = unsafe {Box::new_uninit_slice(size).assume_init()};
    rng.fill(bytes.as_mut());
    Blob(bytes)
}

pub fn size_geometric(rng: &mut impl Rng, max_size: usize) -> usize {
    let max_f64 = (max_size + 1) as f64;
    let dist = Uniform::new(0f64, max_f64.ln()).unwrap();
    let log_val = rng.sample(dist);
    cmp::min(log_val.exp() as usize, max_size)
}

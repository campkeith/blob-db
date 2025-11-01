use std::cmp;

use rand::Rng;
use rand::distr::{Alphanumeric, SampleString, Uniform};

use blob_db::types::{Name, Hash, Blob};


pub fn name(rng: &mut impl Rng, max_size: usize) -> Name {
    let size = size_geometric(rng, max_size);
    Alphanumeric.sample_string(&mut rand::rng(), size).into()
}

pub fn hash(rng: &mut impl Rng) -> Hash {
    let mut hash = Hash::default();
    rng.fill(&mut hash);
    hash
}

pub fn blob(rng: &mut impl Rng, max_size: usize) -> Blob {
    let size = size_geometric(rng, max_size);
    let mut bytes = unsafe {Box::new_uninit_slice(size).assume_init()};
    rng.fill(bytes.as_mut());
    bytes
}

pub fn size_geometric(rng: &mut impl Rng, max_size: usize) -> usize {
    let max_f64 = (max_size + 1) as f64;
    let dist = Uniform::new(0f64, max_f64.ln()).unwrap();
    let log_val = rng.sample(dist);
    cmp::min(log_val.exp() as usize, max_size)
}

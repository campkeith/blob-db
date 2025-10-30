use std::collections::HashMap;

use rand;
use rand::rngs::ThreadRng;
use rand::prelude::IteratorRandom;
use rand::prelude::IndexedRandom;
use sha2::Sha256;
use sha2::Digest;
use clap::Parser;

mod fake;
use blob_db::types::{Hash, Hashes, Blob, BlobRef, Status, Result};
use blob_db::client::Client;


#[derive(Parser)]
struct Args {
    address: Box<str>,
    iterations: u64,
}

fn main() -> Result<()> {
    let args = Args::parse();
    let mut rig = TestRig{
        client: Client::connect(args.address.as_ref())?,
        store: HashMap::new(),
        rng: rand::rng(),
    };
    rig.go(args.iterations)
}

struct TestRig {
    client: Client,
    store: HashMap<Hash, Blob>,
    rng: ThreadRng,
}

impl TestRig {
    const TEST_STORE: &str = "test";
    const MAX_SIZE: usize = 1 << 20;

    fn go(&mut self, iterations: u64) -> Result<()> {
        type TestFn = dyn Fn(&mut TestRig) -> Result<()>;

        let always_ok_ops: Vec<&TestFn> = vec![
            &Self::test_blob_list,
            &Self::test_blob_save,
            &Self::test_blob_hash,
        ];
        let nonempty_ops: Vec<&TestFn> = vec![
            &Self::test_blob_info,
            &Self::test_blob_load,
            &Self::test_blob_delete,
        ];
        let all_ops: Vec<&TestFn> =
            [always_ok_ops.as_slice(), nonempty_ops.as_slice()].concat();

        self.client.store_create(Self::TEST_STORE)?;
        for _count in 0..iterations {
            let ops = if self.store.len() > 0 {&all_ops}
                      else {&always_ok_ops};
            let op = ops.choose(&mut self.rng).unwrap();
            op(self)?;
        }
        self.client.store_destroy(Self::TEST_STORE)?;
        Ok(())
    }

    fn test_blob_hash(&mut self) -> Result<()> {
        let blob = fake::blob(&mut self.rng, Self::MAX_SIZE);
        let exp_hash = blob_hash(&blob);
        let hash = self.client.blob_hash(blob)?;
        assert_eq!(hash, exp_hash);
        Ok(())
    }

    fn test_blob_list(&mut self) -> Result<()> {
        let mut exp_hashes: Hashes = self.store.keys().cloned().collect();
        let mut hashes = self.client.blob_list(Self::TEST_STORE)?;
        exp_hashes.sort();
        hashes.sort();
        assert_eq!(hashes, exp_hashes);
        Ok(())
    }

    fn test_blob_info(&mut self) -> Result<()> {
        let hash = self.random_store_hash();
        self.client.blob_info(Self::TEST_STORE, &hash)?;
        Ok(())
    }

    fn test_blob_load(&mut self) -> Result<()> {
        let hash = self.random_store_hash();
        let exp_blob = self.store.get(&hash).unwrap();
        let blob = self.client.blob_load(Self::TEST_STORE, &hash)?;
        assert_eq!(blob, *exp_blob);
        Ok(())
    }

    fn test_blob_save(&mut self) -> Result<()> {
        let blob = fake::blob(&mut self.rng, Self::MAX_SIZE);
        let exp_hash = blob_hash(&blob);
        let (status, hash) = self.client.blob_save(Self::TEST_STORE, &blob)?;
        assert_eq!(status, Status::Okay);
        assert_eq!(hash, exp_hash);
        self.store.insert(hash, blob);
        Ok(())
    }

    fn test_blob_delete(&mut self) -> Result<()> {
        let hash = self.random_store_hash();
        self.client.blob_delete(Self::TEST_STORE, &hash)?;
        self.store.remove(&hash);
        Ok(())
    }

    fn random_store_hash(&mut self) -> Hash {
        *self.store.keys().choose(&mut self.rng).unwrap()
    }
}

fn blob_hash(blob: BlobRef) -> Hash {
    Sha256::digest(blob).into()
}

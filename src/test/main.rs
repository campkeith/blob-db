use std::hash::Hash;
use std::collections::{HashSet, HashMap};

use rand;
use rand::Rng;
use rand::rngs::ThreadRng;
use rand::prelude::IteratorRandom;
use rand::distr::Distribution;
use rand::distr::weighted::WeightedIndex;
use clap::Parser;

mod fake;
use blob_db::funcs;
use blob_db::types::{StoreId, BlobId, BlobSize, Status, SaveStatus, Result};
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
        db: HashMap::new(),
        rng: rand::rng(),
    };
    rig.go(args.iterations)
}

struct TestRig {
    client: Client,
    db: HashMap<StoreId, HashMap<BlobId, fake::Blob>>,
    rng: ThreadRng,
}

impl TestRig {
    const MAX_STORE_ID_SIZE: usize = 64;
    const MAX_BLOB_SIZE: usize = 1 << 20;

    fn go(&mut self, iterations: u64) -> Result<()> {
        type TestFn = dyn Fn(&mut TestRig) -> Result<()>;
        type WeightedTestFns<'a> = Vec<(&'a TestFn, f32)>;

        let ops: WeightedTestFns = vec![
            (&Self::test_store_list, 0.2),
            (&Self::test_store_create, 0.2),
            (&Self::test_store_destroy, 0.1),
            (&Self::test_blob_list, 1.),
            (&Self::test_blob_save, 2.),
            (&Self::test_blob_hash, 1.),
            (&Self::test_blob_info, 1.),
            (&Self::test_blob_load, 1.),
            (&Self::test_blob_delete, 1.),
        ];
        let (choices, weights): (Vec<_>, Vec<_>) = ops.into_iter().unzip();
        self.test_store_list()?;
        for _count in 0..iterations {
            let dist = WeightedIndex::new(&weights).unwrap();
            let op = choices[dist.sample(&mut self.rng)];
            op(self)?;
        }
        while !self.db.is_empty() {
            self.test_store_destroy()?;
        }
        Ok(())
    }

    fn test_store_list(&mut self) -> Result<()> {
        let exp_store_ids: HashSet<&StoreId> = self.db.keys().collect();
        let store_ids = self.client.store_list()?;
        assert_eq!(as_set(store_ids.iter()), exp_store_ids);
        Ok(())
    }

    fn test_store_create(&mut self) -> Result<()> {
        let (store_id, in_db) = self.random_store();
        let exp_result = if in_db {Err(Status::Exists)}
                         else {Ok(())};
        let result = self.client.store_create(&store_id);
        assert_eq!(result, exp_result);
        if !in_db {
            self.db.insert(store_id, HashMap::new());
        }
        Ok(())
    }

    fn test_store_destroy(&mut self) -> Result<()> {
        let (store_id, in_db) = self.random_store();
        let exp_result = if in_db {Ok(())}
                         else {Err(Status::NotFound)};
        let result = self.client.store_destroy(&store_id);
        assert_eq!(result, exp_result);
        if in_db {
            self.db.remove(&store_id);
        }
        Ok(())
    }

    fn test_blob_hash(&mut self) -> Result<()> {
        let blob = fake::blob(&mut self.rng, Self::MAX_BLOB_SIZE);
        let exp_blob_id = funcs::blob_hash(blob.as_ref());
        let blob_id = self.client.blob_hash(blob)?;
        assert_eq!(blob_id, exp_blob_id);
        Ok(())
    }

    fn test_blob_list(&mut self) -> Result<()> {
        let (store_id, in_db) = self.random_store();
        let exp_result =
            if in_db {
                let store = self.db.get(&store_id).unwrap();
                Ok(store.keys().cloned().collect::<HashSet<BlobId>>())
            } else {
                Err(Status::NotFound)
            };
        let result = self.client.blob_list(store_id)
                     .and_then(|list| Ok(as_set(list)));
        assert_eq!(result, exp_result);
        Ok(())
    }

    fn test_blob_info(&mut self) -> Result<()> {
        let ((store_id, _store_ok), (blob_id, blob_ok)) = self.random_store_blob();
        let exp_result =
            if blob_ok {
                let blob = self.db.get(&store_id).unwrap().get(&blob_id).unwrap();
                Ok(BlobSize::try_from(blob.0.len()).unwrap())
            } else {
                Err(Status::NotFound)
            };
        let result = self.client.blob_info(store_id, &blob_id);
        assert_eq!(result, exp_result);
        Ok(())
    }

    fn test_blob_load(&mut self) -> Result<()> {
        let ((store_id, _store_ok), (blob_id, blob_ok)) = self.random_store_blob();
        let exp_result =
            if blob_ok {
                Ok(self.db.get(&store_id).unwrap().get(&blob_id).unwrap().clone())
            } else {
                Err(Status::NotFound)
            };
        let result_stream = self.client.blob_load(store_id, &blob_id);
        let result = match result_stream {
            Ok(mut blob_stream) => Ok(fake::Blob(blob_stream.slurp()?)),
            Err(error) => Err(error),
        };
        assert_eq!(result, exp_result);
        Ok(())
    }

    fn test_blob_save(&mut self) -> Result<()> {
        let ((store_id, store_ok), (sel_blob_id, blob_ok)) = self.random_store_blob();
        let (exp_blob_id, blob) =
            if blob_ok {
                let store = self.db.get(&store_id).unwrap();
                let blob = store.get(&sel_blob_id).unwrap().clone();
                (sel_blob_id, blob)
            } else {
                let blob = fake::blob(&mut self.rng, Self::MAX_BLOB_SIZE);
                let blob_id = funcs::blob_hash(blob.as_ref());
                (blob_id, blob)
            };
        let exp_result = match (store_ok, blob_ok) {
            (false, _) => Err(Status::NotFound),
            (true, false) => Ok((SaveStatus::Created, exp_blob_id)),
            (true, true) => Ok((SaveStatus::Exists, exp_blob_id)),
        };
        let result = self.client.blob_save(&store_id, &blob);
        assert_eq!(result, exp_result);
        if store_ok && !blob_ok {
            self.db.get_mut(&store_id).unwrap().insert(exp_blob_id, blob);
        }
        Ok(())
    }

    fn test_blob_delete(&mut self) -> Result<()> {
        let ((store_id, _store_ok), (blob_id, blob_ok)) = self.random_store_blob();
        let exp_result =
            if blob_ok {Ok(())}
            else {Err(Status::NotFound)};
        let result = self.client.blob_delete(&store_id, &blob_id);
        assert_eq!(result, exp_result);
        if blob_ok {
            self.db.get_mut(&store_id).unwrap().remove(&blob_id);
        }
        Ok(())
    }

    fn random_store_blob(&mut self) -> ((StoreId, bool), (BlobId, bool)) {
        let (store_id, store_in_db) = self.random_store_with_p(0.8);
        let (blob_id, blob_in_store) = if store_in_db {
            let store = self.db.get(&store_id).unwrap();
            let blob_in_store = !store.is_empty() && self.rng.random_bool(0.8);
            if blob_in_store {
                (*store.keys().choose(&mut self.rng).unwrap(), true)
            } else {
                (fake::blob_id(&mut self.rng), false)
            }
        } else {
            (fake::blob_id(&mut self.rng), false)
        };
        ((store_id, store_in_db), (blob_id, blob_in_store))
    }

    fn random_store(&mut self) -> (StoreId, bool) {
        self.random_store_with_p(0.6)
    }

    fn random_store_with_p(&mut self, in_db_p: f64) -> (StoreId, bool) {
        let in_db = !self.db.is_empty() && self.rng.random_bool(in_db_p);
        let store_id =
            if in_db {self.db.keys().choose(&mut self.rng).unwrap().clone()}
            else {fake::store_id(&mut self.rng, Self::MAX_STORE_ID_SIZE)};
        (store_id, in_db)
    }
}

fn as_set<Collection>(collection: Collection) -> HashSet<Collection::Item>
        where Collection: IntoIterator, Collection::Item: Hash + Eq {
    collection.into_iter().collect()
}

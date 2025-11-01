use std::hash::Hash as HashTrait;
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
use blob_db::types::{Name, Hash, Blob, Status, Result};
use blob_db::client::Client;


#[derive(Parser)]
struct Args {
    address: Box<str>,
    iterations: u64,
}

fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
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
    db: HashMap<Name, HashMap<Hash, Blob>>,
    rng: ThreadRng,
}

impl TestRig {
    const MAX_NAME_SIZE: usize = 64;
    const MAX_BLOB_SIZE: usize = 1 << 8;

    fn go(&mut self, iterations: u64) -> Result<()> {
        type TestFn = dyn Fn(&mut TestRig) -> Result<()>;
        type WeightedTestFns<'a> = Vec<(&'a TestFn, f32)>;

        let ops: WeightedTestFns = vec![
            (&Self::test_store_list, 0.1),
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
        let exp_names: HashSet<&Name> = self.db.keys().collect();
        let names = self.client.store_list()?;
        assert_eq!(as_set(names.iter()), exp_names);
        Ok(())
    }

    fn test_store_create(&mut self) -> Result<()> {
        let (store_id, in_db) = self.random_store(0.5);
        let exp_result = if in_db {Err(Status::AlreadyExists)}
                         else {Ok(())};
        let result = self.client.store_create(&store_id);
        assert_eq!(result, exp_result);
        if !in_db {
            self.db.insert(store_id, HashMap::new());
        }
        Ok(())
    }

    fn test_store_destroy(&mut self) -> Result<()> {
        let (store_id, in_db) = self.random_store(0.5);
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
        let exp_hash = funcs::blob_hash(&blob);
        let hash = self.client.blob_hash(blob)?;
        assert_eq!(hash, exp_hash);
        Ok(())
    }

    fn test_blob_list(&mut self) -> Result<()> {
        let (store_id, in_db) = self.random_store(0.5);
        let exp_result =
            if in_db {
                let store = self.db.get(&store_id).unwrap();
                Ok(store.keys().cloned().collect::<HashSet<Hash>>())
            } else {
                Err(Status::NotFound)
            };
        let result = self.client.blob_list(store_id)
                     .and_then(|list| Ok(as_set(list)));
        assert_eq!(result, exp_result);
        Ok(())
    }

    fn test_blob_info(&mut self) -> Result<()> {
        let ((store_id, _store_ok), (hash, hash_ok)) = self.random_store_hash();
        let exp_result =
            if hash_ok {Ok(())}
            else {Err(Status::NotFound)};
        let result = self.client.blob_info(store_id, &hash);
        assert_eq!(result, exp_result);
        Ok(())
    }

    fn test_blob_load(&mut self) -> Result<()> {
        let ((store_id, _store_ok), (hash, hash_ok)) = self.random_store_hash();
        let exp_result =
            if hash_ok {
                Ok(self.db.get(&store_id).unwrap().get(&hash).unwrap().clone())
            } else {
                Err(Status::NotFound)
            };
        let result = self.client.blob_load(store_id, &hash);
        assert_eq!(result, exp_result);
        Ok(())
    }

    fn test_blob_save(&mut self) -> Result<()> {
        let ((store_id, store_ok), (blob_id, blob_ok)) = self.random_store_hash();
        let exp_status = match (store_ok, blob_ok) {
            (false, _) => Status::NotFound,
            (true, false) => Status::Okay,
            (true, true) => Status::AlreadyExists,
        };
        let (exp_hash, blob) =
            if blob_ok {
                let store = self.db.get(&store_id).unwrap();
                let blob = store.get(&blob_id).unwrap().clone();
                (blob_id, blob)
            } else {
                let blob = fake::blob(&mut self.rng, Self::MAX_BLOB_SIZE);
                let hash = funcs::blob_hash(&blob);
                (hash, blob)
            };
        let (status, hash) = self.client.blob_save(&store_id, &blob)?;
        assert_eq!((status, hash), (exp_status, exp_hash));
        if store_ok && !blob_ok {
            self.db.get_mut(&store_id).unwrap().insert(hash, blob);
        }
        Ok(())
    }

    fn test_blob_delete(&mut self) -> Result<()> {
        let ((store_id, _store_ok), (hash, hash_ok)) = self.random_store_hash();
        let exp_result =
            if hash_ok {Ok(())}
            else {Err(Status::NotFound)};
        let result = self.client.blob_delete(&store_id, &hash);
        assert_eq!(result, exp_result);
        if hash_ok {
            self.db.get_mut(&store_id).unwrap().remove(&hash);
        }
        Ok(())
    }

    fn random_store_hash(&mut self) -> ((Name, bool), (Hash, bool)) {
        let (store_id, store_in_db) = self.random_store(0.75);
        let (hash, hash_in_store) = if store_in_db {
            let store = self.db.get(&store_id).unwrap();
            let hash_in_store = !store.is_empty() && self.rng.random_bool(0.5);
            if hash_in_store {
                (*store.keys().choose(&mut self.rng).unwrap(), true)
            } else {
                (fake::hash(&mut self.rng), false)
            }
        } else {
            (fake::hash(&mut self.rng), false)
        };
        ((store_id, store_in_db), (hash, hash_in_store))
    }

    fn random_store(&mut self, in_db_p: f64) -> (Name, bool) {
        let in_db = !self.db.is_empty() && self.rng.random_bool(in_db_p);
        let store_id =
            if in_db {self.db.keys().choose(&mut self.rng).unwrap().clone()}
            else {fake::name(&mut self.rng, Self::MAX_NAME_SIZE)};
        (store_id, in_db)
    }
}

fn as_set<Collection>(collection: Collection) -> HashSet<Collection::Item>
        where Collection: IntoIterator, Collection::Item: HashTrait + Eq {
    collection.into_iter().collect()
}

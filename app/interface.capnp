@0x84b1279a70ad9e8a;

using Name = Text;
using Blob = Data;
using Hash = Data;
using Status = Text;

interface Database {
    storeCreate @0 (name :Name) -> (status :Status);
    storeDestroy @1 (name :Name) -> (status :Status);

    blobHash @2 (blob :Blob) -> (hash :Hash);
}

interface Store {
    struct Name {
        name @0 :Name;
    }

    blobList @0 () -> (hashes_status: HashesStatus);
    blobInfo @1 (hash :Hash) -> (status :Status);
    blobLoad @2 (hash :Hash) -> (blob_status :BlobStatus);
    blobSave @3 (blob :Blob) -> (status :Status, hash :Hash);
    blobDelete @4 (hash :Hash) -> (status :Status);
}

struct HashesStatus {
    union {
        hashes @0 :List(Blob);
        status @1 :Status;
    }
}

struct BlobStatus {
    union {
        blob @0 :Blob;
        status @1 :Status;
    }
}

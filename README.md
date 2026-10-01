# Blob Database

The Blob Database is a collection of *stores* each containing multiple
content-addressable *blobs*. A blob is binary data (i.e. the contents of a
file). The Blob Database is a place to offload large blobs from your
main database. An example usage for a video file would look like this:

```
# Save
status, hash = blob_database.blob_save("videos", video);
main_database.run("insert into videos (name, hash) values ({name}, {hash})")

# Load
hash = main_database.run("select hash from videos where name={name}")
video = blob_database.blob_load("videos", hash)
```

With this usage pattern, your main database can focus on metadata and stay
small while the Blob Database deals with the large files. A blob's hash
changes when _any_ part of the blob changes, enabling the Blob Database
to ensure data integrity and forcing a main database update for any changes
to a blob. (Technically, this is _replacing_ an _immutable_ blob.) The use of
a secure hash function ([sha256](https://en.wikipedia.org/wiki/SHA-2))
thwarts undetected blob modification even with an intelligent, malicious
adversary.

The Blob Database gives you the best of both worlds -- your preferred
main database with your desired Atomicity, Consistency, Independence,
and Durability (ACID) properties without sacrificing scalability and
performance. (Multi-node support for simultanous redundancy and throughput
amplification is planned for a future release.) Synchronization problems
are minimized by the hashing paradigm and the resulting blob immutability.
To do a consistency check, just compare the list of hashes in the
Blob Database with the list of hashes in your main database to find orphaned
blobs and dangling blob references.

## Recommended CRUD Usage

Dangling blob references can be avoided entirely by doing operations in an
order that ensures that a failed operation will never result in dangling
blob references and at worst result in orphaned blobs. Since orphaned blobs
have no references (by definition), they will have no effect on database
operations other than additional storage use. Orphaned blobs can be safely
deleted once found by a consistency check.

To prevent dangling blob references, the recommended "CRUD" usage pattern is:

1. **Create**: Save blob to blob database. Insert resulting hash into main
database.
2. **Read**: Select hash from main database. Use this hash to load blob
from blob database.
3. **Update**: Save new blob to blob database. Atomically select old hash and
update hash to new hash in main database. Use old hash to delete old blob.
4. **Delete**: Atomically select hash and delete it from main database.
Use hash to delete blob from blob database.

To avoid most orphaned blob scenarios, a good error-handling practice is to
attempt to undo the blob save of (1) and (3) with a corresponding blob delete
upon failure of the main database operation.

## Interface

Conceptually, the Blob Database provides the following set of Create, Read,
Update, and Delete (CRUD) functions. See the following sections for HTTP and
native protocol implementations of this interface.

### Database Functions

These functions operate at the global database scope.

#### List Stores

```
db_list() -> [StoreName, ...]
```
Output the names of all stores in the database.

#### Create Store

```
store_create(StoreName) -> Status
```
Create a store with the given name.

#### Destroy Store

```
store_destroy(StoreName) -> Status
```
Destroy the store with the given name and all blobs within the given store.

**Note**: As one would expect, this does not affect duplicates of any of said
blobs in other stores.

### Store Functions

These functions all operate on the blobs within the given store.

#### List Blobs

```
store_list(StoreName) -> [Hash, ...] | Status
```
Output the hash of all blobs in the given store.

#### Get Blob Info

```
blob_info(StoreName, Hash) -> Size | Status
```
Output the size of the blob with the given hash in the given store or
'not-found' if it does not exist.

#### Load Blob

```
blob_load(StoreName, Hash) -> Blob | Status
```
Output the contents of the blob with the given hash in the given store.

#### Save Blob

```
blob_save(StoreName, Blob) -> (Status, Hash)
```
Save the given blob to the given store. Output the hash to be used as a
handle for subsequent load and remove operations. The hash is always
computed and outputted for valid requests.

**Note**: Some clients may wish to include special logic for the
`already-exists` status code if they intend to sometimes save duplicate blobs.
(As a content-addressible store naturally performs de-duplication, a save of
a duplicate blob is a no-op.)

#### Delete Blob

```
blob_delete(StoreName, Hash) -> Status
```
Delete the blob with the given hash from the given store.

### Convenience Functions

#### Hash Blob

```
blob_hash(Blob) -> Hash
```
Output the hash of the given blob. This function is included for the client's
convenience.

**Note**: This simply implements the
[sha256](https://en.wikipedia.org/wiki/SHA-2) algorithm, which a client can
almost certainly do faster itself.

### Data Types

#### StoreName

The name of a store (i.e. a string), used as a unique identifier for referring
to said store.

#### Blob

A blob is a variably-sized array of bytes. This concept is equivalent to the
contents of a file.

#### Hash

The [sha256](https://en.wikipedia.org/wiki/SHA-2) hash of a Blob, which is
a fixed-sized array of 32 bytes.

#### Size

The size of a blob, in bytes.

#### Status

A status enumeration, which is one of:
* **okay**: The operation was successful.
* **already-exists**: The blob with the given hash or the store with the given
    name already exists.
* **not-found**: The blob with the given hash or the store with the given name
    was not found.
* **no-space**: Save failed due to insufficient storage space.
* **invalid-argument**: The operation failed because one or more function
    arguments violated static protocol constraints.
* **internal-error**: The operation failed because of an internal failure in
    the server. (This shouldn't normally happen.)

## HTTP Protocol

For the client's convenience, the Blob Database provides a Representational
State Transfer (ReST) oriented HTTP protocol with the following supported
request lines:

```
| Function      | Request Line                    | Request Body | Response Body          |
| ------------- | --------------------------------| ------------ | ---------------------- |
| List Stores   | GET    /stores                  | -            | JSON: [StoreName, ...] |
| Create Store  | PUT    /stores/:StoreName       | -            | -                      |
| Destroy Store | DELETE /stores/:StoreName       | -            | -                      |
| List Blobs    | GET    /stores/:StoreName       | -            | JSON: [Hash, ...]      |
| Get Blob Info | HEAD   /stores/:StoreName/:Hash | -            | -                      |
| Load Blob     | GET    /stores/:StoreName/:Hash | -            | Blob                   |
| Save Blob     | POST   /stores/:StoreName       | Blob         | JSON: Hash             |
| Delete Blob   | DELETE /stores/:StoreName/:Hash | -            | -                      |
| Hash Blob     | POST   /hash                    | Blob         | JSON: Hash             |
```

The notation "-" means that the body of the request or response is empty.

For the "Get Blob Info" function, the blob size is the value of the
"Content-Length" response header.

For the "Save Blob" function, if the blob already exists within the given store,
the server will respond with a "409 Conflict" status, but still provide the
hash of the given blob. (This save of a duplicate blob is a no-op in a
de-duplicating content-addressible store.)

### Data Type Formatting

#### String Types

The following conceptual types are represented as strings which can be
inserted into their respective *:PlaceHolder* in the above request lines or
encoded as JSON string values.

```
| Type      | Format                                                   |
| --------- | -------------------------------------------------------- |
| StoreName | The store name as a string                               |
| Hash      | The 32-byte blob hash as a lowercase 64-hexadigit string |
```

#### HTTP Status Mapping

The conceptual *Status* type is mapped to HTTP status codes as follows:

```
| Status         | HTTP Status               |
| -------------- | ------------------------- |
| okay           | 200 OK                    |
| bad-argument   | 400 Bad Request           |
| not-found      | 404 Not Found             |
| already-exists | 409 Conflict              |
| internal-error | 500 Internal Server Error |
| no-space       | 507 Insufficient Storage  |
```

#### Blob

The conceptual *Blob* is mapped to request and response bodies. The Blob bytes
(contents) are transmitted directly through said bodies. The server ignores
the "Content-Type" header sent by the client. For the convenience of the
client (e.g. for browser display or download), the server will set
"Content-Type" to "text/plain" if the first 256 bytes of the blob are non-null
otherwise "application/octet-stream".

The Blob Database stores blob contents, not metadata. The recommended usage
of the Blob Database (see introduction above) is with a parent metadata
database which is a good place to track content types.

## Native Protocol

The native Blob Database protocol is based on TCP using binary streams.
Message framing is baked into the protocol.

### Request and Response Streams

```
RequestStream = {OPEN_DOOR, proto_version: uint32, requests: Request*}
```

```
ResponseStream = {WELCOME, responses: Response*}
               | {NOT_WELCOME, proto_version: uint32}
```

### Request and Response Frames

```
Request = {STORE_LIST}
        | {STORE_CREATE, StoreName}
        | {STORE_DESTROY, StoreName}
        | {BLOB_HASH, Blob}
        | {BLOB_LIST, StoreName}
        | {BLOB_INFO, StoreName, Hash}
        | {BLOB_LOAD, StoreName, Hash}
        | {BLOB_SAVE, StoreName, Blob}
        | {BLOB_DELETE, StoreName, Hash}

Response = Status
         | StoreListResponse
         | BlobHashResponse
         | BlobListResponse
         | BlobInfoResponse
         | BlobLoadResponse
         | BlobSaveResponse

StoreListResponse = {OK, StoreNames} | ErrorStatus
BlobHashResponse = {OK, Hash} | ErrorStatus
BlobListResponse = {OK, Hashes} | ErrorStatus
BlobInfoResponse = {OK, Size} | ErrorStatus
BlobLoadResponse = {OK, Blob} | ErrorStatus
BlobSaveResponse = {OK | ALREADY_EXISTS, Hash}
                 | {NO_SPACE | NOT_FOUND | INVALID_ARGUMENT}
```

### Values

```
StoreName = {size: uint16, elems: [size x uint8]}
StoreNames = {size: uint64, elems: [size x StoreName]}
Blob = {size: uint64, elems: [size x uint8]}
Hash = [32 x uint8]
Hashes = {size: uint64, elems: [size x Hash]}
Size = uint64

Status = OKAY | ErrorStatus

ErrorStatus = ALREADY_EXISTS
            | NOT_FOUND
            | NO_SPACE
            | INVALID_ARGUMENT
            | INTERNAL_ERROR
```


## Architecture

```
      | Binary TCP
      v
+-----------+
| Interface |
+-----------+
| Persister |
+-----------+
      |
      | filesystem
      | operations
      v
(-----------)
|   Disk    |
(-----------)

```

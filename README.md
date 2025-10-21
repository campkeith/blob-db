# Blob Database

The Blob Database is a collection of *stores* each containing multiple
content-addressible *blobs*. A blob is binary data
(i.e. the contents of a file).


## Interface

### Database Functions

These functions operate at the global database scope.

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

#### Hash Blob

```
blob_hash(Blob) -> Hash
```
Output the hash of the given blob.

**Note**: This simply implements the
[sha256](https://en.wikipedia.org/wiki/SHA-2) algorithm, which a client can
almost certainly do faster itself.

### Store Functions

These functions all operate on the blobs within the given store.

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

#### Get Blob Info

```
blob_info(StoreName, Hash) -> Status
```
Determine whether the blob with the given hash exists in the given store.
Outputs `success` if it exists, `not-found` otherwise.

#### List Blobs

```
blob_list(StoreName) -> Hash[] | Status
```
Output the hash of all blobs in the given store.

#### Delete Blob

```
blob_delete(StoreName, Hash) -> Status
```
Delete the blob with the given hash from the given store.

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

#### Status

A status enumeration, which is one of:
* `ok`: The operation was successful.
* `not-found`: The blob with the given hash or the store with the given name
   was not found.
* `already-exists`: The blob with the given hash or the store with the given
   name already exists.
* `no-space`: Save failed due to insufficient storage space.

## Native Protocol

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
Request = {STORE_CREATE, StoreName}
        | {STORE_DESTROY, StoreName}
        | {BLOB_HASH, Blob}
        | {BLOB_LIST, StoreName}
        | {BLOB_INFO, StoreName, Hash}
        | {BLOB_LOAD, StoreName, Hash}
        | {BLOB_SAVE, StoreName, Blob}
        | {BLOB_DELETE, StoreName, Hash}

Response = Status
         | HashResponse
         | ListResponse
         | LoadResponse
         | SaveResponse

HashResponse = {OK, Hash} | ErrorStatus
ListResponse = {OK, Hashes} | ErrorStatus
LoadResponse = {OK, Blob} | ErrorStatus
SaveResponse = {OK | ALREADY_EXISTS | NO_SPACE, Hash} | INVALID_ARGUMENT
```

### Values

```
StoreName = {size: uint32, elems: [size x uint8]}
Blob = {size: uint64, elems: [size x uint8]}
Hash = [32 x uint8]
Hashes = {size: uint32, elems: [size x Hash]}

Status = OK | ErrorStatus

ErrorStatus = NOT_FOUND
            | ALREADY_EXISTS
            | INVALID_ARGUMENT
            | NO_SPACE
```


## Architecture

```
      | Cap'n Proto
      v
+-----------+
| Interface |
+-----------+
|  Storage  |
+-----------+
      |
      | filesystem
      | operations
      v
(-----------)
|   Disk    |
(-----------)

```

# Blob Database

The Blob Database manages multiple stores each containing multiple
content-addressible blobs. A blob is binary data
(i.e. the contents of any file).


## Interface

### Store Functions

These functions are used to manage "stores" which are the top-level
collections of blobs in the database.

#### Create Store

```
store_create(StoreName) -> Status
```
Create a store with the given name.

#### Remove Store

```
store_remove(StoreName) -> Status
```
Remove the store with the given name and all blobs within the given store.

**Note**: As one would expect, this does not affect duplicates of any of said
blobs in other stores.

### Blob Functions

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

#### Remove

```
blob_remove(StoreName, Hash) -> Status
```
Remove the blob with the given hash from the given store.


### Convenience Functions

```
hash(Blob) -> Hash
```
Output the hash of the given blob.

**Note**: This simply implements the
[sha256](https://en.wikipedia.org/wiki/SHA-2) algorithm, which a client can
also do itself.


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

A status string, which is one of:
* `success`: The operation was successful.
* `not-found`: The blob with the given hash or the store with the given name
   was not found.
* `already-exists`: The blob with the given hash or the store with the given
   name already exists.
* `no-space`: Store failed due to insufficient storage space.

## Architecture

```
      | FlatBuffer
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
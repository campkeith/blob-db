use std::io;
use std::io::{Read, Write};

mod types;
use types::*;

pub enum Request {
    StoreCreate(StoreName),
    StoreDestroy(StoreName),
    BlobHash(Blob),

    BlobList(StoreName),
    BlobInfo(StoreName, Hash),
    BlobLoad(StoreName, Hash),
    BlobSave(StoreName, Blob),
    BlobDelete(StoreName, Hash),
}

pub enum Response {
    Status(Status),
    BlobHash(Hash),
    BlobList(Hashes),
    BlobLoad(Blob),
    BlobSave(Status, Hash),
}

#[derive(TryFromPrimitive)]
#[repr(u64)]
enum RequestCode {
    StoreCreate = code8!(b"storenew"),
    StoreDestroy = code8!(b"storedel"),
    BlobHash = code8!(b"blobhash"),

    BlobList = code8!(b"bloblist"),
    BlobInfo = code8!(b"blobinfo"),
    BlobLoad = code8!(b"blobload"),
    BlobSave = code8!(b"blobsave"),
    BlobDelete = code8!(b"blobdel\0"),
}


pub fn send_request(stream: &mut impl Write, request: Request)
        -> io::Result<()> {
    match request {
        Request::StoreCreate(name) => {
            send_request_code(stream, RequestCode::StoreCreate)?;
            send_name(stream, name)?;
        }
        Request::StoreDestroy(name) => {
            send_request_code(stream, RequestCode::StoreDestroy)?;
            send_name(stream, name)?;
        }
        Request::BlobHash(blob) => {
            send_request_code(stream, RequestCode::BlobHash)?;
            send_blob(stream, blob)?;
        }

        Request::BlobList(store_name) => {
            send_request_code(stream, RequestCode::BlobList)?;
            send_name(stream, store_name)?;
        }
        Request::BlobInfo(store_name, hash) => {
            send_request_code(stream, RequestCode::BlobInfo)?;
            send_name(stream, store_name)?;
            send_hash(stream, hash)?;
        }
        Request::BlobLoad(store_name, hash) => {
            send_request_code(stream, RequestCode::BlobLoad)?;
            send_name(stream, store_name)?;
            send_hash(stream, hash)?;
        }
        Request::BlobSave(store_name, blob) => {
            send_request_code(stream, RequestCode::BlobSave)?;
            send_name(stream, store_name)?;
            send_blob(stream, blob)?;
        }
        Request::BlobDelete(store_name, hash) => {
            send_request_code(stream, RequestCode::BlobDelete)?;
            send_name(stream, store_name)?;
            send_hash(stream, hash)?;
        }
    }
    Ok(())
}

pub fn send_response(stream: &mut impl Write, response: Response)
        -> io::Result<()> {
    match response {
        Response::Status(status) => {
            send_status(stream, status)?;
        }
        Response::BlobHash(hash) => {
            send_status(stream, Status::Okay)?;
            send_hash(stream, hash)?;
        }
        Response::BlobList(hashes) => {
            send_status(stream, Status::Okay)?;
            send_hashes(stream, hashes)?;
        }
        Response::BlobLoad(blob) => {
            send_status(stream, Status::Okay)?;
            send_blob(stream, blob)?;
        }
        Response::BlobSave(status, hash) => {
            send_status(stream, status)?;
            send_hash(stream, hash)?;
        }
    }
    Ok(())
}


fn send_name(stream: &mut impl Write, name: Name) -> io::Result<()> {
    let buffer: &[u8] = name.as_bytes();
    let size = buffer.len();
    assert!(size < 2^16, "{}", size);
    send_u16(stream, size as u16)?;
    stream.write_all(buffer)?;
    Ok(())
}

fn send_blob(stream: &mut impl Write, blob: Blob) -> io::Result<()> {
    let size = blob.len();
    assert!(size < 2^64, "{}", size);
    send_u64(stream, size as u64)?;
    stream.write_all(&blob)?;
    Ok(())
}

fn send_hashes(stream: &mut impl Write, hashes: Hashes) -> io::Result<()> {
    let size = hashes.len();
    assert!(size < 2^64, "{}", size);
    send_u64(stream, size as u64)?;
    for hash in hashes {
        send_hash(stream, hash)?;
    }
    Ok(())
}

fn send_status(stream: &mut impl Write, status: Status) -> io::Result<()> {
    send_u64(stream, status as u64)
}

fn send_request_code(stream: &mut impl Write, code: RequestCode)
        -> io::Result<()> {
    send_u64(stream, code as u64)
}

fn send_hash(stream: &mut impl Write, hash: Hash)
        -> io::Result<()> {
    send_bytes(stream, &hash)
}

fn send_u16(stream: &mut impl Write, val: u16) -> io::Result<()> {
    send_bytes(stream, &val.to_le_bytes())
}

fn send_u64(stream: &mut impl Write, val: u64) -> io::Result<()> {
    send_bytes(stream, &val.to_le_bytes())
}

fn send_bytes(stream: &mut impl Write, bytes: &[u8]) -> io::Result<()> {
    stream.write_all(bytes)
}


pub fn recv_request(stream: &mut impl Read) -> io::Result<Request> {
    let code: RequestCode = recv_request_code(stream)?;
    let request: Request = match code {
        RequestCode::StoreCreate => Request::StoreCreate(recv_name(stream)?),
        RequestCode::StoreDestroy => Request::StoreDestroy(recv_name(stream)?),
        RequestCode::BlobHash => Request::BlobHash(recv_blob(stream)?),

        RequestCode::BlobList => Request::BlobList(recv_name(stream)?),
        RequestCode::BlobInfo => Request::BlobInfo(recv_name(stream)?,
                                                   recv_hash(stream)?),
        RequestCode::BlobLoad => Request::BlobLoad(recv_name(stream)?,
                                                   recv_hash(stream)?),
        RequestCode::BlobSave => Request::BlobSave(recv_name(stream)?,
                                                   recv_blob(stream)?),
        RequestCode::BlobDelete => Request::BlobDelete(recv_name(stream)?,
                                                       recv_hash(stream)?),
    };
    Ok(request)
}

pub fn recv_response(stream: &mut impl Read, request_context: Request)
        -> io::Result<Response> {
    let status: Status = recv_status(stream)?;
    let response: Response = match (status, request_context) {
        (Status::InvalidArgument, _) =>
            Response::Status(Status::InvalidArgument),
        (Status::Okay, Request::BlobHash(..)) =>
            Response::BlobHash(recv_hash(stream)?),
        (Status::Okay, Request::BlobList(..)) =>
            Response::BlobList(recv_hashes(stream)?),
        (Status::Okay, Request::BlobLoad(..)) =>
            Response::BlobLoad(recv_blob(stream)?),
        (status, Request::BlobSave(..)) =>
            Response::BlobSave(status, recv_hash(stream)?),
        (status, _) =>
            Response::Status(status),
    };
    Ok(response)
}

fn recv_name(stream: &mut impl Read) -> io::Result<Name> {
    let size = recv_u16(stream)?;
    let mut buffer = vec![0u8; size as usize];
    stream.read_exact(&mut buffer)?;
    let name = String::from_utf8(buffer).unwrap().into_boxed_str();
    Ok(name)
}

fn recv_blob(stream: &mut impl Read) -> io::Result<Blob> {
    let size = recv_u64(stream)?;
    let mut blob = vec![0u8; size as usize].into_boxed_slice();
    stream.read_exact(&mut blob)?;
    Ok(blob)
}

fn recv_hashes(stream: &mut impl Read) -> io::Result<Hashes> {
    let size = recv_u64(stream)?;
    let hashes = std::iter::repeat_with(|| recv_hash(stream))
                 .take(size as usize)
                 .collect::<io::Result<Vec<Hash>>>()?
                 .into_boxed_slice();
    Ok(hashes)
}

fn recv_status(stream: &mut impl Read) -> io::Result<Status> {
    let val = recv_u64(stream)?;
    match Status::try_from(val) {
        Ok(status) => Ok(status),
        Err(_) => io::Result::Err(io::Error::other("oh no!")),
    }
}

fn recv_request_code(stream: &mut impl Read) -> io::Result<RequestCode> {
    let val = recv_u64(stream)?;
    match RequestCode::try_from(val) {
        Ok(status) => Ok(status),
        Err(_) => io::Result::Err(io::Error::other("oh no!")),
    }
}

fn recv_hash(stream: &mut impl Read) -> io::Result<Hash> {
    recv_bytes::<32>(stream)
}

fn recv_u16(stream: &mut impl Read) -> io::Result<u16> {
    let bytes = recv_bytes::<2>(stream)?;
    Ok(u16::from_le_bytes(bytes))
}

fn recv_u64(stream: &mut impl Read) -> io::Result<u64> {
    let bytes = recv_bytes::<8>(stream)?;
    Ok(u64::from_le_bytes(bytes))
}

fn recv_bytes<const SIZE: usize>(stream: &mut impl Read)
        -> io::Result<[u8; SIZE]> {
    let mut buffer = [0u8; SIZE];
    stream.read_exact(&mut buffer)?;
    Ok(buffer)
}

fn main() {
}

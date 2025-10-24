use std::iter;
use std::io::{Read, Write};

use num_enum::{TryFromPrimitive, IntoPrimitive};

use crate::{log_ret_err, log_err_ret_val, log_err, code8};
use crate::types::{Request, Response, Status, Result,
                   Name, Names, Hash, Hashes, Blob};


#[repr(u64)]
#[derive(TryFromPrimitive, IntoPrimitive)]
enum RequestCode {
    StoreList = code8!(b"storlist"),
    StoreCreate = code8!(b"storenew"),
    StoreDestroy = code8!(b"storedel"),
    BlobHash = code8!(b"blobhash"),

    BlobList = code8!(b"bloblist"),
    BlobInfo = code8!(b"blobinfo"),
    BlobLoad = code8!(b"blobload"),
    BlobSave = code8!(b"blobsave"),
    BlobDelete = code8!(b"blobdel\0"),
}


pub trait Send: Sized {
    fn send(self, stream: &mut impl Write) -> Result<()>;
}

macro_rules! send {($stream: expr, $($item: expr), *) => {
    {$($item.send($stream)?;)*}
}}

#[allow(dead_code)]
impl Send for Request {
    fn send(self, stream: &mut impl Write) -> Result<()> {
        match self {
            Request::StoreList() =>
                send!(stream, RequestCode::StoreList),
            Request::StoreCreate(name) =>
                send!(stream, RequestCode::StoreCreate, name),
            Request::StoreDestroy(name) =>
                send!(stream, RequestCode::StoreDestroy, name),
            Request::BlobHash(blob) =>
                send!(stream, RequestCode::BlobHash, blob),
            Request::BlobList(store_name) =>
                send!(stream, RequestCode::BlobList, store_name),
            Request::BlobInfo(store_name, hash) =>
                send!(stream, RequestCode::BlobInfo, store_name, hash),
            Request::BlobLoad(store_name, hash) =>
                send!(stream, RequestCode::BlobLoad, store_name, hash),
            Request::BlobSave(store_name, blob) =>
                send!(stream, RequestCode::BlobSave, store_name, blob),
            Request::BlobDelete(store_name, hash) =>
                send!(stream, RequestCode::BlobDelete, store_name, hash),
        }
        Ok(())
    }
}

#[allow(dead_code)]
impl Send for Response {
    fn send(self, stream: &mut impl Write) -> Result<()> {
        match self {
            Response::Status(status) => send!(stream, status),
            Response::StoreList(names) => send!(stream, Status::Okay, names),
            Response::BlobHash(hash) => send!(stream, Status::Okay, hash),
            Response::BlobList(hashes) => send!(stream, Status::Okay, hashes),
            Response::BlobLoad(blob) => send!(stream, Status::Okay, blob),
            Response::BlobSave(status, hash) => send!(stream, status, hash),
        }
        Ok(())
    }
}

impl Send for Name {
    fn send(self, stream: &mut impl Write) -> Result<()> {
        let buffer = self.as_bytes();
        let size = log_ret_err!(u16::try_from(buffer.len()));
        send!(stream, size, buffer);
        Ok(())
    }
}

impl Send for Names {
    fn send(self, stream: &mut impl Write) -> Result<()> {
        let size = log_ret_err!(u64::try_from(self.len()));
        size.send(stream)?;
        for name in self {
            name.send(stream)?;
        }
        Ok(())
    }
}

impl Send for Blob {
    fn send(self, stream: &mut impl Write) -> Result<()> {
        let size = log_ret_err!(u64::try_from(self.len()));
        send!(stream, size, self);
        Ok(())
    }
}

impl Send for Hashes {
    fn send(self, stream: &mut impl Write) -> Result<()> {
        let size = log_ret_err!(u64::try_from(self.len()));
        let buffer: Blob = self.into_iter().flatten().collect();
        send!(stream, size, buffer);
        Ok(())
    }
}

macro_rules! impl_send_for_enum {($($Enum: ty), +) => {$(
    impl Send for $Enum {
        fn send(self, stream: &mut impl Write) -> Result<()> {
            u64::from(self).send(stream)
        }
    }
)+}}
impl_send_for_enum!(RequestCode, Status);

macro_rules! impl_send_for_num {($($Num: ty), +) => {$(
    impl Send for $Num {
        fn send(self, stream: &mut impl Write) -> Result<()> {
            self.to_le_bytes().send(stream)
        }
    }
)+}}
impl_send_for_num!(u16, u64);

impl Send for &[u8] {
    fn send(self, stream: &mut impl Write) -> Result<()> {
        log_ret_err!(stream.write_all(self));
        Ok(())
    }
}


pub trait Recv: Sized {
    fn recv(stream: &mut impl Read) -> Result<Self>;
}

#[allow(dead_code)]
impl Recv for Request {
    fn recv(stream: &mut impl Read) -> Result<Self> {
        let code: RequestCode = RequestCode::recv(stream)?;
        let request: Request = match code {
            RequestCode::StoreList =>
                Request::StoreList(),
            RequestCode::StoreCreate =>
                Request::StoreCreate(Name::recv(stream)?),
            RequestCode::StoreDestroy =>
                Request::StoreDestroy(Name::recv(stream)?),
            RequestCode::BlobHash =>
                Request::BlobHash(Blob::recv(stream)?),
            RequestCode::BlobList =>
                Request::BlobList(Name::recv(stream)?),
            RequestCode::BlobInfo =>
                Request::BlobInfo(Name::recv(stream)?, Hash::recv(stream)?),
            RequestCode::BlobLoad =>
                Request::BlobLoad(Name::recv(stream)?, Hash::recv(stream)?),
            RequestCode::BlobSave =>
                Request::BlobSave(Name::recv(stream)?, Blob::recv(stream)?),
            RequestCode::BlobDelete =>
                Request::BlobDelete(Name::recv(stream)?, Hash::recv(stream)?),
        };
        Ok(request)
    }
}

#[allow(dead_code)]
impl Response {
    pub fn recv(stream: &mut impl Read, request_context: Request)
            -> Result<Self> {
        let status: Status = Status::recv(stream)?;
        let response: Response = match (status, request_context) {
            (Status::InvalidArgument, _) =>
                Response::Status(Status::InvalidArgument),
            (Status::Okay, Request::StoreList(..)) =>
                Response::StoreList(Names::recv(stream)?),
            (Status::Okay, Request::BlobHash(..)) =>
                Response::BlobHash(Hash::recv(stream)?),
            (Status::Okay, Request::BlobList(..)) =>
                Response::BlobList(Hashes::recv(stream)?),
            (Status::Okay, Request::BlobLoad(..)) =>
                Response::BlobLoad(Blob::recv(stream)?),
            (status, Request::BlobSave(..)) =>
                Response::BlobSave(status, Hash::recv(stream)?),
            (status, _) =>
                Response::Status(status),
        };
        Ok(response)
    }
}

impl Recv for Name {
    fn recv(stream: &mut impl Read) -> Result<Self> {
        let size = u16::recv(stream)?;
        let name_bytes = bytes_recv(stream, usize::from(size))?;
        let name = log_ret_err!(str::from_utf8(&name_bytes));
        Ok(Name::from(name))
    }
}

impl Recv for Names {
    fn recv(stream: &mut impl Read) -> Result<Self> {
        let num_elems_u64 = u64::recv(stream)?;
        let num_elems = log_ret_err!(usize::try_from(num_elems_u64));
        iter::repeat_with(|| Name::recv(stream)).take(num_elems).collect()
    }
}

impl Recv for Blob {
    fn recv(stream: &mut impl Read) -> Result<Self> {
        let size_u64 = u64::recv(stream)?;
        let size = log_ret_err!(usize::try_from(size_u64));
        let blob = bytes_recv(stream, size)?;
        Ok(blob)
    }
}

impl Recv for Hashes {
    fn recv(stream: &mut impl Read) -> Result<Self> {
        let num_elems_u64 = u64::recv(stream)?;
        let num_elems = log_ret_err!(usize::try_from(num_elems_u64));
        let size = num_elems * size_of::<Hash>();
        let buffer = bytes_recv(stream, size)?;
        let hashes = buffer.into_iter().array_chunks().collect();
        Ok(hashes)
    }
}

macro_rules! impl_recv_for_enum{($($Enum: ty), +) => {$(
    impl Recv for $Enum {
        fn recv(stream: &mut impl Read) -> Result<Self> {
            let val = Recv::recv(stream)?;
            let enumerant = log_ret_err!(Self::try_from_primitive(val));
            Ok(enumerant)
        }
    }
)+}}
impl_recv_for_enum!(RequestCode, Status);

macro_rules! impl_recv_for_num{($($Num: ty), +) => {$(
    impl Recv for $Num {
        fn recv(stream: &mut impl Read) -> Result<Self> {
            let bytes = Recv::recv(stream)?;
            Ok(Self::from_le_bytes(bytes))
        }
    }
)+}}
impl_recv_for_num!(u16, u64);

impl<const SIZE: usize> Recv for [u8; SIZE] {
    fn recv(stream: &mut impl Read) -> Result<Self> {
        let mut buffer = [0u8; SIZE];
        log_ret_err!(stream.read_exact(&mut buffer));
        Ok(buffer)
    }
}

fn bytes_recv(stream: &mut impl Read, size: usize) -> Result<Box<[u8]>> {
    let buf_uninit = Box::new_uninit_slice(size);
    let mut buffer = unsafe {buf_uninit.assume_init()};
    log_ret_err!(stream.read_exact(&mut buffer));
    Ok(buffer)
}

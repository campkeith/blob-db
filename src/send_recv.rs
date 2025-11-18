use std::iter;
use std::io::{Read, Write};

use num_enum::{TryFromPrimitive, IntoPrimitive};

use crate::funcs::code8;
use crate::{log_ret_err, log_err_ret_val, log_err};
use crate::types::{
    Request, RequestRef, Response, Status, Result, Code,
    StoreId, StoreIds, BlobId, BlobIds, Blob,
    StoreIdRef, StoreIdsRef, BlobIdsRef, BlobRef,
};


type ProtoVersion = u16;
const PROTO_VERSION: ProtoVersion = 1;

const CODE_OPEN_DOOR: Code = code8(b"OpenDoor");

#[repr(u64)]
#[derive(TryFromPrimitive, IntoPrimitive)]
enum GreetCode {
    Welcome = code8(b"Welcome!"),
    NotWelcome = code8(b"Go away!"),
}

#[repr(u64)]
#[derive(TryFromPrimitive, IntoPrimitive)]
enum RequestCode {
    StoreList = code8(b"storlist"),
    StoreCreate = code8(b"storenew"),
    StoreDestroy = code8(b"storedel"),
    BlobHash = code8(b"blobhash"),

    BlobList = code8(b"bloblist"),
    BlobInfo = code8(b"blobinfo"),
    BlobLoad = code8(b"blobload"),
    BlobSave = code8(b"blobsave"),
    BlobDelete = code8(b"blobdrop"),
    Bye = code8(b"Goodbye!"),
}


pub trait Send: Sized {
    fn send(self, stream: &mut impl Write) -> Result<()>;
}

macro_rules! send {($stream: expr, $($item: expr), *) => {
    {$($item.send($stream)?;)*}
}}

pub fn send_open_door(stream: &mut impl Write) -> Result<()> {
    send!(stream, CODE_OPEN_DOOR, PROTO_VERSION);
    Ok(())
}

pub fn send_welcome(stream: &mut impl Write) -> Result<()> {
    GreetCode::Welcome.send(stream)
}

pub fn send_not_welcome(stream: &mut impl Write) -> Result<()> {
    send!(stream, GreetCode::NotWelcome, PROTO_VERSION);
    Ok(())
}

impl Send for &RequestRef<'_> {
    fn send(self, stream: &mut impl Write) -> Result<()> {
        match self {
            RequestRef::StoreList() =>
                send!(stream, RequestCode::StoreList),
            RequestRef::StoreCreate(store_id) =>
                send!(stream, RequestCode::StoreCreate, store_id),
            RequestRef::StoreDestroy(store_id) =>
                send!(stream, RequestCode::StoreDestroy, store_id),
            RequestRef::BlobHash(blob) =>
                send!(stream, RequestCode::BlobHash, blob),
            RequestRef::BlobList(store_id) =>
                send!(stream, RequestCode::BlobList, store_id),
            RequestRef::BlobInfo(store_id, blob_id) =>
                send!(stream, RequestCode::BlobInfo, store_id, blob_id),
            RequestRef::BlobLoad(store_id, blob_id) =>
                send!(stream, RequestCode::BlobLoad, store_id, blob_id),
            RequestRef::BlobSave(store_id, blob) =>
                send!(stream, RequestCode::BlobSave, store_id, blob),
            RequestRef::BlobDelete(store_id, blob_id) =>
                send!(stream, RequestCode::BlobDelete, store_id, blob_id),
            RequestRef::Bye =>
                send!(stream, RequestCode::Bye),
        }
        Ok(())
    }
}

impl Send for &Response {
    fn send(self, stream: &mut impl Write) -> Result<()> {
        match self {
            Response::Status(status) =>
                send!(stream, status),
            Response::StoreList(store_ids) =>
                send!(stream, Status::Okay, store_ids),
            Response::BlobHash(blob_id) =>
                send!(stream, Status::Okay, blob_id),
            Response::BlobList(blob_ids) =>
                send!(stream, Status::Okay, blob_ids),
            Response::BlobLoad(blob) =>
                send!(stream, Status::Okay, blob),
            Response::BlobSave((status, blob_id)) =>
                send!(stream, status, blob_id),
        }
        Ok(())
    }
}

impl Send for StoreIdRef<'_> {
    fn send(self, stream: &mut impl Write) -> Result<()> {
        let buffer = self.as_bytes();
        let size = log_ret_err!(u16::try_from(buffer.len()));
        size.send(stream)?;
        bytes_send(stream, buffer)
    }
}

impl Send for StoreIdsRef<'_> {
    fn send(self, stream: &mut impl Write) -> Result<()> {
        let size = log_ret_err!(u64::try_from(self.len()));
        size.send(stream)?;
        for store_id in self {
            store_id.send(stream)?;
        }
        Ok(())
    }
}

impl Send for BlobIdsRef<'_> {
    fn send(self, stream: &mut impl Write) -> Result<()> {
        let size = log_ret_err!(u64::try_from(self.len()));
        let buffer: Box<[u8]> = self.iter().cloned().flatten().collect();
        size.send(stream)?;
        bytes_send(stream, &buffer)
    }
}

impl Send for BlobRef<'_> {
    fn send(self, stream: &mut impl Write) -> Result<()> {
        let size = log_ret_err!(u64::try_from(self.len()));
        size.send(stream)?;
        bytes_send(stream, self)
    }
}

macro_rules! impl_send_for_enum {($($Enum: ty), +) => {$(
    impl Send for $Enum {
        fn send(self, stream: &mut impl Write) -> Result<()> {
            Code::from(self).send(stream)
        }
    }
)+}}
impl_send_for_enum!(GreetCode, RequestCode, Status);

macro_rules! impl_send_for_num {($($Num: ty), +) => {$(
    impl Send for $Num {
        fn send(self, stream: &mut impl Write) -> Result<()> {
            bytes_send(stream, &self.to_le_bytes())
        }
    }
)+}}
impl_send_for_num!(u16, u64);

impl<const SIZE: usize> Send for &[u8; SIZE] {
    fn send(self, stream: &mut impl Write) -> Result<()> {
        bytes_send(stream, self)
    }
}

fn bytes_send(stream: &mut impl Write, bytes: &[u8]) -> Result<()> {
    log_ret_err!(stream.write_all(bytes));
    Ok(())
}


pub trait Recv: Sized {
    fn recv(stream: &mut impl Read) -> Result<Self>;
}

pub fn recv_open_door(stream: &mut impl Read) -> Result<()> {
    let open_door = Code::recv(stream)?;
    let proto_version = ProtoVersion::recv(stream)?;
    match (open_door, proto_version) {
        (CODE_OPEN_DOOR, PROTO_VERSION) => Ok(()),
        _ => Err(Status::BadArgument),
    }
}

pub fn recv_welcome(stream: &mut impl Read) -> Result<()> {
    let code = GreetCode::recv(stream)?;
    match code {
        GreetCode::Welcome => Ok(()),
        GreetCode::NotWelcome => {
            let proto_version = ProtoVersion::recv(stream)?;
            eprintln!("recv_welcome: server says we are not welcome; \
                       client: v{PROTO_VERSION}, server: v{proto_version}");
            Err(Status::BadArgument)
        },
    }
}

impl Recv for Request {
    fn recv(stream: &mut impl Read) -> Result<Self> {
        let code: RequestCode = RequestCode::recv(stream)?;
        let request: Request = match code {
            RequestCode::StoreList =>
                Request::StoreList(),
            RequestCode::StoreCreate =>
                Request::StoreCreate(StoreId::recv(stream)?),
            RequestCode::StoreDestroy =>
                Request::StoreDestroy(StoreId::recv(stream)?),
            RequestCode::BlobHash =>
                Request::BlobHash(Blob::recv(stream)?),
            RequestCode::BlobList =>
                Request::BlobList(StoreId::recv(stream)?),
            RequestCode::BlobInfo =>
                Request::BlobInfo(StoreId::recv(stream)?, BlobId::recv(stream)?),
            RequestCode::BlobLoad =>
                Request::BlobLoad(StoreId::recv(stream)?, BlobId::recv(stream)?),
            RequestCode::BlobSave =>
                Request::BlobSave(StoreId::recv(stream)?, Blob::recv(stream)?),
            RequestCode::BlobDelete =>
                Request::BlobDelete(StoreId::recv(stream)?, BlobId::recv(stream)?),
            RequestCode::Bye =>
                Request::Bye,
        };
        Ok(request)
    }
}

impl Response {
    pub fn recv(stream: &mut impl Read, request_context: RequestRef)
            -> Result<Self> {
        let status: Status = Status::recv(stream)?;
        let response: Response = match (status, request_context) {
            (Status::BadArgument, _) =>
                Response::Status(Status::BadArgument),
            (Status::Okay, RequestRef::StoreList(..)) =>
                Response::StoreList(StoreIds::recv(stream)?),
            (Status::Okay, RequestRef::BlobHash(..)) =>
                Response::BlobHash(BlobId::recv(stream)?),
            (Status::Okay, RequestRef::BlobList(..)) =>
                Response::BlobList(BlobIds::recv(stream)?),
            (Status::Okay, RequestRef::BlobLoad(..)) =>
                Response::BlobLoad(Blob::recv(stream)?),
            (status, RequestRef::BlobSave(..)) =>
                Response::BlobSave((status, BlobId::recv(stream)?)),
            (status, _) =>
                Response::Status(status),
        };
        Ok(response)
    }
}

impl Recv for StoreId {
    fn recv(stream: &mut impl Read) -> Result<Self> {
        let size = u16::recv(stream)?;
        let store_id_bytes = bytes_recv(stream, size.into())?;
        let store_id = log_ret_err!(str::from_utf8(&store_id_bytes));
        Ok(store_id.into())
    }
}

impl Recv for StoreIds {
    fn recv(stream: &mut impl Read) -> Result<Self> {
        let num_elems_u64 = u64::recv(stream)?;
        let num_elems = log_ret_err!(usize::try_from(num_elems_u64));
        iter::repeat_with(|| StoreId::recv(stream)).take(num_elems).collect()
    }
}

impl Recv for BlobIds {
    fn recv(stream: &mut impl Read) -> Result<Self> {
        let num_elems_u64 = u64::recv(stream)?;
        let num_elems = log_ret_err!(usize::try_from(num_elems_u64));
        let size = num_elems * size_of::<BlobId>();
        let buffer = bytes_recv(stream, size)?;
        let blob_ids = buffer.into_iter().array_chunks().collect();
        Ok(blob_ids)
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

macro_rules! impl_recv_for_enum{($($Enum: ty), +) => {$(
    impl Recv for $Enum {
        fn recv(stream: &mut impl Read) -> Result<Self> {
            let val = Recv::recv(stream)?;
            let enumerant = log_ret_err!(Self::try_from_primitive(val));
            Ok(enumerant)
        }
    }
)+}}
impl_recv_for_enum!(GreetCode, RequestCode, Status);

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
        let mut bytes = [0u8; SIZE];
        log_ret_err!(stream.read_exact(&mut bytes));
        Ok(bytes)
    }
}

fn bytes_recv(stream: &mut impl Read, size: usize) -> Result<Box<[u8]>> {
    let mut bytes = unsafe {Box::new_uninit_slice(size).assume_init()};
    log_ret_err!(stream.read_exact(&mut bytes));
    Ok(bytes)
}

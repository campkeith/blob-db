use std::iter;
use std::cmp::min;
use std::io::{self, Read, Write};

use memmap2::Mmap;
use num_enum::{TryFromPrimitive, IntoPrimitive};

use crate::log_err;
use crate::funcs::code8;
use crate::types::{
    RequestIn, RequestOut, ResponseIn, ResponseOut,
    Status, SaveStatus, Result, Code,
    StoreId, StoreIds, BlobId, BlobIds, BlobStream, BlobFile, BlobSize,
    StoreIdRef, BlobRef,
};


type ProtoVersion = u16;
type StoreIdSize = u16;
type ArraySize = u64;

const PROTO_VERSION: ProtoVersion = 1;
const CODE_OPEN_DOOR: Code = code8(b"OpenDoor");

#[repr(u64)]
#[derive(Copy, Clone, TryFromPrimitive, IntoPrimitive)]
enum GreetCode {
    Welcome = code8(b"Welcome!"),
    NotWelcome = code8(b"Go away!"),
}

#[repr(u64)]
#[derive(Copy, Clone, TryFromPrimitive, IntoPrimitive)]
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


pub trait Send {
    fn send(&self, stream: &mut impl Write) -> Result<()>;
}

macro_rules! send {($stream: expr, $($item: expr),*) => {{
    $($item.send($stream)?;)*
    Ok(())
}}}

pub fn send_open_door(stream: &mut impl Write) -> Result<()> {
    send!(stream, CODE_OPEN_DOOR, PROTO_VERSION)
}

pub fn send_welcome(stream: &mut impl Write) -> Result<()> {
    GreetCode::Welcome.send(stream)
}

pub fn send_not_welcome(stream: &mut impl Write) -> Result<()> {
    send!(stream, GreetCode::NotWelcome, PROTO_VERSION)
}

impl Send for RequestOut<'_> {
    fn send(&self, stream: &mut impl Write) -> Result<()> {
        match self {
            RequestOut::StoreList() =>
                send!(stream, RequestCode::StoreList),
            RequestOut::StoreCreate(store_id) =>
                send!(stream, RequestCode::StoreCreate, store_id),
            RequestOut::StoreDestroy(store_id) =>
                send!(stream, RequestCode::StoreDestroy, store_id),
            RequestOut::BlobHash(blob) =>
                send!(stream, RequestCode::BlobHash, blob),
            RequestOut::BlobList(store_id) =>
                send!(stream, RequestCode::BlobList, store_id),
            RequestOut::BlobInfo(store_id, blob_id) =>
                send!(stream, RequestCode::BlobInfo, store_id, blob_id),
            RequestOut::BlobLoad(store_id, blob_id) =>
                send!(stream, RequestCode::BlobLoad, store_id, blob_id),
            RequestOut::BlobSave(store_id, blob) =>
                send!(stream, RequestCode::BlobSave, store_id, blob),
            RequestOut::BlobDelete(store_id, blob_id) =>
                send!(stream, RequestCode::BlobDelete, store_id, blob_id),
            RequestOut::Bye =>
                send!(stream, RequestCode::Bye),
        }
    }
}

impl Send for ResponseOut {
    fn send(&self, stream: &mut impl Write) -> Result<()> {
        match self {
            ResponseOut::Status(status) =>
                send!(stream, status),
            ResponseOut::StoreList(store_ids) =>
                send!(stream, Status::Okay, store_ids),
            ResponseOut::BlobHash(blob_id) =>
                send!(stream, Status::Okay, blob_id),
            ResponseOut::BlobList(blob_ids) =>
                send!(stream, Status::Okay, blob_ids),
            ResponseOut::BlobInfo(blob_size) =>
                send!(stream, Status::Okay, blob_size),
            ResponseOut::BlobLoad(blob) =>
                send!(stream, Status::Okay, blob),
            ResponseOut::BlobSave((status, blob_id)) =>
                send!(stream, status, blob_id),
        }
    }
}

impl Send for StoreIdRef<'_> {
    fn send(&self, stream: &mut impl Write) -> Result<()> {
        let buffer = self.as_bytes();
        let size = log_err!(?StoreIdSize::try_from(buffer.len()));
        size.send(stream)?;
        bytes_send(stream, buffer)
    }
}

impl Send for StoreIds {
    fn send(&self, stream: &mut impl Write) -> Result<()> {
        let size = log_err!(?ArraySize::try_from(self.len()));
        size.send(stream)?;
        for store_id in self {
            Send::send(&store_id.as_ref(), stream)?;
        }
        Ok(())
    }
}

impl Send for BlobId {
    fn send(&self, stream: &mut impl Write) -> Result<()> {
        let BlobId(hash) = self;
        bytes_send(stream, hash)
    }
}

impl Send for BlobIds {
    fn send(&self, stream: &mut impl Write) -> Result<()> {
        let size = log_err!(?ArraySize::try_from(self.len()));
        let buffer: Box<[u8]> = self.iter().map(|&BlobId(id)| id)
                                    .flatten().collect();
        size.send(stream)?;
        bytes_send(stream, &buffer)
    }
}

impl Send for BlobFile {
    fn send(&self, stream: &mut impl Write) -> Result<()> {
        let buf = &*log_err!(?unsafe{Mmap::map(self)});
        buf.send(stream)
    }
}

impl Send for BlobRef<'_> {
    fn send(&self, stream: &mut impl Write) -> Result<()> {
        let size = log_err!(?BlobSize::try_from(self.len()));
        size.send(stream)?;
        bytes_send(stream, self)
    }
}

macro_rules! impl_send_for_enum {($($Enum: ty), +) => {$(
    impl Send for $Enum {
        fn send(&self, stream: &mut impl Write) -> Result<()> {
            Code::from(*self).send(stream)
        }
    }
)+}}
impl_send_for_enum!(GreetCode, RequestCode, Status, SaveStatus);

macro_rules! impl_send_for_num {($($Num: ty), +) => {$(
    impl Send for $Num {
        fn send(&self, stream: &mut impl Write) -> Result<()> {
            bytes_send(stream, &self.to_le_bytes())
        }
    }
)+}}
impl_send_for_num!(u16, u64);

fn bytes_send(stream: &mut impl Write, bytes: &[u8]) -> Result<()> {
    log_err!(?stream.write_all(bytes));
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

impl<'a> RequestIn<'a> {
    pub fn recv(stream: &'a mut impl Read) -> Result<Self> {
        let code = RequestCode::recv(stream)?;
        Ok(match code {
            RequestCode::StoreList => RequestIn::StoreList(),
            RequestCode::StoreCreate => RequestIn::StoreCreate(
                StoreId::recv(stream)?),
            RequestCode::StoreDestroy => RequestIn::StoreDestroy(
                StoreId::recv(stream)?),
            RequestCode::BlobHash => RequestIn::BlobHash(
                BlobStream::recv(stream)?),
            RequestCode::BlobList => RequestIn::BlobList(
                StoreId::recv(stream)?),
            RequestCode::BlobInfo => RequestIn::BlobInfo(
                StoreId::recv(stream)?, BlobId::recv(stream)?),
            RequestCode::BlobLoad => RequestIn::BlobLoad(
                StoreId::recv(stream)?, BlobId::recv(stream)?),
            RequestCode::BlobSave => RequestIn::BlobSave(
                StoreId::recv(stream)?, BlobStream::recv(stream)?),
            RequestCode::BlobDelete => RequestIn::BlobDelete(
                StoreId::recv(stream)?, BlobId::recv(stream)?),
            RequestCode::Bye => RequestIn::Bye,
        })
    }
}

impl<'a> ResponseIn<'a> {
    pub fn recv(stream: &'a mut impl Read, request_context: RequestOut)
            -> Result<Self> {
        let status = Status::recv(stream)?;
        Ok(match (status, request_context) {
            (Status::Okay, RequestOut::StoreList(..)) => ResponseIn::StoreList(
                StoreIds::recv(stream)?),
            (Status::Okay, RequestOut::BlobHash(..)) => ResponseIn::BlobHash(
                BlobId::recv(stream)?),
            (Status::Okay, RequestOut::BlobList(..)) => ResponseIn::BlobList(
                BlobIds::recv(stream)?),
            (Status::Okay, RequestOut::BlobInfo(..)) => ResponseIn::BlobInfo(
                BlobSize::recv(stream)?),
            (Status::Okay, RequestOut::BlobLoad(..)) => ResponseIn::BlobLoad(
                BlobStream::recv(stream)?),
            (Status::Okay, RequestOut::BlobSave(..)) => ResponseIn::BlobSave(
                (SaveStatus::Created, BlobId::recv(stream)?)),
            (Status::Exists, RequestOut::BlobSave(..)) => ResponseIn::BlobSave(
                (SaveStatus::Exists, BlobId::recv(stream)?)),
            (status, _) => ResponseIn::Status(status),
        })
    }
}

impl Recv for StoreId {
    fn recv(stream: &mut impl Read) -> Result<Self> {
        let size = StoreIdSize::recv(stream)?;
        let store_id_bytes = bytes_recv(stream, size.into())?;
        let store_id = log_err!(?str::from_utf8(&store_id_bytes));
        Ok(store_id.into())
    }
}

impl Recv for StoreIds {
    fn recv(stream: &mut impl Read) -> Result<Self> {
        let array_size = ArraySize::recv(stream)?;
        let num_elems = log_err!(?usize::try_from(array_size));
        iter::repeat_with(|| StoreId::recv(stream)).take(num_elems).collect()
    }
}

impl Recv for BlobId {
    fn recv(stream: &mut impl Read) -> Result<Self> {
        let hash = Recv::recv(stream)?;
        Ok(BlobId(hash))
    }
}

impl Recv for BlobIds {
    fn recv(stream: &mut impl Read) -> Result<Self> {
        let array_size = ArraySize::recv(stream)?;
        let num_elems = log_err!(?usize::try_from(array_size));
        let size = num_elems * size_of::<BlobId>();
        let buffer = bytes_recv(stream, size)?;
        let blob_ids = buffer.into_iter().array_chunks().map(BlobId).collect();
        Ok(blob_ids)
    }
}

impl<'a> BlobStream<'a> {
    fn recv(stream: &'a mut impl Read) -> Result<Self> {
        let blob_size = BlobSize::recv(stream)?;
        let size = log_err!(?usize::try_from(blob_size));
        Ok(Self {
            bytes_remain: size,
            stream: stream,
        })
    }

    pub fn slurp(&mut self) -> Result<Box<[u8]>> {
        let buf = bytes_recv(&mut self.stream, self.bytes_remain)?;
        self.bytes_remain = 0;
        Ok(buf)
    }
}

impl<'a> Read for BlobStream<'a> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let bytes_goal = min(self.bytes_remain, buf.len());
        let bytes_read = self.stream.read(&mut buf[..bytes_goal])?;
        self.bytes_remain -= bytes_read;
        Ok(bytes_read)
    }
}

impl Drop for BlobStream<'_> {
    fn drop(&mut self) {
        let result = io::copy(self, &mut io::sink());
        if let Err(error) = result {
            eprintln!("BlobStream::drop: failed to drain {} remaining bytes: \
                       {error:?}: {error}", self.bytes_remain);
        }
    }
}

macro_rules! impl_recv_for_enum{($($Enum: ty), +) => {$(
    impl Recv for $Enum {
        fn recv(stream: &mut impl Read) -> Result<Self> {
            let val = Recv::recv(stream)?;
            let enumerant = log_err!(?Self::try_from_primitive(val));
            Ok(enumerant)
        }
    }
)+}}
impl_recv_for_enum!(GreetCode, RequestCode, Status, SaveStatus);

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
        log_err!(?stream.read_exact(&mut bytes));
        Ok(bytes)
    }
}

fn bytes_recv(stream: &mut impl Read, size: usize) -> Result<Box<[u8]>> {
    let mut bytes = unsafe {Box::new_uninit_slice(size).assume_init()};
    log_err!(?stream.read_exact(&mut bytes));
    Ok(bytes)
}

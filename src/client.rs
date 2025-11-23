use std::net::{TcpStream, ToSocketAddrs};
use std::fmt::{self, Debug};

use crate::{log_call, log_err};
use crate::types::{StoreIds, BlobId, BlobIdRef, BlobIds, BlobStream, BlobSize,
                   RequestOut, ResponseIn, Result, Status, SaveStatus};
use crate::send_recv::{send_open_door, recv_welcome, Send};
use crate::debug::format_addr;


macro_rules!
send_req_recv_val{($self: ident, $req_type: ident($($req_arg: expr), *)) => {{
    let request = RequestOut::$req_type($($req_arg,)*);
    request.send(&mut $self.stream)?;
    let response = ResponseIn::recv(&mut $self.stream, request)?;
    match response {
        ResponseIn::$req_type(val) => Ok(val),
        ResponseIn::Status(status) => Err(status),
        _ => {
            let (file, line) = (file!(), line!());
            eprintln!("{file}:{line}: Unexpected response: {response:?}");
            Err(Status::InternalError)
        },
    }
}}}

pub struct Client {
    stream: TcpStream,
}

impl Debug for Client {
    fn fmt(&self, out: &mut fmt::Formatter) -> fmt::Result {
        write!(out, "Client({} => {})",
                    format_addr(self.stream.local_addr()),
                    format_addr(self.stream.peer_addr()))
    }
}

impl Drop for Client {
    log_call!(
    fn drop(&mut self) {
        let result = RequestOut::Bye.send(&mut self.stream);
        if let Err(status) = result {
            eprintln!("Client::drop: failed to send Bye: {status:?}");
        }
    });
}

impl Client {
    log_call!(
    pub fn connect(address: impl ToSocketAddrs + Debug) -> Result<Self> {
        let stream = log_err!(?TcpStream::connect(address));
        let mut client = Client{stream};
        client.shake_hands()?;
        Ok(client)
    });

    fn shake_hands(&mut self) -> Result<()> {
        send_open_door(&mut self.stream)?;
        recv_welcome(&mut self.stream)
    }

    log_call!(
    pub fn store_list(&mut self) -> Result<StoreIds> {
        send_req_recv_val!(self, StoreList())
    });

    log_call!(
    pub fn store_create(&mut self, store_id: impl AsRef<str> + Debug)
            -> Result<()> {
        self.op_status_resp(RequestOut::StoreCreate(store_id.as_ref()))
    });

    log_call!(
    pub fn store_destroy(&mut self, store_id: impl AsRef<str> + Debug)
            -> Result<()> {
        self.op_status_resp(RequestOut::StoreDestroy(store_id.as_ref()))
    });

    log_call!(
    pub fn blob_hash(&mut self, blob: impl AsRef<[u8]> + Debug)
            -> Result<BlobId> {
        send_req_recv_val!(self, BlobHash(blob.as_ref()))
    });

    log_call!(
    pub fn blob_list(&mut self, store_id: impl AsRef<str> + Debug)
            -> Result<BlobIds> {
        send_req_recv_val!(self, BlobList(store_id.as_ref()))
    });

    log_call!(
    pub fn blob_info(&mut self, store_id: impl AsRef<str> + Debug,
                                blob_id: BlobIdRef)
            -> Result<BlobSize> {
        send_req_recv_val!(self, BlobInfo(store_id.as_ref(), blob_id))
    });

    log_call!({named_inner=blob_load_inner}
    pub fn blob_load<'a>(&'a mut self, store_id: impl AsRef<str> + Debug,
                                       blob_id: BlobIdRef)
            -> Result<BlobStream<'a>> {
        send_req_recv_val!(self, BlobLoad(store_id.as_ref(), blob_id))
    });

    log_call!(
    pub fn blob_save(&mut self, store_id: impl AsRef<str> + Debug,
                                blob: impl AsRef<[u8]> + Debug)
            -> Result<(SaveStatus, BlobId)> {
        send_req_recv_val!(self, BlobSave(store_id.as_ref(), blob.as_ref()))
    });

    log_call!(
    pub fn blob_delete(&mut self, store_id: impl AsRef<str> + Debug,
                                  blob_id: BlobIdRef)
            -> Result<()> {
        let request = RequestOut::BlobDelete(store_id.as_ref(), blob_id);
        self.op_status_resp(request)
    });

    fn op_status_resp(&mut self, request: RequestOut) -> Result<()> {
        request.send(&mut self.stream)?;
        let response = ResponseIn::recv(&mut self.stream, request)?;
        match response {
            ResponseIn::Status(status) => match status {
                Status::Okay => Ok(()),
                _ => Err(status),
            },
            _ => {
                eprintln!("op_status_resp: Unexpected response: {response:?}");
                Err(Status::InternalError)
            },
        }
    }
}

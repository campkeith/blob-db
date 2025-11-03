use std::net::{TcpStream, ToSocketAddrs};
use std::fmt::Debug;

use tracing::instrument;

use crate::{log_ret_err, log_err_ret_val, log_err};
use crate::types::{StoreIds, BlobId, BlobIdRef, BlobIds, Blob,
                   RequestRef, Response, Result, Status};
use crate::send_recv::{send_open_door, recv_welcome, Send};


macro_rules!
send_req_recv_val{($self: ident, $req_type: ident($($req_arg: expr), *)) => {{
    let request = RequestRef::$req_type($($req_arg,)*);
    request.send(&mut $self.stream)?;
    let response = Response::recv(&mut $self.stream, request)?;
    match response {
        Response::$req_type(val) => Ok(val),
        Response::Status(status) => Err(status),
        _ => {
            let (file, line) = (file!(), line!());
            eprintln!("{file}:{line}: Unexpected response: {response:?}");
            Err(Status::InternalError)
        },
    }
}}}

#[derive(Debug)]
pub struct Client {
    stream: TcpStream,
}

impl Drop for Client {
    fn drop(&mut self) {
        if let Err(status) = RequestRef::Bye.send(&mut self.stream) {
            eprintln!("Client::drop: failed to send Bye: {status:?}");
        }
    }
}

impl Client {
    #[instrument(ret)]
    pub fn connect(address: impl ToSocketAddrs + Debug) -> Result<Self> {
        let stream = log_ret_err!(TcpStream::connect(address));
        let mut client = Client{stream};
        client.shake_hands()?;
        Ok(client)
    }

    fn shake_hands(&mut self) -> Result<()> {
        send_open_door(&mut self.stream)?;
        recv_welcome(&mut self.stream)
    }

    #[instrument(ret)]
    pub fn store_list(&mut self) -> Result<StoreIds> {
        send_req_recv_val!(self, StoreList())
    }

    #[instrument(ret)]
    pub fn store_create(&mut self, store_id: impl AsRef<str> + Debug) -> Result<()> {
        self.op_status_resp(RequestRef::StoreCreate(store_id.as_ref()))
    }

    #[instrument(ret)]
    pub fn store_destroy(&mut self, store_id: impl AsRef<str> + Debug) -> Result<()> {
        self.op_status_resp(RequestRef::StoreDestroy(store_id.as_ref()))
    }

    #[instrument(ret)]
    pub fn blob_hash(&mut self, blob: impl AsRef<[u8]> + Debug) -> Result<BlobId> {
        send_req_recv_val!(self, BlobHash(blob.as_ref()))
    }

    #[instrument(ret)]
    pub fn blob_list(&mut self, store_id: impl AsRef<str> + Debug) -> Result<BlobIds> {
        send_req_recv_val!(self, BlobList(store_id.as_ref()))
    }

    #[instrument(ret)]
    pub fn blob_info(&mut self, store_id: impl AsRef<str> + Debug, blob_id: BlobIdRef)
            -> Result<()> {
        let request = RequestRef::BlobInfo(store_id.as_ref(), blob_id);
        self.op_status_resp(request)
    }

    #[instrument(ret)]
    pub fn blob_load(&mut self, store_id: impl AsRef<str> + Debug,
                                blob_id: BlobIdRef) -> Result<Blob> {
        send_req_recv_val!(self, BlobLoad(store_id.as_ref(), blob_id))
    }

    #[instrument(ret)]
    pub fn blob_save(&mut self, store_id: impl AsRef<str> + Debug,
                     blob: impl AsRef<[u8]> + Debug)
            -> Result<(Status, BlobId)> {
        send_req_recv_val!(self, BlobSave(store_id.as_ref(), blob.as_ref()))
    }

    #[instrument(ret)]
    pub fn blob_delete(&mut self, store_id: impl AsRef<str> + Debug, blob_id: BlobIdRef)
            -> Result<()> {
        let request = RequestRef::BlobDelete(store_id.as_ref(), blob_id);
        self.op_status_resp(request)
    }

    fn op_status_resp(&mut self, request: RequestRef) -> Result<()> {
        request.send(&mut self.stream)?;
        let response = Response::recv(&mut self.stream, request)?;
        match response {
            Response::Status(status) => match status {
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

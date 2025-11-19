use std::net::{TcpStream, ToSocketAddrs};
use std::fmt::{self, Debug};

use crate::{log_ret_err, log_err_ret_val, log_err, log_call};
use crate::types::{StoreIds, BlobId, BlobIdRef, BlobIds, Blob,
                   RequestRef, Response, Result, Status, SaveStatus};
use crate::send_recv::{send_open_door, recv_welcome, Send};
use crate::debug::format_addr;


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

pub struct Client {
    stream: TcpStream,
}

impl Debug for Client {
    fn fmt(&self, out: &mut fmt::Formatter) -> fmt::Result {
        let stream = &self.stream;
        write!(out, "Client({} => {})",
                    format_addr(stream.local_addr()),
                    format_addr(stream.peer_addr()))
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        log_call!(self.drop() ->
            if let Err(status) = RequestRef::Bye.send(&mut self.stream) {
                eprintln!("Client::drop: failed to send Bye: {status:?}");
            }
        )
    }
}

impl Client {
    pub fn connect(address: impl ToSocketAddrs + Debug) -> Result<Self> {
        log_call!(connect(address) -> {
            let stream = log_ret_err!(TcpStream::connect(address));
            let mut client = Client{stream};
            client.shake_hands()?;
            Ok(client)
        })
    }

    fn shake_hands(&mut self) -> Result<()> {
        send_open_door(&mut self.stream)?;
        recv_welcome(&mut self.stream)
    }

    pub fn store_list(&mut self) -> Result<StoreIds> {
        log_call!(self.store_list() ->
            send_req_recv_val!(self, StoreList())
        )
    }

    pub fn store_create(&mut self, store_id: impl AsRef<str> + Debug)
            -> Result<()> {
        log_call!(self.store_create(store_id) ->
            self.op_status_resp(RequestRef::StoreCreate(store_id.as_ref()))
        )
    }

    pub fn store_destroy(&mut self, store_id: impl AsRef<str> + Debug)
            -> Result<()> {
        log_call!(self.store_destroy(store_id) ->
            self.op_status_resp(RequestRef::StoreDestroy(store_id.as_ref()))
        )
    }

    pub fn blob_hash(&mut self, blob: impl AsRef<[u8]> + Debug)
            -> Result<BlobId> {
        log_call!(self.blob_hash(blob) ->
            send_req_recv_val!(self, BlobHash(blob.as_ref()))
        )
    }

    pub fn blob_list(&mut self, store_id: impl AsRef<str> + Debug)
            -> Result<BlobIds> {
        log_call!(self.blob_list(store_id) ->
            send_req_recv_val!(self, BlobList(store_id.as_ref()))
        )
    }

    pub fn blob_info(&mut self, store_id: impl AsRef<str> + Debug,
                                blob_id: BlobIdRef)
            -> Result<()> {
        log_call!(self.blob_info(store_id, blob_id) -> {
            let request = RequestRef::BlobInfo(store_id.as_ref(), blob_id);
            self.op_status_resp(request)
        })
    }

    pub fn blob_load(&mut self, store_id: impl AsRef<str> + Debug,
                                blob_id: BlobIdRef)
            -> Result<Blob> {
        log_call!(self.blob_load(store_id, blob_id) ->
            send_req_recv_val!(self, BlobLoad(store_id.as_ref(), blob_id))
        )
    }

    pub fn blob_save(&mut self, store_id: impl AsRef<str> + Debug,
                                blob: impl AsRef<[u8]> + Debug)
            -> Result<(SaveStatus, BlobId)> {
        log_call!(self.blob_save(store_id, blob) ->
            send_req_recv_val!(self, BlobSave(store_id.as_ref(), blob.as_ref()))
        )
    }

    pub fn blob_delete(&mut self, store_id: impl AsRef<str> + Debug,
                                  blob_id: BlobIdRef)
            -> Result<()> {
        log_call!(self.blob_delete(store_id, blob_id) -> {
            let request = RequestRef::BlobDelete(store_id.as_ref(), blob_id);
            self.op_status_resp(request)
        })
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

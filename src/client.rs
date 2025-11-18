use std::net::{TcpStream, ToSocketAddrs};
use std::fmt::Debug;

use crate::{log_ret_err, log_err_ret_val, log_err, log_call};
use crate::types::{StoreIds, BlobId, BlobIdRef, BlobIds, Blob,
                   RequestRef, Response, Result, Status};
use crate::send_recv::{send_open_door, recv_welcome, Send};
use crate::trace::Trace;


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

impl Trace for Client {
    fn trace(&self) -> String {
        format!("{self:?}")
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        log_call!(Client::drop[] ->
            if let Err(status) = RequestRef::Bye.send(&mut self.stream) {
                eprintln!("Client::drop: failed to send Bye: {status:?}");
            }
        )
    }
}

impl Client {
    pub fn connect(address_in: impl ToSocketAddrs + Debug) -> Result<Self> {
        let address_dbg = format!("{address_in:?}");
        let address = &address_dbg[1 .. address_dbg.len() - 1];
        log_call!(Client::connect[address] -> {
            let stream = log_ret_err!(TcpStream::connect(address_in));
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
        log_call!(Client::store_list[] ->
            send_req_recv_val!(self, StoreList())
        )
    }

    pub fn store_create(&mut self, store_id_in: impl AsRef<str>) -> Result<()> {
        let store_id = store_id_in.as_ref();
        log_call!(Client::store_create[store_id] ->
            self.op_status_resp(RequestRef::StoreCreate(store_id))
        )
    }

    pub fn store_destroy(&mut self, store_id_in: impl AsRef<str>) -> Result<()> {
        let store_id = store_id_in.as_ref();
        log_call!(Client::store_destroy[store_id] ->
            self.op_status_resp(RequestRef::StoreDestroy(store_id))
        )
    }

    pub fn blob_hash(&mut self, blob_in: impl AsRef<[u8]>) -> Result<BlobId> {
        let blob = blob_in.as_ref();
        log_call!(Client::blob_hash[blob] ->
            send_req_recv_val!(self, BlobHash(blob))
        )
    }

    pub fn blob_list(&mut self, store_id_in: impl AsRef<str>)
            -> Result<BlobIds> {
        let store_id = store_id_in.as_ref();
        log_call!(Client::blob_list[store_id] ->
            send_req_recv_val!(self, BlobList(store_id))
        )
    }

    pub fn blob_info(&mut self, store_id_in: impl AsRef<str>,
                     blob_id: BlobIdRef)
            -> Result<()> {
        let store_id = store_id_in.as_ref();
        log_call!(Client::blob_info[store_id, blob_id] -> {
            let request = RequestRef::BlobInfo(store_id, blob_id);
            self.op_status_resp(request)
        })
    }

    pub fn blob_load(&mut self, store_id_in: impl AsRef<str>,
                                blob_id: BlobIdRef) -> Result<Blob> {
        let store_id = store_id_in.as_ref();
        log_call!(Client::blob_load[store_id, blob_id] -> {
            send_req_recv_val!(self, BlobLoad(store_id, blob_id))
        })
    }

    pub fn blob_save(&mut self, store_id_in: impl AsRef<str>,
                     blob_in: impl AsRef<[u8]>)
            -> Result<(Status, BlobId)> {
        let store_id = store_id_in.as_ref();
        let blob = blob_in.as_ref();
        log_call!(Client::blob_save[store_id, blob] ->
            send_req_recv_val!(self, BlobSave(store_id, blob))
        )
    }

    pub fn blob_delete(&mut self, store_id_in: impl AsRef<str>,
                       blob_id: BlobIdRef)
            -> Result<()> {
        let store_id = store_id_in.as_ref();
        log_call!(Client::blob_delete[store_id, blob_id] -> {
            let request = RequestRef::BlobDelete(store_id, blob_id);
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

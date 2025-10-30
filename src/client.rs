use std::net::TcpStream;

use crate::{log_ret_err, log_err_ret_val, log_err};
use crate::types::{Name, Names, Hash, Hashes, Blob,
                   Request, Response, Result, Status};
use crate::send_recv::{send_open_door, recv_welcome, Send, Recv};


macro_rules!
send_req_recv_val{($self: ident, $req_type: ident($($req_arg: expr), *)) => {{
    let request = Request::$req_type($($req_arg,)*);
    (&request).send(&mut $self.stream)?;
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

struct Client {
    stream: TcpStream,
}

#[allow(dead_code)]
impl Client {
    pub fn connect(address: Box<str>) -> Result<Self> {
        let stream = log_ret_err!(TcpStream::connect(&*address));
        let mut client = Client{stream};
        client.shake_hands()?;
        Ok(client)
    }

    fn shake_hands(&mut self) -> Result<()> {
        send_open_door(&mut self.stream)?;
        recv_welcome(&mut self.stream)
    }

    pub fn store_list(&mut self) -> Result<Names> {
        send_req_recv_val!(self, StoreList())
    }

    pub  fn store_create(&mut self, name: Name) -> Result<()> {
        self.op_status_resp(Request::StoreCreate(name))
    }

    pub fn store_destroy(&mut self, name: Name) -> Result<()> {
        self.op_status_resp(Request::StoreDestroy(name))
    }

    pub fn blob_hash(&mut self, blob: Blob) -> Result<Hash> {
        send_req_recv_val!(self, BlobHash(blob))
    }

    pub fn blob_list(&mut self, store_name: Name) -> Result<Hashes> {
        send_req_recv_val!(self, BlobList(store_name))
    }

    pub fn blob_info(&mut self, store_name: Name, hash: Hash) -> Result<()> {
        self.op_status_resp(Request::BlobInfo(store_name, hash))
    }

    pub fn blob_load(&mut self, store_name: Name, hash: Hash) -> Result<Blob> {
        send_req_recv_val!(self, BlobLoad(store_name, hash))
    }

    pub fn blob_save(&mut self, store_name: Name, blob: Blob)
            -> Result<(Status, Hash)> {
        send_req_recv_val!(self, BlobSave(store_name, blob))
    }

    pub fn blob_delete(&mut self, store_name: Name, hash: Hash) -> Result<()> {
        self.op_status_resp(Request::BlobDelete(store_name, hash))
    }

    fn op_status_resp(&mut self, request: Request) -> Result<()> {
        request.send(&mut self.stream)?;
        let status = Status::recv(&mut self.stream)?;
        match status {
            Status::Okay => Ok(()),
            _ => Err(status),
        }
    }
}

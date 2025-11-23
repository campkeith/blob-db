use std::fmt;
use std::net::{TcpListener, TcpStream};

use crate::{log_call, log_err};
use crate::funcs;
use crate::persister::Persister;
use crate::types::{RequestIn, ResponseOut, Result, Status};
use crate::send_recv::{recv_open_door, send_welcome, send_not_welcome, Send};
use crate::debug::format_addr;

pub struct Server {
    inner: Persister,
    address: Box<str>,
}

impl fmt::Debug for Server {
    fn fmt(&self, out: &mut fmt::Formatter) -> fmt::Result {
        out.debug_tuple("Server")
           .field(&self.address)
           .finish()
    }
}

impl Server {
    pub fn create(inner: Persister) -> Result<Self> {
        let server = Server{
            inner,
            address: funcs::env("BIND_ADDRESS")?,
        };
        Ok(server)
    }

    pub fn go(&mut self) -> Result<()> {
        let listener = log_err!(?TcpListener::bind(self.address.as_ref()));
        println!("Server at {} is up.", format_addr(listener.local_addr()));
        for stream_result in listener.incoming() {
            match stream_result {
                Err(error) =>
                    eprintln!("Error connecting to client: {error:?}: {error}"),
                Ok(mut stream) =>
                    self.client_session(&mut stream),
            }
        }
        eprintln!("TcpListener::incoming iterator terminated unexpectedly.");
        Err(Status::InternalError)
    }

    fn client_session(&mut self, stream: &mut TcpStream) {
        let peer_str = format_addr(stream.peer_addr());
        println!("Client at {peer_str} connected.");
        let result = self.handle_stream(stream);
        match result {
            Ok(_) => println!("Client at {peer_str} disconnected."),
            Err(status) => {
                eprintln!("Dropping client at {peer_str} due to {status:?}.");
            }
        }
    }

    fn handle_stream(&mut self, stream: &mut TcpStream) -> Result<()> {
        self.shake_hands(stream)?;
        while self.handle_request(stream)? {}
        Ok(())
    }

    fn shake_hands(&self, stream: &mut TcpStream) -> Result<()> {
        let result = recv_open_door(stream);
        match result {
            Ok(()) => send_welcome(stream),
            Err(status) => {
                if status == Status::BadArgument {
                    send_not_welcome(stream)?;
                }
                Err(status)
            }
        }
    }

    fn handle_request(&mut self, stream: &mut TcpStream) -> Result<bool> {
        let opt_response = {
            let mut request = RequestIn::recv(stream)?;
            self.process_request(&mut request)
        };
        match opt_response {
            Some(response) => {
                response.send(stream)?;
                Ok(true)
            },
            None => Ok(false),
        }
    }

    log_call!(
    fn process_request<'a>(&mut self, request: &mut RequestIn)
            -> Option<ResponseOut> {
        macro_rules! ret_err_resp{($result:expr) => {
            match $result {
                Ok(val) => val,
                Err(status) => return Some(ResponseOut::Status(status)),
            }
        }}

        fn status_resp(result: Result<()>) -> ResponseOut {
            ResponseOut::Status(match result {
                Ok(()) => Status::Okay,
                Err(status) => status,
            })
        }

        match request {
            RequestIn::StoreList() => Some(ResponseOut::StoreList(
                ret_err_resp!(self.inner.store_list()))),
            RequestIn::StoreCreate(store_id) => Some(status_resp(
                self.inner.store_create(store_id))),
            RequestIn::StoreDestroy(store_id) => Some(status_resp(
                self.inner.store_destroy(store_id))),
            RequestIn::BlobHash(blob_stream) => Some(ResponseOut::BlobHash(
                ret_err_resp!(funcs::hash(blob_stream)))),
            RequestIn::BlobList(store_id) => Some(ResponseOut::BlobList(
                ret_err_resp!(self.inner.blob_list(store_id)))),
            RequestIn::BlobInfo(store_id, blob_id) => Some(ResponseOut::BlobInfo(
                ret_err_resp!(self.inner.blob_info(store_id, blob_id)))),
            RequestIn::BlobLoad(store_id, blob_id) => Some(ResponseOut::BlobLoad(
                ret_err_resp!(self.inner.blob_load(store_id, blob_id)))),
            RequestIn::BlobSave(store_id, blob) => Some(ResponseOut::BlobSave(
                ret_err_resp!(self.inner.blob_save(store_id, blob)))),
            RequestIn::BlobDelete(store_id, blob_id) => Some(status_resp(
                self.inner.blob_delete(store_id, blob_id))),
            RequestIn::Bye => None,
        }
    });
}

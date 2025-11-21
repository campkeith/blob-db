use std::fmt;
use std::net::{TcpListener, TcpStream};

use crate::{log_ret_err, log_err_ret_val, log_err, log_call};
use crate::funcs;
use crate::persister::Persister;
use crate::types::{Request, Response, Result, Status};
use crate::send_recv::{recv_open_door, send_welcome, send_not_welcome, Send};

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
        let listener = log_ret_err!(TcpListener::bind(self.address.as_ref()));
        for stream_result in listener.incoming() {
            match stream_result {
                Err(error) => {
                    eprintln!("Error connecting to client: {error:?}: {error}");
                }
                Ok(mut stream) => {
                    self.client_session(&mut stream);
                }
            }
        }
        eprintln!("go: exiting accept loop...");
        Ok(())
    }

    fn client_session(&mut self, stream: &mut TcpStream) {
        let peer_str = format_peer_addr(stream);
        println!("Client {peer_str} connected.");
        let result = self.handle_stream(stream);
        match result {
            Ok(_) => println!("Client {peer_str} disconnected."),
            Err(status) => {
                eprintln!("Dropping client {peer_str} due to {status:?}.");
            }
        }
    }

    fn handle_stream(&mut self, stream: &mut TcpStream) -> Result<()> {
        self.shake_hands(stream)?;
        let mut run = true;
        while run {
            run = self.handle_request(stream)?;
        }
        Ok(())
    }

    fn shake_hands(&self, stream: &mut TcpStream) -> Result<()> {
        let result = recv_open_door(stream);
        match result {
            Ok(_) => send_welcome(stream),
            Err(Status::BadArgument) => send_not_welcome(stream),
            _ => result,
        }
    }

    fn handle_request(&mut self, stream: &mut TcpStream) -> Result<bool> {
        let opt_response = {
            let mut request = Request::recv(stream)?;
            log_call!(self.process_request(request) ->
                self.process_request(&mut request)
            )
        };
        match opt_response {
            Some(response) => {
                response.send(stream)?;
                Ok(true)
            },
            None => Ok(false),
        }
    }

    fn process_request<'a>(&mut self, request: &mut Request) -> Option<Response> {
        match request {
            Request::StoreList() => {
                let result = self.inner.store_list();
                Some(match result {
                    Ok(list) => Response::StoreList(list),
                    Err(status) => Response::Status(status),
                })
            },
            Request::StoreCreate(store_id) => {
                let status = self.inner.store_create(store_id);
                Some(Response::Status(status))
            },
            Request::StoreDestroy(store_id) => {
                let status = self.inner.store_destroy(store_id);
                Some(Response::Status(status))
            },
            Request::BlobHash(blob_stream) => {
                let result = funcs::hash(blob_stream, blob_stream.bytes_remain);
                Some(match result {
                    Ok(blob_id) => Response::BlobHash(blob_id),
                    Err(status) => Response::Status(status),
                })
            },
            Request::BlobList(store_id) => {
                let result = self.inner.blob_list(store_id);
                Some(match result {
                    Ok(list) => Response::BlobList(list),
                    Err(status) => Response::Status(status),
                })
            },
            Request::BlobInfo(store_id, blob_id) => {
                let status = self.inner.blob_info(store_id, blob_id);
                Some(Response::Status(status))
            },
            Request::BlobLoad(store_id, blob_id) => {
                let result = self.inner.blob_load(store_id, blob_id);
                Some(match result {
                    Ok(blob) => Response::BlobLoad(blob),
                    Err(status) => Response::Status(status),
                })
            },
            Request::BlobSave(store_id, blob) => {
                let result = self.inner.blob_save(store_id, blob);
                Some(match result {
                    Ok(status_id) => Response::BlobSave(status_id),
                    Err(status) => Response::Status(status),
                })
            },
            Request::BlobDelete(store_id, blob_id) => {
                let status = self.inner.blob_delete(store_id, blob_id);
                Some(Response::Status(status))
            }
            Request::Bye => None,
        }
    }
}

fn format_peer_addr(conn: &TcpStream) -> Box<str> {
    match conn.peer_addr() {
        Ok(peer) => format!("{peer:?}").into(),
        Err(_) => "???".into(),
    }
}

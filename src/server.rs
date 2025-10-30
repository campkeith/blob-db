use std::net::{TcpListener, TcpStream};

use crate::{log_ret_err, log_err_ret_val, log_err};
use crate::persister::Persister;
use crate::types::{Request, Response, Result, Status};
use crate::send_recv::{recv_open_door, send_welcome, send_not_welcome,
                       Send, Recv};

struct Server {
    inner: Persister,
    address: Box<str>,
}

impl Server {
    #[allow(dead_code)]
    fn go(&self) -> Result<()> {
        let listener = log_ret_err!(TcpListener::bind(&*self.address));
        for stream_result in listener.incoming() {
            match stream_result {
                Err(error) => {
                    eprintln!("Error connecting to client: {error:?}: {error}");
                }
                Ok(mut stream) => {
                    _ = self.handle_conn(&mut stream);
                }
            }
        }
        eprintln!("go: exiting accept loop...");
        Ok(())
    }

    fn handle_conn(&self, stream: &mut TcpStream) -> Result<()> {
        self.shake_hands(stream)?;
        loop {
            self.handle_request(stream)?;
        }
    }

    fn shake_hands(&self, stream: &mut TcpStream) -> Result<()> {
        let result = recv_open_door(stream);
        match result {
            Ok(_) => send_welcome(stream),
            Err(Status::BadArgument) => send_not_welcome(stream),
            _ => result,
        }
    }

    fn handle_request(&self, stream: &mut TcpStream) -> Result<()> {
        let request = Request::recv(stream)?;
        let response = self.process_request(&request);
        response.send(stream)
    }

    fn process_request<'a>(&self, request: &Request) -> Response {
        match request {
            Request::StoreList() => {
                let result = self.inner.store_list();
                match result {
                    Ok(list) => Response::StoreList(list),
                    Err(status) => Response::Status(status),
                }
            },
            Request::StoreCreate(name) => {
                let status = self.inner.store_create(name);
                Response::Status(status)
            },
            Request::StoreDestroy(name) => {
                let status = self.inner.store_destroy(name);
                Response::Status(status)
            },
            Request::BlobHash(blob) => {
                let hash = self.inner.blob_hash(&blob);
                Response::BlobHash(hash)
            },
            Request::BlobList(store_name) => {
                let result = self.inner.blob_list(store_name);
                match result {
                    Ok(list) => Response::BlobList(list),
                    Err(status) => Response::Status(status),
                }
            },
            Request::BlobInfo(store_name, hash) => {
                let status = self.inner.blob_info(store_name, hash);
                Response::Status(status)
            },
            Request::BlobLoad(store_name, hash) => {
                let result = self.inner.blob_load(store_name, hash);
                match result {
                    Ok(blob) => Response::BlobLoad(blob),
                    Err(status) => Response::Status(status),
                }
            },
            Request::BlobSave(store_name, blob) => {
                let (status, hash) = self.inner.blob_save(store_name, &blob);
                Response::BlobSave((status, hash))
            },
            Request::BlobDelete(store_name, hash) => {
                let status = self.inner.blob_delete(store_name, hash);
                Response::Status(status)
            }
        }
    }
}

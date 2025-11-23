#![feature(array_try_map)]
#![feature(iter_array_chunks)]
#![feature(buf_read_has_data_left)]

mod macros;

pub mod types;
pub mod funcs;
pub mod client;
pub mod server;
pub mod persister;
mod send_recv;
mod debug;

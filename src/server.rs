use clap::Parser;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};

#[derive(Parser)]
struct Args {
    address: String,
}

fn handler(mut stream: TcpStream) -> std::io::Result<()> {
    let mut buf = [0u8; 64];
    let bytes_read = stream.read(&mut buf)?;
    let string = str::from_utf8(&buf[..bytes_read]).unwrap();
    println!("{string}");
    stream.write(b"Welcome to Blobs \"R\" Us!")?;
    Ok(())
}

fn main() -> std::io::Result<()> {
    let args = Args::parse();
    let listener = TcpListener::bind(args.address)?;
    for stream in listener.incoming() {
        let _ = handler(stream?);
    }
    Ok(())
}

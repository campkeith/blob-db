use clap::Parser;
use std::io::{Read, Write};
use std::net::TcpStream;

#[derive(Parser)]
struct Args {
    address: String,
}

fn main() -> std::io::Result<()> {
    let args = Args::parse();
    let mut stream = TcpStream::connect(args.address)?;
    stream.write(b"[Opens door.]")?;
    let mut buf = [0u8; 64];
    let bytes_read = stream.read(&mut buf)?;
    let string = str::from_utf8(&buf[..bytes_read]).unwrap();
    println!("{string}");
    Ok(())
}

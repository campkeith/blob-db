use blob_db::server::Server;
use blob_db::persister::Persister;
use blob_db::types::Result;


fn main() -> Result<()> {
    let persister = Persister::create()?;
    let mut server = Server::create(persister)?;
    server.go()
}

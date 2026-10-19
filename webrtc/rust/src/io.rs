//! I/O error/trait surface for the protocol core.
//!
//! With the `std` feature this re-exports `std::io`, so public
//! signatures are unchanged. Without it (bare metal), it provides
//! the minimal `Error`/`ErrorKind`/`Result`/`Read`/`Write` surface
//! the DTLS/TLS core actually uses.

#[cfg(feature = "std")]
pub use std::io::{Error, ErrorKind, Read, Result, Write};

#[cfg(not(feature = "std"))]
pub use self::shim::{Error, ErrorKind, Read, Result, Write};

#[cfg(not(feature = "std"))]
mod shim {
    use alloc::string::String;
    use core::fmt;

    pub type Result<T> = core::result::Result<T, Error>;

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum ErrorKind {
        InvalidData,
        InvalidInput,
        UnexpectedEof,
        WouldBlock,
        TimedOut,
        BrokenPipe,
        ConnectionReset,
        NotConnected,
        Interrupted,
        Other,
    }

    #[derive(Clone, Debug)]
    pub struct Error {
        kind: ErrorKind,
        message: String,
    }

    impl Error {
        pub fn new(kind: ErrorKind, message: impl Into<String>) -> Self {
            Self { kind, message: message.into() }
        }

        pub fn kind(&self) -> ErrorKind {
            self.kind
        }
    }

    impl fmt::Display for Error {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            write!(f, "{}", self.message)
        }
    }

    impl core::error::Error for Error {}

    pub trait Read {
        fn read(&mut self, buf: &mut [u8]) -> Result<usize>;

        fn read_exact(&mut self, mut buf: &mut [u8]) -> Result<()> {
            while !buf.is_empty() {
                match self.read(buf) {
                    Ok(0) => {
                        return Err(Error::new(
                            ErrorKind::UnexpectedEof,
                            "failed to fill whole buffer",
                        ))
                    }
                    Ok(n) => {
                        let tmp = buf;
                        buf = &mut tmp[n..];
                    }
                    Err(e) => return Err(e),
                }
            }
            Ok(())
        }
    }

    pub trait Write {
        fn write(&mut self, buf: &[u8]) -> Result<usize>;
        fn flush(&mut self) -> Result<()>;

        fn write_all(&mut self, mut buf: &[u8]) -> Result<()> {
            while !buf.is_empty() {
                match self.write(buf) {
                    Ok(0) => {
                        return Err(Error::new(
                            ErrorKind::BrokenPipe,
                            "failed to write whole buffer",
                        ))
                    }
                    Ok(n) => buf = &buf[n..],
                    Err(e) => return Err(e),
                }
            }
            Ok(())
        }
    }
}

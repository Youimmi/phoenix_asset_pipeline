use brotli::{BrotliCompress, enc::backward_references::BrotliEncoderParams};
use rustler::{Binary, Env, Error, NifResult, OwnedBinary};
use std::io::{self, Cursor, Write};

struct BinaryWriter {
    binary: OwnedBinary,
    len: usize,
}

impl BinaryWriter {
    fn new(capacity: usize) -> NifResult<Self> {
        let binary = OwnedBinary::new(capacity)
            .ok_or_else(|| Error::Term(Box::new("brotli alloc error")))?;

        Ok(Self { binary, len: 0 })
    }

    fn into_binary<'a>(mut self, env: Env<'a>) -> NifResult<Binary<'a>> {
        self.resize(self.len)
            .map_err(|_| Error::Term(Box::new("brotli alloc error")))?;

        Ok(Binary::from_owned(self.binary, env))
    }

    fn reserve(&mut self, additional: usize) -> io::Result<()> {
        let required = self
            .len
            .checked_add(additional)
            .ok_or_else(|| io::Error::other("brotli output too large"))?;

        if required <= self.binary.len() {
            return Ok(());
        }

        let mut capacity = self.binary.len().max(1);

        while capacity < required {
            capacity = capacity
                .checked_mul(2)
                .ok_or_else(|| io::Error::other("brotli output too large"))?;
        }

        self.resize(capacity)
    }

    fn resize(&mut self, capacity: usize) -> io::Result<()> {
        if self.binary.realloc(capacity) {
            return Ok(());
        }

        let mut binary =
            OwnedBinary::new(capacity).ok_or_else(|| io::Error::other("brotli alloc error"))?;

        binary.as_mut_slice()[..self.len].copy_from_slice(&self.binary.as_slice()[..self.len]);
        self.binary = binary;

        Ok(())
    }
}

impl Write for BinaryWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.write_all(buf)?;
        Ok(buf.len())
    }

    fn write_all(&mut self, buf: &[u8]) -> io::Result<()> {
        self.reserve(buf.len())?;

        let next = self.len + buf.len();
        self.binary.as_mut_slice()[self.len..next].copy_from_slice(buf);
        self.len = next;

        Ok(())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn compress<'a>(env: Env<'a>, data: Binary<'a>, quality: u32) -> NifResult<Binary<'a>> {
    if quality > 11 {
        return Err(Error::BadArg);
    }

    let mut input = Cursor::new(data.as_slice());
    let mut output = BinaryWriter::new(data.len().saturating_add(64).max(32))?;
    let params = BrotliEncoderParams {
        lgwin: 22,
        quality: quality as i32,
        size_hint: data.len(),
        ..BrotliEncoderParams::default()
    };

    BrotliCompress(&mut input, &mut output, &params)
        .map_err(|_| Error::Term(Box::new("brotli write error")))?;

    output.into_binary(env)
}

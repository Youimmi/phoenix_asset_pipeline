use crate::binary::BinaryBuilder;
use mbrotli::{Compressor, EncoderConfig, InputSize, Quality, RetentionPolicy};
use rustler::{Binary, Env, Error, NifResult};
use std::{
    cell::RefCell,
    io::{self, Write},
};

thread_local! {
    static COMPRESSOR: RefCell<Compressor> = RefCell::new(
        Compressor::builder(EncoderConfig::default())
            .with_retention(RetentionPolicy::Bounded { max_bytes: 16 * 1024 * 1024 })
            .build()
            .expect("valid Brotli defaults")
    );
}

struct BinaryWriter {
    builder: BinaryBuilder,
    overflowed: bool,
}

impl BinaryWriter {
    fn into_binary<'a>(self, env: Env<'a>) -> Binary<'a> {
        self.builder.finish(env)
    }

    fn new(capacity: usize, limit: usize) -> Self {
        Self {
            builder: BinaryBuilder::new(capacity, limit),
            overflowed: false,
        }
    }
}

impl Write for BinaryWriter {
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }

    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.write_all(buf)?;
        Ok(buf.len())
    }

    fn write_all(&mut self, buf: &[u8]) -> io::Result<()> {
        if self.builder.push(buf) {
            Ok(())
        } else {
            self.overflowed = true;
            Err(io::Error::other("brotli output is not smaller than input"))
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
pub fn compress<'a>(env: Env<'a>, data: Binary<'a>, quality: u32) -> NifResult<Binary<'a>> {
    let quality = u8::try_from(quality).map_err(|_| Error::BadArg)?;
    let quality = Quality::try_from(quality).map_err(|_| Error::BadArg)?;

    COMPRESSOR.with_borrow_mut(|compressor| {
        compressor
            .reconfigure(EncoderConfig::default().with_quality(quality))
            .map_err(|_| Error::BadArg)?;

        let mut output = BinaryWriter::new(data.len().clamp(32, 256 * 1024), data.len());
        let result = compressor
            .writer(&mut output, InputSize::Exact(data.len() as u64).into())
            .map_err(io::Error::other)
            .and_then(|mut writer| {
                writer.write_all(data.as_slice())?;
                writer
                    .finish()
                    .map(|_| ())
                    .map_err(mbrotli::io::FinishError::into_error)
            });

        if result.is_err() {
            return if output.overflowed {
                Ok(data)
            } else {
                Err(Error::Term(Box::new("brotli write error")))
            };
        }

        Ok(output.into_binary(env))
    })
}

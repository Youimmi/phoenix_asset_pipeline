use rustler::{Binary, Env, OwnedBinary};

pub struct BinaryBuilder {
    binary: OwnedBinary,
    len: usize,
    limit: usize,
}

impl BinaryBuilder {
    pub fn finish<'a>(mut self, env: Env<'a>) -> Binary<'a> {
        self.resize(self.len);
        Binary::from_owned(self.binary, env)
    }

    pub fn new(capacity: usize, limit: usize) -> Self {
        Self {
            binary: OwnedBinary::new(capacity),
            len: 0,
            limit,
        }
    }

    pub fn push(&mut self, bytes: &[u8]) -> bool {
        let Some(len) = self.len.checked_add(bytes.len()) else {
            return false;
        };

        if len > self.limit {
            return false;
        }

        if len > self.binary.len() {
            let capacity = len
                .checked_next_power_of_two()
                .unwrap_or(self.limit)
                .min(self.limit);
            self.resize(capacity);
        }

        self.binary.as_mut_slice()[self.len..len].copy_from_slice(bytes);
        self.len = len;
        true
    }

    fn resize(&mut self, capacity: usize) {
        if capacity != self.binary.len() && !self.binary.realloc(capacity) {
            let mut binary = OwnedBinary::new(capacity);
            binary.as_mut_slice()[..self.len].copy_from_slice(&self.binary.as_slice()[..self.len]);
            self.binary = binary;
        }
    }
}

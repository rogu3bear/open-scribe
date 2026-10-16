//! Operational counters for ordinary v1 journal replacement. Latency is an
//! observation on this host, not a capture-deadline or performance guarantee.
use std::io::{self, Write};
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct JournalCost {
    pub appends: u64,
    pub bytes_validated: u64,
    pub bytes_copied: u64,
    pub bytes_written: u64,
    pub write_calls: u64,
    pub sync_calls: u64,
    pub elapsed_nanoseconds: u128,
}
pub(super) struct CountedWriter<'a, W> {
    pub inner: &'a mut W,
    pub cost: &'a mut JournalCost,
}
impl<W: Write> Write for CountedWriter<'_, W> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.cost.write_calls += 1;
        let written = self.inner.write(bytes)?;
        self.cost.bytes_written += written as u64;
        Ok(written)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.inner.flush()
    }
}

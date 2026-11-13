//! Lowercase hex SHA-256, the one encoding every stored digest uses.

use super::*;

pub(crate) use open_scribe_types::lowercase_hex;

pub(crate) fn sha256_hex(bytes: &[u8]) -> String {
    lowercase_hex(&Sha256::digest(bytes))
}

pub(crate) fn digest_json(value: &impl Serialize) -> Result<String, StoreError> {
    Ok(sha256_hex(&serde_json::to_vec(value)?))
}

/// A stored digest: 64 lowercase hex digits.
pub(crate) fn is_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// Hashes `reader` from its current position to its end.
pub(crate) fn sha256_to_end(reader: &mut impl Read) -> Result<String, StoreError> {
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(lowercase_hex(&hasher.finalize()))
}

/// Hashes exactly `length` bytes from the current position. A reader that
/// ends first fails with `ended_early`; bytes past `length` are not read.
pub(crate) fn sha256_of_length(
    reader: &mut impl Read,
    length: u64,
    ended_early: &'static str,
) -> Result<String, StoreError> {
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; 1024 * 1024];
    let mut remaining = length;
    while remaining > 0 {
        let limit = remaining.min(buffer.len() as u64) as usize;
        let read = reader.read(&mut buffer[..limit])?;
        if read == 0 {
            return Err(StoreError::IntegrityMismatch(ended_early));
        }
        hasher.update(&buffer[..read]);
        remaining -= read as u64;
    }
    Ok(lowercase_hex(&hasher.finalize()))
}

/// Hashes a whole file by position, leaving its cursor alone. Returns the
/// digest and how many bytes were read before the file ended.
pub(crate) fn sha256_file_at(file: &File, length: u64) -> Result<(String, u64), StoreError> {
    use std::os::unix::fs::FileExt;
    let mut hasher = Sha256::new();
    let mut offset = 0_u64;
    let mut buffer = vec![0_u8; 1 << 20];
    while offset < length {
        let read = file.read_at(&mut buffer, offset)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
        offset += read as u64;
    }
    Ok((lowercase_hex(&hasher.finalize()), offset))
}

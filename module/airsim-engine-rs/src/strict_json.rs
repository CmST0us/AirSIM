use serde::de::DeserializeOwned;
use serde_json::{Map, Value};
use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StrictJsonError {
    Invalid,
}

impl std::fmt::Display for StrictJsonError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("invalid_json")
    }
}

impl std::error::Error for StrictJsonError {}

/// Strict top-level JSON object parser matching Go `internal/strictjson`:
/// - Valid UTF-8
/// - Rejects duplicate keys at any object level (top-level enforced strictly)
/// - Rejects unknown keys
/// - Rejects missing required keys
/// - Rejects explicit `null` for required/allowed fields
/// - Rejects trailing non-whitespace bytes
pub fn parse_object(
    bytes: &[u8],
    required: &[&str],
    optional: &[&str],
) -> Result<Map<String, Value>, StrictJsonError> {
    let text = std::str::from_utf8(bytes).map_err(|_| StrictJsonError::Invalid)?;
    // Verify top-level (and nested) duplicate keys are rejected before serde_json collapses them.
    check_no_duplicate_keys_and_trailing(text)?;
    let value: Value = serde_json::from_str(text).map_err(|_| StrictJsonError::Invalid)?;
    let map = match value {
        Value::Object(m) => m,
        _ => return Err(StrictJsonError::Invalid),
    };

    let req: HashSet<&str> = required.iter().copied().collect();
    let opt: HashSet<&str> = optional.iter().copied().collect();

    for (k, v) in &map {
        if !req.contains(k.as_str()) && !opt.contains(k.as_str()) {
            return Err(StrictJsonError::Invalid);
        }
        if v.is_null() {
            return Err(StrictJsonError::Invalid);
        }
    }
    for k in &req {
        if !map.contains_key(*k) {
            return Err(StrictJsonError::Invalid);
        }
    }
    Ok(map)
}

pub fn decode_exact<T: DeserializeOwned>(
    bytes: &[u8],
    required: &[&str],
    optional: &[&str],
) -> Result<T, StrictJsonError> {
    let map = parse_object(bytes, required, optional)?;
    serde_json::from_value(Value::Object(map)).map_err(|_| StrictJsonError::Invalid)
}

pub fn decode_exact_csv<T: DeserializeOwned>(
    bytes: &[u8],
    required_csv: &str,
    optional_csv: &str,
) -> Result<T, StrictJsonError> {
    let req: Vec<&str> = if required_csv.is_empty() {
        Vec::new()
    } else {
        required_csv.split(',').collect()
    };
    let opt: Vec<&str> = if optional_csv.is_empty() {
        Vec::new()
    } else {
        optional_csv.split(',').collect()
    };
    decode_exact(bytes, &req, &opt)
}

pub fn decode_raw_map(
    bytes: &[u8],
    required: &[&str],
    optional: &[&str],
) -> Result<HashMap<String, Value>, StrictJsonError> {
    let map = parse_object(bytes, required, optional)?;
    Ok(map.into_iter().collect())
}

/// Minimal recursive descent JSON scanner that validates syntax and rejects duplicate keys in any object.
fn check_no_duplicate_keys_and_trailing(s: &str) -> Result<(), StrictJsonError> {
    struct Scanner<'a> {
        b: &'a [u8],
        pos: usize,
        depth: usize,
    }
    impl<'a> Scanner<'a> {
        fn skip_ws(&mut self) {
            while self.pos < self.b.len() {
                match self.b[self.pos] {
                    b' ' | b'\t' | b'\r' | b'\n' => self.pos += 1,
                    _ => break,
                }
            }
        }
        fn peek(&self) -> Option<u8> {
            self.b.get(self.pos).copied()
        }
        fn parse_value(&mut self) -> Result<(), StrictJsonError> {
            self.skip_ws();
            if self.depth > 64 {
                return Err(StrictJsonError::Invalid);
            }
            match self.peek() {
                Some(b'{') => self.parse_object(),
                Some(b'[') => self.parse_array(),
                Some(b'"') => self.parse_string().map(|_| ()),
                Some(b't') => self.expect_bytes(b"true"),
                Some(b'f') => self.expect_bytes(b"false"),
                Some(b'n') => self.expect_bytes(b"null"),
                Some(b'-' | b'0'..=b'9') => self.parse_number(),
                _ => Err(StrictJsonError::Invalid),
            }
        }
        fn expect_bytes(&mut self, lit: &[u8]) -> Result<(), StrictJsonError> {
            if self.b.get(self.pos..self.pos + lit.len()) == Some(lit) {
                self.pos += lit.len();
                Ok(())
            } else {
                Err(StrictJsonError::Invalid)
            }
        }
        fn parse_number(&mut self) -> Result<(), StrictJsonError> {
            let start = self.pos;
            if self.peek() == Some(b'-') {
                self.pos += 1;
            }
            match self.peek() {
                Some(b'0') => self.pos += 1,
                Some(b'1'..=b'9') => {
                    self.pos += 1;
                    while matches!(self.peek(), Some(b'0'..=b'9')) {
                        self.pos += 1;
                    }
                }
                _ => return Err(StrictJsonError::Invalid),
            }
            if self.peek() == Some(b'.') {
                self.pos += 1;
                if !matches!(self.peek(), Some(b'0'..=b'9')) {
                    return Err(StrictJsonError::Invalid);
                }
                while matches!(self.peek(), Some(b'0'..=b'9')) {
                    self.pos += 1;
                }
            }
            if matches!(self.peek(), Some(b'e' | b'E')) {
                self.pos += 1;
                if matches!(self.peek(), Some(b'+' | b'-')) {
                    self.pos += 1;
                }
                if !matches!(self.peek(), Some(b'0'..=b'9')) {
                    return Err(StrictJsonError::Invalid);
                }
                while matches!(self.peek(), Some(b'0'..=b'9')) {
                    self.pos += 1;
                }
            }
            if self.pos == start {
                return Err(StrictJsonError::Invalid);
            }
            Ok(())
        }
        fn parse_string(&mut self) -> Result<String, StrictJsonError> {
            if self.peek() != Some(b'"') {
                return Err(StrictJsonError::Invalid);
            }
            let start = self.pos;
            self.pos += 1;
            while self.pos < self.b.len() {
                let c = self.b[self.pos];
                if c == b'"' {
                    self.pos += 1;
                    let slice = std::str::from_utf8(&self.b[start..self.pos])
                        .map_err(|_| StrictJsonError::Invalid)?;
                    return serde_json::from_str::<String>(slice)
                        .map_err(|_| StrictJsonError::Invalid);
                } else if c == b'\\' {
                    self.pos += 2;
                    if self.pos > self.b.len() {
                        return Err(StrictJsonError::Invalid);
                    }
                } else if c < 0x20 {
                    return Err(StrictJsonError::Invalid);
                } else {
                    self.pos += 1;
                }
            }
            Err(StrictJsonError::Invalid)
        }
        fn parse_array(&mut self) -> Result<(), StrictJsonError> {
            self.pos += 1;
            self.depth += 1;
            self.skip_ws();
            if self.peek() == Some(b']') {
                self.pos += 1;
                self.depth -= 1;
                return Ok(());
            }
            loop {
                self.parse_value()?;
                self.skip_ws();
                match self.peek() {
                    Some(b',') => self.pos += 1,
                    Some(b']') => {
                        self.pos += 1;
                        self.depth -= 1;
                        return Ok(());
                    }
                    _ => return Err(StrictJsonError::Invalid),
                }
            }
        }
        fn parse_object(&mut self) -> Result<(), StrictJsonError> {
            self.pos += 1;
            self.depth += 1;
            self.skip_ws();
            let mut seen = HashSet::new();
            if self.peek() == Some(b'}') {
                self.pos += 1;
                self.depth -= 1;
                return Ok(());
            }
            loop {
                self.skip_ws();
                let key = self.parse_string()?;
                if !seen.insert(key) {
                    return Err(StrictJsonError::Invalid);
                }
                self.skip_ws();
                if self.peek() != Some(b':') {
                    return Err(StrictJsonError::Invalid);
                }
                self.pos += 1;
                self.parse_value()?;
                self.skip_ws();
                match self.peek() {
                    Some(b',') => self.pos += 1,
                    Some(b'}') => {
                        self.pos += 1;
                        self.depth -= 1;
                        return Ok(());
                    }
                    _ => return Err(StrictJsonError::Invalid),
                }
            }
        }
    }

    let mut sc = Scanner {
        b: s.as_bytes(),
        pos: 0,
        depth: 0,
    };
    sc.parse_value()?;
    sc.skip_ws();
    if sc.pos != sc.b.len() {
        return Err(StrictJsonError::Invalid);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_duplicate_unknown_null_and_trailing() {
        assert!(parse_object(br#"{"a":1,"a":2}"#, &["a"], &[]).is_err());
        assert!(parse_object(br#"{"a":1,"b":2}"#, &["a"], &[]).is_err());
        assert!(parse_object(br#"{"a":null}"#, &["a"], &[]).is_err());
        assert!(parse_object(br#"{"a":1} trailing"#, &["a"], &[]).is_err());
        let ok = parse_object(br#"{"a":1,"b":"x"}"#, &["a"], &["b"]).unwrap();
        assert_eq!(ok.get("a").unwrap().as_i64(), Some(1));
    }
}

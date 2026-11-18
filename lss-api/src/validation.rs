use serde_json::Value;

/// Validate that a JSON value is a non-negative integer (i64 >= 0).
/// Rejects strings, floats (even 10.0), bools, null, negative numbers.
pub fn validate_non_negative_integer(val: &Value) -> Option<i64> {
    match val {
        Value::Number(n) => {
            // If it was parsed as a float (has decimal point in JSON), reject it.
            // serde_json's as_i64()/as_u64() can return Some even for 10.0,
            // so we must check is_f64() first. A number is f64 if it had a '.' or 'e'
            // in the original JSON (and is NOT a pure integer).
            // serde_json: is_i64() and is_u64() return false for float-stored numbers,
            // but as_i64() can still return Some for 10.0. We use the is_ checks.
            if n.is_i64() {
                let i = n.as_i64().unwrap_or(-1);
                if i >= 0 {
                    return Some(i);
                }
                return None;
            }
            if n.is_u64() {
                let u = n.as_u64().unwrap_or(0);
                return Some(u as i64);
            }
            // It's a float (10.0, 10.5, etc.) → reject
            None
        }
        _ => None,
    }
}

/// Validate a string field: must be a JSON string, 1 to max_len chars.
pub fn validate_string(val: &Value, max_len: usize) -> Option<String> {
    match val {
        Value::String(s) => {
            if s.is_empty() || s.len() > max_len {
                None
            } else {
                Some(s.clone())
            }
        }
        _ => None,
    }
}

/// Validate that a string is non-empty and within 1-64 chars (for IDs).
pub fn validate_id(val: &Value) -> Option<String> {
    validate_string(val, 64)
}

/// Parse and validate page query param: must be whole number >= 1, default 1.
pub fn parse_page(s: Option<&str>) -> Result<i64, ()> {
    match s {
        None => Ok(1),
        Some(v) => {
            // Must be a whole number >= 1
            // Reject empty, floats, non-numeric
            if v.is_empty() {
                return Err(());
            }
            match v.parse::<i64>() {
                Ok(n) if n >= 1 => Ok(n),
                _ => Err(()),
            }
        }
    }
}

/// Parse and validate limit query param: whole number 1-50, default 20.
pub fn parse_limit(s: Option<&str>) -> Result<i64, ()> {
    match s {
        None => Ok(20),
        Some(v) => {
            if v.is_empty() {
                return Err(());
            }
            match v.parse::<i64>() {
                Ok(n) if n >= 1 && n <= 50 => Ok(n),
                _ => Err(()),
            }
        }
    }
}


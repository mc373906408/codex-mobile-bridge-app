use crate::error::{BridgeError, Result};

#[derive(Default)]
pub struct SseDecoder {
    line: Vec<u8>,
    event: String,
    data_bytes: usize,
}

impl SseDecoder {
    pub fn feed(&mut self, chunk: &[u8]) -> Result<Vec<String>> {
        let mut events = Vec::new();
        for byte in chunk {
            if *byte != b'\n' {
                self.line.push(*byte);
                if self.line.len() + self.data_bytes > 8 * 1024 * 1024 {
                    return Err(BridgeError::TooLarge);
                }
                continue;
            }
            if self.line.last() == Some(&b'\r') {
                self.line.pop();
            }
            let line = std::str::from_utf8(&self.line)
                .map_err(|_| BridgeError::Protocol("invalid SSE encoding".into()))?;
            if line.is_empty() {
                if self.data_bytes > 0 || self.event == "logout" {
                    events.push(if self.event.is_empty() {
                        "message".into()
                    } else {
                        std::mem::take(&mut self.event)
                    });
                }
                self.event.clear();
                self.data_bytes = 0;
            } else if let Some(value) = line.strip_prefix("event:") {
                self.event = value.trim_start().to_owned();
            } else if line.starts_with("data:") {
                self.data_bytes += line.len();
            }
            self.line.clear();
        }
        Ok(events)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_survive_chunk_boundaries_crlf_and_comments() {
        let source = ": heartbeat\r\n\r\nevent: state\r\ndata: {\"text\":\"\u{4e2d}\"}\r\n\r\nevent: logout\ndata: {}\n\n";
        let mut decoder = SseDecoder::default();
        let mut events = vec![];
        for chunk in source.as_bytes().chunks(2) {
            events.extend(decoder.feed(chunk).unwrap());
        }
        assert_eq!(events, vec!["state", "logout"]);
    }
}

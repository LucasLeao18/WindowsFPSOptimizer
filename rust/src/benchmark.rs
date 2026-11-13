//! PresentMon interval captures. Does not collect frames or modify the system.
use crate::{FrameSummary, summarize_frames};
use std::{fs::File, io::Read, path::Path};

const MAX_BYTES: u64 = 128 * 1024 * 1024;
const MAX_ROWS: usize = 2_000_000;

#[derive(Debug)]
pub struct Capture {
    pub application: Option<String>,
    pub summary: FrameSummary,
    pub seconds: f64,
    pub skipped_zero: usize,
    pub complete_identity: bool,
}

pub fn from_path(path: &Path) -> Result<Capture, String> {
    let file = File::open(path).map_err(|e| format!("Não foi possível abrir a captura: {e}"))?;
    if file.metadata().map_err(|e| e.to_string())?.len() > MAX_BYTES {
        return Err("A captura excede 128 MB.".into());
    }
    from_reader(file)
}

pub fn from_reader(reader: impl Read) -> Result<Capture, String> {
    let mut csv = csv::ReaderBuilder::new()
        .flexible(false)
        .from_reader(BoundedReader {
            inner: reader,
            remaining: MAX_BYTES,
        });
    let headers = csv
        .headers()
        .map_err(|e| format!("Cabeçalho inválido: {e}"))?
        .clone();
    let column = |name: &str| headers.iter().position(|h| h.eq_ignore_ascii_case(name));
    let frame_column = column("MsBetweenPresents")
        .ok_or("Coluna MsBetweenPresents ausente. Use o CSV do PresentMon.")?;
    let app_column = column("Application");
    let pid_column = column("ProcessID");
    let chain_column = column("SwapChainAddress");
    let mut identity: Option<(String, String, String)> = None;
    let mut frames = Vec::new();
    let mut skipped_zero = 0;
    let mut total = 0.0;
    for (index, record) in csv.records().enumerate() {
        if index >= MAX_ROWS {
            return Err("A captura excede dois milhões de linhas.".into());
        }
        let record = record.map_err(|e| format!("CSV inválido na linha {}: {e}", index + 2))?;
        let get = |index: Option<usize>| index.and_then(|i| record.get(i)).unwrap_or("").to_owned();
        let next_identity = (get(app_column), get(pid_column), get(chain_column));
        if let Some(current) = &identity {
            if *current != next_identity {
                return Err("A captura mistura aplicativos, processos ou swap chains.".into());
            }
        } else {
            identity = Some(next_identity);
        }
        let raw = record.get(frame_column).ok_or("Tempo de quadro ausente.")?;
        let value: f64 = raw
            .parse()
            .map_err(|_| format!("Tempo de quadro inválido na linha {}.", index + 2))?;
        if !value.is_finite() || !(0.0..=600_000.0).contains(&value) {
            return Err(format!("Tempo de quadro inválido na linha {}.", index + 2));
        }
        if value == 0.0 {
            skipped_zero += 1;
            continue;
        }
        total += value;
        frames.push(value);
    }
    let summary = summarize_frames(&frames).map_err(str::to_owned)?;
    let complete_identity = identity.as_ref().is_some_and(|(app, pid, chain)| {
        !app.trim().is_empty() && !pid.trim().is_empty() && !chain.trim().is_empty()
    });
    Ok(Capture {
        application: identity.map(|v| v.0).filter(|v| !v.trim().is_empty()),
        summary,
        seconds: total / 1000.0,
        skipped_zero,
        complete_identity,
    })
}

// Returning EOF at the limit would silently accept a truncated or growing CSV.
struct BoundedReader<R> {
    inner: R,
    remaining: u64,
}
impl<R: Read> Read for BoundedReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        if self.remaining == 0 {
            let mut extra = [0u8; 1];
            return match self.inner.read(&mut extra)? {
                0 => Ok(0),
                _ => Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "A captura excede 128 MB.",
                )),
            };
        }
        let limit = buf.len().min(self.remaining as usize);
        let count = self.inner.read(&mut buf[..limit])?;
        self.remaining -= count as u64;
        Ok(count)
    }
}

pub fn compare(
    before: &Capture,
    after: &Capture,
) -> Result<Vec<(&'static str, f64, f64, f64)>, String> {
    if let (Some(a), Some(b)) = (&before.application, &after.application)
        && !a.eq_ignore_ascii_case(b)
    {
        return Err("As capturas são de aplicativos diferentes.".into());
    }
    let values = [
        (
            "FPS médio",
            before.summary.average_fps,
            after.summary.average_fps,
        ),
        (
            "1% low",
            before.summary.one_percent_low_fps,
            after.summary.one_percent_low_fps,
        ),
        ("P95 (ms)", before.summary.p95_ms, after.summary.p95_ms),
        ("P99 (ms)", before.summary.p99_ms, after.summary.p99_ms),
    ];
    Ok(values
        .into_iter()
        .map(|(label, old, new)| (label, old, new, (new / old - 1.0) * 100.0))
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_interleaved_chains_and_bad_numbers() {
        let mixed = "Application,ProcessID,SwapChainAddress,MsBetweenPresents\ngame.exe,1,aa,10\ngame.exe,1,bb,11\n";
        assert!(
            from_reader(mixed.as_bytes())
                .unwrap_err()
                .contains("mistura")
        );
        for bad in ["NaN", "Infinity", "-1", "600001", "texto"] {
            let input = format!("MsBetweenPresents\n10\n{bad}\n");
            assert!(from_reader(input.as_bytes()).is_err());
        }
    }
    #[test]
    fn skips_only_zero_and_retains_slow_frames() {
        let input = "Application,ProcessID,SwapChainAddress,MsBetweenPresents\ngame.exe,1,aa,0\ngame.exe,1,aa,10\ngame.exe,1,aa,100\n";
        let capture = from_reader(input.as_bytes()).unwrap();
        assert_eq!(capture.skipped_zero, 1);
        assert_eq!(capture.summary.frame_count, 2);
        assert_eq!(capture.summary.one_percent_low_fps, 10.0);
        assert!(capture.complete_identity);
    }
    #[test]
    fn compares_only_the_same_game() {
        let one =
            from_reader("Application,MsBetweenPresents\na.exe,10\na.exe,10\n".as_bytes()).unwrap();
        let other =
            from_reader("Application,MsBetweenPresents\nb.exe,10\nb.exe,10\n".as_bytes()).unwrap();
        assert!(compare(&one, &other).is_err());
        assert_eq!(compare(&one, &one).unwrap()[0].3, 0.0);
    }
    #[test]
    fn missing_identity_values_are_not_reported_as_complete() {
        let input = "Application,ProcessID,SwapChainAddress,MsBetweenPresents\ngame.exe,,aa,10\ngame.exe,,aa,11\n";
        assert!(!from_reader(input.as_bytes()).unwrap().complete_identity);
    }
    #[test]
    fn bounded_reader_distinguishes_exact_limit_from_truncation() {
        let mut exact = BoundedReader {
            inner: &b"abc"[..],
            remaining: 3,
        };
        let mut output = Vec::new();
        exact.read_to_end(&mut output).unwrap();
        assert_eq!(output, b"abc");
        let mut over = BoundedReader {
            inner: &b"abcd"[..],
            remaining: 3,
        };
        assert!(over.read_to_end(&mut Vec::new()).is_err());
    }
}

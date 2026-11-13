//! Core logic independent of the graphical interface and Windows APIs.

pub mod benchmark;
pub mod compatibility;
pub mod diagnostics;
pub mod engine;
pub mod pagefile;
#[cfg(windows)]
pub mod process_control;
#[cfg(not(windows))]
#[path = "process_control_stub.rs"]
pub mod process_control;
pub mod process_inventory;
pub mod session;
pub mod storage;
pub mod temp_scan;
pub mod transaction;
#[cfg(windows)]
pub mod windows_process;
#[cfg(windows)]
pub mod windows_registry;
#[cfg(windows)]
pub mod windows_visual;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Preset {
    Safe,
    Balanced,
    MaximumFps,
}

impl Preset {
    pub fn name(self) -> &'static str {
        match self {
            Self::Safe => "Seguro",
            Self::Balanced => "Equilibrado",
            Self::MaximumFps => "Máximo FPS",
        }
    }
}

#[derive(Debug, PartialEq)]
pub struct FrameSummary {
    pub frame_count: usize,
    pub average_fps: f64,
    pub one_percent_low_fps: f64,
    pub p95_ms: f64,
    pub p99_ms: f64,
}

/// Computes statistics from frame intervals in milliseconds.
pub fn summarize_frames(frames: &[f64]) -> Result<FrameSummary, &'static str> {
    if frames.len() < 2 {
        return Err("São necessários pelo menos dois quadros.");
    }
    if frames
        .iter()
        .any(|x| !x.is_finite() || *x <= 0.0 || *x > 600_000.0)
    {
        return Err("Os tempos de quadro devem ser finitos e positivos.");
    }
    let mut sorted = frames.to_vec();
    sorted.sort_by(f64::total_cmp);
    let count = sorted.len();
    let slow_count = count.div_ceil(100);
    let total: f64 = sorted.iter().sum();
    let slow_total: f64 = sorted[count - slow_count..].iter().sum();
    let rank = |numerator: usize| (count * numerator).div_ceil(100) - 1;
    Ok(FrameSummary {
        frame_count: count,
        average_fps: 1000.0 * count as f64 / total,
        one_percent_low_fps: 1000.0 * slow_count as f64 / slow_total,
        p95_ms: sorted[rank(95)],
        p99_ms: sorted[rank(99)],
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preserves_stutter_and_uses_total_time() {
        let mut frames = vec![10.0; 99];
        frames.push(100.0);
        let summary = summarize_frames(&frames).unwrap();
        assert!((summary.average_fps - 100_000.0 / 1090.0).abs() < 1e-9);
        assert_eq!(summary.one_percent_low_fps, 10.0);
        assert_eq!(summary.p95_ms, 10.0);
        assert_eq!(summary.p99_ms, 10.0);
    }

    #[test]
    fn rounds_up_the_slowest_one_percent() {
        let mut frames = vec![10.0; 99];
        frames.extend([50.0, 100.0]);
        let summary = summarize_frames(&frames).unwrap();
        assert!((summary.one_percent_low_fps - 1000.0 / 75.0).abs() < 1e-9);
    }

    #[test]
    fn rejects_invalid_inputs() {
        for frames in [
            vec![],
            vec![10.0],
            vec![10.0, 0.0],
            vec![10.0, f64::NAN],
            vec![10.0, f64::INFINITY],
        ] {
            assert!(summarize_frames(&frames).is_err());
        }
    }
}
pub mod power_session;
#[cfg(windows)]
pub mod windows_power;

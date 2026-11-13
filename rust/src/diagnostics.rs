//! Read-only system observations. Values describe the current moment and are
//! not a guarantee of game performance.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PowerSource {
    Ac,
    Battery,
    Unknown,
}

#[derive(Debug, Clone)]
pub struct Snapshot {
    pub total_memory: Option<u64>,
    pub available_memory: Option<u64>,
    pub logical_processors_available: Option<usize>,
    pub power: PowerSource,
    pub battery_percent: Option<u8>,
    pub battery_saver: Option<bool>,
}

fn power_status(
    ac: u8,
    flag: u8,
    percent: u8,
    saver: u8,
) -> (PowerSource, Option<u8>, Option<bool>) {
    let source = match ac {
        0 if flag != 255 && flag & 128 == 0 => PowerSource::Battery,
        1 => PowerSource::Ac,
        _ => PowerSource::Unknown,
    };
    let battery = if flag == 255 || flag & 128 != 0 || percent > 100 {
        None
    } else {
        Some(percent)
    };
    let saver = match saver {
        0 => Some(false),
        1 => Some(true),
        _ => None,
    };
    (source, battery, saver)
}

#[cfg(windows)]
pub fn read() -> Snapshot {
    use windows_sys::Win32::System::{
        Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS},
        SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX},
    };
    let mut memory = MEMORYSTATUSEX {
        dwLength: std::mem::size_of::<MEMORYSTATUSEX>() as u32,
        ..Default::default()
    };
    let memory_ok = unsafe { GlobalMemoryStatusEx(&mut memory) } != 0;
    let mut power = SYSTEM_POWER_STATUS::default();
    let (source, battery, saver) = if unsafe { GetSystemPowerStatus(&mut power) } != 0 {
        power_status(
            power.ACLineStatus,
            power.BatteryFlag,
            power.BatteryLifePercent,
            power.SystemStatusFlag,
        )
    } else {
        (PowerSource::Unknown, None, None)
    };
    Snapshot {
        total_memory: memory_ok.then_some(memory.ullTotalPhys),
        available_memory: memory_ok.then_some(memory.ullAvailPhys),
        logical_processors_available: std::thread::available_parallelism().ok().map(|n| n.get()),
        power: source,
        battery_percent: battery,
        battery_saver: saver,
    }
}

#[cfg(not(windows))]
pub fn read() -> Snapshot {
    Snapshot {
        total_memory: None,
        available_memory: None,
        logical_processors_available: std::thread::available_parallelism().ok().map(|n| n.get()),
        power: PowerSource::Unknown,
        battery_percent: None,
        battery_saver: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unknown_battery_is_not_mistaken_for_no_battery() {
        assert_eq!(
            power_status(255, 255, 255, 0),
            (PowerSource::Unknown, None, Some(false))
        );
        assert_eq!(
            power_status(1, 128, 100, 0),
            (PowerSource::Ac, None, Some(false))
        );
        assert_eq!(
            power_status(0, 255, 255, 0),
            (PowerSource::Unknown, None, Some(false))
        );
        assert_eq!(
            power_status(0, 0, 42, 1),
            (PowerSource::Battery, Some(42), Some(true))
        );
    }
    #[cfg(windows)]
    #[test]
    fn local_snapshot_has_sensible_memory_values() {
        let snapshot = read();
        let total = snapshot.total_memory.unwrap();
        assert!(total > 0 && snapshot.available_memory.unwrap() <= total);
    }
}

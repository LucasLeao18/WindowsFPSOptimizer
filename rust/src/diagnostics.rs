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
    pub active_power_plan: Option<String>,
    pub system_disk_available: Option<u64>,
}

#[cfg(windows)]
fn system_disk_available() -> Option<u64> {
    use windows_sys::Win32::{
        Storage::FileSystem::GetDiskFreeSpaceExW, System::SystemInformation::GetWindowsDirectoryW,
    };
    let mut path = vec![0u16; 32768];
    let size = unsafe { GetWindowsDirectoryW(path.as_mut_ptr(), path.len() as u32) } as usize;
    if size == 0 || size >= path.len() {
        return None;
    }
    // The Windows folder is a directory on the system volume; avoid relying
    // on environment variables or a hard-coded drive letter.
    if size == 2 && path[1] == u16::from(b':') {
        path[2] = u16::from(b'\\');
        path[3] = 0;
    }
    let mut available = 0u64;
    if unsafe {
        GetDiskFreeSpaceExW(
            path.as_ptr(),
            &mut available,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    } == 0
    {
        None
    } else {
        Some(available)
    }
}

#[cfg(windows)]
fn active_power_plan() -> Option<String> {
    use std::ptr;
    use windows_sys::Win32::{
        Foundation::{ERROR_SUCCESS, LocalFree},
        System::Power::{PowerGetActiveScheme, PowerReadFriendlyName},
    };
    struct LocalGuid(*mut windows_sys::core::GUID);
    impl Drop for LocalGuid {
        fn drop(&mut self) {
            unsafe {
                LocalFree(self.0.cast());
            }
        }
    }
    let mut pointer = ptr::null_mut();
    let status = unsafe { PowerGetActiveScheme(ptr::null_mut(), &mut pointer) };
    if pointer.is_null() {
        return None;
    }
    let guid = LocalGuid(pointer);
    if status != ERROR_SUCCESS {
        return None;
    }
    let mut size = 0u32;
    if unsafe {
        PowerReadFriendlyName(
            ptr::null_mut(),
            guid.0,
            ptr::null(),
            ptr::null(),
            ptr::null_mut(),
            &mut size,
        )
    } != ERROR_SUCCESS
        || size == 0
        || size > 4096
        || !size.is_multiple_of(2)
    {
        return None;
    }
    let mut buffer = vec![0u16; (size / 2) as usize];
    if unsafe {
        PowerReadFriendlyName(
            ptr::null_mut(),
            guid.0,
            ptr::null(),
            ptr::null(),
            buffer.as_mut_ptr().cast(),
            &mut size,
        )
    } != ERROR_SUCCESS
    {
        return None;
    }
    let length = buffer.iter().position(|c| *c == 0).unwrap_or(buffer.len());
    let name = String::from_utf16_lossy(&buffer[..length]);
    if name.is_empty() { None } else { Some(name) }
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
        active_power_plan: active_power_plan(),
        system_disk_available: system_disk_available(),
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
        active_power_plan: None,
        system_disk_available: None,
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
    #[cfg(windows)]
    #[test]
    #[ignore = "Requires an available Windows power service"]
    fn reads_the_local_active_power_plan() {
        assert!(!active_power_plan().unwrap().is_empty());
    }
    #[cfg(windows)]
    #[test]
    fn can_read_system_disk_space() {
        assert!(system_disk_available().is_some());
    }
}

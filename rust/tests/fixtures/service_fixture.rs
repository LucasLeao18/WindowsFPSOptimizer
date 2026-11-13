#![cfg_attr(windows, windows_subsystem = "windows")]
//! Disposable CI-only service. Never installed by the application.
#[cfg(windows)]
mod fixture {
    use std::{
        ffi::c_void,
        ptr,
        sync::atomic::{AtomicBool, Ordering},
        thread,
        time::Duration,
    };
    use windows_sys::Win32::System::Services::*;
    static STOP: AtomicBool = AtomicBool::new(false);
    fn wide(text: &str) -> Vec<u16> {
        text.encode_utf16().chain(Some(0)).collect()
    }
    unsafe extern "system" fn control(code: u32, _: u32, _: *mut c_void, _: *mut c_void) -> u32 {
        if code == SERVICE_CONTROL_STOP {
            STOP.store(true, Ordering::Release);
        }
        0
    }
    unsafe extern "system" fn service_main(_: u32, _: *mut *mut u16) {
        STOP.store(false, Ordering::Release);
        let handle = unsafe {
            RegisterServiceCtrlHandlerExW(
                wide("WindowsFPSOptimizerRustValidation").as_ptr(),
                Some(control),
                ptr::null(),
            )
        };
        if handle.is_null() {
            return;
        }
        let mut state = SERVICE_STATUS {
            dwServiceType: SERVICE_WIN32_OWN_PROCESS,
            dwCurrentState: SERVICE_RUNNING,
            dwControlsAccepted: SERVICE_ACCEPT_STOP,
            ..Default::default()
        };
        if unsafe { SetServiceStatus(handle, &state) } == 0 {
            return;
        }
        while !STOP.load(Ordering::Acquire) {
            thread::sleep(Duration::from_millis(50));
        }
        state.dwCurrentState = SERVICE_STOPPED;
        state.dwControlsAccepted = 0;
        unsafe {
            SetServiceStatus(handle, &state);
        }
    }
    pub fn run() {
        let mut name = wide("WindowsFPSOptimizerRustValidation");
        let table = [
            SERVICE_TABLE_ENTRYW {
                lpServiceName: name.as_mut_ptr(),
                lpServiceProc: Some(service_main),
            },
            SERVICE_TABLE_ENTRYW::default(),
        ];
        unsafe {
            StartServiceCtrlDispatcherW(table.as_ptr());
        }
    }
}
#[cfg(windows)]
fn main() {
    fixture::run();
}
#[cfg(not(windows))]
fn main() {}

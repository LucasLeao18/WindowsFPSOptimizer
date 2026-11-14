//! One-shot cleanup used by the Maximum profile, as gaming boosters do: close a
//! fixed list of background helpers and trim working sets. It cannot be undone
//! by restoration; closed helpers start again with Windows or when opened.
use crate::session::ProcessIdentity;

/// Background helpers that hold no user documents. Browsers, chat, launchers,
/// media players and anything with open work are deliberately absent.
pub const CLOSABLE: [(&str, &str); 13] = [
    (
        "onedrive.exe",
        "OneDrive (a sincronização volta ao reabrir ou no próximo login)",
    ),
    ("phoneexperiencehost.exe", "Vincular ao Celular"),
    ("yourphone.exe", "Vincular ao Celular"),
    ("widgets.exe", "Widgets"),
    ("widgetservice.exe", "Widgets"),
    ("gamebar.exe", "Xbox Game Bar"),
    ("gamebarftserver.exe", "Xbox Game Bar"),
    ("cortana.exe", "Cortana"),
    ("skypeapp.exe", "Skype"),
    ("skypebackgroundhost.exe", "Skype"),
    ("adobearm.exe", "Atualizador da Adobe"),
    ("adobecollabsync.exe", "Sincronização do Adobe Acrobat"),
    ("jusched.exe", "Atualizador do Java"),
];

pub fn title(name: &str) -> Option<&'static str> {
    let lower = name.to_ascii_lowercase();
    CLOSABLE
        .iter()
        .find(|(exe, _)| *exe == lower)
        .map(|(_, title)| *title)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Found {
    pub name: String,
    pub title: &'static str,
    pub identity: ProcessIdentity,
}

/// Read-only: listed helpers that are running and pass every protection check.
#[cfg(windows)]
pub fn running() -> Vec<Found> {
    let Ok(inventory) = crate::process_inventory::collect() else {
        return Vec::new();
    };
    inventory
        .processes
        .into_iter()
        .filter_map(|process| {
            let title = title(&process.name)?;
            let identity = process.identity?;
            crate::process_control::inspect(identity).ok()?;
            Some(Found {
                name: process.name,
                title,
                identity,
            })
        })
        .collect()
}

/// Closes the helpers still running, rechecking identity and protections.
#[cfg(windows)]
pub fn close() -> (usize, usize) {
    let (mut closed, mut kept) = (0, 0);
    for found in running() {
        match crate::process_control::inspect(found.identity)
            .and_then(|candidate| crate::process_control::terminate(&candidate))
        {
            Ok(_) => closed += 1,
            Err(_) => kept += 1,
        }
    }
    (closed, kept)
}

/// Asks Windows to trim the working set of this user's processes. Pages move
/// to the standby list and return on demand; nothing is closed.
#[cfg(windows)]
pub fn trim_memory() -> usize {
    use windows_sys::Win32::{
        Foundation::CloseHandle,
        System::{
            ProcessStatus::K32EmptyWorkingSet,
            Threading::{
                GetCurrentProcessId, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION,
                PROCESS_SET_QUOTA,
            },
        },
    };
    let Ok(inventory) = crate::process_inventory::collect() else {
        return 0;
    };
    let own = unsafe { GetCurrentProcessId() };
    let mut trimmed = 0;
    for process in inventory.processes {
        if process.pid == own || process.pid <= 4 {
            continue;
        }
        let handle = unsafe {
            OpenProcess(
                PROCESS_SET_QUOTA | PROCESS_QUERY_LIMITED_INFORMATION,
                0,
                process.pid,
            )
        };
        if handle.is_null() {
            continue;
        }
        if unsafe { K32EmptyWorkingSet(handle) } != 0 {
            trimmed += 1;
        }
        unsafe {
            CloseHandle(handle);
        }
    }
    trimmed
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_listed_helpers_are_closable() {
        assert!(title("OneDrive.exe").is_some());
        for kept in [
            "chrome.exe",
            "discord.exe",
            "steam.exe",
            "explorer.exe",
            "ExitLag.exe",
        ] {
            assert!(title(kept).is_none(), "{kept}");
        }
    }
    #[cfg(windows)]
    #[test]
    fn listing_running_helpers_changes_nothing() {
        for found in running() {
            assert!(title(&found.name).is_some());
        }
    }
}

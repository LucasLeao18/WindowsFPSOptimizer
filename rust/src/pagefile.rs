//! Read-only page-file discovery. Writing this machine-wide setting requires
//! an elevated, independently protected transaction and is not implemented yet.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Management {
    Automatic,
    Manual,
}

fn unique_state(values: &[Option<bool>]) -> Result<Management, String> {
    match values {
        [Some(true)] => Ok(Management::Automatic),
        [Some(false)] => Ok(Management::Manual),
        _ => Err("Não foi possível confirmar como a memória virtual é gerenciada.".into()),
    }
}

/// Queries only the local machine. Call from a worker thread; WMI can be slow or disabled.
#[cfg(windows)]
pub fn detect() -> Result<Management, String> {
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "PascalCase")]
    struct ComputerSystem {
        automatic_managed_pagefile: Option<bool>,
    }
    let connection = wmi::WMIConnection::new()
        .map_err(|e| format!("O serviço de gerenciamento do Windows está indisponível: {e}"))?;
    let rows: Vec<ComputerSystem> = connection
        .raw_query("SELECT AutomaticManagedPagefile FROM Win32_ComputerSystem")
        .map_err(|e| format!("Não foi possível consultar a memória virtual: {e}"))?;
    unique_state(
        &rows
            .iter()
            .map(|r| r.automatic_managed_pagefile)
            .collect::<Vec<_>>(),
    )
}

#[cfg(not(windows))]
pub fn detect() -> Result<Management, String> {
    Err("Esta consulta requer Windows.".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_missing_or_ambiguous_machine_data() {
        assert_eq!(unique_state(&[Some(true)]).unwrap(), Management::Automatic);
        assert_eq!(unique_state(&[Some(false)]).unwrap(), Management::Manual);
        for invalid in [vec![], vec![None], vec![Some(true), Some(false)]] {
            assert!(unique_state(&invalid).is_err());
        }
    }

    #[cfg(windows)]
    #[test]
    #[ignore = "Requires the local Windows WMI service"]
    fn reads_local_pagefile_management() {
        assert!(matches!(
            detect(),
            Ok(Management::Automatic | Management::Manual)
        ));
    }
}

//! WMI snapshot adapter. Mutation remains disabled until its recovery behavior
//! has been verified on disposable Windows installations.
use crate::pagefile_transaction::{self, Backend, Setting, State};

#[derive(Default)]
pub struct WindowsPagefile;
impl Backend for WindowsPagefile {
    fn snapshot(&mut self) -> Result<State, String> {
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "PascalCase")]
        struct Computer {
            automatic_managed_pagefile: Option<bool>,
        }
        #[derive(serde::Deserialize)]
        #[serde(rename_all = "PascalCase")]
        struct Pagefile {
            name: Option<String>,
            initial_size: Option<u32>,
            maximum_size: Option<u32>,
        }
        let connection = wmi::WMIConnection::new()
            .map_err(|e| format!("O serviço de gerenciamento do Windows está indisponível: {e}"))?;
        let systems: Vec<Computer> = connection
            .raw_query("SELECT AutomaticManagedPagefile FROM Win32_ComputerSystem")
            .map_err(|e| format!("Não foi possível consultar a memória virtual: {e}"))?;
        let automatic = match systems.as_slice() {
            [
                Computer {
                    automatic_managed_pagefile: Some(value),
                },
            ] => *value,
            _ => return Err("O Windows retornou um estado de memória virtual ambíguo.".into()),
        };
        let pages: Vec<Pagefile> = connection
            .raw_query("SELECT Name, InitialSize, MaximumSize FROM Win32_PageFileSetting")
            .map_err(|e| format!("Não foi possível consultar os arquivos de paginação: {e}"))?;
        if pages.len() > 26 {
            return Err("Há arquivos de paginação demais para verificar com segurança.".into());
        }
        let settings = pages
            .into_iter()
            .map(
                |page| match (page.name, page.initial_size, page.maximum_size) {
                    (Some(name), Some(initial_mb), Some(maximum_mb)) => Ok(Setting {
                        name,
                        initial_mb,
                        maximum_mb,
                    }),
                    _ => Err("O Windows retornou um arquivo de paginação incompleto.".to_string()),
                },
            )
            .collect::<Result<Vec<_>, _>>()?;
        pagefile_transaction::normalize(State {
            automatic,
            settings,
        })
    }
    fn set_automatic(&mut self, _: &State) -> Result<(), String> {
        Err("A alteração de memória virtual ainda não está disponível.".into())
    }
    fn restore_exact(&mut self, _: &State, _: &State) -> Result<(), String> {
        Err("A restauração de memória virtual ainda não está disponível.".into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "Read-only query requiring a working local WMI service"]
    fn reads_complete_pagefile_snapshot_without_changes() {
        let first = WindowsPagefile.snapshot().unwrap();
        assert!(first.settings.len() <= 26);
        assert_eq!(
            pagefile_transaction::normalize(first.clone()).unwrap(),
            first
        );
    }
}

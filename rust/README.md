# Windows FPS Optimizer 2.0 (Rust)

Aplicativo nativo em Rust: um único executável portátil, sem instalador, sem PowerShell e sem dependência do Visual C++ Redistributable. Funciona no Windows 10 e no Windows 11, em computadores x64, x86 (32 bits) e ARM64.

## Perfis

| Perfil | O que faz |
|---|---|
| **Seguro** | Modo de Jogo, transparência e animações compatíveis. Cada mudança é mostrada antes da confirmação e salva para restauração. |
| **Equilibrado** | Inclui o Seguro, desativa sombras do cursor e das janelas e, se a memória virtual estiver manual, devolve-a ao gerenciamento automático do Windows (exige administrador e vale após reiniciar). A configuração manual anterior é salva e pode ser restaurada exatamente. |
| **Máximo FPS** | Inicia o jogo escolhido e, só durante a sessão, eleva a prioridade, reduz efeitos visuais, ativa o plano Alto Desempenho (se existir), impede a suspensão automática e, opcionalmente, para serviços escolhidos. Um monitor independente restaura tudo quando o jogo termina, mesmo se a janela do aplicativo for fechada. |

Nenhum perfil promete ganho de FPS; use a comparação de capturas do PresentMon na interface avançada para medir.

## Interface avançada

- Recuperação: restaurar, arquivar e reativar backups, com detecção de conflitos.
- Diagnóstico de memória, disco, processadores e energia, sem alterações.
- Processos: encerramento manual com verificação de identidade; processos críticos, do Windows, serviços e elevados são protegidos.
- Inicialização: desativar entradas de `HKCU\...\Run` com backup e transação do Registro.
- Serviços opcionais: parar e restaurar individualmente (exige administrador).
- Limpeza de temporários do usuário com mais de sete dias, após análise e confirmação.
- Comparação de capturas CSV do PresentMon (FPS médio, 1% low, P95, P99).

O botão **Reabrir como administrador** é necessário para memória virtual e serviços. Os demais recursos funcionam como usuário comum.

## Compatibilidade

- A interface tenta OpenGL, depois um segundo renderizador (wgpu) e, se nenhum funcionar, abre uma interface nativa do Windows com os três perfis, a recuperação e a limpeza. O objetivo é abrir também com drivers de vídeo antigos, em máquinas virtuais e por acesso remoto.
- O runtime do C é estático: os executáveis só usam DLLs que fazem parte do Windows.
- O manifesto declara Windows 10/11, DPI por monitor e caminhos longos; o aplicativo roda como usuário comum (`asInvoker`).
- Backups da versão 1.x (PowerShell) não são importados. Para restaurá-los, use a versão 1.2.0, que continua disponível nas releases.

## Compilar e gerar a release localmente

Requisitos: [rustup](https://rustup.rs) e Visual Studio Build Tools com o workload **Desenvolvimento para desktop com C++**, incluindo **MSVC ARM64 build tools** e um Windows SDK.

```powershell
cd rust
powershell -ExecutionPolicy Bypass -File .\build-release.ps1
```

O script verifica formatação e lint, executa os testes (incluindo os de integração que não alteram o sistema), compila x64/x86/ARM64, confirma que não há DLLs de runtime do Visual C++, testa a abertura das três interfaces gráficas e o monitor de sessão, e grava os executáveis e o `SHA256SUMS.txt` em `rust\dist`. Nenhuma etapa depende de GitHub Actions.

Desenvolvimento:

```powershell
cargo test
cargo run
```

# Windows FPS Optimizer 2.0 (Rust)

Aplicativo nativo em Rust: um único executável portátil, sem instalador, sem PowerShell e sem dependência do Visual C++ Redistributable. Funciona no Windows 10 e no Windows 11, em computadores x64, x86 (32 bits) e ARM64.

## Perfis

Todos os perfis valem para o Windows inteiro, mostram cada mudança antes de aplicar e guardam os valores anteriores para **Restaurar último backup**.

| Perfil | O que faz | O que os testes publicados mostram |
|---|---|---|
| **Seguro** | Ativa o Modo de Jogo e desliga transparência e animações. | Diferença de FPS pequena ou nula em jogos com GPU dedicada. Deixa a área de trabalho mais responsiva e pode ajudar gráficos integrados fracos. |
| **Equilibrado** | Seguro + sem sombras, sem gravação em segundo plano do Game Bar e memória virtual manual devolvida ao gerenciamento do Windows (exige administrador e reinício). | A gravação em segundo plano custa pouco no FPS médio (~1 FPS), mas é a causa mais citada de quedas nos 1% low. A paginação automática não aumenta FPS; evita travamentos quando a paginação manual é pequena demais. |
| **Máximo FPS** | Equilibrado + energia no máximo: plano Alto Desempenho em desktops ou modo **Melhor desempenho** em notebooks que só têm o plano Equilibrado. | O ajuste com mais evidência de ganho, principalmente em CPUs que demoram a acelerar. Aumenta consumo e temperatura. Planos personalizados ou do fabricante nunca são substituídos. |

O Máximo informa se a **Integridade de memória** está ativada. É o recurso com maior custo medido em jogos (cerca de 3% a 8% em alguns títulos), mas é proteção de segurança, então o aplicativo não a desativa; o botão **Abrir Isolamento de núcleo** leva à configuração.

Nenhum perfil promete ganho de FPS. Para medir no seu PC, use a comparação de capturas do PresentMon na interface avançada.

## Interface avançada

- Recuperação: restaurar, arquivar e reativar backups, com detecção de conflitos.
- Diagnóstico de memória, disco, processadores e energia, sem alterações.
- Processos: encerramento manual com verificação de identidade; processos críticos, do Windows, serviços e elevados são protegidos.
- Inicialização: desativar entradas de `HKCU\...\Run` com backup e transação do Registro.
- Serviços opcionais: parar e restaurar individualmente (exige administrador).
- Limpeza de temporários do usuário com mais de sete dias, após análise e confirmação.
- Comparação de capturas CSV do PresentMon (FPS médio, 1% low, P95, P99).
- Sessão de jogo temporária (opcional): inicia um jogo escolhido com prioridade, efeitos visuais e energia ajustados só enquanto ele está aberto, e um monitor independente restaura tudo quando o jogo fecha.

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

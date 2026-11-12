# Windows FPS Optimizer

[Baixar instalador EXE v1.1.0](https://github.com/LucasLeao18/WindowsFPSOptimizer/releases/download/v1.1.0/WindowsFPSOptimizer-1.1.0-Setup.exe) · [Releases e hashes](https://github.com/LucasLeao18/WindowsFPSOptimizer/releases) · [Histórico de mudanças](CHANGELOG.md)

Aplicativo gráfico, local e offline para analisar e ajustar o próprio Windows 10 ou Windows 11 antes de jogos. Ele foi escrito em Windows PowerShell 5.1, usa WPF e não depende de módulos de terceiros.

O objetivo é reduzir trabalho dispensável em segundo plano, manter configurações de energia coerentes durante uma sessão de jogo e tornar mudanças reversíveis sempre que o Windows permitir. O aplicativo compara FPS e tempos de quadro de capturas externas do PresentMon, sem prometer ganhos. O resultado depende do jogo, do driver, do hardware, da temperatura, da carga em segundo plano e da configuração original.

> **Segurança por padrão:** `Config.json` inicia o aplicativo em modo de simulação. Abrir o programa normalmente não aplica mudanças. Alterações reais são permitidas somente na cópia instalada pelo `Setup.exe` sob `Program Files`; depois disso ainda é necessário desativar a simulação, confirmar as ações e aceitar UAC quando solicitado.

As releases incluem instalador, SHA-256, metadados do build e código-fonte. O workflow `Windows build and installer validation` compila em Windows Server 2022 e testa o EXE final em um runner descartável: instalação silenciosa (`/quiet`), código de saída e hashes de todos os arquivos instalados. O modo silencioso mantém a exigência de administrador e as verificações do instalador. O EXE não recebe assinatura Authenticode quando um certificado não é fornecido ao build.

## Limites do projeto

Este projeto otimiza somente componentes locais do Windows relacionados a jogos, energia, interface, processos, memória, armazenamento, inicialização e manutenção. Ele não contém ajustes de rede.

São proibidos e não fazem parte do aplicativo:

- DNS, TCP/IP, MTU, Winsock, proxy, Teredo, roteamento ou QoS;
- Wi-Fi, Ethernet, adaptadores, drivers de rede, portas ou firewall;
- registro de rede, serviços essenciais de rede, pacotes, ping ou latência;
- configuração do ExitLag, VPNs, launchers de túnel ou aplicativos semelhantes;
- overclock, BIOS, clocks, voltagens, injeção de código, alteração de memória de jogos ou cheats;
- desativação do Windows Defender, Windows Update ou componentes essenciais para obter desempenho.

O núcleo bloqueia caminhos de Registro relacionados a rede e limita comandos nativos a uma allowlist de ferramentas do próprio Windows. O programa não baixa arquivos, não instala drivers e não faz consultas de atualização pela Internet. ExitLag, VPNs e aplicativos de túnel são marcados como protegidos por nome, descrição, fabricante e caminho: não podem ser colocados na lista de fechamento, encerrados pelo gerenciador nem desativados na inicialização.

## Requisitos

- Windows 10 ou Windows 11, build 10240 ou superior;
- Windows PowerShell 5.1 Desktop (`powershell.exe`), não PowerShell 7 (`pwsh.exe`);
- sessão gráfica com WPF disponível;
- processo de 64 bits em Windows de 64 bits; o inicializador se relança automaticamente pelo host correto quando necessário;
- Windows 10 x86/x64 ou Windows 11 x64; o bootstrap do instalador usa PE x86 compatível e o aplicativo seleciona o host nativo disponível;
- execução em apartment state STA; o inicializador também corrige isso automaticamente;
- privilégios de administrador apenas para operações que alteram configurações de máquina, serviços, tarefas, energia, paginação ou integridade;
- Proteção do Sistema habilitada se pontos de restauração forem desejados. O baseline JSON continua existindo e a interface avisa claramente quando o Windows recusa o checkpoint.

Não é necessária conexão com a Internet. O DISM `RestoreHealth` só é permitido com uma fonte local válida e `/LimitAccess`.

## Execução rápida

Abra o **Windows PowerShell 5.1** na pasta do projeto.

### 1. Primeira execução — simulação recomendada

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WindowsFPSOptimizer.ps1 -Simulation
```

O mesmo modo já é o padrão em `Config.json`, portanto este comando também abre em simulação:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WindowsFPSOptimizer.ps1
```

Analise o computador, navegue pelas abas e confira os logs antes de mudar o modo.

### 2. Modo somente leitura

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\WindowsFPSOptimizer.ps1 -ReadOnly
```

Esse modo permite inventário, análise e abertura das páginas oficiais do Windows, mas bloqueia alterações, importação de backup e gravação de perfis/listas. Se `-ReadOnly` e `-Simulation` forem usados juntos, somente as operações de leitura permanecem disponíveis.

### 3. Alterações reais

Gere ou abra `dist\WindowsFPSOptimizer-<versão>-Setup.exe`, confirme o UAC e
inicie o aplicativo pelo atalho criado. O código executável fica protegido sob
`Program Files`; estado, backups e logs continuam no perfil do usuário.

Na interface instalada, desative **Simulação** somente depois de analisar o
computador. O aplicativo informa quando uma ação exige administrador e oferece
relançar pelo UAC, preservando o modo escolhido. Execução real a partir da pasta
de fontes, Downloads, Desktop ou outra pasta gravável pelo usuário é recusada
para impedir troca de scripts antes da elevação.

### 4. Perfil de jogo por linha de comando

Um atalho criado pelo próprio aplicativo usa o identificador salvo do perfil e
o script da instalação protegida:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "C:\Program Files\WindowsFPSOptimizer\App\<versão>\WindowsFPSOptimizer.ps1" -NoSimulation -LaunchGameProfile "GUID-DO-PERFIL"
```

O aplicativo inicia o executável local validado, acompanha o processo e restaura a sessão no bloco `finally` quando o jogo termina. Se houver falha ou desligamento inesperado, reabra o programa e use **Encerrar sessão** ou restaure o backup pendente.

Se a sessão estiver elevada por causa de energia ou serviços, o jogo é aberto pelo Shell do Explorer do usuário. O aplicativo verifica que esse Explorer não está elevado e não usa fallback administrativo; se não puder confirmar o contexto normal, cancela o lançamento e restaura a sessão. Isso evita que o otimizador force launchers, overlays ou anticheat a herdarem o UAC.

### 5. Validação automatizada sem alterações reais

Execute os cinco scripts no Windows PowerShell 5.1 antes do modo real:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Validate-Project.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Smoke-Simulation.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Test-IntegrationContracts.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Test-SidecarReconciliation.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tests\Test-BackupBaseline.ps1
```

O primeiro valida sintaxe, importações, XAML, referências de controles, contratos, codificação compatível com 5.1, bloqueios de rede e proteções ExitLag/VPN. O smoke test carrega os inventários e a análise, testa sessão transitória, paginação e filtros em simulação. Os testes dirigidos cobrem os contratos da UI, a recusa de Máximo FPS sem jogo, a interpretação/validade conservadora de integridade, as cadeias A→B→C dos sidecars e o pacote/hashes do baseline. O último cria e remove apenas uma fixture na pasta de backups; não aplica tweak do Windows. Nenhum deles substitui o roteiro de VM para mutações privilegiadas.

## Modos de segurança

| Modo | Como ativar | Escritas | Backups | Uso recomendado |
|---|---|---:|---:|---|
| Simulação | padrão, `-Simulation` ou caixa na interface | Não | Não cria transação real | Descoberta, demonstração e validação inicial |
| Somente leitura | `-ReadOnly` ou caixa na interface | Bloqueadas | Bloqueados | Auditoria sem risco de mudança |
| Real | `-NoSimulation` | Somente após validação/confirmação | Sim, por transação raiz | Aplicação controlada |
| Administrador | botão na interface ou UAC sob demanda | Libera somente ações que exigem elevação | Sim | Serviços, tarefas, energia, HKLM, paginação e integridade |

Os setters verificam o estado atual antes de escrever e retornam `Skipped` quando o valor já corresponde ao solicitado. Limpezas, reparos e manutenção de volume não têm “undo” e não devem ser interpretados como operações reversíveis ou estritamente idempotentes.

## Arquitetura

```text
WindowsFPSOptimizer.ps1       Bootstrap, host STA/x64, WPF, runspaces e eventos
MainWindow.xaml               Interface em tema escuro e 15 áreas funcionais
Config.json                   Versão, modos padrão, allowlists e limiares de análise
Core.psm1                     Contexto, guardas, transações e comandos seguros
Logging.psm1                  Log TXT/JSONL e relatórios TXT/CSV/JSON/HTML
BackupManager.psm1            Manifestos, exportação .reg, importação e restauração
SystemAnalysis.psm1           Inventário, métricas, pontuação e recomendações
Benchmark.psm1                Importação e comparação de capturas CSV do PresentMon
GameOptimizations.psm1        Game Mode, capturas, perfis e sessão de jogo
PowerOptimizations.psm1       Planos, CPU, resfriamento, tela e suspensão
GraphicsOptimizations.psm1    GPU/driver, HAGS manual, efeitos e caches gráficos
ProcessManager.psm1           Processos, prioridades, listas e paginação
StorageOptimizations.psm1     Limpeza allowlisted, TRIM/HDD, SFC, DISM e CHKDSK
ServiceManager.psm1           Serviços opcionais, perfis e restauração
StartupManager.psm1           Itens Run/pastas de inicialização e restauração
WindowsAppsManager.psm1       Inventário Win32/Appx e remoção Appx conservadora
PrivacyManager.psm1           Políticas documentadas e detecção de domínio/MDM
ScheduledTaskManager.psm1     Inventário e allowlist de tarefas opcionais
Profiles.psm1                 Catálogo e perfis Seguro/Equilibrado/Máximo FPS
UIController.psm1             Dispatcher fechado entre a interface e os módulos
Build-WindowsFPSOptimizer.ps1 Build validado, assinatura opcional e publicação transacional
Installer\SetupLauncher.cs    Bootstrap UAC com payload incorporado e verificado
Installer\SetupLauncher.manifest Manifesto requireAdministrator e compatibilidade
Installer\Run-Installer.cmd   Seleção segura do Windows PowerShell nativo
Installer\Install-WindowsFPSOptimizer.ps1 Instalação, ACL, atalhos e rollback
```

### Fluxo de uma alteração

```mermaid
flowchart LR
    A["WPF: seleção e confirmação"] --> B["UIController: ActionId permitido"]
    B --> C["Módulo da categoria"]
    C --> D["Core: modo, admin e allowlists"]
    D --> E["BackupManager: manifesto e checkpoint"]
    E --> F["Aplicação por API ou ferramenta do Windows"]
    F --> G["Verificação do estado aplicado"]
    G --> H["Log estruturado e atualização da interface"]
    F -. falha .-> I["Rollback da transação quando reversível"]
```

A interface usa um pool de runspaces para não bloquear a thread WPF durante análises, inventários ou ferramentas demoradas. O dispatcher aceita apenas `ActionId` codificados; ele não executa nomes de comando vindos de backup ou configuração.

## Interface

O menu lateral reúne as seguintes páginas:

1. **Início:** inventário, métricas, análise, backup, otimização rápida e restauração.
2. **Otimizações de jogos:** Game Mode, capturas, páginas oficiais e sessão temporária.
3. **Jogos e programas:** executáveis locais, detecção com inclusão explícita, edição de perfis, execução monitorada e atalhos.
4. **CPU e energia:** planos, estados do processador, resfriamento, tela e suspensão.
5. **GPU e gráficos:** adaptadores, driver, HAGS manual, caches e opções oficiais.
6. **Memória RAM:** total/usada/disponível, maiores consumidores, processos e paginação.
7. **Armazenamento:** estimativas, limpeza seletiva, TRIM/HDD e integridade.
8. **Processos e serviços:** métricas, proteção de críticos, inventário completo somente leitura e alterações restritas aos serviços opcionais.
9. **Inicialização:** Registro Run e pastas Startup, com seleção múltipla e restauração.
10. **Interface e efeitos visuais:** perfis, opções individuais e prévia do diff antes da aplicação.
11. **Aplicativos do Windows:** inventário Win32/Appx e remoção individual allowlisted.
12. **Privacidade e telemetria:** políticas opcionais documentadas e páginas oficiais.
13. **Tarefas agendadas:** inventário completo classificado, descrição, allowlist e restauração.
14. **Segurança e integridade:** Defender, reinicialização, hotfix local, ponto, SFC e DISM.
15. **Perfis de otimização:** Seguro, Equilibrado e Máximo FPS.

## Catálogo de otimizações

Legenda de restauração:

- **Completa:** o estado original é salvo e pode ser reaplicado pelo gerenciador de backup;
- **Melhor esforço:** depende de o recurso/processo/payload ainda existir;
- **Manual:** a aplicação e a reversão ocorrem na interface oficial do Windows;
- **Nenhuma:** limpeza, reparo ou manutenção sem undo item a item;
- **N/A:** leitura, análise ou criação de contingência.

“Benefício esperado” descreve a finalidade técnica, não uma promessa de ganho. `Pro+` significa Pro, Enterprise, Education, IoT ou Workstation quando a política existe nessa edição.

| Nome | Categoria | Descrição real | Benefício esperado | Risco | Compatibilidade | Reinício | Restauração |
|---|---|---|---|---|---|---|---|
| Game Mode | Jogos | No Windows 11, grava a preferência documentada do usuário; no Windows 10 abre Configurações | Permitir que o Windows aplique sua política de jogos | Seguro | W11 automático; W10 manual | Não | Completa no W11; manual no W10 |
| Capturas e Game DVR | Jogos | Usa `AllowGameDVR` somente no Windows 10 Pro+; Windows 11 é manual | Evitar gravação/transmissão concorrente quando não usada | Seguro/moderado | W10 Pro+ automático; W11/Home manual | Possível | Completa quando automatizado |
| Xbox Game Bar | Jogos | Abre a página oficial; não remove Xbox ou Gaming Services | Evitar overlay/captura não utilizados após escolha do usuário | Manual | W10/W11 | Não | Manual |
| HAGS | GPU/Jogos | Detecta condição mínima e abre Configurações; não força Registro privado | Pode alterar o escalonamento de GPU, com efeito dependente de driver/jogo | Manual/controverso | W10 2004+/W11 e driver compatível | Sim | Manual |
| Otimizações de tela cheia por jogo | Jogos | Valida o `.exe` e orienta Propriedades > Compatibilidade | Diagnosticar casos específicos de apresentação/stutter | Manual/controverso | W10/W11 | Não | Manual por executável |
| Preferência de GPU por programa | GPU/Jogos | Valida o `.exe` e abre Configurações gráficas | Escolher GPU de alto desempenho em sistemas híbridos | Manual | W10 1803+/W11 | Não | Manual |
| Prioridade de jogo | Processos/Jogos | Aplica `AboveNormal` ou `High` ao processo existente; nunca `Realtime` | Favorecer o jogo sob concorrência de CPU | Moderado | W10/W11 | Não | Completa enquanto o mesmo processo existir |
| Não Perturbe/Assistente de Foco | Jogos | Abre a regra oficial de foco para jogos | Reduzir notificações e interrupções visuais | Manual | Varia entre W10/W11 | Não | Manual |
| Sessão de jogo | Jogos | Fecha processos selecionados, para serviços opcionais, muda energia/visuais e acompanha o jogo | Liberar temporariamente recursos escolhidos | Moderado | W10/W11 | Possível | Melhor esforço automática ao término |
| Alto Desempenho | CPU/Energia | Ativa plano existente ou clone conhecido e preserva o GUID anterior | Reduzir políticas conservadoras de economia durante o jogo | Moderado | W10/W11 | Não | Completa |
| Desempenho Máximo | CPU/Energia | Ativa/duplica Ultimate Performance; usa Alto Desempenho como fallback | Reduzir transições de economia em hardware compatível | Agressivo | Disponibilidade depende da edição/hardware | Não | Completa |
| Plano personalizado para jogos | CPU/Energia | Cria clone isolado e opcionalmente o ativa | Separar ajustes de jogo do plano cotidiano | Moderado | W10/W11 | Não | Completa; plano criado é removido quando seguro |
| Estados mínimo/máximo da CPU | CPU/Energia | Ajusta índices AC/DC de 0–100 no plano; não altera clock/voltagem | Adequar a política de energia do processador | Moderado | Firmware/ACPI dependentes | Não | Completa |
| Política de resfriamento | CPU/Energia | Escolhe ativa/passiva somente quando o setting existe no plano | Priorizar ventoinha ou redução de frequência conforme escolha | Moderado | Pode estar oculta/indisponível | Não | Completa |
| Tela e suspensão | CPU/Energia | Ajusta tempos AC/DC; a sessão pode impedir suspensão temporariamente | Evitar interrupção de uma sessão longa | Seguro/moderado | W10/W11 | Não | Completa |
| Suspensão seletiva por dispositivo | CPU/Energia | Abre o Gerenciador de Dispositivos; não escreve Registro PnP | Permitir decisão por periférico/driver | Manual | Dependente do driver | Possível | Manual |
| Transparências | Interface/GPU | Altera a preferência documentada de transparência | Reduzir composição visual do desktop | Seguro | W10/W11 | Possível logoff/Explorer | Completa |
| Animações | Interface/GPU | Usa `SystemParametersInfoW` para opções públicas | Tornar a interface mais imediata e reduzir efeitos do desktop | Seguro | W10/W11 | Possível logoff | Completa |
| Sombras | Interface/GPU | Usa parâmetro público e preserva estado original | Reduzir efeitos do desktop | Seguro | W10/W11 | Possível logoff | Completa |
| Miniaturas como efeito | Interface | Opção individual que desativa miniaturas do Explorer | Reduzir geração/leitura de previews em caso específico | Moderado | W10/W11 | Possível Explorer/logoff | Completa |
| Suavização de fontes | Interface | Opção individual, nunca incluída nos perfis automáticos | Redução visual mínima; normalmente não recomendada | Agressivo à usabilidade | W10/W11 | Possível logoff | Completa |
| Cache de shaders DirectX | GPU/Armazenamento | Apaga apenas arquivos no diretório allowlisted | Recuperar espaço e reconstruir cache possivelmente corrompido | Moderado | W10/W11 | Não | Nenhuma; o driver/jogo recompila |
| Caches NVIDIA/AMD | GPU/Armazenamento | Detecta fabricante e limpa apenas diretórios conhecidos, sem seguir reparse points | Recuperar espaço/forçar reconstrução após problemas | Moderado | Somente fornecedor detectado | Não | Nenhuma; recompilação automática |
| Encerrar processo selecionado | Memória/Processos | Protege críticos, sessão 0, PID atual e valida PID + horário de início | Liberar recursos de um aplicativo escolhido | Moderado | W10/W11 | Não | Melhor esforço somente quando reinício foi autorizado |
| Listas de processos | Processos/Jogos | Salva permitidos e itens a fechar antes do jogo; críticos são filtrados | Automatizar apenas escolhas explícitas | Moderado | W10/W11 | Não | Arquivo de estado editável/restaurável |
| Prioridade de processo | Processos | Ajusta classe permitida para o PID validado | Redistribuir CPU sob concorrência | Moderado | W10/W11 | Não | Completa enquanto PID/StartTime coincidem |
| Paginação automática | Memória | Devolve o arquivo de paginação ao gerenciamento do Windows | Preservar estabilidade sob pressão de memória | Seguro | W10/W11 | Sim | Completa |
| Paginação personalizada | Memória | Define `pagefile.sys` local com limites validados; não permite desativá-lo pela UI | Atender um caso de capacidade específico | Agressivo | W10/W11 | Sim | Completa |
| Temporários do usuário | Armazenamento | Exclui arquivos allowlisted com idade mínima, sem tocar Downloads/pessoais | Recuperar espaço e reduzir acúmulo | Seguro | W10/W11 | Não | Nenhuma |
| Temporários do Windows | Armazenamento | Exclui apenas arquivos desbloqueados de `%WINDIR%\Temp` | Recuperar espaço do sistema | Moderado/admin | W10/W11 | Não | Nenhuma |
| Cache de miniaturas | Armazenamento | Remove `thumbcache_*.db`, sem desativar a função | Reconstruir cache e recuperar espaço | Seguro | W10/W11 | Não | Nenhuma |
| Relatórios de erros | Armazenamento | Remove WER do usuário e, com admin, filas/arquivos de máquina com 30+ dias | Recuperar espaço de diagnóstico antigo | Seguro/moderado | W10/W11 | Não | Nenhuma |
| Componentes substituídos | Armazenamento | Executa DISM `/StartComponentCleanup`, nunca `/ResetBase` | Reduzir component store com mecanismo suportado | Agressivo | W10/W11 | Possível | Nenhuma |
| Lixeira | Armazenamento | Esvazia somente a unidade confirmada | Recuperar espaço já marcado para descarte | Agressivo | W10/W11 | Não | Nenhuma |
| TRIM ou desfragmentação | Armazenamento | `ReTrim` em SSD/NVMe; `Defrag` somente em HDD confirmado; bloqueia mídia desconhecida | Executar manutenção adequada ao tipo de mídia | Moderado | Tipo deve ser detectável | Não | Nenhuma |
| SFC | Integridade | Oferece `/verifyonly` ou `/scannow` | Detectar/reparar arquivos protegidos corrompidos | Seguro/moderado | W10/W11 | Possível | Verificação: N/A; reparo: nenhuma |
| DISM | Integridade | `CheckHealth`, `ScanHealth` ou `RestoreHealth` com fonte local e `/LimitAccess` | Diagnosticar/reparar a imagem local | Seguro/moderado | W10/W11 | Possível | Diagnóstico: N/A; reparo: nenhuma |
| CHKDSK online | Integridade | Executa somente `/scan`, sem correção destrutiva/agendada | Detectar problemas lógicos do volume | Seguro | NTFS/W10/W11 | Possível conforme resultado | N/A |
| Serviços opcionais | Serviços | Muda estado/start type somente para a allowlist de `Config.json` | Evitar atividade de recurso comprovadamente não usado | Moderado | Serviço precisa estar instalado | Possível | Completa |
| Perfis de serviços | Serviços | Salva seleções nomeadas, lista perfis e aplica `StopOnly` ou `Disabled` conforme escolha explícita | Repetir um conjunto allowlisted | Moderado | Serviço precisa estar instalado | Possível | Completa pelo backup |
| Programas de inicialização | Inicialização | Remove valor Run ou move atalho para o backup; não desinstala o programa | Reduzir atividade após logon | Moderado | W10/W11 | Possível logoff | Completa |
| Appx opcional | Aplicativos | Remove pacote allowlisted apenas do usuário atual; protege Store, Security, Xbox, Gaming Services e frameworks | Reduzir aplicativos opcionais não utilizados | Agressivo | Pacote/edição dependentes | Possível | Melhor esforço se o manifesto local permanecer |
| Aplicativos em segundo plano | Aplicativos | Abre opções por aplicativo; não aplica bloqueio global | Reduzir atividade sem quebrar autenticação/sincronização global | Manual | Varia por app/build | Possível | Manual |
| Experiências personalizadas | Privacidade | Aplica política documentada quando a edição permite | Mais privacidade e menos conteúdo personalizado | Seguro | Pro+; build 15063+ | Não normalmente | Completa |
| Sugestões de terceiros | Privacidade | Desativa política documentada de sugestões de terceiros | Menos conteúdo promocional | Seguro | Pro+; build 14393+ | Não normalmente | Completa |
| Identificação de publicidade | Privacidade | Desativa o ID por política de máquina | Mais privacidade; sem benefício de FPS comprovado | Seguro | Pro+; build 14393+ | Não normalmente | Melhor esforço; o ID antigo não volta |
| Histórico de atividades | Privacidade | Desativa feed, publicação e upload por políticas documentadas | Menos coleta opcional | Moderado | Pro+; build 17134+ | Não normalmente | Completa |
| Diagnóstico opcional | Privacidade | Define `AllowTelemetry=1`, o mínimo obrigatório suportado, nunca zero de segurança | Reduzir dados opcionais | Moderado | Pro+; build 15063+ | Não normalmente | Completa |
| Dicas do Windows | Privacidade/Interface | Função do módulo para `DisableSoftLanding` | Menos dicas ocasionais | Seguro | Enterprise/Education/IoT | Não normalmente | Completa |
| Recursos de consumo | Privacidade/Interface | Função do módulo para a política oficial de conteúdo promocional | Menos provisionamento/recomendações promocionais | Moderado | Enterprise/Education/IoT | Não normalmente | Completa |
| Recomendações do Iniciar | Interface/Privacidade | Controla `Start_IrisRecommendations` no usuário atual | Menu Iniciar mais limpo | Seguro | Windows 11 | Não normalmente | Completa |
| Tarefas opcionais | Tarefas agendadas | Desativa individualmente apenas tarefas allowlisted; não as exclui | Evitar execuções periódicas opcionais | Moderado | Tarefa precisa existir | Não | Completa |
| Ponto de restauração | Segurança | Solicita `Checkpoint-Computer` e registra sucesso/erro no manifesto | Contingência adicional ao backup granular | Seguro | Proteção do Sistema/limite do Windows | Não | N/A; usar `rstrui.exe` para restaurar sistema |
| Perfil Seguro | Perfis | Game Mode/captura quando suportados, visual equilibrado e startup selecionado; preserva energia e privacidade | Aplicar conjunto conservador e explicável | Seguro | Conforme capacidades | Possível | Completa, exceto limpeza opcional marcada |
| Perfil Equilibrado | Perfis | Acrescenta serviços/tarefas selecionados e paginação automática | Reduzir atividade escolhida sem tocar essenciais | Moderado | Conforme capacidades | Possível | Completa, exceto limpeza opcional marcada |
| Perfil Máximo FPS | Perfis | Exige um `.exe` válido e executa energia, visuais, serviços e processos numa sessão monitorada | Preparar temporariamente o ambiente com escolhas agressivas | Agressivo | Conforme capacidades | Possível | Melhor esforço automático ao término; limpeza opcional continua separada |
| Perfil por jogo | Jogos/Programas | Salva executável, argumentos, prioridade, processos, serviços, energia e visuais por jogo | Repetir uma sessão consistente sem alterar arquivos do jogo | Moderado | W10/W11 | Não | Configuração removível; sessão com restauração automática |
| Análise explicável | Análise | Calcula prontidão usando métricas e estado local, sem estimar FPS | Priorizar recomendações e revelar gargalos de configuração | Informativo | W10/W11 | Não | N/A |

### Allowlists de limpeza

| ID | Local | Regra |
|---|---|---|
| `UserTemp` | `%TEMP%` | Arquivos com a idade mínima escolhida; padrão de 7 dias |
| `WindowsTemp` | `%WINDIR%\Temp` | Arquivos com 7+ dias; itens bloqueados são ignorados |
| `DirectXCache` | `%LOCALAPPDATA%\D3DSCache` | Cache reconstruível |
| `Thumbnails` | `%LOCALAPPDATA%\Microsoft\Windows\Explorer` | Somente `thumbcache_*.db` |
| `UserWER` | `%LOCALAPPDATA%\Microsoft\Windows\WER` | Relatórios com 30+ dias |
| `MachineWERArchive` | `%ProgramData%\Microsoft\Windows\WER\ReportArchive` | Arquivos com 30+ dias e administrador |
| `MachineWERQueue` | `%ProgramData%\Microsoft\Windows\WER\ReportQueue` | Arquivos com 30+ dias e administrador |

Downloads, Documentos, Área de Trabalho, Imagens, Vídeos e Músicas são raízes bloqueadas. A limpeza gráfica também rejeita junctions/symlinks (`ReparsePoint`) e só percorre diretórios exatos de cache detectados.

### Serviços opcionais disponíveis

Nenhum serviço é selecionado automaticamente. A interface mostra finalidade, benefício possível, problemas, necessidade de reinício e se a sessão tentará restaurá-lo.

| Serviço | Finalidade | Quando pode fazer sentido parar/desativar | Impacto provável |
|---|---|---|---|
| `Spooler` | Impressão e impressoras virtuais | Máquina sem qualquer impressão | Impressão e Microsoft Print to PDF podem falhar |
| `Fax` | Envio/recepção de fax | Recurso nunca usado | Fax deixa de funcionar |
| `bthserv` | Descoberta e associação Bluetooth | Desktop sem Bluetooth | Headset, controle, teclado ou mouse Bluetooth pode desconectar |
| `MapsBroker` | Mapas offline | Nenhum app usa mapas baixados | Mapas offline deixam de atualizar |
| `lfsvc` | Geolocalização | Localização não é usada | Clima, mapas e automações perdem localização |
| `TabletInputService` | Toque, caneta e teclado virtual | Desktop sem toque/caneta | Entrada por toque/caneta pode parar; logoff pode ser necessário |
| `WbioSrvc` | Biometria/Windows Hello | Nenhum login biométrico | Digital/rosto pode parar; logoff pode ser necessário |
| `RetailDemo` | Demonstração comercial | Computador pessoal comum | Modo de loja fica indisponível |
| `XblAuthManager` | Autenticação Xbox Live | Nenhum jogo Xbox/Store/Game Pass | Login, conquistas e jogos da Store podem falhar |
| `XboxGipSvc` | Acessórios Xbox | Nenhum acessório Xbox | Controles/acessórios podem parar |

Serviços de RPC, logon, áudio, energia, Defender, Update, Store, criptografia e rede estão na lista protegida e não podem entrar nos perfis opcionais.

### Tarefas opcionais disponíveis

| Caminho/nome | Finalidade | Possível efeito ao desativar |
|---|---|---|
| `Application Experience\Microsoft Compatibility Appraiser` | Inventário de compatibilidade | Menos dados locais para avaliação de upgrades |
| `Application Experience\ProgramDataUpdater` | Dados de compatibilidade de programas | Diagnóstico de compatibilidade menos atualizado |
| `Customer Experience Improvement Program\Consolidator` | Consolidação de dados opcionais | Dados CEIP opcionais deixam de ser enviados |
| `Customer Experience Improvement Program\UsbCeip` | Estatísticas opcionais de USB | Telemetria USB opcional deixa de executar |

Tarefas de Windows Update, Update Orchestrator, Defender, Servicing, CHKDSK, WaaSMedic e certificados são protegidas.

### Aplicativos Appx opcionais

Somente pacotes cujo nome corresponde a uma destas entradas podem ser removidos individualmente:

`Microsoft.BingWeather`, `Microsoft.GetHelp`, `Microsoft.Getstarted`, `Microsoft.MicrosoftSolitaireCollection`, `Microsoft.People`, `Microsoft.WindowsMaps`, `Microsoft.ZuneMusic`, `Microsoft.ZuneVideo`, `Clipchamp.Clipchamp`, `Microsoft.Todos` e `MSTeams`.

Microsoft Store, Store Purchase App, Windows Security, Desktop App Installer, Gaming Services, Xbox, VCLibs, .NET Native, UI Xaml, Windows App Runtime, WinUI, brokers de conta e shells essenciais são bloqueados. Aplicativos Win32 são apenas inventariados; a desinstalação deve ser feita em **Aplicativos Instalados**.

### Efeitos visuais individuais

O módulo expõe transparência, miniaturas, animação de janelas, arraste de janela completa, suavização de fontes, animações de menu e combo box, rolagem suave, fades, tooltip, sombra do cursor, sombras, efeitos gerais, animações de área cliente e atraso de menu. Ele usa `SystemParametersInfoW` para parâmetros públicos; apenas transparência e miniaturas usam preferências de Registro conhecidas.

Os perfis automáticos **preservam miniaturas e suavização de fontes**. O perfil automático usa Equilibrado em notebook e Máximo Desempenho em desktop. Isso não implica ganho dentro de um jogo em tela cheia.

## Perfis de otimização

### Seguro

- solicita Game Mode quando a build permite;
- desativa Game DVR somente onde a política é suportada;
- usa o perfil visual Equilibrado;
- preserva o plano de energia atual e as preferências de privacidade; essas opções continuam disponíveis individualmente;
- desativa somente os itens de inicialização selecionados;
- inclui somente temporários antigos do usuário se a caixa irreversível for marcada. O cache de shaders permanece intacto; a limpeza manual de caches continua disponível para diagnóstico.

### Equilibrado

Inclui tudo do Seguro e também:

- serviços opcionais selecionados;
- tarefas opcionais selecionadas;
- paginação automática;
- mesmas seleções explícitas de inicialização;
- limpeza somente quando confirmada separadamente.

### Máximo FPS

Exige um executável local válido antes de iniciar qualquer transação. Os ajustes agressivos são executados em uma sessão transitória monitorada, sem criar nem sobrescrever silenciosamente a biblioteca de perfis; energia, serviços, processos, prioridade e efeitos da sessão são restaurados ao término. Sem `.exe`, a ação é recusada sem criar backup nem estado de sessão.

Usa `AboveNormal` e Alto Desempenho temporariamente. Não altera Game Mode, capturas, tarefas ou inicialização antes da sessão. A interface permanece disponível para encerrar e restaurar a sessão, inclusive ao fechar a janela. Limpeza irreversível é recusada nesse perfil. Ultimate e prioridade High continuam como escolhas individuais; compare capturas e temperatura antes de adotá-los.

Novos perfis de jogos e sessões avulsas preservam energia por padrão (`PowerPlan = 'None'`); perfis já salvos mantêm a escolha anterior. A caixa de Alto Desempenho permanece desmarcada até ser escolhida explicitamente.

O nome “Máximo FPS” descreve o nível de agressividade, não um resultado mensurável garantido. O perfil não desativa Defender, Update, rede, serviços essenciais, Xbox/Gaming Services automaticamente, BIOS ou proteções do Windows.

## Análise e pontuação

**Analisar computador** coleta inventário e uma amostra local de CPU, RAM, disco e processos. A pontuação é de prontidão/configuração, não de FPS. Os pesos em `Config.json` são:

| Componente | Peso máximo | Observação |
|---|---:|---|
| Inicialização | 12 | Bom até 8 itens; alerta a partir de 15 |
| Processos | 0 | Inventário; contagem não indica carga nem FPS |
| CPU em repouso | 12 | Bom até 5%; alerta a partir de 12%; é uma amostra instantânea |
| RAM em repouso | 12 | Bom até 55%; alerta a partir de 75%; cache do Windows é normal |
| Espaço livre | 10 | Bom com 20%+; alerta abaixo de 10% |
| Plano de energia | 0 | Não penaliza Balanced ou planos do fabricante |
| Game Mode | 8 | Só entra quando o estado é determinável |
| Capturas | 8 | Só entra quando o estado é determinável |
| Serviços opcionais | 0 | Serviço ativo não é evidência de consumo relevante |
| Efeitos visuais | 0 | Afeta sobretudo o desktop |
| Aplicativos em segundo plano | 0 | Contagem isolada não indica gargalo |
| Integridade | 4 | Só deve contar quando houver resultado conhecido |

A integridade só entra na pontuação depois que uma saída de SFC ou DISM corresponde a uma regra conservadora conhecida em português ou inglês. O aplicativo persiste ferramenta, modo, horário UTC, código de saída e evidência resumida; saídas desconhecidas e reparos ainda não verificados permanecem “inconclusivos”. Resultados expiram após 30 dias; um resultado inconclusivo vigente nunca é mascarado por outra ferramenta e não recebe pontos.

Componentes indisponíveis ou indeterminados são omitidos em vez de receber uma nota inventada. O uso de disco por processo exibido na lista é taxa de I/O em MB/s, não percentual físico do disco. O estado de atualizações é somente histórico local e reinicialização pendente; o aplicativo não pesquisa a Internet.

A CPU por processo é normalizada pelo total de processadores lógicos (0–100% do computador). Contadores ausentes de CPU e I/O ficam indeterminados, em vez de aparentarem consumo zero. Energia, contagens de processos/serviços/aplicativos e efeitos visuais não entram na nota, inclusive com configurações antigas. A sugestão de revisar aplicativos em segundo plano exige também carga de CPU elevada.

## Comparar FPS e estabilidade (1.1.0)

Na página **Início**, use **Comparar dois CSVs** e escolha primeiro a captura anterior e depois a posterior. A importação funciona sem administrador, inclusive em simulação e somente leitura. O otimizador não inicia capturas nem baixa ferramentas.

Gere os CSVs com o [PresentMon oficial](https://github.com/GameTechDev/PresentMon). Exemplo para o console que oferece `--v1_metrics`:

```powershell
.\PresentMon.exe --process_name jogo.exe --v1_metrics --delay 10 --timed 60 --terminate_after_timed --output_file antes.csv
# Repita a mesma cena após mudar uma única opção, usando --output_file depois.csv.
```

Use um único jogo/processo/swap chain em cada arquivo, separador vírgula e decimais com ponto. O módulo exige `MsBetweenPresents` em milissegundos e aceita arquivos de até 128 MB/dois milhões de linhas. Capturas misturadas são recusadas para não somar frames de fluxos diferentes. Pelo módulo é possível selecionar um fluxo explicitamente:

```powershell
Import-Module .\Benchmark.psm1
$antes = Import-FrameTimeCapture .\antes.csv -ProcessId 1234 -SwapChainAddress '0x1234' -WarmupFrames 120
$depois = Import-FrameTimeCapture .\depois.csv -ProcessId 5678 -SwapChainAddress '0x5678' -WarmupFrames 120
(Compare-FrameTimeCapture $antes $depois).Metrics | Format-Table
```

- FPS médio: `1000 / média dos intervalos`, sem fazer média de FPS instantâneos.
- 1% low: `1000 / média dos ceil(N × 0,01) intervalos mais lentos`. Ferramentas com outras definições podem mostrar valores diferentes.
- P95/P99: percentis nearest-rank dos intervalos; menores são melhores. O pior quadro também é exibido.
- Intervalos zero são contabilizados separadamente e omitidos; números inválidos, negativos ou não finitos são recusados. Travadas válidas não são removidas como outliers.

Essas métricas representam intervalos de apresentação, sem medir latência de entrada ou FPS exibido com geração de quadros. Aqueça o jogo e o cache de shaders antes da captura. Repita de três a cinco capturas alternadas com a mesma cena, duração, resolução, limite de FPS, driver e condições térmicas. Capturas curtas e diferenças de duração recebem avisos; uma comparação isolada não comprova ganho.

No Windows 11 22H2+, a página **Jogos** também oferece **Otimizações para jogos em janela**, abrindo Gráficos para revisão manual. O recurso se aplica a jogos DX10/DX11 em janela/sem bordas e exige reiniciar o jogo após alterar. HAGS continua como opção manual dependente do hardware e driver.

Referências técnicas consultadas em 12/11/2026: [otimizações para jogos em janela](https://support.microsoft.com/en-us/windows/hardware/display-graphics/optimizations-for-windowed-games-in-windows-11), [contadores de CPU e múltiplos processadores](https://learn.microsoft.com/en-us/windows/win32/perfctrs/collecting-performance-data), [formato CSV do PresentMon](https://github.com/GameTechDev/PresentMon/blob/main/README-ConsoleApplication.md), [cache de shaders como diagnóstico](https://nvidia.custhelp.com/app/answers/detail/a_id/5735) e [opções de temporizador do BCDEdit destinadas à depuração](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/bcdedit--set). Não são aplicados ajustes de HPET/BCD, desativação de segurança, core parking ou limpeza artificial de RAM.

Execute `powershell.exe -NoProfile -File .\Tests\Test-PerformanceImprovements.ps1` para verificar fórmulas, filtros de capturas, padrões dos perfis, pontuação e CPU normalizada com fixtures isoladas. O build também executa esse teste.

## Backup e restauração

### Onde os dados ficam

Por padrão:

```text
%LOCALAPPDATA%\WindowsFPSOptimizer\
├── Backups\
├── Logs\
└── State\
```

Se o perfil bloquear gravação em `%LOCALAPPDATA%`, o aplicativo usa uma pasta
temporária apenas para diagnóstico e simulação. Alterações reais são recusadas,
pois não seria possível garantir backups persistentes.

Cada transação raiz cria uma pasta com data UTC e GUID. O pacote contém:

- `manifest.json` e `manifest.sha256`;
- `baseline.json` com inventário de energia, visuais, serviços opcionais, tarefas, inicialização, paginação, jogos/captura/HAGS, privacidade e última integridade quando o usuário cria um backup manual;
- versão do aplicativo, computador, usuário, Windows, PowerShell, data e perfil;
- estado original e aplicado de cada entrada;
- exportações `.reg` de emergência das chaves tocadas, com SHA-256 quando a exportação funciona;
- estado de serviços, tarefas, energia, paginação, visuais, startup e recursos da sessão;
- resultado da tentativa de criar ponto de restauração;
- histórico de restauração e conflitos.

`baseline.json` é somente um inventário para auditoria/restauração manual; as restaurações automáticas usam as entradas granulares capturadas imediatamente antes de cada mutação. Caminho, tamanho e SHA-256 do baseline são validados ao listar ou importar o pacote.

O checkpoint é **best effort**: Proteção do Sistema desativada, falta de privilégio ou o limite de frequência do Windows podem impedir sua criação. O erro fica registrado e é mostrado imediatamente. O baseline ainda é preservado, enquanto alterações reais continuam usando seus próprios manifestos granulares.

### Restauração pela interface

- **Desfazer última otimização:** restaura o backup pendente mais recente;
- **Restaurar tudo:** processa backups do mais novo para o mais antigo;
- **Carregar itens da transação / Restaurar somente o item selecionado:** lista resumos seguros e restaura exatamente o `EntryId` escolhido;
- **Restaurar transação inteira:** restaura todas as entradas reversíveis daquele manifesto;
- **Restaurar inicialização/serviço/tarefa/visual/energia:** atalhos especializados;
- **Importar backup:** aceita pasta ou `manifest.json`, exige `manifest.sha256`, valida esquema, caminhos e hashes;
- **Abrir pasta de backup:** abre a raiz persistente no Explorer.

Um backup manual que contenha somente baseline/checkpoint não finge possuir restauração granular: a interface orienta consultar `baseline.json` ou usar a Restauração do Sistema. Ele não é tratado como uma transação de tweaks.

Sem `Force`, o restaurador faz comparação em três vias: original, valor que o otimizador aplicou e valor atual. Se outro programa ou o usuário mudou o recurso depois, a restauração retorna `Conflict` e preserva a mudança posterior. Use restauração forçada apenas depois de revisar o manifesto.

`manifest.sha256` detecta corrupção acidental; ele não é uma assinatura digital e não comprova a autoria do backup. Nunca restaure um manifesto recebido da Internet ou de outra pessoa. Use apenas backups criados nesta máquina/usuário e passe pacotes externos pelo botão **Importar backup** para que as validações adicionais sejam executadas.

Backups importados não reiniciam processos nem registram Appx; esses tipos são bloqueados na importação por segurança. Um Appx local só pode ser restaurado em melhor esforço se o `AppxManifest.xml` original ainda existir.

### O que não pode ser desfeito

- temporários, caches, relatórios WER e Lixeira;
- TRIM/desfragmentação já executados;
- DISM `StartComponentCleanup`;
- reparos efetuados por SFC ou DISM;
- conteúdo de um Appx cujo payload local foi removido;
- estado interno e dados não salvos de um processo encerrado.

### Restauração manual se a interface não abrir

1. Faça uma cópia da pasta `Backups` antes de qualquer tentativa.
2. Abra Windows PowerShell 5.1 como administrador.
3. Importe os módulos na mesma ordem do inicializador e restaure o manifesto desejado:

```powershell
$root = 'C:\CAMINHO\WindowsFPSOptimizer'
$modules = @(
    'Logging.psm1','Core.psm1','BackupManager.psm1','ProcessManager.psm1',
    'ServiceManager.psm1','StartupManager.psm1','PowerOptimizations.psm1',
    'GraphicsOptimizations.psm1','StorageOptimizations.psm1','WindowsAppsManager.psm1',
    'PrivacyManager.psm1','ScheduledTaskManager.psm1','GameOptimizations.psm1',
    'SystemAnalysis.psm1','Profiles.psm1','UIController.psm1'
)
foreach ($module in $modules) { Import-Module (Join-Path $root $module) -Force }
$ctx = Initialize-OptimizerContext -AppRoot $root -ConfigPath (Join-Path $root 'Config.json')
Initialize-OptimizerLogging -RootPath $ctx.LogRoot | Out-Null

Get-OptimizerBackups | Format-Table CreatedAtUtc, Name, Status, PendingCount, ManifestPath -AutoSize
# Use somente um ManifestPath retornado pela linha anterior, dentro do BackupRoot local.
Restore-OptimizerBackup -ManifestPath 'C:\CAMINHO\LOCAL\Backups\...\manifest.json' -Confirm:$false
```

4. Para energia, consulte `powercfg.exe /list` e reative manualmente o GUID original registrado no manifesto com `powercfg.exe /setactive GUID`.
5. Para um serviço, abra `services.msc` e use `Original.StartMode`/`Original.Status` do manifesto.
6. Para uma tarefa, abra `taskschd.msc` e reaplique o campo `Original.Enabled`.
7. Para paginação, abra `SystemPropertiesAdvanced.exe` > Desempenho > Avançado > Memória virtual e use o estado original do manifesto.
8. Para inicialização, use o restaurador do módulo sempre que possível; atalhos desativados ficam dentro do próprio pacote de backup.
9. Arquivos `.reg` são contingência de chave, não substituem a restauração granular: importar uma chave inteira pode sobrescrever valores posteriores e não remove necessariamente valores que antes não existiam.
10. Como último recurso, execute `rstrui.exe` e escolha o checkpoint registrado, se ele tiver sido criado com sucesso.

Reinicie depois de restaurar paginação ou quando o manifesto indicar `RequiresRestart`.

## Logs e relatórios

Os logs persistentes são:

- `optimizer.jsonl`: um objeto JSON por linha, tolerante a interrupções;
- `optimizer.log`: visão textual legível.

Cada evento pode conter data/hora ISO 8601, sessão, categoria, nome, valor anterior, novo valor, resultado, erro, reinicialização, perfil, nível e detalhes. A interface mostra os eventos recentes e permite exportar:

- TXT;
- CSV;
- JSON;
- HTML em tema escuro.

Os relatórios descrevem ações e resultados. Eles não incluem telemetria remota e não são enviados automaticamente.

## Riscos, controvérsias e casos que podem piorar o desempenho

Revise estes pontos antes do modo real:

- **Planos agressivos:** elevam consumo, ruído e temperatura. Em notebook ou refrigeração limitada, throttling térmico pode reduzir desempenho sustentado.
- **Estado mínimo alto da CPU:** mantém consumo ocioso elevado e pode reduzir margem térmica para boost. Os valores padrão do Windows costumam ser melhores que `100% mínimo`.
- **Ultimate Performance:** nem sempre existe e frequentemente não melhora jogos em relação a Balanced/High Performance.
- **HAGS:** pode melhorar, piorar ou não alterar frametime conforme GPU, driver, captura e jogo. Por isso é manual e requer reinício.
- **Tela cheia:** desativar otimizações pode ajudar um jogo antigo e piorar outro; nunca é aplicado globalmente.
- **Prioridade High:** pode prejudicar áudio, streaming, captura, entrada ou processos que alimentam o próprio jogo. `Realtime` é bloqueado.
- **Serviços Xbox/Bluetooth:** podem quebrar autenticação, Game Pass, controles e headsets. Não os desative se forem usados.
- **Spooler:** desligá-lo também afeta Microsoft Print to PDF e software que enumera impressoras.
- **Processos:** encerrar um aplicativo pode perder trabalho não salvo; reiniciar o executável não recupera seu estado interno.
- **Caches de shaders:** a primeira execução posterior pode ter mais stutter enquanto shaders são recompilados.
- **Efeitos visuais:** normalmente afetam a experiência do desktop, não FPS dentro do jogo. Desativar miniaturas/font smoothing pode piorar produtividade e legibilidade.
- **Paginação personalizada:** tamanho insuficiente pode causar travamentos, falhas de alocação e ausência de crash dumps. O gerenciamento automático é a opção recomendada para a maioria.
- **Limpeza de componentes:** é suportada, mas irreversível; não execute durante update/manutenção do Windows.
- **SFC/DISM:** são ferramentas de reparo, não “tweaks de FPS”, e podem mudar arquivos do sistema legítimos quando há corrupção.
- **TRIM/Defrag:** são manutenção, não garantia de FPS. O módulo bloqueia desfragmentação manual em SSD, mas a detecção de mídia precisa estar correta.
- **Startup:** desativar launchers, sincronizadores ou utilitários de periféricos pode impedir recursos esperados no logon.
- **Privacidade:** benefícios são principalmente de privacidade/menos conteúdo; não existe ganho de FPS comprovado. Políticas podem aparecer como “gerenciadas pela organização”.
- **Tarefas de compatibilidade:** desativá-las pode reduzir dados usados por upgrades e solucionadores; updates podem recriá-las.
- **Appx:** reinstalação offline não é garantida se o payload desaparecer. A Microsoft Store pode ser necessária depois, mas o aplicativo nunca a acessa automaticamente.
- **Máquina virtual:** não representa HAGS, GPU híbrida, latência de driver ou temperatura real. Use VM para segurança/rollback, não para concluir desempenho de jogos.

Faça uma alteração por vez e compare benchmarks repetíveis do próprio jogo, com mesma cena, driver, temperatura e processos. Uma média isolada é insuficiente para concluir melhoria de frametime.

## Diferenças entre Windows 10 e Windows 11

| Recurso | Windows 10 | Windows 11 |
|---|---|---|
| Game Mode | Página oficial; automação conservadoramente desativada | Preferência do usuário automatizável e restaurável |
| Game DVR/capturas | Política automática somente em Pro+ | Página oficial; política antiga não é aplicada |
| HAGS | Página disponível em builds/driver compatíveis | Página oficial; disponibilidade depende de GPU/driver |
| Não Perturbe | Assistente de Foco/Quiet Hours conforme build | Não Perturbe/regras automáticas |
| Preferência de GPU | Página gráfica em 1803+ | Página gráfica atual |
| Segundo plano de Appx | Pode existir página global | Configuração geralmente por aplicativo |
| Recomendações do Iniciar | Não usa `Start_IrisRecommendations` | Preferência disponível |
| Políticas de privacidade | Dependem de build e edição | Dependem de build e edição; algumas opções mudaram de nome |

Em dispositivos Home, várias políticas de Grupo não são suportadas. O módulo retorna `Unsupported`/`Manual` em vez de escrever uma chave que o Windows não honra. Em computador associado a domínio ou MDM, as políticas são bloqueadas por padrão para evitar conflito com a organização.

## Teste em máquina virtual

Use uma VM descartável. O roteiro recomendado é:

1. Crie VMs limpas de Windows 10 22H2 e Windows 11; se possível, teste Home e Pro.
2. Instale as atualizações e ferramentas de integração do hipervisor, reinicie e crie um snapshot chamado `baseline`.
3. Copie o projeto sem instalar módulos e desconecte o adaptador virtual para confirmar funcionamento offline.
4. Execute primeiro com `-Simulation`, sem administrador.
5. Abra todas as páginas, rode **Analisar**, atualize inventários, pesquise processos e exporte os quatro formatos de relatório.
6. Confirme que HAGS, GPU por programa, tela cheia, foco e apps em segundo plano aparecem como manual/indisponível quando apropriado.
7. Execute com `-ReadOnly` e tente uma ação de escrita; ela deve ser recusada.
8. Gere o Setup, instale na VM, abra pelo atalho protegido, desative a simulação e aceite UAC apenas para um teste de baixo risco, como transparência ou um item de startup fictício.
9. Verifique criação de `manifest.json`, `manifest.sha256`, `.reg` e logs.
10. Restaure a última alteração sem `Force` e compare o estado original.
11. Aplique novamente a alteração, mude o mesmo valor manualmente e restaure; o aplicativo deve relatar conflito e preservar a mudança posterior.
12. Teste energia e paginação apenas após snapshot; valide a restauração depois de reiniciar.
13. Para processos, use `notepad.exe`; confirme que processos protegidos e PID reutilizado são bloqueados.
14. Para serviço/tarefa, selecione somente um item opcional existente e valide stop/disable/restore.
15. Teste sessão com um executável local simples; confirme plano, serviço/processo escolhido e restauração ao fechar.
16. Teste limpeza, Appx e `StartComponentCleanup` somente em snapshot descartável, pois são irreversíveis.
17. Compare antes/depois as configurações de DNS, IP, adaptadores, firewall e proxy usando apenas ferramentas de leitura do Windows; não deve existir diferença causada pelo aplicativo.
18. Revise `optimizer.jsonl` procurando qualquer erro, restauração parcial ou reinicialização pendente.
19. Reinicie a VM, reabra o aplicativo e valide que backups, perfis e sessão pendente continuam detectáveis.
20. Volte ao snapshot `baseline` ao final.

Para validar visualmente a WPF, teste escalas de 100%, 125%, 150% e 200%, resolução mínima prática de 1366×768, teclado, foco visível, seleção múltipla, barra de progresso e texto PT-BR. Operações SFC/DISM/otimização de volume não devem ser canceladas à força.

## Criar um atalho de desenvolvimento

O Setup cria atalhos protegidos automaticamente. Para abrir apenas a simulação
diretamente das fontes durante o desenvolvimento, ajuste `$root` e execute:

```powershell
$root = 'C:\CAMINHO\WindowsFPSOptimizer'
$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Windows FPS Optimizer.lnk'))
$lnk.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$root\WindowsFPSOptimizer.ps1`" -Simulation"
$lnk.WorkingDirectory = $root
$lnk.Description = 'Windows FPS Optimizer — inicia em simulação'
$lnk.Save()
```

Não troque esse atalho de fontes para `-NoSimulation`: mutações reais e UAC são
recusados fora de `Program Files`. O próprio aplicativo instalado cria atalhos
para perfis de jogos apontando para sua versão protegida.

## Empacotar como EXE

O projeto inclui um build reproduzível que usa somente `iexpress.exe`, o
compilador do .NET Framework e o Windows PowerShell 5.1, todos componentes
nativos do Windows. Nenhum módulo, download ou executável de terceiros é
necessário.

Na raiz do projeto, execute:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-WindowsFPSOptimizer.ps1
```

O script primeiro executa `Tests\Validate-Project.ps1` no Windows PowerShell
5.1 e só empacota se a validação passar. Os artefatos são criados em `dist`:

- `WindowsFPSOptimizer-<versão>-Setup.exe`;
- o arquivo de hash SHA-256 correspondente;
- `WindowsFPSOptimizer-BuildInfo.json`, com versão, tamanho, hash e estado da
  assinatura.

Ao abrir o EXE, o bootstrap:

- solicita UAC pelo manifesto do próprio EXE, antes de qualquer extração;
- extrai o IExpress embutido somente em uma pasta protegida sob `Program Files`;
- confere o SHA-256 do payload incorporado;
- valida tamanho e SHA-256 de cada arquivo antes de instalar;
- faz uma troca segura por diretório, preservando a versão anterior se a
  instalação falhar;
- instala código em `%ProgramFiles%\WindowsFPSOptimizer\App\<versão>` com ACL
  de leitura/execução para usuários e escrita somente para administradores;
- cria atalhos comuns na Área de Trabalho e no Menu Iniciar;
- não abre a interface dentro do processo elevado: o usuário inicia pelo atalho;
- mantém o modo de simulação ativado por padrão.

Estado, backups, perfis e logs permanecem por usuário em
`%LOCALAPPDATA%\WindowsFPSOptimizer`. O código protegido fica separado desses
dados. O aplicativo solicita novo UAC somente quando uma operação real exigir
privilégio.

Para assinar o EXE com um certificado de assinatura de código já instalado no
repositório pessoal do Windows:

```powershell
.\Build-WindowsFPSOptimizer.ps1 -CodeSigningCertificateThumbprint 'THUMBPRINT'
```

### PS2EXE opcional — não incluído

PS2EXE é uma ferramenta de terceiros. Instalação e auditoria ficam a cargo do mantenedor; o aplicativo nunca a baixa. Um exemplo, após instalar conscientemente o módulo, é:

```powershell
Invoke-ps2exe .\WindowsFPSOptimizer.ps1 .\WindowsFPSOptimizer.exe -noConsole -STA -requireAdmin
```

O executável resultante não incorpora automaticamente `MainWindow.xaml`,
`Config.json` e os módulos. Parâmetros e comportamento também variam por
versão do PS2EXE. Por isso, o launcher com payload IExpress incorporado,
incluído no projeto, é o método suportado.

O payload IExpress não transforma PowerShell em código nativo; o launcher
compilado apenas protege e coordena a instalação.
Sem um certificado confiável, o EXE pode receber aviso do SmartScreen ou do
antivírus. Isso não deve ser contornado: distribuições públicas devem assinar o
artefato e publicar o SHA-256.

A publicação restaura o conjunto anterior quando ocorre uma exceção tratável e
usa renomes no próprio volume para cada arquivo final. Uma queda de energia ou
encerramento forçado exatamente entre os três renomes pode deixar arquivos
ocultos `.wfpo-stage-*` ou `.wfpo-backup-*`; o construtor não apaga esses
arquivos genericamente, para não remover dados que não consiga atribuir à
transação atual. Compare os hashes e preserve-os antes de qualquer limpeza
manual.

## Checklist de segurança e funcionamento

### Antes de aplicar

- [ ] Estou em Windows 10/11 suportado e usando `powershell.exe` 5.1 Desktop.
- [ ] Executei primeiro em simulação.
- [ ] Li benefício, risco, problemas e reinício do item.
- [ ] Fechei documentos e trabalho não salvo.
- [ ] Tenho espaço livre para backup e logs.
- [ ] Proteção do Sistema está habilitada, se quero checkpoint adicional.
- [ ] Confirmei que ExitLag/VPN aparecem protegidos e não selecionei anticheat, launcher necessário, áudio, captura ou periférico usado.
- [ ] Não selecionei Bluetooth/Xbox/Spooler/biometria se dependo do recurso.
- [ ] Não estou durante Windows Update, instalação de driver ou manutenção do sistema.
- [ ] Em notebook, estou monitorando bateria e temperatura.

### Limites que devem permanecer verdadeiros

- [ ] Nenhum comando ou chave de DNS/TCP/IP/MTU/Winsock/proxy/Teredo/QoS/rota.
- [ ] Nenhuma alteração de Wi-Fi, Ethernet, adaptador, firewall, porta ou serviço essencial de rede.
- [ ] Nenhuma alteração no ExitLag/VPN ou arquivos de jogos.
- [ ] Nenhum download automático ou executável externo desconhecido.
- [ ] Nenhum Defender/Update/Store/Gaming Services essencial desativado automaticamente.
- [ ] Nenhum overclock, BIOS, clock, voltagem ou instalação automática de driver.
- [ ] Nenhum processo crítico, sessão 0, PID 0/4 ou processo do próprio aplicativo encerrado.
- [ ] Nenhuma tarefa/serviço/Appx fora da allowlist modificado.
- [ ] Nenhum arquivo pessoal ou Downloads incluído na limpeza.
- [ ] Nenhum SSD desfragmentado manualmente.

### Depois de aplicar

- [ ] O resultado está como `Success`, `Skipped` ou `Simulated`, sem erro oculto.
- [ ] Existe manifesto válido para toda mudança reversível.
- [ ] O log contém valor anterior, novo valor, perfil e reinicialização.
- [ ] Áudio, controle, login, Store, Defender e Windows Update continuam funcionando.
- [ ] ExitLag/VPN e as configurações de rede permanecem inalterados.
- [ ] Temperatura e clocks sustentados não pioraram por throttling.
- [ ] O jogo e aplicativos auxiliares necessários continuam funcionando.
- [ ] Comparei benchmark repetível, não apenas sensação ou pico de FPS.
- [ ] Reiniciei quando paginação/Windows indicou necessidade.

### Restauração

- [ ] Testei **Desfazer última otimização** antes de aplicar um perfil amplo.
- [ ] Não usei `Force` sem revisar conflitos.
- [ ] Entendo quais itens são irreversíveis.
- [ ] Guardei a pasta de backup fora da VM/máquina antes de uma migração.
- [ ] Após restaurar, conferi serviços, tarefas, energia, startup, paginação e visuais.
- [ ] Se o aplicativo fechou durante um jogo, restaurei a sessão pendente.

## Referências técnicas

O projeto prefere APIs e ferramentas documentadas do Windows:

- [SystemParametersInfoW](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-systemparametersinfow)
- [Opções de linha de comando do powercfg](https://learn.microsoft.com/windows-hardware/design/device-experiences/powercfg-command-line-options)
- [Optimize-Volume](https://learn.microsoft.com/en-us/powershell/module/storage/optimize-volume?view=windowsserver2025-ps)
- [Reparar uma imagem do Windows com DISM](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/repair-a-windows-image?view=windows-11)
- [System File Checker](https://support.microsoft.com/en-us/windows/experience/backup-recovery/use-the-system-file-checker-tool-to-repair-missing-or-corrupted-system-files)
- [Policy CSP — ApplicationManagement/AllowGameDVR](https://learn.microsoft.com/windows/client-management/mdm/policy-csp-applicationmanagement#allowgamedvr)
- [Policy CSP — Experience](https://learn.microsoft.com/windows/client-management/mdm/policy-csp-experience)
- [Hardware-accelerated GPU scheduling](https://devblogs.microsoft.com/directx/hardware-accelerated-gpu-scheduling/)
- [Abrir páginas do aplicativo Configurações](https://learn.microsoft.com/en-us/windows/apps/develop/launch/launch-settings)

Quando não existe API pública estável — HAGS, preferência gráfica por executável, compatibilidade de tela cheia, Não Perturbe e permissões modernas de segundo plano — o aplicativo abre a página oficial ou fornece instrução manual em vez de gravar chaves privadas.

## Contribuições

Melhorias são bem-vindas. Se quiser corrigir um problema, aprimorar uma
funcionalidade ou propor algo novo, faça um fork do repositório, crie uma
branch com a sua alteração e abra um **pull request** explicando o que mudou.

Antes de enviar, execute os testes disponíveis, mantenha as proteções de
segurança do projeto e não inclua logs, builds ou dados pessoais no commit.

## Licenciamento e manutenção

Este projeto é open source e distribuído sob a [licença MIT](LICENSE). Ao
alterar `Config.json`, mantenha allowlists conservadoras, documente cada
impacto e valide em Windows 10/11. Não transforme recomendações em aplicação
automática sem contrato público, backup, verificação posterior e caminho de
restauração.

# Histórico de mudanças

## 2.1.0 — 13/11/2026

- Perfis revisados com base em testes publicados: as descrições dizem o que cada ajuste costuma (ou não) mudar.
- **Máximo FPS** deixou de depender de um jogo: agora é um perfil do Windows, aplicado e restaurado como os outros.
- O Máximo usa o plano Alto Desempenho quando existe ou o modo de energia **Melhor desempenho** em notebooks que só têm o plano Equilibrado. Planos personalizados ou do fabricante são preservados.
- Equilibrado e Máximo desligam a gravação em segundo plano do Game Bar; a gravação manual continua disponível.
- O Máximo informa quando a Integridade de memória está ativada e abre o Isolamento de núcleo, sem desativá-la.
- A sessão de jogo temporária continua disponível como ferramenta opcional na interface avançada.
- Máximo inclui os recursos de otimização do Windows do ExitLag e do NoPing: núcleos sem estacionamento (exceto Ryzen X3D), PCI Express e USB sem economia, Game Bar e Game DVR desligados, último acesso do NTFS e contadores de desempenho desligados, SysMain e Windows Search desativados, economia de energia do Ethernet desligada, auxiliares em segundo plano fechados e memória liberada. Todos com backup, exceto o fechamento de programas.
- Equilibrado também desliga o último acesso do NTFS e libera a memória dos programas.
- O desligamento do Windows Defender oferecido pelo ExitLag não foi incluído por segurança.

## 2.0.0 — 13/11/2026

- Aplicativo reescrito em Rust: executável único e portátil para Windows 10/11 em x64, x86 e ARM64, sem instalador, PowerShell ou Visual C++ Redistributable.
- Interface gráfica com OpenGL, segundo renderizador (wgpu) e interface nativa do Windows como último recurso.
- Perfis Seguro, Equilibrado e Máximo FPS com análise prévia, backup transacional e restauração com detecção de conflitos.
- Equilibrado devolve a memória virtual manual ao gerenciamento automático do Windows, com backup exato da configuração anterior e restauração.
- Máximo FPS em sessão temporária (prioridade, efeitos visuais, plano de energia, bloqueio de suspensão e serviços opcionais), restaurada por um monitor independente quando o jogo termina.
- Botão **Reabrir como administrador** para memória virtual e serviços.
- Manifesto com DPI por monitor, controles comuns v6 e caminhos longos.
- Build, testes e release feitos localmente por `rust/build-release.ps1`; os workflows do GitHub Actions foram removidos.
- Backups da versão 1.x não são importados; use a versão 1.2.0 para restaurá-los.

## 1.2.0 — 12/11/2026

- Novo visual com cores, contraste, cartões de presets e hierarquia mais claros.
- Interface simplificada com **Seguro**, **Equilibrado** e **Máximo FPS**, explicações, teste sem alterações e restauração pelo backup.
- Máximo FPS simplificado permite escolher o executável do jogo e encerrar/restaurar a sessão.
- Onboarding de três etapas na primeira abertura, com escolha de interface, opção de pular, voltar e reabrir em **Primeiros passos**.
- Preferências da interface e conclusão do onboarding salvas por usuário, inclusive em simulação.
- Carregamento inicial simplificado consulta apenas métricas e backups; o inventário completo é carregado ao entrar no modo avançado.
- Aplicativo WinExe com motor do Windows PowerShell integrado ao próprio processo, sem janela de terminal.
- Instalador com pacote ZIP validado, sem CMD ou IExpress; atalhos normais, UAC e atalhos de jogos usam o aplicativo gráfico.
- Consultas e ferramentas nativas executadas sem console, com captura de saída e preservação dos códigos de erro.
- Testes adicionais da experiência simplificada, dos três presets, das preferências e da execução nativa.

## 1.1.0 — 12/11/2026

- Comparador de capturas CSV do PresentMon na página Início: FPS médio, 1% low, tempo médio/P95/P99 e pior quadro.
- Validação de dados, filtros de processo/swap chain e avisos para capturas curtas ou com durações diferentes.
- CPU por processo normalizada pelo total de processadores lógicos; contadores indisponíveis permanecem indeterminados.
- Perfis Seguro e Equilibrado preservam energia e privacidade. Novos perfis e sessões avulsas preservam o plano de energia por padrão.
- Limpeza dos perfis preserva caches de shaders.
- Máximo FPS entra diretamente em sessão temporária, usa AboveNormal e Alto Desempenho e mantém os controles de encerramento/restauração disponíveis.
- A nota não recompensa redução de processos/serviços nem alteração de efeitos visuais ou plano de energia.
- Acesso às otimizações oficiais para jogos em janela no Windows 11 22H2+.
- Testes adicionais de fórmulas, filtros, perfis, pontuação, CPU e classificação das sessões na interface.
- Instalador aceita `/quiet` ou `--quiet`, mantendo elevação, ACL, hashes e validação do recibo.
- Build no GitHub Actions, testes de integração/restauração, instalação do EXE final em runner descartável e arquivos de procedência e SHA-256.

O aplicativo inicia em simulação. Não foram medidos ganhos de FPS em jogos nesta versão. O comparador usa capturas externas; os resultados dependem de hardware, driver, jogo e condições da medição.

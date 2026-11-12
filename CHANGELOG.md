# Histórico de mudanças

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

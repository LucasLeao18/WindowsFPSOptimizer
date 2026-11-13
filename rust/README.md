# Reescrita em Rust — em desenvolvimento

Esta pasta contém uma implementação independente ainda incompleta. Não distribua esta versão como substituta da versão publicada: os três perfis são parciais e várias funções avançadas ainda não foram implementadas ou validadas.

Há uma interface inicial acessível, análise e aplicação parcial dos perfis Seguro e Equilibrado, backup e restauração com detecção de conflitos, uma sessão de prioridade para o executável selecionado, diagnóstico, inventário somente leitura de processos e comparação de capturas CSV do PresentMon. O Equilibrado atualmente só funciona quando a memória virtual já está sob gerenciamento automático; ele não altera essa configuração. O Máximo FPS ainda não implementa os demais ajustes da sessão anterior e precisa de mais testes. A implementação não migra os backups da versão anterior. O aplicativo atual em PowerShell permanece intacto.

A interface tenta OpenGL e, se a inicialização falhar antes de o aplicativo abrir, tenta uma vez um segundo renderizador. A disponibilidade depende do Windows, dos drivers e do ambiente gráfico; acesso remoto e máquinas virtuais também precisam de validação. Há uma mensagem nativa se ambos falharem.

Com Rust e uma toolchain de link para Windows instalados:

```powershell
cd rust
cargo test
cargo run
```

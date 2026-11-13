# Reescrita em Rust — em desenvolvimento

Esta pasta contém uma implementação independente ainda incompleta. Não distribua esta versão como substituta da versão publicada: os três perfis são parciais e várias funções avançadas ainda não foram implementadas ou validadas.

Há uma interface inicial acessível, análise e aplicação parcial dos perfis Seguro e Equilibrado, backup e restauração com detecção de conflitos, sessão de jogo, diagnóstico, inventário de processos e comparação de capturas CSV do PresentMon. A sessão tenta ajustar a prioridade do executável selecionado, ativar o plano Alto Desempenho quando este já existe e impedir temporariamente a suspensão automática enquanto o aplicativo e o processo estão abertos; ela não impede que a tela apague. Os valores anteriores de prioridade e energia são registrados separadamente. Se o aplicativo for fechado antes do jogo, é necessário reabri-lo para restaurar o plano ao fim da sessão. O encerramento de um processo é uma ação manual, sujeita a análise e confirmação; os perfis não encerram programas. O Equilibrado atualmente só funciona quando a memória virtual já está sob gerenciamento automático; ele não altera essa configuração. O Máximo FPS ainda não implementa os demais ajustes da sessão anterior e precisa de mais testes. A implementação não migra os backups da versão anterior. O aplicativo atual em PowerShell permanece intacto.

A interface tenta OpenGL e, se a inicialização falhar antes de o aplicativo abrir, tenta um segundo renderizador. Se nenhum estiver disponível, abre uma interface nativa de compatibilidade com os três perfis e a recuperação de backups; as ferramentas avançadas ainda exigem a interface completa. A disponibilidade depende do Windows, dos drivers e do ambiente gráfico; acesso remoto e máquinas virtuais também precisam de validação.

Com Rust e uma toolchain de link para Windows instalados:

```powershell
cd rust
cargo test
cargo run
```

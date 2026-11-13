# Reescrita em Rust — em desenvolvimento

Esta pasta contém uma implementação independente ainda incompleta. Não distribua esta versão como substituta da versão publicada: os três perfis são parciais e várias funções avançadas ainda não foram implementadas ou validadas.

Há uma interface inicial acessível, análise e aplicação parcial dos perfis Seguro e Equilibrado, backup e restauração com detecção de conflitos, sessão de jogo, diagnóstico, inventário de processos e comparação de capturas CSV do PresentMon. A sessão tenta ajustar a prioridade do executável selecionado, ativar o plano Alto Desempenho quando este já existe e impedir temporariamente a suspensão automática enquanto o aplicativo e o processo estão abertos; ela não impede que a tela apague. Os valores anteriores de prioridade e energia são registrados separadamente. Um monitor tenta restaurá-los ao fim do jogo mesmo se a janela for fechada; conflitos ou falhas persistentes mantêm os registros para revisão. O encerramento de um processo é uma ação manual, sujeita a análise e confirmação; os perfis não encerram programas. O Equilibrado consulta a memória virtual quando possível, mas ainda não altera essa configuração nem implementa todas as opções adicionais da versão anterior. O Máximo FPS ainda não implementa os demais ajustes da sessão anterior e precisa de mais testes. A implementação não migra os backups da versão anterior. O aplicativo atual em PowerShell permanece intacto.

Na interface avançada, a limpeza de temporários é uma ação manual: analisa arquivos com mais de sete dias diretamente em `LocalAppData\Temp` e pede confirmação para removê-los permanentemente. Ela não percorre subpastas e preserva arquivos alterados desde a análise ou impossíveis de verificar. Nenhum perfil inicia a limpeza.

A interface avançada também permite revisar e desativar individualmente entradas de inicialização da chave `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`. O comando selecionado é exibido antes da confirmação, o valor é salvo e a alteração utiliza uma transação do Registro. Entradas protegidas e conflitos não são alterados. Outras origens, incluindo entradas de máquina e atalhos na pasta de inicialização, ainda não foram portadas.

A interface tenta OpenGL e, se a inicialização falhar antes de o aplicativo abrir, tenta um segundo renderizador. Se nenhum estiver disponível, abre uma interface nativa de compatibilidade com os três perfis e a recuperação de backups; as ferramentas avançadas ainda exigem a interface completa. A disponibilidade depende do Windows, dos drivers e do ambiente gráfico; acesso remoto e máquinas virtuais também precisam de validação.

Com Rust e uma toolchain de link para Windows instalados:

```powershell
cd rust
cargo test
cargo run
```

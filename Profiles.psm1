#requires -Version 5.1

Set-StrictMode -Version Latest

function New-OptimizerOperationDescriptor {
    param(
        [string]$Id, [string]$Name, [string]$Category, [string]$Description,
        [ValidateSet('Safe', 'Moderate', 'Aggressive', 'Information', 'Manual')][string]$Risk,
        [string]$Compatibility, [ValidateSet('Never', 'Possible', 'Required')][string]$Restart,
        [ValidateSet('Full', 'BestEffort', 'None', 'Manual')][string]$Reversibility,
        [bool]$RequiresAdmin = $false
    )
    return [pscustomobject]@{
        Id = $Id; Version = 1; Name = $Name; Category = $Category; Description = $Description
        Risk = $Risk; Compatibility = $Compatibility; Restart = $Restart
        Reversibility = $Reversibility; RequiresAdmin = $RequiresAdmin; NetworkImpact = $false
    }
}

function Get-OptimizerOperationCatalog {
    [CmdletBinding()]
    param()

    return @(
        (New-OptimizerOperationDescriptor 'games.game-mode' 'Game Mode' 'Jogos' 'Ativa o recurso suportado pelo Windows quando a build oferece contrato documentado.' Safe 'Windows 10/11; automacao depende da build' Never Full),
        (New-OptimizerOperationDescriptor 'games.capture' 'Capturas e Game DVR' 'Jogos' 'Desativa por politica suportada no Windows 10; no Windows 11 abre Configuracoes.' Safe 'Windows 10 automatizado; Windows 11 manual' Possible Full $true),
        (New-OptimizerOperationDescriptor 'games.game-bar' 'Xbox Game Bar' 'Jogos' 'Abre a pagina oficial; nao remove Xbox nem Gaming Services.' Manual 'Windows 10/11' Never Manual),
        (New-OptimizerOperationDescriptor 'games.hags' 'HAGS' 'Jogos/GPU' 'Consulta capacidade conservadora e abre Configuracoes para alteracao.' Manual 'GPU/driver/build dependentes' Required Manual),
        (New-OptimizerOperationDescriptor 'games.fullscreen' 'Tela cheia por jogo' 'Jogos' 'Orienta alteracao manual por executavel; nenhuma camada interna nao documentada.' Manual 'Windows 10/11' Never Manual),
        (New-OptimizerOperationDescriptor 'games.gpu-preference' 'Preferencia de GPU' 'Jogos/GPU' 'Abre Configuracoes graficas para o executavel escolhido.' Manual 'Windows 10 1803+/11' Never Manual),
        (New-OptimizerOperationDescriptor 'games.windowed' 'Jogos em janela' 'Jogos/GPU' 'Abre Graficos para revisar otimizacoes de jogos DX10/DX11 em janela e sem bordas.' Manual 'Windows 11 22H2+' Never Manual),
        (New-OptimizerOperationDescriptor 'analysis.benchmark' 'Comparar capturas' 'Analise' 'Compara FPS, 1% low e frametimes medidos em CSV do PresentMon.' Information 'CSV com MsBetweenPresents' Never None),
        (New-OptimizerOperationDescriptor 'games.priority' 'Prioridade do jogo' 'Jogos/Processos' 'Aplica AboveNormal ou High enquanto o processo existe; nunca Realtime.' Moderate 'Windows 10/11' Never BestEffort),
        (New-OptimizerOperationDescriptor 'games.notifications' 'Nao Perturbe' 'Jogos' 'Abre a regra oficial de foco/nao perturbe para jogos.' Manual 'Varia entre Windows 10/11' Never Manual),
        (New-OptimizerOperationDescriptor 'games.session' 'Sessao de jogo' 'Jogos' 'Orquestra somente selecoes do usuario e restaura ao fim.' Moderate 'Windows 10/11' Possible BestEffort $true),
        (New-OptimizerOperationDescriptor 'power.high-performance' 'Alto Desempenho' 'CPU/Energia' 'Ativa plano conhecido e preserva o GUID anterior.' Moderate 'Windows 10/11' Never Full $true),
        (New-OptimizerOperationDescriptor 'power.ultimate' 'Desempenho Maximo' 'CPU/Energia' 'Ativa ou duplica o plano quando suportado.' Aggressive 'Disponibilidade varia' Never Full $true),
        (New-OptimizerOperationDescriptor 'power.custom' 'Plano personalizado' 'CPU/Energia' 'Cria copia isolada para configuracoes de jogo.' Moderate 'Windows 10/11' Never Full $true),
        (New-OptimizerOperationDescriptor 'power.processor' 'Estados do processador' 'CPU/Energia' 'Ajusta min/max AC/DC dentro de 0 a 100.' Moderate 'Firmware/ACPI dependentes' Never Full $true),
        (New-OptimizerOperationDescriptor 'power.cooling' 'Politica de resfriamento' 'CPU/Energia' 'Usa apenas configuracao exposta pelo plano.' Moderate 'Pode estar oculta/indisponivel' Never Full $true),
        (New-OptimizerOperationDescriptor 'power.session-sleep' 'Suspensao durante jogos' 'CPU/Energia' 'Ajuste temporario de tela/suspensao para a sessao.' Safe 'Windows 10/11' Never Full $true),
        (New-OptimizerOperationDescriptor 'power.usb-device' 'Suspensao seletiva por dispositivo' 'CPU/Energia' 'Abre o Gerenciador de Dispositivos; drivers nao possuem contrato universal.' Manual 'Dependente do driver' Possible Manual),
        (New-OptimizerOperationDescriptor 'graphics.transparency' 'Transparencias' 'GPU/Interface' 'Desativa transparencia por preferencia documentada.' Safe 'Windows 10/11' Possible Full),
        (New-OptimizerOperationDescriptor 'graphics.animations' 'Animacoes' 'GPU/Interface' 'Usa SystemParametersInfo para efeitos suportados.' Safe 'Windows 10/11' Possible Full),
        (New-OptimizerOperationDescriptor 'graphics.shadows' 'Sombras' 'GPU/Interface' 'Usa SystemParametersInfo e preserva o estado original.' Safe 'Windows 10/11' Possible Full),
        (New-OptimizerOperationDescriptor 'graphics.thumbnails' 'Miniaturas' 'Interface' 'Opcao individual; pode prejudicar navegacao.' Moderate 'Windows 10/11' Possible Full),
        (New-OptimizerOperationDescriptor 'graphics.font-smoothing' 'Suavizacao de fontes' 'Interface' 'Opcao individual, nunca incluida em perfis automaticos.' Aggressive 'Windows 10/11' Possible Full),
        (New-OptimizerOperationDescriptor 'graphics.cache-directx' 'Cache DirectX' 'GPU/Armazenamento' 'Remove cache recompilavel; pode haver stutter inicial.' Moderate 'Windows 10/11' Never None),
        (New-OptimizerOperationDescriptor 'graphics.cache-vendor' 'Caches NVIDIA/AMD' 'GPU/Armazenamento' 'Remove somente diretorios detectados e conhecidos.' Moderate 'Fornecedor dependente' Never None),
        (New-OptimizerOperationDescriptor 'memory.process-stop' 'Encerrar processo selecionado' 'Memoria/Processos' 'Bloqueia processos criticos e valida PID + StartTime.' Moderate 'Windows 10/11' Never BestEffort),
        (New-OptimizerOperationDescriptor 'memory.pagefile-auto' 'Paginacao automatica' 'Memoria' 'Devolve o dimensionamento ao Windows.' Safe 'Windows 10/11' Required Full $true),
        (New-OptimizerOperationDescriptor 'memory.pagefile-custom' 'Paginacao personalizada' 'Memoria' 'Limites validados, aviso e backup completo.' Aggressive 'Windows 10/11' Required Full $true),
        (New-OptimizerOperationDescriptor 'storage.temp-user' 'Temporarios do usuario' 'Armazenamento' 'Remove somente arquivos temporarios validados.' Safe 'Windows 10/11' Never None),
        (New-OptimizerOperationDescriptor 'storage.temp-windows' 'Temporarios do Windows' 'Armazenamento' 'Remove arquivos desbloqueados do diretorio Temp do Windows.' Moderate 'Windows 10/11' Never None $true),
        (New-OptimizerOperationDescriptor 'storage.thumbnails' 'Cache de miniaturas' 'Armazenamento' 'Limpa cache reconstruivel sem desativar miniaturas.' Safe 'Windows 10/11' Never None),
        (New-OptimizerOperationDescriptor 'storage.wer' 'Relatorios de erro antigos' 'Armazenamento' 'Limpa relatorios locais antigos, nao o servico.' Safe 'Windows 10/11' Never None),
        (New-OptimizerOperationDescriptor 'storage.components' 'Componentes substituidos' 'Armazenamento' 'DISM StartComponentCleanup sem ResetBase.' Aggressive 'Windows 10/11' Possible None $true),
        (New-OptimizerOperationDescriptor 'storage.recycle-bin' 'Lixeira' 'Armazenamento' 'Esvazia somente uma unidade confirmada.' Aggressive 'Windows 10/11' Never None),
        (New-OptimizerOperationDescriptor 'storage.optimize' 'TRIM ou desfragmentacao' 'Armazenamento' 'ReTrim em SSD/NVMe; Defrag somente em HDD confirmado.' Moderate 'Tipo de midia deve ser conhecido' Never None $true),
        (New-OptimizerOperationDescriptor 'integrity.sfc' 'SFC' 'Integridade' 'Verifica ou repara arquivos protegidos.' Moderate 'Windows 10/11' Possible None $true),
        (New-OptimizerOperationDescriptor 'integrity.dism' 'DISM' 'Integridade' 'Check/ScanHealth; RestoreHealth exige fonte local e LimitAccess.' Moderate 'Windows 10/11' Possible None $true),
        (New-OptimizerOperationDescriptor 'integrity.disk' 'CHKDSK scan' 'Integridade' 'Verificacao online nao destrutiva.' Safe 'NTFS/Windows 10/11' Possible None $true),
        (New-OptimizerOperationDescriptor 'services.optional' 'Servicos opcionais' 'Servicos' 'Somente itens da allowlist, um a um, com impacto exibido.' Moderate 'Servico deve estar instalado' Possible Full $true),
        (New-OptimizerOperationDescriptor 'startup.manage' 'Inicializacao' 'Inicializacao' 'Move valor/atalho selecionado para backup, sem remover programa.' Moderate 'Windows 10/11' Possible Full),
        (New-OptimizerOperationDescriptor 'apps.optional-remove' 'Appx opcional' 'Aplicativos' 'Remove somente para o usuario e fora da blocklist.' Aggressive 'Payload/edicao dependentes' Possible BestEffort),
        (New-OptimizerOperationDescriptor 'apps.background' 'Segundo plano por aplicativo' 'Aplicativos' 'Abre opcoes avancadas; Windows 11 nao possui controle global suportado.' Manual 'Varia por aplicativo/build' Possible Manual),
        (New-OptimizerOperationDescriptor 'privacy.tailored' 'Experiencias personalizadas' 'Privacidade' 'Politica documentada quando a edicao oferece suporte.' Safe 'Pro+; build dependente' Possible Full $true),
        (New-OptimizerOperationDescriptor 'privacy.ad-id' 'ID de publicidade' 'Privacidade' 'Desativa pela politica suportada; beneficio principal e privacidade.' Safe 'Pro+; build dependente' Possible BestEffort $true),
        (New-OptimizerOperationDescriptor 'privacy.activity' 'Historico de atividades' 'Privacidade' 'Desativa feed/publicacao/upload quando suportado.' Moderate 'Pro+; recurso varia' Possible Full $true),
        (New-OptimizerOperationDescriptor 'privacy.diagnostics' 'Diagnostico opcional' 'Privacidade' 'Reduz ao minimo permitido; nunca desativa seguranca.' Moderate 'Edicao/politica dependente' Possible Full $true),
        (New-OptimizerOperationDescriptor 'tasks.optional' 'Tarefas opcionais' 'Tarefas' 'Somente allowlist individual; nao toca seguranca/manutencao essencial.' Moderate 'Tarefa deve existir' Never Full $true),
        (New-OptimizerOperationDescriptor 'security.restore-point' 'Ponto de restauracao' 'Seguranca' 'Cria checkpoint quando Protecao do Sistema permite.' Safe 'Pode estar desabilitado/limitado' Never Full $true),
        (New-OptimizerOperationDescriptor 'profiles.safe' 'Perfil seguro' 'Perfis' 'Agrupa somente alteracoes de baixo risco e escolhas explicitas.' Safe 'Conforme capacidades' Possible Full $true),
        (New-OptimizerOperationDescriptor 'profiles.balanced' 'Perfil equilibrado' 'Perfis' 'Inclui servicos/tarefas/processos selecionados.' Moderate 'Conforme capacidades' Possible Full $true),
        (New-OptimizerOperationDescriptor 'profiles.maximum' 'Perfil maximo FPS' 'Perfis' 'Mais agressivo e preferencialmente temporario por sessao.' Aggressive 'Conforme capacidades' Possible BestEffort $true),
        (New-OptimizerOperationDescriptor 'games.profile' 'Perfil por jogo' 'Jogos/Programas' 'Salva configuracao separada por executavel.' Moderate 'Windows 10/11' Never Full),
        (New-OptimizerOperationDescriptor 'analysis.score' 'Analise explicavel' 'Analise' 'Pontuacao de prontidao; nunca estima FPS.' Information 'Windows 10/11' Never None)
    )
}

function Get-OptimizationProfiles {
    [CmdletBinding()]
    param()
    return @(
        [pscustomobject]@{
            Name = 'Safe'; Title = 'Perfil seguro'; Risk = 'Safe'
            Description = 'Game Mode, capturas quando suportadas e visuais equilibrados; preserva energia e preferencias de privacidade.'
            RequiresConfirmation = $false
        },
        [pscustomobject]@{
            Name = 'Balanced'; Title = 'Perfil equilibrado'; Risk = 'Moderate'
            Description = 'Acrescenta somente servicos, tarefas, inicializacao e processos previamente selecionados.'
            RequiresConfirmation = $true
        },
        [pscustomobject]@{
            Name = 'MaximumFPS'; Title = 'Perfil maximo FPS'; Risk = 'Aggressive'
            Description = 'Exige um jogo selecionado e usa somente uma sessao temporaria para energia, visuais, servicos e processos.'
            RequiresConfirmation = $true
        }
    )
}

function Invoke-KnownProfileCommand {
    param([string]$CommandName, [hashtable]$Parameters = @{}, [switch]$Optional)
    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    if (-not $command) {
        if ($Optional) { return [pscustomobject]@{ Command = $CommandName; Status = 'Unsupported' } }
        throw "Capacidade indisponivel: $CommandName"
    }
    return & $CommandName @Parameters
}

function Invoke-OptimizationProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Safe', 'Balanced', 'MaximumFPS')][string]$Name,
        [string[]]$SelectedServices = @(),
        [string[]]$SelectedTaskIds = @(),
        [string[]]$SelectedStartupIds = @(),
        [switch]$IncludeCleanup,
        [switch]$Confirmed,
        [switch]$ConfirmedIrreversible,
        [string]$GameExecutable
    )

    if ($Name -ne 'Safe' -and -not $Confirmed) { throw 'O perfil selecionado exige confirmacao explicita.' }
    if ($IncludeCleanup -and -not $ConfirmedIrreversible) { throw 'A limpeza irreversivel exige confirmacao separada.' }
    $sessionBoundMaximum = ($Name -eq 'MaximumFPS')
    if ($sessionBoundMaximum) {
        if ($IncludeCleanup) {
            throw 'O perfil maximo FPS e temporario. Desmarque a limpeza e use a pagina de armazenamento separadamente.'
        }
        if ([string]::IsNullOrWhiteSpace($GameExecutable)) {
            throw 'O perfil maximo FPS exige um executavel de jogo. Nenhuma alteracao foi iniciada.'
        }
        if (-not (Test-SafeExecutablePath -Path $GameExecutable)) {
            throw 'Executavel de jogo invalido. Nenhuma alteracao foi iniciada.'
        }
    }
    Set-OptimizerCurrentProfile -Name $Name
    try {
        if ($sessionBoundMaximum) {
            # Nao execute ajustes persistentes de Game Mode, captura ou startup
            # antes da sessao que promete restaurar os recursos alterados.
            $sessionResult = Invoke-TransientGameProfile -ExecutablePath $GameExecutable -Priority AboveNormal `
                -SuspendServices $SelectedServices -PowerPlan HighPerformance -PreventSleep $true `
                -ReduceVisualEffects $true -UseConfiguredProcessList $true
            return [pscustomobject]@{ ProfileResults = @(); GameSession = $sessionResult }
        }
        $profileResults = Invoke-OptimizerOperation -Name "Aplicar perfil $Name" `
            -Risk $(switch ($Name) { 'Safe' { 'Seguro' } 'Balanced' { 'Moderado' } default { 'Agressivo' } }) `
            -RequiresAdministrator -ScriptBlock {
            $results = New-Object System.Collections.Generic.List[object]

            $results.Add((Invoke-KnownProfileCommand 'Set-GameModeState' @{ Enabled = $true } -Optional))
            $results.Add((Invoke-KnownProfileCommand 'Set-GameCaptureState' @{ Disabled = $true } -Optional))
            $results.Add((Invoke-KnownProfileCommand 'Set-VisualEffectsProfile' @{ Profile = 'Balanced' } -Optional))
            # Energia e privacidade continuam como escolhas explicitas na interface.
            # Planos agressivos podem aumentar temperatura e prejudicar o boost sustentado.

            foreach ($startupId in $SelectedStartupIds) { $results.Add((Disable-StartupItem -Id $startupId)) }
            if ($IncludeCleanup) {
                $results.Add((Invoke-SafeCleanup -Categories @('UserTemp') -Confirmed))
            }

            if ($Name -eq 'Balanced') {
                foreach ($service in $SelectedServices) {
                    $results.Add((Set-OptionalServiceState -Name $service -DesiredState Disabled))
                }
                foreach ($taskId in $SelectedTaskIds) {
                    $parts = $taskId -split '\|', 2
                    if ($parts.Count -ne 2) { throw "ID de tarefa invalido: $taskId" }
                    $results.Add((Set-OptionalScheduledTaskState -TaskPath $parts[0] -TaskName $parts[1] -Enabled $false))
                }
                $results.Add((Invoke-KnownProfileCommand 'Set-AutomaticPageFile' @{} -Optional))
            }

            return $results.ToArray()
        }
        return $profileResults
    }
    finally { Set-OptimizerCurrentProfile -Name '' }
}

function Invoke-QuickOptimization {
    [CmdletBinding()]
    param([string[]]$SelectedStartupIds = @())
    return Invoke-OptimizationProfile -Name Safe -SelectedStartupIds $SelectedStartupIds
}

Export-ModuleMember -Function Get-OptimizerOperationCatalog, Get-OptimizationProfiles,
    Invoke-OptimizationProfile, Invoke-QuickOptimization

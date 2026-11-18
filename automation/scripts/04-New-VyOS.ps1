#Requires -Version 7.2
<#
.SYNOPSIS
    Cria o roteador VyOS do lab como VM no ESXi físico, instala pela ISO e aplica a configuração.
.DESCRIPTION
    - Envia a ISO do VyOS para o [ds-ssd] ISO/ (se faltar)
    - VM BIOS com 3 placas: eth0 = rede de casa (DHCP, WAN/NAT), eth1 = VCF911-MGMT (sem tag),
      eth2 = VCF911-NSX-TRUNK (VLAN 4095, VIFs 13-16)
    - Live: digita só login + DHCP/SSH; 'install image' roda por SSH respondendo cada pergunta pelo texto
    - Desliga, tira a ISO com a VM desligada, liga pelo disco e grava DHCP/SSH com a senha nova
    - Depois do reboot, descobre o IP da eth0 pelo VMware Tools, copia o script de configuração por SCP
      e aplica (gerência 10.52.10.1, VIFs, MTU, NAT, BGP pronto para os Edges)
.PARAMETER Force
    Apaga a VM existente e recria.
.PARAMETER WanIp
    IP da eth0 do VyOS, se o VMware Tools não informar (veja na console: show interfaces).
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '../config/lab-config.psd1'),
    [switch]$Force,
    [string]$WanIp
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LabCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'EsxiPlatform.psm1') -Force
Import-Module Posh-SSH
Assert-Admin
$cfg = Get-LabConfig -Path $ConfigPath
$v = $cfg.VyOS; $n = $cfg.Network
$wanNet = ($cfg.EsxiHost.Address -replace '\.\d+$', '')   # rede de casa (/24 do ESXi físico)
Connect-LabEsxi -Config $cfg | Out-Null
Write-LabLog "VyOS $($v.VmName) no [$($v.Datastore)]" 'STEP'


function Wait-VyosConsole {
    # o VyOS (live e instalado) pode não ter VMware Tools: espera fixa até o prompt de login
    param([string]$Name, [int]$ExtraSec = 120)
    Write-LabLog "Aguardando o boot do VyOS ($ExtraSec s)..."
    Start-Sleep -Seconds $ExtraSec
}

function Wait-VyosIp {
    # IP da eth0 pelo VMware Tools ou, sem Tools, pelo MAC na rede de casa (varredura ping + tabela ARP da svc01)
    param([string]$Name, [string]$Mac, [string]$Subnet, [int]$TimeoutSec = 600)
    $mac = $Mac.ToLower(); $t = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $ip = @((Get-LabVm $Name).Guest.IPAddress) | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' -and $_ -notlike '10.52.*' } | Select-Object -First 1
        if ($ip) { return $ip }
        & bash -c "for i in `$(seq 1 254); do ping -c1 -W1 $Subnet.`$i >/dev/null 2>&1 & done; wait" 2>$null
        $n = & ip neigh show 2>$null | Where-Object { $_.ToLower() -match [regex]::Escape($mac) -and $_ -notmatch 'FAILED|INCOMPLETE' } | Select-Object -First 1
        if ($n) { return ($n -split '\s+')[0] }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $t)
    return $null
}

function Get-VyosLoginKeys {
    param([string]$Password, [switch]$Save)
    $k = @('<enter><wait3s>', 'vyos<enter><wait3s>', "$Password<enter><wait5s>",
           'configure<enter><wait3s>', 'set interfaces ethernet eth0 address dhcp<enter><wait1s>',
           'set service ssh port 22<enter><wait1s>', 'commit<enter><wait8s>')
    if ($Save) { $k += 'save<enter><wait3s>' }
    $k + 'exit<enter><wait2s>'
}

function Invoke-VyosInstall {
    # roda 'install image' numa sessão SSH interativa e responde cada pergunta pelo texto (robusto à ordem/versão)
    param([string]$Ip, [string]$Password)
$cred = [pscredential]::new('vyos', (ConvertTo-SecureString 'vyos' -AsPlainText -Force))
    $s = New-SSHSession -ComputerName $Ip -Credential $cred -AcceptKey -Force
    try {
        $st = New-SSHShellStream -SSHSession $s -TerminalName 'dumb' -Columns 250 -Rows 60
        Start-Sleep -Seconds 3; $null = $st.Read()
        $st.WriteLine('install image')
        Write-LabLog 'install image (respondendo as perguntas pela sessão SSH)...'
        $rules = @(
            @{ Re = '(?i)password';                              Ans = $Password; Show = '********' }
            @{ Re = '(?i)name (this|the) image';                 Ans = '' }
            @{ Re = '(?i)console';                               Ans = 'K' }
            @{ Re = '(?i)which one should be used for install';  Ans = '' }
            @{ Re = '(?i)boot config';                           Ans = '1' }
            @{ Re = '(?i)\[y/N\]|\[Y/n\]|\(y/n\)|\[yes/no\]';    Ans = 'y' }
        )
        $buf = ''; $mark = 0; $last = Get-Date; $deadline = (Get-Date).AddMinutes(20)
        while ((Get-Date) -lt $deadline) {
            $o = $st.Read()
            if ($o) { $buf += ($o -replace "`e\[[0-9;?]*[A-Za-z]", '' -replace "`r", ''); $last = Get-Date }
            if ($buf -match '(?i)installed successfully|please reboot|installation (is )?complete') {
                Write-LabLog 'VyOS instalado no disco' 'OK'
                $st.WriteLine('sudo poweroff'); Start-Sleep -Seconds 3
                return
            }
            $tail = $buf.Substring($mark)
            $ready = $tail.TrimEnd() -match '[\?\:\]\)]$' -and ((Get-Date) - $last).TotalSeconds -ge 1.5
            if ($ready) {
                $q = ($tail.Trim() -split "`n")[-1]
                $hit = $rules | Where-Object { $tail -match $_.Re } | Select-Object -First 1
                $ans = if ($hit) { $hit.Ans } elseif (((Get-Date) - $last).TotalSeconds -ge 15) { '' } else { $null }
                if ($null -ne $ans) {
                    $show = if ($hit -and $hit.Show) { $hit.Show } elseif ($ans) { $ans } else { '<Enter>' }
                    Write-LabLog "  ? $($q.Trim())  ->  $show"
                    $st.WriteLine($ans); $mark = $buf.Length; $last = Get-Date
                }
            }
            Start-Sleep -Milliseconds 500
        }
        throw "install image não terminou em 20 min. Últimas linhas: $(($buf -split "`n" | Select-Object -Last 8) -join ' | ')"
    } finally { Remove-SSHSession -SSHSession $s -ErrorAction SilentlyContinue | Out-Null }
}

$vm = Get-LabVm $v.VmName
if ($vm -and $Force) { Remove-LabVm $v.VmName | Out-Null; $vm = $null; Write-LabLog 'VM antiga apagada' }
$cred = [pscredential]::new('vyos', (ConvertTo-SecureString $v.Password -AsPlainText -Force))

if (-not $vm) {
    if (-not (Test-Path $cfg.Paths.IsoVyos)) { throw "ISO do VyOS não encontrada: $($cfg.Paths.IsoVyos)" }
    $iso = Copy-LabIso -Config $cfg -LocalPath $cfg.Paths.IsoVyos
    $nics = @(
        @{ Portgroup = $n.WanPortgroup;   Mac = "$($v.MacPrefix):00" }
        @{ Portgroup = $n.MgmtPortgroup;  Mac = "$($v.MacPrefix):01" }
        @{ Portgroup = $n.TrunkPortgroup; Mac = "$($v.MacPrefix):02" }
    )
    $vm = New-LabVm -Name $v.VmName -Datastore $v.Datastore -GuestId 'debian12_64Guest' -NumCpu $v.CpuCount -MemoryGB ([math]::Ceiling($v.MemoryMB / 1024)) `
        -Firmware bios -DiskController pvscsi -Disks @([math]::Ceiling($v.DiskMB / 1024)) -Nics $nics -IsoPath $iso
    Write-LabLog "VM criada; ligando o VyOS live (ISO)" 'OK'
    Start-VM -VM $vm | Out-Null

    # 1) live: só login + DHCP/SSH na eth0 (comandos curtos, sem depender da ordem das perguntas do instalador)
    Wait-VyosConsole -Name $v.VmName -ExtraSec ([math]::Max(120, $v.BootWaitSec))
    Send-LabVmKeys -VM (Get-LabVm $v.VmName) -Command (Get-VyosLoginKeys -Password 'vyos' -Save:$false)
    Write-LabLog 'Aguardando o IP do VyOS live na rede de casa (VMware Tools)...'
    $liveIp = Wait-VyosIp -Name $v.VmName -Mac "$($v.MacPrefix):00" -Subnet $wanNet -TimeoutSec 300
    if (-not $liveIp) { throw "O VyOS live não pegou IP na eth0. Na console (vyos/vyos): show interfaces. O DHCP da rede de casa responde no port group $($n.WanPortgroup)?" }
    if (-not (Wait-TcpPort -ComputerName $liveIp -Port 22 -TimeoutSec 180 -IntervalSec 5)) { throw "SSH do VyOS live em $liveIp não abriu." }
    Write-LabLog "VyOS live em $liveIp" 'OK'

    # 2) install image por SSH, respondendo cada pergunta pelo texto dela
    Invoke-VyosInstall -Ip $liveIp -Password $v.Password

    # 3) desliga, tira a ISO com a VM desligada (sem a pergunta da trava do CD) e liga pelo disco
    Write-LabLog 'Desligando o live, tirando a ISO e ligando pelo disco'
    $t = (Get-Date).AddMinutes(3)
    while ((Get-LabVm $v.VmName).PowerState -ne 'PoweredOff' -and (Get-Date) -lt $t) { Start-Sleep -Seconds 5 }
    $vm = Get-LabVm $v.VmName
    if ($vm.PowerState -ne 'PoweredOff') { Stop-VM -VM $vm -Confirm:$false | Out-Null }
    Get-CDDrive -VM $vm | Set-CDDrive -NoMedia -StartConnected:$false -Confirm:$false | Out-Null
    Start-VM -VM $vm | Out-Null

    # 4) instalado: login com a senha nova + DHCP/SSH gravados
    Wait-VyosConsole -Name $v.VmName -ExtraSec 120
    Send-LabVmKeys -VM (Get-LabVm $v.VmName) -Command (Get-VyosLoginKeys -Password $v.Password -Save:$true)
}
elseif ($vm.PowerState -ne 'PoweredOn') { Start-VM -VM $vm | Out-Null }

# ---------------- configuração (só se o gateway do lab ainda não responde)
if (-not (Wait-TcpPort -ComputerName $n.MgmtGateway -Port 22 -TimeoutSec 20 -IntervalSec 5)) {
    if (-not $WanIp) {
        Write-LabLog 'Aguardando o IP da eth0 (rede de casa): VMware Tools ou MAC na rede...'
        $WanIp = Wait-VyosIp -Name $v.VmName -Mac "$($v.MacPrefix):00" -Subnet $wanNet -TimeoutSec 900
    }
    if (-not $WanIp) { throw "Não descobri o IP da eth0. Na console da VM (login vyos / senha do config): show interfaces; depois rode: .\04-New-VyOS.ps1 -WanIp <ip>" }
    Write-LabLog "VyOS na rede de casa: $WanIp"
    if (-not (Wait-TcpPort -ComputerName $WanIp -Port 22 -TimeoutSec 600 -IntervalSec 10)) { throw "SSH em $WanIp não abriu (a instalação terminou? veja a console)." }

    $script = ConvertTo-VyosScript -Commands (Get-VyosConfigCommands -Config $cfg)
    $scriptPath = Join-Path $cfg.Paths.WorkDir 'vyos-config.vbash'
    [System.IO.File]::WriteAllText($scriptPath, $script + "`n", [System.Text.UTF8Encoding]::new($false))
    Set-SCPItem -ComputerName $WanIp -Credential $cred -Path $scriptPath -Destination '/tmp' -AcceptKey -Force
    $s = New-SSHSession -ComputerName $WanIp -Credential $cred -AcceptKey -Force
    try {
        $r = Invoke-SSHCommand -SSHSession $s -Command "sg vyattacfg -c '/bin/vbash /tmp/vyos-config.vbash'" -TimeOut 300
        $r.Output | Select-Object -Last 5 | ForEach-Object { Write-LabLog "  $_" }
        if (($r.Output -join ' ') -notmatch 'VyOS configurado') { throw "O script do VyOS não terminou: $($r.Error -join ' ')" }
    } finally { Remove-SSHSession -SSHSession $s | Out-Null }
}

Write-LabLog "Aguardando o gateway $($n.MgmtGateway) (SSH 22)..."
if (-not (Wait-TcpPort -ComputerName $n.MgmtGateway -Port 22 -TimeoutSec 600 -IntervalSec 10)) {
    throw "VyOS não respondeu em $($n.MgmtGateway):22 - confira na console se a eth1 está no port group $($n.MgmtPortgroup)."
}
Set-LabVmAutostart -VM (Get-LabVm $v.VmName) -Order 2 -DelaySec 60
Write-LabLog "VyOS no ar: $($v.Hostname) / $($n.MgmtGateway) (WAN na rede de casa)" 'OK'
Write-LabLog 'Para o seu notebook alcançar o lab: rota 10.52.0.0/16 via o IP da eth0 do VyOS (no roteador de casa, ou: route add 10.52.0.0 mask 255.255.0.0 <ip>)' 'INFO'
exit 0

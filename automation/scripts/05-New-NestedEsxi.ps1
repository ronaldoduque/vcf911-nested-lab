#Requires -Version 7.2
<#
.SYNOPSIS
    Cria os ESX 9.1.1 nested como VMs do ESXi físico (um por NVMe), instalados por kickstart.
.DESCRIPTION
    Para cada host do lab-config.psd1:
      1. Gera o kickstart (o mesmo do lab Workstation) e publica no nginx da svc01 (site vcf911-ks, porta 8080)
      2. Cria a VM: EFI, vhv, máscara de CPUID Cascade Lake, vmxnet3 com MAC fixo nos port groups,
         discos thin (OSA: PVSCSI marcado SSD | ESA: NVMe), CD-ROM com a ISO no [ds-ssd]
      3. Liga e digita a linha de boot pela API do ESXi (Shift+O em loop, apaga, redigita com ks=)
    Depois espera as instalações, tira a ISO, sai do modo manutenção, liga NTP e confere o certificado.
.PARAMETER Force
    Apaga as VMs existentes e recria.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '../config/lab-config.psd1'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LabCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'EsxiPlatform.psm1') -Force
Import-Module Posh-SSH
Assert-Admin
$cfg = Get-LabConfig -Path $ConfigPath
$e = $cfg.Esxi; $n = $cfg.Network
$esa = ($cfg.Vcf.VsanMode -eq 'ESA')
Connect-LabEsxi -Config $cfg | Out-Null
Write-LabLog "ESX nested: $($e.Hosts.Count) hosts, $($e.CpuCount) vCPU ($($e.CoresPerSocket)/socket) / $($e.MemoryGB) GB, vSAN $($cfg.Vcf.VsanMode)" 'STEP'

# ---------------------------------------------------------------- site de kickstart no nginx
$ksDir = Join-Path $cfg.Paths.WorkDir 'ks'
New-Item -ItemType Directory -Path $ksDir -Force | Out-Null
$ksSite = 'vcf911-ks'; $ksPort = [int]$e.HttpPortBase
Set-LabNginxSite -Config $cfg -Name $ksSite -Listen "$($n.HostAdapterIp):$ksPort" -Root $ksDir
$repair = if ($e.ContainsKey('VsanRepairDelayMin') -and $e.VsanRepairDelayMin) { [int]$e.VsanRepairDelayMin } else { 60 }

# ---------------------------------------------------------------- hosts fora da conta
foreach ($x in @($e.AllHosts | Select-Object -Skip $e.Hosts.Count)) {
    $xn = "$($cfg.LabName)-$($x.Name)"
    if (Get-LabVm $xn) {
        if ($Force) { Remove-LabVm $xn | Out-Null; Write-LabLog "$xn apagado (lab com $($e.Hosts.Count) hosts)" 'OK' }
        else { Write-LabLog "$xn existe mas o lab está com $($e.Hosts.Count) hosts - apague ou rode com -Force" 'WARN' }
    }
}

$isoDs = $null
$created = @()
for ($i = 0; $i -lt $e.Hosts.Count; $i++) {
    $h = $e.Hosts[$i]; $idx = $i + 1
    $vmName = "$($cfg.LabName)-$($h.Name)"
    $fqdn = "$($h.Name).$($cfg.Domain)"
    $vm = Get-LabVm $vmName
    if ($vm -and -not $Force) { Write-LabLog "$vmName já existe - pulando a instalação (use -Force para reinstalar)" 'WARN'; continue }
    if ($vm) { Remove-LabVm $vmName | Out-Null }
    if (-not $isoDs) {
        if (-not (Test-Path $cfg.Paths.IsoEsxi)) { throw "ISO do ESX não encontrada: $($cfg.Paths.IsoEsxi)" }
        $isoDs = Copy-LabIso -Config $cfg -LocalPath $cfg.Paths.IsoEsxi
    }

    # ---------------- kickstart (igual ao do lab Workstation)
    $ksIgnore = if ($e.LegacyCpu) { ' --ignoreprereqwarnings --ignoreprereqerrors --forceunsupportedinstall' } else { '' }
    $ks = @"
vmaccepteula
keyboard 'US Default'
rootpw $($e.Password)
install --firstdisk --overwritevmfs --novmfsondisk$ksIgnore
network --bootproto=static --device=vmnic0 --ip=$($h.Ip) --netmask=$($n.MgmtNetmask) --gateway=$($n.MgmtGateway) --nameserver=$($n.DnsServer) --hostname=$fqdn --addvmportgroup=0
reboot

%firstboot --interpreter=busybox
vim-cmd hostsvc/enable_ssh
vim-cmd hostsvc/start_ssh
vim-cmd hostsvc/enable_esx_shell
vim-cmd hostsvc/start_esx_shell
esxcli system settings advanced set -o /UserVars/SuppressShellWarning -i 1
esxcli system settings advanced set -o /UserVars/HostClientCEIPOptIn -i 2
esxcli system hostname set --host=$($h.Name) --domain=$($cfg.Domain)
esxcli network ip dns search add --domain=$($cfg.Domain)
esxcli network ip dns server remove --all
esxcli network ip dns server add --server=$($n.DnsServer)
esxcli system ntp set --server=$($n.NtpServer) --enabled=true
# discos virtuais não têm reserva SCSI real (vSAN nested)
esxcli system settings advanced set -o /VSAN/FakeSCSIReservations -i 1
# sem traffic shaping no vSwitch0 (o padrão já é desligado; fica explícito)
esxcli network vswitch standard policy shaping set -v vSwitch0 -e false
# energia em High Performance dentro do ESX nested (sem estados de economia que atrasam o agendamento)
esxcli system settings advanced set -o /Power/CpuPolicy -s "High Performance"
# anéis da vmxnet3 no máximo (4096): menos pacotes descartados ("High pNic error rate") no vSAN/vMotion.
# Vai para o local.sh, que roda a cada boot, e já vale agora.
sed -i '/^exit 0$/d' /etc/rc.local.d/local.sh
cat >> /etc/rc.local.d/local.sh <<'EORING'
for n in `$(esxcli network nic list | awk 'NR>2 {print `$1}'); do esxcli network nic ring current set -n `$n -r 4096 -t 4096 >/dev/null 2>&1; done
exit 0
EORING
sh /etc/rc.local.d/local.sh
# vSAN refaz uma cópia ausente em $repair min (padrão 60)
esxcli system settings advanced set -o /VSAN/ClomRepairDelay -i $repair
/sbin/generate-certificates
/etc/init.d/hostd restart
/etc/init.d/vpxa restart
"@
    [System.IO.File]::WriteAllText((Join-Path $ksDir "$($h.Name).cfg"), ($ks -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))

    # ---------------- VM
    $plan = @(Get-EsxiNicPlan -Config $cfg -HostIndex $idx)
    $extra = [ordered]@{ 'disk.EnableUUID' = 'TRUE'; 'mks.enable3d' = 'FALSE' }
    if ($e.CpuidMask) { $extra['cpuid.1.eax'] = $e.CpuidMask }
    $disks = if ($esa) { @($e.BootDiskGB, $e.CapacityDiskGB) } else { @($e.BootDiskGB, $e.CacheDiskGB, $e.CapacityDiskGB) }
    if (-not $esa) { for ($u = 0; $u -lt $disks.Count; $u++) { $extra["scsi0:$u.virtualSSD"] = '1' } }   # OSA all-flash
    # OSA: toda escrita passa pelo disco de cache; eager-zeroed tira o custo de alocar/zerar na 1a escrita (40 GB por host)
    $ezt = if (-not $esa -and $e.ContainsKey('CacheEagerZero') -and $e.CacheEagerZero) { @(1) } else { @() }
    # vmxnet3 com vários threads de transmissão por placa (ctxPerDev=3): mais vazão de pacotes para vSAN e vMotion
    if ($e.ContainsKey('NicTxThreads') -and $e.NicTxThreads) { for ($k = 0; $k -lt $plan.Count; $k++) { $extra["ethernet$k.ctxPerDev"] = '3' } }
    $vm = New-LabVm -Name $vmName -Datastore $h.Datastore -GuestId 'vmkernel8Guest' -NumCpu $e.CpuCount -CoresPerSocket $e.CoresPerSocket `
        -MemoryGB $e.MemoryGB -Firmware efi -NestedHv -DiskController $(if ($esa) { 'nvme' } else { 'pvscsi' }) -Disks $disks `
        -Nics @($plan | ForEach-Object { @{ Portgroup = $_.Portgroup; Mac = $_.Mac } }) -IsoPath $isoDs -ExtraConfig $extra -EagerZeroDisks $ezt
    Write-LabLog "$vmName criada em [$($h.Datastore)] (MAC0 $($plan[0].Mac))" 'OK'

    # ---------------- boot: Shift+O em loop, apaga a linha e digita a do kickstart
    Start-VM -VM $vm | Out-Null
    $win = if ($e.ShiftOWindowSec) { [int]$e.ShiftOWindowSec } else { 45 }
    $kopt = if ($e.BootKernelOpt) { $e.BootKernelOpt } else { 'runweasel cdromBoot' }
    $extraBoot = if ($e.LegacyCpu) { ' allowLegacyCPU=true cpuUniformityHardCheckPanic=FALSE' } else { '' }
    $line = "$kopt netdevice=$($plan[0].Mac) ip=$($h.Ip) netmask=$($n.MgmtNetmask) gateway=$($n.MgmtGateway) nameserver=$($n.DnsServer) ks=http://$($n.HostAdapterIp):$ksPort/$($h.Name).cfg$extraBoot"
    $cmd = @(1..$win | ForEach-Object { '<leftShiftOn>o<leftShiftOff><wait1s>' }) + @('<end>') + @(1..($win + 60) | ForEach-Object { '<bs>' }) + @('<wait1s>', "$line<enter>")
    Write-LabLog "  digitando a linha de boot (~$($win + 10) s)..."
    Send-LabVmKeys -VM $vm -Command $cmd
    $created += [pscustomobject]@{ Host = $h; Vm = $vmName; Fqdn = $fqdn }
}

# ---------------------------------------------------------------- espera, limpa, confere
$cred = [pscredential]::new('root', (ConvertTo-SecureString $e.Password -AsPlainText -Force))
if ($created.Count) { Write-LabLog "Instalando $($created.Count) host(s) (15-30 min). A console da VM no Host Client mostra o progresso." }
foreach ($h in $e.Hosts) {
    $vmName = "$($cfg.LabName)-$($h.Name)"
    $vm = Get-LabVm $vmName
    if (-not $vm) { throw "$vmName não existe - rode com -Force." }
    if ($vm.PowerState -ne 'PoweredOn') { Start-VM -VM $vm | Out-Null }
    $fqdn = "$($h.Name).$($cfg.Domain)"
    if (-not (Wait-TcpPort -ComputerName $h.Ip -Port 22 -TimeoutSec 3600)) { throw "$fqdn não abriu SSH em 60 min - veja a console da VM $vmName (a linha de boot entrou? o kickstart foi baixado de http://$($n.HostAdapterIp):$([int]$e.HttpPortBase)/$($h.Name).cfg?)." }
    if (-not (Wait-TcpPort -ComputerName $h.Ip -Port 443 -TimeoutSec 900)) { throw "$fqdn não abriu HTTPS." }
    Get-CDDrive -VM $vm | Where-Object { $_.IsoPath } | Set-CDDrive -NoMedia -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    Set-LabVmAutostart -VM $vm -Order (2 + [array]::IndexOf(@($e.Hosts.Name), $h.Name) + 1) -DelaySec 30

    $s = New-SSHSession -ComputerName $h.Ip -Credential $cred -AcceptKey -Force -ConnectionTimeout 30
    try {
        if (Exit-EsxiMaintenanceMode -Session $s) { Write-LabLog "$fqdn fora do modo manutenção" } else { Write-LabLog "$fqdn continua em modo manutenção" 'WARN' }
        foreach ($c in @("esxcli system ntp set --server=$($n.NtpServer) --enabled=true", 'esxcli network firewall ruleset set --ruleset-id=ntpClient --enabled=true', 'chkconfig ntpd on 2>/dev/null; /etc/init.d/ntpd restart')) {
            Invoke-SSHCommand -SSHSession $s -Command $c -TimeOut 60 | Out-Null
        }
        Start-Sleep -Seconds 5
        $ntp = (Invoke-SSHCommand -SSHSession $s -Command 'esxcli system ntp get').Output -join ' '
        if ($ntp -match 'Enabled:\s*true') { Write-LabLog "$fqdn NTP -> $($n.NtpServer)" 'OK' } else { Write-LabLog "$fqdn NTP não ligou: $ntp" 'WARN' }
        $ssd = (Invoke-SSHCommand -SSHSession $s -Command "esxcli storage core device list | grep -c 'Is SSD: true'").Output -join ''
        Write-LabLog "$fqdn discos vistos como SSD: $ssd"
    } finally { Remove-SSHSession -SSHSession $s | Out-Null }

    $tcp = [System.Net.Sockets.TcpClient]::new($h.Ip, 443)
    $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, { $true })
    try { $ssl.AuthenticateAsClient($fqdn); $subject = ([System.Security.Cryptography.X509Certificates.X509Certificate2]$ssl.RemoteCertificate).Subject }
    finally { $ssl.Dispose(); $tcp.Dispose() }
    if ($subject -notmatch [regex]::Escape($fqdn)) { Write-LabLog "$fqdn : certificado '$subject' (esperado CN=$fqdn). Rode /sbin/generate-certificates no host." 'WARN' }
    else { Write-LabLog "$fqdn pronto ($subject)" 'OK' }
}
exit 0

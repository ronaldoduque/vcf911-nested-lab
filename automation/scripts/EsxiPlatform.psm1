#Requires -Version 7.2
<#
    EsxiPlatform.psm1 - o lab roda em VMs do ESXi 8 físico (antes: VMware Workstation).
    Substitui vmrun/Packer/.vmx por PowerCLI (VCF.PowerCLI):
      Connect-LabEsxi, Get-LabEsxiLicense, New-LabVm, Copy-LabIso, Send-LabVmKeys (teclado via USB HID,
      como o Packer), Wait-LabVmToolsIp, Invoke-LabGuestBash, Copy-LabFileToGuest, Remove-LabVm,
      Set-LabVmAutostart, Get-LabVm.
#>
Set-StrictMode -Version Latest

function Connect-LabEsxi {
    param([Parameter(Mandatory)]$Config)
    $h = $Config.EsxiHost
    if (-not (Get-Module -ListAvailable VMware.VimAutomation.Core)) {
        throw 'PowerCLI ausente. No PowerShell 7: Install-Module VCF.PowerCLI -Scope AllUsers (o svc01/setup-svc01.sh já instala).'
    }
    Import-Module VMware.VimAutomation.Core -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -ParticipateInCEIP $false -DefaultVIServerMode Single -Scope Session -Confirm:$false | Out-Null
    $cur = Get-Variable -Name DefaultVIServer -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($cur -and $cur.IsConnected -and $cur.Name -eq $h.Address) { return $cur }
    try { Connect-VIServer -Server $h.Address -User $h.User -Password $h.Password -ErrorAction Stop -WarningAction SilentlyContinue }
    catch { throw "Não conectei no ESXi $($h.Address) como $($h.User): $($_.Exception.Message)" }
}

function Get-LabEsxiLicense {
    # Modo de avaliação (60 dias, API completa) x licença gratuita (API só leitura, máx. 8 vCPU por VM)
    $si = Get-View ServiceInstance
    $lm = Get-View $si.Content.LicenseManager
    $lic = @($lm.Licenses)[0]
    $evalHours = $null
    if ($lm.Evaluation) { $evalHours = ($lm.Evaluation.Properties | Where-Object Key -eq 'expirationHours' | Select-Object -First 1).Value }
    $isEval = ($lic.LicenseKey -eq '00000-00000-00000-00000-00000')
    $isFree = (-not $isEval) -and ($lic.Name -match 'Hypervisor|Free|Basic' -or $lic.EditionKey -match 'esxBasic')
    [pscustomobject]@{
        Name = $lic.Name; Key = $lic.LicenseKey; Edition = $lic.EditionKey
        Evaluation = $isEval; Free = $isFree
        DaysLeft = if ($isEval -and $null -ne $evalHours) { [math]::Floor([double]$evalHours / 24) } else { $null }
    }
}

function Wait-VimTask {
    param([Parameter(Mandatory)]$TaskRef, [int]$TimeoutSec = 1800)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        Start-Sleep -Seconds 2
        $t = Get-View $TaskRef
        if ($t.Info.State -eq 'success') { return $t.Info.Result }
        if ($t.Info.State -eq 'error') { throw "Tarefa do ESXi falhou: $($t.Info.Error.LocalizedMessage)" }
    } while ((Get-Date) -lt $deadline)
    throw 'Tarefa do ESXi não terminou no tempo.'
}

function Get-LabVm([string]$Name) { Get-VM -Name $Name -ErrorAction SilentlyContinue }

function Copy-LabIso {
    # Copia uma ISO local (svc01) para <datastore>/ISO se ainda não estiver lá. Retorna "[ds] ISO/arquivo.iso".
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$LocalPath)
    $dsName = $Config.EsxiHost.IsoDatastore
    $folder = $Config.EsxiHost.IsoFolder
    $name = Split-Path $LocalPath -Leaf
    $ds = Get-Datastore -Name $dsName -ErrorAction Stop
    $drive = 'labiso'
    if (-not (Get-PSDrive $drive -ErrorAction SilentlyContinue)) { New-PSDrive -Name $drive -PSProvider VimDatastore -Root '/' -Location $ds | Out-Null }
    if (-not (Test-Path "${drive}:/$folder")) { New-Item -ItemType Directory -Path "${drive}:/$folder" | Out-Null }
    $dst = "${drive}:/$folder/$name"
    $local = Get-Item $LocalPath
    $remote = Get-Item $dst -ErrorAction SilentlyContinue
    if (-not $remote -or $remote.Length -ne $local.Length) {
        Write-LabLog "Enviando $name para [$dsName] $folder/ ($([math]::Round($local.Length / 1GB, 1)) GB)..."
        Copy-DatastoreItem -Item $LocalPath -Destination "${drive}:/$folder/" -Force
    }
    "[$dsName] $folder/$name"
}

function New-LabVm {
    <#
      Cria uma VM vazia por ConfigSpec (controle total, como o .vmx do Workstation):
      -Disks      tamanhos em GB (o primeiro é o de boot), thin, todos na controladora -DiskController
      -EagerZeroDisks  índices (0 = boot) dos discos criados thick eager-zeroed em vez de thin
      -Nics       objetos {Portgroup, Mac} (Mac vazio = gerado); vmxnet3
      -IsoPath    "[ds] ISO/x.iso" numa CD-ROM SATA conectada no boot
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Datastore,
        [Parameter(Mandatory)][string]$GuestId,
        [int]$NumCpu = 2, [int]$CoresPerSocket = 0, [int]$MemoryGB = 2,
        [ValidateSet('efi', 'bios')][string]$Firmware = 'efi',
        [switch]$NestedHv,
        [ValidateSet('pvscsi', 'nvme', 'lsilogic')][string]$DiskController = 'pvscsi',
        [int[]]$Disks = @(16),
        [object[]]$Nics = @(),
        [string]$IsoPath,
        [System.Collections.IDictionary]$ExtraConfig = @{},
        [int[]]$EagerZeroDisks = @(),
        [string]$HwVersion = 'vmx-21'
    )
    $vmhost = Get-VMHost | Select-Object -First 1
    $dc = Get-Datacenter | Select-Object -First 1
    $folder = Get-View $dc.ExtensionData.VmFolder
    $pool = (Get-ResourcePool -Location $vmhost | Where-Object { $_.Name -eq 'Resources' } | Select-Object -First 1).ExtensionData.MoRef
    if (-not (Get-Datastore -Name $Datastore -ErrorAction SilentlyContinue)) { throw "Datastore $Datastore não existe no ESXi." }

    $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $spec.Name = $Name
    $spec.GuestId = $GuestId
    $spec.Version = $HwVersion
    $spec.NumCPUs = $NumCpu
    $spec.NumCoresPerSocket = $(if ($CoresPerSocket) { $CoresPerSocket } else { $NumCpu })
    $spec.MemoryMB = [long]$MemoryGB * 1024
    $spec.Firmware = $Firmware
    $spec.NestedHVEnabled = [bool]$NestedHv
    $spec.Files = New-Object VMware.Vim.VirtualMachineFileInfo
    $spec.Files.VmPathName = "[$Datastore]"
    if ($Firmware -eq 'efi') { $spec.BootOptions = New-Object VMware.Vim.VirtualMachineBootOptions; $spec.BootOptions.EfiSecureBootEnabled = $false }
    $spec.ExtraConfig = @(foreach ($k in $ExtraConfig.Keys) { $o = New-Object VMware.Vim.OptionValue; $o.Key = $k; $o.Value = [string]$ExtraConfig[$k]; $o })

    $dev = [System.Collections.Generic.List[object]]::new()
    $add = { param($d, [switch]$Create) $c = New-Object VMware.Vim.VirtualDeviceConfigSpec; $c.Operation = 'add'; if ($Create) { $c.FileOperation = 'create' }; $c.Device = $d; $dev.Add($c) }

    # controladora de disco
    $ctl = switch ($DiskController) {
        'pvscsi'   { $x = New-Object VMware.Vim.ParaVirtualSCSIController; $x.SharedBus = 'noSharing'; $x }
        'lsilogic' { $x = New-Object VMware.Vim.VirtualLsiLogicController; $x.SharedBus = 'noSharing'; $x }
        'nvme'     { New-Object VMware.Vim.VirtualNVMEController }
    }
    $ctl.Key = -100; $ctl.BusNumber = 0
    & $add $ctl
    $unit = 0
    for ($i = 0; $i -lt $Disks.Count; $i++) {
        if ($DiskController -ne 'nvme' -and $unit -eq 7) { $unit++ }
        $d = New-Object VMware.Vim.VirtualDisk
        $d.Key = -(200 + $i); $d.ControllerKey = -100; $d.UnitNumber = $unit; $unit++
        $d.CapacityInKB = [long]$Disks[$i] * 1024 * 1024
        $b = New-Object VMware.Vim.VirtualDiskFlatVer2BackingInfo
        $b.DiskMode = 'persistent'; $b.FileName = "[$Datastore]"
        # thin: aloca e zera cada bloco na primeira escrita. Eager-zeroed: já nasce alocado e zerado, sem esse custo
        if ($i -in $EagerZeroDisks) { $b.ThinProvisioned = $false; $b.EagerlyScrub = $true } else { $b.ThinProvisioned = $true }
        $d.Backing = $b
        & $add $d -Create
    }

    # CD-ROM SATA com a ISO
    if ($IsoPath) {
        $sata = New-Object VMware.Vim.VirtualAHCIController
        $sata.Key = -300; $sata.BusNumber = 0
        & $add $sata
        $cd = New-Object VMware.Vim.VirtualCdrom
        $cd.Key = -301; $cd.ControllerKey = -300; $cd.UnitNumber = 0
        $cb = New-Object VMware.Vim.VirtualCdromIsoBackingInfo; $cb.FileName = $IsoPath
        $cd.Backing = $cb
        $cd.Connectable = New-Object VMware.Vim.VirtualDeviceConnectInfo
        $cd.Connectable.StartConnected = $true; $cd.Connectable.Connected = $true; $cd.Connectable.AllowGuestControl = $true
        & $add $cd
    }

    # placas de rede
    for ($i = 0; $i -lt $Nics.Count; $i++) {
        $nic = New-Object VMware.Vim.VirtualVmxnet3
        $nic.Key = -(400 + $i)
        $nb = New-Object VMware.Vim.VirtualEthernetCardNetworkBackingInfo; $nb.DeviceName = $Nics[$i].Portgroup
        $nic.Backing = $nb
        if ($Nics[$i].Mac) { $nic.AddressType = 'manual'; $nic.MacAddress = $Nics[$i].Mac } else { $nic.AddressType = 'generated' }
        $nic.Connectable = New-Object VMware.Vim.VirtualDeviceConnectInfo
        $nic.Connectable.StartConnected = $true; $nic.Connectable.AllowGuestControl = $true
        & $add $nic
    }
    $spec.DeviceChange = $dev.ToArray()

    foreach ($pg in @($Nics | ForEach-Object Portgroup | Select-Object -Unique)) {
        if (-not (Get-VirtualPortGroup -Standard -Name $pg -ErrorAction SilentlyContinue)) { throw "Port group '$pg' não existe no ESXi (rode host/esxi-host-setup.sh rede ou a etapa 1)." }
    }
    $task = $folder.CreateVM_Task($spec, $pool, $vmhost.ExtensionData.MoRef)
    Wait-VimTask -TaskRef $task -TimeoutSec 600 | Out-Null
    Get-VM -Name $Name
}

function Remove-LabVm {
    param([Parameter(Mandatory)][string]$Name)
    $vm = Get-LabVm $Name
    if (-not $vm) { return $false }
    if ($vm.PowerState -ne 'PoweredOff') { Stop-VM -VM $vm -Confirm:$false -ErrorAction SilentlyContinue | Out-Null }
    Remove-VM -VM $vm -DeletePermanently -Confirm:$false | Out-Null
    return $true
}

function Set-LabVmAutostart {
    # liga o VM junto com o ESXi, na ordem dada (svc01=1, VyOS=2, ESX=3..)
    param([Parameter(Mandatory)]$VM, [Parameter(Mandatory)][int]$Order, [int]$DelaySec = 120)
    try {
        Get-VMHostStartPolicy -VMHost (Get-VMHost | Select-Object -First 1) | Set-VMHostStartPolicy -Enabled $true -Confirm:$false | Out-Null
        Get-VMStartPolicy -VM $VM | Set-VMStartPolicy -StartAction PowerOn -StartOrder $Order -StartDelay $DelaySec -StopAction GuestShutdown -Confirm:$false | Out-Null
    } catch { Write-LabLog "Autostart de $($VM.Name) não configurado: $($_.Exception.Message)" 'WARN' }
}

# ----------------------------------------------------------------- teclado (USB HID), como o boot_command do Packer
# dicionário com diferença de maiúsculas ('a' sem Shift, 'A' com Shift)
$script:Hid = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
for ($i = 0; $i -lt 26; $i++) {
    $script:Hid[[string][char](97 + $i)] = @{ C = 0x04 + $i; S = $false }
    $script:Hid[[string][char](65 + $i)] = @{ C = 0x04 + $i; S = $true }
}
for ($i = 1; $i -le 9; $i++) { $script:Hid["$i"] = @{ C = 0x1D + $i; S = $false } }
$script:Hid['0'] = @{ C = 0x27; S = $false }
$plain = @{ ' ' = 0x2C; '-' = 0x2D; '=' = 0x2E; '[' = 0x2F; ']' = 0x30; '\' = 0x31; ';' = 0x33; "'" = 0x34; '`' = 0x35; ',' = 0x36; '.' = 0x37; '/' = 0x38 }
foreach ($k in $plain.Keys) { $script:Hid[$k] = @{ C = $plain[$k]; S = $false } }
$shifted = @{ '!' = 0x1E; '@' = 0x1F; '#' = 0x20; '$' = 0x21; '%' = 0x22; '^' = 0x23; '&' = 0x24; '*' = 0x25; '(' = 0x26; ')' = 0x27
              '_' = 0x2D; '+' = 0x2E; '{' = 0x2F; '}' = 0x30; '|' = 0x31; ':' = 0x33; '"' = 0x34; '~' = 0x35; '<' = 0x36; '>' = 0x37; '?' = 0x38 }
foreach ($k in $shifted.Keys) { $script:Hid[$k] = @{ C = $shifted[$k]; S = $true } }
$script:HidSpecial = @{ enter = 0x28; esc = 0x29; bs = 0x2A; tab = 0x2B; spacebar = 0x2C; end = 0x4D; home = 0x4A; del = 0x4C
                        pageup = 0x4B; pagedown = 0x4E; right = 0x4F; left = 0x50; down = 0x51; up = 0x52 }
for ($i = 1; $i -le 12; $i++) { $script:HidSpecial["f$i"] = 0x39 + $i }

function Send-HidBatch($View, [object[]]$Keys) {
    if (-not $Keys.Count) { return }
    $events = foreach ($k in $Keys) {
        $ev = New-Object VMware.Vim.UsbScanCodeSpecKeyEvent
        $ev.UsbHidCode = ([int]$k.C -shl 16) -bor 7
        if ($k.S) { $m = New-Object VMware.Vim.UsbScanCodeSpecModifierType; $m.LeftShift = $true; $ev.Modifiers = $m }
        $ev
    }
    $spec = New-Object VMware.Vim.UsbScanCodeSpec
    $spec.KeyEvents = @($events)
    [void]$View.PutUsbScanCodes($spec)
    Start-Sleep -Milliseconds (40 * $Keys.Count)
}

function Send-LabVmKeys {
    <#
      Digita no console da VM usando a sintaxe do boot_command do Packer:
        texto comum, <enter> <bs> <end> <esc> <tab> <f1>..<f12> <up>..., <wait> <wait5> <wait5s>,
        <leftShiftOn> ... <leftShiftOff>
    #>
    param([Parameter(Mandatory)]$VM, [Parameter(Mandatory)][string[]]$Command)
    $view = Get-View -Id $VM.Id
    $shift = $false
    foreach ($line in $Command) {
        $batch = [System.Collections.Generic.List[object]]::new()
        foreach ($m in [regex]::Matches($line, '<[^<>]+>|.', 'Singleline')) {
            $tok = $m.Value
            if ($tok.Length -gt 1 -and $tok.StartsWith('<')) {
                $name = $tok.Trim('<', '>').ToLower()
                if ($name -match '^wait(\d*)s?$') {
                    Send-HidBatch $view $batch.ToArray(); $batch.Clear()
                    Start-Sleep -Seconds $(if ($Matches[1]) { [int]$Matches[1] } else { 1 })
                    continue
                }
                if ($name -eq 'leftshifton') { Send-HidBatch $view $batch.ToArray(); $batch.Clear(); $shift = $true; continue }
                if ($name -eq 'leftshiftoff') { Send-HidBatch $view $batch.ToArray(); $batch.Clear(); $shift = $false; continue }
                if ($script:HidSpecial.ContainsKey($name)) { $batch.Add(@{ C = $script:HidSpecial[$name]; S = $shift }); continue }
                throw "Tecla desconhecida no comando de boot: $tok"
            }
            $k = $script:Hid[$tok]
            if (-not $k) { throw "Caractere sem mapa de teclado: '$tok'" }
            $batch.Add(@{ C = $k.C; S = ($k.S -or $shift) })
            if ($batch.Count -ge 16) { Send-HidBatch $view $batch.ToArray(); $batch.Clear() }
        }
        Send-HidBatch $view $batch.ToArray()
    }
}

function Wait-LabVmToolsIp {
    # IPv4 informado pelo VMware Tools (fora da faixa do lab e de link-local)
    param([Parameter(Mandatory)][string]$Name, [string]$ExcludePrefix = '10.52.', [int]$TimeoutSec = 900)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $vm = Get-VM -Name $Name
        $ip = @($vm.Guest.IPAddress) | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' -and -not ($ExcludePrefix -and $_.StartsWith($ExcludePrefix)) } | Select-Object -First 1
        if ($ip) { return $ip }
        Start-Sleep -Seconds 15
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Invoke-LabGuestBash {
    # comando no Linux da VM pelo VMware Tools (substitui vmrun runProgramInGuest)
    param([Parameter(Mandatory)]$VM, [Parameter(Mandatory)][string]$User, [Parameter(Mandatory)][string]$Password, [Parameter(Mandatory)][string]$Script)
    $r = Invoke-VMScript -VM $VM -GuestUser $User -GuestPassword $Password -ScriptType Bash -ScriptText $Script -ErrorAction Stop -WarningAction SilentlyContinue
    if ($r.ExitCode -ne 0) { throw "Comando no convidado saiu com código $($r.ExitCode): $($r.ScriptOutput)" }
    $r.ScriptOutput
}

function Test-LabGuestFile {
    param([Parameter(Mandatory)]$VM, [string]$User, [string]$Password, [string]$Path)
    try { (Invoke-LabGuestBash -VM $VM -User $User -Password $Password -Script "test -e '$Path' && echo EXISTE || echo NAO") -match 'EXISTE' } catch { $false }
}

function Copy-LabFileToGuest {
    param([Parameter(Mandatory)]$VM, [string]$User, [string]$Password, [string]$Source, [string]$Destination)
    Copy-VMGuestFile -VM $VM -LocalToGuest -Source $Source -Destination $Destination -GuestUser $User -GuestPassword $Password -Force -ErrorAction Stop -WarningAction SilentlyContinue
}

Export-ModuleMember -Function *

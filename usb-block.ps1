$ErrorActionPreference = "Stop"

$USB_KEY = "HKLM\SYSTEM\CurrentControlSet\Control\USB"

# -------------------------------------------------------------------
# Соответствие "станок -> PCI-контроллер USB, к которому подключён ключ".
# Формат: "ИмяСтанка" = "VID:DEV"
# !!! Не включайте сюда контроллер клавиатуры/мыши (сейчас это 1022:7914) !!!
# Изменить при смене портов/плат (узнать ID: команда pci-list).
# -------------------------------------------------------------------
$MACHINES = [ordered]@{
    "A" = "1022:43BC"   # ключ A (встроенный контроллер AMD)
    "B" = "1B21:2142"   # ключ B (плата расширения ASMedia)
}

function PrintHelp {
    Write-Host ""
    Write-Host "Управление блокировкой USB"
    Write-Host ""
    Write-Host "Использование:"
Write-Host "  powershell -File usb-block.ps1 list"
    Write-Host "  powershell -File usb-block.ps1 keys"
    Write-Host "  powershell -File usb-block.ps1 key-off <серийник>"
    Write-Host "  powershell -File usb-block.ps1 key-on  <серийник>"
    Write-Host "  powershell -File usb-block.ps1 key-state"
    Write-Host "  powershell -File usb-block.ps1 pci-list"
    Write-Host "  powershell -File usb-block.ps1 pci-off 1B21:2142"
    Write-Host "  powershell -File usb-block.ps1 pci-on  1B21:2142"
    Write-Host "  powershell -File usb-block.ps1 machine A"
    Write-Host "  powershell -File usb-block.ps1 block  VID_1234 PID_5678"
    Write-Host "  powershell -File usb-block.ps1 unblock VID_1234 PID_5678"
    Write-Host "  powershell -File usb-block.ps1 status"
    Write-Host "  powershell -File usb-block.ps1 usb-off"
    Write-Host "  powershell -File usb-block.ps1 usb-on"
    Write-Host ""
    Write-Host "Команды:"
    Write-Host "  list      - показать USB-устройства, подключенные прямо сейчас"
    Write-Host "  keys      - показать USB-ключи с серийным номером и статусом"
    Write-Host "  key-off   - отключить конкретный ключ по серийнику (старый способ)"
    Write-Host "  key-on    - включить конкретный ключ по серийнику"
    Write-Host "  key-state - показать все ключи и их статус (вкл/выкл)"
    Write-Host "  pci-list  - показать PCI USB-контроллеры (встроенные и платы расширения)"
    Write-Host "  pci-off   - отключить PCI-контроллер по VID:DEV (обесточить плату с ключом)"
    Write-Host "  pci-on    - включить PCI-контроллер по VID:DEV"
    Write-Host "  machine   - выбрать станок: включить его контроллер, остальные выключить"
    Write-Host "  block     - заблокировать устройство (VID/PID)"
    Write-Host "  unblock   - разблокировать устройство (VID/PID)"
    Write-Host "  status    - показать текущие заблокированные правила"
    Write-Host "  usb-off   - отключить все USB-контроллеры и хабы"
    Write-Host "  usb-on    - включить все USB-контроллеры и хабы"
    Write-Host "  usb-state - показать состояние USB-контроллеров"
    Write-Host ""
}

function Get-PhysicallyPresentUsb {
    $ids = Get-CimInstance Win32_USBControllerDevice -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Dependent.DeviceID } |
        Where-Object { $_ -match "^USB\\VID_[0-9A-F]+&PID_[0-9A-F]+" -and $_ -notmatch "&MI_" }
    $result = @()
    foreach ($id in ($ids | Select-Object -Unique)) {
        $m = [regex]::Match($id, "(VID_[0-9A-F]+)&(PID_[0-9A-F]+)")
        if (-not $m) { continue }
        $vid = $m.Groups[1].Value
        $pidVal = $m.Groups[2].Value
        $friendly = ""
        $dev = Get-PnpDevice -InstanceId $id -ErrorAction SilentlyContinue
        if ($dev) { $friendly = $dev.FriendlyName }
        $result += [pscustomobject]@{
            VID = $vid
            PID = $pidVal
            InstanceId = $id
            FriendlyName = $friendly
        }
    }
    return $result
}

function Write-Device {
    param($device)
    if ($device.FriendlyName) {
        Write-Host ("{0,-45}  {1}&{2}" -f $device.FriendlyName, $device.VID, $device.PID)
    } else {
        Write-Host ("{0,-45}  {1}&{2}" -f $device.InstanceId, $device.VID, $device.PID)
    }
}

function ListDevices {
    Write-Host "Список USB-устройств, физически подключенных сейчас:"
    Write-Host "---------------------------------------------------"
    $devices = Get-PhysicallyPresentUsb
    if (-not $devices) {
        Write-Host "(устройств не найдено)"
        return
    }
    foreach ($d in $devices) { Write-Device $d }
    Write-Host "---------------------------------------------------"
    Write-Host "Итого устройств: $($devices.Count)"
}

function Get-KeySerial {
    param($instanceId)
    $idx = $instanceId.IndexOf("\", ($instanceId.IndexOf("\") + 1))
    if ($idx -ge 0 -and $idx -lt ($instanceId.Length - 1)) {
        return $instanceId.Substring($idx + 1)
    }
    return $instanceId
}

function Get-KeyParent {
    param($instanceId)
    try {
        $p = Get-PnpDeviceProperty -InstanceId $instanceId -ErrorAction SilentlyContinue |
            Where-Object { $_.KeyName -eq "DEVPKEY_Device_Parent" }
        if ($p) { return $p.Data }
    } catch {}
    return ""
}

function Get-KeyLocation {
    param($instanceId)
    try {
        $p = Get-PnpDeviceProperty -InstanceId $instanceId -ErrorAction SilentlyContinue |
            Where-Object { $_.KeyName -eq "DEVPKEY_Device_LocationInfo" }
        if ($p) { return $p.Data }
    } catch {}
    return ""
}

function Find-AllKeys {
    Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Present -eq $true -and (
                $_.InstanceId -match "^USB\\VID_0529&PID_0003" -or
                $_.InstanceId -match "^USB\\VID_0529&PID_0002" -or
                $_.InstanceId -match "^USB\\VID_04B9" -or
                $_.InstanceId -match "^USB\\VID_0F6F"
            )
        }
}

function Find-KeyBySerial {
    param($serial)
    Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Present -eq $true -and (
                $_.InstanceId -match "^USB\\VID_0529&PID_0003" -or
                $_.InstanceId -match "^USB\\VID_0529&PID_0002" -or
                $_.InstanceId -match "^USB\\VID_04B9" -or
                $_.InstanceId -match "^USB\\VID_0F6F"
            ) -and
            (Get-KeySerial $_.InstanceId) -ieq $serial
        } |
        Select-Object -First 1
}

function Write-Key {
    param($device)
    $serial = Get-KeySerial $device.InstanceId
    $status = "?"
    $dev = Get-PnpDevice -InstanceId $device.InstanceId -ErrorAction SilentlyContinue
    if ($dev) { $status = $dev.Status }
    $parent = Get-KeyParent $device.InstanceId
    $loc = Get-KeyLocation $device.InstanceId
    $m = [regex]::Match($device.InstanceId, "(VID_[0-9A-F]+)&(PID_[0-9A-F]+)")
    if ($m) {
        Write-Host ("[{0,-8}] {1,-35} {2}&{3}  Ключ(порт): {4}" -f $status, $device.FriendlyName, $m.Groups[1].Value, $m.Groups[2].Value, $serial)
        Write-Host ("           Порт: {0}   Контроллер: {1}" -f $loc, $parent)
    } else {
        Write-Host ("[{0,-8}] {1,-35} {2}  Ключ(порт): {3}" -f $status, $device.FriendlyName, $device.InstanceId, $serial)
        Write-Host ("           Порт: {0}   Контроллер: {1}" -f $loc, $parent)
    }
}

function ListKeys {
    Write-Host "Ключи (v3, физические узлы) — статус: OK=активен, Disabled=отключён:"
    Write-Host "--------------------------------------------------"
    $keys = @(Find-AllKeys)
    if ($keys.Count -eq 0) {
        Write-Host "(ключи не найдены — подключите USB-ключ)"
        return
    }
    foreach ($k in $keys) { Write-Key $k }
    Write-Host "--------------------------------------------------"
}

function Get-KeyHub {
    param($instanceId)
    $parent = Get-KeyParent $instanceId
    if (-not $parent) { return "" }
    $p = Get-PnpDevice -InstanceId $parent -ErrorAction SilentlyContinue
    if ($p) { return $p }
    return $null
}

function Set-KeyState {
    param([string]$cmd, [string]$serial)
    if (-not $serial) { PrintHelp; exit 1 }
    $key = Find-KeyBySerial $serial
    if (-not $key) {
        Write-Host "[ОШИБКА] Ключ с серийником '$serial' не найден."
        Write-Host "        Запустите 'keys', чтобы увидеть доступные серийники."
        exit 1
    }
    $parentId = Get-KeyParent $key.InstanceId
    $parent = Get-KeyHub $key.InstanceId
    if (-not $parent) {
        Write-Host "[ОШИБКА] Не удалось определить контроллер для ключа '$serial'."
        exit 1
    }
    $target = $parent.InstanceId
    # Проверка: не сидят ли на том же хабе мышь/клавиатура
    try {
        $siblings = Get-PnpDevice | Where-Object { (Get-KeyParent $_.InstanceId) -eq $target -and $_.Status -eq "OK" }
        $danger = $siblings | Where-Object { $_.FriendlyName -match "Мышь|Mouse|Клави|Keyboard|Touchpad" }
        if ($danger -and $cmd -eq "off") {
            Write-Host "[ВНИМАНИЕ] На этом порту находятся: $($danger.FriendlyName -join ', ')"
            Write-Host "           Отключение порта остановит их работу!"
        }
    } catch {}
    try {
        if ($cmd -eq "off") {
            Disable-PnpDevice -InstanceId $target -Confirm:$false -ErrorAction Stop
        } else {
            Enable-PnpDevice -InstanceId $target -Confirm:$false -ErrorAction Stop
        }
        $action = if ($cmd -eq "off") { "отключён (порт обесточен)" } else { "включён" }
        Write-Host "[OK] Ключ (серийник $serial) $action."
        Write-Host "     Порт: $($parent.FriendlyName) ($target)"
    } catch {
        Write-Host "[ОШИБКА] $($_.Exception.Message)"
        exit 1
    }
}

function ShowKeyState {
    Write-Host "Все ключи и их статус:"
    Write-Host "----------------------------"
    $keys = @(Find-AllKeys)
    if ($keys.Count -eq 0) {
        Write-Host "(ключи не найдены — подключите USB-ключ)"
        return
    }
    foreach ($k in $keys) { Write-Key $k }
}

function ShowKeyInfo {
    Write-Host "Детальная информация о ключах:"
    Write-Host "--------------------------------"
    $keys = @(Find-AllKeys)
    if ($keys.Count -eq 0) {
        Write-Host "(ключи не найдены — подключите USB-ключ)"
        return
    }
    foreach ($k in $keys) {
        $parent = Get-KeyParent $k.InstanceId
        $dev = Get-PnpDevice -InstanceId $k.InstanceId -ErrorAction SilentlyContinue
        Write-Host "Ключ:            $($k.FriendlyName)"
        Write-Host "  InstanceId:    $($k.InstanceId)"
        Write-Host "  Ключ(порт):    $(Get-KeySerial $k.InstanceId)"
        Write-Host "  Статус:        $($dev.Status)"
        Write-Host "  Контроллер:    $parent"
        Write-Host "  ---"
    }
}

function BlockDevice {
    param($vid, $pid)
    if (-not $vid -or -not $pid) { PrintHelp; exit 1 }
    $name = "VendorID_$vid&ProductID_$pid"
    reg add "$USB_KEY" /v "$name" /t REG_BINARY /d 0000
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Устройство $name заблокировано."
        Write-Host "     Переподключите USB-устройство или перезагрузите ПК, чтобы применить."
    } else {
        Write-Host "[ОШИБКА] Не удалось записать правило (нужны права администратора)."
        exit 1
    }
}

function UnblockDevice {
    param($vid, $pid)
    if (-not $vid -or -not $pid) { PrintHelp; exit 1 }
    $name = "VendorID_$vid&ProductID_$pid"
    reg delete "$USB_KEY" /v "$name" /f
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Устройство $name разблокировано."
        Write-Host "     Переподключите USB-устройство или перезагрузите ПК, чтобы применить."
    } else {
        Write-Host "[ОШИБКА] Правило не найдено или нет прав администратора."
        exit 1
    }
}

function ShowStatus {
    Write-Host "Текущие заблокированные правила:"
    Write-Host "----------------------------"
    $rules = reg query "$USB_KEY" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Ветка реестра не найдена или нет прав администратора."
        return
    }
    $found = $false
    foreach ($line in $rules) {
        if ($line -match "VendorID_") {
            Write-Host $line
            $found = $true
        }
    }
    if (-not $found) {
        Write-Host "(нет заблокированных правил)"
    }
}

function Get-UsbDevices {
    Get-PnpDevice -Class USB -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -match "Host Controller|Hub|корневой|контроллер|концентратор|хаб|XRCH|EHC|UHCI" -or
                       $_.InstanceId -match "ROOT_HUB|USB\\ROOT" } |
        Select-Object FriendlyName, InstanceId, Status
}

function Set-UsbState {
    param([string]$cmd)
    $devices = Get-UsbDevices
    if (-not $devices) {
        Write-Host "[ОШИБКА] USB-контроллеры не найдены (нужны права администратора?)."
        exit 1
    }
    $count = 0
    foreach ($d in $devices) {
        if ($cmd -eq "off" -and $d.Status -ne "OK") { continue }
        if ($cmd -eq "on" -and $d.Status -eq "OK") { continue }
        try {
            if ($cmd -eq "off") {
                Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop
            } else {
                Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Stop
            }
            $count++
        } catch {
            Write-Host "[ПРОПУЩЕНО] $($d.FriendlyName): $($_.Exception.Message)"
        }
    }
    if ($count -gt 0) {
        Write-Host "[OK] Отключено/включено устройств: $count"
    } else {
        Write-Host "(ничего не изменено — все устройства уже в нужном состоянии)"
    }
}

function ShowUsbState {
    Write-Host "Состояние USB-контроллеров и хабов:"
    Write-Host "----------------------------"
    $devices = Get-UsbDevices
    if (-not $devices) {
        Write-Host "(не найдено — нужны права администратора?)"
        return
    }
    $devices | ForEach-Object {
        Write-Host ("{0,-10} {1}" -f $_.Status, $_.FriendlyName)
    }
}

function Get-PciUsbControllers {
    Get-PnpDevice -Class USB -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match "^PCI\\" }
}

function ListPciControllers {
    Write-Host "PCI USB-контроллеры (ID для pci-off/pci-on = VID:DEV):"
    Write-Host "--------------------------------------------------------"
    $ctrls = @(Get-PciUsbControllers)
    if ($ctrls.Count -eq 0) {
        Write-Host "(не найдено — нужны права администратора?)"
        return
    }
    foreach ($c in $ctrls) {
        $m = [regex]::Match($c.InstanceId, "VEN_([0-9A-F]+)&DEV_([0-9A-F]+)")
        $id = if ($m.Success) { "$($m.Groups[1].Value):$($m.Groups[2].Value)" } else { "?" }
        Write-Host ("[{0,-8}] {1,-12} {2}" -f $c.Status, $id, $c.FriendlyName)
    }
    Write-Host "--------------------------------------------------------"
    Write-Host "Пример: pci-off 1B21:2142"
}

function Resolve-PciPattern {
    param($id)
    $p = $id.ToUpper().Trim()
    if ($p -match "^([0-9A-F]+):([0-9A-F]+)$") {
        return "VEN_$($matches[1])&DEV_$($matches[2])"
    }
    return $p
}

function Set-PciState {
    param([string]$cmd, [string]$id)
    if (-not $id) { PrintHelp; exit 1 }
    $pattern = Resolve-PciPattern $id
    $ctrls = @(Get-PciUsbControllers | Where-Object { $_.InstanceId.ToUpper() -like "*$pattern*" })
    if ($ctrls.Count -eq 0) {
        Write-Host "[ОШИБКА] PCI-контроллер '$id' не найден."
        Write-Host "        Запустите 'pci-list', чтобы увидеть доступные контроллеры."
        exit 1
    }
    $count = 0
    foreach ($c in $ctrls) {
        if ($cmd -eq "off" -and $c.Status -ne "OK") { continue }
        if ($cmd -eq "on" -and $c.Status -eq "OK") { continue }
        try {
            if ($cmd -eq "off") {
                Disable-PnpDevice -InstanceId $c.InstanceId -Confirm:$false -ErrorAction Stop
            } else {
                Enable-PnpDevice -InstanceId $c.InstanceId -Confirm:$false -ErrorAction Stop
            }
            $count++
        } catch {
            Write-Host "[ОШИБКА] $($c.FriendlyName): $($_.Exception.Message)"
        }
    }
    if ($count -gt 0) {
        $action = if ($cmd -eq "off") { "отключён (плата обесточена)" } else { "включён" }
        Write-Host "[OK] PCI-контроллер ${action}: $id ($count шт.)"
    }
}

function Select-Machine {
    param([string]$name)
    if (-not $name) {
        Write-Host "Использование: machine <имя станка>. Доступные: $($MACHINES.Keys -join ', ')"
        exit 1
    }
    $key = $name.ToUpper()
    if (-not $MACHINES.Contains($key)) {
        Write-Host "[ОШИБКА] Станок '$name' не задан."
        Write-Host "        Доступные: $($MACHINES.Keys -join ', ')"
        Write-Host "        Настройте соответствие в переменной MACHINES в начале скрипта."
        exit 1
    }
    Write-Host "Переключение на станок $key..."
    foreach ($m in $MACHINES.GetEnumerator()) {
        if ($m.Key -eq $key) {
            Set-PciState "on" $m.Value
        } else {
            Set-PciState "off" $m.Value
        }
    }
    Write-Host "[OK] Активен станок $key (контроллер $($MACHINES[$key]) включён, остальные выключены)."
}

# ---------------- main ----------------
$cmdArgs = $args
if ($null -eq $cmdArgs -or $cmdArgs.Count -eq 0) { PrintHelp; exit 0 }

$cmd = $cmdArgs[0]

switch ($cmd) {
    "list"     { ListDevices }
    "keys"     { ListKeys }
    "key-off"  { Set-KeyState "off" $cmdArgs[1] }
    "key-on"   { Set-KeyState "on" $cmdArgs[1] }
    "key-state"{ ShowKeyState }
    "key-info" { ShowKeyInfo }
    "pci-list" { ListPciControllers }
    "pci-off"  { Set-PciState "off" $cmdArgs[1] }
    "pci-on"   { Set-PciState "on" $cmdArgs[1] }
    "machine"  { Select-Machine $cmdArgs[1] }
    "block"    { BlockDevice $cmdArgs[1] $cmdArgs[2] }
    "unblock"  { UnblockDevice $cmdArgs[1] $cmdArgs[2] }
    "status"   { ShowStatus }
    "usb-off"  { Set-UsbState "off" }
    "usb-on"   { Set-UsbState "on" }
    "usb-state"{ ShowUsbState }
    default    { PrintHelp }
}

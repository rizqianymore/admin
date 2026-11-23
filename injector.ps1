<#
.SYNOPSIS
    UKK INJECTOR - HAFIZHUL F.A (XI RPL 05)
    Alur: Deteksi project -> Salin ke htdocs -> Import SQL -> Start Service -> Buka Browser
#>

$ErrorActionPreference = 'Stop'

# ===================== KONFIGURASI =====================
$RepoZip = 'https://github.com/USERNAME/REPO/archive/refs/heads/main.zip'
$RepoRaw = 'https://raw.githubusercontent.com/USERNAME/REPO/main'
$Xampp = 'C:\xampp'
$WebRoot = 'C:\xampp\htdocs'
$AppName = 'hafizul'
$SiteUrl = 'http://localhost/hafizul/'
$DbName = 'UKK - HAFIZHUL F.A XI RPL 05'

$ProjectFiles = @(
    'index.php', 'login.php', 'logout.php', 'pendaftar.php', 'create.php',
    'koneksi-db.php', 'sidebar-pendaftar.php', 'style.css',
    'admin/index.php', 'admin/edit.php', 'admin/update.php',
    'admin/delete.php', 'admin/sidebar-admin.php'
)

# ===================== FORMAT TAMPILAN [*][+][-] =====================
$script:Failed = $false
function Info { param($m) Write-Host "[*] $m" -ForegroundColor Cyan }
function Ok { param($m) Write-Host "[+] $m" -ForegroundColor Green }
function Bad { param($m) $script:Failed = $true; Write-Host "[-] $m" -ForegroundColor Red }
function Die { param($m) Bad $m; Read-Host 'Tekan Enter untuk keluar'; exit 1 }

function Test-Port {
    param([int]$Port)
    try { $c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $Port); $c.Close(); $true }
    catch { $false }
}

function Get-SqlNames { @('schema.sql', 'UKK - HAFIZHUL F.A XI RPL 05.sql') }

# ===================== 1. AMBIL FILE =====================
$Src = $null
foreach ($base in @($PSScriptRoot, (Get-Location).Path)) {
    if ($base -and (Test-Path (Join-Path $base 'koneksi-db.php'))) { $Src = $base; break }
}

function Get-Project {
    if ($Src) {
        Info "Sumber project lokal terdeteksi: $Src"
        return $Src
    }

    Info "Mengunduh project dari remote repository..."
    $tmp = Join-Path $env:TEMP ('ukk-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null

    try {
        Info "Mengunduh arsip ZIP..."
        Invoke-WebRequest -Uri $RepoZip -OutFile "$tmp\p.zip" -UseBasicParsing -TimeoutSec 60
        Expand-Archive -Path "$tmp\p.zip" -DestinationPath "$tmp\x" -Force
        $hit = Get-ChildItem "$tmp\x" -Filter 'koneksi-db.php' -Recurse | Select-Object -First 1
        if (-not $hit) { throw 'koneksi-db.php tidak ditemukan di dalam arsip' }
        Ok "Download ZIP berhasil"
        return $hit.Directory.FullName
    }
    catch {
        Bad "Download ZIP gagal: $($_.Exception.Message)"
    }

    try {
        Info "Mengunduh file secara individual..."
        $dest = "$tmp\files"
        foreach ($f in $ProjectFiles + (Get-SqlNames)) {
            $out = Join-Path $dest ($f -replace '/', '\')
            $dir = Split-Path $out -Parent
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Invoke-WebRequest -Uri "$RepoRaw/$([Uri]::EscapeDataString($f))" -OutFile $out -UseBasicParsing -TimeoutSec 30
            Info "Mengambil: $f"
        }
        Ok "Download seluruh file berhasil"
        return $dest
    }
    catch {
        Die "Gagal mengunduh project: $($_.Exception.Message)"
    }
}

# ===================== 2. COPY KE HTDOCS =====================
function Copy-Project {
    $dst = Join-Path $WebRoot $AppName
    Info "Menyalin file project ke $dst..."
    if (-not (Test-Path $WebRoot)) { Die "Folder htdocs tidak ditemukan di: $WebRoot" }

    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    $null = robocopy $Src $dst /E /XD '.git' /XF 'injector.ps1' /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -ge 8) { Die "Gagal menyalin file (robocopy exit: $LASTEXITCODE)" }

    if (-not (Test-Path (Join-Path $dst 'index.php'))) { Die "File index.php tidak ditemukan di $dst" }
    Ok "File project berhasil disalin ke $dst"
}

# ===================== 3. IMPORT SQL =====================
function Import-Sql {
    Info "Memeriksa database dan file SQL..."
    $mysql = Join-Path $Xampp 'mysql\bin\mysql.exe'
    if (-not (Test-Path $mysql)) { Die "mysql.exe tidak ditemukan di: $mysql" }

    $sql = $null
    foreach ($n in Get-SqlNames) {
        $c = Get-ChildItem -Path $Src -Filter $n -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { $sql = $c.FullName; break }
    }
    if (-not $sql) {
        $c = Get-ChildItem -Path $Src -Filter '*.sql' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c) { $sql = $c.FullName }
    }
    if (-not $sql) { Die "File SQL tidak ditemukan di $Src" }
    Info "Menggunakan file SQL: $sql"

    if (-not (Test-Port 3306)) {
        Start-Db
        if (-not (Test-Port 3306)) { Die "MySQL service gagal berjalan pada port 3306" }
    }

    $exists = & $mysql --user=root --batch --skip-column-names -e ("SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME = '" + ($DbName -replace "'", "''") + "'") 2>$null
    if ($exists -and ($exists -join '').Trim()) {
        Info "Database '$DbName' sudah ada, melewati proses import"
        return
    }

    Info "Mengimpor database '$DbName'..."
    cmd /c "`"$mysql`" --user=root --default-character-set=utf8mb4 < `"$sql`""
    if ($LASTEXITCODE -ne 0) { Die "Import database gagal (exit: $LASTEXITCODE)" }

    $tables = & $mysql --user=root --batch --skip-column-names -e ('SHOW TABLES FROM `' + $DbName + '`;') 2>$null
    Ok "Database berhasil diimport: $DbName"
    Ok "Tabel tersedia: $(($tables -join ', '))"
}

# ===================== 4. START APACHE & MYSQL =====================
function Start-One {
    param($Name, $Bat, $Port, $Label)

    if (Test-Port $Port) {
        Ok "$Label aktif (port $Port terbuka)"
        return
    }

    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($svc -and $svc.Status -ne 'Running') {
        try {
            Start-Service -Name $svc.Name -ErrorAction Stop
            Ok "${Label}: Service '$($svc.Name)' dijalankan"
        }
        catch {
            Info "${Label}: Service gagal start, mencoba via skrip runner..."
        }
    }

    if ((-not (Test-Port $Port)) -and (Test-Path $Bat)) {
        Start-Process -FilePath 'cmd.exe' -ArgumentList "/c `"$Bat`"" -WindowStyle Hidden
        Info "${Label}: Menjalankan $(Split-Path $Bat -Leaf)..."
    }

    for ($i = 0; $i -lt 15; $i++) {
        if (Test-Port $Port) {
            Ok "$Label aktif (port $Port)"
            return
        }
        Start-Sleep -Seconds 1
    }
    Bad "$Label gagal aktif pada port $Port"
}

function Start-Db { Start-One -Name 'mysql*' -Bat (Join-Path $Xampp 'mysql_start.bat') -Port 3306 -Label 'MySQL' }
function Start-Web {
    Start-One -Name 'Apache2.4' -Bat (Join-Path $Xampp 'apache_start.bat') -Port 80 -Label 'Apache'
    Start-One -Name 'mysql*'    -Bat (Join-Path $Xampp 'mysql_start.bat')   -Port 3306 -Label 'MySQL'
}

# ===================== 5. BUKA BROWSER =====================
function Open-Site {
    Info "Memverifikasi web server di $SiteUrl..."
    for ($i = 0; $i -lt 5; $i++) {
        try {
            $r = Invoke-WebRequest -Uri $SiteUrl -UseBasicParsing -TimeoutSec 10
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400) {
                Ok "Aplikasi merespons (HTTP $($r.StatusCode))"
                Start-Process $SiteUrl
                Ok "Browser berhasil dibuka"
                return
            }
        }
        catch { Start-Sleep -Seconds 2 }
    }
    Bad "Website belum merespons, silakan periksa Apache & folder htdocs"
}

# ===================== JALANKAN PROGRAM =====================
Info "Memeriksa konfigurasi XAMPP..."
if (-not (Test-Path "$Xampp\xampp_start.exe")) {
    $alt = Get-PSDrive -PSProvider FileSystem | ForEach-Object { Join-Path $_.Root 'xampp\xampp_start.exe' } | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($alt) {
        $Xampp = Split-Path $alt
        $WebRoot = Join-Path $Xampp 'htdocs'
        Ok "XAMPP ditemukan di: $Xampp"
    }
    else {
        Die "XAMPP tidak ditemukan di drive sistem"
    }
}

$Src = Get-Project
Copy-Project
Import-Sql
Start-Web
Open-Site

if ($script:Failed) {
    Bad "Proses selesai dengan beberapa catatan kesalahan"
}
else {
    Ok "Semua proses selesai dengan sukses"
}

Read-Host 'Tekan Enter untuk menutup'

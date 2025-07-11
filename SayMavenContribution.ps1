param (
  [Parameter()]
  [switch]
  $UninstallSpotifyStoreEdition = (Read-Host -Prompt 'Lu Kalau ada spotify versi Microsoft Store Pengen Hapus gak? (Y/N)') -eq 'y',
  [Parameter()]
  [switch]
  $UpdateSpotify
)

# Ignore errors from `Stop-Process`
$PSDefaultParameterValues['Stop-Process:ErrorAction'] = [System.Management.Automation.ActionPreference]::SilentlyContinue

[System.Version] $minimalSupportedSpotifyVersion = '1.2.8.923'

function Get-File
{
  param (
    [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [System.Uri]
    $Uri,
    [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [System.IO.FileInfo]
    $TargetFile,
    [Parameter(ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [Int32]
    $BufferSize = 1,
    [Parameter(ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [ValidateSet('KB, MB')]
    [String]
    $BufferUnit = 'MB',
    [Parameter(ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [ValidateSet('KB, MB')]
    [Int32]
    $Timeout = 10000
  )

  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

  $useBitTransfer = $null -ne (Get-Module -Name BitsTransfer -ListAvailable) -and ($PSVersionTable.PSVersion.Major -le 5) -and ((Get-Service -Name BITS).StartType -ne [System.ServiceProcess.ServiceStartMode]::Disabled)

  if ($useBitTransfer)
  {
    Write-Information -MessageData 'Menggunakan cara fallback BitTransfer sejak lu menjalankan Windows PowerShell'
    Start-BitsTransfer -Source $Uri -Destination "$($TargetFile.FullName)"
  }
  else
  {
    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.set_Timeout($Timeout) #15 second timeout
    $response = $request.GetResponse()
    $totalLength = [System.Math]::Floor($response.get_ContentLength() / 1024)
    $responseStream = $response.GetResponseStream()
    $targetStream = New-Object -TypeName ([System.IO.FileStream]) -ArgumentList "$($TargetFile.FullName)", Create
    switch ($BufferUnit)
    {
      'KB' { $BufferSize = $BufferSize * 1024 }
      'MB' { $BufferSize = $BufferSize * 1024 * 1024 }
      Default { $BufferSize = 1024 * 1024 }
    }
    Write-Verbose -Message "Buffer size: $BufferSize B ($($BufferSize/("1$BufferUnit")) $BufferUnit)"
    $buffer = New-Object byte[] $BufferSize
    $count = $responseStream.Read($buffer, 0, $buffer.length)
    $downloadedBytes = $count
    $downloadedFileName = $Uri -split '/' | Select-Object -Last 1
    while ($count -gt 0)
    {
      $targetStream.Write($buffer, 0, $count)
      $count = $responseStream.Read($buffer, 0, $buffer.length)
      $downloadedBytes = $downloadedBytes + $count
      Write-Progress -Activity "Downloading file '$downloadedFileName'" -Status "Downloaded ($([System.Math]::Floor($downloadedBytes/1024))K of $($totalLength)K): " -PercentComplete ((([System.Math]::Floor($downloadedBytes / 1024)) / $totalLength) * 100)
    }

    Write-Progress -Activity "Selesai mendownload File '$downloadedFileName'"

    $targetStream.Flush()
    $targetStream.Close()
    $targetStream.Dispose()
    $responseStream.Dispose()
  }
}

function Test-SpotifyVersion
{
  param (
    [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
    [ValidateNotNullOrEmpty()]
    [System.Version]
    $MinimalSupportedVersion,
    [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [System.Version]
    $TestedVersion
  )

  process
  {
    return ($MinimalSupportedVersion.CompareTo($TestedVersion) -le 0)
  }
}

Write-Host @'
**********************************
Authors: @Nuzair46, @KUTlime, @SayMaven, @Ka2z9h1to, @Bl0cktheSp0T
**********************************
'@

$spotifyDirectory = Join-Path -Path $env:APPDATA -ChildPath 'Spotify'
$spotifyExecutable = Join-Path -Path $spotifyDirectory -ChildPath 'Spotify.exe'
$spotifyApps = Join-Path -Path $spotifyDirectory -ChildPath 'Apps'

[System.Version] $actualSpotifyClientVersion = (Get-ChildItem -LiteralPath $spotifyExecutable -ErrorAction:SilentlyContinue).VersionInfo.ProductVersionRaw

Write-Host "Menghentikan Spotify Spotify...`n"
Stop-Process -Name Spotify
Stop-Process -Name SpotifyWebHelper

if ($PSVersionTable.PSVersion.Major -ge 7)
{
  Import-Module Appx -UseWindowsPowerShell -WarningAction:SilentlyContinue
}

if (Get-AppxPackage -Name SpotifyAB.SpotifyMusic)
{
  Write-Host "Versi Spotify yang kedetek gak support!.`n"

  if ($UninstallSpotifyStoreEdition)
  {
    Write-Host "Menghapus Spotify.`n"
    Get-AppxPackage -Name SpotifyAB.SpotifyMusic | Remove-AppxPackage
  }
  else
  {
    Read-Host "Keluar...`nTekan apa saja untuk keluar..."
    exit
  }
}

Push-Location -LiteralPath $env:TEMP
try
{
  # Unique directory name based on time
  New-Item -Type Directory -Name "BlockTheSpot-$(Get-Date -UFormat '%Y-%m-%d_%H-%M-%S')" |
  Convert-Path |
  Set-Location
}
catch
{
  Write-Output $_
  Read-Host 'Tekan key apa saja...'
  exit
}

$spotifyInstalled = Test-Path -LiteralPath $spotifyExecutable

if (-not $spotifyInstalled) {
  $unsupportedClientVersion = $true
} else {
  $unsupportedClientVersion = ($actualSpotifyClientVersion | Test-SpotifyVersion -MinimalSupportedVersion $minimalSupportedSpotifyVersion) -eq $false
}

if (-not $UpdateSpotify -and $unsupportedClientVersion)
{
  if ((Read-Host -Prompt 'Untuk menginstal BlocktheSpot, Client Spotify  lu harus diupdate, lanjutkan? (Y/N)') -ne 'y')
  {
    exit
  }
}

if (-not $spotifyInstalled -or $UpdateSpotify -or $unsupportedClientVersion)
{
  Write-Host 'Mendownload setup terbaru spotify, tunggu sebentar...'
  $spotifySetupFilePath = Join-Path -Path $PWD -ChildPath 'SpotifyFullSetup.exe'
  try
  {
    if ([Environment]::Is64BitOperatingSystem) { # Check if the computer is running a 64-bit version of Windows
      $uri = 'https://download.scdn.co/SpotifyFullSetupX64.exe'
    } else {
      $uri = 'https://download.scdn.co/SpotifyFullSetup.exe'
    }
    Get-File -Uri $uri -TargetFile "$spotifySetupFilePath"
  }
  catch
  {
    Write-Output $_
    Read-Host 'Tekan apa saja untuk keluar'
    exit
  }
  New-Item -Path $spotifyDirectory -ItemType:Directory -Force | Write-Verbose

  [System.Security.Principal.WindowsPrincipal] $principal = [System.Security.Principal.WindowsIdentity]::GetCurrent()
  $isUserAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
  Write-Host 'Running installation...'
  if ($isUserAdmin)
  {
    Write-Host
    Write-Host 'Membuat daftar task...'
    $apppath = 'powershell.exe'
    $taskname = 'Spotify install'
    $action = New-ScheduledTaskAction -Execute $apppath -Argument "-NoLogo -NoProfile -Command & `'$spotifySetupFilePath`'"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -WakeToRun
    Register-ScheduledTask -Action $action -Trigger $trigger -TaskName $taskname -Settings $settings -Force | Write-Verbose
    Write-Host 'Menginstal sedang dalam task. Memulai task...'
    Start-ScheduledTask -TaskName $taskname
    Start-Sleep -Seconds 2
    Write-Host 'Meng unregistering Task...'
    Unregister-ScheduledTask -TaskName $taskname -Confirm:$false
    Start-Sleep -Seconds 2
  }
  else
  {
    Start-Process -FilePath "$spotifySetupFilePath"
  }

  while ($null -eq (Get-Process -Name Spotify -ErrorAction SilentlyContinue))
  {
    # Waiting until installation complete
    Start-Sleep -Milliseconds 100
  }


  Write-Host 'Menghentikan Spotify...Lagi'

  Stop-Process -Name Spotify
  Stop-Process -Name SpotifyWebHelper
  if ([Environment]::Is64BitOperatingSystem) { # Check if the computer is running a 64-bit version of Windows
    Stop-Process -Name SpotifyFullSetupX64
  } else {
     Stop-Process -Name SpotifyFullSetup
  }
}

Write-Host "Mendownload patch Terbaru (chrome_elf.zip)...`n"
$elfPath = Join-Path -Path $PWD -ChildPath 'chrome_elf.zip'
try
{
  $bytes = [System.IO.File]::ReadAllBytes($spotifyExecutable)
  $peHeader = [System.BitConverter]::ToUInt16($bytes[0x3C..0x3D], 0)
  $is64Bit = $bytes[$peHeader + 4] -eq 0x64

  if ($is64Bit) {
    $uri = 'https://github.com/mrpond/BlockTheSpot/releases/latest/download/chrome_elf.zip'
  } else {
    Write-Host 'Di momen ini, adblock mungkin tidak berkerja di sistem x86 yang tidak lagi mendapat update.'
    $uri = 'https://github.com/mrpond/BlockTheSpot/releases/download/2023.5.20.80/chrome_elf.zip'
  }

  Get-File -Uri $uri -TargetFile "$elfPath"
}
catch
{
  Write-Output $_
  Start-Sleep
}

Expand-Archive -Force -LiteralPath "$elfPath" -DestinationPath $PWD
Remove-Item -LiteralPath "$elfPath" -Force

Write-Host 'Memasang Mod Spotify...'
$patchFiles = (Join-Path -Path $PWD -ChildPath 'dpapi.dll'), (Join-Path -Path $PWD -ChildPath 'config.ini')

Copy-Item -LiteralPath $patchFiles -Destination "$spotifyDirectory"
Remove-Item -LiteralPath (Join-Path -Path $spotifyDirectory -ChildPath 'blockthespot_settings.json') -Force -ErrorAction SilentlyContinue

# function Install-VcRedist {
#   $architecture = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
#   # https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist?view=msvc-170
#   $vcRedistUrl = "https://aka.ms/vs/17/release/vc_redist.$($architecture).exe"
#   $registryPath = "HKLM:\Software\Microsoft\VisualStudio\14.0\VC\Runtimes\$architecture"
#   $installedVersion = [version]((Get-ItemProperty $registryPath -ErrorAction SilentlyContinue).Version).Substring(1)
#   $latestVersion = [version]"14.40.33810.0"
# 
#   if ($installedVersion -lt $latestVersion) {
#       $vcRedistFile = Join-Path -Path $PWD -ChildPath "vc_redist.$architecture.exe"
#       Write-Host "Downloading and installing vc_redist.$architecture.exe..."
#       Get-File -Uri $vcRedistUrl -TargetFile $vcRedistFile
#       Start-Process -FilePath $vcRedistFile -ArgumentList "/install /quiet /norestart" -Wait
#   }
# }
# 
# Install-VcRedist

$tempDirectory = $PWD
Pop-Location

Remove-Item -LiteralPath $tempDirectory -Recurse

Write-Host 'Modding selesai, memulai spotify...'

Start-Process -WorkingDirectory $spotifyDirectory -FilePath $spotifyExecutable
Write-Host 'DAH KELAR BOS.'
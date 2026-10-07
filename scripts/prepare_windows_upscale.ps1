[CmdletBinding()]
param(
  [string]$Destination = 'build/upscale-runtime',
  [string]$ArchivePath
)

$ErrorActionPreference = 'Stop'
$version = '20220728'
$expectedSha256 = 'c6e08d46c11704b1e3a1ada9ddd591cb5005f52f132136c8633ba25def400e01'
$sourceUrl = "https://github.com/nihui/realcugan-ncnn-vulkan/releases/download/$version/realcugan-ncnn-vulkan-$version-windows.zip"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$buildRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build'))
$destinationPath = if ([IO.Path]::IsPathRooted($Destination)) {
  [IO.Path]::GetFullPath($Destination)
} else {
  [IO.Path]::GetFullPath((Join-Path $repoRoot $Destination))
}
$buildPrefix = $buildRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $destinationPath.StartsWith($buildPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Destination must be inside the repository build directory: $destinationPath"
}

$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$tempRoot = [IO.Path]::GetFullPath($tempRoot)
$workingDirectory = Join-Path $tempRoot "venera-realcugan-$version-$([guid]::NewGuid().ToString('N'))"
$tempPrefix = $tempRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $workingDirectory.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Temporary extraction directory is outside the temporary root: $workingDirectory"
}
New-Item -ItemType Directory -Path $workingDirectory | Out-Null

try {
  if (-not $ArchivePath) {
    $ArchivePath = Join-Path $workingDirectory "realcugan-$version.zip"
    Invoke-WebRequest -Uri $sourceUrl -OutFile $ArchivePath
  } else {
    $ArchivePath = (Resolve-Path -LiteralPath $ArchivePath).Path
  }

  $actualSha256 = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualSha256 -ne $expectedSha256) {
    throw "Real-CUGAN archive SHA-256 mismatch. Expected $expectedSha256, received $actualSha256."
  }

  $unpackDirectory = Join-Path $workingDirectory 'unpacked'
  Expand-Archive -LiteralPath $ArchivePath -DestinationPath $unpackDirectory
  $engine = Get-ChildItem -LiteralPath $unpackDirectory -Filter 'realcugan-ncnn-vulkan.exe' -File -Recurse | Select-Object -First 1
  if (-not $engine) { throw 'The Real-CUGAN archive does not contain its Windows executable.' }
  $sourceDirectory = $engine.Directory.FullName
  foreach ($requiredFile in @('vcomp140.dll', 'LICENSE')) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceDirectory $requiredFile) -PathType Leaf)) {
      throw "The Real-CUGAN archive is missing $requiredFile."
    }
  }

$modelVariants = @{
  'models-se' = @(
    'up2x-no-denoise', 'up2x-conservative', 'up2x-denoise1x', 'up2x-denoise2x', 'up2x-denoise3x',
    'up3x-no-denoise', 'up3x-conservative', 'up3x-denoise3x',
    'up4x-no-denoise', 'up4x-conservative', 'up4x-denoise3x'
  )
  'models-pro' = @(
    'up2x-no-denoise', 'up2x-conservative', 'up2x-denoise3x',
    'up3x-no-denoise', 'up3x-conservative', 'up3x-denoise3x'
  )
}
$requiredModelFiles = [System.Collections.Generic.List[string]]::new()
foreach ($modelName in $modelVariants.Keys) {
    $modelDirectory = Join-Path $sourceDirectory $modelName
    if (-not (Test-Path -LiteralPath $modelDirectory -PathType Container)) {
      throw "The Real-CUGAN archive is missing $modelName."
    }
    foreach ($variant in $modelVariants[$modelName]) {
      foreach ($extension in @('param', 'bin')) {
        $weight = "$variant.$extension"
        if (-not (Test-Path -LiteralPath (Join-Path $modelDirectory $weight) -PathType Leaf)) {
          throw "The Real-CUGAN archive is missing $modelName/$weight."
        }
        $requiredModelFiles.Add("$modelName/$weight")
      }
    }
}

  if (Test-Path -LiteralPath $destinationPath) {
    Remove-Item -LiteralPath $destinationPath -Recurse -Force
  }
  New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
  Copy-Item -LiteralPath $engine.FullName -Destination $destinationPath
  Copy-Item -LiteralPath (Join-Path $sourceDirectory 'vcomp140.dll') -Destination $destinationPath
  Copy-Item -LiteralPath (Join-Path $sourceDirectory 'LICENSE') -Destination $destinationPath
  foreach ($modelName in @('models-se', 'models-pro')) {
    Copy-Item -LiteralPath (Join-Path $sourceDirectory $modelName) -Destination $destinationPath -Recurse
  }

  $manifestJson = [ordered]@{
    version = $version
    sha256 = $expectedSha256
    source = $sourceUrl
  } | ConvertTo-Json
  [IO.File]::WriteAllText(
    (Join-Path $destinationPath 'realcugan-manifest.json'),
    $manifestJson,
    [Text.UTF8Encoding]::new($false)
  )

  $requiredFiles = @(
    'realcugan-ncnn-vulkan.exe', 'vcomp140.dll', 'LICENSE',
    'realcugan-manifest.json'
  ) + $requiredModelFiles.ToArray()
  foreach ($required in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $destinationPath $required) -PathType Leaf)) {
      throw "Staged Real-CUGAN runtime is incomplete: $required"
    }
  }
  Write-Host "Staged Real-CUGAN $version ($expectedSha256) at $destinationPath"
} finally {
  if (Test-Path -LiteralPath $workingDirectory) {
    $resolvedWorkingDirectory = [IO.Path]::GetFullPath($workingDirectory)
    if ($resolvedWorkingDirectory.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
      Remove-Item -LiteralPath $resolvedWorkingDirectory -Recurse -Force
    } else {
      Write-Warning "Skipped cleanup because the extraction directory left the temporary root: $resolvedWorkingDirectory"
    }
  }
}

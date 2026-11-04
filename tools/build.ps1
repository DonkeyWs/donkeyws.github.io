#!/usr/bin/env pwsh
#
# Build all the post articles into static html5
#
# PowerShell port of tools/build.sh
#
# Author: donkey <anjingyu_ws@foxmail.com>

$script:__VERSION__ = "0.2.1"

# Assume the terminal is a MODERN terminal
# support colorful output
$ESC = [char]27
$N = "$ESC[0m"
$BK = "$ESC[0;30m"
$R = "$ESC[0;31m"
$G = "$ESC[0;32m"
$Y = "$ESC[0;33m"
$B = "$ESC[0;34m"
$M = "$ESC[0;35m"
$C = "$ESC[0;36m"
$W = "$ESC[0;37m"

$script:DebugMode = $false

function Write-LogError
{
    param([string]$Message)
    [Console]::Error.WriteLine("[${R}E${N}] $Message")
}

function Write-LogWarning
{
    param([string]$Message)
    Write-Host "[${Y}W${N}] $Message"
}

function Write-LogInfo
{
    param([string]$Message)
    Write-Host "[${C}I${N}] $Message"
}

function Write-LogDebug
{
    param([string]$Message)
    Write-Host "[${M}D${N}] $Message"
}

$script:CUR_DIR = $PSScriptRoot
$script:PROJ_DIR = Split-Path -Parent $script:CUR_DIR
$script:MATHJAX_PATH = (Join-Path $script:CUR_DIR "mathjax/tex-mml-chtml.min.js") -replace '\\', '/'
$script:MATHJAX_FONT_DIR = Join-Path $script:CUR_DIR "mathjax/output"

function Test-CommandExists
{
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Resolve-FullPath
{
    param([string]$Path)

    if ([string]::IsNullOrEmpty($Path)) {
        return $Path
    }
    if (Test-Path -LiteralPath $Path) {
        return (Resolve-Path -LiteralPath $Path).ProviderPath
    }
    return $Path
}

function Confirm-Required
{
    if (-not (Test-CommandExists "pandoc")) {
        Write-LogError "Please install ${G}pandoc${N} first: ${Y}winget install --id JohnMacFarlane.Pandoc${N}"
        return $false
    }
    return $true
}

# Encrypt a file with AES-128-CBC
#
# $InputFile  - input file path
# $OutputFile - output file path
# $Password   - password
function Invoke-Encrypt
{
    param(
        [string]$InputFile,
        [string]$OutputFile,
        [string]$Password
    )

    if (-not (Test-CommandExists "openssl")) {
        Write-LogWarning "The command ${Y}openssl${N} is required, please install it first."
        return
    }

    & openssl enc -aes-128-cbc -pbkdf2 -in $InputFile -out $OutputFile -pass "pass:$Password"
}

# Decrypt a file with AES-128-CBC
#
# $InputFile  - encrypted file path
# $OutputFile - output file path
# $Password   - password
function Invoke-Decrypt
{
    param(
        [string]$InputFile,
        [string]$OutputFile,
        [string]$Password
    )

    if (-not (Test-CommandExists "openssl")) {
        Write-LogWarning "The command ${Y}openssl${N} is required, please install it first."
        return
    }

    & openssl enc -aes-128-cbc -pbkdf2 -d -in $InputFile -out $OutputFile -pass "pass:$Password"
}

# Extract the title from a markdown file
function Get-MarkdownTitle
{
    param([string]$Path)

    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^#\s*(.*)$') {
            return $Matches[1]
        }
    }
    return ""
}

# Extract the title from an org file
function Get-OrgTitle
{
    param([string]$Path)

    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -cmatch '^#\+title:\s*(.*)$') {
            return $Matches[1]
        }
    }
    return ""
}

# Replace all the *.md or *.org links to *.html in the generated html
function Update-HtmlLinks
{
    param([string]$HtmlFile)

    if (-not (Test-Path -LiteralPath $HtmlFile)) {
        return
    }

    $content = [IO.File]::ReadAllText($HtmlFile)
    $urls = [regex]::Matches($content, 'href="([^"]+\.(?:md|org))"')
    if ($urls.Count -eq 0) {
        return
    }

    $changed = $false
    foreach ($m in $urls) {
        $u = $m.Groups[1].Value
        if ($u -match '^https?://') {
            continue
        }

        # Use relative path in the link URL
        $p = [regex]::Replace($u, '\.(md|org)$', '.html')
        $leaf = [regex]::Match($u, '[^/]*$').Value
        if ($leaf -clike 'README*') {
            $p = [regex]::Replace($u, '[^/]*$', 'index.html')
        }

        $from = 'href="' + $u + '"'
        if ($content.Contains($from)) {
            $content = $content.Replace($from, 'href="' + $p + '"')
            $changed = $true
        }
    }

    if ($changed) {
        [IO.File]::WriteAllText($HtmlFile, $content, (New-Object System.Text.UTF8Encoding($false)))
    }
}

# Build one markdown or org file
#
# $RootInputDir  - root input directory
# $RootOutputDir - root output directory
# $InputFile     - input file
# $OutputDir     - output directory
# $ThemeDir      - theme directory
function Build-OneFile
{
    param(
        [string]$RootInputDir,
        [string]$RootOutputDir,
        [string]$InputFile,
        [string]$OutputDir,
        [string]$ThemeDir,
        [switch]$Toc
    )

    $inputFileBaseName = Split-Path -Leaf $InputFile
    $inputDir = Split-Path -Parent $InputFile

    if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $OutputDir -Force
    }

    $ext = [IO.Path]::GetExtension($inputFileBaseName).ToLowerInvariant()
    if ($ext -in @('.png', '.jpg', '.jpeg', '.svg', '.webp', '.bmp')) {
        Copy-Item -LiteralPath $InputFile -Destination (Join-Path $OutputDir $inputFileBaseName) -Force
        return
    }

    $nameWithoutExt = [IO.Path]::GetFileNameWithoutExtension($inputFileBaseName)
    $outputFile = Join-Path $OutputDir ($nameWithoutExt + '.html')

    # Tricks for README.md or README.org
    if ($nameWithoutExt -clike 'README') {
        $outputFile = Join-Path $OutputDir 'index.html'
    }

    $pandocArgs = @(
        "--resource-path=.$([IO.Path]::PathSeparator)$($script:CUR_DIR)",
        "--mathjax=$($script:MATHJAX_PATH)",
        "--to=html5"
    )

    if ($Toc) {
        $pandocArgs += @('--toc', '--toc-depth=2')
    }

    if (Test-Path -LiteralPath (Join-Path $ThemeDir 'styling.css')) {
        $pandocArgs += "--css=/static/$(Split-Path -Leaf $ThemeDir)/styling.css"
    }

    if (Test-Path -LiteralPath (Join-Path $ThemeDir 'template.html')) {
        $pandocArgs += "--template=$(Join-Path $ThemeDir 'template.html')"
    }

    if (Test-Path -LiteralPath (Join-Path $ThemeDir 'header.html')) {
        $pandocArgs += "--include-in-header=$(Join-Path $ThemeDir 'header.html')"
    }

    if (Test-Path -LiteralPath (Join-Path $ThemeDir 'navbar.html')) {
        $pandocArgs += "--include-before-body=$(Join-Path $ThemeDir 'navbar.html')"
    }

    if (Test-Path -LiteralPath (Join-Path $ThemeDir 'footer.html')) {
        $pandocArgs += "--include-after-body=$(Join-Path $ThemeDir 'footer.html')"
    }

    if (Test-Path -LiteralPath (Join-Path $ThemeDir 'metadata.yml')) {
        $pandocArgs += "--metadata-file=$(Join-Path $ThemeDir 'metadata.yml')"
    }

    Push-Location -LiteralPath $inputDir
    try {
        if ($ext -in @('.md', '.markdown')) {
            # Extract the title from file content
            $title = Get-MarkdownTitle -Path $InputFile

            if (-not [string]::IsNullOrEmpty($title)) {
                # Append title
                $pandocArgs += @('--metadata', "title=$title")
            }

            # Always use gfm
            $pandocArgs += '--from=gfm'

            $pandocCommand = @($pandocArgs) + @('-o', $outputFile, $InputFile)
            if ($script:DebugMode) {
                Write-LogDebug "pandoc $($pandocCommand -join ' ')"
            }

            & pandoc @pandocCommand 1>$null 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-LogInfo "Generated ${G}$inputFileBaseName${N}: ${C}$title${N} ..."
            }
            else {
                Write-LogError "Failed to generate ${R}$inputFileBaseName${N} ..."
            }
        }
        elseif ($ext -in @('.org')) {
            # Extract the title from file content
            $title = Get-OrgTitle -Path $InputFile

            if (-not [string]::IsNullOrEmpty($title)) {
                # Append title
                $pandocArgs += @('--metadata', "title=$title")
            }

            $pandocArgs += @('-V', "orgtitle:$title")

            $pandocCommand = @($pandocArgs) + @('-o', $outputFile, $InputFile)
            if ($script:DebugMode) {
                Write-LogDebug "pandoc $($pandocCommand -join ' ')"
            }

            & pandoc @pandocCommand 1>$null 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-LogInfo "Generated ${G}$inputFileBaseName${N}: ${C}$title${N} ..."
            }
            else {
                Write-LogError "Failed to generate ${R}$inputFileBaseName${N} ..."
            }
        }
        else {
            Write-LogWarning "Unsupported format: ${R}${ext}${N}"
            return
        }

        Update-HtmlLinks -HtmlFile $outputFile
    }
    finally {
        Pop-Location
    }
}

# Build one directory recursively and keep the hierarchy structure.
#
# $RootInputDir  - root input directory
# $RootOutputDir - root output directory
# $InputDir      - input directory
# $OutputDir     - output directory
# $ThemeDir      - theme directory
function Build-OneDir
{
    param(
        [string]$RootInputDir,
        [string]$RootOutputDir,
        [string]$InputDir,
        [string]$OutputDir,
        [string]$ThemeDir,
        [switch]$Toc
    )

    if ([string]::IsNullOrEmpty($ThemeDir)) {
        $ThemeDir = Join-Path $script:CUR_DIR 'themes/github'
    }
    elseif (-not (Test-Path -LiteralPath $ThemeDir -PathType Container)) {
        Write-LogWarning "${Y}$ThemeDir${N} is not a valid theme, use default theme ${Y}github${N}."
        $ThemeDir = Join-Path $script:CUR_DIR 'themes/github'
    }

    if (-not (Test-Path -LiteralPath $ThemeDir -PathType Container)) {
        Write-LogError "${Y}$(Split-Path -Leaf $ThemeDir)${N} is not a valid theme."
        exit 1
    }

    foreach ($fd in Get-ChildItem -LiteralPath $InputDir -Force) {
        $fpath = $fd.FullName
        if ($fd.PSIsContainer) {
            Build-OneDir -RootInputDir $RootInputDir -RootOutputDir $RootOutputDir -InputDir $fpath -OutputDir (Join-Path $OutputDir $fd.Name) -ThemeDir $ThemeDir -Toc:$Toc
        }
        else {
            Build-OneFile -RootInputDir $RootInputDir -RootOutputDir $RootOutputDir -InputFile $fpath -OutputDir $OutputDir -ThemeDir $ThemeDir -Toc:$Toc
        }
    }
}

# Publish one file
#
# $InputFile  - input file path
# $OutputFile - output file path
function Publish-OneFile
{
    param(
        [string]$InputFile,
        [string]$OutputFile
    )

    $outputDir = Split-Path -Parent $OutputFile
    if (-not (Test-Path -LiteralPath $outputDir -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $outputDir -Force
    }

    Write-LogInfo "Publishing the file: ${Y}$(Split-Path -Leaf $InputFile)${N} ..."
    Copy-Item -LiteralPath $InputFile -Destination $outputDir -Force
}

# Publish one directory recursively and keep the hierarchy structure
#
# $InputDir  - input directory
# $OutputDir - output directory
function Publish-OneDir
{
    param(
        [string]$InputDir,
        [string]$OutputDir
    )

    foreach ($fd in Get-ChildItem -LiteralPath $InputDir -Force) {
        $fpath = $fd.FullName
        if ($fd.PSIsContainer) {
            Publish-OneDir -InputDir $fpath -OutputDir (Join-Path $OutputDir $fd.Name)
        }
        else {
            Publish-OneFile -InputFile $fpath -OutputFile (Join-Path $OutputDir $fd.Name)
        }
    }
}

function Show-Help
{
    $scriptName = Split-Path -Leaf $PSCommandPath
    Write-Host "Usage: ${scriptName} [-h,--help] [-v,--version] [-i,--input DIR] [-o,--output DIR] [-t,--theme THEME]"
    Write-Host ""
    Write-Host "Build the ${G}markdown${N} or ${G}org${N} files to ${Y}html5${N} with my own style."
    Write-Host ""
    Write-Host "Options:"
    Write-Host "    ${G}-h${N},${G}--help${N}         Show help and exit"
    Write-Host "    ${G}-v${N},${G}--version${N}      Show version and exit"
    Write-Host "    ${G}-i${N},${G}--input${Y} DIR${N}    Specify a input DIR, default: `$PROJECT/notes"
    Write-Host "    ${G}-o${N},${G}--output${Y} DIR${N}   Specify the output DIR, default: `$PROJECT/docs"
    Write-Host "    ${G}-t${N},${G}--theme${Y} THEME${N}  Specify the theme, default: github"
    Write-Host "    ${G}-p${N},${G}--publish${Y} DIR${N}  Specify the publish directory"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "    # Build all the files in ${G}notes${N}, and output to the directory ${Y}docs${N}"
    Write-Host "    tools/${scriptName} -i notes -o docs"
    Write-Host ""
}

function Invoke-Main
{
    if (-not (Confirm-Required)) {
        exit 1
    }

    $articlesDir = Join-Path $script:PROJ_DIR 'notes'
    $outputDir = Join-Path $script:PROJ_DIR 'docs'
    $theme = 'github'
    $publishDir = ""
    $useToc = $false

    $i = 0
    while ($i -lt $args.Count) {
        switch ($args[$i]) {
            { $_ -in @('-i', '--input') } {
                $i++
                if ($i -lt $args.Count) { $articlesDir = Resolve-FullPath $args[$i] }
            }
            { $_ -in @('-d', '--debug') } {
                $script:DebugMode = $true
            }
            { $_ -in @('-o', '--output') } {
                $i++
                if ($i -lt $args.Count) { $outputDir = Resolve-FullPath $args[$i] }
            }
            { $_ -in @('-t', '--theme') } {
                $i++
                if ($i -lt $args.Count) { $theme = $args[$i] }
            }
            { $_ -in @('-p', '--publish') } {
                $i++
                if ($i -lt $args.Count) { $publishDir = $args[$i] }
            }
            '--toc' {
                $useToc = $true
            }
            { $_ -in @('-v', '--version') } {
                Write-Host "$script:__VERSION__"
                exit 0
            }
            { $_ -in @('-h', '--help') } {
                Show-Help
                exit 0
            }
        }
        $i++
    }

    if (-not (Test-Path -LiteralPath $articlesDir -PathType Container)) {
        Write-LogError "${Y}$articlesDir${N} is not a valid directory."
        exit 1
    }

    if (-not (Test-Path -LiteralPath $outputDir -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $outputDir -Force
    }
    $outputDir = Resolve-FullPath $outputDir

    Build-OneDir -RootInputDir $articlesDir -RootOutputDir $outputDir -InputDir $articlesDir -OutputDir $outputDir -ThemeDir (Join-Path $script:CUR_DIR "themes/$theme") -Toc:$useToc

    if (Test-Path -LiteralPath $script:MATHJAX_FONT_DIR -PathType Container) {
        Write-LogInfo "Copying the fonts required by ${G}MathJax${N} ..."
        Copy-Item -LiteralPath $script:MATHJAX_FONT_DIR -Destination $outputDir -Recurse -Force
    }

    $staticDir = Join-Path $outputDir "static/$theme"
    $stylingCss = Join-Path $script:CUR_DIR "themes/$theme/styling.css"
    if ((-not (Test-Path -LiteralPath $staticDir)) -and (Test-Path -LiteralPath $stylingCss)) {
        Write-LogInfo "Copying the style sheet required by ${G}$theme theme${N} ..."
        $null = New-Item -ItemType Directory -Path $staticDir -Force
        Copy-Item -LiteralPath $stylingCss -Destination $staticDir -Force
    }

    # Do publish if specify this argument
    if (-not [string]::IsNullOrEmpty($publishDir)) {
        Publish-OneDir -InputDir $outputDir -OutputDir $publishDir
    }
}

Invoke-Main @args

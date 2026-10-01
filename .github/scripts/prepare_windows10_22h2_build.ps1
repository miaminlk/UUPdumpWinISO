#requires -Version 7.0

[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[ValidatePattern('^19045\.[0-9]+$')]
	[string]$build_version,
	[Parameter(Mandatory)]
	[ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')]
	[string]$uup_id,
	[string]$target_directory = (Join-Path $PSScriptRoot '../../Windows10_22H2_amd64_Feature_update')
)

$ErrorActionPreference = 'Stop'
$download_file = Join-Path $target_directory 'uup_download_windows.cmd'
$download_text = Get-Content -LiteralPath $download_file -Raw -Encoding utf8
$id_pattern = '(?<=https://uupdump\.net/get\.php\?id=)[0-9a-f-]{36}'
$title_pattern = '(?m)^title[^\r\n]+'
if(([regex]::Matches($download_text, $id_pattern).Count -ne 1) -or ([regex]::Matches($download_text, $title_pattern).Count -ne 1))
{
	throw 'The download script must contain exactly one UUP ID and one title.'
}

$converter_url = 'https://git.uupdump.net/uup-dump/misc/raw/branch/master/autodl_files/converter_windows'
$converter_response = Invoke-WebRequest -Uri $converter_url -TimeoutSec 45 -MaximumRetryCount 3 -RetryIntervalSec 5
$converter_text = [string]$converter_response.Content
foreach($converter_name in @('7zr.exe', 'uup-converter-wimlib.7z'))
{
	$converter_pattern = '(?m)^https://[^\r\n]+\r?\n[ \t]+out=' + [regex]::Escape($converter_name) + '\r?\n[ \t]+checksum=sha-256=[0-9a-f]{64}[ \t]*\r?$'
	if([regex]::Matches($converter_text, $converter_pattern).Count -ne 1)
	{
		throw "The converter manifest is missing a valid URL and SHA256 for $converter_name."
	}
}

$mirror_pattern = '(?m)^https://uupdump\.net/misc/([A-Za-z0-9._-]+)\r?$'
$mirror_replacement = 'https://uupdump.net/misc/$1' + "`t" + 'https://git.uupdump.net/uup-dump/misc/raw/branch/master/$1'
$converter_text = $converter_text -replace $mirror_pattern, $mirror_replacement

$short_id = $uup_id.Substring(0, 8)
$download_text = [regex]::Replace($download_text, $id_pattern, $uup_id)
$download_text = [regex]::Replace($download_text, $title_pattern, "title ${build_version}_amd64_zh-cn_professional_${short_id} download")
$download_text = $download_text -replace '\r?\n', "`r`n"
Set-Content -LiteralPath $download_file -Value $download_text -Encoding utf8NoBOM -NoNewline
Set-Content -LiteralPath (Join-Path $target_directory 'files/converter_windows') -Value $converter_text -Encoding utf8NoBOM -NoNewline

if($env:GITHUB_ENV)
{
	Add-Content -LiteralPath $env:GITHUB_ENV -Value "Build_VERSION=$build_version" -Encoding utf8NoBOM
}

Write-Host "Prepared Windows 10 22H2 $build_version ($uup_id) with the latest converter manifest."

#requires -Version 7.0

[CmdletBinding()]
param(
	[Parameter(Mandatory)]
	[ValidatePattern('^[^/]+/[^/]+$')]
	[string]$repo_full_name,
	[Parameter(Mandatory)]
	[ValidatePattern('^19045\.[0-9]+$')]
	[string]$current_build_version,
	[switch]$force_build
)

$ErrorActionPreference = 'Stop'
$file_name = 'Windows10_22H2_amd64_Feature_update'
$search_text = 'Feature update to Windows 10, version 22H2'
$search_query = [Uri]::EscapeDataString($search_text)
$response = Invoke-RestMethod -Uri "https://api.uupdump.net/listid.php?search=$search_query" -TimeoutSec 45 -MaximumRetryCount 3 -RetryIntervalSec 5
if(($null -eq $response.response.builds) -or $response.response.error)
{
	throw "UUP dump did not return a build list: $($response.response.error)"
}

$builds = $response.response.builds
if($builds -isnot [array])
{
	$builds = @($builds.PSObject.Properties.Value)
}

$latest_build = $builds | Where-Object {
	([string]$_.arch -eq 'amd64') -and
	([string]$_.title -like "$search_text*") -and
	([string]$_.build -match '^19045\.[0-9]+$')
} | Sort-Object -Property @(
	@{ Expression = { [version]$_.build } },
	@{ Expression = { [int64]$_.created } }
) -Descending | Select-Object -First 1

if($null -eq $latest_build)
{
	throw 'UUP dump returned no Windows 10 22H2 amd64 feature update.'
}

$build_version = [string]$latest_build.build
$uup_id = [string]$latest_build.uuid
if($uup_id -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
{
	throw "UUP dump returned an invalid UUID: $uup_id"
}

if([string]::IsNullOrWhiteSpace($env:GH_TOKEN))
{
	throw 'GH_TOKEN is required to check published releases.'
}

$headers = @{
	'Accept' = 'application/vnd.github+json'
	'Authorization' = "Bearer $env:GH_TOKEN"
	'X-GitHub-Api-Version' = '2022-11-28'
}
$published_version = [version]'0.0'
$release_pattern = '^' + [regex]::Escape($file_name) + '-(?<version>19045\.[0-9]+)$'
$page = 1
do
{
	$release_page = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo_full_name/releases?per_page=100&page=$page" -Headers $headers -UserAgent 'uupdumpwiniso-update-check' -TimeoutSec 45 -MaximumRetryCount 3 -RetryIntervalSec 5
	$releases = @($release_page)
	foreach($release in $releases)
	{
		if($release.draft -or ([string]$release.tag_name -notmatch $release_pattern))
		{
			continue
		}

		$release_version = [version]$Matches['version']
		$archive_assets = @($release.assets | Where-Object { ($_.name -match '\.7z(?:\.[0-9]+)?$') -and ($_.size -gt 0) })
		if(($archive_assets.Count -gt 0) -and ($release_version -gt $published_version))
		{
			$published_version = $release_version
		}
	}

	$page++
} while($releases.Count -eq 100)

$should_build = $true
$reason = 'A newer or previously unsuccessful version needs to be built.'
if([version]$build_version -lt [version]$current_build_version)
{
	$should_build = $false
	$reason = 'The UUP dump response is older than the configured version; skipping downgrade.'
}
elseif(($published_version -ge [version]$build_version) -and (-not $force_build))
{
	$should_build = $false
	$reason = 'This version or a newer version is already published.'
}
elseif($force_build)
{
	$reason = 'A manual rebuild was requested.'
}

$result = [ordered]@{
	should_build = $should_build.ToString().ToLowerInvariant()
	build_version = $build_version
	uup_id = $uup_id
}
if($env:GITHUB_OUTPUT)
{
	foreach($output_key in $result.Keys)
	{
		Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$output_key=$($result[$output_key])" -Encoding utf8NoBOM
	}
}

Write-Host "UUP dump latest: $build_version ($uup_id)"
Write-Host "Last published: $published_version"
Write-Host $reason
if($env:GITHUB_STEP_SUMMARY)
{
	@(
		'## Windows 10 22H2 update check'
		''
		"- UUP dump latest: $build_version"
		"- Last published: $published_version"
		"- Build required: $($result.should_build)"
		"- $reason"
	) | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8NoBOM
}

[pscustomobject]$result

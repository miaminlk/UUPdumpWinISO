#requires -Version 7.0

[CmdletBinding()]
param(
	[string]$Ini_Path = 'D:\float\OneDrive\diatom\conf\const\git.ini',
	[string]$Ini_Section = 'miaminlk',
	[string]$Ini_Key = 'tokens_classic',
	[string]$Repo_Full_Name = '',
	[string]$Workflow_File = 'Windows10_22H2_amd64_Feature_update.yml',
	[string]$Workflow_Path = '.github/workflows/Windows10_22H2_amd64_Feature_update.yml',
	[string]$State_Path = '',
	[int]$Dispatch_Cooldown_Minutes = 30,
	[switch]$Force_Dispatch,
	[switch]$Dry_Run
)

$ErrorActionPreference = 'Stop'

function ini_read {
	param(
		[string]$Ini_Path,
		[string]$Section,
		[string]$Key,
		[string]$Default_Value = ''
	)

	if(-not (Test-Path -LiteralPath $Ini_Path -PathType Leaf))
	{
		throw "INI 文件不存在: $Ini_Path"
	}

	$Current_Section = ''
	foreach($Line in (Get-Content -LiteralPath $Ini_Path -ErrorAction Stop))
	{
		$Trimmed = $Line.Trim()
		if($Trimmed -eq '')
		{
			continue
		}

		if($Trimmed -match '^[;#]')
		{
			continue
		}

		if($Trimmed -match '^\[(?<Section>[^\]]+)\]$')
		{
			$Current_Section = $Matches['Section'].Trim()
			continue
		}

		if($Current_Section -ne $Section)
		{
			continue
		}

		if($Trimmed -match '^(?<Key>[^=]+?)\s*=\s*(?<Value>.*)$')
		{
			$Found_Key = $Matches['Key'].Trim()
			if($Found_Key -ne $Key)
			{
				continue
			}

			$Value = $Matches['Value'].Trim()
			if((($Value.StartsWith('"')) -and ($Value.EndsWith('"'))) -or (($Value.StartsWith("'")) -and ($Value.EndsWith("'"))))
			{
				$Value = $Value.Substring(1, $Value.Length - 2)
			}

			return $Value
		}
	}

	return $Default_Value
}

function iniread {
	param(
		[string]$Ini_Path,
		[string]$Section,
		[string]$Key,
		[string]$Default_Value = ''
	)

	return ini_read -Ini_Path $Ini_Path -Section $Section -Key $Key -Default_Value $Default_Value
}

function read_state {
	param(
		[string]$State_Path
	)

	if(-not (Test-Path -LiteralPath $State_Path -PathType Leaf))
	{
		return @{}
	}

	try {
		$Raw = Get-Content -LiteralPath $State_Path -Raw -ErrorAction Stop
		if([string]::IsNullOrWhiteSpace($Raw))
		{
			return @{}
		}

		return ($Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop)
	} catch {
		return @{}
	}
}

function write_state {
	param(
		[string]$State_Path,
		[hashtable]$State
	)

	$Parent = Split-Path -Parent $State_Path
	if(-not (Test-Path -LiteralPath $Parent -PathType Container))
	{
		$null = New-Item -Path $Parent -ItemType Directory -Force
	}

	$Json = ($State | ConvertTo-Json -Depth 20)
	Set-Content -LiteralPath $State_Path -Value $Json -Encoding UTF8
}

function parse_repo_full_name_from_git_remote {
	param(
		[string]$Repo_Root,
		[string]$Remote_Name = 'origin'
	)

	$Remote_Url = ''
	try {
		$Remote_Url = (& git -C $Repo_Root remote get-url $Remote_Name 2>$null).Trim()
	} catch {
		$Remote_Url = ''
	}

	if([string]::IsNullOrWhiteSpace($Remote_Url))
	{
		return ''
	}

	if($Remote_Url -match 'github\.com[:/](?<Owner>[^/]+)/(?<Repo>[^/\.]+)(?:\.git)?$')
	{
		return "$($Matches['Owner'])/$($Matches['Repo'])"
	}

	return ''
}

function github_api_request {
	param(
		[string]$Method,
		[string]$Uri,
		[string]$Token,
		[object]$Body = $null
	)

	$Status_Code = $null
	$Response_Headers = $null
	$Headers = @{
		'Accept' = 'application/vnd.github+json'
		'X-GitHub-Api-Version' = '2022-11-28'
		'Authorization' = "Bearer $Token"
	}

	$Params = @{
		Method = $Method
		Uri = $Uri
		Headers = $Headers
		SkipHttpErrorCheck = $true
		StatusCodeVariable = 'Status_Code'
		ResponseHeadersVariable = 'Response_Headers'
		UserAgent = 'uupdumpwiniso-trigger'
	}

	if($null -ne $Body)
	{
		$Params['Body'] = ($Body | ConvertTo-Json -Depth 20)
		$Params['ContentType'] = 'application/json'
	}

	$Data = Invoke-RestMethod @Params

	return @{
		Status_Code = [int]$Status_Code
		Headers = $Response_Headers
		Data = $Data
	}
}

function get_repo_info {
	param(
		[string]$Repo_Full_Name,
		[string]$Token
	)

	$Uri = "https://api.github.com/repos/$Repo_Full_Name"
	$Resp = github_api_request -Method 'GET' -Uri $Uri -Token $Token
	if($Resp.Status_Code -ne 200)
	{
		throw "获取仓库信息失败($($Resp.Status_Code)): $Repo_Full_Name"
	}

	return $Resp.Data
}

function get_workflow_yaml_text {
	param(
		[string]$Repo_Full_Name,
		[string]$Workflow_Path,
		[string]$Ref,
		[string]$Token
	)

	$Path_Encoded = [System.Uri]::EscapeDataString($Workflow_Path).Replace('%2F', '/')
	$Ref_Encoded = [System.Uri]::EscapeDataString($Ref)
	$Uri = "https://api.github.com/repos/$Repo_Full_Name/contents/${Path_Encoded}?ref=${Ref_Encoded}"
	$Resp = github_api_request -Method 'GET' -Uri $Uri -Token $Token
	if($Resp.Status_Code -ne 200)
	{
		throw "获取 workflow 文件失败($($Resp.Status_Code)): $Workflow_Path"
	}

	$Content = [string]$Resp.Data.content
	$Content = $Content -replace '\s', ''
	$Bytes = [System.Convert]::FromBase64String($Content)
	return [System.Text.Encoding]::UTF8.GetString($Bytes)
}

function parse_workflow_env {
	param(
		[string]$Yaml_Text,
		[string]$Workflow_File
	)

	$Build_Version = ''
	$File_Name = ''

	if($Yaml_Text -match '(?m)^\s*Build_VERSION:\s*[\x27\x22]?(?<V>[^\x27\x22\r\n]+)[\x27\x22]?\s*$')
	{
		$Build_Version = $Matches['V'].Trim()
	}

	if($Yaml_Text -match '(?m)^\s*FILE_NAME:\s*[\x27\x22]?(?<N>[^\x27\x22\r\n]+)[\x27\x22]?\s*$')
	{
		$File_Name = $Matches['N'].Trim()
	}

	if([string]::IsNullOrWhiteSpace($File_Name))
	{
		$File_Name = [System.IO.Path]::GetFileNameWithoutExtension($Workflow_File)
	}

	if([string]::IsNullOrWhiteSpace($Build_Version))
	{
		throw "无法从 workflow YAML 中解析 Build_VERSION"
	}

	return @{
		Build_Version = $Build_Version
		File_Name = $File_Name
	}
}

function get_release_by_tag {
	param(
		[string]$Repo_Full_Name,
		[string]$Tag_Name,
		[string]$Token
	)

	$Tag_Encoded = [System.Uri]::EscapeDataString($Tag_Name)
	$Uri = "https://api.github.com/repos/$Repo_Full_Name/releases/tags/$Tag_Encoded"
	$Resp = github_api_request -Method 'GET' -Uri $Uri -Token $Token

	if($Resp.Status_Code -eq 200)
	{
		return @{
			Exists = $true
			Release = $Resp.Data
		}
	}

	if($Resp.Status_Code -eq 404)
	{
		return @{
			Exists = $false
			Release = $null
		}
	}

	throw "查询 release 失败($($Resp.Status_Code)): $Tag_Name"
}

function get_workflow_runs {
	param(
		[string]$Repo_Full_Name,
		[string]$Workflow_File,
		[string]$Branch,
		[string]$Token,
		[int]$Per_Page = 20
	)

	$Workflow_Encoded = [System.Uri]::EscapeDataString($Workflow_File)
	$Branch_Encoded = [System.Uri]::EscapeDataString($Branch)
	$Uri = "https://api.github.com/repos/$Repo_Full_Name/actions/workflows/$Workflow_Encoded/runs?branch=$Branch_Encoded&per_page=$Per_Page"
	$Resp = github_api_request -Method 'GET' -Uri $Uri -Token $Token
	if($Resp.Status_Code -ne 200)
	{
		throw "获取 workflow runs 失败($($Resp.Status_Code)): $Workflow_File"
	}

	return $Resp.Data.workflow_runs
}

function select_active_run {
	param(
		[object[]]$Workflow_Runs
	)

	foreach($Run in $Workflow_Runs)
	{
		if($null -eq $Run)
		{
			continue
		}

		if($Run.status -ne 'completed')
		{
			return $Run
		}
	}

	return $null
}

function dispatch_workflow {
	param(
		[string]$Repo_Full_Name,
		[string]$Workflow_File,
		[string]$Ref,
		[string]$Token
	)

	$Workflow_Encoded = [System.Uri]::EscapeDataString($Workflow_File)
	$Uri = "https://api.github.com/repos/$Repo_Full_Name/actions/workflows/$Workflow_Encoded/dispatches"
	$Body = @{
		ref = $Ref
	}

	$Resp = github_api_request -Method 'POST' -Uri $Uri -Token $Token -Body $Body
	if($Resp.Status_Code -ne 204)
	{
		throw "触发 workflow 失败($($Resp.Status_Code)): $Workflow_File"
	}

	return $true
}

if([string]::IsNullOrWhiteSpace($State_Path))
{
	$Base_Dir = [Environment]::GetFolderPath('LocalApplicationData')
	if([string]::IsNullOrWhiteSpace($Base_Dir))
	{
		$Base_Dir = $PSScriptRoot
	}

	$State_Path = Join-Path $Base_Dir 'UUPdumpWinISO\state\Windows10_22H2_amd64_Feature_update.json'
}

$State = read_state -State_Path $State_Path

$Token = iniread $Ini_Path $Ini_Section $Ini_Key ''
if([string]::IsNullOrWhiteSpace($Token))
{
	throw "无法从 git.ini 读取 Token: [$Ini_Section] $Ini_Key"
}

if([string]::IsNullOrWhiteSpace($Repo_Full_Name))
{
	$Repo_Full_Name = parse_repo_full_name_from_git_remote -Repo_Root $PSScriptRoot
}

if([string]::IsNullOrWhiteSpace($Repo_Full_Name))
{
	throw "无法确定 GitHub 仓库。请使用 -Repo_Full_Name 'owner/repo' 指定。"
}

$Now = [DateTimeOffset]::Now

$Repo_Info = get_repo_info -Repo_Full_Name $Repo_Full_Name -Token $Token
$Default_Branch = [string]$Repo_Info.default_branch
if([string]::IsNullOrWhiteSpace($Default_Branch))
{
	$Default_Branch = 'main'
}

$Yaml_Text = get_workflow_yaml_text -Repo_Full_Name $Repo_Full_Name -Workflow_Path $Workflow_Path -Ref $Default_Branch -Token $Token
$Workflow_Env = parse_workflow_env -Yaml_Text $Yaml_Text -Workflow_File $Workflow_File
$Build_Version = $Workflow_Env.Build_Version
$File_Name = $Workflow_Env.File_Name
$Release_Tag = "$File_Name-$Build_Version"

$Runs = get_workflow_runs -Repo_Full_Name $Repo_Full_Name -Workflow_File $Workflow_File -Branch $Default_Branch -Token $Token
$Active_Run = select_active_run -Workflow_Runs $Runs
$Latest_Run = $null
if($Runs.Count -gt 0)
{
	$Latest_Run = $Runs[0]
}

$Release_Check = get_release_by_tag -Repo_Full_Name $Repo_Full_Name -Tag_Name $Release_Tag -Token $Token
$Release_Exists = [bool]$Release_Check.Exists

$State['Last_Checked_At'] = $Now.ToString('o')
$State['Repo_Full_Name'] = $Repo_Full_Name
$State['Workflow_File'] = $Workflow_File
$State['Workflow_Path'] = $Workflow_Path
$State['Default_Branch'] = $Default_Branch
$State['Target_Build_Version'] = $Build_Version
$State['Target_Release_Tag'] = $Release_Tag

Write-Host "Repo: $Repo_Full_Name"
Write-Host "Workflow: $Workflow_File ($Default_Branch)"
Write-Host "Build_VERSION: $Build_Version"
Write-Host "Release tag: $Release_Tag"

if($null -ne $Active_Run)
{
	$State['Is_Building'] = $true
	$State['Active_Run_Id'] = $Active_Run.id
	$State['Active_Run_Status'] = $Active_Run.status
	$State['Active_Run_Url'] = $Active_Run.html_url
	write_state -State_Path $State_Path -State $State

	Write-Host "状态: 正在编译中 ($($Active_Run.status))"
	Write-Host "Run: $($Active_Run.html_url)"
	exit 0
}

$State['Is_Building'] = $false
$State.Remove('Active_Run_Id')
$State.Remove('Active_Run_Status')
$State.Remove('Active_Run_Url')

if($Release_Exists -and (-not $Force_Dispatch))
{
	$Release = $Release_Check.Release
	$State['Last_Built_Version'] = $Build_Version
	$State['Last_Built_Tag'] = $Release_Tag
	$State['Last_Built_At'] = [string]$Release.published_at
	$State['Last_Built_Url'] = [string]$Release.html_url
	write_state -State_Path $State_Path -State $State

	Write-Host "状态: 已发布，无需触发编译"
	Write-Host "Release: $($Release.html_url)"
	exit 0
}

if(( -not $Force_Dispatch) -and ($Dispatch_Cooldown_Minutes -gt 0))
{
	$Last_Dispatched_Version = [string]$State['Last_Dispatched_Version']
	$Last_Dispatched_At = [string]$State['Last_Dispatched_At']

	$Skip_Cooldown = $false
	if($null -ne $Latest_Run)
	{
		$Latest_Status = [string]$Latest_Run.status
		$Latest_Conclusion = [string]$Latest_Run.conclusion
		$Latest_Created_At = $Latest_Run.created_at

		if(($Latest_Status -eq 'completed') -and ($Latest_Conclusion -in @('cancelled', 'failure', 'timed_out')))
		{
			$Dispatch_Time = [DateTimeOffset]::MinValue
			$Run_Time = [DateTimeOffset]::MinValue

			if($Latest_Created_At -is [DateTime])
			{
				$Run_Time = [DateTimeOffset]$Latest_Created_At
			}
			elseif($Latest_Created_At -is [DateTimeOffset])
			{
				$Run_Time = $Latest_Created_At
			}
			else
			{
				$null = [DateTimeOffset]::TryParse([string]$Latest_Created_At, [ref]$Run_Time)
			}

			if([DateTimeOffset]::TryParse($Last_Dispatched_At, [ref]$Dispatch_Time))
			{
				if($Run_Time -ge $Dispatch_Time)
				{
					$Skip_Cooldown = $true
				}
			}
			else
			{
				$Skip_Cooldown = $true
			}
		}
	}

	if($Skip_Cooldown)
	{
		$State['Last_Action'] = 'cooldown_skipped_due_to_previous_run_result'
		write_state -State_Path $State_Path -State $State
	}
	else
	{
	if(($Last_Dispatched_Version -eq $Build_Version) -and (-not [string]::IsNullOrWhiteSpace($Last_Dispatched_At)))
	{
		$Parsed = [DateTimeOffset]::MinValue
		if([DateTimeOffset]::TryParse($Last_Dispatched_At, [ref]$Parsed))
		{
			$Next_Time = $Parsed.AddMinutes($Dispatch_Cooldown_Minutes)
			if($Now -lt $Next_Time)
			{
				write_state -State_Path $State_Path -State $State
				Write-Host "状态: 未发布，但最近已触发过（冷却中，$Dispatch_Cooldown_Minutes 分钟）"
				exit 0
			}
		}
	}
	}
}

if($Dry_Run)
{
	$State['Last_Action'] = 'dry_run_dispatch_skipped'
	write_state -State_Path $State_Path -State $State
	Write-Host "Dry_Run: 将会触发 workflow_dispatch（但已跳过）"
	exit 0
}

dispatch_workflow -Repo_Full_Name $Repo_Full_Name -Workflow_File $Workflow_File -Ref $Default_Branch -Token $Token | Out-Null

$State['Last_Dispatched_Version'] = $Build_Version
$State['Last_Dispatched_At'] = ([DateTimeOffset]::Now).ToString('o')
$State['Last_Action'] = 'workflow_dispatched'

Write-Host "状态: 已触发远程编译"

$Dispatched_Run = $null
for($Try = 0; $Try -lt 8; $Try++)
{
	Start-Sleep -Seconds 2
	$Runs = get_workflow_runs -Repo_Full_Name $Repo_Full_Name -Workflow_File $Workflow_File -Branch $Default_Branch -Token $Token -Per_Page 5
	$Dispatched_Run = select_active_run -Workflow_Runs $Runs
	if($null -ne $Dispatched_Run)
	{
		break
	}
}

if($null -ne $Dispatched_Run)
{
	$State['Is_Building'] = $true
	$State['Active_Run_Id'] = $Dispatched_Run.id
	$State['Active_Run_Status'] = $Dispatched_Run.status
	$State['Active_Run_Url'] = $Dispatched_Run.html_url

	Write-Host "Run: $($Dispatched_Run.html_url)"
}
else
{
	Write-Host "提示: 稍后再次运行本脚本，可看到 Run 链接/编译状态"
}

write_state -State_Path $State_Path -State $State

#requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param(
	[string]$Ini_Path = 'D:\float\OneDrive\diatom\conf\const\git.ini',
	[string]$Ini_Section = 'miaminlk',
	[string]$Ini_Key = 'tokens_classic',
	[string]$Repo_Full_Name = '',
	[string]$Workflow_File = 'Windows10_22H2_amd64_Feature_update.yml',
	[string]$Branch = '',
	[int]$Keep_Last_Runs = 0,
	[switch]$Cancel_Active_Runs = $true,
	[switch]$Delete_Run_Artifacts,
	[switch]$Delete_Workflow_Runs
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
		UserAgent = 'uupdumpwiniso-clear'
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

function get_repo_default_branch {
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

	$B = [string]$Resp.Data.default_branch
	if([string]::IsNullOrWhiteSpace($B))
	{
		return 'main'
	}

	return $B
}

function get_workflow_id {
	param(
		[string]$Repo_Full_Name,
		[string]$Workflow_File,
		[string]$Token
	)

	$Workflow_Encoded = [System.Uri]::EscapeDataString($Workflow_File)
	$Uri = "https://api.github.com/repos/$Repo_Full_Name/actions/workflows/$Workflow_Encoded"
	$Resp = github_api_request -Method 'GET' -Uri $Uri -Token $Token
	if($Resp.Status_Code -ne 200)
	{
		throw "获取 workflow 失败($($Resp.Status_Code)): $Workflow_File"
	}

	return [int64]$Resp.Data.id
}

function list_workflow_runs_all {
	param(
		[string]$Repo_Full_Name,
		[int64]$Workflow_Id,
		[string]$Branch,
		[string]$Token,
		[int]$Per_Page = 100,
		[int]$Max_Pages = 10
	)

	$All = @()
	for($Page = 1; $Page -le $Max_Pages; $Page++)
	{
		$Uri = "https://api.github.com/repos/$Repo_Full_Name/actions/workflows/$Workflow_Id/runs?per_page=$Per_Page&page=$Page"
		if(-not [string]::IsNullOrWhiteSpace($Branch))
		{
			$B = [System.Uri]::EscapeDataString($Branch)
			$Uri = "$Uri&branch=$B"
		}

		$Resp = github_api_request -Method 'GET' -Uri $Uri -Token $Token
		if($Resp.Status_Code -ne 200)
		{
			throw "获取 workflow runs 失败($($Resp.Status_Code))"
		}

		$Runs = @($Resp.Data.workflow_runs)
		if($Runs.Count -eq 0)
		{
			break
		}

		$All += $Runs
		if($Runs.Count -lt $Per_Page)
		{
			break
		}
	}

	return $All
}

function cancel_run {
	param(
		[string]$Repo_Full_Name,
		[int64]$Run_Id,
		[string]$Token
	)

	$Uri = "https://api.github.com/repos/$Repo_Full_Name/actions/runs/$Run_Id/cancel"
	$Resp = github_api_request -Method 'POST' -Uri $Uri -Token $Token -Body @{}
	if(($Resp.Status_Code -ne 202) -and ($Resp.Status_Code -ne 409))
	{
		throw "取消 run 失败($($Resp.Status_Code)): $Run_Id"
	}

	return $Resp.Status_Code
}

function list_run_artifacts {
	param(
		[string]$Repo_Full_Name,
		[int64]$Run_Id,
		[string]$Token
	)

	$Uri = "https://api.github.com/repos/$Repo_Full_Name/actions/runs/$Run_Id/artifacts?per_page=100"
	$Resp = github_api_request -Method 'GET' -Uri $Uri -Token $Token
	if($Resp.Status_Code -ne 200)
	{
		throw "获取 run artifacts 失败($($Resp.Status_Code)): $Run_Id"
	}

	return @($Resp.Data.artifacts)
}

function delete_artifact {
	param(
		[string]$Repo_Full_Name,
		[int64]$Artifact_Id,
		[string]$Token
	)

	$Uri = "https://api.github.com/repos/$Repo_Full_Name/actions/artifacts/$Artifact_Id"
	$Resp = github_api_request -Method 'DELETE' -Uri $Uri -Token $Token
	if(($Resp.Status_Code -ne 204) -and ($Resp.Status_Code -ne 404))
	{
		throw "删除 artifact 失败($($Resp.Status_Code)): $Artifact_Id"
	}

	return $Resp.Status_Code
}

function delete_workflow_run {
	param(
		[string]$Repo_Full_Name,
		[int64]$Run_Id,
		[string]$Token
	)

	$Uri = "https://api.github.com/repos/$Repo_Full_Name/actions/runs/$Run_Id"
	$Resp = github_api_request -Method 'DELETE' -Uri $Uri -Token $Token
	if(($Resp.Status_Code -ne 204) -and ($Resp.Status_Code -ne 404))
	{
		throw "删除 run 失败($($Resp.Status_Code)): $Run_Id"
	}

	return $Resp.Status_Code
}

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

if([string]::IsNullOrWhiteSpace($Branch))
{
	$Branch = get_repo_default_branch -Repo_Full_Name $Repo_Full_Name -Token $Token
}

$Workflow_Id = get_workflow_id -Repo_Full_Name $Repo_Full_Name -Workflow_File $Workflow_File -Token $Token
$Runs = list_workflow_runs_all -Repo_Full_Name $Repo_Full_Name -Workflow_Id $Workflow_Id -Branch $Branch -Token $Token

Write-Host "Repo: $Repo_Full_Name"
Write-Host "Workflow: $Workflow_File (id=$Workflow_Id)"
Write-Host "Branch: $Branch"
Write-Host "Runs: $($Runs.Count)"

if($Keep_Last_Runs -lt 0)
{
	$Keep_Last_Runs = 0
}

$Sorted = $Runs | Sort-Object -Property created_at -Descending
$Skip_Ids = @{}
if($Keep_Last_Runs -gt 0)
{
	foreach($Run in ($Sorted | Select-Object -First $Keep_Last_Runs))
	{
		$Skip_Ids[[string]$Run.id] = $true
	}
}

foreach($Run in $Sorted)
{
	$Run_Id = [int64]$Run.id
	$Run_Url = [string]$Run.html_url
	$Run_Status = [string]$Run.status
	$Run_Conclusion = [string]$Run.conclusion

	if($Skip_Ids.ContainsKey([string]$Run_Id))
	{
		continue
	}

	if($Cancel_Active_Runs -and ($Run_Status -ne 'completed'))
	{
		if($PSCmdlet.ShouldProcess("run $Run_Id", "cancel ($Run_Status)"))
		{
			$Code = cancel_run -Repo_Full_Name $Repo_Full_Name -Run_Id $Run_Id -Token $Token
			Write-Host "已取消: $Run_Id ($Run_Status) code=$Code"
			Write-Host "Run: $Run_Url"
		}
	}

	if($Delete_Run_Artifacts)
	{
		if($PSCmdlet.ShouldProcess("run $Run_Id", "delete artifacts"))
		{
			$Artifacts = list_run_artifacts -Repo_Full_Name $Repo_Full_Name -Run_Id $Run_Id -Token $Token
			foreach($A in $Artifacts)
			{
				$A_Id = [int64]$A.id
				$A_Name = [string]$A.name
				$Code = delete_artifact -Repo_Full_Name $Repo_Full_Name -Artifact_Id $A_Id -Token $Token
				Write-Host "已删除 artifact: $A_Id ($A_Name) code=$Code"
			}
		}
	}

	if($Delete_Workflow_Runs)
	{
		if($PSCmdlet.ShouldProcess("run $Run_Id", "delete workflow run ($Run_Status/$Run_Conclusion)"))
		{
			$Code = delete_workflow_run -Repo_Full_Name $Repo_Full_Name -Run_Id $Run_Id -Token $Token
			Write-Host "已删除 run: $Run_Id code=$Code"
		}
	}
}

Write-Host "完成"


#requires -Version 7.0

[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = 'Stop'

Set-Location -LiteralPath $PSScriptRoot

$Ini_Path = 'D:\float\OneDrive\diatom\conf\const\git.ini'
$Ini_Section = 'miaminlk'
$Ini_Key = 'tokens_classic'

$Repo_Full_Name = ''
$Workflow_File = 'Windows10_22H2_amd64_Feature_update.yml'
$Workflow_Path = '.github/workflows/Windows10_22H2_amd64_Feature_update.yml'

$Sync_Remote_Files = $true

$Cleanup_Artifacts = $true
$Cleanup_Workflow_Runs = $true
$Cleanup_Target_Release = $true
$Cleanup_Prefix_Releases = $true
$Cleanup_Prefix_Releases_Keep_Last = 0

$Dispatch_Workflow = $true
$Dispatch_Input_Upload_Artifact = 'false'

$Pause_At_End = $true
if($env:UUPDUMPWINISO_NO_PAUSE -eq '1')
{
	$Pause_At_End = $false
}

$Open_Actions_Page = $true
$Actions_Page_Url = 'https://github.com/miaminlk/UUPdumpWinISO/actions'
if($env:UUPDUMPWINISO_NO_OPEN -eq '1')
{
	$Open_Actions_Page = $false
}

$Update_To_Latest = $true
$Uupdump_Known_Category_Url = 'https://uupdump.net/known.php?q=category:w10-22h2'
$Uupdump_Api_Base_Url = 'https://api.uupdump.net/listid.php'
$Uupdump_Search_Text = 'Feature update to Windows 10, version 22H2'
$Uupdump_Target_Arch = 'amd64'
$Uupdump_Download_Cmd_Relative_Path = 'Windows10_22H2_amd64_Feature_update\uup_download_windows.cmd'

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
		UserAgent = 'uupdumpwiniso-run'
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

function get_workflow_runs {
	param(
		[string]$Repo_Full_Name,
		[string]$Workflow_File,
		[string]$Branch,
		[string]$Token,
		[int]$Per_Page = 50
	)

	$W = [System.Uri]::EscapeDataString($Workflow_File)
	$B = [System.Uri]::EscapeDataString($Branch)
	$Uri = "https://api.github.com/repos/$Repo_Full_Name/actions/workflows/$W/runs?branch=$B&per_page=$Per_Page"
	$Resp = github_api_request -Method 'GET' -Uri $Uri -Token $Token
	if($Resp.Status_Code -ne 200)
	{
		throw "获取 workflow runs 失败($($Resp.Status_Code)): $Workflow_File"
	}

	return @($Resp.Data.workflow_runs)
}

function list_workflow_runs_all {
	param(
		[string]$Repo_Full_Name,
		[string]$Workflow_File,
		[string]$Branch,
		[string]$Token,
		[int]$Per_Page = 100,
		[int]$Max_Pages = 10
	)

	$All = @()
	for($Page = 1; $Page -le $Max_Pages; $Page++)
	{
		$W = [System.Uri]::EscapeDataString($Workflow_File)
		$B = [System.Uri]::EscapeDataString($Branch)
		$Uri = "https://api.github.com/repos/$Repo_Full_Name/actions/workflows/$W/runs?branch=$B&per_page=$Per_Page&page=$Page"
		$Resp = github_api_request -Method 'GET' -Uri $Uri -Token $Token
		if($Resp.Status_Code -ne 200)
		{
			throw "获取 workflow runs 失败($($Resp.Status_Code)): $Workflow_File"
		}

		$Items = @($Resp.Data.workflow_runs)
		if($Items.Count -eq 0)
		{
			break
		}

		$All += $Items
		if($Items.Count -lt $Per_Page)
		{
			break
		}
	}

	return $All
}

function cancel_run_best_effort {
	param(
		[string]$Repo_Full_Name,
		[int64]$Run_Id,
		[string]$Token
	)

	$Uri = "https://api.github.com/repos/$Repo_Full_Name/actions/runs/$Run_Id/cancel"
	$Resp = github_api_request -Method 'POST' -Uri $Uri -Token $Token -Body @{}
	if($Resp.Status_Code -in 202, 409)
	{
		return $true
	}

	Write-Host "WARN: 取消 run 失败($($Resp.Status_Code)): $Run_Id"
	return $false
}

function delete_run_best_effort {
	param(
		[string]$Repo_Full_Name,
		[int64]$Run_Id,
		[string]$Token
	)

	$Uri = "https://api.github.com/repos/$Repo_Full_Name/actions/runs/$Run_Id"
	$Resp = github_api_request -Method 'DELETE' -Uri $Uri -Token $Token
	if($Resp.Status_Code -in 204, 404)
	{
		return $true
	}

	Write-Host "WARN: 删除 run 失败($($Resp.Status_Code)): $Run_Id"
	return $false
}

function list_repo_artifacts {
	param(
		[string]$Repo_Full_Name,
		[string]$Token,
		[int]$Per_Page = 100,
		[int]$Max_Pages = 10
	)

	$All = @()
	for($Page = 1; $Page -le $Max_Pages; $Page++)
	{
		$Uri = "https://api.github.com/repos/$Repo_Full_Name/actions/artifacts?per_page=$Per_Page&page=$Page"
		$Resp = github_api_request -Method 'GET' -Uri $Uri -Token $Token
		if($Resp.Status_Code -ne 200)
		{
			throw "获取 artifacts 失败($($Resp.Status_Code))"
		}

		$Items = @($Resp.Data.artifacts)
		if($Items.Count -eq 0)
		{
			break
		}

		$All += $Items
		if($Items.Count -lt $Per_Page)
		{
			break
		}
	}

	return $All
}

function delete_artifact_best_effort {
	param(
		[string]$Repo_Full_Name,
		[int64]$Artifact_Id,
		[string]$Token
	)

	$Uri = "https://api.github.com/repos/$Repo_Full_Name/actions/artifacts/$Artifact_Id"
	$Resp = github_api_request -Method 'DELETE' -Uri $Uri -Token $Token
	if($Resp.Status_Code -in 204, 404)
	{
		return $true
	}

	Write-Host "WARN: 删除 artifact 失败($($Resp.Status_Code)): $Artifact_Id"
	return $false
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

function try_get_latest_uupdump_build_from_known_page {
	$Headers = @{
		'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36'
		'Accept' = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
		'Accept-Language' = 'en-US,en;q=0.9'
	}

	try {
		$Resp = Invoke-WebRequest -Uri $Uupdump_Known_Category_Url -Headers $Headers -TimeoutSec 60 -SkipHttpErrorCheck -ErrorAction Stop
	} catch {
		return $null
	}

	if(($null -eq $Resp) -or ($Resp.StatusCode -ne 200))
	{
		return $null
	}

	$Html = [string]$Resp.Content
	if([string]::IsNullOrWhiteSpace($Html))
	{
		return $null
	}

	if(($Html -match 'Just a moment') -or ($Html -match 'cf-chl'))
	{
		return $null
	}

	$Row_Pattern = '(?s)<tr>.*?<a\s+href="selectlang\.php\?id=(?<Id>[0-9a-fA-F-]{36})">\s*(?<Title>[^<]+?)\s*</a>.*?<td\s+class="collapsing">\s*(?<Arch>[^<]+?)\s*</td>.*?<td\s+class="collapsing">\s*(?<Created>[^<]+?)\s*</td>\s*</tr>'
	$Row_Matches = [regex]::Matches($Html, $Row_Pattern)
	foreach($M in $Row_Matches)
	{
		$Title = [string]$M.Groups['Title'].Value.Trim()
		$Uup_Id = [string]$M.Groups['Id'].Value.Trim().ToLowerInvariant()
		$Arch = [string]$M.Groups['Arch'].Value.Trim().ToLowerInvariant()
		$Created = [string]$M.Groups['Created'].Value.Trim()

		if($Title -notlike "$Uupdump_Search_Text*")
		{
			continue
		}

		if(($Arch -ne 'x64') -and ($Title -notmatch '\bamd64\b'))
		{
			continue
		}

		$Build_Version = ''
		if($Title -match '\((?<V>[0-9]+\.[0-9]+)\)')
		{
			$Build_Version = $Matches['V'].Trim()
		}

		if([string]::IsNullOrWhiteSpace($Build_Version) -or [string]::IsNullOrWhiteSpace($Uup_Id))
		{
			continue
		}

		return @{
			Build_Version = $Build_Version
			Uup_Id = $Uup_Id
			Title = $Title
			Created_Utc = $Created
			Source = 'known.php'
		}
	}

	return $null
}

function uupdump_api_listid_search {
	param(
		[string]$Search_Text
	)

	$Q = [System.Uri]::EscapeDataString($Search_Text)
	$Uri = "$Uupdump_Api_Base_Url?search=$Q"

	try {
		$Resp = Invoke-RestMethod -Method 'GET' -Uri $Uri -TimeoutSec 60 -ErrorAction Stop
	} catch {
		throw "请求 UUP dump API 失败: $Uri ($($_.Exception.Message))"
	}

	if(($null -eq $Resp) -or ($null -eq $Resp.response))
	{
		throw "UUP dump API 返回空响应: $Uri"
	}

	$Builds_Object = $Resp.response.builds
	if($null -eq $Builds_Object)
	{
		return @()
	}

	$Builds = @()
	foreach($Prop in $Builds_Object.PSObject.Properties)
	{
		if($null -ne $Prop.Value)
		{
			$Builds += $Prop.Value
		}
	}

	return $Builds
}

function get_latest_uupdump_build_for_w10_22h2_amd64_feature_update {
	$Known = try_get_latest_uupdump_build_from_known_page
	if($null -ne $Known)
	{
		return $Known
	}

	$Builds = uupdump_api_listid_search -Search_Text $Uupdump_Search_Text
	$Targets = @(
		$Builds | Where-Object {
			([string]$_.arch -eq $Uupdump_Target_Arch) -and
			([string]$_.title -like "$Uupdump_Search_Text*")
		}
	)

	if($Targets.Count -eq 0)
	{
		throw "无法从 UUP dump API 找到目标条目: $Uupdump_Search_Text ($Uupdump_Target_Arch)"
	}

	$Latest = $Targets | Sort-Object -Property @(
		@{ Expression = { try { [version]$_.build } catch { [version]'0.0' } } },
		@{ Expression = { try { [int64]$_.created } catch { 0 } } }
	) -Descending | Select-Object -First 1

	$Build_Version = [string]$Latest.build
	$Uup_Id = [string]$Latest.uuid
	$Created_Utc = ''

	$Created_Seconds = 0
	if([int64]::TryParse([string]$Latest.created, [ref]$Created_Seconds))
	{
		try {
			$Created_Utc = [DateTimeOffset]::FromUnixTimeSeconds($Created_Seconds).ToUniversalTime().ToString('u')
		} catch {
			$Created_Utc = ''
		}
	}

	if([string]::IsNullOrWhiteSpace($Build_Version) -or [string]::IsNullOrWhiteSpace($Uup_Id))
	{
		throw "UUP dump API 返回的目标条目缺少 build/uuid 字段"
	}

	return @{
		Build_Version = $Build_Version
		Uup_Id = $Uup_Id
		Title = [string]$Latest.title
		Created_Utc = $Created_Utc
		Source = 'api.uupdump.net'
	}
}

function update_workflow_build_version_local {
	param(
		[string]$Workflow_Local_File,
		[string]$New_Build_Version
	)

	$Text = Get-Content -LiteralPath $Workflow_Local_File -Raw -ErrorAction Stop
	$Pattern = '(?m)^(\s*Build_VERSION:\s*)[\x27\x22]?[^\x27\x22\r\n]+[\x27\x22]?\s*$'
	if(-not [regex]::IsMatch($Text, $Pattern))
	{
		throw "workflow YAML 中未找到 Build_VERSION: $Workflow_Local_File"
	}

	$Updated = ($Text -replace $Pattern, { "$($_.Groups[1].Value)'$New_Build_Version'" })
	if($Updated -ne $Text)
	{
		Set-Content -LiteralPath $Workflow_Local_File -Value $Updated -Encoding UTF8
		return $true
	}

	return $false
}

function update_uup_download_windows_cmd_local {
	param(
		[string]$Cmd_File,
		[string]$New_Build_Version,
		[string]$New_Uup_Id
	)

	$Text = Get-Content -LiteralPath $Cmd_File -Raw -ErrorAction Stop
	$Updated = $Text
	$Changed = $false

	$Short_Id = ''
	if($New_Uup_Id -match '^(?<S>[0-9a-fA-F]{8})-')
	{
		$Short_Id = $Matches['S'].ToLowerInvariant()
	}
	else
	{
		$Short_Id = ($New_Uup_Id -replace '[^0-9a-fA-F]', '').Substring(0, 8).ToLowerInvariant()
	}

	$Title_Pattern = '(?m)^title\s+[0-9]+\.[0-9]+_amd64_zh-cn_professional_[0-9a-fA-F]{8}\s+download\s*$'
	$New_Title = "title ${New_Build_Version}_amd64_zh-cn_professional_${Short_Id} download"
	if([regex]::IsMatch($Updated, $Title_Pattern))
	{
		$Temp_Text = $Updated -replace $Title_Pattern, $New_Title
		if($Temp_Text -ne $Updated)
		{
			$Updated = $Temp_Text
			$Changed = $true
		}
	}
	else
	{
		$Fallback_Title_Pattern = '(?m)^title\s+.*$'
		if([regex]::IsMatch($Updated, $Fallback_Title_Pattern))
		{
			$Temp_Text = $Updated -replace $Fallback_Title_Pattern, $New_Title
			if($Temp_Text -ne $Updated)
			{
				$Updated = $Temp_Text
				$Changed = $true
			}
		}
		else
		{
			throw "无法在下载脚本中找到 title 行: $Cmd_File"
		}
	}

	$Id_Pattern = '(?<=https://uupdump\.net/get\.php\?id=)[0-9a-fA-F-]{36}'
	if([regex]::IsMatch($Updated, $Id_Pattern))
	{
		$Temp_Text = [regex]::Replace($Updated, $Id_Pattern, $New_Uup_Id)
		if($Temp_Text -ne $Updated)
		{
			$Updated = $Temp_Text
			$Changed = $true
		}
	}
	else
	{
		throw "无法在下载脚本中找到 get.php?id=...: $Cmd_File"
	}

	if($Changed)
	{
		$Now_Utc = [DateTimeOffset]::Now.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
		$Generated_Pattern = '(?m)^:: Generated on .*$'
		if([regex]::IsMatch($Updated, $Generated_Pattern))
		{
			$Updated = $Updated -replace $Generated_Pattern, ":: Generated on $Now_Utc GMT"
		}
	}

	if($Updated -ne $Text)
	{
		Set-Content -LiteralPath $Cmd_File -Value $Updated -Encoding UTF8
		return $true
	}

	return $false
}

function normalize_text {
	param(
		[string]$Text
	)

	if($null -eq $Text)
	{
		return ''
	}

	return (($Text -replace "`r`n", "`n") -replace "`r", "`n").TrimEnd()
}

function get_remote_file {
	param(
		[string]$Repo_Full_Name,
		[string]$Remote_Path,
		[string]$Branch,
		[string]$Token
	)

	$Path_Encoded = [System.Uri]::EscapeDataString($Remote_Path).Replace('%2F', '/')
	$Ref_Encoded = [System.Uri]::EscapeDataString($Branch)
	$Uri = "https://api.github.com/repos/$Repo_Full_Name/contents/${Path_Encoded}?ref=${Ref_Encoded}"
	$Resp = github_api_request -Method 'GET' -Uri $Uri -Token $Token
	if($Resp.Status_Code -eq 404)
	{
		return @{
			Exists = $false
			Sha = ''
			Text = ''
		}
	}

	if($Resp.Status_Code -ne 200)
	{
		throw "获取远端文件失败($($Resp.Status_Code)): $Remote_Path"
	}

	$Content = [string]$Resp.Data.content
	$Content = $Content -replace '\s', ''
	$Bytes = [System.Convert]::FromBase64String($Content)
	$Text = [System.Text.Encoding]::UTF8.GetString($Bytes)

	return @{
		Exists = $true
		Sha = [string]$Resp.Data.sha
		Text = $Text
	}
}

function put_remote_file {
	param(
		[string]$Repo_Full_Name,
		[string]$Remote_Path,
		[string]$Branch,
		[string]$Token,
		[string]$Commit_Message,
		[string]$Text,
		[string]$Sha = ''
	)

	$Path_Encoded = [System.Uri]::EscapeDataString($Remote_Path).Replace('%2F', '/')
	$Uri = "https://api.github.com/repos/$Repo_Full_Name/contents/${Path_Encoded}"

	$Bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
	$Content_B64 = [System.Convert]::ToBase64String($Bytes)

	$Body = @{
		message = $Commit_Message
		content = $Content_B64
		branch = $Branch
	}

	if(-not [string]::IsNullOrWhiteSpace($Sha))
	{
		$Body['sha'] = $Sha
	}

	$Resp = github_api_request -Method 'PUT' -Uri $Uri -Token $Token -Body $Body
	if($Resp.Status_Code -in 200, 201)
	{
		return $true
	}

	throw "更新远端文件失败($($Resp.Status_Code)): $Remote_Path"
}

function ensure_remote_file_matches_local {
	param(
		[string]$Repo_Full_Name,
		[string]$Remote_Path,
		[string]$Local_File,
		[string]$Branch,
		[string]$Token,
		[string]$Commit_Message
	)

	if(-not (Test-Path -LiteralPath $Local_File -PathType Leaf))
	{
		throw "找不到本地文件: $Local_File"
	}

	$Local_Text = Get-Content -LiteralPath $Local_File -Raw -ErrorAction Stop
	$Local_Norm = normalize_text -Text $Local_Text

	$Remote = get_remote_file -Repo_Full_Name $Repo_Full_Name -Remote_Path $Remote_Path -Branch $Branch -Token $Token
	$Remote_Norm = normalize_text -Text $Remote.Text

	if($Remote.Exists -and ($Remote_Norm -eq $Local_Norm))
	{
		return $false
	}

	if($PSCmdlet.ShouldProcess("${Repo_Full_Name}:$Remote_Path", "update remote file"))
	{
		$Sha = ''
		if($Remote.Exists)
		{
			$Sha = $Remote.Sha
		}

		$null = put_remote_file -Repo_Full_Name $Repo_Full_Name -Remote_Path $Remote_Path -Branch $Branch -Token $Token -Commit_Message $Commit_Message -Text $Local_Text -Sha $Sha
		return $true
	}

	return $false
}

function delete_release_by_tag_best_effort {
	param(
		[string]$Repo_Full_Name,
		[string]$Tag_Name,
		[string]$Token
	)

	$Tag_Encoded = [System.Uri]::EscapeDataString($Tag_Name)
	$Get_Uri = "https://api.github.com/repos/$Repo_Full_Name/releases/tags/$Tag_Encoded"
	$Get = github_api_request -Method 'GET' -Uri $Get_Uri -Token $Token
	if($Get.Status_Code -eq 404)
	{
		return $true
	}

	if($Get.Status_Code -ne 200)
	{
		Write-Host "WARN: 查询 release 失败($($Get.Status_Code)): $Tag_Name"
		return $false
	}

	$Release_Id = [int64]$Get.Data.id
	$Del_Uri = "https://api.github.com/repos/$Repo_Full_Name/releases/$Release_Id"
	$Del = github_api_request -Method 'DELETE' -Uri $Del_Uri -Token $Token
	if($Del.Status_Code -in 204, 404)
	{
		return $true
	}

	Write-Host "WARN: 删除 release 失败($($Del.Status_Code)): $Tag_Name"
	return $false
}

function list_repo_releases_all {
	param(
		[string]$Repo_Full_Name,
		[string]$Token,
		[int]$Per_Page = 100,
		[int]$Max_Pages = 10
	)

	$All = @()
	for($Page = 1; $Page -le $Max_Pages; $Page++)
	{
		$Uri = "https://api.github.com/repos/$Repo_Full_Name/releases?per_page=$Per_Page&page=$Page"
		$Resp = github_api_request -Method 'GET' -Uri $Uri -Token $Token
		if($Resp.Status_Code -ne 200)
		{
			throw "获取 releases 失败($($Resp.Status_Code)): $Repo_Full_Name"
		}

		$Items = @($Resp.Data)
		if($Items.Count -eq 0)
		{
			break
		}

		$All += $Items
		if($Items.Count -lt $Per_Page)
		{
			break
		}
	}

	return $All
}

function delete_release_by_id_best_effort {
	param(
		[string]$Repo_Full_Name,
		[int64]$Release_Id,
		[string]$Token
	)

	$Uri = "https://api.github.com/repos/$Repo_Full_Name/releases/$Release_Id"
	$Del = github_api_request -Method 'DELETE' -Uri $Uri -Token $Token
	if($Del.Status_Code -in 204, 404)
	{
		return $true
	}

	Write-Host "WARN: 删除 release 失败($($Del.Status_Code)): id=$Release_Id"
	return $false
}

function delete_git_tag_best_effort {
	param(
		[string]$Repo_Full_Name,
		[string]$Tag_Name,
		[string]$Token
	)

	$Ref = "tags/$Tag_Name"
	$Ref_Encoded = [System.Uri]::EscapeDataString($Ref).Replace('%2F', '/')
	$Uri = "https://api.github.com/repos/$Repo_Full_Name/git/refs/$Ref_Encoded"
	$Resp = github_api_request -Method 'DELETE' -Uri $Uri -Token $Token
	if($Resp.Status_Code -in 204, 404)
	{
		return $true
	}

	if($Resp.Status_Code -eq 422)
	{
		$Message = ''
		if($null -ne $Resp.Data)
		{
			$Message = [string]$Resp.Data.message
		}

		if($Message -eq 'Reference does not exist')
		{
			return $true
		}
	}

	Write-Host "WARN: 删除 tag 失败($($Resp.Status_Code)): $Tag_Name"
	return $false
}

function dispatch_workflow {
	param(
		[string]$Repo_Full_Name,
		[string]$Workflow_File,
		[string]$Ref,
		[string]$Token,
		[hashtable]$Inputs = $null
	)

	$W = [System.Uri]::EscapeDataString($Workflow_File)
	$Uri = "https://api.github.com/repos/$Repo_Full_Name/actions/workflows/$W/dispatches"

	$Body = @{
		ref = $Ref
	}

	if($null -ne $Inputs)
	{
		$Body['inputs'] = $Inputs
	}

	$Resp = github_api_request -Method 'POST' -Uri $Uri -Token $Token -Body $Body
	if($Resp.Status_Code -ne 204)
	{
		throw "触发 workflow 失败($($Resp.Status_Code)): $Workflow_File"
	}
}

try {
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
	$Repo_Full_Name = 'miaminlk/UUPdumpWinISO'
}

$Default_Branch = get_repo_default_branch -Repo_Full_Name $Repo_Full_Name -Token $Token

$Workflow_Local_File = Join-Path $PSScriptRoot $Workflow_Path
if(-not (Test-Path -LiteralPath $Workflow_Local_File -PathType Leaf))
{
	throw "找不到本地 workflow 文件: $Workflow_Local_File"
}

$Workflow_Text = Get-Content -LiteralPath $Workflow_Local_File -Raw -ErrorAction Stop
$Workflow_Env = parse_workflow_env -Yaml_Text $Workflow_Text -Workflow_File $Workflow_File
$Current_Build_Version = $Workflow_Env.Build_Version
$File_Name = $Workflow_Env.File_Name

if($Update_To_Latest)
{
	$Latest = get_latest_uupdump_build_for_w10_22h2_amd64_feature_update
	$Latest_Build_Version = [string]$Latest.Build_Version
	$Latest_Uup_Id = [string]$Latest.Uup_Id

	if(-not [string]::IsNullOrWhiteSpace([string]$Latest.Source))
	{
		Write-Host "UUP dump 来源: $($Latest.Source)"
	}

	Write-Host "UUP dump 最新: $($Latest.Title)"
	if(-not [string]::IsNullOrWhiteSpace([string]$Latest.Created_Utc))
	{
		Write-Host "UUP dump 时间(UTC): $($Latest.Created_Utc)"
	}

	if($Current_Build_Version -ne $Latest_Build_Version)
	{
		if($PSCmdlet.ShouldProcess($Workflow_Local_File, "update Build_VERSION -> $Latest_Build_Version"))
		{
			$Is_Updated = update_workflow_build_version_local -Workflow_Local_File $Workflow_Local_File -New_Build_Version $Latest_Build_Version
			if($Is_Updated)
			{
				Write-Host "已更新本地 workflow Build_VERSION: $Current_Build_Version -> $Latest_Build_Version"
			}
		}
	}

	$Download_Cmd = Join-Path $PSScriptRoot $Uupdump_Download_Cmd_Relative_Path
	if(-not (Test-Path -LiteralPath $Download_Cmd -PathType Leaf))
	{
		throw "找不到下载脚本: $Download_Cmd"
	}

	if($PSCmdlet.ShouldProcess($Download_Cmd, "update uupdump id -> $Latest_Uup_Id"))
	{
		$Is_Updated = update_uup_download_windows_cmd_local -Cmd_File $Download_Cmd -New_Build_Version $Latest_Build_Version -New_Uup_Id $Latest_Uup_Id
		if($Is_Updated)
		{
			Write-Host "已更新本地下载脚本: $Download_Cmd"
		}
		else
		{
			Write-Host "本地下载脚本已是最新: $Download_Cmd"
		}
	}

	$Workflow_Text = Get-Content -LiteralPath $Workflow_Local_File -Raw -ErrorAction Stop
	$Workflow_Env = parse_workflow_env -Yaml_Text $Workflow_Text -Workflow_File $Workflow_File
}

$Build_Version = $Workflow_Env.Build_Version
$Release_Tag = "$File_Name-$Build_Version"
$Name_Prefix = "$File_Name-"

Write-Host "Repo: $Repo_Full_Name"
Write-Host "Branch: $Default_Branch"
Write-Host "Workflow: $Workflow_File"
Write-Host "Build_VERSION: $Build_Version"
Write-Host "Release tag: $Release_Tag"

if($Sync_Remote_Files)
{
	$Remote_Workflow_Ready = $false
	try {
		$null = ensure_remote_file_matches_local -Repo_Full_Name $Repo_Full_Name -Remote_Path $Workflow_Path -Local_File $Workflow_Local_File -Branch $Default_Branch -Token $Token -Commit_Message "Update workflow: $Workflow_File"

		$Convert_Local_File = Join-Path $PSScriptRoot 'Windows10_22H2_amd64_Feature_update\ConvertConfig.ini'
		$null = ensure_remote_file_matches_local -Repo_Full_Name $Repo_Full_Name -Remote_Path 'Windows10_22H2_amd64_Feature_update/ConvertConfig.ini' -Local_File $Convert_Local_File -Branch $Default_Branch -Token $Token -Commit_Message "Update ConvertConfig.ini (Windows10_22H2_amd64_Feature_update)"

		$Download_Local_File = Join-Path $PSScriptRoot 'Windows10_22H2_amd64_Feature_update\uup_download_windows.cmd'
		$null = ensure_remote_file_matches_local -Repo_Full_Name $Repo_Full_Name -Remote_Path 'Windows10_22H2_amd64_Feature_update/uup_download_windows.cmd' -Local_File $Download_Local_File -Branch $Default_Branch -Token $Token -Commit_Message "Update uup_download_windows.cmd (Windows10_22H2_amd64_Feature_update)"

		$Remote_Workflow = get_remote_file -Repo_Full_Name $Repo_Full_Name -Remote_Path $Workflow_Path -Branch $Default_Branch -Token $Token
		$Remote_Workflow_Ready = (normalize_text -Text $Remote_Workflow.Text) -eq (normalize_text -Text $Workflow_Text)
	} catch {
		Write-Host "WARN: 同步远端文件失败：$($_.Exception.Message)"
		$Remote_Workflow_Ready = $false
	}

	if(-not $Remote_Workflow_Ready)
	{
		Write-Host "ERROR: 远端 workflow 未同步到最新版本，已停止触发。请先检查 Token 权限或手动推送: $Workflow_Path"
		$Dispatch_Workflow = $false
	}
}

if($Cleanup_Workflow_Runs)
{
	$Runs = list_workflow_runs_all -Repo_Full_Name $Repo_Full_Name -Workflow_File $Workflow_File -Branch $Default_Branch -Token $Token -Per_Page 100 -Max_Pages 10
	foreach($Run in $Runs)
	{
		if($Run.status -ne 'completed')
		{
			$Run_Id = [int64]$Run.id
			if($PSCmdlet.ShouldProcess("run $Run_Id", "cancel ($($Run.status))"))
			{
				Write-Host "取消 run: $Run_Id ($($Run.status))"
				$null = cancel_run_best_effort -Repo_Full_Name $Repo_Full_Name -Run_Id $Run_Id -Token $Token
			}
		}
	}
}

if($Cleanup_Artifacts)
{
	$Artifacts = list_repo_artifacts -Repo_Full_Name $Repo_Full_Name -Token $Token
	$Targets = @($Artifacts | Where-Object { $_.name -like "$Name_Prefix*" })
	foreach($A in $Targets)
	{
		$A_Id = [int64]$A.id
		if($PSCmdlet.ShouldProcess("artifact $A_Id", "delete ($($A.name))"))
		{
			Write-Host "删除 artifact: $A_Id ($($A.name))"
			$null = delete_artifact_best_effort -Repo_Full_Name $Repo_Full_Name -Artifact_Id $A_Id -Token $Token
		}
	}
}

if($Cleanup_Prefix_Releases)
{
	$All_Releases = @()
	try {
		$All_Releases = list_repo_releases_all -Repo_Full_Name $Repo_Full_Name -Token $Token -Per_Page 100 -Max_Pages 10
	} catch {
		Write-Host "WARN: 获取 releases 失败：$($_.Exception.Message)"
		$All_Releases = @()
	}

	$Prefix_Releases = @($All_Releases | Where-Object { [string]$_.tag_name -like "$Name_Prefix*" })
	$To_Delete = $Prefix_Releases

	if($Cleanup_Prefix_Releases_Keep_Last -lt 0)
	{
		$Cleanup_Prefix_Releases_Keep_Last = 0
	}

	if(($Cleanup_Prefix_Releases_Keep_Last -gt 0) -and ($Prefix_Releases.Count -gt 0))
	{
		$Sorted = $Prefix_Releases | Sort-Object -Property @(
			@{ Expression = { [string]$_.published_at } },
			@{ Expression = { [string]$_.created_at } }
		) -Descending
		$To_Delete = @($Sorted | Select-Object -Skip $Cleanup_Prefix_Releases_Keep_Last)
	}

	if($Prefix_Releases.Count -gt 0)
	{
		Write-Host "匹配 releases: $($Prefix_Releases.Count) (prefix: $Name_Prefix)"
	}

	foreach($R in $To_Delete)
	{
		$Tag = [string]$R.tag_name
		$Release_Id = [int64]$R.id
		if($PSCmdlet.ShouldProcess("release $Release_Id ($Tag)", "delete"))
		{
			Write-Host "删除 release: $Release_Id ($Tag)"
			$null = delete_release_by_id_best_effort -Repo_Full_Name $Repo_Full_Name -Release_Id $Release_Id -Token $Token
		}

		if($PSCmdlet.ShouldProcess("tag $Tag", "delete"))
		{
			Write-Host "删除 tag: $Tag"
			$null = delete_git_tag_best_effort -Repo_Full_Name $Repo_Full_Name -Tag_Name $Tag -Token $Token
		}
	}
}

if($Cleanup_Target_Release)
{
	if($PSCmdlet.ShouldProcess("release/tag $Release_Tag", "delete"))
	{
		Write-Host "删除 release/tag: $Release_Tag"
		$null = delete_release_by_tag_best_effort -Repo_Full_Name $Repo_Full_Name -Tag_Name $Release_Tag -Token $Token
		$null = delete_git_tag_best_effort -Repo_Full_Name $Repo_Full_Name -Tag_Name $Release_Tag -Token $Token
	}
}

if($Cleanup_Workflow_Runs)
{
	$Runs = list_workflow_runs_all -Repo_Full_Name $Repo_Full_Name -Workflow_File $Workflow_File -Branch $Default_Branch -Token $Token -Per_Page 100 -Max_Pages 10
	foreach($Run in $Runs)
	{
		if($Run.status -eq 'completed')
		{
			$Run_Id = [int64]$Run.id
			if($PSCmdlet.ShouldProcess("run $Run_Id", "delete ($($Run.conclusion))"))
			{
				Write-Host "删除 run: $Run_Id ($($Run.conclusion))"
				$null = delete_run_best_effort -Repo_Full_Name $Repo_Full_Name -Run_Id $Run_Id -Token $Token
			}
		}
	}
}

if($Dispatch_Workflow)
{
	$Inputs = @{
		upload_artifact = $Dispatch_Input_Upload_Artifact
	}

	if($PSCmdlet.ShouldProcess("${Repo_Full_Name}:$Workflow_File", "dispatch workflow"))
	{
		dispatch_workflow -Repo_Full_Name $Repo_Full_Name -Workflow_File $Workflow_File -Ref $Default_Branch -Token $Token -Inputs $Inputs
		Write-Host "已触发 workflow_dispatch"
	}

	$New_Run = $null
	for($Try = 0; $Try -lt 10; $Try++)
	{
		Start-Sleep -Seconds 3
		$Runs = get_workflow_runs -Repo_Full_Name $Repo_Full_Name -Workflow_File $Workflow_File -Branch $Default_Branch -Token $Token -Per_Page 10
		foreach($Run in $Runs)
		{
			if($Run.event -eq 'workflow_dispatch' -and $Run.status -ne 'completed')
			{
				$New_Run = $Run
				break
			}
		}

		if($null -ne $New_Run)
		{
			break
		}
	}

	if($null -ne $New_Run)
	{
		Write-Host "Run: $($New_Run.html_url)"
	}
	else
	{
		Write-Host "提示: 稍后在 Actions 页面查看运行记录"
	}
}
} finally {
	if($Open_Actions_Page)
	{
		Write-Host "打开 Actions 页面: $Actions_Page_Url"
		try {
			Start-Process -FilePath $Actions_Page_Url | Out-Null
		} catch {
			Write-Host "WARN: 打开浏览器失败：$($_.Exception.Message)"
		}
	}

	if($Pause_At_End)
	{
		$Is_Input_Redirected = $false
		try {
			$Is_Input_Redirected = [Console]::IsInputRedirected
		} catch {
			$Is_Input_Redirected = $false
		}

		if(-not $Is_Input_Redirected)
		{
			Write-Host ''
			Write-Host '执行完毕，按 Enter 退出...'
			try {
				$null = Read-Host
			} catch {
				Write-Host 'WARN: 当前 Host 不支持暂停输入，已跳过'
			}
		}
	}
}

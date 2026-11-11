# 在`Github Actions`上使用`UUP dump`自动制作`Windows 10/11` ISO镜像

## 说明
1. 本项目的主要目的是：使用`UUP dump`自动制作`Windows 10/11`ISO镜像(使用`Github Actions`自动构建)

## 地址
1. 本仓库地址: https://github.com/yuanpeirong/UUPdumpWinISO (只发布源码)
2. 备用仓库地址: https://github.com/yprsoft/UUPdumpWinISO (发布源码+镜像)
3. `UUP dump`地址: https://uupdump.net/

## 目前已构建`Windows 10`版本
- Windows10_21H2_amd64_Cumulative_Update：
  - `19044.6812.260122-0756.21H2_RELEASE_SVC_IM_CLIENTMULTI_X64FRE_ZH-CN.ISO` (2026年2月)
- Windows10_21H2_amd64_Feature_update：
  - `19044.6937.260207-1153.21H2_RELEASE_SVC_PROD1_CLIENTMULTI_X64FRE_ZH-CN.ISO` (2026年2月)
- Windows10_22H2_amd64_Cumulative_Update：
  - `19045.6937.260207-1153.22H2_RELEASE_SVC_PROD1_CLIENTMULTI_X64FRE_ZH-CN.ISO` (2026年2月)
- Windows10_22H2_amd64_Feature_update：
  - `19045.6937.260207-1153.22H2_RELEASE_SVC_PROD1_CLIENTMULTI_X64FRE_ZH-CN.ISO` (2026年2月)

## 目前已构建`Windows 11`版本
- Windows11_23H2_amd64：
  - `22631.6649.260207-1041.23H2_NI_RELEASE_SVC_PROD1_CLIENTMULTI_X64FRE_ZH-CN.ISO` (2026年2月)
- Windows11_24H2_amd64：
  - `26100.7899.260206-1814.GE_RELEASE_SVC_PROD2_CLIENTMULTI_X64FRE_ZH-CN.ISO` (2026年2月第2次)
- Windows11_25H2_amd64：
  - `26200.7840.260206-2000.25H2_GE_RELEASE_SVC_PROD1_CLIENTMULTI_X64FRE_ZH-CN.ISO` (2026年2月)
- Windows11_26H1_amd64：
  - `28000.1575.260205-1934.BR_RELEASE_SVC_PROD1_CLIENTMULTI_X64FRE_ZH-CN.ISO` (2026年2月)
- Windows11_Insider_Preview_Feature_Update_Canary_amd64
  - `28020.1611.260205-2019.BR_RELEASE_SVC_BETAFLT_PROD1_CLIENTMULTI_X64FRE_ZH-CN.ISO`  (2026年2月第2次)

## 仓库原理和目的
- 将`UUP dump`网站上得到的脚本上传到仓库，利用Github Actions自动生成ISO镜像
- 将本地运行`UUP dump`脚本改为远程运行，不耗时、不耗CPU、不耗硬盘，坐等远程完成后下载即可
- 支持同时运行多个制作任务

## Windows 10 22H2 每日自动构建
- `Windows10_22H2_amd64_Feature_update` 每天北京时间 08:23（UTC 00:23）检查 UUP dump 的 Windows 10 22H2 amd64 功能更新。
- 检查任务通过 `api.uupdump.net/listid.php` 获取最新版本，并与本仓库已发布且包含镜像分卷的 Release 比较。没有新版本时跳过 Windows 构建；尚未成功发布的版本会在下一次检查时重试。
- 构建前自动更新下载脚本中的 UUP ID、镜像版本号和带 SHA256 校验的转换器下载清单，并添加 UUP dump 官方 Git 仓库的备用下载地址，避免主站文件更新滞后导致 404。所有分卷上传成功后才将 Release 从草稿发布。
- 下载清单返回 `XML_PARSE_ERROR` 等 UUP dump 错误或下载失败时，每隔 30 秒重试，最多尝试 4 次；仍失败则在下载步骤报错退出，不再误报成功后进入打包。
- 保留手动运行入口：勾选 `force_build` 可重新构建已发布版本，`upload_artifact` 可额外上传 Actions artifact。默认仅发布 Release。
- `run_windows10_22h2_amd64_feature_update.ps1` 同步远端文件时包含每日检查和构建准备脚本。其他 Windows 工作流仍采用手动运行。
- 工作流和两个 `.github/scripts/*.ps1` 脚本须一并推送到默认分支后定时任务才会生效；GitHub 的定时执行可能延迟，参见 [GitHub Actions 定时事件说明](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)。

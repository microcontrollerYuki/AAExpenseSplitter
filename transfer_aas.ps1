# AA 同步文件双模拟器传输脚本
# 用法: powershell -File transfer_aas.ps1 -From emulator-5554 -To emulator-5556
# 前提: 先在导出端 App 的「AA」页点一次「导出并发送」(弹出的选项框可以返回取消,
#       文件此时已生成在应用缓存里), 再运行本脚本。
param(
    [string]$From = 'emulator-5554',
    [string]$To = 'emulator-5556'
)
$adb = 'D:\Dev\Android\Sdk\platform-tools\adb.exe'
$pkg = 'com.aaexpense.aa_expense_splitter'
$tmp = Join-Path $env:TEMP 'aasync_transfer.aas'

# 1. 找导出端缓存里最新的导出文件 (只认 aasync_月日_时分秒.aas 格式,
#    避免误拿脚本自己塞入的收件文件; ls 按字母序, 同日内最新排最后)
$files = @(& $adb -s $From shell "run-as $pkg ls cache/" | Select-String 'aasync_\d{4}_\d{6}\.aas')
if ($files.Count -eq 0) {
    Write-Host "导出端 $From 没有找到同步文件: 请先在 App「AA」页点「导出并发送」" -ForegroundColor Red
    exit 1
}
$latest = ("$($files[-1])" -split '\s+')[-1]
Write-Host "导出文件: cache/$latest"

# 2. 拉到电脑 (cmd 重定向保证二进制不被 PowerShell 改写)
cmd /c "$adb -s $From exec-out run-as $pkg cat cache/$latest > $tmp"
if (-not (Test-Path $tmp) -or (Get-Item $tmp).Length -lt 100) {
    Write-Host "拉取失败" -ForegroundColor Red
    exit 1
}
Write-Host ("已拉取到电脑: {0} ({1} 字节)" -f $tmp, (Get-Item $tmp).Length)

# 3. 经 /data/local/tmp 中转, 直接放进目标 App 私有缓存
#    (公共 Download 目录受 Android 分区存储限制, App 无权直接读)
& $adb -s $To push $tmp /data/local/tmp/aa_inbox.aas | Out-Null
& $adb -s $To shell "run-as $pkg cp /data/local/tmp/aa_inbox.aas cache/aa_inbox.aas"
Write-Host "已放入 $To 的应用缓存"

# 4. 显式启动 App 并通过 extra 传入路径触发导入 (App 读自己的缓存目录没有权限问题)
& $adb -s $To shell am start -n "$pkg/.MainActivity" --es aa_import "/data/user/0/$pkg/cache/aa_inbox.aas" | Out-Null

# 5. 清理收件文件, 避免残留干扰后续传输
& $adb -s $To shell "run-as $pkg rm cache/aa_inbox.aas" | Out-Null
& $adb -s $To shell rm /data/local/tmp/aa_inbox.aas | Out-Null
Write-Host "已触发 $To 上的 AA记账 导入, 请查看应用弹窗" -ForegroundColor Green


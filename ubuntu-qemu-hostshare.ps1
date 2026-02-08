# 1) Create a local user (pick a strong password)
$u = "qemuguest"
$p = Read-Host "New password for $u" -AsSecureString
New-LocalUser -Name $u -Password $p -PasswordNeverExpires -AccountNeverExpires

# 2) Give this user NTFS permission on the folder
$path = "C:\Users\User\Desktop\QEMU_Ubuntu\share"
icacls $path /grant "${u}:(OI)(CI)M" /t

# 3) Share the folder as 'hostshare' and allow that user
# (GUI: Properties → Sharing → Advanced Sharing → Share this folder → Permissions → Add qemuguest → Allow Change+Read)

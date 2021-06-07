resource "aws_instance" "myec2" {
  # The connection block tells our provisioner how to
  # communicate with the resource (instance)
  # WinRM will not work unless you include a SG here to allow
  # traffic from TCP ports 5985/5986.
  connection {
    type     = "winrm"
    user     = "Administrator"
    password = var.admin_password
    # Limit for WinRM timeout
    timeout = "10m"
  }
  # Change instance type for appropriate use case
  instance_type = "t2.micro"
  ami           = "ami-053bfce7fb332917f"

  # Root storage
  # Terraform doesn't allow encryption of root at this time
  # encrypt volume after deployment.
  root_block_device {
    volume_type = "gp2"
    volume_size = 40
    delete_on_termination = true
  }

  ebs_block_device {
    device_name = "xvdf"
    delete_on_termination = true
    volume_size = 10
    volume_type = "standard"
  }

  ebs_block_device {
    device_name = "xvdg"
    delete_on_termination = true
    volume_size = 10
    volume_type = "standard"
  }

  # AZ to launch in
  availability_zone = var.aws_availability_zone

  # VPC subnet and SGs
  subnet_id = aws_subnet.main.id
  vpc_security_group_ids = [aws_security_group.RemoteAdmin.id, aws_security_group.WebProtocols.id ]
  associate_public_ip_address = "true"

  key_name = var.key_name

     user_data = <<EOF
<script>
  winrm quickconfig -q & winrm set winrm/config @{MaxTimeoutms="1800000"} & winrm set winrm/config/service @{AllowUnencrypted="true"} & winrm set winrm/config/service/auth @{Basic="true"}
</script>
<powershell>
  #Install WMF 5.1
  $source = "https://go.microsoft.com/fwlink/?linkid=839516"
  $destination = "$env:temp\Win8.1AndW2K12R2-KB3191564-x64.msu" 
  $wc = New-Object System.Net.WebClient 
  $wc.DownloadFile($source, $destination)
  Start-Process -FilePath $destination -Wait -ArgumentList '/quiet /norestart'
 
  # Allow WinRM Connection
  netsh advfirewall firewall add rule name="WinRM in" protocol=TCP dir=in profile=any localport=5985 remoteip=${var.winrm_IP} localip=any action=allow
  
  # Configure WinRM certificates
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri ${var.gitHub_winRM_cert_script} -OutFile "$env:temp\ConfigureRemotingForAnsible.ps1"
  Set-Location $env:temp
  .\ConfigureRemotingForAnsible.ps1

  # Disable IE Security Function
  function Disable-InternetExplorerESC {
    $AdminKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}"
    $UserKey = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}"
    Set-ItemProperty -Path $AdminKey -Name "IsInstalled" -Value 0 -Force
    Set-ItemProperty -Path $UserKey -Name "IsInstalled" -Value 0 -Force
    Stop-Process -Name Explorer -Force
  }
  
  # Disable UAC Function
  function Disable-UserAccessControl {
    Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "ConsentPromptBehaviorAdmin" -Value 00000000 -Force
    Write-Host "User Access Control (UAC) has been disabled." -ForegroundColor Green    
  }

  # Disable IE Sec and UAC
  Disable-InternetExplorerESC
  Disable-UserAccessControl

  #Set Time Zone
  Set-TimeZone -Name "W. Europe Standard Time"

  # Set Default Administrator password
  $admin = [adsi]("WinNT://./administrator, user")
  $admin.psbase.invoke("SetPassword", "${var.admin_password}")
  
  # Install IIS Features and Roles
  Install-WindowsFeature -name Web-Server -IncludeAllSubFeature -IncludeManagementTools
  
  #Install NuGet
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
  
  #Set up PSModules dir
  New-Item -ItemType Directory -Path 'C:\PSModules'
  $CurrentValue = [Environment]::GetEnvironmentVariable("PSModulePath", "Machine")
  [Environment]::SetEnvironmentVariable("PSModulePath", $CurrentValue + [System.IO.Path]::PathSeparator + "C:\PSModules", "Machine")
  
  #Install Universal Dashboard Module
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Find-Module UniversalDashboard -RequiredVersion ${var.UD_version_number} | Save-Module -Path 'C:\PSModules'
  
  #Install Dot Net Hosting 
  $source = "https://download.visualstudio.microsoft.com/download/pr/c8eabe25-bb2b-4089-992e-48198ff72ad8/a55a5313bfb65ac9bd2e5069dd4de5bc/dotnet-hosting-3.1.15-win.exe"
  $destination = "$env:temp\dotnet-hosting-3.1.15-win.exe" 
  $wc = New-Object System.Net.WebClient 
  $wc.DownloadFile($source, $destination)
  Start-Process -FilePath $destination -Wait - -ArgumentList '/Quiet'
    
  #Configure Drives
  $drive = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter = 'D:'"
  $drive | Set-CimInstance -Property @{DriveLetter ='O:'}
  
  $drive = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter = 'E:'"
  $drive | Set-CimInstance -Property @{DriveLetter ='P:'}
  
  #Add Website dirs
  New-Item -ItemType Directory -Path 'O:\UniversalDashboard\'
  New-Item -ItemType Directory -Path 'O:\UniversalDashboard\UDDashboard'
  New-Item -ItemType Directory -Path 'O:\UniversalDashboard\UDRestAPI'
  New-Item -ItemType Directory -Path 'P:\Log'
  New-Item -ItemType Directory -Path 'P:\Log\stdout'
    
  #Create the websites:
  #https://4sysops.com/archives/create-web-apps-and-application-pools-in-iis-with-powershell/
  Import-Module WebAdministration

  New-WebAppPool -Name UDRestAPI
  New-WebAppPool -Name UDDashboard

  New-WebApplication -Site UDDashboard -name UDDashboard  -PhysicalPath 'O:\UniversalDashboard\UDDashboard' -ApplicationPool UDDashBoard
  New-WebApplication -Site UDRestAPI -name UDRestAPI  -PhysicalPath 'O:\UniversalDashboard\UDRestAPI' -ApplicationPool UDRestAPI

  Set-ItemProperty IIS:\AppPools\UDDashboard managedPipelineMode Integrated
  Set-ItemProperty IIS:\AppPools\UDDashboard autoStart true

  Set-ItemProperty IIS:\AppPools\UDRestAPI managedPipelineMode Integrated
  Set-ItemProperty IIS:\AppPools\UDRestAPI startMode AlwaysRunning

  $acl = Get-Acl C:\PSModules
  $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule("IIS AppPool\UDDashboard","ReadAndExecute","Allow")
  $acl.SetAccessRule($accessRule)
  $acl | Set-Acl 

  $acl = Get-Acl C:\PSModules
  $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule("IIS AppPool\UDRestAPI","ReadAndExecute","Allow")
  $acl.SetAccessRule($accessRule)
  $acl | Set-Acl 

  #Copy contents of UD Module to website dirs
  $source = C:\PSModules\UniversalDashboard\${var.UD_version_number}
  Get-ChildItem $source | Copy-Item -Destination 'O:\UniversalDashboard\UDDashboard' -Recurse
  Get-ChildItem $source | Copy-Item -Destination 'O:\UniversalDashboard\UDRestAPI' -Recurse

  #Configure WebConfigs
  [xml]$xml = Get-Content O:\UniversalDashboard\UDDashboard\web.config
  $xml.configuration.'system.webServer'.aspNetCore.processPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
  $xml.configuration.'system.webServer'.aspNetCore.arguments = '.\dashboard.ps1'
  $xml.configuration.'system.webServer'.aspNetCore.stdoutLogEnabled = 'true'
  $xml.configuration.'system.webServer'.aspNetCore.stdoutLogFile = 'P:\Log\stdout'
  $xml.Save("O:\UniversalDashboard\UDDashboard\web.config")

  [xml]$xml = Get-Content O:\UniversalDashboard\UDDashboard\web.config
  $xml.configuration.'system.webServer'.aspNetCore.processPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
  $xml.configuration.'system.webServer'.aspNetCore.arguments = '.\restapi.ps1'
  $xml.configuration.'system.webServer'.aspNetCore.stdoutLogEnabled = 'true'
  $xml.configuration.'system.webServer'.aspNetCore.stdoutLogFile = 'P:\Log\stdout'
  $xml.Save("O:\UniversalDashboard\UDRestAPI\web.config")

  $dashContent = @"
  Start-UDDashboard -Port 80 -Wait -Dashboard (
    New-UDDashboard -Title "Powershell UniversalDashboard" -Content {
        New-UDButton -Id "test" -Text "test" -BackgroundColor "#6f42c1" -onClick {}
    }
)
"@

$restapiContent = @"
Start-UDRestApi -Port 8080 -Wait -Endpoint @(
	New-UDEndpoint -Url "user" -Method "GET" -Endpoint {
		@("Adam", "Sarah", "Bill") | ConvertTo-Json
	}
)
"@

  $dashContent | Out-File -Path "O:\UniversalDashboard\UDDashboard\dashboard.ps1"
  $restAPIContent | Out-File -Path "O:\UniversalDashboard\UDRestAPI\restapi.ps1"

  #Set the RESTAPI binding to match the startup port in the script
  Set-WebBinding -Name 'UDRestAPI' -BindingInformation "*:80:" ‑PropertyName Port -Value 8080
  
  #Install Dot Net Hosting 
  $source = "https://download.visualstudio.microsoft.com/download/pr/5ee633f2-bf6d-49bd-8fb6-80c861c36d54/caa93641707e1fd5b8273ada22009246/dotnet-hosting-2.2.1-win.exe"
  $destination = "$env:temp\dotnet-hosting-2.2.1-win.exe" 
  $wc = New-Object System.Net.WebClient 
  $wc.DownloadFile($source, $destination)
  Start-Process -FilePath $destination -Wait
    
  # Reset IIS
  Start-Process "iisreset.exe" -NoNewWindow -Wait
</powershell>
EOF
}

/*
resource "aws_ebs_volume" "ODrive" {
  availability_zone = var.aws_availability_zone
  size              = 10
  
  depends_on = [
    aws_instance.myec2
  ]
}

resource "aws_ebs_volume" "PDrive" {
  availability_zone = var.aws_availability_zone
  size              = 10
  depends_on = [
    aws_instance.myec2
  ]
}

resource "aws_volume_attachment" "ODriveAttach" {
  device_name = "xvdf"
  volume_id   = aws_ebs_volume.ODrive.id
  instance_id = aws_instance.myec2.id
}

resource "aws_volume_attachment" "PDriveAttach" {
  device_name = "xvdg"
  volume_id   = aws_ebs_volume.PDrive.id
  instance_id = aws_instance.myec2.id
}
*/


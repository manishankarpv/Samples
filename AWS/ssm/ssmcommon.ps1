﻿function SSMSetTitle ($Suffix) {

    $map = @{
        'us-east-1'='IAD (Virginia)'
        'eu-west-1'='DUB (Ireland)'
        'us-west-2'='PDX (Oregon)'

        'eu-central-1'='FRA (Frankfurt)'
        'us-west-1'='SFO (CA)'
        'sa-east-1'='GRU (Sao Paulo)'
        'ap-northeast-1'='NRT (Tokyo)'
        'ap-southeast-1'='SIN (Singapore)'
        'ap-southeast-2'='SYD (Sydney)'
        'ap-northeast-2'='ICN (Seoul)'
    }
    if ($endpoint) {
        $title = 'Gamma'
    } else {
        $region = (Get-DefaultAWSRegion).Region
        $title = "$region, $($map.$region)"
    }
    if ($Suffix.Length -gt 0) {
        $title = "$title, $Suffix"
    }
    $host.ui.RawUI.WindowTitle = $title
    if ($psISE) {
        $psISE.CurrentPowerShellTab.DisplayName = "$($psISE.PowerShellTabs.IndexOf($psISE.CurrentPowerShellTab)). $title"
    }
}

function SSMDeleteDocument ([string]$DocumentName) {
    #delete association
    foreach ($association in (Get-SSMAssociationList -AssociationFilterList @{Key='Name';Value=$DocumentName})) {
        Remove-SSMAssociation -AssociationId $association.AssociationId -Force
        #aws ssm delete-association --association-id $association.AssociationId --endpoint-url $endpoint
        Write-Verbose "Deleted Association Name=$($association.Name), AssociationId=$($association.AssociationId)"
    }

    #delete document
    if (Get-SSMDocumentList -DocumentFilterList @{key='Owner';Value='self'},@{key='Name';Value=$DocumentName}) {
        Write-Verbose "Delete Document $DocumentName"
        Remove-SSMDocument -Name $DocumentName -Force
    } else {
        Write-Verbose "Skipping to delete Document as $DocumentName not found"
    }
}


function SSMCreateDocument ([string]$DocumentName, [string]$DocumentContent, [string]$DocumentType = 'Command') {
#    Write-Verbose "Create SSM Document Name=$DocumentName, Content=`n$DocumentContent"
    Write-Verbose "Create SSM Document Name=$DocumentName"
    $DocumentContent = $DocumentContent.Replace("`r",'').Trim()
    #$DocumentContent | Out-File -Encoding ascii doc.json
    #$info = aws ssm create-document --name $DocumentName --content file://.\doc.json --document-type $DocumentType --endpoint-url $endpoint
    $info = New-SSMDocument -Name $DocumentName -Content $DocumentContent -DocumentType $DocumentType

    $d2 =(Get-SSMDocument -Name $DocumentName).Content.Trim()
    if ($DocumentContent -ne $d2) {
        throw "$DocumentName content did not match"
    }
}


function SSMAssociateTarget ([string]$DocumentName, [Hashtable]$Targets, [Hashtable]$Parameters, [string]$Schedule="cron(0 0/30 * 1/1 * ? *)") {
    $region = (Get-DefaultAWSRegion).Region
    $bucket = Get-SSMS3Bucket
    $key=$Targets.'Key'

    $target=$Targets.'Values' <#| ConvertTo-Json
    if ($Targets.'Values'.Count -eq 1) {
        $target="[$Target]"
    }#>

    Write-Verbose ''
    Write-Verbose "SSMAssociateTarget: Name=$Name, Bucket=$bucket, Key=$key, Target=$target"
    $inputJson = @"
        {
            "Name": "$DocumentName", 
            "Parameters": $($Parameters | ConvertTo-Json), 
            "Targets": [
                {"Key": "$key", "Values": $target}
            ], 
            "ScheduleExpression": "$Schedule", 
            "OutputLocation": {
                "S3Location": {"OutputS3Region": "$region", "OutputS3BucketName": "$bucket", "OutputS3KeyPrefix": "associate"}
            }
        }
"@
    #$output = Invoke-AWSCLI -SubCommand 'create-association' -InputJson $inputJson
    #$output

    New-SSMAssociation -Name $DocumentName -Target @{Key=$Targets.'Key'; Values=$target} -Parameter $Parameters -ScheduleExpression $Schedule `
        -S3Location_OutputS3Region $region -S3Location_OutputS3BucketName $bucket -S3Location_OutputS3KeyPrefix 'ssm/associate'
}


function SSMReStartAgent ($Instances) {
    foreach ($instance in $instances) {
    $cmd = @'
if [ -f /etc/debian_version ]; then
        sudo service amazon-ssm-agent stop
        sudo rm /var/log/amazon/ssm/amazon-ssm-agent.log
        sudo service amazon-ssm-agent start
else
        sudo stop amazon-ssm-agent
        sudo rm /var/log/amazon/ssm/amazon-ssm-agent.log
        sudo start amazon-ssm-agent
fi

'@.Replace("`r",'')

        $publicIpAddress = $instance.PublicIpAddress
        $output = Invoke-WinEC2Command $instance -Script $cmd
        Write-Verbose "ssh output:`n$output"
    }
}


function SSMWaitForMapping([string[]]$InstanceIds, [int]$AssociationCount) {
    Write-Verbose ''

    foreach ($instanceId in $InstanceIds) {
        $cmd = {
            $a = Get-SSMInstanceAssociationsStatus -InstanceId $instanceId
            Write-Verbose "SSMWaitForMapping Current=$($a.Count), Expected=$AssociationCount, InstanceId=$instanceId"
            $a.Count -eq $AssociationCount
        }

        $null = Invoke-PSUtilWait $cmd -Message 'Mapping' -RetrySeconds 50
    }
}

function SSMWaitForAssociation([string[]]$InstanceIds, [int]$ExpectedAssociationCount, [int]$MinS3OutputSize = 100, [string]$ContainsString) {

    foreach ($instanceid in $InstanceIds) {
        Write-Verbose ''
        Write-Verbose "SSMWaitForAssociation: InstanceId=$instanceid, ExpectedAssociationCount=$ExpectedAssociationCount, S3OutputSize=$size, Min Expected=$MinS3OutputSize"
        $cmd = {
            $infos = Get-SSMInstanceAssociationsStatus -InstanceId $instanceid
            $found = $true
            foreach ($info in $infos) {
                Write-Verbose "Status=$($info.Status), InstanceId=$($info.InstanceId), AssociationId=$($info.AssociationId), Current Count=$($infos.Count)"
                if ($info.Status -ne 'Success') {
                    $found = $false
                }
            }
            $found -and $infos.Count -eq $ExpectedAssociationCount
        }
        $null = Invoke-PSUtilWait $cmd 'Associate Apply' -RetrySeconds 500 -SleepTimeInMilliSeconds 20000


        $size = 0

        $infos = Get-SSMInstanceAssociationsStatus -InstanceId $instanceid
        foreach ($info in $infos) {
            $association = Get-SSMAssociation -AssociationId $info.AssociationId
            if ($association.OutputLocation -and $ContainsString.Length -gt 0) {
                $key = "$($association.OutputLocation.S3Location.OutputS3KeyPrefix)/$instanceid/$($association.AssociationId)/"
                $bucket=$association.OutputLocation.S3Location.OutputS3BucketName
            
                for ($retryCount=0; $retryCount -lt 50; $retryCount++) {
                    $s3objects = Get-S3Object -BucketName $bucket -KeyPrefix $key

                    if ($s3objects.Count -gt 0) {
                        break
                    }
                    Write-Verbose "Sleeping $bucket/$key Count=$($s3objects.Count)"
                    Sleep 2
                }
                if ($retryCount -ge 5) {
                    throw "Key count is zero $bucket/$key"
                }
                Write-Verbose "$bucket/$key Count=$($s3objects.Count)"

                $found = $false
                $tempFile = [System.IO.Path]::GetTempFileName()
                foreach ($s3object in $s3objects)
                {
                    $size += $s3object.Size
                    if ($s3object.Size -gt 3) 
                    {
                        #Write-Verbose "$bucket\$($s3object.key):"
                        $null = Read-S3Object -BucketName $bucket -Key $s3object.Key -File $tempFile
                        if ($s3object.key.EndsWith('stderr.txt') -or $s3object.key.EndsWith('stderr')) {
                            cat $tempFile -Raw | Write-Error
                        } else {
                            $st = cat $tempFile -Raw 
                            if ($st.Contains($ContainsString)) {
                                $found = $true
                            }
                            #Write-Verbose "output: '$st'"
                        }
                        del $tempFile -Force
                    }
                    $null = Remove-S3Object -BucketName $bucket -Key $s3object.Key -Force
                }
                if (! $found) {
                    throw "'$ContainsString' is not found in the output"
                }
            }
        }

        if ($size -lt $MinS3OutputSize) {
            throw "S3Output is less than expected S3OutputSize=$size, Min Expected=$MinS3OutputSize"
        }
    
        $effectiveAssociations = Get-SSMEffectiveInstanceAssociationList -InstanceId $instanceid -MaxResult 5
        if ($effectiveAssociations.Count -ne $ExpectedAssociationCount) {
            throw "Effective Association Count did not match. Expected=$ExpectedAssociationCount, got=$($effectiveAssociations.Count)"
        }
    }
}

function SSMRefreshAssociation ([string[]]$InstanceIds, [string]$AssociationIds) {
    Write-Verbose ''

    $batchsize = 5

    for ($i = 0; $i -lt $InstanceIds.Count; $i += $batchsize) {
        $batchInstanceIds = $InstanceIds[$i..($i + $batchsize -1)]
        Write-Verbose "SSMRefreshAssociation: InstanceIds=$batchInstanceIds, AssociationIds=$AssociationIds"
        $result = Send-SSMCommand -InstanceId $batchInstanceIds -DocumentName 'AWS-RefreshAssociation' -Parameters @{associationIds=$AssociationIds} -MaxConcurrency '1'

        Write-Verbose "CommandId=$($result.CommandId)"

        $cmd = {
            $status1 = (Get-SSMCommand -CommandId $result.CommandId).Status
            ($status1 -ne 'Pending' -and $status1 -ne 'InProgress')
        }
        $null = SSMWait -Cmd $cmd -Message 'Command Execution' -RetrySeconds 300 -SleepTimeInMilliSeconds 3000
    
        $command = Get-SSMCommand -CommandId $result.CommandId
        if ($command.Status -ne 'Success') {
            throw "Command $($command.CommandId) did not succeed, Status=$($command.Status)"
        }


        foreach ($instanceId in $batchInstanceIds) {
            $invocation = Get-SSMCommandInvocation -InstanceId $InstanceId -CommandId $command.CommandId -Details:$true
            $output = $invocation.CommandPlugins[0].Output
            Write-Verbose "RefreshAssociation InstanceId=$instanceId, Output: $output"
        }
    }
}


function SSMCreateKeypair (
        [string]$KeyFile = 'c:\keys\test'
    )
{
    $keyName = $KeyFile.split('/\')[-1]

    if (Get-EC2KeyPair  | ? { $_.KeyName -eq $keyName }) { 
        Write-Verbose "Skipping as keypair ($keyName) already present." 
        return
    }

    if (Test-Path "$KeyFile.pub") {
        $publicKeyMaterial = cat "$KeyFile.pub" -Raw
        $encodedPublicKeyMaterial = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($publicKeyMaterial))
        Import-EC2KeyPair -KeyName $keyName -PublicKeyMaterial $encodedPublicKeyMaterial
        Write-Verbose "Importing KeyName=$keyName, keyfile=$KeyFile"
    } else {
        Write-Verbose "Creating KeyName=$keyName, keyfile=$KeyFile"
        $keypair = New-EC2KeyPair -KeyName $keyName
        "$($keypair.KeyMaterial)" | Out-File -encoding ascii -filepath "$KeyFile.pem"
    }
}

function SSMRemoveKeypair (
        [string]$KeyFile = 'c:\keys\test'
    )
{
    #delete keypair
    $keyName = $KeyFile.split('/\')[-1]
    Remove-EC2KeyPair -KeyName $keyName -Force
    Write-Verbose "Removed keypair=$keypair, keyfile=$keyfile"
}


function SSMCreateRole ([string]$RoleName = 'winec2role')
{
    if (Get-IAMRoles | ? {$_.RoleName -eq $RoleName}) {
        Write-Verbose "Skipping as role ($RoleName) is already present."
        return
    }
    #Define which accounts or AWS services can assume the role.
    $assumePolicy = @"
{
    "Version":"2012-10-17",
    "Statement":[
      {
        "Sid":"",
        "Effect":"Allow",
        "Principal":{"Service":["ec2.amazonaws.com", "ssm.amazonaws.com", "lambda.amazonaws.com", "kinesisanalytics.amazonaws.com"]},
        "Action":"sts:AssumeRole"
      }
    ]
}
"@
    #step a - Create the role and specify who can assume
    $null = New-IAMRole -RoleName $RoleName `
                -AssumeRolePolicyDocument $assumePolicy
    
    #step b - write the role policy
    #Write-IAMRolePolicy -RoleName $RoleName `
    #            -PolicyDocument $policy -PolicyName 'ssm'

    Register-IAMRolePolicy -RoleName $RoleName -PolicyArn 'arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM'

    #step c - Create instance profile
    $null = New-IAMInstanceProfile -InstanceProfileName $RoleName

    #step d - Add the role to the profile
    Add-IAMRoleToInstanceProfile -InstanceProfileName $RoleName `
            -RoleName $RoleName
    Write-Verbose "Role $RoleName created" 
}
function SSMRemoveRole ([string]$RoleName = 'winec2role')
{
    if (!(Get-IAMRoles | ? {$_.RoleName -eq $RoleName})) {
        Write-Verbose "Skipping as role ($RoleName) not found"
        return
    }
    #Remove the instance role and IAM Role
    Invoke-PSUtilIgnoreError {Remove-IAMRoleFromInstanceProfile -InstanceProfileName $RoleName -RoleName $RoleName -Force}
    Invoke-PSUtilIgnoreError {Remove-IAMInstanceProfile $RoleName -Force}
    Invoke-PSUtilIgnoreError {Unregister-IAMRolePolicy -RoleName $RoleName -PolicyArn 'arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM'}
    #Remove-IAMRolePolicy $RoleName ssm -Force
    Remove-IAMRole $RoleName -Force
    Write-Verbose "Role $RoleName removed" 
}




function SSMCreateSecurityGroup ([string]$SecurityGroupName = 'winec2securitygroup')
{
    if ($securityGroup = (Get-EC2SecurityGroup | ? { $_.GroupName -eq $securityGroupName })) {
        Write-Verbose "Skipping as SecurityGroup ($securityGroupName) already present."
        $securityGroupId = $securityGroup.GroupId
    } else {
        #Security group and the instance should be in the same network (VPC)
        $vpc = Get-EC2Vpc | ? { $_.IsDefault } | select -First 1
        $securityGroupId = New-EC2SecurityGroup $securityGroupName  -Description "winec2 Securitygroup" -VpcId $vpc.VpcId
        $securityGroup = Get-EC2SecurityGroup -GroupName $securityGroupName 
        Write-Verbose "Security Group $securityGroupName created"
    }

    #Compute new ip ranges
    $bytes = (Invoke-WebRequest 'http://checkip.amazonaws.com/' -UseBasicParsing).Content
    $myIP = @(([System.Text.Encoding]::Ascii.GetString($bytes).Trim() + "/32"))
    Write-Verbose "$myIP retreived from checkip.amazonaws.com"
    $ips = @($myIP)
    $ips += (Get-EC2Vpc).CidrBlock

    $SourceIPRanges = @()
    foreach ($ip in $ips) {
        $SourceIPRanges += @{ IpProtocol="tcp"; FromPort="22"; ToPort="5986"; IpRanges=$ip}
        $SourceIPRanges += @{ IpProtocol='icmp'; FromPort = -1; ToPort = -1; IpRanges = $ip}
    }

    #Current expanded list
    $currentIPRanges = @()
    foreach ($ipPermission in $securityGroup.IpPermission) {
        foreach ($iprange in $ipPermission.IpRange) {
            $currentIPRanges += @{ IpProtocol=$ipPermission.IpProtocol; FromPort =$ipPermission.FromPort; ToPort = $ipPermission.ToPort; IpRanges = $iprange}
        }
    }

    # Remove IPRange from current, if it should not be
    foreach ($currentIPRange in $currentIPRanges) {
        $found = $false
        foreach ($SourceIPRange in $SourceIPRanges) {
            if ($SourceIPRange.IpProtocol -eq $currentIPRange.IpProtocol -and
                $SourceIPRange.FromPort -eq $currentIPRange.FromPort -and
                $SourceIPRange.ToPort -eq $currentIPRange.ToPort -and
                $SourceIPRange.IpRanges -eq $currentIPRange.IpRanges) {
                    $found = $true
                    break
            }
        }
        if ($found) {
            Write-Verbose "Skipping protocol=$($currentIPRange.IpProtocol) IPRange=$($currentIPRange.IpRanges)"
        } else {
            Revoke-EC2SecurityGroupIngress -GroupId $securityGroupId -IpPermission $currentIPRange
            Write-Verbose "Granted permissions for $($SourceIPRange.IpProtocol) ports $($SourceIPRange.FromPort) to $($SourceIPRange.ToPort), IP=$($SourceIPRange.IpRanges)"
        }
    }

    # Add IPRange to current, if it is not present
    foreach ($SourceIPRange in $SourceIPRanges) {
        $found = $false
        foreach ($currentIPRange in $currentIPRanges) {
            if ($SourceIPRange.IpProtocol -eq $currentIPRange.IpProtocol -and
                $SourceIPRange.FromPort -eq $currentIPRange.FromPort -and
                $SourceIPRange.ToPort -eq $currentIPRange.ToPort -and
                $SourceIPRange.IpRanges -eq $currentIPRange.IpRanges) {
                    $found = $true
                    break
            }
        }
        if (! $found) {
            Grant-EC2SecurityGroupIngress -GroupId $securityGroupId -IpPermissions $SourceIPRange
            Write-Verbose "Granted permissions for ports 22 to 5986, for IP=$($SourceIPRange.IpRanges)"
        }
    }
}

function SSMRemoveSecurityGroup ([string]$SecurityGroupName = 'winec2securitygroup')
{
    $securityGroupId = (Get-EC2SecurityGroup | `
        ? { $_.GroupName -eq $securityGroupName }).GroupId

    if ($securityGroupId) {
        SSMWait {(Remove-EC2SecurityGroup $securityGroupId -Force) -eq $null} `
                'Delete Security Group' 300
        Write-Verbose "Security Group $securityGroupName removed"
    } else {
        Write-Verbose "Skipping as SecurityGroup $securityGroupName not found"
    }
}




function SSMCreateWindowsInstance (
        [string]$ImageName = 'WINDOWS_2012R2_BASE',
        [string]$SecurityGroupName = 'winec2securitygroup',
        [string]$InstanceType = 'm4.large',
        [string]$Tag = 'ssm-demo',
        [string]$KeyName = 'winec2keypair',
        [string]$KeyFile = "c:\keys\$((Get-DefaultAWSRegion).Region).$keyName.pem",
        [string]$RoleName = 'winec2role',
        [int]$InstanceCount=1
    )
{
    #Check if the instance is already present
    $filter1 = @{Name='tag:Name';Value=$Tag}
    $filter2 = @{Name='instance-state-name';Values=@('running','pending','stopped')}
    $instance = Get-EC2Instance -Filter @($filter1, $filter2)
    if ($instance) {
        $instanceId = $instance.Instances.InstanceId
        Write-Verbose "Skipping instance $instanceId creation, already present"
        $instanceId
        return
    }

    $securityGroupId = (Get-EC2SecurityGroup | `
        ? { $_.GroupName -eq $SecurityGroupName }).GroupId
    if (! $securityGroupId) {
        throw "Security Group $SecurityGroupName not found"
    }

    #Get the latest R2 base image
    $image = Get-EC2ImageByName $ImageName
    Write-Verbose "Image=$($image.Name), SecurityGroupName=$SecurityGroupName, InstanceType=$InstanceType, KeyName=$KeyName, RoleName=$RoleName, InstanceCount=$InstanceCount"

    #User Data to enable PowerShell remoting on port 80
    #User data must be passed in as 64bit encoding.
    $userdata = @"
    <powershell>
    Enable-NetFirewallRule FPS-ICMP4-ERQ-In
    Set-NetFirewallRule -Name WINRM-HTTP-In-TCP-PUBLIC -RemoteAddress Any
    New-NetFirewallRule -Name "WinRM80" -DisplayName "WinRM80" -Protocol TCP -LocalPort 80
    Set-Item WSMan:\localhost\Service\EnableCompatibilityHttpListener -Value true
    </powershell>
"@
    $utf8 = [System.Text.Encoding]::UTF8.GetBytes($userdata)
    $userdataBase64Encoded = [System.Convert]::ToBase64String($utf8)

    #Launch EC2 Instance with the role, firewall group created
    # and on the right subnet
    $instances = (New-EC2Instance -ImageId $image.ImageId `
                    -InstanceProfile_Id $RoleName `
                    -AssociatePublicIp $true `
                    -SecurityGroupId $securityGroupId `
                    -KeyName $keyName `
                    -UserData $userdataBase64Encoded `
                    -InstanceType $InstanceType `
                    -MinCount $InstanceCount -MaxCount $InstanceCount).Instances

    New-EC2Tag -ResourceId $instances.InstanceId -Tag @{Key='Name'; Value=$Tag}

    foreach ($instance in $instances) {
        Write-Verbose "InstanceId=$($instance.InstanceId)"
        #Wait to retrieve password
        $cmd = { 
                $password = Get-EC2PasswordData -InstanceId $instance.InstanceId `
                    -PemFile $keyfile -Decrypt 
                $password -ne $null
                }
        SSMWait $cmd 'Password Generation' 600

        $password = Get-EC2PasswordData -InstanceId $instance.InstanceId `
                        -PemFile $keyfile -Decrypt 
        $securepassword = ConvertTo-SecureString $Password -AsPlainText -Force
        $creds = New-Object System.Management.Automation.PSCredential ("Administrator", $securepassword)


<##        #update the instance to get the public IP Address
        $instance = (Get-EC2Instance $instance.InstanceId).Instances

        #Wait for remote PS connection
        $cmd = {
            icm $instance.PublicIpAddress {dir c:\} -Credential $creds -Port 80 
        }
        SSMWait $cmd 'Remote Connection' 450
##>
    }
    $cmd = { 
        $count = (Get-SSMInstanceInformation -InstanceInformationFilterList @{ Key='InstanceIds'; ValueSet=$instances.InstanceId}).Count
        $count -eq $InstanceCount
    }
    SSMWait $cmd 'Instance Registration' 300
    $instances.InstanceId
}
function SSMCreateLinuxInstance (
        [string]$ImageName = `
                #'amzn-ami-hvm-*gp2',
                'ubuntu/images/hvm-ssd/ubuntu-*-14.*',
        [string]$SecurityGroupName = 'winec2securitygroup',
        [string]$InstanceType = 'm4.large',
        [string]$Tag = 'ssm-demo',
        [string]$KeyName = 'winec2keypair',
        [string]$KeyFile = "c:\keys\$((Get-DefaultAWSRegion).Region).$keyName.pem",
        [string]$RoleName = 'winec2role',
        [int]$InstanceCount=1
    )
{
    $filter1 = @{Name='tag:Name';Value=$Tag}
    $filter2 = @{Name='instance-state-name';Values=@('running','pending','stopped')}
    $instance = Get-EC2Instance -Filter @($filter1, $filter2)
    if ($instance) {
        $instanceId = $instance.Instances.InstanceId
        Write-Verbose "Skipping instance $instanceId creation, already present"
        $instanceId
        return
    }
    $securityGroupId = (Get-EC2SecurityGroup | `
        ? { $_.GroupName -eq $SecurityGroupName }).GroupId
    if (! $securityGroupId) {
        throw "Security Group $SecurityGroupName not found"
    }

    #Get the latest image
    $image = Get-EC2Image -Filters @{Name = "name"; Values = "$ImageName*"} | sort -Property CreationDate -Descending | select -First 1
    Write-Verbose "Image=$($image.Name), SecurityGroupName=$SecurityGroupName, InstanceType=$InstanceType, KeyName=$KeyName, RoleName=$RoleName, InstanceCount=$InstanceCount"

    $userdata = @'
#!/bin/bash
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

if [ -f /etc/debian_version ]; then
    echo "Debian"
    curl https://amazon-ssm-us-east-1.s3.amazonaws.com/latest/debian_amd64/amazon-ssm-agent.deb -o amazon-ssm-agent.deb
    dpkg -i amazon-ssm-agent.deb
else
    echo "Amazon Linux or Redhat"
    curl https://amazon-ssm-us-east-1.s3.amazonaws.com/latest/linux_amd64/amazon-ssm-agent.rpm -o amazon-ssm-agent.rpm
    yum install -y amazon-ssm-agent.rpm
fi

'@.Replace("`r",'')

    #User data must be passed in as 64bit encoding.
    $utf8 = [System.Text.Encoding]::UTF8.GetBytes($userdata)
    $userdataBase64Encoded = [System.Convert]::ToBase64String($utf8)

    #Launch EC2 Instance with the role, firewall group created
    # and on the right subnet
    $instances = (New-EC2Instance -ImageId $image.ImageId `
                    -InstanceProfile_Id $RoleName `
                    -AssociatePublicIp $true `
                    -SecurityGroupId $securityGroupId `
                    -KeyName $keyName `
                    -UserData $userdataBase64Encoded `
                    -InstanceType $InstanceType `
                    -MinCount $InstanceCount -MaxCount $InstanceCount).Instances
    New-EC2Tag -ResourceId $instances.InstanceId -Tag @{Key='Name'; Value=$Tag}
<##
    foreach ($instance in $instances) {
        Write-Verbose "InstanceId=$($instance.InstanceId)"

        $cmd = { 
            $a = $(Get-EC2Instance -Filter @{Name = "instance-id"; Values = $instance.InstanceId}).Instances
            ping $a.PublicIpAddress > $null
            $LASTEXITCODE -eq 0
        }
        SSMWait $cmd 'ping' 300
    
    }
##>
    $cmd = { 
        $count = (Get-SSMInstanceInformation -InstanceInformationFilterList @{ Key='InstanceIds'; ValueSet=$instances.InstanceId}).Count
        $count -eq $InstanceCount
    }
    SSMWait $cmd 'Instance Registration' 300
    $instances.InstanceId
}
function SSMRemoveInstance (
        [string]$Tag = 'ssm-demo',
        [string]$KeyName = 'winec2keypair',
        [string]$KeyFile = "c:\keys\$((Get-DefaultAWSRegion).Region).$keyName.pem"
    )
{
    $filter1 = @{Name='tag:Name';Value=$Tag}
    $filter2 = @{Name='instance-state-name';Values=@('running','pending','stopped')}
    $instances = (Get-EC2Instance -Filter @($filter1, $filter2)).Instances
    
    if ($instances) {
        foreach ($instance in $instances) {
            $instanceId = $instance.InstanceId
            $null = Stop-EC2Instance -Instance $instanceId -Force -Terminate
            Write-Verbose "Terminated instance $instanceId"
        }
    } else {
        Write-Verbose "Skipping as instance with name=$Tag not found"
    }
}




function SSMRunCommand (
        $InstanceIds,
        [string]$DocumentName = 'AWS-RunPowerShellScript',
        [Hashtable]$Parameters,
        [string]$Comment = $DocumentName,
        [string]$Outputs3BucketName,
        [string]$Outputs3KeyPrefix = 'ssm/command',
        [int]$Timeout = 300,
        [int]$SleepTimeInMilliSeconds = 2000
    )
{
    Write-Verbose "SSMRunCommand: InstanceIds=$InstanceIds, DocumentName=$DocumentName, Outputs3BucketName=$Outputs3BucketName, Outputs3KeyPrefix=$Outputs3KeyPrefix"
    $parameters = @{
        InstanceId = $InstanceIds
        DocumentName = $DocumentName
        Comment = $DocumentName
        Parameters = $Parameters
        TimeoutSecond = $Timeout
    }
    ($parameters.Parameters | Out-String).Trim() | Write-Verbose
    if($Outputs3BucketName.Length -gt 0 -and $Outputs3KeyPrefix.Length -gt 0) {
        $parameters.'Outputs3BucketName' = $Outputs3BucketName
        $parameters.'Outputs3KeyPrefix' = $Outputs3KeyPrefix

    }
    $result=Send-SSMCommand @parameters 

    Write-Verbose "CommandId=$($result.CommandId)"
    $cmd = {
        $status1 = (Get-SSMCommand -CommandId $result.CommandId).Status
        ($status1 -ne 'Pending' -and $status1 -ne 'InProgress')
    }
    $null = SSMWait -Cmd $cmd -Message 'Command Execution' -RetrySeconds $Timeout -SleepTimeInMilliSeconds $SleepTimeInMilliSeconds
    
    $command = Get-SSMCommand -CommandId $result.CommandId
    if ($command.Status -ne 'Success') {
        (Get-SSMCommandInvocation -CommandId $command.CommandId -Detail $true).CommandPlugins | ? Status -eq 'Failed' | select output | Write-Verbose
        throw "Command $($command.CommandId) did not succeed, Status=$($command.Status)"
    }
    $result
}


function SSMDumpOutput (
        $Command,
        [boolean]$DeleteS3Keys = $true
    )
{
    $commandId = $Command.CommandId
    $bucket = $Command.OutputS3BucketName
    $key = $Command.OutputS3KeyPrefix
    Write-Verbose "SSMDumpOutput CommandId=$commandId, Bucket=$bucket, Key=$key"
    foreach ($instanceId in $Command.InstanceIds) {
        Write-Verbose "InstanceId=$instanceId"
        $invocation = Get-SSMCommandInvocation -InstanceId $instanceId `
                        -CommandId $commandId -Details:$true

        foreach ($plugin in $invocation.CommandPlugins) {
            Write-Verbose "Plugin Name=$($plugin.Name)"
            Write-Verbose "ResponseCode=$($plugin.ResponseCode)"
            Write-Verbose "Plugin Status=$($plugin.Status)"
            if ($key.Length -eq 0 -and $plugin.Output.Length -gt 0) { 
                #if S3 key is defined, this will avoid duplication
                $plugin.Output.Trim()
            }
        }
        if ($bucket -and $key) {
            $s3objects = Get-S3Object -BucketName $bucket `
                      -Key "$key\$commandId\$instanceId\"
            $tempFile = [System.IO.Path]::GetTempFileName()
            foreach ($s3object in $s3objects)
            {
                if ($s3object.Size -gt 3) 
                {
                    $offset = $key.Length + $commandId.Length + `
                                    $instanceId.Length + 3
                    Write-Verbose "$($s3object.key.Substring($offset)):"
                    $null = Read-S3Object -BucketName $bucket `
                             -Key $s3object.Key -File $tempFile
                    if ($s3object.key.EndsWith('stdout.txt') -or $s3object.key.EndsWith('stdout')) {
                        cat $tempFile -Raw | Write-Host
                    } elseif ($s3object.key.EndsWith('stderr.txt') -or $s3object.key.EndsWith('stderr')) {
                        cat $tempFile -Raw | Write-Error
                    } else {
                        cat $tempFile -Raw | Write-Verbose
                    }
                    del $tempFile -Force
                    Write-Verbose ''
                }
                if ($DeleteS3Keys) {
                    $null = Remove-S3Object -BucketName $bucket `
                                 -Key $s3object.Key -Force
                }
            }
        }
        Write-Verbose ''
    }
}

function SSMWait (
    [ScriptBlock] $Cmd, 
    [string] $Message, 
    [int] $RetrySeconds,
    [int] $SleepTimeInMilliSeconds = 5000)
{
    $_msg = "Waiting for $Message to succeed"
    $_t1 = Get-Date
    while ($true)
    {
        $_t2 = Get-Date
        $_t = [int]($_t2 - $_t1).TotalSeconds
        Write-Verbose "$_msg ($_t/$RetrySeconds) Seconds."
        try
        {
            $_result = & $Cmd 2>$_null | select -Last 1 
            if ($? -and $_result)
            {
                Write-Verbose("Succeeded $Message in " + `
                    "$([int]($_t2-$_t1).TotalSeconds) Seconds, Result=$_result")
                break;
            }
        }
        catch
        {
        }
        $_t = [int]($_t2 - $_t1).TotalSeconds
        if ($_t -gt $RetrySeconds)
        {
            throw "Timeout - $Message after $RetrySeconds seconds, " +  `
                "Current result=$_result"
            break
        }
        Sleep -Milliseconds $SleepTimeInMilliSeconds
    }
}





function SSMGetLogs (
    $instance, 
    [PSCredential] $Credential, 
    [string]$log = 'ssm.log')
{
    Write-Verbose "Log file $log"
    $cmd = {
        Get-EventLog -LogName Ec2ConfigService |
        % { $_.Message.trim() } | 
        sort 
     }
    icm $instance.PublicIpAddress $cmd -Credential $Credential -Port 80 > $log
    notepad $log
}


function SSMAssociate (
    $instance, 
    [string]$DocumentName = 'AWS-RunPowerShellScript',
    [Hashtable]$Parameters,
    [PSCredential] $Credential, 
    [int]$RetrySeconds = 150,
    [boolean]$ClearEventLog = $true)
{
    $instanceId = $instance.InstanceId
    $ipaddress = $instance.PublicIpAddress

    Write-Verbose "SSMAssociate: DocumentName=$DocumentName, InstanceId=$instanceId"

    #Only one association is support per instance at this time
    #Delete the association if it exists.
    $association = Get-SSMAssociationList -AssociationFilterList @{Key='InstanceId'; Value=$instanceId}
    if ($association)
    {
        Write-Verbose "Removing Association DocumentName=$DocumentName, InstanceId=$instanceId"
        Remove-SSMAssociation -InstanceId $association.InstanceId `
            -Name $association.Name -Force
    }

    if ($ClearEventLog) 
    {
        icm $ipaddress {Clear-EventLog -LogName Ec2ConfigService} `
            -Credential $Credential -Port 80
    }
    
    #assocate the document to the instance
    $null = New-SSMAssociation -InstanceId $instance.InstanceId -Name $DocumentName

    #apply config
    $cmd = {& "$env:ProgramFiles\Amazon\Ec2ConfigService\ec2config-cli.exe" -a}
    $null = icm $ipaddress $cmd -Credential $Credential -Port 80

    #Wait for convergence    
    $cmd = {
        $status = (Get-SSMAssociation -InstanceId $instanceid -Name $DocumentName).Status
        Write-Verbose "Association State=$($status.Name)"
        $status.Name -eq 'Success' -or $status.Name -eq 'Failed'
    }
    $null = SSMWait $cmd -Message 'Converge Association' -RetrySeconds $RetrySeconds

    #Output Status
    $status = (Get-SSMAssociation -InstanceId $instanceid -Name $DocumentName).Status
    Write-Verbose "Status=$($status.Name), Message=$($status.Message)"
    if ($status.Name -ne 'Success')
    {
        throw 'SSM Failed'
    }
}



function SSMAssociateOld (
    $instance, 
    [string]$doc, 
    [PSCredential] $Credential, 
    [int]$RetrySeconds = 150,
    [boolean]$ClearEventLog = $true,
    [boolean]$DeleteDocument = $true)
{
    #Only one association is support per instance at this time
    #Delete the association if it exists.
    $association = Get-SSMAssociationList -AssociationFilterList `
                    @{Key='InstanceId'; Value=$instance.instanceid}
    if ($association)
    {
        Remove-SSMAssociation -InstanceId $association.InstanceId `
            -Name $association.Name -Force
        
        if ($DeleteDocument)
        {
            Remove-SSMDocument -Name $association.Name -Force
        }
    }

    $instanceId = $instance.InstanceId
    $ipaddress = $instance.PublicIpAddress

    if ($ClearEventLog) 
    {
        icm $ipaddress {Clear-EventLog -LogName Ec2ConfigService} `
            -Credential $Credential -Port 80
    }
    
    #generate a new document with unique name
    $name = 'doc-' + [Guid]::NewGuid()
    Write-Verbose "Document Name=$name"
    $null = New-SSMDocument -Content $doc -name $name

    #assocate the document to the instance
    $null = New-SSMAssociation -InstanceId $instance.InstanceId -Name $name

    #apply config
    $cmd = {& "$env:ProgramFiles\Amazon\Ec2ConfigService\ec2config-cli.exe" -a}
    $null = icm $ipaddress $cmd -Credential $Credential -Port 80

    #Wait for convergence    
    $cmd = {
        $status = (Get-SSMAssociation -InstanceId $instanceid -Name $name).Status
        $status.Name -eq 'Success' -or $status.Name -eq 'Failed'
    }
    $null = SSMWait $cmd -Message 'Converge Association' `
                -RetrySeconds $RetrySeconds

    #Output Status
    $status = (Get-SSMAssociation -InstanceId $instanceid -Name $name).Status
    Write-Verbose "Status=$($status.Name), Message=$($status.Message)"
    if ($status.Name -ne 'Success')
    {
        throw 'SSM Failed'
    }
}


function SSMGetAssociations ()
{
    foreach ($i in Get-EC2Instance)
    {
        $association = Get-SSMAssociationList -AssociationFilterList `
                        @{Key='InstanceId'; Value=$i.instances[0].instanceid}

        if ($association)
        {
            Get-SSMAssociation -InstanceId $association.InstanceId `
                -Name $association.Name
        }
    }
}
function SSMEnter-PSSession (
        [string]$Tag = $instanceName,
        [string]$KeyName = 'winec2keypair',
        [string]$KeyFile = "c:\keys\$((Get-DefaultAWSRegion).Region).$keyName.pem"
    )
{
    $instance = (Get-EC2Instance -Filter @{Name='tag:Name';Value=$Tag}).Instances[0]

    $password = Get-EC2PasswordData -InstanceId $instance.InstanceId `
                    -PemFile $keyfile -Decrypt 
    $securepassword = ConvertTo-SecureString $Password -AsPlainText -Force
    $creds = New-Object System.Management.Automation.PSCredential ("Administrator", $securepassword)
    Enter-PSSession $instance.PublicIpAddress -Credential $creds -Port 80 
}

function SSMWindowsInstallAgent ([string]$ConnectionUri, [System.Management.Automation.PSCredential]$Credential, [string]$Region, [string]$DefaultInstanceName)
{
    Write-Verbose "ConnectionUri=$ConnectionUri, Region=$Region, DefaultInstanceName=$DefaultInstanceName"
    $code = New-SSMActivation -DefaultInstanceName $DefaultInstanceName -IamRole 'test' -RegistrationLimit 1 –Region $Region
    Write-Verbose "ActivationCode=$($code.ActivationCode), ActivationId=$($code.ActivationId)"

    $sb = {
        param ($Region, $ActivationCode, $ActivationId)

        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Force

        #$source = "https://s3.amazonaws.com/sivaiadbucket/Agent/AmazonSSMAgentSetup.exe"

        $source = "https://amazon-ssm-$region.s3.amazonaws.com/latest/windows_amd64/AmazonSSMAgentSetup.exe"
        $dest = "$($env:TEMP)\AmazonSSMAgentSetup.exe"
        del $dest -ea 0
        $log = "$($env:TEMP)\SSMInstall.log"
        $webclient = New-Object System.Net.WebClient
        $webclient.DownloadFile($source, $dest)

        $a = @('/q', '/log', $log, "CODE=$ActivationCode", "ID=$ActivationId", "REGION=$Region", 'ALLOWEC2INSTALL=YES')
        Start-Process $dest -ArgumentList $a -Wait
        #cat $log
        $st = Get-Content ("$($env:ProgramData)\Amazon\SSM\InstanceData\registration")
        Write-Verbose "ProgramData\Amazon\SSM\InstanceData\registration=$st"
        Write-Verbose (Get-Service -Name "AmazonSSMAgent")
    }

    Invoke-Command -ScriptBlock $sb -ConnectionUri $ConnectionUri -Credential $Credential -ArgumentList @($Region, $code.ActivationCode, $code.ActivationId) -SessionOption (New-PSSessionOption -SkipCACheck)

    Remove-SSMActivation $code.ActivationId -Force -Region $Region

    $filter = @{Key='ActivationIds'; ValueSet=$code.ActivationId}
    $InstanceId = (Get-SSMInstanceInformation -InstanceInformationFilterList $filter -Region $Region).InstanceId
    Write-Verbose "Managed InstanceId=$InstanceId"

    $cmd = { 
        (Get-SSMInstanceInformation -InstanceInformationFilterList @{ Key='InstanceIds'; ValueSet=$instanceid} -Region $Region).Count -eq 1
    }
    $null = Invoke-PSUtilWait $cmd 'Instance Registration' 150

    $instanceId
}

function SSMLinuxInstallAgent ([string]$Key, [string]$User, [string]$remote, [string]$Port = 22, [string]$IAMRole, [string]$Region, [string]$DefaultInstanceName)
{
    Write-Verbose "SSMInstallLinuxAgent:  Key=$Key, User=$User, Remote=$remote, Port=$Port, IAM Role=$IAMRole, SSMRegion=$Region, DefaultInstanceName=$DefaultInstanceName"
    $code = New-SSMActivation -DefaultInstanceName $DefaultInstanceName -IamRole $IAMRole -RegistrationLimit 1 –Region $Region
    Write-Verbose "ActivationCode=$($code.ActivationCode) ActivationId=$($code.ActivationId)"
    $installScript = @"
    mkdir /tmp/ssm 2>&1
    sudo curl https://amazon-ssm-$region.s3.amazonaws.com/latest/debian_amd64/amazon-ssm-agent.deb -o /tmp/ssm/amazon-ssm-agent.deb 2>&1
    sudo dpkg -i /tmp/ssm/amazon-ssm-agent.deb 2>&1
    sudo stop amazon-ssm-agent 2>&1
    sudo amazon-ssm-agent -register -code "$($code.ActivationCode)" -id "$($code.ActivationId)" -region "$region" -y 2>&1
    sudo start amazon-ssm-agent 2>&1
"@
    $output = Invoke-PsUtilSSHCommand -key $key -user $user -remote $remote -port $port -cmd $installScript
    Write-Verbose "sshoutput:`n$output"
   
    $filter = @{Key='ActivationIds'; ValueSet=$code.ActivationId}
    $InstanceId = (Get-SSMInstanceInformation -InstanceInformationFilterList $filter -Region $Region).InstanceId
    Write-Verbose "Managed InstanceId=$InstanceId"

    Remove-SSMActivation $code.ActivationId -Force -Region $Region

    $cmd = { 
        (Get-SSMInstanceInformation -InstanceInformationFilterList @{ Key='InstanceIds'; ValueSet=$instanceid}).Count -eq 1
    }
    $null = Invoke-PSUtilWait $cmd 'Instance Registration' 150

    $instanceId
}

function Get-SSMS3Bucket () {
    $Region = (Get-DefaultAWSRegion).Region
    if ($Region -eq 'us-east-1') {
        $Region = ''
    }
    foreach ($bucket in (Get-S3Bucket)) {
        $location = Get-S3BucketLocation -BucketName $bucket.BucketName
        if ($location.Value -eq $Region) {
            return $bucket.BucketName
        }
    }
}

function Test-SSMOuput (
        $Command,
        $ExpectedMinLength = 100,
        $ExpectedMaxLength = 1000,
        $ExpectedOutput,
        [boolean]$DeleteS3Keys = $true
    )
{
    $commandId = $Command.CommandId
    $bucket = $Command.OutputS3BucketName
    $keyPrefix = $Command.OutputS3KeyPrefix
    
    Write-Verbose "SSMDumpOutput CommandId=$commandId, Bucket=$bucket, Key=$keyPrefix, ExpectedMinLength=$ExpectedMinLength, ExpectedMaxLength=$ExpectedMaxLength"
    foreach ($instanceId in $Command.InstanceIds) {
        $totalOutputLength = 0
        Write-Verbose "InstanceId=$instanceId"
        $global:invocation = Get-SSMCommandInvocation -InstanceId $instanceId `
                        -CommandId $commandId -Details:$true

        $found = $false
        foreach ($plugin in $invocation.CommandPlugins) {
            Write-Verbose "Plugin Name=$($plugin.Name)"
            Write-Verbose "ResponseCode=$($plugin.ResponseCode)"
            Write-Verbose "Plugin Status=$($plugin.Status)"

            $pluginOutput = $plugin.Output
            if ($pluginOutput) {
                $pluginOutput = $pluginOutput.Trim()
            }
            Write-Verbose "Output from plugin:`n$pluginOutput"
            if ($ExpectedOutput -and $pluginOutput -and $pluginOutput.contains($ExpectdOutput)) {
                #Write-Verbose "Found the expected string '$ExpectedOutput' in output"
                $found = $true
            }
            $totalOutputLength += $pluginOutput.Length

        }
        if (! $found -and $ExpectedOutput.Length -gt 0) {
            throw "$ExpectedOutput is not found in the output (Plugin)"
        }

        if ($bucket -and $keyPrefix) {
            $totalOutputLength = 0
            $s3objects = Get-S3Object -BucketName $bucket -Key "$keyPrefix\$commandId\$instanceId\"
            $found = $false
            $tempFile = [System.IO.Path]::GetTempFileName()
            foreach ($s3object in $s3objects)
            {
                if ($s3object.Size -gt 3) 
                {
                    $totalOutputLength += $s3object.Size
                    #Write-Verbose "$bucket\$($s3object.key):"
                    $null = Read-S3Object -BucketName $bucket -Key $s3object.Key -File $tempFile
                    if ($s3object.key.EndsWith('stderr.txt') -or $s3object.key.EndsWith('stderr')) {
                        cat $tempFile -Raw | Write-Error
                    } else {
                        $st = cat $tempFile -Raw 
                        if ($st.Contains($ExpectedOutput)) {
                            #Write-Verbose "S3 Found the expected string '$ExpectedOutput' in output"
                            $found = $true
                        }
                        #Write-Verbose "S3 Output"
                        #$st | Write-Verbose
                    }
                    del $tempFile -Force
                }
                $null = Remove-S3Object -BucketName $bucket -Key $s3object.Key -Force
                
                if ($DeleteS3Keys) {
                    Write-Verbose "Deleting Bucket=$bucket, Key=$($s3object.Key )"
                    $null = Remove-S3Object -BucketName $bucket -Key $s3object.Key -Force
                }
            }
            if (! $found -and $ExpectedOutput.Length -gt 0) {
                throw "$ExpectedOutput is not found in the output (S3)"
            }
        }

        if ($totalOutputLength -lt $ExpectedMinLength) {
            throw "TotalOutputLength=$totalOutputLength is less than ExpectedMinLength=$ExpectedMinLength"
        }
        if ($totalOutputLength -gt $ExpectedMaxLength) {
            throw "TotalOutputLength=$totalOutputLength is greater than ExpectedMaxLength=$ExpectedMaxLength"
        }
        Write-Verbose "TotalOutputLength=$totalOutputLength"
    }
}


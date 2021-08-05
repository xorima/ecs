<#
    .Synopsis
    MYSQL DBDeploy
    Updates a mysql database
    .DESCRIPTION
    This script checks the database for the current latest version
    and applies all versions inbetween that and the latest version
    in the supplied folder
    .PARAMETER Path
    The path to the folder with the sql scripts in it
    .PARAMETER Username
    The username for the MySQL Server
    .PARAMETER Server
    The Server to connect to
    .PARAMETER DatabaseName
    The Name of the database to run against
    .PARAMETER Password
    The password for the MySQL Server
    .NOTES
    Author     : Jason Field - jason@avon-lea.co.uk
    Requires   : PowerShell V3+, InvokeQuery
#>
param
(
    [Parameter(Mandatory)]
    [String]
    [ValidateScript( { Test-Path $_ -PathType 'Container' })]
    $Path,

    [String]
    [Parameter(Mandatory)]
    $Username,

    [String]
    [Parameter(Mandatory)]
    $Server,

    [String]
    [Parameter(Mandatory)]
    $DatabaseName,

    [String]
    [Parameter(Mandatory)]
    $Password
)

<#Assumptions made:
  1. If there is a duplicate script it will just be ignored
  2. All scripts will perform a create, update or delete action
  3. The Version table will hold all versions run on the database in an int format (no leading 0's)
  4. The versionTable is already created when this script runs along with the database in question
  5. All scripts will be stored in UTF8 encoding
  6. It is not expected for someone to create a table called 0
#>

# Static Variables
$module = 'InvokeQuery'
$port = 3306
$databaseVersionQuery = "select COALESCE(MAX(version),0) as 'version' from versionTable"
$extensionFilter = '*.sql'
[regex]$NumbersRegex = '^(\d+)'
$dbVersionSQL = "`r insert into versionTable values({0});"
# Computed Variables
$connectionString = "Server=$server;Database=$DatabaseName;UID=$Username;Password=$Password;SslMode=none"
# Validate All parameters passed in
# Verify the Module is installed on the system
$moduleAvailable = Get-Module $module -ListAvailable
if ($moduleAvailable) {
    Import-Module $module
}
else {
    Write-Error -Message "Cannot import $module, please install from Powershell Gallery (Install-Module -Name $module)" -ErrorAction Stop
}
$moduleAvailable = $null

# Verify the server is listening
$connection = Test-Connection -TargetName $Server -TcpPort $port
if (!($connection)) {
    Write-Error -Message "Cannot connect to $Server on $port, please verify mysql is running and accessible" -ErrorAction Stop
}
$connection = $null

# Verify the Database exists and credentials work
$sql = New-SqlQuery -Sql $databaseVersionQuery
 try {
    $databaseVersionRes = Invoke-MySqlQuery -SqlQuery $sql -ConnectionString $connectionString -ErrorAction Stop
}
catch {
    if ($_ -like '*Access denied*') {
        Write-Verbose $_
        Write-Error -Message 'Invalid username or password' -ErrorAction Stop
    }
    if ($_ -like '*Unknown database*') {
        Write-Verbose $_
        Write-Error -Message 'Invalid database name' -ErrorAction Stop
    }
    else {
        write-output $_.exception
        Write-Error $_ -ErrorAction Stop
    }
}
$databaseVersion = $databaseVersionRes.version
$currentDatabaseVersion = $databaseVersion
$databaseVersionRes = $null

Write-Output "Database version: $databaseVersion"

# get all applicable scripts
$sqlScripts = Get-ChildItem -Path $Path -Filter $extensionFilter
foreach ($sqlScript in $sqlScripts) {
    $Matches = $null
    $matchCheck = $sqlScript.Name -match $NumbersRegex
    # Check they start with a number, if they do and are newer than current version add sql to script to migration script
    # Check as well that they are not a duplicate number
    if ($matchCheck -and [int]$Matches[0] -gt $databaseVersion -and [int]$Matches[0] -ne $currentDatabaseVersion ) {
        # get file contents for sql and ensure it ends with ;
        $content = (Get-Content ($sqlScript.FullName) -Encoding UTF8).Trim()

        Write-Verbose "Starting migration script: $($sqlScript.name)"
        # Write every script into the version table incase there is an error
        $migrationSQLScript = "START TRANSACTION; `r"
        $migrationSQLScript += $content
        $migrationSQLScript += $dbVersionSQL -f $Matches[0]
        $migrationSQLScript += " COMMIT;"

        try {
            $databaseVersionRes = Invoke-MySqlQuery -Sql $migrationSQLScript -ConnectionString $connectionString -CUD -ErrorAction Stop
        }
        catch {
            Write-Error -Message "Error found with Migration: $($_.Message)" -ErrorAction Stop
        }
        $currentDatabaseVersion = [int]$Matches[0]

    }
}

$sql = New-SqlQuery -Sql $databaseVersionQuery
$databaseVersionRes = Invoke-MySqlQuery -SqlQuery $sql -ConnectionString $connectionString
$newDatabaseVersion = $databaseVersionRes.version
$databaseVersionRes = $null

Write-Output "Database $DatabaseName migrated on $server from $databaseVersion to $newDatabaseVersion"

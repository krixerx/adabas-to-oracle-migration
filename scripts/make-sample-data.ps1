# Fallback level 2 / test fixtures: writes simulated Adabas-shaped CSVs that obey
# FLAT_FILE_CONTRACT.md exactly (BOM-less UTF-8, RFC 4180, empty = NULL), plus
# manifest.json. Deliberately exercises: MU/PE occurrences, YYYYMMDD dates,
# lookup codes (incl. one unknown code), a quoted comma in a name, a NULL field,
# and one vehicle whose personnel_id has no matching employee (orphan -> EMP_ID NULL).
$ErrorActionPreference = "Stop"
$pocRoot = Split-Path $PSScriptRoot -Parent
$dataDir = Join-Path $pocRoot "data"
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory $dataDir | Out-Null }
$utf8 = New-Object System.Text.UTF8Encoding($false)

$employees = @(
    'isn,personnel_id,first_name,middle_name,last_name,mar_stat,sex,birth_yyyymmdd,city,postal_code,country,dept,job_title'
    '101,50005000,ANNA,,KASK,M,F,19750312,TALLINN,10111,EST,ADMN01,SECRETARY'
    '102,50005100,PEETER,JAAN,TAMM,S,M,19820724,TARTU,51004,EST,TECH02,ANALYST'
    '103,50005200,MARI,,"SAAR, JR",D,F,19680101,PARNU,80010,EST,TECH02,PROGRAMMER'
    '104,50005300,JURI,K,METS,W,M,19550930,NARVA,20308,EST,MGMT01,MANAGER'
    '105,50005400,LIISA,,KUUSK,X,F,19910215,VILJANDI,71003,EST,ADMN01,CLERK'
)
$addressLines = @(
    'parent_key,occurrence_index,address_line'
    '101,1,PIKK 12-4'
    '101,2,KESKLINNA LINNAOSA'
    '102,1,RIIA MNT 5'
    '103,1,"MERE PST 1, KORTER 2"'
    '103,2,KESKLINN'
    '104,1,PETERBURI TEE 8'
    '105,1,TARTU TN 3'
)
$languages = @(
    'parent_key,occurrence_index,language_code'
    '101,1,EST'
    '101,2,ENG'
    '102,1,EST'
    '102,2,RUS'
    '102,3,ENG'
    '103,1,EST'
    '104,1,EST'
    '104,2,GER'
    '105,1,EST'
)
$income = @(
    'parent_key,occurrence_index,currency_code,salary_amount'
    '101,1,EUR,28000'
    '101,2,EEK,180000'
    '102,1,EUR,42000'
    '103,1,EUR,51000'
    '104,1,EUR,64000'
    '104,2,EEK,410000'
    '105,1,EUR,'
)
$vehicles = @(
    'isn,reg_num,personnel_id,make,model,color,year_built'
    '201,123ABC,50005000,SKODA,OCTAVIA,BLUE,2019'
    '202,456DEF,50005200,TOYOTA,COROLLA,WHITE,2021'
    '203,789GHI,50005300,VOLVO,V60,BLACK,2017'
    '204,321XYZ,99999999,LADA,NIVA,RED,1995'
)

$files = [ordered]@{
    "employees.csv"               = $employees
    "employees_address_lines.csv" = $addressLines
    "employees_languages.csv"     = $languages
    "employees_income.csv"        = $income
    "vehicles.csv"                = $vehicles
}
$counts = [ordered]@{}
foreach ($name in $files.Keys) {
    $path = Join-Path $dataDir $name
    [System.IO.File]::WriteAllLines($path, $files[$name], $utf8)
    $counts[$name] = $files[$name].Count - 1
    Write-Host ("  {0,-30} {1} rows" -f $name, $counts[$name])
}

$manifest = [ordered]@{
    extracted_at = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    source       = "make-sample-data.ps1 (SIMULATED - fallback level 2, not real Adabas)"
    files        = $counts
}
[System.IO.File]::WriteAllText((Join-Path $dataDir "manifest.json"), ($manifest | ConvertTo-Json), $utf8)
Write-Host "  manifest.json written. Source marked SIMULATED."
exit 0

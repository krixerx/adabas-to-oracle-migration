# Fallback level 2 / test fixtures: writes simulated Adabas-shaped CSVs that obey
# FLAT_FILE_CONTRACT.md exactly (BOM-less UTF-8, RFC 4180, empty = NULL), plus
# manifest.json. Deliberately exercises, in miniature, everything the real data does:
#   - the legacy multi-plate workaround (4 vehicles across 9 rows -> 8 plates,
#     plus one fourth plate that must be rejected);
#   - a custom vehicle type ('X-OLD') absent from VEHICLE_TYPE_MAP;
#   - fines raised against a suffixed plate, against the REJECTED fourth plate,
#     and against a plate belonging to no vehicle at all;
#   - MU offence codes and PE part payments, including a fine with neither;
#   - a quoted comma in a text field;
#   - all four powertrain paths: derived from the VIN (202, a Ford), derived
#     from the free-text fuel field (201, 204), left UNKNOWN (203), and one
#     where the VIN CONTRADICTS the text (202 again - VIN says hybrid, the
#     clerk typed PETROL).
$ErrorActionPreference = "Stop"
$pocRoot = Split-Path $PSScriptRoot -Parent
$dataDir = Join-Path $pocRoot "data"
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory $dataDir | Out-Null }
$utf8 = New-Object System.Text.UTF8Encoding($false)

# VINs are exactly 17 characters; anything past that is the legacy suffix, so
# 205/206 are the same car as 201 and 207/208/209 the same car as 203. Each carries a
# genuinely DIFFERENT plate - that is the point of the workaround - and 209 is a fourth
# plate, so it must end up in MIGRATION_REJECT.
$vehicles = @(
    'isn,plate_no,personnel_id,make,model,color,year_built,vin,veh_type,fuel_desc'
    '201,123ABC,50005000,SKODA,OCTAVIA,BLUE,2019,SKOZZ1JZW00000201,SEDAN,PLUG-IN HYBRID'
    '205,90000201,50005000,SKODA,OCTAVIA,BLUE,2019,SKOZZ1JZW000002011,SEDAN,PLUG-IN HYBRID'
    '206,90000202,50005000,SKODA,OCTAVIA,BLUE,2019,SKOZZ1JZW000002012,SEDAN,PLUG-IN HYBRID'
    '202,456DEF,50005200,FORD,FOCUS,WHITE,2021,FORZH1JZW00000202,HATCH,PETROL'
    '203,789GHI,50005300,VOLVO,V60,BLACK,2017,VOLZZ1JZW00000203,ESTATE,N/A'
    '207,90000203,50005300,VOLVO,V60,BLACK,2017,VOLZZ1JZW000002031,ESTATE,N/A'
    '208,90000204,50005300,VOLVO,V60,BLACK,2017,VOLZZ1JZW000002032,ESTATE,N/A'
    '209,90000205,50005300,VOLVO,V60,BLACK,2017,VOLZZ1JZW000002033,ESTATE,N/A'
    '204,321XYZ,99999999,LADA,NIVA,RED,1995,LADZZ1JZW00000204,X-OLD,BENZIN'
)
# Fine 305 is on '90000202' - the car's SECOND plate, so it must resolve to the SAME
# vehicle as 301. Fine 306 is on '789GHI-3', the plate rejected as a fourth plate,
# so it cannot resolve - the cascade. Fine 307 is on a plate that never existed.
$fines = @(
    'isn,fine_no,plate_no,offence_yyyymmdd,location,amount,status,offender_national_id'
    '301,F000000301,123ABC,20240115,"MUSCAT EXPRESSWAY, KM 12",25.00,P,50005000'
    '302,F000000302,456DEF,20240220,AL KHUWAIR R/A,40.00,I,50005200'
    '303,F000000303,789GHI,20240305,NIZWA HIGHWAY,55.00,P,50005300'
    '304,F000000304,321XYZ,20240410,SOHAR PORT RD,70.00,C,99999999'
    '305,F000000305,90000202,20240512,SALALAH CORNICHE,85.00,A,50005000'
    '306,F000000306,90000205,20240618,SULTAN QABOOS ST,100.00,I,50005300'
    '307,F000000307,FGN00001,20240722,SULTAN QABOOS ST,115.00,P,99999999'
)
$offences = @(
    'parent_key,occurrence_index,offence_code'
    '301,1,SPD1'
    '302,1,SPD2'
    '302,2,MOBP'
    '303,1,RLGT'
    '304,1,PARK'
    '305,1,SBLT'
    '305,2,MOBP'
    '305,3,SPD1'
    '306,1,SPD1'
    '307,1,SPD2'
)
# Only the paid fines (301, 303, 307) have payments; 303 was paid in two parts.
$payments = @(
    'parent_key,occurrence_index,paid_yyyymmdd,paid_amount,payment_method'
    '301,1,20240120,25.00,CA'
    '303,1,20240310,30.00,CC'
    '303,2,20240402,25.00,BT'
    '307,1,20240801,115.00,BT'
)

$files = [ordered]@{
    "vehicles.csv"              = $vehicles
    "traffic_fines.csv"         = $fines
    "traffic_fine_offences.csv" = $offences
    "traffic_fine_payments.csv" = $payments
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

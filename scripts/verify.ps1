#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$root = Split-Path -Parent $PSScriptRoot
$project = "outbox-verify-$([guid]::NewGuid().ToString('N').Substring(0, 12))"
$composeArgs = @('--project-name', $project, '-f', "$root/compose.yaml", '-f', "$PSScriptRoot/compose.verify.yaml")
$originalPort = $env:OUTBOX_API_PORT
$crashContainer = $null
$scenario = 'setup'

function Invoke-Compose {
    docker compose @composeArgs @args
    if ($LASTEXITCODE -ne 0) { throw "docker compose $args exited with code $LASTEXITCODE" }
}

function Assert-That($Condition, $Message) {
    if (-not $Condition) { throw $Message }
}

function Wait-For($Description, [scriptblock]$Probe) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $result = & $Probe
        if ($result) { return $result }
        Start-Sleep -Milliseconds 500
    } while ($timer.Elapsed.TotalSeconds -lt 60)
    throw "Timed out waiting for $Description"
}

function Read-Sql($Database, $Sql) {
    Invoke-Compose exec -T postgres psql -X -qAt -v ON_ERROR_STOP=1 -U outbox -d $Database -c $Sql
}

function Get-OrderCounts($Sku) {
    Read-Sql orders @"
        SELECT (SELECT count(*) FROM orders WHERE sku = '$Sku'),
               (SELECT count(*) FROM outbox_events WHERE sku = '$Sku');
"@
}

function Get-Outbox([guid]$EventId) {
    Read-Sql orders @"
        SELECT json_build_object('orderId', order_id, 'attempts', attempt_count,
                                 'delivered', delivered_at IS NOT NULL)
        FROM outbox_events WHERE event_id = '$EventId';
"@ | ConvertFrom-Json
}

function Get-ShipmentIds([guid]$EventId) {
    Read-Sql shipping "SELECT id FROM shipments WHERE event_id = '$EventId'"
}

function Submit-Order($Body) {
    Invoke-WebRequest "$api/orders" -Method Post -ContentType 'application/json' -Body $Body -TimeoutSec 10 -SkipHttpErrorCheck
}

function New-Order($Sku, [int]$Quantity) {
    $response = Submit-Order (@{ sku = $Sku; quantity = $Quantity } | ConvertTo-Json -Compress)
    Assert-That ($response.StatusCode -eq 201) "Expected HTTP 201 for $Sku, got $($response.StatusCode)"
    $order = $response.Content | ConvertFrom-Json
    Assert-That (([guid]$order.orderId -ne [guid]::Empty) -and ([guid]$order.eventId -ne [guid]::Empty)) 'Missing order or event ID'
    return $order
}

try {
    $env:OUTBOX_API_PORT = '0'
    Write-Host "Compose project $project"
    Invoke-Compose build api
    Invoke-Compose up -d postgres api
    $api = "http://$(Invoke-Compose port api 8080)"
    $null = Wait-For 'orders API readiness' {
        try {
            $result = Invoke-WebRequest "$api/orders/$([guid]::Empty)" -TimeoutSec 2 -SkipHttpErrorCheck
            $result.StatusCode -eq 404
        } catch [System.Net.Http.HttpRequestException], [System.Threading.Tasks.TaskCanceledException] {
            $false
        }
    }

    $scenario = '1. Rollback'
    Read-Sql orders "ALTER TABLE outbox_events ADD CONSTRAINT verify_rollback_sku CHECK (sku <> 'rollback-probe')"
    try {
        $failure = Submit-Order '{"sku":"rollback-probe","quantity":1}'
        $counts = Get-OrderCounts 'rollback-probe'
        $apiLogs = Invoke-Compose logs --no-color api
        Assert-That ($failure.StatusCode -eq 500) 'Expected HTTP 500 from the failed outbox insert'
        Assert-That ($apiLogs -match 'violates check constraint "verify_rollback_sku"') 'The injected outbox constraint did not reject the write'
        Assert-That ($counts -eq '0|0') "Expected zero orders and events, got $counts"
        Write-Host 'PASS 1 Rollback | outbox constraint rejected write | HTTP 500 | orders=0 | events=0'
    } finally {
        Read-Sql orders 'ALTER TABLE outbox_events DROP CONSTRAINT verify_rollback_sku'
    }

    $scenario = '2. Retry after shipping recovers'
    Invoke-Compose up -d worker
    Assert-That ((Invoke-Compose ps --status running --services) -notcontains 'shipping') 'Shipping must be down'
    $first = New-Order 'retry-probe' 1
    $firstId = [guid]$first.eventId
    $pending = Wait-For 'failed HTTP attempt while shipping is down' {
        $logs = Invoke-Compose logs --no-color worker
        if ($logs -match "eventId=$firstId attempt=\d+ delivery failed:") { Get-Outbox $firstId }
    }
    $counts = Get-OrderCounts 'retry-probe'
    $shipments = @(Get-ShipmentIds $firstId)
    Assert-That ($counts -eq '1|1' -and $pending.orderId -eq $first.orderId -and $pending.attempts -ge 1 -and -not $pending.delivered -and $shipments.Count -eq 0) 'Expected a persisted order and a pending event with no shipment'
    Write-Host "  Offline | order=$($first.orderId) | event=$firstId | attempts=$($pending.attempts) | delivered=false | orders=1 | events=1 | shipments=0"

    Invoke-Compose up -d shipping
    $delivered = Wait-For 'the original event to be marked delivered' {
        $state = Get-Outbox $firstId
        if ($state.delivered) { $state }
    }
    $counts = Get-OrderCounts 'retry-probe'
    $shipments = @(Get-ShipmentIds $firstId)
    $shippedOrder = Read-Sql shipping "SELECT order_id FROM shipments WHERE event_id = '$firstId'"
    Assert-That ($counts -eq '1|1' -and $delivered.orderId -eq $first.orderId -and $delivered.attempts -gt $pending.attempts -and $shipments.Count -eq 1 -and $shippedOrder -eq $first.orderId) 'Recovery did not deliver the original event once without another order'
    Write-Host "PASS 2 Retry | event=$firstId | attempts=$($delivered.attempts) | delivered=true | orders=1 | events=1 | shipments=1"

    $scenario = '3. Worker crash after shipping acknowledges'
    Invoke-Compose stop worker
    $second = New-Order 'crash-probe' 2
    $secondId = [guid]$second.eventId
    Assert-That ((Get-Outbox $secondId).attempts -eq 0) 'The regular worker picked up the crash experiment event'
    $crashContainer = Invoke-Compose run --detach --no-deps -e OUTBOX_CRASH_AFTER_DELIVERY=true worker
    $null = Wait-For 'the fault worker to exit' {
        (docker inspect --format '{{.State.Status}}' $crashContainer) -eq 'exited'
    }
    $exitCode = docker inspect --format '{{.State.ExitCode}}' $crashContainer
    $crashLogs = docker logs $crashContainer
    $beforeReplay = Get-Outbox $secondId
    $originalShipment = @(Get-ShipmentIds $secondId)
    Assert-That ($exitCode -eq '42' -and $crashLogs -match "eventId=$secondId attempt=1 acknowledged" -and -not $beforeReplay.delivered -and $beforeReplay.attempts -eq 1 -and $originalShipment.Count -eq 1) 'Expected shipping to commit before the worker halted with a pending outbox row'
    Write-Host "  Crash | exit=$exitCode | event=$secondId | attempts=1 | delivered=false | shipment=$($originalShipment[0])"
    docker rm $crashContainer | Out-Null
    Assert-That ($LASTEXITCODE -eq 0) 'Could not remove the stopped fault worker'
    $crashContainer = $null

    Invoke-Compose up -d worker
    $replayed = Wait-For 'the crash event to be marked delivered' {
        $state = Get-Outbox $secondId
        if ($state.delivered) { $state }
    }
    $shippingLogs = Invoke-Compose logs --no-color shipping
    $afterReplay = @(Get-ShipmentIds $secondId)
    Assert-That ($replayed.attempts -eq 2 -and $shippingLogs -match "eventId=$secondId duplicate acknowledged" -and $afterReplay.Count -eq 1 -and $afterReplay[0] -eq $originalShipment[0]) 'Expected the same event to be acknowledged again with one original shipment'
    Write-Host "PASS 3 Crash and replay | event=$secondId | attempts=2 | delivered=true | shipments=1 | same shipment=$($afterReplay[0])"

    $scenario = 'Concurrent delivery to shipping'
    $shipping = "http://$(Invoke-Compose port shipping 8080)/events/order-created"
    $concurrentId = [guid]::NewGuid()
    $payload = @{
        eventId = $concurrentId
        orderId = [guid]::NewGuid()
        sku = 'concurrent-probe'
        quantity = 1
        createdAt = [DateTimeOffset]::UtcNow.ToString('o')
    } | ConvertTo-Json -Compress
    $client = [System.Net.Http.HttpClient]::new()
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(15)
        $requests = 1..8 | ForEach-Object {
            $body = [System.Net.Http.StringContent]::new($payload, [Text.Encoding]::UTF8, 'application/json')
            $client.PostAsync($shipping, $body)
        }
        foreach ($request in $requests) {
            $response = $request.GetAwaiter().GetResult()
            try { Assert-That ([int]$response.StatusCode -eq 204) 'A concurrent delivery did not return HTTP 204' }
            finally { $response.Dispose() }
        }
    } finally {
        $client.Dispose()
    }
    Assert-That (@(Get-ShipmentIds $concurrentId).Count -eq 1) 'Concurrent requests created more or fewer than one shipment'
    Write-Host "PASS Concurrent delivery | event=$concurrentId | 8 responses=204 | shipments=1"

    $scenario = 'Order API regressions'
    $fractional = Submit-Order '{"sku":"fraction-probe","quantity":1.9}'
    Assert-That ($fractional.StatusCode -eq 400 -and (Get-OrderCounts 'fraction-probe') -eq '0|0') 'Expected fractional quantity to be rejected before persistence'
    Read-Sql orders "DELETE FROM outbox_events WHERE event_id = '$firstId' AND delivered_at IS NOT NULL"
    $order = Invoke-RestMethod "$api/orders/$($first.orderId)" -TimeoutSec 10
    Assert-That ($order.orderId -eq $first.orderId -and $order.sku -eq 'retry-probe' -and $order.quantity -eq 1 -and (Get-OrderCounts 'retry-probe') -eq '1|0') 'The persisted order became unreadable after its delivered event was removed'
    Write-Host 'PASS Order API | fractional quantity=400 and zero writes | GET after outbox removal=200'
} catch {
    Write-Host "FAIL $scenario | $($_.Exception.Message)"
    if ($crashContainer) { docker logs --tail 30 $crashContainer }
    docker compose @composeArgs logs --no-color --tail 30
    throw
} finally {
    try {
        if ($crashContainer) { docker rm -f $crashContainer | Out-Null }
        Invoke-Compose down --volumes
    } finally {
        $env:OUTBOX_API_PORT = $originalPort
    }
}

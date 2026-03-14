$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

$Image = if ($env:IMAGE) { $env:IMAGE } else { "a75g/docker-db-backup:ci" }
$Net = if ($env:NET) { $env:NET } else { "dbbackup-ci-net" }
$TmpRoot = if ($env:TMP_ROOT) { $env:TMP_ROOT } elseif ($env:RUNNER_TEMP) { Join-Path $env:RUNNER_TEMP "dbbackup-ci" } else { Join-Path ([System.IO.Path]::GetTempPath()) "dbbackup-ci" }

$PgBackupDir = Join-Path $TmpRoot "pg"
$MysqlBackupDir = Join-Path $TmpRoot "mysql"
$RedisBackupDir = Join-Path $TmpRoot "redis"
$MongoBackupDir = Join-Path $TmpRoot "mongo"
$SqliteBackupDir = Join-Path $TmpRoot "sqlite"
$S3SrcBackupDir = Join-Path $TmpRoot "s3src"

New-Item -ItemType Directory -Force -Path $PgBackupDir, $MysqlBackupDir, $RedisBackupDir, $MongoBackupDir, $SqliteBackupDir, $S3SrcBackupDir | Out-Null

function Invoke-Docker {
    param(
        [object[]]$DockerArgs
    )

    if ($DockerArgs.Count -eq 1 -and $DockerArgs[0] -is [System.Array]) {
        $DockerArgs = [object[]]$DockerArgs[0]
    }

    & docker @DockerArgs
    if ($LASTEXITCODE -ne 0) {
        throw "docker command failed: docker $($DockerArgs -join ' ')"
    }
}

function Wait-Until {
    param(
        [scriptblock]$Condition,
        [int]$Attempts = 60,
        [int]$SleepSeconds = 2,
        [string]$Description = "condition"
    )

    for ($i = 0; $i -lt $Attempts; $i++) {
        if (& $Condition) {
            return
        }
        Start-Sleep -Seconds $SleepSeconds
    }

    throw "Timed out waiting for $Description"
}

function Cleanup {
    $containers = @(
        "dbbackup-pg", "pg18-ci",
        "dbbackup-mysql", "mysql8-ci",
        "dbbackup-redis", "redis7-ci",
        "dbbackup-mongo", "mongo7-ci",
        "dbbackup-sqlite",
        "dbbackup-s3",
        "minio-ci"
    )

    foreach ($container in $containers) {
        cmd /c "docker rm -f $container >nul 2>nul" | Out-Null
    }
    cmd /c "docker network rm $Net >nul 2>nul" | Out-Null
}

try {
    Cleanup
    Invoke-Docker -DockerArgs @("network", "create", $Net) | Out-Null

    Write-Host "=== PostgreSQL 18 backup + restore smoke ==="
    Invoke-Docker -DockerArgs @("run", "-d", "--name", "pg18-ci", "--network", $Net,
        "-e", "POSTGRES_PASSWORD=postgres",
        "-e", "POSTGRES_DB=testdb",
        "postgres:18") | Out-Null

    Wait-Until -Description "PostgreSQL readiness" -Condition {
        & docker exec pg18-ci pg_isready -U postgres *> $null
        $LASTEXITCODE -eq 0
    }

    Invoke-Docker -DockerArgs @("exec", "pg18-ci", "psql", "-U", "postgres", "-d", "testdb", "-c", "CREATE TABLE IF NOT EXISTS ci_items(id int primary key, val text);") | Out-Null
    Invoke-Docker -DockerArgs @("exec", "pg18-ci", "psql", "-U", "postgres", "-d", "testdb", "-c", "TRUNCATE ci_items;") | Out-Null
    Invoke-Docker -DockerArgs @("exec", "pg18-ci", "psql", "-U", "postgres", "-d", "testdb", "-c", "INSERT INTO ci_items VALUES (1,'one'),(2,'two');") | Out-Null

    Invoke-Docker -DockerArgs @("run", "-d", "--name", "dbbackup-pg", "--network", $Net,
        "-v", "${PgBackupDir}:/backup",
        "-e", "MODE=MANUAL",
        "-e", "CONTAINER_ENABLE_SCHEDULING=FALSE",
        "-e", "MANUAL_RUN_FOREVER=TRUE",
        "-e", "DB01_TYPE=pgsql",
        "-e", "DB01_NAME=testdb",
        "-e", "DB01_HOST=pg18-ci",
        "-e", "DB01_USER=postgres",
        "-e", "DB01_PASS=postgres",
        "-e", "DB01_PORT=5432",
        "-e", "DB01_BACKUP_LOCATION=FILESYSTEM",
        $Image) | Out-Null

    Start-Sleep -Seconds 10
    Invoke-Docker -DockerArgs @("exec", "dbbackup-pg", "backup-now") | Out-Null

    $pgFile = (& docker exec dbbackup-pg sh -lc "ls -1 /backup/pgsql_testdb_pg18-ci_*.sql.zst | head -n1 | xargs -n1 basename").Trim()
    if (-not $pgFile) { throw "PostgreSQL backup file not found" }

    Invoke-Docker -DockerArgs @("exec", "pg18-ci", "psql", "-U", "postgres", "-d", "postgres", "-c", "DROP DATABASE IF EXISTS restoredb;") | Out-Null
    Invoke-Docker -DockerArgs @("exec", "pg18-ci", "psql", "-U", "postgres", "-d", "postgres", "-c", "CREATE DATABASE restoredb;") | Out-Null
    Invoke-Docker -DockerArgs @("exec", "dbbackup-pg", "restore", "/backup/$pgFile", "pgsql", "pg18-ci", "restoredb", "postgres", "postgres", "5432") | Out-Null
    $pgCount = (& docker exec pg18-ci psql -U postgres -d restoredb -tAc "SELECT COUNT(*) FROM ci_items;").Trim()
    if ($pgCount -ne "2") { throw "Unexpected PostgreSQL restore count: $pgCount" }

    Write-Host "=== MySQL 8 backup + restore smoke ==="
    Invoke-Docker -DockerArgs @("run", "-d", "--name", "mysql8-ci", "--network", $Net,
        "-e", "MYSQL_ROOT_PASSWORD=rootpass",
        "-e", "MYSQL_DATABASE=appdb",
        "mysql:8") | Out-Null

    Wait-Until -Attempts 90 -Description "MySQL readiness" -Condition {
        & docker exec mysql8-ci sh -lc "mysqladmin ping -h 127.0.0.1 -uroot -prootpass --silent >/dev/null 2>&1"
        $LASTEXITCODE -eq 0
    }

    Invoke-Docker -DockerArgs @("exec", "mysql8-ci", "mysql", "-uroot", "-prootpass", "-e", "CREATE DATABASE IF NOT EXISTS appdb; USE appdb; CREATE TABLE IF NOT EXISTS ci_items(id INT PRIMARY KEY, val VARCHAR(20)); TRUNCATE ci_items; INSERT INTO ci_items VALUES (1,'one'),(2,'two');") | Out-Null

    Invoke-Docker -DockerArgs @("run", "-d", "--name", "dbbackup-mysql", "--network", $Net,
        "-v", "${MysqlBackupDir}:/backup",
        "-e", "MODE=MANUAL",
        "-e", "CONTAINER_ENABLE_SCHEDULING=FALSE",
        "-e", "MANUAL_RUN_FOREVER=TRUE",
        "-e", "DB01_TYPE=mysql",
        "-e", "DB01_NAME=appdb",
        "-e", "DB01_HOST=mysql8-ci",
        "-e", "DB01_USER=root",
        "-e", "DB01_PASS=rootpass",
        "-e", "DB01_PORT=3306",
        "-e", "DB01_BACKUP_LOCATION=FILESYSTEM",
        $Image) | Out-Null

    Start-Sleep -Seconds 10
    Invoke-Docker -DockerArgs @("exec", "dbbackup-mysql", "backup-now") | Out-Null

    $mysqlFile = (& docker exec dbbackup-mysql sh -lc "ls -1 /backup/mariadb_appdb_mysql8-ci_*.sql.zst | head -n1 | xargs -n1 basename").Trim()
    if (-not $mysqlFile) { throw "MySQL backup file not found" }

    Invoke-Docker -DockerArgs @("exec", "mysql8-ci", "mysql", "-uroot", "-prootpass", "-e", "DROP DATABASE IF EXISTS restoredb; CREATE DATABASE restoredb;") | Out-Null
    Invoke-Docker -DockerArgs @("exec", "dbbackup-mysql", "restore", "/backup/$mysqlFile", "mysql", "mysql8-ci", "restoredb", "root", "rootpass", "3306", "false") | Out-Null
    $mysqlCount = (& docker exec mysql8-ci mysql -N -uroot -prootpass -e "SELECT COUNT(*) FROM restoredb.ci_items;").Trim()
    if ($mysqlCount -ne "2") { throw "Unexpected MySQL restore count: $mysqlCount" }

    Write-Host "=== Redis 7 backup smoke ==="
    Invoke-Docker -DockerArgs @("run", "-d", "--name", "redis7-ci", "--network", $Net, "redis:7") | Out-Null
    Start-Sleep -Seconds 5
    Invoke-Docker -DockerArgs @("exec", "redis7-ci", "redis-cli", "SET", "ci_key", "ci_value") | Out-Null

    Invoke-Docker -DockerArgs @("run", "-d", "--name", "dbbackup-redis", "--network", $Net,
        "-v", "${RedisBackupDir}:/backup",
        "-e", "MODE=MANUAL",
        "-e", "CONTAINER_ENABLE_SCHEDULING=FALSE",
        "-e", "MANUAL_RUN_FOREVER=TRUE",
        "-e", "DB01_TYPE=redis",
        "-e", "DB01_NAME=ALL",
        "-e", "DB01_HOST=redis7-ci",
        "-e", "DB01_PORT=6379",
        "-e", "DB01_BACKUP_LOCATION=FILESYSTEM",
        $Image) | Out-Null

    Start-Sleep -Seconds 10
    Invoke-Docker -DockerArgs @("exec", "dbbackup-redis", "backup-now") | Out-Null
    Invoke-Docker -DockerArgs @("exec", "dbbackup-redis", "sh", "-lc", "ls -1 /backup/redis_all_redis7-ci_*.rdb.zst >/dev/null") | Out-Null

    Write-Host "=== MongoDB 7 backup smoke ==="
    Invoke-Docker -DockerArgs @("run", "-d", "--name", "mongo7-ci", "--network", $Net, "mongo:7") | Out-Null

    Wait-Until -Description "MongoDB readiness" -Condition {
        & docker exec mongo7-ci mongosh --quiet --eval "db.runCommand({ping:1}).ok" *> $null
        $LASTEXITCODE -eq 0
    }

    Invoke-Docker -DockerArgs @("exec", "mongo7-ci", "mongosh", "--quiet", "--eval", "db.getSiblingDB('appdb').ci.insertOne({id:1,val:'one'})") | Out-Null

    Invoke-Docker -DockerArgs @("run", "-d", "--name", "dbbackup-mongo", "--network", $Net,
        "-v", "${MongoBackupDir}:/backup",
        "-e", "MODE=MANUAL",
        "-e", "CONTAINER_ENABLE_SCHEDULING=FALSE",
        "-e", "MANUAL_RUN_FOREVER=TRUE",
        "-e", "DB01_TYPE=mongo",
        "-e", "DB01_NAME=appdb",
        "-e", "DB01_HOST=mongo7-ci",
        "-e", "DB01_PORT=27017",
        "-e", "DB01_BACKUP_LOCATION=FILESYSTEM",
        $Image) | Out-Null

    Start-Sleep -Seconds 10
    Invoke-Docker -DockerArgs @("exec", "dbbackup-mongo", "backup-now") | Out-Null
    Invoke-Docker -DockerArgs @("exec", "dbbackup-mongo", "sh", "-lc", "ls -1 /backup/mongo_appdb_mongo7-ci_*.archive.gz >/dev/null") | Out-Null

    Write-Host "=== SQLite backup smoke ==="
    @"
CREATE TABLE IF NOT EXISTS t(i INTEGER);
INSERT INTO t VALUES (1);
"@ | Set-Content -NoNewline -Path (Join-Path $SqliteBackupDir "init.sql")

    Invoke-Docker -DockerArgs @("run", "--rm", "--entrypoint", "sh", "-v", "${SqliteBackupDir}:/data", $Image, "-lc", "sqlite3 /data/app.db < /data/init.sql") | Out-Null

    Invoke-Docker -DockerArgs @("run", "-d", "--name", "dbbackup-sqlite", "--network", $Net,
        "-v", "${SqliteBackupDir}:/data",
        "-v", "${SqliteBackupDir}:/backup",
        "-e", "MODE=MANUAL",
        "-e", "CONTAINER_ENABLE_SCHEDULING=FALSE",
        "-e", "MANUAL_RUN_FOREVER=TRUE",
        "-e", "DB01_TYPE=sqlite3",
        "-e", "DB01_HOST=/data/app.db",
        "-e", "DB01_NAME=appdb",
        "-e", "DB01_BACKUP_LOCATION=FILESYSTEM",
        $Image) | Out-Null

    Start-Sleep -Seconds 10
    Invoke-Docker -DockerArgs @("exec", "dbbackup-sqlite", "backup-now") | Out-Null
    Invoke-Docker -DockerArgs @("exec", "dbbackup-sqlite", "sh", "-lc", "ls -1 /backup/sqlite3_appdb_*.sqlite3.zst >/dev/null") | Out-Null

    Write-Host "=== S3/MinIO backup smoke ==="
    Invoke-Docker -DockerArgs @("run", "-d", "--name", "minio-ci", "--network", $Net,
        "-e", "MINIO_ROOT_USER=minio",
        "-e", "MINIO_ROOT_PASSWORD=minio123",
        "minio/minio", "server", "/data") | Out-Null

    Wait-Until -Description "MinIO readiness" -Condition {
        & docker run --rm --network $Net -e MC_HOST_local=http://minio:minio123@minio-ci:9000 minio/mc ls local *> $null
        $LASTEXITCODE -eq 0
    }

    Invoke-Docker -DockerArgs @("run", "--rm", "--network", $Net, "-e", "MC_HOST_local=http://minio:minio123@minio-ci:9000", "minio/mc", "mb", "--ignore-existing", "local/backups") | Out-Null

    @"
CREATE TABLE IF NOT EXISTS t(i INTEGER);
INSERT INTO t VALUES (1);
"@ | Set-Content -NoNewline -Path (Join-Path $S3SrcBackupDir "init.sql")

    Invoke-Docker -DockerArgs @("run", "--rm", "--entrypoint", "sh", "-v", "${S3SrcBackupDir}:/data", $Image, "-lc", "sqlite3 /data/s3.db < /data/init.sql") | Out-Null

    Invoke-Docker -DockerArgs @("run", "-d", "--name", "dbbackup-s3", "--network", $Net,
        "-v", "${S3SrcBackupDir}:/data",
        "-e", "MODE=MANUAL",
        "-e", "CONTAINER_ENABLE_SCHEDULING=FALSE",
        "-e", "MANUAL_RUN_FOREVER=TRUE",
        "-e", "DB01_TYPE=sqlite3",
        "-e", "DB01_HOST=/data/s3.db",
        "-e", "DB01_NAME=s3db",
        "-e", "DB01_BACKUP_LOCATION=S3",
        "-e", "DB01_S3_BUCKET=backups",
        "-e", "DB01_S3_KEY_ID=minio",
        "-e", "DB01_S3_KEY_SECRET=minio123",
        "-e", "DB01_S3_PATH=dbbackup",
        "-e", "DB01_S3_REGION=us-east-1",
        "-e", "DB01_S3_HOST=minio-ci:9000",
        "-e", "DB01_S3_PROTOCOL=http",
        "-e", "DB01_S3_CERT_SKIP_VERIFY=TRUE",
        $Image) | Out-Null

    Start-Sleep -Seconds 10
    Invoke-Docker -DockerArgs @("exec", "dbbackup-s3", "backup-now") | Out-Null
    $mcListing = & docker run --rm --network $Net -e MC_HOST_local=http://minio:minio123@minio-ci:9000 minio/mc ls --recursive local/backups/dbbackup
    if (-not ($mcListing | Select-String -Pattern "sqlite3_s3db_")) {
        throw "S3 backup object not found in MinIO bucket"
    }

    Write-Host "=== No zabbix references in runtime logs ==="
    $pgLogs = & docker logs dbbackup-pg 2>&1
    if ($pgLogs | Select-String -Pattern "zabbix|03-monitoring") {
        throw "Unexpected zabbix reference in logs"
    }

    Write-Host "Integration tests passed."
}
finally {
    Cleanup
}

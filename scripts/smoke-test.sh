#!/usr/bin/env bash
set -euo pipefail

IMAGE="${IMAGE:-a75g/docker-db-backup:ci}"
NET="${NET:-dbbackup-ci-net}"
TMP_ROOT="${TMP_ROOT:-${RUNNER_TEMP:-/tmp}/dbbackup-ci}"

PG_BACKUP_DIR="${TMP_ROOT}/pg"
MYSQL_BACKUP_DIR="${TMP_ROOT}/mysql"
REDIS_BACKUP_DIR="${TMP_ROOT}/redis"
MONGO_BACKUP_DIR="${TMP_ROOT}/mongo"
SQLITE_BACKUP_DIR="${TMP_ROOT}/sqlite"
S3SRC_BACKUP_DIR="${TMP_ROOT}/s3src"

mkdir -p "${PG_BACKUP_DIR}" "${MYSQL_BACKUP_DIR}" "${REDIS_BACKUP_DIR}" "${MONGO_BACKUP_DIR}" "${SQLITE_BACKUP_DIR}" "${S3SRC_BACKUP_DIR}"

cleanup() {
  docker rm -f \
    dbbackup-pg pg18-ci \
    dbbackup-mysql mysql8-ci \
    dbbackup-redis redis7-ci \
    dbbackup-mongo mongo7-ci \
    dbbackup-sqlite \
    dbbackup-s3 \
    minio-ci >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
docker network create "${NET}" >/dev/null

echo "=== PostgreSQL 18 backup + restore smoke ==="
docker run -d --name pg18-ci --network "${NET}" \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=testdb \
  postgres:18 >/dev/null

for i in $(seq 1 60); do
  if docker exec pg18-ci pg_isready -U postgres >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

docker exec pg18-ci psql -U postgres -d testdb -c "CREATE TABLE IF NOT EXISTS ci_items(id int primary key, val text);" >/dev/null
docker exec pg18-ci psql -U postgres -d testdb -c "TRUNCATE ci_items;" >/dev/null
docker exec pg18-ci psql -U postgres -d testdb -c "INSERT INTO ci_items VALUES (1,'one'),(2,'two');" >/dev/null

docker run -d --name dbbackup-pg --network "${NET}" \
  -v "${PG_BACKUP_DIR}:/backup" \
  -e MODE=MANUAL \
  -e CONTAINER_ENABLE_SCHEDULING=FALSE \
  -e MANUAL_RUN_FOREVER=TRUE \
  -e DB01_TYPE=pgsql \
  -e DB01_NAME=testdb \
  -e DB01_HOST=pg18-ci \
  -e DB01_USER=postgres \
  -e DB01_PASS=postgres \
  -e DB01_PORT=5432 \
  -e DB01_BACKUP_LOCATION=FILESYSTEM \
  "${IMAGE}" >/dev/null

sleep 10
docker exec dbbackup-pg backup-now >/dev/null

PG_FILE="$(docker exec dbbackup-pg sh -lc 'ls -1 /backup/pgsql_testdb_pg18-ci_*.sql.zst | head -n1 | xargs -n1 basename')"
test -n "${PG_FILE}"

docker exec pg18-ci psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS restoredb;" >/dev/null
docker exec pg18-ci psql -U postgres -d postgres -c "CREATE DATABASE restoredb;" >/dev/null
docker exec dbbackup-pg restore "/backup/${PG_FILE}" pgsql pg18-ci restoredb postgres postgres 5432 >/dev/null
PG_COUNT="$(docker exec pg18-ci psql -U postgres -d restoredb -tAc "SELECT COUNT(*) FROM ci_items;")"
test "${PG_COUNT}" = "2"

echo "=== MySQL 8 backup + restore smoke ==="
docker run -d --name mysql8-ci --network "${NET}" \
  -e MYSQL_ROOT_PASSWORD=rootpass \
  -e MYSQL_DATABASE=appdb \
  mysql:8 >/dev/null

for i in $(seq 1 90); do
  if docker exec mysql8-ci sh -lc 'mysqladmin ping -h 127.0.0.1 -uroot -prootpass --silent >/dev/null 2>&1'; then
    break
  fi
  sleep 2
done

docker exec mysql8-ci mysql -uroot -prootpass -e "CREATE DATABASE IF NOT EXISTS appdb; USE appdb; CREATE TABLE IF NOT EXISTS ci_items(id INT PRIMARY KEY, val VARCHAR(20)); TRUNCATE ci_items; INSERT INTO ci_items VALUES (1,'one'),(2,'two');" >/dev/null

docker run -d --name dbbackup-mysql --network "${NET}" \
  -v "${MYSQL_BACKUP_DIR}:/backup" \
  -e MODE=MANUAL \
  -e CONTAINER_ENABLE_SCHEDULING=FALSE \
  -e MANUAL_RUN_FOREVER=TRUE \
  -e DB01_TYPE=mysql \
  -e DB01_NAME=appdb \
  -e DB01_HOST=mysql8-ci \
  -e DB01_USER=root \
  -e DB01_PASS=rootpass \
  -e DB01_PORT=3306 \
  -e DB01_BACKUP_LOCATION=FILESYSTEM \
  "${IMAGE}" >/dev/null

sleep 10
docker exec dbbackup-mysql backup-now >/dev/null

MYSQL_FILE="$(docker exec dbbackup-mysql sh -lc 'ls -1 /backup/mariadb_appdb_mysql8-ci_*.sql.zst | head -n1 | xargs -n1 basename')"
test -n "${MYSQL_FILE}"

docker exec mysql8-ci mysql -uroot -prootpass -e "DROP DATABASE IF EXISTS restoredb; CREATE DATABASE restoredb;" >/dev/null
docker exec dbbackup-mysql restore "/backup/${MYSQL_FILE}" mysql mysql8-ci restoredb root rootpass 3306 false >/dev/null
MYSQL_COUNT="$(docker exec mysql8-ci mysql -N -uroot -prootpass -e "SELECT COUNT(*) FROM restoredb.ci_items;")"
test "${MYSQL_COUNT}" = "2"

echo "=== Redis 7 backup smoke ==="
docker run -d --name redis7-ci --network "${NET}" redis:7 >/dev/null
sleep 5
docker exec redis7-ci redis-cli SET ci_key ci_value >/dev/null

docker run -d --name dbbackup-redis --network "${NET}" \
  -v "${REDIS_BACKUP_DIR}:/backup" \
  -e MODE=MANUAL \
  -e CONTAINER_ENABLE_SCHEDULING=FALSE \
  -e MANUAL_RUN_FOREVER=TRUE \
  -e DB01_TYPE=redis \
  -e DB01_NAME=ALL \
  -e DB01_HOST=redis7-ci \
  -e DB01_PORT=6379 \
  -e DB01_BACKUP_LOCATION=FILESYSTEM \
  "${IMAGE}" >/dev/null

sleep 10
docker exec dbbackup-redis backup-now >/dev/null
docker exec dbbackup-redis sh -lc 'ls -1 /backup/redis_all_redis7-ci_*.rdb.zst >/dev/null'

echo "=== MongoDB 7 backup smoke ==="
docker run -d --name mongo7-ci --network "${NET}" mongo:7 >/dev/null
for i in $(seq 1 60); do
  if docker exec mongo7-ci mongosh --quiet --eval 'db.runCommand({ping:1}).ok' >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
docker exec mongo7-ci mongosh --quiet --eval "db.getSiblingDB('appdb').ci.insertOne({id:1,val:'one'})" >/dev/null

docker run -d --name dbbackup-mongo --network "${NET}" \
  -v "${MONGO_BACKUP_DIR}:/backup" \
  -e MODE=MANUAL \
  -e CONTAINER_ENABLE_SCHEDULING=FALSE \
  -e MANUAL_RUN_FOREVER=TRUE \
  -e DB01_TYPE=mongo \
  -e DB01_NAME=appdb \
  -e DB01_HOST=mongo7-ci \
  -e DB01_PORT=27017 \
  -e DB01_BACKUP_LOCATION=FILESYSTEM \
  "${IMAGE}" >/dev/null

sleep 10
docker exec dbbackup-mongo backup-now >/dev/null
docker exec dbbackup-mongo sh -lc 'ls -1 /backup/mongo_appdb_mongo7-ci_*.archive.gz >/dev/null'

echo "=== SQLite backup smoke ==="
cat > "${SQLITE_BACKUP_DIR}/init.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS t(i INTEGER);
INSERT INTO t VALUES (1);
EOF

docker run --rm -v "${SQLITE_BACKUP_DIR}:/data" "${IMAGE}" sh -lc 'sqlite3 /data/app.db < /data/init.sql' >/dev/null

docker run -d --name dbbackup-sqlite --network "${NET}" \
  -v "${SQLITE_BACKUP_DIR}:/data" \
  -v "${SQLITE_BACKUP_DIR}:/backup" \
  -e MODE=MANUAL \
  -e CONTAINER_ENABLE_SCHEDULING=FALSE \
  -e MANUAL_RUN_FOREVER=TRUE \
  -e DB01_TYPE=sqlite3 \
  -e DB01_HOST=/data/app.db \
  -e DB01_NAME=appdb \
  -e DB01_BACKUP_LOCATION=FILESYSTEM \
  "${IMAGE}" >/dev/null

sleep 10
docker exec dbbackup-sqlite backup-now >/dev/null
docker exec dbbackup-sqlite sh -lc 'ls -1 /backup/sqlite3_appdb_*.sqlite3.zst >/dev/null'

echo "=== S3/MinIO backup smoke ==="
docker run -d --name minio-ci --network "${NET}" \
  -e MINIO_ROOT_USER=minio \
  -e MINIO_ROOT_PASSWORD=minio123 \
  minio/minio server /data >/dev/null

for i in $(seq 1 60); do
  if docker run --rm --network "${NET}" -e MC_HOST_local=http://minio:minio123@minio-ci:9000 minio/mc ls local >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

docker run --rm --network "${NET}" -e MC_HOST_local=http://minio:minio123@minio-ci:9000 minio/mc mb --ignore-existing local/backups >/dev/null

cat > "${S3SRC_BACKUP_DIR}/init.sql" <<'EOF'
CREATE TABLE IF NOT EXISTS t(i INTEGER);
INSERT INTO t VALUES (1);
EOF

docker run --rm -v "${S3SRC_BACKUP_DIR}:/data" "${IMAGE}" sh -lc 'sqlite3 /data/s3.db < /data/init.sql' >/dev/null

docker run -d --name dbbackup-s3 --network "${NET}" \
  -v "${S3SRC_BACKUP_DIR}:/data" \
  -e MODE=MANUAL \
  -e CONTAINER_ENABLE_SCHEDULING=FALSE \
  -e MANUAL_RUN_FOREVER=TRUE \
  -e DB01_TYPE=sqlite3 \
  -e DB01_HOST=/data/s3.db \
  -e DB01_NAME=s3db \
  -e DB01_BACKUP_LOCATION=S3 \
  -e DB01_S3_BUCKET=backups \
  -e DB01_S3_KEY_ID=minio \
  -e DB01_S3_KEY_SECRET=minio123 \
  -e DB01_S3_PATH=dbbackup \
  -e DB01_S3_REGION=us-east-1 \
  -e DB01_S3_HOST=minio-ci:9000 \
  -e DB01_S3_PROTOCOL=http \
  -e DB01_S3_CERT_SKIP_VERIFY=TRUE \
  "${IMAGE}" >/dev/null

sleep 10
docker exec dbbackup-s3 backup-now >/dev/null
docker run --rm --network "${NET}" -e MC_HOST_local=http://minio:minio123@minio-ci:9000 minio/mc ls --recursive local/backups/dbbackup | grep -q 'sqlite3_s3db_'

echo "=== No zabbix references in runtime logs ==="
if docker logs dbbackup-pg 2>&1 | grep -Ei 'zabbix|03-monitoring' >/dev/null; then
  echo "Unexpected zabbix reference in logs" >&2
  exit 1
fi

echo "Integration tests passed."

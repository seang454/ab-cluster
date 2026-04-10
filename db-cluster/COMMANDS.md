# Database Operator Command Reference

Complete command reference for all 5 database operators in the db-cluster project.
All commands assume namespace `databases` and release name `my-db`.

---

## Table of Contents

- [Universal kubectl Commands](#universal-kubectl-commands)
- [PostgreSQL — CloudNativePG (cnpg)](#postgresql--cloudnativepg-cnpg)
- [MongoDB — Percona PSMDB](#mongodb--percona-psmdb)
- [MySQL — Percona PXC](#mysql--percona-pxc)
- [Redis — OpsTree Operator](#redis--opstree-operator)
- [Cassandra — K8ssandra](#cassandra--k8ssandra)

---

## Universal kubectl Commands

These work for all databases regardless of operator.

Notes:
- A Job pod showing `0/1 Completed` is usually healthy. Jobs finish and do not stay `1/1 Running`.
- Cassandra pods can show `1/2 Running` during bootstrap while the `cassandra` container is still joining the ring.
- If you only want active pods, hide completed Jobs with `kubectl get pods -n databases --field-selector=status.phase!=Succeeded`.

### Cluster overview

```bash
# List all database clusters at once
kubectl get cluster,psmdb,pxc,rediscluster,k8ssandracluster -n databases

# List all pods
kubectl get pods -n databases

# List only active pods (hide completed Jobs)
kubectl get pods -n databases --field-selector=status.phase!=Succeeded

# Watch pods in real time
kubectl get pods -n databases -w

# List all persistent volumes
kubectl get pvc -n databases

# List all secrets
kubectl get secrets -n databases

# List all services
kubectl get svc -n databases

# Check resource usage (requires metrics-server)
kubectl top pods -n databases

# Check node resource usage
kubectl top nodes
```

### Events and debugging

```bash
# Show all events sorted by time (errors appear here)
kubectl get events -n databases --sort-by='.lastTimestamp'

# Show only warning events
kubectl get events -n databases --field-selector type=Warning

# Describe a pod (shows resource limits, mounts, events)
kubectl describe pod <pod-name> -n databases

# Get pod logs
kubectl logs <pod-name> -n databases

# Get previous pod logs (if pod restarted)
kubectl logs <pod-name> -n databases --previous

# Follow logs in real time
kubectl logs <pod-name> -n databases -f

# Get logs from a specific container inside a pod
kubectl logs <pod-name> -c <container-name> -n databases
```

### Failover testing

```bash
# Simulate failover — delete any pod, operator auto-recovers
kubectl delete pod <pod-name> -n databases

# Watch recovery in real time
kubectl get pods -n databases -w

# Cordon a node (prevent new pods scheduling on it)
kubectl cordon <node-name>

# Drain a node (evict all pods, simulates node failure)
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# Uncordon node after test
kubectl uncordon <node-name>
```

### Storage

```bash
# List all PVCs
kubectl get pvc -n databases

# Describe a PVC (shows Longhorn volume details)
kubectl describe pvc <pvc-name> -n databases

# List all PVs (cluster-wide)
kubectl get pv
```

---

## PostgreSQL — CloudNativePG (cnpg)

### Install the cnpg kubectl plugin

```bash
# Via krew (recommended)
kubectl krew install cnpg

# Verify installation
kubectl cnpg version
```

### Cluster status

```bash
# Show cluster summary (instances, primary, phase)
kubectl cnpg status my-db-postgresql -n databases

# Verbose status (includes replication lag, timeline)
kubectl cnpg status my-db-postgresql -n databases --verbose

# Watch status continuously
kubectl cnpg status my-db-postgresql -n databases --watch

# Show cluster as YAML
kubectl get cluster my-db-postgresql -n databases -o yaml

# Describe cluster (events + spec)
kubectl describe cluster my-db-postgresql -n databases

# List all CNPG clusters in namespace
kubectl get cluster -n databases
```

### Primary and replicas

```bash
# Find which pod is primary
kubectl get pods -n databases -l cnpg.io/cluster=my-db-postgresql,role=primary

# Find all replica pods
kubectl get pods -n databases -l cnpg.io/cluster=my-db-postgresql,role=replica

# Show replication status from inside primary
kubectl exec -it $(kubectl get pod -n databases -l cnpg.io/cluster=my-db-postgresql,role=primary -o name) -n databases \
  -- psql -U postgres -c "SELECT * FROM pg_stat_replication;"

# Check replication lag on replica
kubectl exec -it my-db-postgresql-2 -n databases \
  -- psql -U postgres -c "SELECT now() - pg_last_xact_replay_timestamp() AS replication_lag;"
```

### Failover and switchover

```bash
# Planned switchover (graceful — promotes specific replica)
kubectl cnpg promote my-db-postgresql my-db-postgresql-2 -n databases

# Force failover (use when primary is unresponsive)
kubectl cnpg switchover my-db-postgresql my-db-postgresql-2 -n databases

# Simulate failover by deleting primary pod
kubectl delete pod $(kubectl get pod -n databases -l cnpg.io/cluster=my-db-postgresql,role=primary -o jsonpath='{.items[0].metadata.name}') -n databases
```

### Connecting to PostgreSQL

```bash
# Connect to primary via cnpg plugin
kubectl cnpg psql my-db-postgresql -n databases

# Connect manually to primary
kubectl exec -it $(kubectl get pod -n databases -l cnpg.io/cluster=my-db-postgresql,role=primary -o name) -n databases \
  -- psql -U postgres

# Connect to a specific replica
kubectl exec -it my-db-postgresql-2 -n databases \
  -- psql -U postgres

# Connect to specific database
kubectl exec -it my-db-postgresql-1 -n databases \
  -- psql -U postgres -d appdb

# Run a one-off SQL query
kubectl exec -it my-db-postgresql-1 -n databases \
  -- psql -U postgres -c "SELECT version();"

# List databases
kubectl exec -it my-db-postgresql-1 -n databases \
  -- psql -U postgres -c "\l"

# List tables in appdb
kubectl exec -it my-db-postgresql-1 -n databases \
  -- psql -U postgres -d appdb -c "\dt"
```

### Restart and reload

```bash
# Rolling restart of all instances (applies config changes)
kubectl cnpg restart my-db-postgresql -n databases

# Reload config without restart
kubectl cnpg reload my-db-postgresql -n databases

# Restart a specific instance
kubectl cnpg restart my-db-postgresql --instance my-db-postgresql-2 -n databases
```

### Backup

```bash
# Trigger an on-demand backup
kubectl cnpg backup my-db-postgresql -n databases

# List all backups
kubectl get backup -n databases

# Describe a specific backup
kubectl describe backup <backup-name> -n databases

# List scheduled backups
kubectl get scheduledbackup -n databases

# Check WAL archive status
kubectl cnpg status my-db-postgresql -n databases --verbose | grep -i wal
```

### Maintenance and upgrade

```bash
# Put instance in maintenance mode (stops pod rescheduling)
kubectl cnpg maintenance set --reusePVC my-db-postgresql -n databases

# Remove maintenance mode
kubectl cnpg maintenance unset my-db-postgresql -n databases

# Check operator logs
kubectl logs -n cnpg-system deployment/cnpg-controller-manager -f

# Check operator version
kubectl cnpg version
```

### Hibernate (pause cluster to save resources)

```bash
# Hibernate — stops all pods, keeps PVCs
kubectl cnpg hibernate on my-db-postgresql -n databases

# Wake up
kubectl cnpg hibernate off my-db-postgresql -n databases
```

---

## MongoDB — Percona PSMDB

### Cluster status

```bash
# List all MongoDB clusters
kubectl get psmdb -n databases

# Show cluster details
kubectl get psmdb my-db-mongodb -n databases -o yaml

# Describe cluster
kubectl describe psmdb my-db-mongodb -n databases

# Check all pods
kubectl get pods -n databases -l app.kubernetes.io/instance=my-db-mongodb

# Check operator logs
kubectl logs -n databases deployment/psmdb-operator -f
```

### Replica set status

```bash
# Check replica set status
kubectl exec -it my-db-mongodb-rs0-0 -n databases \
  -- mongo -u clusterAdmin -p SecureMongoPassword123! \
  --eval "rs.status()"

# Check who is primary
kubectl exec -it my-db-mongodb-rs0-0 -n databases \
  -- mongo -u clusterAdmin -p SecureMongoPassword123! \
  --eval "rs.isMaster()"

# Check replication lag
kubectl exec -it my-db-mongodb-rs0-0 -n databases \
  -- mongo -u clusterAdmin -p SecureMongoPassword123! \
  --eval "rs.printSlaveReplicationInfo()"

# Check replica set config
kubectl exec -it my-db-mongodb-rs0-0 -n databases \
  -- mongo -u clusterAdmin -p SecureMongoPassword123! \
  --eval "rs.conf()"

# Show all members and their states
kubectl exec -it my-db-mongodb-rs0-0 -n databases \
  -- mongo -u clusterAdmin -p SecureMongoPassword123! \
  --eval "rs.status().members.forEach(m => print(m.name, m.stateStr, m.health))"
```

### Connecting to MongoDB

```bash
# Connect to primary
kubectl exec -it my-db-mongodb-rs0-0 -n databases \
  -- mongo -u clusterAdmin -p SecureMongoPassword123!

# Connect using replica set URI
kubectl exec -it my-db-mongodb-rs0-0 -n databases \
  -- mongo "mongodb://clusterAdmin:SecureMongoPassword123!@my-db-mongodb-rs0-0.my-db-mongodb-rs0.databases.svc:27017/?replicaSet=rs0"

# List databases
kubectl exec -it my-db-mongodb-rs0-0 -n databases \
  -- mongo -u clusterAdmin -p SecureMongoPassword123! \
  --eval "db.adminCommand({ listDatabases: 1 })"

# Show current DB stats
kubectl exec -it my-db-mongodb-rs0-0 -n databases \
  -- mongo -u clusterAdmin -p SecureMongoPassword123! \
  --eval "db.stats()"

# Show server status
kubectl exec -it my-db-mongodb-rs0-0 -n databases \
  -- mongo -u clusterAdmin -p SecureMongoPassword123! \
  --eval "db.serverStatus()"
```

### Failover testing

```bash
# Delete primary pod — replica set auto-elects new primary
kubectl delete pod my-db-mongodb-rs0-0 -n databases

# Force stepdown (graceful primary handoff)
kubectl exec -it my-db-mongodb-rs0-0 -n databases \
  -- mongo -u clusterAdmin -p SecureMongoPassword123! \
  --eval "rs.stepDown()"

# Watch election in real time
kubectl get pods -n databases -w
```

### Backup (Percona Backup for MongoDB — pbm)

```bash
# Check pbm status
kubectl exec -it my-db-mongodb-rs0-0 -n databases \
  -- pbm status

# Trigger a full backup
kubectl exec -it my-db-mongodb-rs0-0 -n databases \
  -- pbm backup

# List all backups
kubectl exec -it my-db-mongodb-rs0-0 -n databases \
  -- pbm list

# Check backup progress
kubectl exec -it my-db-mongodb-rs0-0 -n databases \
  -- pbm status --format json

# Restore from backup
kubectl exec -it my-db-mongodb-rs0-0 -n databases \
  -- pbm restore <backup-name>

# Check pbm config
kubectl exec -it my-db-mongodb-rs0-0 -n databases \
  -- pbm config
```

---

## MySQL — Percona PXC

### Cluster status

```bash
# List all MySQL clusters
kubectl get pxc -n databases

# Show cluster details
kubectl get pxc my-db-mysql -n databases -o yaml

# Describe cluster
kubectl describe pxc my-db-mysql -n databases

# Check all pods
kubectl get pods -n databases -l app.kubernetes.io/instance=my-db-mysql

# Check operator logs
kubectl logs -n databases deployment/pxc-operator -f
```

### Galera cluster status

```bash
# Check Galera cluster state
kubectl exec -it my-db-mysql-pxc-0 -n databases \
  -- mysql -u root -pSecureMysqlPassword123! \
  -e "SHOW STATUS LIKE 'wsrep_cluster%';"

# Check cluster size and readiness
kubectl exec -it my-db-mysql-pxc-0 -n databases \
  -- mysql -u root -pSecureMysqlPassword123! \
  -e "SHOW STATUS LIKE 'wsrep_cluster_size';"

# Check node state (Synced = healthy)
kubectl exec -it my-db-mysql-pxc-0 -n databases \
  -- mysql -u root -pSecureMysqlPassword123! \
  -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"

# Check all node addresses in cluster
kubectl exec -it my-db-mysql-pxc-0 -n databases \
  -- mysql -u root -pSecureMysqlPassword123! \
  -e "SHOW STATUS LIKE 'wsrep_incoming_addresses';"

# Check replication health
kubectl exec -it my-db-mysql-pxc-0 -n databases \
  -- mysql -u root -pSecureMysqlPassword123! \
  -e "SHOW STATUS LIKE 'wsrep%';"
```

### Connecting to MySQL

```bash
# Connect to cluster via HAProxy
kubectl exec -it my-db-mysql-pxc-0 -n databases \
  -- mysql -u root -pSecureMysqlPassword123!

# Connect to specific database
kubectl exec -it my-db-mysql-pxc-0 -n databases \
  -- mysql -u root -pSecureMysqlPassword123! appdb

# List all databases
kubectl exec -it my-db-mysql-pxc-0 -n databases \
  -- mysql -u root -pSecureMysqlPassword123! \
  -e "SHOW DATABASES;"

# List tables
kubectl exec -it my-db-mysql-pxc-0 -n databases \
  -- mysql -u root -pSecureMysqlPassword123! appdb \
  -e "SHOW TABLES;"

# Show MySQL version
kubectl exec -it my-db-mysql-pxc-0 -n databases \
  -- mysql -u root -pSecureMysqlPassword123! \
  -e "SELECT VERSION();"

# Show running processes
kubectl exec -it my-db-mysql-pxc-0 -n databases \
  -- mysql -u root -pSecureMysqlPassword123! \
  -e "SHOW PROCESSLIST;"
```

### Failover testing

```bash
# Delete a PXC pod — Galera resyncs remaining nodes automatically
kubectl delete pod my-db-mysql-pxc-0 -n databases

# Watch cluster resyncing
kubectl get pods -n databases -w

# Check wsrep state after recovery
kubectl exec -it my-db-mysql-pxc-1 -n databases \
  -- mysql -u root -pSecureMysqlPassword123! \
  -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"
```

### Backup

```bash
# Trigger on-demand backup (apply as YAML)
kubectl apply -f - <<EOF
apiVersion: pxc.percona.com/v1
kind: PerconaXtraDBClusterBackup
metadata:
  name: manual-backup-$(date +%Y%m%d)
  namespace: databases
spec:
  pxcCluster: my-db-mysql
  storageName: s3-storage
EOF

# List all backups
kubectl get pxc-backup -n databases

# Describe backup status
kubectl describe pxc-backup manual-backup -n databases

# Restore from backup
kubectl apply -f - <<EOF
apiVersion: pxc.percona.com/v1
kind: PerconaXtraDBClusterRestore
metadata:
  name: restore-$(date +%Y%m%d)
  namespace: databases
spec:
  pxcCluster: my-db-mysql
  backupName: manual-backup
EOF

# Check restore status
kubectl get pxc-restore -n databases
```

---

## Redis — OpsTree Operator

This chart's Redis cluster usually creates 3 leader pods and 3 follower pods when `cluster.instances: 3`.

### Cluster status

```bash
# List all Redis clusters
kubectl get rediscluster -n databases

# Show cluster details
kubectl get rediscluster my-db-redis -n databases -o yaml

# Describe cluster
kubectl describe rediscluster my-db-redis -n databases

# Check all pods
kubectl get pods -n databases -l app=my-db-redis

# Check operator logs
kubectl logs -n databases deployment/redis-operator -f
```

### Redis cluster info

```bash
# Check cluster info
kubectl exec -it my-db-redis-leader-0 -n databases \
  -- redis-cli -a SecureRedisPassword123! cluster info

# List all cluster nodes (leaders + followers)
kubectl exec -it my-db-redis-leader-0 -n databases \
  -- redis-cli -a SecureRedisPassword123! cluster nodes

# Check cluster slots distribution
kubectl exec -it my-db-redis-leader-0 -n databases \
  -- redis-cli -a SecureRedisPassword123! cluster slots

# Show server info
kubectl exec -it my-db-redis-leader-0 -n databases \
  -- redis-cli -a SecureRedisPassword123! info

# Show replication info
kubectl exec -it my-db-redis-leader-0 -n databases \
  -- redis-cli -a SecureRedisPassword123! info replication

# Show memory usage
kubectl exec -it my-db-redis-leader-0 -n databases \
  -- redis-cli -a SecureRedisPassword123! info memory

# Show connected clients
kubectl exec -it my-db-redis-leader-0 -n databases \
  -- redis-cli -a SecureRedisPassword123! info clients
```

### Connecting and testing

```bash
# Connect to Redis leader interactively
kubectl exec -it my-db-redis-leader-0 -n databases \
  -- redis-cli -a SecureRedisPassword123!

# Test write
kubectl exec -it my-db-redis-leader-0 -n databases \
  -- redis-cli -a SecureRedisPassword123! set testkey "hello"

# Test read
kubectl exec -it my-db-redis-leader-0 -n databases \
  -- redis-cli -a SecureRedisPassword123! get testkey

# Test with cluster mode flag (required for cluster mode)
kubectl exec -it my-db-redis-leader-0 -n databases \
  -- redis-cli -c -a SecureRedisPassword123! set testkey "hello"

# Ping all nodes
kubectl exec -it my-db-redis-leader-0 -n databases \
  -- redis-cli -a SecureRedisPassword123! ping

# Check key count
kubectl exec -it my-db-redis-leader-0 -n databases \
  -- redis-cli -a SecureRedisPassword123! dbsize

# List all keys (use carefully in production)
kubectl exec -it my-db-redis-leader-0 -n databases \
  -- redis-cli -a SecureRedisPassword123! keys "*"

# Monitor live commands
kubectl exec -it my-db-redis-leader-0 -n databases \
  -- redis-cli -a SecureRedisPassword123! monitor

# Check slowlog
kubectl exec -it my-db-redis-leader-0 -n databases \
  -- redis-cli -a SecureRedisPassword123! slowlog get 10
```

### Failover testing

```bash
# Delete leader pod — cluster auto-promotes follower
kubectl delete pod my-db-redis-leader-0 -n databases

# Watch cluster heal
kubectl get pods -n databases -w

# Check new cluster state after recovery
kubectl exec -it my-db-redis-leader-1 -n databases \
  -- redis-cli -a SecureRedisPassword123! cluster info

# Manual failover (graceful)
kubectl exec -it my-db-redis-follower-0 -n databases \
  -- redis-cli -a SecureRedisPassword123! cluster failover
```

### Backup (manual — operator does not include backup)

```bash
# Trigger RDB snapshot
kubectl exec -it my-db-redis-leader-0 -n databases \
  -- redis-cli -a SecureRedisPassword123! bgsave

# Check last save time
kubectl exec -it my-db-redis-leader-0 -n databases \
  -- redis-cli -a SecureRedisPassword123! lastsave

# Trigger AOF rewrite
kubectl exec -it my-db-redis-leader-0 -n databases \
  -- redis-cli -a SecureRedisPassword123! bgrewriteaof
```

### Config management

```bash
# Get all config values
kubectl exec -it my-db-redis-leader-0 -n databases \
  -- redis-cli -a SecureRedisPassword123! config get "*"

# Get specific config value
kubectl exec -it my-db-redis-leader-0 -n databases \
  -- redis-cli -a SecureRedisPassword123! config get maxmemory

# Set config at runtime (resets on pod restart)
kubectl exec -it my-db-redis-leader-0 -n databases \
  -- redis-cli -a SecureRedisPassword123! config set maxmemory 512mb

# Reset stats
kubectl exec -it my-db-redis-leader-0 -n databases \
  -- redis-cli -a SecureRedisPassword123! config resetstat
```

---

## Cassandra — K8ssandra

Operational notes:
- Cassandra pods are normally spread across different nodes.
- `1/2 Running` during bootstrap is expected for a while.
- The k8ssandra CRD upgrader pod is a Job, so `0/1 Completed` is normal.

### Cluster status

```bash
# List all K8ssandra clusters
kubectl get k8ssandracluster -n databases

# Show cluster details
kubectl get k8ssandracluster my-db-cassandra -n databases -o yaml

# Describe cluster
kubectl describe k8ssandracluster my-db-cassandra -n databases

# Check all pods
kubectl get pods -n databases -l cassandra.datastax.com/cluster=seang-cassandra

# Check operator logs
kubectl logs -n databases deployment/k8ssandra-operator -f

# Check cass-operator logs (sub-operator)
kubectl logs -n databases deployment/cass-operator -f

# Watch Cassandra pod readiness during bootstrap
kubectl get pods -n databases -l cassandra.datastax.com/cluster=seang-cassandra -w

# Show CassandraDatacenter status
kubectl get cassandradatacenter dc1 -n databases -o jsonpath='{.status}'
```

### Ring and node status (nodetool)

```bash
# Check ring status — shows all nodes, state, load, tokens
kubectl exec -it my-db-cassandra-dc1-default-sts-0 -n databases \
  -- nodetool status

# Verbose ring info
kubectl exec -it my-db-cassandra-dc1-default-sts-0 -n databases \
  -- nodetool ring

# Node info (uptime, load, heap usage)
kubectl exec -it my-db-cassandra-dc1-default-sts-0 -n databases \
  -- nodetool info

# Check gossip state (inter-node communication)
kubectl exec -it my-db-cassandra-dc1-default-sts-0 -n databases \
  -- nodetool gossipinfo

# List all endpoints in ring
kubectl exec -it my-db-cassandra-dc1-default-sts-0 -n databases \
  -- nodetool endpoints

# Show token ranges
kubectl exec -it my-db-cassandra-dc1-default-sts-0 -n databases \
  -- nodetool describering <keyspace-name>

# Check thread pool stats
kubectl exec -it my-db-cassandra-dc1-default-sts-0 -n databases \
  -- nodetool tpstats

# Show compaction stats
kubectl exec -it my-db-cassandra-dc1-default-sts-0 -n databases \
  -- nodetool compactionstats

# Check table stats
kubectl exec -it my-db-cassandra-dc1-default-sts-0 -n databases \
  -- nodetool tablestats

# Show data center info
kubectl exec -it my-db-cassandra-dc1-default-sts-0 -n databases \
  -- nodetool describecluster

# Check management API readiness from inside the pod
kubectl exec -it my-db-cassandra-dc1-default-sts-0 -n databases -c cassandra \
  -- curl -i http://127.0.0.1:8080/api/v0/probes/readiness
```

### Connecting with cqlsh

```bash
# Connect to Cassandra
kubectl exec -it my-db-cassandra-dc1-default-sts-0 -n databases \
  -- cqlsh -u cassandra -p cassandra

# Run one-off CQL query
kubectl exec -it my-db-cassandra-dc1-default-sts-0 -n databases \
  -- cqlsh -u cassandra -p cassandra \
  -e "DESCRIBE KEYSPACES;"

# List all keyspaces
kubectl exec -it my-db-cassandra-dc1-default-sts-0 -n databases \
  -- cqlsh -u cassandra -p cassandra \
  -e "SELECT keyspace_name FROM system_schema.keyspaces;"

# Show tables in a keyspace
kubectl exec -it my-db-cassandra-dc1-default-sts-0 -n databases \
  -- cqlsh -u cassandra -p cassandra \
  -e "DESCRIBE TABLES;" -k <keyspace-name>

# Check cluster name and version
kubectl exec -it my-db-cassandra-dc1-default-sts-0 -n databases \
  -- cqlsh -u cassandra -p cassandra \
  -e "SELECT cluster_name, release_version FROM system.local;"
```

### Maintenance operations

```bash
# Run repair (fixes data consistency across nodes)
kubectl exec -it my-db-cassandra-dc1-default-sts-0 -n databases \
  -- nodetool repair

# Run repair on specific keyspace
kubectl exec -it my-db-cassandra-dc1-default-sts-0 -n databases \
  -- nodetool repair <keyspace-name>

# Run full repair (all token ranges)
kubectl exec -it my-db-cassandra-dc1-default-sts-0 -n databases \
  -- nodetool repair --full

# Flush memtables to disk
kubectl exec -it my-db-cassandra-dc1-default-sts-0 -n databases \
  -- nodetool flush

# Run compaction manually
kubectl exec -it my-db-cassandra-dc1-default-sts-0 -n databases \
  -- nodetool compact

# Drain node (graceful shutdown prep)
kubectl exec -it my-db-cassandra-dc1-default-sts-0 -n databases \
  -- nodetool drain

# Decommission node (remove from ring permanently)
kubectl exec -it my-db-cassandra-dc1-default-sts-0 -n databases \
  -- nodetool decommission
```

### Failover testing

```bash
# Delete a pod — ring continues, pod rejoins on restart
kubectl delete pod my-db-cassandra-dc1-default-sts-0 -n databases

# Watch pod restart
kubectl get pods -n databases -w

# Check ring status after recovery (should show UN = Up/Normal)
kubectl exec -it my-db-cassandra-dc1-default-sts-1 -n databases \
  -- nodetool status
```

### Backup (Medusa)

```bash
# Trigger backup via MedusaBackup CRD
kubectl apply -f - <<EOF
apiVersion: medusa.k8ssandra.io/v1alpha1
kind: MedusaBackup
metadata:
  name: manual-backup-$(date +%Y%m%d)
  namespace: databases
spec:
  cassandraDatacenter: dc1
  type: differential
EOF

# List all backups
kubectl get medusabackup -n databases

# Describe backup status
kubectl describe medusabackup manual-backup -n databases

# Restore from backup
kubectl apply -f - <<EOF
apiVersion: medusa.k8ssandra.io/v1alpha1
kind: MedusaRestoreJob
metadata:
  name: restore-$(date +%Y%m%d)
  namespace: databases
spec:
  backup: manual-backup-20240101
  cassandraDatacenter:
    name: dc1
    clusterName: my-db-cassandra
EOF

# Check restore status
kubectl get medusarestorejob -n databases
```

---

## Quick Health Check — All Databases

Run this to check all clusters at once:

```bash
echo "=== PostgreSQL ===" && kubectl get cluster -n databases
echo "=== MongoDB ===" && kubectl get psmdb -n databases
echo "=== MySQL ===" && kubectl get pxc -n databases
echo "=== Redis ===" && kubectl get rediscluster -n databases
echo "=== Cassandra ===" && kubectl get k8ssandracluster -n databases
echo "=== All Pods ===" && kubectl get pods -n databases
echo "=== Events ===" && kubectl get events -n databases --sort-by='.lastTimestamp' | tail -20
```

---

## Common Status Values

### PostgreSQL (CNPG)
| Status | Meaning |
|---|---|
| `Cluster in healthy state` | All good |
| `Switchover in progress` | Planned failover happening |
| `Failing over` | Unplanned failover happening |
| `Creating primary` | First boot |

### MongoDB (PSMDB)
| State | Meaning |
|---|---|
| `ready` | Cluster healthy |
| `initializing` | Starting up |
| `error` | Check operator logs |

### MySQL (PXC) — wsrep states
| wsrep_local_state_comment | Meaning |
|---|---|
| `Synced` | Node healthy, in sync |
| `Joining` | Node joining cluster |
| `Donor/Desynced` | Node sending data to joiner |
| `Disconnected` | Node not in cluster |

### Redis Cluster
| cluster_state | Meaning |
|---|---|
| `ok` | All slots covered |
| `fail` | Slots uncovered — action needed |

### Cassandra (nodetool status)
| Code | Meaning |
|---|---|
| `UN` | Up + Normal (healthy) |
| `DN` | Down + Normal (pod crashed) |
| `UL` | Up + Leaving (decommissioning) |
| `UJ` | Up + Joining (new node joining) |



PG_PASS="securePassword12345"
MONGO_PASS="securePassword12345"
MYSQL_PASS="securePassword12345"
REDIS_PASS="securePassword12345"
CASS_PASS="securePassword12345"

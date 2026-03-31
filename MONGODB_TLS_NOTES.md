# MongoDB TLS Notes

## TLS vs mTLS

### Normal TLS
- The server presents a certificate.
- The client verifies the server certificate.
- The client usually authenticates with username/password.

Flow:

```text
client -> verify server cert -> connect
```

Diagram:

```text
+-------------+        +-------------+
| Client      |        | Server      |
| app/mongosh |------->| database    |
+-------------+        +-------------+
       |                      |
       | 1. server sends cert |
       |<---------------------|
       |                      |
       | 2. client verifies   |
       |    server cert       |
       |--------------------->|
       |                      |
       | 3. username/password |
       |    auth usually here |
       |--------------------->|
```

Result:
- server proves identity
- client does not send its own certificate

### Mutual TLS (mTLS)
- The server presents a certificate.
- The client verifies the server certificate.
- The client also presents its own certificate.
- The server verifies the client certificate.

Flow:

```text
client -> verify server cert
server -> verify client cert
```

Diagram:

```text
+-------------+        +-------------+
| Client      |        | Server      |
| app/service |<-----> | database    |
+-------------+        +-------------+
       |                      |
       | 1. server sends cert |
       |<---------------------|
       |                      |
       | 2. client verifies   |
       |    server cert       |
       |--------------------->|
       |                      |
       | 3. client sends cert |
       |--------------------->|
       |                      |
       | 4. server verifies   |
       |    client cert       |
       |<---------------------|
```

Result:
- server proves identity
- client also proves identity
- both sides use certificates

## What SAN Means

SAN means `Subject Alternative Name`.

It is the list of hostnames a certificate is valid for.

Example:

```text
mongo-db-0.seang.shop
mongo-db-1.seang.shop
mongo-db-2.seang.shop
```

If a client connects to `mongo-db-0.seang.shop`, that exact hostname must be present in the server certificate SAN list.

## What "Node" Means

There are two meanings of `node` in this setup.

### Kubernetes node
- A worker machine in the Kubernetes cluster.
- Example:
  - `worker01`
  - `worker02`
  - `worker03`
- Pods run on these nodes.

### MongoDB node / member
- One MongoDB server instance in the replica set.
- In this setup:
  - `my-db-mongodb-rs0-0`
  - `my-db-mongodb-rs0-1`
  - `my-db-mongodb-rs0-2`

Practical mapping:

```text
Kubernetes node (machine)
  -> hosts Mongo pod

Mongo pod
  -> runs one mongod process

mongod process
  -> is one replica-set member/node
```

Example:

```text
worker01 -> my-db-mongodb-rs0-0
worker02 -> my-db-mongodb-rs0-1
worker03 -> my-db-mongodb-rs0-2
```

## Why MongoDB Uses Certificates More Deeply

MongoDB replica sets are not just a client talking to one database server.

The MongoDB members also connect to each other for:
- replication
- elections
- membership validation
- cluster state coordination

In this setup, internal member-to-member authentication uses:

```text
clusterAuthMode=x509
```

That means:
- each MongoDB member has a certificate
- one member presents its certificate to another member
- the receiving member verifies that certificate

So there are multiple certificate-related layers in this MongoDB setup.

### 1. External client -> MongoDB
- The client connects over TLS.
- The client verifies the server certificate with the CA file.

### 2. MongoDB member -> MongoDB member
- Replica-set members authenticate each other.
- This uses x509 certificates internally.

### 3. Replica-set topology advertisement
- MongoDB tells clients which members exist.
- Those advertised member names must match certificate SANs.

This is why MongoDB needed more certificate work than a simpler single-endpoint database connection.

## What Was Wrong In This MongoDB Setup

The external MongoDB client path was failing for two main reasons:

1. MongoDB was rejecting normal external TLS clients with:

```text
No SSL certificate provided by peer; connection rejected
```

That meant the server was behaving as if external clients had to present a client certificate.

2. The replica set was advertising public endpoints that did not match the HAProxy public port mapping.

## What Was Fixed

### 1. Bootstrap shell compatibility
- The Percona operator expected `mongo`.
- MongoDB 7 only had `mongosh`.
- A compatibility wrapper was added.

### 2. TLS certificate SAN coverage
- Internal pod DNS names were added.
- External public DNS names were added.

### 3. External TLS client behavior
- MongoDB was configured to allow normal TLS clients without requiring a client certificate.

Applied setting:

```yaml
net:
  tls:
    allowConnectionsWithoutCertificates: true
```

### 4. External HAProxy routing
- All public hostnames resolve to the same external IP and share port 27017.
- HAProxy chooses the backend by TLS SNI so each hostname always lands on
- its matching member.

### 5. Replica-set advertised horizons
- MongoDB now advertises the same hostnames (on port 27017) that HAProxy exposes.

## Final Working External URI

```text
mongodb://clusterAdmin:YourMongoPassword@mongo-db-0.seang.shop:27017,mongo-db-1.seang.shop:27017,mongo-db-2.seang.shop:27017/admin?replicaSet=rs0&authSource=admin&tls=true
```

Example:

```bash
mongosh "mongodb://clusterAdmin:YourMongoPassword@mongo-db-0.seang.shop:27017,mongo-db-1.seang.shop:27017,mongo-db-2.seang.shop:27017/admin?replicaSet=rs0&authSource=admin&tls=true" --tls --tlsCAFile /mnt/d/CSTADPreUniversityTraining/ITP/iacfinal/mongo-ca.crt
```

## Should Other Databases Use The Same Concept?

### Yes, for all databases
- Use TLS.
- Make sure certificate SANs match the hostnames clients use.
- Make sure clients trust the CA.

### No, not the full MongoDB-specific model
Do not blindly copy these MongoDB-specific pieces to every database:
- replica-set horizons
- per-member external topology
- `allowConnectionsWithoutCertificates`
- Mongo replica-set discovery behavior

## Practical Guidance Per Database

1. Do clients need to trust the server certificate?
2. Do clients also need to send their own certificate?

Important distinction:
- `server certificate` means the database server presents a TLS certificate.
- `client CA trust` means the client has the CA file and uses it to verify the server certificate.
- `client certificate` means the client also sends its own certificate to the server.

In most normal database connections:
- the server has a certificate
- the client verifies that server certificate
- the client logs in with username/password

That is normal TLS.

That does **not** automatically mean:
- the client must also send its own certificate

That second model is mutual TLS.

### PostgreSQL
- Normal/common setup:
  - PostgreSQL server has a certificate.
  - Client verifies the PostgreSQL server certificate with a CA file.
  - Client logs in with username/password.
- Usually one stable external endpoint is enough.
- Client certificate authentication is optional, not required by default.

### MySQL
- Normal/common setup:
  - MySQL server has a certificate.
  - Client verifies the MySQL server certificate with a CA file.
  - Client logs in with username/password.
- Client certificate authentication is optional, not required by default.

### Redis
- If Redis TLS is enabled:
  - Redis server has a certificate.
  - Client verifies the Redis server certificate with a CA file.
- Client certificate authentication depends on your security design.
- It is not automatically required just because TLS is enabled.

### Cassandra
- Normal/common setup:
  - Cassandra server has a certificate.
  - Client verifies the Cassandra server certificate with a CA file.
  - Client usually still authenticates normally, depending on the setup.
- Some Cassandra environments use mutual TLS, but it is not required in every deployment.
- In this repo, the Cassandra default was adjusted so enabling TLS does not automatically require client certificates.

### MongoDB
- External clients:
  - MongoDB server presents a certificate.
  - Client verifies the MongoDB server certificate with a CA file.
  - Client logs in with username/password.
  - External client certificate authentication is not required in this setup.
- Internal MongoDB replica-set members may still use x509 certificates to identify each other.

## Why MongoDB Looked Different From Other Databases

MongoDB looked more complex because:
- the client is replica-set aware
- the members talk directly to each other
- internal member identity uses x509 in this setup
- external clients discover multiple member addresses

Other databases often look simpler because they usually use:
- one stable external endpoint
- server certificate for encryption
- username/password for client authentication

That does not mean other databases cannot use mutual TLS.
It means they usually do not need the full MongoDB-style member identity model by default.

## Short Answer

- Server certificate: usually yes.
- Client certificate: only if you intentionally want mutual TLS.
- SANs: always important when TLS hostname verification is enabled.

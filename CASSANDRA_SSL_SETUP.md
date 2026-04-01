# Cassandra SSL Setup

The Cassandra subchart now generates TLS secrets automatically during `helm install` and `helm upgrade`.
You do not need to run `keytool` manually for the normal path.

## External connection

Use the public hostname on the HAProxy port:

```ini
[connection]
hostname = cassandra-db.seang.shop
port = 9042

[ssl]
certfile = /mnt/d/CSTADPreUniversityTraining/ITP/iacfinal/cassandra.cer
validate = true
```

Fetch the certificate from the cluster:

```bash
kubectl get configmap my-db-cassandra-client-ca -n databases \
  -o jsonpath='{.data.cassandra\.cer}' > /mnt/d/CSTADPreUniversityTraining/ITP/iacfinal/cassandra.cer
```

Then connect with:

```bash
cqlsh --ssl --cqlshrc ./cqlshrc -u cassandra -p <password>
```

## Notes

- Cassandra is exposed through `cassandra-db.seang.shop:9042`.
- `requireClientAuth: false` keeps external access on normal TLS instead of mTLS.
- If you need to regenerate the secrets, rerun `./setup.sh upgrade`.

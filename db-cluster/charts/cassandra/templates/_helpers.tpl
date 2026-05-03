{{- define "cassandra.fullname" -}}
{{- printf "%s-cassandra" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cassandra.clusterName" -}}
{{- default (include "cassandra.fullname" .) .Values.cluster.config.clusterName -}}
{{- end -}}

{{- define "cassandra.datacenter" -}}
{{- default "dc1" .Values.cluster.config.datacenter -}}
{{- end -}}

{{- define "cassandra.secretName" -}}
{{- printf "%s-cassandra-credentials" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cassandra.storageClass" -}}
{{- .Values.storage.storageClass | default "longhorn" -}}
{{- end -}}

{{- define "cassandra.serverSecretName" -}}
{{- if and .Values.tls.enabled .Values.tls.serverSecretName -}}
{{- .Values.tls.serverSecretName -}}
{{- else -}}
{{- printf "%s-server-encryption-stores" (include "cassandra.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "cassandra.clientSecretName" -}}
{{- if and .Values.tls.enabled .Values.tls.clientSecretName -}}
{{- .Values.tls.clientSecretName -}}
{{- else -}}
{{- printf "%s-client-encryption-stores" (include "cassandra.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

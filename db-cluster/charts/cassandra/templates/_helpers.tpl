{{- define "cassandra.fullname" -}}
{{- printf "%s-cassandra" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cassandra.clusterName" -}}
{{- $values := .Values | default dict -}}
{{- if hasKey $values "cluster" -}}
{{- $cluster := get $values "cluster" | default dict -}}
{{- $config := get $cluster "config" | default dict -}}
{{- default (include "cassandra.fullname" .) (get $config "clusterName" | default "") -}}
{{- else if hasKey $values "cassandra" -}}
{{- $cassandra := get $values "cassandra" | default dict -}}
{{- $cluster := get $cassandra "cluster" | default dict -}}
{{- $config := get $cluster "config" | default dict -}}
{{- default (printf "%s-cassandra" .Release.Name) (get $config "clusterName" | default "") -}}
{{- else -}}
{{- printf "%s-cassandra" .Release.Name -}}
{{- end -}}
{{- end -}}

{{- define "cassandra.datacenter" -}}
{{- $values := .Values | default dict -}}
{{- $defaultDc := printf "%s-dc1" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- if hasKey $values "cluster" -}}
{{- $cluster := get $values "cluster" | default dict -}}
{{- $config := get $cluster "config" | default dict -}}
{{- default $defaultDc (get $config "datacenter" | default "") -}}
{{- else if hasKey $values "cassandra" -}}
{{- $cassandra := get $values "cassandra" | default dict -}}
{{- $cluster := get $cassandra "cluster" | default dict -}}
{{- $config := get $cluster "config" | default dict -}}
{{- default $defaultDc (get $config "datacenter" | default "") -}}
{{- else -}}
{{- $defaultDc -}}
{{- end -}}
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

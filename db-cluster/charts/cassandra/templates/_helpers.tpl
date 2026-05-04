{{- define "cassandra.fullname" -}}
{{- printf "%s-cassandra" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cassandra.clusterName" -}}
{{- $values := .Values | default dict -}}
{{- $legacyCluster := "seang-cassandra" -}}
{{- if hasKey $values "cluster" -}}
{{- $cluster := get $values "cluster" | default dict -}}
{{- $config := get $cluster "config" | default dict -}}
{{- $configured := get $config "clusterName" | default "" -}}
{{- if or (eq $configured "") (eq $configured $legacyCluster) -}}
{{- include "cassandra.fullname" . -}}
{{- else -}}
{{- $configured -}}
{{- end -}}
{{- else if hasKey $values "cassandra" -}}
{{- $cassandra := get $values "cassandra" | default dict -}}
{{- $cluster := get $cassandra "cluster" | default dict -}}
{{- $config := get $cluster "config" | default dict -}}
{{- $configured := get $config "clusterName" | default "" -}}
{{- if or (eq $configured "") (eq $configured $legacyCluster) -}}
{{- printf "%s-cassandra" .Release.Name -}}
{{- else -}}
{{- $configured -}}
{{- end -}}
{{- else -}}
{{- printf "%s-cassandra" .Release.Name -}}
{{- end -}}
{{- end -}}

{{- define "cassandra.datacenter" -}}
{{- $values := .Values | default dict -}}
{{- $releaseSuffix := regexFind "[^-]+$" .Release.Name | default .Release.Name -}}
{{- $shortSuffix := trunc 4 $releaseSuffix -}}
{{- $defaultDc := printf "d%s" $shortSuffix | trunc 63 | trimSuffix "-" -}}
{{- $legacyDc := "dc1" -}}
{{- $legacyLongDc := printf "%s-dc1" .Release.Name -}}
{{- $legacyMediumDc := printf "dc-%s" $releaseSuffix -}}
{{- if hasKey $values "cluster" -}}
{{- $cluster := get $values "cluster" | default dict -}}
{{- $config := get $cluster "config" | default dict -}}
{{- $configured := get $config "datacenter" | default "" -}}
{{- if or (eq $configured "") (eq $configured $legacyDc) (eq $configured $legacyLongDc) (eq $configured $legacyMediumDc) -}}
{{- $defaultDc -}}
{{- else -}}
{{- $configured -}}
{{- end -}}
{{- else if hasKey $values "cassandra" -}}
{{- $cassandra := get $values "cassandra" | default dict -}}
{{- $cluster := get $cassandra "cluster" | default dict -}}
{{- $config := get $cluster "config" | default dict -}}
{{- $configured := get $config "datacenter" | default "" -}}
{{- if or (eq $configured "") (eq $configured $legacyDc) (eq $configured $legacyLongDc) (eq $configured $legacyMediumDc) -}}
{{- $defaultDc -}}
{{- else -}}
{{- $configured -}}
{{- end -}}
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
{{- $legacyName := "cassandra-server-keystore-secret" -}}
{{- $values := .Values | default dict -}}
{{- $tls := dict -}}
{{- if hasKey $values "tls" -}}
{{- $tls = get $values "tls" | default dict -}}
{{- else if hasKey $values "cassandra" -}}
{{- $tls = dig "cassandra" "tls" dict $values -}}
{{- end -}}
{{- $configured := get $tls "serverSecretName" | default "" -}}
{{- if and (get $tls "enabled") $configured (ne $configured $legacyName) -}}
{{- $configured -}}
{{- else -}}
{{- printf "%s-server-encryption-stores" (include "cassandra.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "cassandra.clientSecretName" -}}
{{- $legacyName := "cassandra-client-trust-secret" -}}
{{- $values := .Values | default dict -}}
{{- $tls := dict -}}
{{- if hasKey $values "tls" -}}
{{- $tls = get $values "tls" | default dict -}}
{{- else if hasKey $values "cassandra" -}}
{{- $tls = dig "cassandra" "tls" dict $values -}}
{{- end -}}
{{- $configured := get $tls "clientSecretName" | default "" -}}
{{- if and (get $tls "enabled") $configured (ne $configured $legacyName) -}}
{{- $configured -}}
{{- else -}}
{{- printf "%s-client-encryption-stores" (include "cassandra.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

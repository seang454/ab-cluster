{{- define "cassandra.fullname" -}}
{{- printf "%s-cassandra" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cassandra.secretName" -}}
{{- printf "%s-cassandra-credentials" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cassandra.storageClass" -}}
{{- .Values.storage.storageClass | default "longhorn" -}}
{{- end -}}

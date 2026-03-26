{{- define "postgresql.fullname" -}}
{{- printf "%s-postgresql" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "postgresql.secretName" -}}
{{- printf "%s-postgresql-credentials" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "postgresql.storageClass" -}}
{{- .Values.storage.storageClass | default "longhorn" -}}
{{- end -}}

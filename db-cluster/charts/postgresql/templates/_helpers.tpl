{{- define "postgresql.fullname" -}}
{{- printf "%s-postgresql" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "postgresql.superuserSecretName" -}}
{{- printf "%s-postgresql-credentials" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "postgresql.appSecretName" -}}
{{- printf "%s-postgresql-app" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "postgresql.storageClass" -}}
{{- .Values.storage.storageClass | default "longhorn" -}}
{{- end -}}

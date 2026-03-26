{{- define "mysql.fullname" -}}
{{- printf "%s-mysql" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mysql.secretName" -}}
{{- printf "%s-mysql-credentials" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

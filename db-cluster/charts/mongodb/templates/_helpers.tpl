{{- define "mongodb.fullname" -}}
{{- printf "%s-mongodb" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mongodb.secretName" -}}
{{- printf "%s-mongodb-credentials" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

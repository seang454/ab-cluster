{{- define "redis.fullname" -}}
{{- printf "%s-redis" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "redis.secretName" -}}
{{- printf "%s-redis-credentials" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

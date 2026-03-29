{{- define "redis.fullname" -}}
{{- printf "%s-redis" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "redis.secretName" -}}
{{- printf "%s-redis-credentials" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "redis.tlsSecretName" -}}
{{- if and .Values.tls.enabled .Values.tls.secretName -}}
{{- .Values.tls.secretName -}}
{{- else -}}
{{- printf "%s-tls" (include "redis.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "redis.caCertificateSecretName" -}}
{{- printf "%s-ca" (include "redis.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "redis.caIssuerName" -}}
{{- printf "%s-ca-issuer" (include "redis.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

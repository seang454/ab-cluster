{{- define "mongodb.fullname" -}}
{{- printf "%s-mongodb" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mongodb.secretName" -}}
{{- if .Values.externalSecretRef -}}
{{- .Values.externalSecretRef -}}
{{- else -}}
{{- printf "%s-mongodb-credentials" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "mongodb.sslSecretName" -}}
{{- if and .Values.tls.enabled .Values.tls.sslSecretName -}}
{{- .Values.tls.sslSecretName -}}
{{- else -}}
{{- printf "%s-ssl" (include "mongodb.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "mongodb.sslInternalSecretName" -}}
{{- if and .Values.tls.enabled .Values.tls.sslInternalSecretName -}}
{{- .Values.tls.sslInternalSecretName -}}
{{- else -}}
{{- printf "%s-ssl-internal" (include "mongodb.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "mongodb.caCertificateSecretName" -}}
{{- printf "%s-ca" (include "mongodb.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mongodb.caIssuerName" -}}
{{- printf "%s-ca-issuer" (include "mongodb.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

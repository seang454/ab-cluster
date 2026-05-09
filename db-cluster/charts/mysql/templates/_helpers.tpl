{{- define "mysql.fullname" -}}
{{- $releaseName := .Release.Name | lower -}}
{{- if le (len $releaseName) 22 -}}
{{- $releaseName | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" ($releaseName | trunc 13 | trimSuffix "-") ($releaseName | sha256sum | trunc 8) | trunc 22 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "mysql.secretName" -}}
{{- if .Values.externalSecretRef -}}
{{- .Values.externalSecretRef -}}
{{- else -}}
{{- printf "%s-mysql-credentials" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "mysql.initSecretName" -}}
{{- if .Values.externalSecretRef -}}
{{- .Values.externalSecretRef -}}
{{- else -}}
{{- printf "%s-mysql-init" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "mysql.sslSecretName" -}}
{{- if and .Values.tls.enabled .Values.tls.sslSecretName -}}
{{- .Values.tls.sslSecretName -}}
{{- else -}}
{{- printf "%s-ssl" (include "mysql.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "mysql.sslInternalSecretName" -}}
{{- if and .Values.tls.enabled .Values.tls.sslInternalSecretName -}}
{{- .Values.tls.sslInternalSecretName -}}
{{- else -}}
{{- printf "%s-ssl-internal" (include "mysql.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "mysql.caCertificateSecretName" -}}
{{- printf "%s-ca" (include "mysql.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mysql.caIssuerName" -}}
{{- printf "%s-ca-issuer" (include "mysql.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

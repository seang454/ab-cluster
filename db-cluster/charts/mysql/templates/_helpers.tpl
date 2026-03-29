{{- define "mysql.fullname" -}}
{{- printf "%s-mysql" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mysql.secretName" -}}
{{- printf "%s-mysql-credentials" .Release.Name | trunc 63 | trimSuffix "-" -}}
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

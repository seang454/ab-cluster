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

{{- define "postgresql.serverTLSSecretName" -}}
{{- if and .Values.tls.enabled (eq (.Values.tls.mode | default "certManager") "existing") .Values.tls.existingSecretName -}}
{{- .Values.tls.existingSecretName -}}
{{- else -}}
{{- printf "%s-cm-server-tls" (include "postgresql.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "postgresql.serverCASecretName" -}}
{{- if and .Values.tls.enabled (eq (.Values.tls.mode | default "certManager") "existing") .Values.tls.existingCASecretName -}}
{{- .Values.tls.existingCASecretName -}}
{{- else -}}
{{- include "postgresql.serverTLSSecretName" . -}}
{{- end -}}
{{- end -}}

{{- define "postgresql.caCertificateSecretName" -}}
{{- printf "%s-cm-ca" (include "postgresql.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "postgresql.caIssuerName" -}}
{{- printf "%s-ca-issuer" (include "postgresql.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "postgresql.externalServiceName" -}}
{{- if .Values.externalAccess.serviceName -}}
{{- .Values.externalAccess.serviceName -}}
{{- else -}}
{{- printf "%s-external-rw" (include "postgresql.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "vault-transit.fullname" -}}
{{- printf "%s-vault-transit" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "vault-transit.serviceAccountName" -}}
{{- printf "%s-vault-transit-sa" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "vault-transit.namespace" -}}
{{- .Values.namespace | default "vault-transit" -}}
{{- end -}}

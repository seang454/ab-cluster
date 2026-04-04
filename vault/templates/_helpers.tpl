{{- define "vault.fullname" -}}
{{- printf "%s-vault" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "vault.serviceAccountName" -}}
{{- printf "%s-vault-auth" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

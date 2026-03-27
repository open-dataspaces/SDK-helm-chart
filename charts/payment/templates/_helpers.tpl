{{- define "payment.base" -}}
{{- printf "%s-payment" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "payment.secretName" -}}
{{- default (printf "%s-secrets" (include "payment.base" .)) .Values.secrets.secretName | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "payment.appName" -}}
{{- printf "%s-payment-app" (include "payment.base" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "payment.dbName" -}}
{{- printf "%s-payment-db" (include "payment.base" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

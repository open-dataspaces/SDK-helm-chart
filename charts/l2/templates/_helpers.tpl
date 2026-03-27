{{- define "l2.base" -}}
{{- printf "%s-l2" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "l2.secretName" -}}
{{- default (printf "%s-secrets" (include "l2.base" .)) .Values.secrets.secretName | trunc 63 | trimSuffix "-" -}}
{{- end -}}

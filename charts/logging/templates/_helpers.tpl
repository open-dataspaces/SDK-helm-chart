{{- define "logging.base" -}}
{{- printf "%s-logging" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

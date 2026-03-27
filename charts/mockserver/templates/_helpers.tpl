{{- define "mockserver.base" -}}
{{- printf "%s-mockserver" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

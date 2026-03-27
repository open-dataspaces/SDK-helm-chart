{{- define "l3.base" -}}
{{- printf "%s-l3" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Expand the name of the chart.
*/}}
{{- define "capsm-cluster-vm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "capsm-cluster-vm.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "capsm-cluster-vm.labels" -}}
helm.sh/chart: {{ include "capsm-cluster-vm.chart" . }}
{{ include "capsm-cluster-vm.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "capsm-cluster-vm.selectorLabels" -}}
app.kubernetes.io/name: {{ include "capsm-cluster-vm.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Generate monitoringid
*/}}
{{- define "capsm-cluster-vm.monitoringid" -}}
{{ adler32sum .Release.Name | int }}
{{- end }}

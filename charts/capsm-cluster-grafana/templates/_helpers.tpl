{{/*
Expand the name of the chart.
*/}}
{{- define "capsm-cluster-grafana.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "capsm-cluster-grafana.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "capsm-cluster-grafana.labels" -}}
helm.sh/chart: {{ include "capsm-cluster-grafana.chart" . }}
{{ include "capsm-cluster-grafana.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "capsm-cluster-grafana.selectorLabels" -}}
app.kubernetes.io/name: {{ include "capsm-cluster-grafana.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the ClusterConfig of the secret to use
*/}}
{{- define "capsm-cluster-grafana.dataSource" -}}
{{- tpl (.Files.Get .Values.dataSourceFile) . | b64enc | quote }}
{{- end }}

{{/*
Generate monitoringid
*/}}
{{- define "capsm-cluster-grafana.monitoringid" -}}
{{ adler32sum .Release.Name | int }}
{{- end }}

{{/*
Expand the name of the chart.
*/}}
{{- define "capsm-cluster-vm.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "capsm-cluster-vm.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
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
Create the name of the service account to use
*/}}
{{- define "capsm-cluster-vm.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "capsm-cluster-vm.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the vmrule-system of the secret to use
*/}}
{{- define "capsm-cluster-vm.vmruleSystemSpec" -}}
{{- tpl (.Files.Get .Values.vmruleSystemSpecFile) . | b64enc | quote }}
{{- end }}


{{/*
Generate monitoringid
*/}}
{{- define "capsm-cluster-vm.monitoringid" -}}
{{ adler32sum .Release.Name | int }}
{{- end }}


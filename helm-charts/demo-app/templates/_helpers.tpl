{{/* Truncated to the 63-character limit on label values. */}}
{{- define "demo-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "demo-app.fullname" -}}
{{- default .Release.Name .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Labels on every object in this chart. */}}
{{- define "demo-app.labels" -}}
app.kubernetes.io/name: {{ include "demo-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: eks-platform
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/*
A Deployment selector is immutable after creation, so no label that changes
between releases (version, chart) may appear here.
*/}}
{{- define "demo-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "demo-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "demo-app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "demo-app.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* Digest wins over tag; fails the render if neither is set. */}}
{{- define "demo-app.image" -}}
{{- $repo := required "image.repository must be set" .Values.image.repository -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" $repo .Values.image.digest -}}
{{- else if .Values.image.tag -}}
{{- printf "%s:%s" $repo .Values.image.tag -}}
{{- else -}}
{{- fail "either image.digest or image.tag must be set" -}}
{{- end -}}
{{- end -}}

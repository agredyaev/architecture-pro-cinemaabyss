{{/*
Expand the name of the chart.
*/}}
{{- define "cinemaabyss.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "cinemaabyss.fullname" -}}
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
{{- define "cinemaabyss.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "cinemaabyss.labels" -}}
helm.sh/chart: {{ include "cinemaabyss.chart" . }}
{{ include "cinemaabyss.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "cinemaabyss.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cinemaabyss.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "cinemaabyss.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "cinemaabyss.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Return the namespace
*/}}
{{- define "cinemaabyss.namespace" -}}
{{- default .Values.global.namespace .Release.Namespace }}
{{- end }}
{{/*
Create a full service deployment and service manifest
*/}}
{{- define "cinemaabyss.service.tpl" -}}
{{- $root := .root -}}
{{- $service := .service -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $root.Release.Name }}-{{ $service.name }}
  namespace: {{ include "cinemaabyss.namespace" $root }}
  labels:
    app: {{ $service.name }}
spec:
  replicas: {{ $service.replicas }}
  selector:
    matchLabels:
      app: {{ $service.name }}
  template:
    metadata:
      labels:
        app: {{ $service.name }}
    spec:
      containers:
      - name: {{ $service.name }}
        image: "{{ $root.Values.global.image.registry }}/{{ $service.image.repository }}:{{ $service.image.tag }}"
        imagePullPolicy: {{ $service.image.pullPolicy }}
        ports:
        - containerPort: {{ $service.service.targetPort }}
        env:
          {{- range $key, $value := $service.env }}
        - name: {{ $key }}
          {{- if kindIs "map" $value }}
          valueFrom:
            {{- if $value.configMapKeyRef }}
            configMapKeyRef:
              name: {{ $root.Release.Name }}-config
              key: {{ $value.configMapKeyRef.key }}
            {{- else if $value.secretKeyRef }}
            secretKeyRef:
              name: {{ $root.Release.Name }}-secrets
              key: {{ $value.secretKeyRef.key }}
            {{- end }}
          {{- else }}
          value: {{ $value | quote }}
          {{- end }}
          {{- end }}
        envFrom:
        - configMapRef:
            name: cinemaabyss-config
        - secretRef:
            name: cinemaabyss-secrets
        resources:
          limits:
            cpu: {{ $service.resources.limits.cpu }}
            memory: {{ $service.resources.limits.memory }}
          requests:
            cpu: {{ $service.resources.requests.cpu }}
            memory: {{ $service.resources.requests.memory }}
      imagePullSecrets:
      - name: {{ $root.Values.imagePullSecrets.name }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ $service.name }}
  namespace: {{ include "cinemaabyss.namespace" $root }}
spec:
  selector:
    app: {{ $service.name }}
  ports:
  - protocol: TCP
    port: {{ $service.service.port }}
    targetPort: {{ $service.service.targetPort }}
  type: {{ $service.service.type }}
{{- end -}}
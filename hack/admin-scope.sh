#!/usr/bin/env bash

export KUBECONFIG=admin.kubeconfig

kubectl config get-contexts

kubectl config use-context default
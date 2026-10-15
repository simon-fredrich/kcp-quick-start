#!/usr/bin/env bash

for i in {1..100}; do
  kubectl ws create "team-$i"
done